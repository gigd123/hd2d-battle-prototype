class_name Battlefield
extends Node3D
## 戰場主場景：組裝地形、光影、相機。
## 所有原型功能都在同一個戰場內疊加測試（研究報告建議），而不是做獨立展示。

var terrain: BattleTerrain
var cam_rig: OrbitFollowCamera
var world_env: WorldEnvironment
var sun: DirectionalLight3D
var horse: Horse
var player: PlayerController
var hud: BattleHUD
var debug_draw: DebugDraw

## 壓力測試模式：不建立玩家輸入，相機自動繞場
var stress_mode := false


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

	_spawn_player_and_horse(Vector3(-30, 0, 0))

	debug_draw = DebugDraw.new()
	debug_draw.name = "DebugDraw"
	debug_draw.player = player
	add_child(debug_draw)

	hud = BattleHUD.new()
	hud.name = "HUD"
	hud.player = player
	add_child(hud)

	apply_postfx()
	if stress_mode:
		cam_rig.auto_orbit = true
		cam_rig.distance = 38.0
		cam_rig.pitch_deg = 40.0
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _spawn_player_and_horse(at: Vector3) -> void:
	# 馬先加入場景樹：同一物理步中馬先移動，騎手再對齊到馬
	horse = Horse.new()
	horse.name = "Horse"
	horse.terrain = terrain
	add_child(horse)
	var hp := at + Vector3(2.5, 0, 0)
	horse.teleport(Vector3(hp.x, terrain.get_height(hp.x, hp.z) + 0.1, hp.z), PI * 0.5)

	player = PlayerController.new()
	player.name = "Player"
	player.terrain = terrain
	player.horse = horse
	player.cam_rig = cam_rig
	player.spawn_point = Vector3(at.x, terrain.get_height(at.x, at.z) + 0.1, at.z)
	add_child(player)
	player.global_position = player.spawn_point
	player.facing = Vector3(1, 0, 0)
	cam_rig.target = player
	cam_rig.yaw = -PI * 0.5      # 從玩家背後看向戰場（+X 方向）
	if stress_mode:
		player.set_physics_process(false)


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
