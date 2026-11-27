class_name Horse
extends CharacterBody3D
## 馬：CharacterBody3D＋自訂加速、轉向率與慣性（研究報告建議，不用 RigidBody3D）。
##
## 操作手感的關鍵數值都 export 出來，方便在編輯器裡邊玩邊調：
## - 馬不能平移，只能「轉向＋前進」；速度越快轉向越慢（轉向半徑變大）
## - 急轉彎（目標方向與目前朝向差太多）會自動減速
## - 撞牆會掉速；穿過人群會依人數減速（由戰場管理器提供「周圍士兵」查詢）

@export var trot_speed := 7.5
@export var gallop_speed := 15.0
@export var accel := 5.0
@export var brake := 9.0
@export var turn_rate_slow := 2.8      # 低速時每秒可轉的弧度
@export var turn_rate_fast := 1.1      # 全速時每秒可轉的弧度
@export var sharp_turn_angle := 1.6    # 超過這個角度差就減速（弧度）
@export var crowd_slowdown := 0.12     # 每個擋路士兵造成的減速比例
@export var gravity := 25.0
# 「跟步行一樣」的操作（騎手用 set_drive_look）：馬頭轉向滑鼠方向，W 前進、S 後退
@export var back_speed := 2.6          # 倒退（勒馬後退）的最高速度
@export var side_speed := 2.0          # 低速時 A/D 的側步速度（馬只能慢慢橫移）
@export var side_max_speed := 3.0      # 前進速度超過這個值就不能側步，A/D 改成讓馬頭偏一點
@export var steer_bias_deg := 35.0     # 前進中按 A/D，馬頭相對滑鼠方向偏幾度

var heading := 0.0                     # 朝向（yaw），forward = (sin, 0, cos)
var speed := 0.0
var rider: Node3D = null
var terrain: BattleTerrain
var battle: Node = null                # BattleManager（階段 2 起）
var visual: LayeredActorVisual
const CLOTH_TINT := Color(0.25, 0.45, 0.85)
var _baked: BakedSpriteSet = null

var _desired := Vector3.ZERO
var _sprint := false
var _look_mode := false
var _look := Vector3.ZERO              # 滑鼠（相機）水平前方
var _input := Vector2.ZERO             # x = 右，y = 前
var side := 0.0                        # 目前側步速度（正 = 往右）
var _stride := 0.0
var _prev_pos := Vector3.ZERO
var _cur_pos := Vector3.ZERO


func _ready() -> void:
	floor_max_angle = deg_to_rad(42.0)
	floor_snap_length = 0.6
	var shape := CapsuleShape3D.new()
	shape.radius = 0.55
	shape.height = 2.6
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = shape
	cs.rotation_degrees = Vector3(90, 0, 0)   # 橫躺的膠囊，沿馬身前後方向
	cs.position = Vector3(0, 0.95, 0)          # 原點在蹄底
	add_child(cs)
	_build_visual()
	GameConfig.art_mode_changed.connect(_build_visual)
	_prev_pos = global_position
	_cur_pos = global_position


## 建立（或重建）畫面：預渲染的馬＋騎士（身體、劍兩層），騎士的 seat 錨點對齊馬的 saddle 錨點
func _build_visual() -> void:
	if visual:
		visual.queue_free()
	visual = LayeredActorVisual.new()
	visual.name = "HorseVisual"
	_baked = GameConfig.baked_set("horse")
	var rider_set := GameConfig.baked_set("knight")
	if _baked and rider_set:
		visual.setup_main_baked(_baked, ["horse"], CLOTH_TINT, 2.4)
		var layers := ["body", "sword"]
		if rider_set.layers.has("spear"):
			layers.append("spear")
		visual.setup_attach_baked(rider_set, layers, "saddle", "seat", CLOTH_TINT)
		visual.set_layer_hidden("spear", true)
		if rider != null and rider.has_method("_apply_weapon_layers"):
			rider.call("_apply_weapon_layers")
	else:
		_baked = null
		visual.setup_main(PlaceholderArt.horse_atlas(), PlaceholderArt.HORSE_FRAME, PlaceholderArt.HORSE_ROWS, PlaceholderArt.horse_anchors(), 2.4)
		visual.setup_attach(PlaceholderArt.rider_atlas(), PlaceholderArt.RIDER_FRAME, PlaceholderArt.RIDER_ROWS, PlaceholderArt.rider_anchors(), "saddle", "seat")
	add_child(visual)


func forward() -> Vector3:
	return Vector3(sin(heading), 0.0, cos(heading))


## 由騎手每個物理步呼叫：desired = 希望前進的世界方向（長度 0..1），零向量代表停下。
func set_drive(desired: Vector3, sprint: bool) -> void:
	_desired = desired
	_sprint = sprint
	_look_mode = false


## 跟步行一樣的操作：look = 滑鼠方向（相機水平前方），input = WASD（x 右、y 前）。
## 馬不能像人一樣自由平移，所以：
## - 馬頭會以有限的轉向速度轉向滑鼠方向（站著不動時原地轉）
## - W 前進、S 慢慢倒退
## - A/D：低速時慢慢側步；前進中改成讓馬頭往那邊偏，走出斜線
func set_drive_look(look: Vector3, input: Vector2, sprint: bool) -> void:
	_look = look
	_input = input
	_sprint = sprint
	_look_mode = true


func right() -> Vector3:
	var f := forward()
	return Vector3(-f.z, 0.0, f.x)


func teleport(p: Vector3, new_heading: float) -> void:
	global_position = p
	heading = new_heading
	speed = 0.0
	velocity = Vector3.ZERO
	_prev_pos = p
	_cur_pos = p


func _physics_process(delta: float) -> void:
	var target_speed := 0.0
	var target_side := 0.0
	if rider != null and _look_mode:
		var d := _look
		if _input.y > 0.1:
			d = _look.rotated(Vector3.UP, -_input.x * deg_to_rad(steer_bias_deg))
		var diff := wrapf(atan2(d.x, d.z) - heading, -PI, PI)
		var t := clampf(absf(speed) / gallop_speed, 0.0, 1.0)
		var tr := lerpf(turn_rate_slow, turn_rate_fast, t)
		heading = wrapf(heading + clampf(diff, -tr * delta, tr * delta), -PI, PI)
		if _input.y > 0.1:
			target_speed = (gallop_speed if _sprint else trot_speed) * minf(_input.y, 1.0)
			if absf(diff) > sharp_turn_angle:
				target_speed = minf(target_speed, trot_speed * 0.4)
		elif _input.y < -0.1:
			target_speed = -back_speed * minf(-_input.y, 1.0)
		if absf(_input.x) > 0.1 and _input.y <= 0.1 and absf(speed) < side_max_speed:
			target_side = side_speed * signf(_input.x)
		if terrain and target_speed > 0.0:
			var hf0 := forward()
			target_speed *= terrain.move_factor(global_position.x, global_position.z, hf0.x, hf0.z)
	elif rider != null and _desired.length() > 0.1:
		var desired_heading := atan2(_desired.x, _desired.z)
		var diff := wrapf(desired_heading - heading, -PI, PI)
		var t := clampf(speed / gallop_speed, 0.0, 1.0)
		var tr := lerpf(turn_rate_slow, turn_rate_fast, t)
		heading = wrapf(heading + clampf(diff, -tr * delta, tr * delta), -PI, PI)
		target_speed = (gallop_speed if _sprint else trot_speed) * minf(_desired.length(), 1.0)
		if absf(diff) > sharp_turn_angle:
			target_speed = minf(target_speed, trot_speed * 0.4)
		# 地形：上坡變慢、下坡稍快，涉水與積雪減速（與士兵同一條規則）
		if terrain:
			var hf := forward()
			target_speed *= terrain.move_factor(global_position.x, global_position.z, hf.x, hf.z)
	var rate := accel if absf(target_speed) > absf(speed) and target_speed * speed >= 0.0 else brake
	speed = move_toward(speed, target_speed, rate * delta)
	side = move_toward(side, target_side, (accel if absf(target_side) > absf(side) else brake) * delta)

	# 人群阻擋：由戰場管理器回報前方有幾個士兵
	if battle != null and speed > 0.5:
		var blockers: int = battle.call("count_blockers", global_position + forward() * 1.2, 1.3)
		if blockers > 0:
			speed *= maxf(0.0, 1.0 - crowd_slowdown * blockers * delta * 10.0)

	var f := forward()
	var r := right()
	velocity.x = f.x * speed + r.x * side
	velocity.z = f.z * speed + r.z * side
	if is_on_floor():
		velocity.y = -1.0
	else:
		velocity.y -= gravity * delta
	rotation.y = heading
	move_and_slide()
	if is_on_wall():
		var real := get_real_velocity()
		var real_fwd := real.x * f.x + real.z * f.z
		if speed > 0.0:
			speed = minf(speed, maxf(0.0, real_fwd) + accel * delta)
		elif speed < 0.0:
			speed = maxf(speed, minf(0.0, real_fwd) - accel * delta)
	if terrain:
		global_position = terrain.clamp_to_map(global_position, 3.0)
	_stride += (absf(speed) + absf(side)) * delta
	_prev_pos = _cur_pos
	_cur_pos = global_position


## 物理步之間的內插位置（畫面用，避免高刷新率下抖動）
func visual_position() -> Vector3:
	var p := _prev_pos.lerp(_cur_pos, Engine.get_physics_interpolation_fraction())
	# 碰撞膠囊是橫躺的，物理原點會比地面低一點；畫面改用地形高度：前後蹄位置取平均與中心取較高者，
	# 斜坡上馬腳不會陷進地面
	if terrain:
		var f := forward()
		var hc := terrain.get_height(p.x, p.z)
		var hf := terrain.get_height(p.x + f.x * 0.9, p.z + f.z * 0.9)
		var hb := terrain.get_height(p.x - f.x * 0.9, p.z - f.z * 0.9)
		var ground := maxf(hc, (hf + hb) * 0.5) + 0.04
		if p.y < ground + 0.6:          # 在地面附近（不是跳起或掉落中）才貼地
			p.y = ground
	return p


func anim_row() -> int:
	if _baked:
		var moving := absf(speed) + absf(side)
		if moving < 0.6:
			return _baked.row_at_time("idle", Time.get_ticks_msec() / 1000.0)
		if speed < 0.6:
			# 倒退或側步：小跑動畫倒著／慢慢播
			return _baked.row_at_progress("trot", fmod(-_stride / 1.6 if speed < 0.0 else _stride / 1.6, 1.0))
		if speed < (trot_speed + gallop_speed) * 0.5:
			return _baked.row_at_progress("trot", fmod(_stride / 2.8, 1.0))
		return _baked.row_at_progress("gallop", fmod(_stride / 4.4, 1.0))
	if absf(speed) + absf(side) < 0.6:
		return 0
	return int(_stride / 1.4) % 2


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var rider_row := 0
	if rider != null and rider.has_method("rider_anim_row"):
		rider_row = rider.call("rider_anim_row")
	visual.set_attach_visible(rider != null and rider.call("is_seated"))
	visual.update_visual(visual_position(), forward(), cam, anim_row(), rider_row)
