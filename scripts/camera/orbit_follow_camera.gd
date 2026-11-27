class_name OrbitFollowCamera
extends Node3D
## 可旋轉的第三人稱追隨相機（使用者暫定方向；保留調整空間）。
##
## - 滑鼠移動：繞目標水平旋轉（yaw）與上下俯仰（pitch，有限制）
## - 滾輪：拉近拉遠
## - 窄 FOV＋中高俯角，接近 HD-2D 的「微縮模型」視角；景深做出移軸效果
## - auto_orbit：壓力測試時自動繞場，讓每次測試的畫面負載接近
##
## 相機只讀取 target 的位置，不影響任何戰鬥邏輯。

@export var target: Node3D
@export var distance := 14.0
@export var min_distance := 5.0
@export var max_distance := 45.0
@export var pitch_deg := 35.0
@export var min_pitch_deg := 12.0
@export var max_pitch_deg := 70.0
@export var mouse_sensitivity := 0.0035
@export var follow_smooth := 10.0
@export var fov := 38.0

var yaw := 0.0
var terrain: BattleTerrain
var auto_orbit := false
var auto_orbit_center := Vector3.ZERO
var auto_orbit_speed := 0.12
## 觀戰鏡頭（V）：拉遠、壓低俯角、繞著戰場中心慢慢轉；再按一次恢復原本的相機
var spectating := false
var _saved := {}

var camera: Camera3D
## 鏡頭震動（純畫面效果）：add_shake() 疊加強度，隨時間衰減
var shake := 0.0
var _shake_t := 0.0
var _focus := Vector3.ZERO
var _attrs: CameraAttributesPractical


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = fov
	camera.far = 600.0
	_attrs = CameraAttributesPractical.new()
	camera.attributes = _attrs
	add_child(camera)
	camera.make_current()
	if target:
		_focus = target.global_position
	apply_postfx(GameConfig.postfx_enabled)


func apply_postfx(enabled: bool) -> void:
	_attrs.dof_blur_far_enabled = enabled
	_attrs.dof_blur_near_enabled = enabled
	_attrs.dof_blur_amount = 0.05


func _unhandled_input(event: InputEvent) -> void:
	if spectating:
		# 觀戰中仍可用滾輪調整距離
		if event.is_action_pressed("zoom_in"):
			distance = maxf(min_distance, distance * 0.9)
		elif event.is_action_pressed("zoom_out"):
			distance = minf(80.0, distance * 1.1)
		return
	if auto_orbit:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * mouse_sensitivity
		pitch_deg = clampf(pitch_deg + mm.relative.y * mouse_sensitivity * 57.3, min_pitch_deg, max_pitch_deg)
	elif event.is_action_pressed("zoom_in"):
		distance = maxf(min_distance, distance * 0.9)
	elif event.is_action_pressed("zoom_out"):
		distance = minf(max_distance, distance * 1.1)


func _process(delta: float) -> void:
	var goal := _focus
	if auto_orbit:
		yaw += auto_orbit_speed * delta
		goal = auto_orbit_center
	elif target:
		goal = target.call("visual_position") if target.has_method("visual_position") else target.global_position
	_focus = _focus.lerp(goal, 1.0 - exp(-(1.2 if spectating else follow_smooth) * delta))
	var look_at_point := _focus + Vector3(0, 1.4, 0)
	var pitch := deg_to_rad(pitch_deg)
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	var cam_pos := look_at_point + offset
	# 不鑽進地形：相機至少高於地面 1 公尺
	if terrain:
		var ground := terrain.get_height(cam_pos.x, cam_pos.z)
		cam_pos.y = maxf(cam_pos.y, ground + 1.0)
	# 震動用「未縮放」的時間衰減，命中停頓（time_scale 變小）期間仍會正常震完
	var real_dt := delta / maxf(Engine.time_scale, 0.001)
	var jitter := Vector3.ZERO
	if shake > 0.001:
		_shake_t += real_dt * 60.0
		var amp := shake * shake * 0.35
		jitter = Vector3(sin(_shake_t * 1.7), sin(_shake_t * 2.3 + 1.0), sin(_shake_t * 1.3 + 2.0)) * amp
		shake = maxf(0.0, shake - real_dt * 2.5)
	camera.global_position = cam_pos + jitter
	camera.look_at(look_at_point + jitter * 0.5, Vector3.UP)
	# 景深焦點跟著距離走（移軸感：焦點外的前景與遠景模糊）
	_attrs.dof_blur_far_distance = distance + 12.0
	_attrs.dof_blur_far_transition = distance * 1.5
	_attrs.dof_blur_near_distance = maxf(distance * 0.45, 1.0)
	_attrs.dof_blur_near_transition = distance * 0.3


## 切換觀戰鏡頭；回傳切換後是否在觀戰
func toggle_spectate(center: Vector3) -> bool:
	spectating = not spectating
	if spectating:
		_saved = {"yaw": yaw, "distance": distance, "pitch": pitch_deg, "auto": auto_orbit, "speed": auto_orbit_speed}
		auto_orbit = true
		auto_orbit_center = center
		auto_orbit_speed = 0.16
		distance = 46.0
		pitch_deg = 22.0
	else:
		yaw = _saved.get("yaw", yaw)
		distance = _saved.get("distance", distance)
		pitch_deg = _saved.get("pitch", pitch_deg)
		auto_orbit = _saved.get("auto", false)
		auto_orbit_speed = _saved.get("speed", auto_orbit_speed)
	return spectating


func add_shake(amount: float) -> void:
	shake = clampf(shake + amount, 0.0, 1.0)


## 相機的「水平前方」，給角色做相機相對移動。
func flat_forward() -> Vector3:
	return Vector3(-sin(yaw), 0, -cos(yaw))


func flat_right() -> Vector3:
	return Vector3(cos(yaw), 0, -sin(yaw))
