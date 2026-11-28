class_name BattleMenus
extends CanvasLayer
## 戰場上的兩個覆蓋畫面：暫停選單（Esc）與戰後結算。
## 結算內容同時可以複製成文字（朋友試玩後直接貼回來），並附加一行到 user://battle_results.csv。

const MENU_SCENE := "res://scenes/main_menu.tscn"
const RESULTS_CSV := "user://battle_results.csv"

var battle: BattleManager
var player: PlayerController            # 觀戰時為 null
var setup: BattleSetup                  # 攻城戰或展示腳本時為 null
var _panel: Control = null
var _kind := ""                         # "pause" | "results"
var _results_text := ""
var _was_captured := false


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _panel != null


func close() -> void:
	if _panel:
		_panel.queue_free()
		_panel = null
	if _kind == "pause":
		get_tree().paused = false
		if _was_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_kind = ""


# ---------------------------------------------------------------------------
# 暫停選單
# ---------------------------------------------------------------------------
func toggle_pause() -> void:
	if _kind == "pause":
		close()
		return
	if _panel:
		return
	_kind = "pause"
	_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true
	var box := _make_panel("暫停", 420)
	_add_button(box, "繼續（Esc）", close)
	_add_button(box, "重新開始（同樣設定）", _restart)
	_add_button(box, "回到初始選單", _to_menu)
	_add_button(box, "結束遊戲", func(): get_tree().quit())
	var hint := Label.new()
	hint.text = "暫停中可以用滑鼠點選；按 Esc 或「繼續」回到戰場"
	hint.add_theme_font_size_override("font_size", 14)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


# ---------------------------------------------------------------------------
# 戰後結算
# ---------------------------------------------------------------------------
func show_results() -> void:
	if _kind == "pause":
		close()
	if _panel:
		_panel.queue_free()
	_kind = "results"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_results_text = results_text()
	_append_csv()
	var box := _make_panel(battle.winner_text(battle.winner), 720)
	var sub := Label.new()
	sub.text = "戰鬥時間 %s%s" % [_fmt_time(battle.battle_time), "（時間到，以剩餘人數判定）" if _time_up() else ""]
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	box.add_child(_unit_table())
	var src := Label.new()
	src.text = _kill_source_line()
	src.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(src)
	if player:
		var pl := Label.new()
		pl.text = _player_line()
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(pl)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	_add_button(row, "再打一場", _restart, 150)
	_add_button(row, "回到初始選單", _to_menu, 150)
	var copy_btn := _add_button(row, "複製結果", func(): pass, 150)
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(_results_text)
		copy_btn.text = "已複製！")
	_add_button(row, "繼續觀看", close, 150)
	var path := Label.new()
	path.text = "結果已記錄到 %s" % ProjectSettings.globalize_path(RESULTS_CSV)
	path.add_theme_font_size_override("font_size", 12)
	path.modulate = Color(1, 1, 1, 0.6)
	path.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	path.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	box.add_child(path)


func _time_up() -> bool:
	return battle.time_limit > 0.0 and battle.alive_count[0] > 0 and battle.alive_count[1] > 0


func _unit_types() -> Array[int]:
	var out: Array[int] = []
	for ut in 4:
		if battle.stat_start[ut] + battle.stat_start[4 + ut] > 0:
			out.append(ut)
	return out


func _unit_table() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 7
	g.add_theme_constant_override("h_separation", 22)
	g.add_theme_constant_override("v_separation", 4)
	var head := ["兵種", "藍軍 開場", "陣亡", "剩餘", "紅軍 開場", "陣亡", "剩餘"]
	for h in head:
		g.add_child(_cell(h, true))
	var tot := [0, 0, 0, 0]
	for ut in _unit_types():
		g.add_child(_cell(BattleManager.U_NAMES[ut], false))
		for t in 2:
			var su := battle.stat_unit(t, ut)
			tot[t * 2] += su.x
			tot[t * 2 + 1] += su.y
			g.add_child(_cell(str(su.x), false))
			g.add_child(_cell(str(su.y), false))
			g.add_child(_cell(str(su.x - su.y), false))
	g.add_child(_cell("合計", true))
	for t in 2:
		g.add_child(_cell(str(tot[t * 2]), true))
		g.add_child(_cell(str(tot[t * 2 + 1]), true))
		g.add_child(_cell(str(tot[t * 2] - tot[t * 2 + 1]), true))
	return g


func _cell(text: String, bold: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if bold:
		l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	return l


func _kill_source_line() -> String:
	var parts: Array[String] = []
	for t in 2:
		var bits: Array[String] = []
		for src in 4:
			var n := battle.stat_kill_src[t * 4 + src]
			if n > 0:
				bits.append("%s %d" % [BattleManager.SRC_NAMES[src], n])
		parts.append("%s擊殺：%s" % [BattleSetup.SIDE_NAMES[t], "、".join(bits) if not bits.is_empty() else "0"])
	return "　".join(parts)


func _player_line() -> String:
	var acc := ""
	if player.arrows_fired > 0:
		acc = "　弓箭命中 %d/%d（%d%%）" % [player.arrows_hit, player.arrows_fired, roundi(100.0 * player.arrows_hit / player.arrows_fired)]
	return "玩家（%s）：擊殺 %d　造成傷害 %d　承受傷害 %d　陣亡 %d 次%s" % [
		BattleSetup.SIDE_NAMES[player.team], player.total_kills, roundi(player.dmg_dealt), roundi(player.dmg_taken), player.deaths, acc]


static func _fmt_time(sec: float) -> String:
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]


## 純文字版結果（複製用）
func results_text() -> String:
	var lines: Array[String] = []
	lines.append("【戰鬥結果】%s　時間 %s%s" % [battle.winner_text(battle.winner), _fmt_time(battle.battle_time), "（時間到）" if _time_up() else ""])
	if setup:
		lines.append("設定：" + setup.summary())
	for ut in _unit_types():
		var b := battle.stat_unit(0, ut)
		var r := battle.stat_unit(1, ut)
		lines.append("%s　藍 %d→%d（陣亡 %d）　紅 %d→%d（陣亡 %d）" % [BattleManager.U_NAMES[ut], b.x, b.x - b.y, b.y, r.x, r.x - r.y, r.y])
	lines.append(_kill_source_line())
	if player:
		lines.append(_player_line())
	lines.append("遊戲版本：%s" % ProjectSettings.get_setting("application/config/version", "dev"))
	return "\n".join(lines)


func _append_csv() -> void:
	var exists := FileAccess.file_exists(RESULTS_CSV)
	var f := FileAccess.open(RESULTS_CSV, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if f == null:
		return
	if exists:
		f.seek_end()
	else:
		f.store_csv_line(PackedStringArray(["時間", "勝方", "秒數", "藍開場", "藍陣亡", "紅開場", "紅陣亡",
			"藍步兵", "藍弓兵", "藍騎兵", "紅步兵", "紅弓兵", "紅騎兵", "玩家陣營", "玩家擊殺", "玩家傷害", "玩家承受", "設定"]))
	var row := PackedStringArray()
	row.append(Time.get_datetime_string_from_system(false, true))
	row.append(battle.winner_text(battle.winner))
	row.append("%.0f" % battle.battle_time)
	for t in 2:
		var s0 := 0
		var d0 := 0
		for ut in 4:
			s0 += battle.stat_start[t * 4 + ut]
			d0 += battle.stat_dead[t * 4 + ut]
		row.append(str(s0))
		row.append(str(d0))
	for t in 2:
		for ut in 3:
			var su := battle.stat_unit(t, ut)
			row.append("%d/%d" % [su.x - su.y, su.x])
	if player:
		row.append(BattleSetup.SIDE_NAMES[player.team])
		row.append(str(player.total_kills))
		row.append(str(roundi(player.dmg_dealt)))
		row.append(str(roundi(player.dmg_taken)))
	else:
		row.append_array(PackedStringArray(["觀戰", "", "", ""]))
	row.append(setup.summary() if setup else "")
	f.store_csv_line(row)


# ---------------------------------------------------------------------------
func _restart() -> void:
	get_tree().paused = false
	if setup and setup.random_seed:
		setup.seed_value = randi() % 100000
		GameConfig.battle_seed = setup.seed_value
	get_tree().reload_current_scene()


func _to_menu() -> void:
	get_tree().paused = false
	GameConfig.siege_mode = false
	GameConfig.siege_side = -1
	get_tree().change_scene_to_file(MENU_SCENE)


func _make_panel(title: String, width: float) -> VBoxContainer:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	_panel = root
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13, 0.94)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(22)
	pc.add_theme_stylebox_override("panel", sb)
	center.add_child(pc)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(width, 0)
	box.add_theme_constant_override("separation", 12)
	pc.add_child(box)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 30)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	return box


func _add_button(parent: Control, text: String, cb: Callable, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 42)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b
