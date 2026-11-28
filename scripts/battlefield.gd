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
var battle: BattleManager
var siege_map: SiegeMap = null          # 攻城戰時才有

## 每方士兵人數（總人數 = 2 倍）
@export var soldiers_per_team := 50

## 壓力測試模式：不建立玩家輸入，相機自動繞場
var stress_mode := false
## 這場的戰鬥設定（GameConfig.setup）；攻城戰、壓力測試、展示腳本沿用舊的固定佈陣，為 null
var setup: BattleSetup = null
## 觀戰：設定裡沒有玩家（玩家節點存在但隱藏、不參戰）
var spectator := false
var menus: BattleMenus


func _ready() -> void:
	if not (stress_mode or GameConfig.siege_mode or GameConfig.legacy_layout):
		setup = GameConfig.setup
		GameConfig.battle_seed = setup.seed_value
		GameConfig.terrain_type = setup.terrain_type
		spectator = setup.player_side < 0
	seed(GameConfig.battle_seed)
	_build_environment()
	terrain = BattleTerrain.new()
	terrain.name = "Terrain"
	terrain.seed_value = GameConfig.battle_seed
	terrain.terrain_type = GameConfig.terrain_type
	if setup:
		terrain.size_m = setup.resolved_map_size()
	if GameConfig.siege_mode:
		terrain.siege_layout = true
		terrain.terrain_type = BattleTerrain.Type.PLAINS
		if GameConfig.siege_side < 0:
			GameConfig.siege_side = 0
			_show_side_picker()
	add_child(terrain)
	terrain.build()
	_apply_terrain_environment()
	if GameConfig.siege_mode:
		siege_map = SiegeMap.new()
		siege_map.name = "Siege"
		add_child(siege_map)
		siege_map.build(terrain)

	cam_rig = OrbitFollowCamera.new()
	cam_rig.name = "CameraRig"
	cam_rig.terrain = terrain
	add_child(cam_rig)

	if siege_map and GameConfig.siege_side == 1:
		_spawn_player_and_horse(Vector3(22, 0, -9))
	elif siege_map:
		_spawn_player_and_horse(Vector3(-50, 0, 6))
	else:
		_spawn_player_and_horse(Vector3(-30, 0, 0))
	if siege_map:
		_place_player_for_siege()

	battle = BattleManager.new()
	battle.name = "BattleManager"
	battle.auto_charge_both = stress_mode
	add_child(battle)
	if setup and not spectator:
		player.configure(setup.player_side, setup.player_weapons)
		player.respawn_enabled = setup.player_respawn
	battle.setup(terrain, null if (stress_mode or spectator) else player)
	battle.siege = siege_map
	battle.set_renderer(make_renderer())
	_spawn_soldiers()
	if setup and not spectator:
		_place_player_for_setup()
	battle.battle_finished.connect(_on_battle_finished)
	battle.siege_event.connect(func(t: String): if hud: hud.toast(t, 3.0))
	if not stress_mode and not spectator:
		horse.battle = battle
		player.battle = battle
		player.hit_landed.connect(_on_hit_landed)
		player.arrow_hit_confirmed.connect(func(p: Vector3, d: float, k: bool): hud.on_arrow_hit(p, d, k))
		player.weapon_changed.connect(func(_n: String): hud.toast(WeaponDefs.summary(player.wdef), 3.0))
		player.died.connect(_on_player_died)

	if not stress_mode:
		var fx := CombatFX.new()
		fx.name = "CombatFX"
		add_child(fx)
		fx.setup(player, cam_rig, battle)

	debug_draw = DebugDraw.new()
	debug_draw.name = "DebugDraw"
	debug_draw.player = player
	debug_draw.battle = battle
	add_child(debug_draw)

	hud = BattleHUD.new()
	hud.name = "HUD"
	hud.player = null if spectator else player
	hud.battle = battle
	hud.visible = not stress_mode
	add_child(hud)

	menus = BattleMenus.new()
	menus.name = "Menus"
	menus.battle = battle
	menus.player = null if (stress_mode or spectator) else player
	menus.setup = setup
	add_child(menus)

	apply_postfx()
	if spectator:
		cam_rig.toggle_spectate(battle_center())
		hud.toast("觀戰模式：雙方 AI 對打（滑鼠／滾輪調整鏡頭，Esc 暫停）", 5.0)
	elif stress_mode:
		cam_rig.auto_orbit = true
		cam_rig.distance = 38.0
		cam_rig.pitch_deg = 40.0
	else:
		if _picker == null:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if siege_map:
			if GameConfig.siege_side == 0:
				hud.toast("攻城戰：你是攻方（400 人）。三道雲梯已架好，攻城槌往城門推進（F11 換守方）", 5.0)
			else:
				hud.toast("攻城戰：你是守方（200 人）。守住城牆與城門 10 分鐘（F11 換攻方）", 5.0)
		else:
			hud.toast("場地：%s　%s（%d m）　Esc 暫停／回選單" % [terrain.type_name(), BattleTerrain.TYPE_HINTS[terrain.terrain_type], terrain.size_m], 4.0)


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
	horse.set_owner_player(player)
	player.facing = Vector3(1, 0, 0)
	cam_rig.target = player
	cam_rig.yaw = -PI * 0.5      # 從玩家背後看向戰場（+X 方向）
	if stress_mode or spectator:
		# 壓力測試／觀戰只有士兵：玩家與馬隱藏且不更新
		for n: Node3D in [player, horse]:
			n.visible = false
			n.process_mode = Node.PROCESS_MODE_DISABLED


func _unhandled_input(event: InputEvent) -> void:
	if menus and menus.is_open():
		if event.is_action_pressed("release_mouse"):
			if menus._kind == "pause":
				menus.close()
			else:
				menus.close()
		return
	if event.is_action_pressed("release_mouse"):
		if stress_mode:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
		else:
			menus.toggle_pause()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("cycle_directions"):
		GameConfig.cycle_direction_mode()
	elif event.is_action_pressed("toggle_debug"):
		GameConfig.debug_draw = not GameConfig.debug_draw
	elif event.is_action_pressed("next_terrain"):
		GameConfig.siege_mode = false
		GameConfig.next_terrain()
		get_tree().reload_current_scene()
	elif event.is_action_pressed("random_terrain"):
		GameConfig.siege_mode = false
		GameConfig.random_terrain()
		get_tree().reload_current_scene()
	elif event.is_action_pressed("toggle_siege"):
		GameConfig.siege_mode = not GameConfig.siege_mode
		GameConfig.siege_side = -1
		get_tree().reload_current_scene()
	elif event.is_action_pressed("swap_siege_side") and siege_map:
		GameConfig.siege_side = 1 - GameConfig.siege_side
		get_tree().reload_current_scene()
	elif event.is_action_pressed("spectate") and not spectator:
		var on := cam_rig.toggle_spectate(battle_center())
		hud.toast("觀戰鏡頭（滾輪調整距離，V 返回）" if on else "回到玩家相機")
	elif event.is_action_pressed("toggle_backend"):
		GameConfig.soldier_backend = 1 - GameConfig.soldier_backend
		restart_battle()
		hud.toast("士兵畫面後端：" + GameConfig.backend_name())
	elif event.is_action_pressed("restart_battle"):
		if setup or siege_map:
			get_tree().reload_current_scene()
		else:
			restart_battle()
			hud.toast("重開戰局")
	elif event.is_action_pressed("order_charge"):
		_order(BattleManager.Order.CHARGE, "全軍衝鋒！")
	elif event.is_action_pressed("order_hold"):
		_order(BattleManager.Order.HOLD, "在此集結！")
	elif event.is_action_pressed("order_follow"):
		_order(BattleManager.Order.FOLLOW, "跟隨我！")
	elif event.is_action_pressed("toggle_billboard"):
		GameConfig.full_billboard = not GameConfig.full_billboard
		hud.toast("Billboard：" + ("完全面向相機" if GameConfig.full_billboard else "Y 軸直立"))
	elif event.is_action_pressed("toggle_art"):
		GameConfig.toggle_art_mode()
		restart_battle()
		hud.toast("角色美術：" + GameConfig.art_mode_name())
	elif event.is_action_pressed("toggle_postfx"):
		GameConfig.postfx_enabled = not GameConfig.postfx_enabled
		apply_postfx()


static func make_renderer() -> SoldierRenderer:
	if GameConfig.soldier_backend == GameConfig.SoldierBackend.MULTIMESH:
		return MultiMeshSoldierRenderer.new()
	return SpriteSoldierRenderer.new()


func restart_battle() -> void:
	seed(GameConfig.battle_seed)
	battle.rng.seed = GameConfig.battle_seed
	battle.set_renderer(make_renderer())
	_spawn_soldiers()
	if player:
		player.hp = player.max_hp
		if siege_map:
			_place_player_for_siege()


func _spawn_soldiers() -> void:
	if siege_map:
		# 玩家永遠是陣營 0：當攻方時陣營 0 = 攻方（400 人），當守方時陣營 0 = 守方（200 人）
		battle.spawn_siege(0 if GameConfig.siege_side == 0 else 1, 400, 200)
	elif setup:
		battle.spawn_from_setup(setup)
	else:
		battle.spawn_armies(soldiers_per_team)


## 依設定放玩家：己方大軍後方中央、面向敵軍；騎馬開局直接在馬上
func _place_player_for_setup() -> void:
	var side := setup.player_side
	var x: float = battle.rear_x[side]
	var p := Vector3(x, terrain.get_height(x, 0.0) + 0.1, 0.0)
	var fwd := Vector3(1, 0, 0) if side == 0 else Vector3(-1, 0, 0)
	player.spawn_point = p
	player.global_position = p
	player.velocity = Vector3.ZERO
	player.facing = fwd
	var hp := p + Vector3(0, 0, 2.5)
	horse.teleport(Vector3(hp.x, terrain.get_height(hp.x, hp.z) + 0.1, hp.z), atan2(fwd.x, fwd.z))
	cam_rig.yaw = -PI * 0.5 if side == 0 else PI * 0.5
	if setup.player_mounted:
		player.mount_instant()


## 攻城戰的玩家位置：攻方在大軍後方；守方站在第二道雲梯旁的牆頂，馬留在城內
func _place_player_for_siege() -> void:
	# 雲梯是 62° 的斜板，放寬玩家可走的坡度
	player.floor_max_angle = deg_to_rad(64.0)
	if GameConfig.siege_side == 1:
		var p := Vector3(SiegeMap.WALK_X0 + 1.3, siege_map.wall_top() + 0.1, -9.0)
		player.spawn_point = p
		player.global_position = p
		player.facing = Vector3(-1, 0, 0)
		cam_rig.yaw = PI * 0.5           # 從城內看向城外（-X 方向）
	else:
		player.facing = Vector3(1, 0, 0)
		cam_rig.yaw = -PI * 0.5
	player.velocity = Vector3.ZERO


var _picker: CanvasLayer = null


## 攻城戰選邊畫面：暫停遊戲，選完重新載入
func _show_side_picker() -> void:
	_picker = CanvasLayer.new()
	_picker.layer = 20
	_picker.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_picker)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_picker.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(520, 0)
	box.position = Vector2(-260, -130)
	box.add_theme_constant_override("separation", 16)
	_picker.add_child(box)
	var title := Label.new()
	title.text = "攻城戰：選擇陣營"
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	for side in [0, 1]:
		var b := Button.new()
		b.text = "攻城方（400 人：雲梯 ×3、攻城槌）" if side == 0 else "守城方（200 人：城牆、城門，撐 10 分鐘）"
		b.add_theme_font_size_override("font_size", 22)
		b.custom_minimum_size = Vector2(520, 56)
		b.pressed.connect(func():
			GameConfig.siege_side = side
			get_tree().paused = false
			get_tree().reload_current_scene())
		box.add_child(b)
	var hint := Label.new()
	hint.text = "遊戲中按 F11 換邊、F10 回到野戰"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true


func _order(order: int, text: String) -> void:
	if stress_mode or player == null:
		return
	# 命令只是寫入佇列；集結點 = 玩家目前位置，面向玩家朝向
	battle.issue_order(player.team, order, player.global_position, player.facing)
	hud.toast(text)


func _on_hit_landed(hits: int, dmg: float) -> void:
	hud.toast("命中 %d 人　傷害 %d" % [hits, dmg], 0.8)


func _on_battle_finished(winner: int) -> void:
	if hud:
		hud.toast(battle.winner_text(winner) + "！", 3.0)
	# 批次測試用：--print-results 在分出勝負時把結算文字印到主控台後結束
	if "--print-results" in OS.get_cmdline_user_args():
		print(menus.results_text())
		get_tree().quit()
		return
	# 野戰：稍等一下讓最後一擊演完，再跳結算畫面（攻城戰、壓力測試照舊只顯示提示）
	if setup and menus:
		get_tree().create_timer(2.0).timeout.connect(func():
			if is_instance_valid(menus):
				menus.show_results()
				_maybe_results_shot())


## 開發用：--results-shot=路徑.png 在結算畫面出現後截圖並結束
func _maybe_results_shot() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--results-shot="):
			for k in 10:
				await get_tree().process_frame
			get_viewport().get_texture().get_image().save_png(a.get_slice("=", 1))
			get_tree().quit()


## 玩家陣亡且不重生：改成觀戰鏡頭，看到分出勝負
func _on_player_died() -> void:
	if player.respawn_enabled or cam_rig.spectating:
		return
	cam_rig.toggle_spectate(battle_center())
	hud.toast("你陣亡了，改為觀戰（Esc 暫停）", 4.0)


func apply_postfx() -> void:
	var on := GameConfig.postfx_enabled
	var env := world_env.environment
	env.glow_enabled = on
	env.ssao_enabled = on
	env.fog_enabled = on
	cam_rig.apply_postfx(on)


func _build_environment() -> void:
	# 自訂天空（漸層＋太陽＋飄動的像素風雲），鏡頭往上看時才不會一片空
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky_clouds.gdshader")
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


## 依場地套用天空、霧與陽光
func _apply_terrain_environment() -> void:
	var e := terrain.environment_settings()
	var env := world_env.environment
	var sky_mat := env.sky.sky_material as ShaderMaterial
	sky_mat.set_shader_parameter("sky_top", e["sky_top"])
	sky_mat.set_shader_parameter("sky_horizon", e["horizon"])
	sky_mat.set_shader_parameter("ground_color", (e["horizon"] as Color).darkened(0.2))
	sky_mat.set_shader_parameter("cloud_cover", 0.6 if terrain.terrain_type == BattleTerrain.Type.SNOW else 0.45)
	env.fog_light_color = e["fog"]
	env.fog_density = e["fog_density"]
	env.ambient_light_energy = e["ambient"]
	sun.light_color = e["sun"]
	sun.light_energy = e["sun_energy"]
	# 太陽壓低一點，起伏的明暗比較明顯
	sun.rotation_degrees = Vector3(-38, -35, 0)


## 存活士兵的平均位置（觀戰鏡頭的繞場中心）；沒有士兵時用地圖中央
func battle_center() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for i in battle.count:
		if battle.state[i] != BattleManager.State.DEAD:
			sum += battle.pos[i]
			n += 1
	if n == 0:
		return Vector3(0, terrain.get_height(0, 0), 0)
	return sum / n


var _center_timer := 0.0


func _process(delta: float) -> void:
	# 遮擋淡化：玩家（或騎乘中的馬上騎士）被樹、岩石擋住時，擋住的部分變成點陣半透明
	if terrain and player and not stress_mode:
		var vp: Vector3 = horse.visual_position() if player.mounted else player.visual_position()
		terrain.set_occlusion_target(vp + Vector3(0, 1.9 if player.mounted else 1.0, 0))
	# 觀戰中每半秒更新一次繞場中心，相機會平滑地跟著戰線移動
	if cam_rig and cam_rig.spectating and not stress_mode:
		_center_timer -= delta
		if _center_timer <= 0.0:
			_center_timer = 0.5
			cam_rig.auto_orbit_center = battle_center()
