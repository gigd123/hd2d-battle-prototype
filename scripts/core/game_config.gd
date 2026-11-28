extends Node
## 全域原型設定（Autoload 名稱：GameConfig）。
##
## 這裡只放「尚未定案、之後可能改」的選項，讓戰鬥邏輯與畫面都從同一處讀取。
## 例如方向數：架構上限是 8 方向，可在執行期切換成 4 方向或「5 方向＋鏡像」比較。

signal direction_mode_changed
signal art_mode_changed

## 方向模式：
## - DIR_8：8 張方向圖（S, SE, E, NE, N, NW, W, SW）
## - DIR_8_MIRROR：只畫 5 張（S, N, 與西側 3 張），東側 3 張用西側水平翻轉
## - DIR_4：4 張方向圖（S, E, N, W）
enum DirectionMode { DIR_8, DIR_8_MIRROR, DIR_4 }

## 士兵畫面後端（視覺代理的兩種實作）
enum SoldierBackend { SPRITE3D, MULTIMESH }

## 角色美術來源：預渲染（tools/sprite_baker 烘焙出的 art/baked/*）或程式佔位圖
enum ArtMode { BAKED, PLACEHOLDER }

const MAX_DIRECTIONS := 8

var direction_mode: int = DirectionMode.DIR_8
var soldier_backend: int = SoldierBackend.SPRITE3D
## 預設用預渲染圖；找不到 art/baked/ 的檔案時各角色會自動退回佔位圖。F7 切換。
var art_mode: int = ArtMode.BAKED
## Billboard 方式：false = Y 軸（直立紙片，報告建議的起點）；true = 完全面向相機。
## 相機俯角大時，Y 軸 Billboard 在畫面邊緣會有透視傾斜；兩種都保留，F6 切換比較。
var full_billboard := false
## 相機接近正上方俯視時（OrbitFollowCamera 設定），Y 軸紙片會變成一條線，暫時自動改成完全面向相機
var auto_full_billboard := false
## 後製效果（景深、泛光、SSAO、霧）。壓力測試可關閉以比較。
var postfx_enabled := true
## 固定亂數種子：同一種子重跑，戰場生成與 AI 隨機值一致（便於比較）。
var battle_seed := 12345
## 除錯繪製（武器掃掠軌跡、小隊目標等）
var debug_draw := false
## 場地類型（BattleTerrain.Type）：F8 下一種、F9 隨機；啟動參數 --terrain=plains|hills|forest|river|snow|random
var terrain_type := 1
## 俯角補償（0 = 關，1 = 完全補償）：Y 軸 Billboard 是直立紙片，相機越往下看，畫面上就越扁。
## 依相機俯角把角色往上拉長，讓俯視時比例接近正常。完全面向相機模式本來就不會扁，不套用。
var pitch_compensation := 0.85
## 攻城戰：F10 切換野戰 ⇄ 攻城戰；siege_side：0 = 玩家當攻方（400 人）、1 = 守方（200 人）、-1 = 還沒選（開局先跳選邊畫面）
## 啟動參數 --siege=attack|defend 直接進入
var siege_mode := false
var siege_side := -1
## 野戰的戰鬥設定（初始選單填寫；直接開戰場時用預設值）。見 BattleSetup
var setup: BattleSetup
## 展示影片腳本（--scenario）沿用改版前的固定佈陣，鏡頭腳本才對得上
var legacy_layout := false
## 從初始選單進入戰場（結算畫面才有「回選單」可用）
var from_menu := false
const LAST_SETUP_PATH := "user://last_setup.json"


func _ready() -> void:
	_setup_input_map()
	_parse_terrain_arg()
	setup = BattleSetup.make_default()
	setup.terrain_type = terrain_type
	_parse_dev_args()
	_parse_setup_args()


## 戰鬥設定相關的啟動參數（方便雲端或批次測試，不必開選單）：
##   --setup=檔案.json   讀入整份設定
##   --per-side=N        雙方各 N 人（照預設比例）
##   --side=blue|red|spectate   玩家陣營
##   --mounted           玩家開局騎馬
func _parse_setup_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--setup="):
			var s := BattleSetup.load_json(a.get_slice("=", 1))
			if s:
				setup = s
				terrain_type = s.terrain_type
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--per-side="):
			var n := int(a.get_slice("=", 1))
			setup.apply_preset(0, n)
			setup.apply_preset(1, n)
		elif a.begins_with("--side="):
			var v := a.get_slice("=", 1)
			setup.player_side = 1 if v == "red" else (-1 if v == "spectate" else 0)
		elif a == "--mounted":
			setup.player_mounted = true
		elif a.begins_with("--map-size="):
			setup.map_size = int(a.get_slice("=", 1))
		elif a.begins_with("--terrain="):
			setup.terrain_type = terrain_type


func _parse_dev_args() -> void:
	var shot := ""
	var frames := 180
	var scenario := ""
	var shots := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screenshot="):
			shot = a.get_slice("=", 1)
		elif a.begins_with("--screenshot-frames="):
			frames = int(a.get_slice("=", 1))
		elif a.begins_with("--backend="):
			soldier_backend = SoldierBackend.MULTIMESH if a.get_slice("=", 1) == "multimesh" else SoldierBackend.SPRITE3D
		elif a == "--no-postfx":
			postfx_enabled = false
		elif a.begins_with("--scenario="):
			scenario = a.get_slice("=", 1)
		elif a.begins_with("--shots="):
			shots = a.get_slice("=", 1)
		elif a == "--full-billboard":
			full_billboard = true
		elif a == "--debug-draw":
			debug_draw = true
		elif a.begins_with("--siege="):
			siege_mode = true
			siege_side = 1 if a.get_slice("=", 1) == "defend" else 0
		elif a.begins_with("--art="):
			art_mode = ArtMode.PLACEHOLDER if a.get_slice("=", 1) == "placeholder" else ArtMode.BAKED
	if scenario != "":
		legacy_layout = true
		var r: Node = load("res://scripts/debug/scenario_runner.gd").new()
		if shots != "":
			r.set("shots_dir", shots)
		r.call("setup", scenario)
		add_child(r)
	if shot != "":
		var n: Node = load("res://scripts/debug/auto_screenshot.gd").new()
		n.set("path", shot)
		n.set("frames", frames)
		add_child(n)


func direction_count() -> int:
	return 4 if direction_mode == DirectionMode.DIR_4 else 8


func mirror_enabled() -> bool:
	return direction_mode == DirectionMode.DIR_8_MIRROR


func direction_mode_name() -> String:
	match direction_mode:
		DirectionMode.DIR_8:
			return "8 方向"
		DirectionMode.DIR_8_MIRROR:
			return "5 方向＋鏡像"
		_:
			return "4 方向"


func cycle_direction_mode() -> void:
	direction_mode = (direction_mode + 1) % 3
	direction_mode_changed.emit()


## 目前美術模式下的預渲染圖集；佔位圖模式或檔案不存在時回傳 null
func baked_set(set_name: String) -> BakedSpriteSet:
	if art_mode != ArtMode.BAKED:
		return null
	return BakedSpriteSet.get_set(set_name)


func toggle_art_mode() -> void:
	art_mode = ArtMode.PLACEHOLDER if art_mode == ArtMode.BAKED else ArtMode.BAKED
	art_mode_changed.emit()


func art_mode_name() -> String:
	return "預渲染 3D 像素圖" if art_mode == ArtMode.BAKED else "程式佔位圖"


## 目前相機下 Y 軸 Billboard 角色要拉高的倍率（腳底不動）
func billboard_stretch(cam: Camera3D) -> float:
	if use_full_billboard() or cam == null or pitch_compensation <= 0.0:
		return 1.0
	var f := -cam.global_basis.z
	var cos_p := Vector2(f.x, f.z).length()
	return lerpf(1.0, 1.0 / maxf(cos_p, 0.5), pitch_compensation)


func billboard_mode() -> BaseMaterial3D.BillboardMode:
	return BaseMaterial3D.BILLBOARD_ENABLED if use_full_billboard() else BaseMaterial3D.BILLBOARD_FIXED_Y


func use_full_billboard() -> bool:
	return full_billboard or auto_full_billboard


func backend_name() -> String:
	return "MultiMesh" if soldier_backend == SoldierBackend.MULTIMESH else "Sprite3D"


# ---------------------------------------------------------------------------
# 輸入對應：用程式建立，避免手寫 project.godot 的冗長格式，也方便之後改鍵。
# ---------------------------------------------------------------------------
func _setup_input_map() -> void:
	_add_keys("move_forward", [KEY_W, KEY_UP])
	_add_keys("move_back", [KEY_S, KEY_DOWN])
	_add_keys("move_left", [KEY_A, KEY_LEFT])
	_add_keys("move_right", [KEY_D, KEY_RIGHT])
	_add_keys("sprint", [KEY_SHIFT])
	_add_keys("interact", [KEY_E])            # 上馬 / 下馬
	_add_mouse("attack", MOUSE_BUTTON_LEFT)
	_add_keys("attack", [KEY_SPACE])
	_add_mouse("block", MOUSE_BUTTON_RIGHT)    # 舉盾（按住）
	_add_keys("block", [KEY_C])
	_add_keys("switch_weapon", [KEY_Q])       # 下一把武器
	_add_keys("prev_weapon", [KEY_Z])         # 上一把武器
	_add_keys("aim_view", [KEY_F])            # 弓的瞄準視角：第三人稱肩後 ⇄ 第一人稱
	# 部隊指揮：先選兵種（Shift 加選），再下命令；命令只對選取的兵種有效
	_add_keys("select_all", [KEY_1])
	_add_keys("select_inf", [KEY_2])
	_add_keys("select_arc", [KEY_3])
	_add_keys("select_cav", [KEY_4])
	_add_keys("order_charge", [KEY_G])         # 衝鋒
	_add_keys("order_hold", [KEY_H])           # 在此集結（守位）
	_add_keys("order_follow", [KEY_T])         # 跟隨我
	_add_keys("order_move", [KEY_B])           # 移動到準心指的地點（包抄、佔位）
	_add_keys("order_advance", [KEY_X])        # 前進 15 公尺（Shift＋X 後退）
	_add_keys("order_attack", [KEY_N])         # 攻擊準心附近的敵方小隊
	_add_keys("form_line", [KEY_5])
	_add_keys("form_tight", [KEY_6])
	_add_keys("form_loose", [KEY_7])
	_add_keys("form_wedge", [KEY_8])
	_add_keys("toggle_keep", [KEY_9])          # 保持陣型 開／關
	_add_keys("toggle_debug", [KEY_F3])
	_add_keys("cycle_directions", [KEY_F2])
	_add_keys("toggle_backend", [KEY_F4])
	_add_keys("toggle_postfx", [KEY_F5])
	_add_keys("toggle_billboard", [KEY_F6])
	_add_keys("toggle_art", [KEY_F7])
	_add_keys("restart_battle", [KEY_R])
	_add_keys("release_mouse", [KEY_ESCAPE])
	_add_mouse("zoom_in", MOUSE_BUTTON_WHEEL_UP)
	_add_mouse("zoom_out", MOUSE_BUTTON_WHEEL_DOWN)
	_add_keys("next_terrain", [KEY_F8])
	_add_keys("random_terrain", [KEY_F9])
	_add_keys("spectate", [KEY_V])             # 觀戰鏡頭
	_add_keys("toggle_siege", [KEY_F10])       # 野戰 ⇄ 攻城戰
	_add_keys("swap_siege_side", [KEY_F11])    # 攻城戰：攻方 ⇄ 守方（重開）


func _add_keys(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _add_mouse(action: StringName, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------------------
# 場地類型
# ---------------------------------------------------------------------------
func _parse_terrain_arg() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--terrain="):
			var key := a.get_slice("=", 1)
			if key == "random":
				terrain_type = randi() % BattleTerrain.TYPE_KEYS.size()
			elif BattleTerrain.type_from_key(key) >= 0:
				terrain_type = BattleTerrain.type_from_key(key)


func next_terrain() -> void:
	terrain_type = (terrain_type + 1) % BattleTerrain.TYPE_KEYS.size()
	setup.terrain_type = terrain_type


func random_terrain() -> void:
	var n := BattleTerrain.TYPE_KEYS.size()
	terrain_type = (terrain_type + 1 + randi() % (n - 1)) % n
	setup.terrain_type = terrain_type
