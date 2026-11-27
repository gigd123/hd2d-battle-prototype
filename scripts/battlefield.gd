class_name Battlefield
extends Node3D
## 戰場主場景：組裝地形、光影、相機。
## 所有原型功能都在同一個戰場內疊加測試（研究報告建議），而不是做獨立展示。

var terrain: BattleTerrain
var cam_rig: OrbitFollowCamera
var world_env: WorldEnvironment
var sun: DirectionalLight3D

# 階段 0：一個佔位 Sprite 在斜坡上繞圈，檢查漂浮與方向切換
var _dummy: LayeredActorVisual
var _dummy_t := 0.0


func _ready() -> void:
	seed(GameConfig.battle_seed)
	_build_environment()
	terrain = BattleTerrain.new()
	terrain.name = "Terrain"
	terrain.seed_value = GameConfig.battle_seed
	add_child(terrain)
	terrain.build()

	cam_rig = OrbitFollowCamera.new()
	cam_rig.name = "CameraRig"
	cam_rig.terrain = terrain
	add_child(cam_rig)

	_dummy = LayeredActorVisual.new()
	_dummy.name = "Dummy"
	_dummy.setup_main(PlaceholderArt.human_atlas(), PlaceholderArt.HUMAN_FRAME, PlaceholderArt.HUMAN_ROWS)
	add_child(_dummy)
	var marker := Node3D.new()
	marker.name = "DummyFocus"
	add_child(marker)
	cam_rig.target = marker
	apply_postfx()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	_dummy_t += delta
	var r := 10.0
	var p := Vector3(cos(_dummy_t * 0.3) * r + 18.0, 0, sin(_dummy_t * 0.3) * r)
	p.y = terrain.get_height(p.x, p.z)
	var facing := Vector3(-sin(_dummy_t * 0.3), 0, cos(_dummy_t * 0.3))
	var row := PlaceholderArt.ROW_WALK if int(_dummy_t * 6.0) % 2 == 0 else PlaceholderArt.ROW_IDLE
	_dummy.update_visual(p, facing, cam_rig.camera, row)
	(get_node("DummyFocus") as Node3D).global_position = p


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("cycle_directions"):
		GameConfig.cycle_direction_mode()
	elif event.is_action_pressed("toggle_postfx"):
		GameConfig.postfx_enabled = not GameConfig.postfx_enabled
		apply_postfx()


func apply_postfx() -> void:
	var on := GameConfig.postfx_enabled
	var env := world_env.environment
	env.glow_enabled = on
	env.ssao_enabled = on
	env.fog_enabled = on
	cam_rig.apply_postfx(on)


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.55, 0.80)
	sky_mat.sky_horizon_color = Color(0.80, 0.78, 0.72)
	sky_mat.ground_horizon_color = Color(0.70, 0.66, 0.58)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.25
	env.glow_bloom = 0.02
	env.ssao_enabled = true
	env.fog_enabled = true
	env.fog_light_color = Color(0.78, 0.80, 0.86)
	env.fog_density = 0.002
	env.fog_sky_affect = 0.3
	world_env = WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	sun.rotation_degrees = Vector3(-50, -35, 0)
	add_child(sun)
