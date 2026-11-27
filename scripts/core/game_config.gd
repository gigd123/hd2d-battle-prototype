extends Node
## 全域原型設定（Autoload 名稱：GameConfig）。
##
## 這裡只放「尚未定案、之後可能改」的選項，讓戰鬥邏輯與畫面都從同一處讀取。
## 例如方向數：架構上限是 8 方向，可在執行期切換成 4 方向或「5 方向＋鏡像」比較。

signal direction_mode_changed

## 方向模式：
## - DIR_8：8 張方向圖（S, SE, E, NE, N, NW, W, SW）
## - DIR_8_MIRROR：只畫 5 張（S, N, 與西側 3 張），東側 3 張用西側水平翻轉
## - DIR_4：4 張方向圖（S, E, N, W）
enum DirectionMode { DIR_8, DIR_8_MIRROR, DIR_4 }

## 士兵畫面後端（視覺代理的兩種實作）
enum SoldierBackend { SPRITE3D, MULTIMESH }

const MAX_DIRECTIONS := 8

var direction_mode: int = DirectionMode.DIR_8
var soldier_backend: int = SoldierBackend.SPRITE3D
## Billboard 方式：false = Y 軸（直立紙片，報告建議的起點）；true = 完全面向相機。
## 相機俯角大時，Y 軸 Billboard 在畫面邊緣會有透視傾斜；兩種都保留，F6 切換比較。
var full_billboard := false
## 後製效果（景深、泛光、SSAO、霧）。壓力測試可關閉以比較。
var postfx_enabled := true
## 固定亂數種子：同一種子重跑，戰場生成與 AI 隨機值一致（便於比較）。
var battle_seed := 12345
## 除錯繪製（武器掃掠軌跡、小隊目標等）
var debug_draw := false
## 場地類型（BattleTerrain.Type）：F8 下一種、F9 隨機；啟動參數 --terrain=plains|hills|forest|river|snow|random
var terrain_type := 1


func _ready() -> void:
	_setup_input_map()
	_parse_terrain_arg()
	_parse_dev_args()


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
	if scenario != "":
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


func billboard_mode() -> BaseMaterial3D.BillboardMode:
	return BaseMaterial3D.BILLBOARD_ENABLED if full_billboard else BaseMaterial3D.BILLBOARD_FIXED_Y


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
	_add_keys("order_charge", [KEY_1])         # 全軍衝鋒
	_add_keys("order_hold", [KEY_2])           # 在此集結（守位）
	_add_keys("order_follow", [KEY_3])         # 跟隨我
	_add_keys("toggle_debug", [KEY_F3])
	_add_keys("cycle_directions", [KEY_F2])
	_add_keys("toggle_backend", [KEY_F4])
	_add_keys("toggle_postfx", [KEY_F5])
	_add_keys("toggle_billboard", [KEY_F6])
	_add_keys("restart_battle", [KEY_R])
	_add_keys("release_mouse", [KEY_ESCAPE])
	_add_mouse("zoom_in", MOUSE_BUTTON_WHEEL_UP)
	_add_mouse("zoom_out", MOUSE_BUTTON_WHEEL_DOWN)
	_add_keys("next_terrain", [KEY_F8])
	_add_keys("random_terrain", [KEY_F9])


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


func random_terrain() -> void:
	var n := BattleTerrain.TYPE_KEYS.size()
	terrain_type = (terrain_type + 1 + randi() % (n - 1)) % n
