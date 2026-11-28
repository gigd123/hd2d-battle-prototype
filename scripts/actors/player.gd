class_name PlayerController
extends CharacterBody3D
## 玩家：步行時是 CharacterBody3D；騎馬時關閉自己的碰撞，由馬帶著走，
## 輸入改為驅動馬。武器命中用「掃掠幾何」（前一物理步與這一物理步的刀身連成的面），
## 高速衝鋒也不會穿透目標；同一次揮擊對同一目標只算一次。

signal hit_landed(hits: int, total_damage: float)
signal died
## 以下訊號只給畫面／音效回饋用（CombatFX），判定邏輯不依賴它們
signal swing_started(mounted: bool)
signal hit_detail(point: Vector3, damage: float, killed: bool, closing_speed: float)
signal damaged(amount: float)
signal blocked(point: Vector3)             # 舉盾擋下攻擊
signal weapon_stuck(point: Vector3)        # 長槍貼身刺不出去
signal weapon_changed(weapon_name: String)

enum AttackPhase { NONE, WINDUP, SWING, RECOVER }
## 武器數值全部在 WeaponDefs（scripts/combat/weapon_defs.gd），這裡只放跟武器無關的手感數值

@export var walk_speed := 4.4
@export var run_speed := 7.6
@export var gravity := 25.0
@export var max_hp := 250.0
@export var mount_range := 3.0
@export var mount_duration := 0.35
@export var blade_radius := 0.15
@export var block_speed_scale := 0.5
# 步伐（每跑一個動畫循環前進的距離，越大步伐越大）
@export var walk_stride := 1.9
@export var run_stride := 3.2
# 受擊反應
@export var hurt_time := 0.32           # 硬直秒數：移動變慢、蓄力會被打斷
@export var hurt_knockback := 6.0       # 步行時被擊退的初速（m/s）
@export var back_speed_scale := 0.6     # 往後退的速度比例（邊打邊退）
@export var strafe_speed_scale := 0.8   # 左右平移的速度比例

var team := 0
var horse: Horse
var cam_rig: OrbitFollowCamera
var terrain: BattleTerrain
var battle: Node = null               # BattleManager（階段 2 起）
var visual: LayeredActorVisual
const PLAYER_TINT := Color(0.25, 0.45, 0.85)
var _baked: BakedSpriteSet = null     # 預渲染圖集（null = 用佔位圖）
var spawn_point := Vector3.ZERO

var mounted := false
var hp := 250.0
var dead := false
var facing := Vector3(0, 0, -1)
var attack_phase := AttackPhase.NONE
var attack_timer := 0.0
var total_kills := 0
## 最近幾次揮擊的掃掠線段（除錯繪製用）：每筆 [prev_tip, tip, base, 剩餘秒數]
var debug_sweeps: Array = []

var _mount_t := -1.0
var _mount_from := Vector3.ZERO
var _respawn_timer := 0.0
var _swing_hit: Dictionary = {}
var _swing_prev_base := Vector3.ZERO
var _swing_prev_tip := Vector3.ZERO
var _walk_phase := 0.0
var _prev_pos := Vector3.ZERO
var _cur_pos := Vector3.ZERO
var _shape: CollisionShape3D
var _swing_dir := 1.0            # +1：右→左橫掃；-1：左→右（連段交替）
var _attack_buffered := false    # 收招中按下攻擊 → 收招結束立刻接下一刀
var _swing_t := -1.0             # 目前揮擊進度 0..1；-1 = 沒有在揮
var weapon := 0                  # WeaponDefs 的索引
var wdef: Dictionary = WeaponDefs.get_def(0)
var blocking := false
## 弓：拉弓秒數（-1 = 沒在拉）、瞄準視角（1 = 第三人稱肩後、2 = 第一人稱）
var draw_t := -1.0
var aim_view := 1
var _release_t := -1.0           # 放箭動作剩餘秒數
var hurt_t := 0.0                # >0：受擊硬直中
var _knock := Vector3.ZERO       # 擊退速度（逐漸衰減）
var _flash_t := 0.0              # 受擊閃紅剩餘秒數
var _recoil := Vector3.ZERO      # 畫面上的後仰位移（不影響判定）


func _ready() -> void:
	hp = max_hp
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.4
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	_shape = CollisionShape3D.new()
	_shape.name = "Shape"
	_shape.shape = cap
	_shape.position = Vector3(0, 0.9, 0)     # 原點在腳底
	add_child(_shape)
	_build_visual()
	GameConfig.art_mode_changed.connect(_build_visual)
	_prev_pos = global_position
	_cur_pos = global_position


## 建立（或重建）畫面：有預渲染圖就用它（身體＋劍兩層），否則用佔位圖
func _build_visual() -> void:
	if visual:
		visual.queue_free()
	visual = LayeredActorVisual.new()
	visual.name = "PlayerVisual"
	_baked = GameConfig.baked_set("knight")
	if _baked:
		visual.setup_main_baked(_baked, visual_layers(_baked), PLAYER_TINT)
	else:
		visual.setup_main(PlaceholderArt.unit_atlas_tinted(PlaceholderArt.Unit.INFANTRY, PLAYER_TINT), PlaceholderArt.HUMAN_FRAME, PlaceholderArt.HUMAN_ROWS)
	add_child(visual)


## 目前武器要疊哪些圖層：身體＋（盾）＋武器。舊的烘焙圖沒有盾／該武器圖層時自動略過。
func visual_layers(bs: BakedSpriteSet) -> Array:
	var out := ["body"]
	if wdef["shield"] and bs.has_layer("shield"):
		out.append("shield")
	out.append(wdef["layer"] if bs.has_layer(wdef["layer"]) else "sword")
	return out


## 換武器：dir = +1 下一把、-1 上一把
func _switch_weapon(dir := 1) -> void:
	var old_layer: String = wdef["layer"]
	weapon = posmod(weapon + dir, WeaponDefs.count())
	wdef = WeaponDefs.get_def(weapon)
	draw_t = -1.0
	_build_visual()
	if horse:
		horse.call("_build_visual")
	# 換下來的武器圖層釋放記憶體（每張圖層圖集都不小）
	if _baked and old_layer != wdef["layer"]:
		_baked.release_layer(old_layer)
	weapon_changed.emit(wdef["name"])


func weapon_name() -> String:
	return wdef["name"]


func is_bow() -> bool:
	return wdef["kind"] == "bow"


## 正在用弓瞄準（相機與準心用）
func is_aiming() -> bool:
	return is_bow() and draw_t >= 0.0 and not dead


func draw_power() -> float:
	if draw_t < 0.0:
		return 0.0
	return clampf(draw_t / float(wdef["draw_time"]), 0.0, 1.0)


func reach() -> float:
	return float(wdef["reach_mounted"] if mounted else wdef["reach_foot"])


## 揮擊進度 0..1（含蓄力與收招），給預渲染動畫選幀：蓄力 = 前 1/3，揮出 = 中段，收招 = 最後 1/6
func attack_anim_progress() -> float:
	if wdef["kind"] == "thrust":
		# 刺擊動畫：0~0.3 收槍、0.5 刺出、之後收回
		match attack_phase:
			AttackPhase.WINDUP:
				return (1.0 - attack_timer / _wt()) * 0.4
			AttackPhase.SWING:
				return 0.4 + (1.0 - attack_timer / _st()) * 0.3
			AttackPhase.RECOVER:
				return 0.7 + (1.0 - attack_timer / _rt()) * 0.3
		return 0.0
	match attack_phase:
		AttackPhase.WINDUP:
			return (1.0 - attack_timer / _wt()) / 3.0
		AttackPhase.SWING:
			return 1.0 / 3.0 + (1.0 - attack_timer / _st()) * 0.5
		AttackPhase.RECOVER:
			return 5.0 / 6.0 + (1.0 - attack_timer / _rt()) / 6.0
	return 0.0


func _attack_action(on_horse: bool) -> String:
	if wdef["anim"] == "thrust":
		if on_horse:
			return "ride_thrust"
		return "walk_thrust" if _moving() else "thrust"
	var side := "_a" if _swing_dir > 0.0 else "_b"
	var base := "heavy" if wdef["anim"] == "heavy" else "attack"
	if on_horse:
		return "ride_" + base + side
	if _moving():
		return "walk_" + base + side
	return base + side


func _moving() -> bool:
	return Vector2(velocity.x, velocity.z).length() > 0.5


func _wt() -> float:
	return wdef["windup"]


func _st() -> float:
	return wdef["swing"]


func _rt() -> float:
	return wdef["recover"]


## 舉盾或用武器格擋時的動作名（block / walk_block / ride_block，或 parry 系列）
func _guard_action(prefix: String) -> String:
	var base := "parry" if wdef["block"] == "weapon" else "block"
	return prefix + base


func _row_or(action: String, fallback: String, progress: float) -> int:
	return _baked.row_at_progress(action if _baked.has_action(action) else fallback, progress)


## 預渲染圖：步行時選哪一列
func _baked_foot_row() -> int:
	if dead:
		return _baked.row_at_time("death", 4.0 - _respawn_timer)
	var spd := Vector2(velocity.x, velocity.z).length()
	if is_bow():
		if _release_t >= 0.0:
			return _row_or("bow_release", "idle", 1.0 - _release_t / float(wdef["recover"]))
		if draw_t >= 0.0:
			if spd > 0.3 and draw_power() > 0.5:
				return _row_or("walk_bow", "walk", fmod(_walk_phase / walk_stride, 1.0))
			return _row_or("bow_draw", "idle", draw_power())
	if attack_phase != AttackPhase.NONE:
		var fb := ("thrust" if wdef["anim"] == "thrust" else ("attack_a" if _swing_dir > 0.0 else "attack_b"))
		return _row_or(_attack_action(false), fb, attack_anim_progress())
	if hurt_t > 0.0 and not blocking:
		return _row_or("hurt", "idle", 1.0 - hurt_t / hurt_time)
	if blocking:
		if spd > 0.3:
			return _row_or(_guard_action("walk_"), "walk", fmod(_walk_phase / walk_stride, 1.0))
		return _row_or(_guard_action(""), "idle", fmod(Time.get_ticks_msec() / 1000.0, 1.0))
	if spd > 0.3:
		if spd > (walk_speed + run_speed) * 0.5:
			return _baked.row_at_progress("run", fmod(_walk_phase / run_stride, 1.0))
		return _baked.row_at_progress("walk", fmod(_walk_phase / walk_stride, 1.0))
	return _baked.row_at_time("idle", Time.get_ticks_msec() / 1000.0)


# ---------------------------------------------------------------------------
# 給其他系統查詢的介面
# ---------------------------------------------------------------------------
func is_seated() -> bool:
	return mounted and _mount_t < 0.0


func is_targetable() -> bool:
	return not dead


## 邏輯上的身體中心（士兵攻擊距離以此計算）
func body_center() -> Vector3:
	return global_position + Vector3(0, 2.0 if mounted else 1.0, 0)


func move_velocity() -> Vector3:
	if mounted and horse:
		return horse.forward() * horse.speed + horse.right() * horse.side
	return Vector3(velocity.x, 0, velocity.z)


## from_pos：攻擊來源位置（決定擊退方向）；不給就往面向的反方向退
## ranged：是不是箭（用武器格擋擋不了箭，盾可以）
func take_damage(amount: float, from_pos = null, ranged := false) -> void:
	if dead:
		return
	var away := -facing
	if from_pos != null:
		away = global_position - (from_pos as Vector3)
		away.y = 0.0
		away = away.normalized() if away.length_squared() > 0.0001 else -facing
	# 舉盾：正前方的攻擊大幅減傷，不會硬直也不會被打斷
	var can_guard: bool = wdef["block"] == "shield" or (wdef["block"] == "weapon" and not ranged)
	if blocking and can_guard and from_pos != null and facing.dot(-away) > cos(deg_to_rad(wdef["block_angle_deg"])):
		hp -= amount * (1.0 - float(wdef["block_reduce"]))
		if not mounted:
			_knock = away * 1.6
		blocked.emit(global_position + Vector3(0, 2.0 if mounted else 1.1, 0) - away * 0.5)
		if hp <= 0.0:
			_die()
		return
	hp -= amount
	hurt_t = hurt_time
	# 被打中會中斷目前的動作（蓄力、揮出、收招都算）
	if attack_phase != AttackPhase.NONE:
		attack_phase = AttackPhase.NONE
		_swing_t = -1.0
		_attack_buffered = false
	draw_t = -1.0                    # 拉弓也會被打斷
	_flash_t = 0.18
	_recoil = away * (0.12 if mounted else 0.25)
	if not mounted:
		_knock = away * hurt_knockback * clampf(amount / 15.0, 0.5, 1.3)
	damaged.emit(amount)
	if hp <= 0.0:
		_die()


func _die() -> void:
	if dead:
		return
	hp = 0.0
	if mounted and _mount_t < 0.0:
		_dismount()          # 落馬
	dead = true
	blocking = false
	_respawn_timer = 4.0
	attack_phase = AttackPhase.NONE
	_swing_t = -1.0
	died.emit()


func rider_anim_row() -> int:
	if _baked:
		if is_bow() and (draw_t >= 0.0 or _release_t >= 0.0):
			return _row_or("ride_bow", "ride_idle", 0.0)
		if attack_phase != AttackPhase.NONE:
			return _row_or(_attack_action(true), "ride_attack_a", attack_anim_progress())
		if blocking:
			return _row_or(_guard_action("ride_"), "ride_idle", fmod(Time.get_ticks_msec() / 1000.0, 1.0))
		return _baked.row_at_time("ride_idle", Time.get_ticks_msec() / 1000.0)
	match attack_phase:
		AttackPhase.WINDUP:
			return PlaceholderArt.RIDER_WINDUP
		AttackPhase.SWING:
			return PlaceholderArt.RIDER_SWING
		_:
			return PlaceholderArt.RIDER_IDLE


# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_update_debug_sweeps(delta)
	hurt_t = maxf(hurt_t - delta, 0.0)
	if dead:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_respawn()
		_store_pos()
		return

	var input := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
	var dir := Vector3.ZERO
	if cam_rig:
		dir = cam_rig.flat_right() * input.x + cam_rig.flat_forward() * input.y
	if dir.length() > 1.0:
		dir = dir.normalized()
	var sprint := Input.is_action_pressed("sprint")

	if Input.is_action_just_pressed("interact") and _mount_t < 0.0:
		if mounted:
			_dismount()
		elif horse and global_position.distance_to(horse.global_position) <= mount_range:
			_start_mount()

	if attack_phase == AttackPhase.NONE and draw_t < 0.0:
		if Input.is_action_just_pressed("switch_weapon"):
			_switch_weapon(1)
		elif Input.is_action_just_pressed("prev_weapon"):
			_switch_weapon(-1)
	if Input.is_action_just_pressed("aim_view"):
		aim_view = 2 if aim_view == 1 else 1

	if is_bow():
		blocking = false
		_update_bow(delta)
	else:
		# 右鍵舉盾（或用雙手武器格擋）：硬直中舉不起來；蓄力中舉起會取消這一刀，揮出後要等收招完
		var want_block: bool = Input.is_action_pressed("block") and _mount_t < 0.0 and hurt_t <= 0.0 and wdef["block"] != "none"
		if want_block and attack_phase == AttackPhase.WINDUP:
			attack_phase = AttackPhase.NONE
			_attack_buffered = false
		blocking = want_block and attack_phase == AttackPhase.NONE

		if Input.is_action_just_pressed("attack") and _mount_t < 0.0 and not blocking:
			if attack_phase == AttackPhase.NONE:
				_begin_attack()
			elif attack_phase == AttackPhase.RECOVER or attack_phase == AttackPhase.SWING:
				_attack_buffered = true

	if _mount_t >= 0.0:
		_update_mount_transition(delta)
	elif mounted:
		# 騎馬：跟步行一樣由滑鼠決定方向、W 前進 S 後退（細節見 Horse.set_drive_look），朝向 = 馬頭方向
		if cam_rig:
			horse.set_drive_look(cam_rig.flat_forward(), input, sprint)
		else:
			horse.set_drive(dir, sprint)
		global_position = horse.global_position
		facing = horse.forward()
	else:
		_move_on_foot(dir, input, sprint, delta)

	_update_attack(delta)
	_store_pos()


## 步行：朝向由滑鼠（相機）決定，WASD 只決定相對相機的前後左右，不改朝向 → 可以邊打邊後退。
## 往後退與平移比較慢；只有往前時才能奔跑。
func _move_on_foot(dir: Vector3, input: Vector2, sprint: bool, delta: float) -> void:
	if cam_rig and attack_phase != AttackPhase.SWING and attack_phase != AttackPhase.RECOVER:
		facing = cam_rig.flat_forward()      # 揮出後到收招前鎖定，掃掠弧線才不會被滑鼠甩歪
	var can_run := sprint and input.y > 0.3 and not blocking and draw_t < 0.0
	var spd := run_speed if can_run else walk_speed
	if input.length() > 0.01:
		var n := input.normalized()
		spd *= lerpf(1.0, back_speed_scale if n.y < 0.0 else strafe_speed_scale, minf(absf(n.y) if n.y < 0.0 else absf(n.x), 1.0))
	if attack_phase != AttackPhase.NONE or draw_t >= 0.0:
		spd *= float(wdef["attack_move"])
	if blocking:
		spd *= block_speed_scale
	if hurt_t > 0.0:
		spd *= 0.3
	var dl := Vector2(dir.x, dir.z).length()
	if terrain and dl > 0.1:
		spd *= terrain.move_factor(global_position.x, global_position.z, dir.x / dl, dir.z / dl)
	velocity.x = dir.x * spd + _knock.x
	velocity.z = dir.z * spd + _knock.z
	_knock = _knock.move_toward(Vector3.ZERO, 18.0 * delta)
	if is_on_floor():
		velocity.y = -1.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()
	if terrain:
		global_position = terrain.clamp_to_map(global_position, 3.0)
	_walk_phase += Vector2(velocity.x, velocity.z).length() * delta


func _store_pos() -> void:
	_prev_pos = _cur_pos
	_cur_pos = global_position


func visual_position() -> Vector3:
	return _prev_pos.lerp(_cur_pos, Engine.get_physics_interpolation_fraction())


# ---------------------------------------------------------------------------
# 上馬 / 下馬
# ---------------------------------------------------------------------------
func _start_mount() -> void:
	_mount_t = 0.0
	_mount_from = global_position
	mounted = true
	horse.rider = self
	_shape.disabled = true
	velocity = Vector3.ZERO


func _update_mount_transition(delta: float) -> void:
	_mount_t += delta / mount_duration
	var t := minf(_mount_t, 1.0)
	var to := horse.global_position
	var p := _mount_from.lerp(to, t)
	p.y += sin(t * PI) * 1.2          # 一個跳上去的弧線
	global_position = p
	facing = horse.forward()
	if _mount_t >= 1.0:
		_mount_t = -1.0
		global_position = to


func _dismount() -> void:
	# 依序嘗試：馬的左側、右側、後方、前方；選第一個不會卡進牆或岩石的位置
	var f := horse.forward()
	var right := Vector3(-f.z, 0, f.x)
	var candidates := [-right * 1.5, right * 1.5, -f * 2.2, f * 2.2]
	var chosen := horse.global_position + Vector3(0, 0.3, 0)
	for off in candidates:
		var p: Vector3 = horse.global_position + off
		if terrain:
			p.y = terrain.get_height(p.x, p.z) + 0.05
		if _is_free(p):
			chosen = p
			break
	mounted = false
	horse.rider = null
	horse.set_drive(Vector3.ZERO, false)
	global_position = chosen
	_shape.disabled = false
	velocity = Vector3.ZERO


func _is_free(p: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _shape.shape
	q.transform = Transform3D(Basis(), p + Vector3(0, 0.95, 0))
	q.exclude = [get_rid(), horse.get_rid()]
	var hits := get_world_3d().direct_space_state.intersect_shape(q, 1)
	return hits.is_empty()


func _respawn() -> void:
	dead = false
	hp = max_hp
	if mounted:
		mounted = false
		horse.rider = null
	_mount_t = -1.0
	_shape.disabled = false
	global_position = spawn_point
	velocity = Vector3.ZERO
	_prev_pos = spawn_point
	_cur_pos = spawn_point
	if horse:
		horse.teleport(spawn_point + Vector3(2.5, 0, 0), horse.heading)


# ---------------------------------------------------------------------------
# 揮擊與掃掠命中
# ---------------------------------------------------------------------------
func _begin_attack() -> void:
	attack_phase = AttackPhase.WINDUP
	attack_timer = _wt()
	_attack_buffered = false


## 給畫面回饋用：目前揮擊進度（0..1），收招中仍回傳 1 讓刀光淡出；沒有揮擊時回傳 -1。
func swing_progress() -> float:
	return _swing_t


## 給畫面回饋用：以「畫面內插位置」計算刀柄與刀尖，讓刀光跟著角色畫面而不是物理步。
func blade_at(t: float) -> Array:
	return _swing_geometry(t, visual_position())


func _update_attack(delta: float) -> void:
	if attack_phase == AttackPhase.NONE:
		return
	attack_timer -= delta
	match attack_phase:
		AttackPhase.WINDUP:
			if attack_timer <= 0.0:
				attack_phase = AttackPhase.SWING
				attack_timer = _st()
				_swing_t = 0.0
				_swing_hit.clear()
				swing_started.emit(mounted)
				var g := _swing_geometry(0.0)
				_swing_prev_base = g[0]
				_swing_prev_tip = g[1]
		AttackPhase.SWING:
			var t := clampf(1.0 - attack_timer / _st(), 0.0, 1.0)
			_swing_t = t
			var g := _swing_geometry(t)
			_sweep(_swing_prev_base, _swing_prev_tip, g[0], g[1])
			_swing_prev_base = g[0]
			_swing_prev_tip = g[1]
			if attack_timer <= 0.0:
				attack_phase = AttackPhase.RECOVER
				attack_timer = _rt()
		AttackPhase.RECOVER:
			if attack_timer <= _rt() - 0.12:
				_swing_t = -1.0
			if attack_timer <= 0.0:
				attack_phase = AttackPhase.NONE
				_swing_dir = -_swing_dir
				if _attack_buffered:
					_begin_attack()


## t: 0..1 揮擊進度。回傳 [刀柄位置, 刀尖位置]（世界座標）。
## 由右後上方往左前下方橫掃；騎馬時從較高處往下砍到步兵胸口高度。
func _swing_geometry(t: float, origin = null) -> Array:
	var at: Vector3 = global_position if origin == null else origin
	var f := facing
	var right := Vector3(-f.z, 0, f.x)
	var shoulder_h := 2.3 if mounted else 1.35
	if wdef["kind"] == "thrust":
		# 刺擊：槍從肩膀往正前方（略往下）直直推出去，前段收在身邊、刺到底時達最大距離
		var sb := at + Vector3(0, shoulder_h - 0.1, 0) + right * 0.2
		var sdir := (f + Vector3(0, -0.35 if mounted else -0.12, 0)).normalized()
		var se := t * t * (3.0 - 2.0 * t)
		var stip := sb + sdir * reach() * lerpf(0.35, 1.0, se)
		return [stip - sdir * 1.0, stip]
	var reach := reach()
	var base := at + Vector3(0, shoulder_h, 0) + right * 0.25 * _swing_dir
	# 前後段慢、中段快（ease），比等速轉動更有「甩出去」的感覺
	var e := t * t * (3.0 - 2.0 * t)
	var half := deg_to_rad(float(wdef["arc_deg"]) * 0.5)     # 掃過的角度由武器決定（單手劍窄、大劍寬）
	var ang := lerpf(half, -half, e) * _swing_dir
	var drop := lerpf(0.2, -1.0 if mounted else -0.5, e)
	var tip := base + (f * cos(ang) + right * sin(ang)) * reach + Vector3(0, drop, 0)
	var hilt := base + (tip - base) * 0.25
	return [hilt, tip]


func _sweep(prev_base: Vector3, prev_tip: Vector3, base: Vector3, tip: Vector3) -> void:
	debug_sweeps.append([prev_tip, tip, base, 0.6])
	if battle == null:
		return
	var max_t: int = wdef["max_targets"]
	if _swing_hit.size() >= max_t:
		return                         # 這一刀已經砍滿人數，後面掃到的都不算
	var hits: PackedInt32Array = battle.call("sweep_query", prev_base, prev_tip, base, tip, blade_radius, team, _swing_hit)
	if hits.is_empty():
		return
	# 同一步掃到多人時，近的先算
	var order: Array = []
	for idx in hits:
		var sp: Vector3 = battle.call("soldier_position", idx)
		order.append([Vector2(sp.x - global_position.x, sp.z - global_position.z).length(), idx])
	order.sort_custom(func(x, y): return x[0] < y[0])
	var my_vel := move_velocity()
	var total := 0.0
	var landed := 0
	var stuck := false
	var long_bonus := 1.4 if mounted and (wdef["kind"] == "thrust" or float(wdef["reach_foot"]) >= 2.2) else 1.0
	for e in order:
		if _swing_hit.size() >= max_t:
			break
		var idx: int = e[1]
		var flat_d: float = e[0]
		_swing_hit[idx] = true
		var spos: Vector3 = battle.call("soldier_position", idx)
		var svel: Vector3 = battle.call("soldier_velocity", idx)
		var to_target := spos - global_position
		to_target.y = 0
		to_target = to_target.normalized()
		# 相對速度在「朝向目標」方向的分量：迎面衝鋒 > 靜止 > 同向追擊
		var closing := maxf(0.0, (my_vel - svel).dot(to_target))
		var dmg: float = float(wdef["damage"]) + closing * float(wdef["speed_damage"]) * long_bonus
		if not mounted and flat_d < float(wdef["min_dist"]):
			# 貼太近：長武器用柄打到（傷害打折）；長槍則是頂住刺不出去，這一刀直接結束
			dmg *= float(wdef["close_mult"])
			stuck = wdef["stuck"]
		var knock := to_target * (0.6 + closing * 0.12) * float(wdef["knockback"])
		var killed: bool = battle.call("apply_damage", idx, dmg, knock)
		if killed:
			total_kills += 1
		total += dmg
		landed += 1
		var point := spos + Vector3(0, 1.2, 0) - to_target * 0.3
		hit_detail.emit(point, dmg, killed, closing)
		if stuck:
			weapon_stuck.emit(point)
			break
	hit_landed.emit(landed, total)
	if stuck:
		attack_phase = AttackPhase.RECOVER
		attack_timer = _rt() + 0.3
		_swing_t = -1.0


# ---------------------------------------------------------------------------
# 弓：按住攻擊鍵拉弓、放開射出；拉弓中鏡頭進入瞄準視角（F 切換肩後／第一人稱）
# ---------------------------------------------------------------------------
func _update_bow(delta: float) -> void:
	if _release_t >= 0.0:
		if Input.is_action_just_pressed("attack"):
			_attack_buffered = true
		_release_t -= delta
		if _release_t < 0.0:
			_release_t = -1.0
		return
	if _mount_t >= 0.0 or hurt_t > 0.0:
		draw_t = -1.0
		return
	if draw_t < 0.0:
		if Input.is_action_just_pressed("attack") or (Input.is_action_pressed("attack") and _attack_buffered):
			draw_t = 0.0
			_attack_buffered = false
		return
	if Input.is_action_pressed("attack"):
		draw_t += delta
		return
	# 放開：拉得夠才射，太早放開等於取消
	if draw_t >= float(wdef["min_draw"]):
		_fire_arrow(draw_power())
		_release_t = float(wdef["recover"])
	draw_t = -1.0


## 箭的出發點與方向：從胸口射向「相機準心」對到的地面點（沒有碰到地面就取遠處）
func _fire_arrow(power: float) -> void:
	var origin := body_center() + Vector3(0, 0.45, 0)
	var dir := Vector3(facing.x, 0.0, facing.z).normalized()
	var cam := get_viewport().get_camera_3d()
	if cam:
		var cf := -cam.global_basis.z
		var target := cam.global_position + cf * 90.0
		if terrain:
			var p := cam.global_position
			for i in 90:
				p += cf
				if p.y <= terrain.get_height(p.x, p.z):
					target = p
					break
		dir = (target - origin).normalized()
	var spd := lerpf(float(wdef["arrow_speed_min"]), float(wdef["arrow_speed_max"]), power)
	var dmg := lerpf(float(wdef["arrow_dmg_min"]), float(wdef["arrow_dmg_max"]), power)
	swing_started.emit(mounted)
	if battle != null:
		battle.call("fire_player_arrow", origin, dir * spd, dmg, team)


## 第一人稱瞄準中：自己（和馬上的騎士）不畫，免得擋住鏡頭
func first_person() -> bool:
	return is_aiming() and aim_view == 2


## BattleManager 回報玩家的箭射中士兵
func on_arrow_hit(point: Vector3, dmg: float, killed: bool) -> void:
	if killed:
		total_kills += 1
	hit_detail.emit(point, dmg, killed, 0.0)
	hit_landed.emit(1, dmg)


func _update_debug_sweeps(delta: float) -> void:
	for i in range(debug_sweeps.size() - 1, -1, -1):
		debug_sweeps[i][3] -= delta
		if debug_sweeps[i][3] <= 0.0:
			debug_sweeps.remove_at(i)


# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	# 命中停頓的那一幀 time_scale 會突然變小，換算回真實時間要設上限，否則閃紅會一幀就結束
	var real_dt := minf(delta / maxf(Engine.time_scale, 0.001), 0.05)
	_flash_t = maxf(_flash_t - real_dt, 0.0)
	_recoil = _recoil.lerp(Vector3.ZERO, minf(1.0, real_dt * 12.0))
	var tint := Color(1.0, 0.35, 0.3) if _flash_t > 0.0 else Color.WHITE
	var show_foot := not is_seated()
	if cam_rig:
		cam_rig.aim_mode = aim_view if is_aiming() else 0
	visual.visible = show_foot and not first_person()
	if horse and horse.visual:
		horse.visual.set_attach_tint(tint)
	if not show_foot:
		return
	visual.set_tint(tint)
	var vp := visual_position() + _recoil
	if _baked:
		visual.update_visual(vp, facing, cam, _baked_foot_row())
		return
	var row := PlaceholderArt.ROW_IDLE
	if dead:
		row = PlaceholderArt.ROW_DEAD
	elif attack_phase == AttackPhase.SWING or attack_phase == AttackPhase.RECOVER:
		row = PlaceholderArt.ROW_ATTACK
	elif Vector2(velocity.x, velocity.z).length() > 0.3:
		row = PlaceholderArt.ROW_WALK if int(_walk_phase / 0.6) % 2 == 0 else PlaceholderArt.ROW_IDLE
	visual.update_visual(vp, facing, cam, row)
