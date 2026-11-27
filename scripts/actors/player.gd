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

enum AttackPhase { NONE, WINDUP, SWING, RECOVER }

@export var walk_speed := 3.8
@export var run_speed := 6.5
@export var gravity := 25.0
@export var max_hp := 250.0
@export var mount_range := 3.0
@export var mount_duration := 0.35
# 揮擊時間（秒）
@export var windup_time := 0.22
@export var swing_time := 0.18
@export var recover_time := 0.25
# 揮擊幾何
@export var reach_mounted := 2.0
@export var reach_foot := 1.6
@export var base_damage := 22.0
@export var speed_damage := 3.0       # 每 m/s 相對速度加成
@export var blade_radius := 0.15

var team := 0
var horse: Horse
var cam_rig: OrbitFollowCamera
var terrain: BattleTerrain
var battle: Node = null               # BattleManager（階段 2 起）
var visual: LayeredActorVisual
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
	visual = LayeredActorVisual.new()
	visual.name = "PlayerVisual"
	visual.setup_main(PlaceholderArt.unit_atlas_tinted(PlaceholderArt.Unit.INFANTRY, Color(0.25, 0.45, 0.85)), PlaceholderArt.HUMAN_FRAME, PlaceholderArt.HUMAN_ROWS)
	add_child(visual)
	_prev_pos = global_position
	_cur_pos = global_position


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
		return horse.forward() * horse.speed
	return Vector3(velocity.x, 0, velocity.z)


func take_damage(amount: float) -> void:
	if dead:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		hp = 0.0
		if mounted and _mount_t < 0.0:
			_dismount()          # 落馬
		dead = true
		_respawn_timer = 4.0
		attack_phase = AttackPhase.NONE
		died.emit()


func rider_anim_row() -> int:
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

	if Input.is_action_just_pressed("attack") and _mount_t < 0.0:
		if attack_phase == AttackPhase.NONE:
			_begin_attack()
		elif attack_phase == AttackPhase.RECOVER or attack_phase == AttackPhase.SWING:
			_attack_buffered = true

	if _mount_t >= 0.0:
		_update_mount_transition(delta)
	elif mounted:
		horse.set_drive(dir, sprint)
		global_position = horse.global_position
		facing = horse.forward()
	else:
		_move_on_foot(dir, sprint, delta)

	_update_attack(delta)
	_store_pos()


func _move_on_foot(dir: Vector3, sprint: bool, delta: float) -> void:
	var spd := run_speed if sprint else walk_speed
	if attack_phase != AttackPhase.NONE:
		spd *= 0.4
	var dl := Vector2(dir.x, dir.z).length()
	if terrain and dl > 0.1:
		spd *= terrain.move_factor(global_position.x, global_position.z, dir.x / dl, dir.z / dl)
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd
	if is_on_floor():
		velocity.y = -1.0
	else:
		velocity.y -= gravity * delta
	if dir.length() > 0.1 and attack_phase == AttackPhase.NONE:
		facing = Vector3(dir.x, 0, dir.z).normalized()
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
	attack_timer = windup_time
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
				attack_timer = swing_time
				_swing_t = 0.0
				_swing_hit.clear()
				swing_started.emit(mounted)
				var g := _swing_geometry(0.0)
				_swing_prev_base = g[0]
				_swing_prev_tip = g[1]
		AttackPhase.SWING:
			var t := clampf(1.0 - attack_timer / swing_time, 0.0, 1.0)
			_swing_t = t
			var g := _swing_geometry(t)
			_sweep(_swing_prev_base, _swing_prev_tip, g[0], g[1])
			_swing_prev_base = g[0]
			_swing_prev_tip = g[1]
			if attack_timer <= 0.0:
				attack_phase = AttackPhase.RECOVER
				attack_timer = recover_time
		AttackPhase.RECOVER:
			if attack_timer <= recover_time - 0.12:
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
	var reach := reach_mounted if mounted else reach_foot
	var base := at + Vector3(0, shoulder_h, 0) + right * 0.25 * _swing_dir
	# 前後段慢、中段快（ease），比等速轉動更有「甩出去」的感覺
	var e := t * t * (3.0 - 2.0 * t)
	var ang := lerpf(deg_to_rad(80.0), deg_to_rad(-80.0), e) * _swing_dir
	var drop := lerpf(0.2, -1.0 if mounted else -0.5, e)
	var tip := base + (f * cos(ang) + right * sin(ang)) * reach + Vector3(0, drop, 0)
	var hilt := base + (tip - base) * 0.25
	return [hilt, tip]


func _sweep(prev_base: Vector3, prev_tip: Vector3, base: Vector3, tip: Vector3) -> void:
	debug_sweeps.append([prev_tip, tip, base, 0.6])
	if battle == null:
		return
	var hits: PackedInt32Array = battle.call("sweep_query", prev_base, prev_tip, base, tip, blade_radius, team, _swing_hit)
	if hits.is_empty():
		return
	var my_vel := move_velocity()
	var total := 0.0
	for idx in hits:
		_swing_hit[idx] = true
		var spos: Vector3 = battle.call("soldier_position", idx)
		var svel: Vector3 = battle.call("soldier_velocity", idx)
		var to_target := spos - global_position
		to_target.y = 0
		to_target = to_target.normalized()
		# 相對速度在「朝向目標」方向的分量：迎面衝鋒 > 靜止 > 同向追擊
		var closing := maxf(0.0, (my_vel - svel).dot(to_target))
		var dmg := base_damage + closing * speed_damage
		var knock := to_target * (0.6 + closing * 0.12)
		var killed: bool = battle.call("apply_damage", idx, dmg, knock)
		if killed:
			total_kills += 1
		total += dmg
		var point := spos + Vector3(0, 1.2, 0) - to_target * 0.3
		hit_detail.emit(point, dmg, killed, closing)
	hit_landed.emit(hits.size(), total)


func _update_debug_sweeps(delta: float) -> void:
	for i in range(debug_sweeps.size() - 1, -1, -1):
		debug_sweeps[i][3] -= delta
		if debug_sweeps[i][3] <= 0.0:
			debug_sweeps.remove_at(i)


# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var show_foot := not is_seated()
	visual.visible = show_foot
	if not show_foot:
		return
	var row := PlaceholderArt.ROW_IDLE
	if dead:
		row = PlaceholderArt.ROW_DEAD
	elif attack_phase == AttackPhase.SWING or attack_phase == AttackPhase.RECOVER:
		row = PlaceholderArt.ROW_ATTACK
	elif Vector2(velocity.x, velocity.z).length() > 0.3:
		row = PlaceholderArt.ROW_WALK if int(_walk_phase / 0.6) % 2 == 0 else PlaceholderArt.ROW_IDLE
	visual.update_visual(visual_position(), facing, cam, row)
