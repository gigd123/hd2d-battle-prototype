class_name Horse
extends CharacterBody3D
## 馬：CharacterBody3D＋自訂加速、轉向率與慣性（研究報告建議，不用 RigidBody3D）。
##
## 操作手感的關鍵數值都 export 出來，方便在編輯器裡邊玩邊調：
## - 馬不能平移，只能「轉向＋前進」；速度越快轉向越慢（轉向半徑變大）
## - 急轉彎（目標方向與目前朝向差太多）會自動減速
## - 撞牆會掉速；穿過人群會依人數減速（由戰場管理器提供「周圍士兵」查詢）

@export var trot_speed := 6.5
@export var gallop_speed := 13.0
@export var accel := 5.0
@export var brake := 9.0
@export var turn_rate_slow := 2.8      # 低速時每秒可轉的弧度
@export var turn_rate_fast := 1.1      # 全速時每秒可轉的弧度
@export var sharp_turn_angle := 1.6    # 超過這個角度差就減速（弧度）
@export var crowd_slowdown := 0.12     # 每個擋路士兵造成的減速比例
@export var gravity := 25.0

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
		visual.setup_attach_baked(rider_set, ["body", "sword"], "saddle", "seat", CLOTH_TINT)
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


func teleport(p: Vector3, new_heading: float) -> void:
	global_position = p
	heading = new_heading
	speed = 0.0
	velocity = Vector3.ZERO
	_prev_pos = p
	_cur_pos = p


func _physics_process(delta: float) -> void:
	var target_speed := 0.0
	if rider != null and _desired.length() > 0.1:
		var desired_heading := atan2(_desired.x, _desired.z)
		var diff := wrapf(desired_heading - heading, -PI, PI)
		var t := clampf(speed / gallop_speed, 0.0, 1.0)
		var tr := lerpf(turn_rate_slow, turn_rate_fast, t)
		heading = wrapf(heading + clampf(diff, -tr * delta, tr * delta), -PI, PI)
		target_speed = (gallop_speed if _sprint else trot_speed) * minf(_desired.length(), 1.0)
		if absf(diff) > sharp_turn_angle:
			target_speed = minf(target_speed, trot_speed * 0.4)
	var rate := accel if target_speed > speed else brake
	speed = move_toward(speed, target_speed, rate * delta)

	# 人群阻擋：由戰場管理器回報前方有幾個士兵
	if battle != null and speed > 0.5:
		var blockers: int = battle.call("count_blockers", global_position + forward() * 1.2, 1.3)
		if blockers > 0:
			speed *= maxf(0.0, 1.0 - crowd_slowdown * blockers * delta * 10.0)

	var f := forward()
	velocity.x = f.x * speed
	velocity.z = f.z * speed
	if is_on_floor():
		velocity.y = -1.0
	else:
		velocity.y -= gravity * delta
	rotation.y = heading
	move_and_slide()
	if is_on_wall():
		var real := get_real_velocity()
		var real_fwd := maxf(0.0, real.x * f.x + real.z * f.z)
		speed = minf(speed, real_fwd + accel * delta)
	if terrain:
		global_position = terrain.clamp_to_map(global_position, 3.0)
	_stride += speed * delta
	_prev_pos = _cur_pos
	_cur_pos = global_position


## 物理步之間的內插位置（畫面用，避免高刷新率下抖動）
func visual_position() -> Vector3:
	return _prev_pos.lerp(_cur_pos, Engine.get_physics_interpolation_fraction())


func anim_row() -> int:
	if _baked:
		if speed < 0.6:
			return _baked.row_at_time("idle", Time.get_ticks_msec() / 1000.0)
		if speed < (trot_speed + gallop_speed) * 0.5:
			return _baked.row_at_progress("trot", fmod(_stride / 2.2, 1.0))
		return _baked.row_at_progress("gallop", fmod(_stride / 3.6, 1.0))
	if speed < 0.6:
		return 0
	return int(_stride / 1.4) % 2


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var rider_row := 0
	if rider != null and rider.has_method("rider_anim_row"):
		rider_row = rider.call("rider_anim_row")
	visual.set_attach_visible(rider != null and rider.call("is_seated"))
	visual.update_visual(visual_position(), forward(), cam, anim_row(), rider_row)
