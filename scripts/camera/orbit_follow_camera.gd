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

var camera: Camera3D
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
	_focus = _focus.lerp(goal, 1.0 - exp(-follow_smooth * delta))
	var look_at_point := _focus + Vector3(0, 1.4, 0)
	var pitch := deg_to_rad(pitch_deg)
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	var cam_pos := look_at_point + offset
	# 不鑽進地形：相機至少高於地面 1 公尺
	if terrain:
		var ground := terrain.get_height(cam_pos.x, cam_pos.z)
		cam_pos.y = maxf(cam_pos.y, ground + 1.0)
	camera.global_position = cam_pos
	camera.look_at(look_at_point, Vector3.UP)
	# 景深焦點跟著距離走（移軸感：焦點外的前景與遠景模糊）
	_attrs.dof_blur_far_distance = distance + 12.0
	_attrs.dof_blur_far_transition = distance * 1.5
	_attrs.dof_blur_near_distance = maxf(distance * 0.45, 1.0)
	_attrs.dof_blur_near_transition = distance * 0.3


## 相機的「水平前方」，給角色做相機相對移動。
func flat_forward() -> Vector3:
	return Vector3(-sin(yaw), 0, -cos(yaw))


func flat_right() -> Vector3:
	return Vector3(cos(yaw), 0, -sin(yaw))
