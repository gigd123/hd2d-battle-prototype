extends Control
## 初始選單：設定地圖、雙方編成（兵種 × 武器配置 × 人數）、AI、玩家角色，然後開打。
## 全部只是在填 BattleSetup；按「開始戰鬥」時存成 user://last_setup.json，下次打開選單會記得。
## 以啟動參數直接指定戰場（--scenario、--setup、--siege、--per-side、--side、--screenshot）時跳過選單。

const BATTLE_SCENE := "res://scenes/battlefield.tscn"
const SKIP_ARGS := ["--scenario=", "--setup=", "--siege=", "--per-side=", "--side=", "--screenshot=", "--battle"]

var setup: BattleSetup
var _army_boxes: Array[VBoxContainer] = [null, null]
var _side_totals: Array[Label] = [null, null]
var _ai_opts: Array[OptionButton] = [null, null]
var _total_label: Label
var _weapon_checks: Array[CheckBox] = []
var _terrain_opt: OptionButton
var _size_opt: OptionButton
var _seed_spin: SpinBox
var _seed_random: CheckBox
var _time_opt: OptionButton
var _side_opt: OptionButton
var _mounted_chk: CheckBox
var _counts_chk: CheckBox
var _respawn_chk: CheckBox
const TIME_LIMITS := [0.0, 180.0, 300.0, 600.0]
const TIME_NAMES := ["不限", "3 分鐘", "5 分鐘", "10 分鐘"]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if "--menu" in args:
			break
		for k in SKIP_ARGS:
			if a.begins_with(k):
				_go_battle.call_deferred(false)
				return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	var last := BattleSetup.load_json(GameConfig.LAST_SETUP_PATH)
	setup = last if last else GameConfig.setup.duplicate_setup()
	_build()
	_refresh_all()


# ---------------------------------------------------------------------------
# 版面
# ---------------------------------------------------------------------------
func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.10)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var title := Label.new()
	title.text = "戰鬥測試平台"
	title.add_theme_font_size_override("font_size", 34)
	root.add_child(title)
	var sub := Label.new()
	sub.text = "自由配置雙方軍隊後開打。所有選項都會記住，下次打開維持上次的設定。"
	sub.modulate = Color(1, 1, 1, 0.7)
	root.add_child(sub)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 18)
	root.add_child(cols)

	# --- 左：地圖與玩家 ---
	var left := _section(cols, "地圖", 400)
	_terrain_opt = _option(left, "場地", BattleTerrain.TYPE_NAMES, func(i): setup.terrain_type = i)
	_size_opt = _option(left, "地圖尺寸", BattleSetup.MAP_SIZE_NAMES, func(i):
		setup.map_size = BattleSetup.MAP_SIZES[i]
		_refresh_totals())
	var seed_row := _row(left, "亂數種子")
	_seed_spin = SpinBox.new()
	_seed_spin.max_value = 99999
	_seed_spin.value_changed.connect(func(v): setup.seed_value = int(v))
	seed_row.add_child(_seed_spin)
	_seed_random = CheckBox.new()
	_seed_random.text = "每場隨機"
	_seed_random.toggled.connect(func(on): setup.random_seed = on)
	seed_row.add_child(_seed_random)
	_time_opt = _option(left, "時間上限", TIME_NAMES, func(i): setup.time_limit = TIME_LIMITS[i])

	_header(left, "玩家")
	_side_opt = _option(left, "陣營", ["藍軍（西側）", "紅軍（東側）", "不參戰，只觀戰"], func(i):
		setup.player_side = [0, 1, -1][i]
		_refresh_totals())
	_mounted_chk = _check(left, "開局騎馬", func(on):
		setup.player_mounted = on
		_refresh_totals())
	_counts_chk = _check(left, "玩家算在己方人數裡（從同類兵種扣 1 人）", func(on):
		setup.player_counts = on
		_refresh_totals())
	_respawn_chk = _check(left, "陣亡後在後方重生（不勾 = 改成觀戰）", func(on): setup.player_respawn = on)
	var wl := Label.new()
	wl.text = "攜帶武器（Q／Z 切換，第一把是開場武器）"
	left.add_child(wl)
	var wg := GridContainer.new()
	wg.columns = 2
	left.add_child(wg)
	for k in WeaponDefs.count():
		var d := WeaponDefs.get_def(k)
		var cb := CheckBox.new()
		cb.text = d["name"]
		var id: String = WeaponDefs.ALL[k]["id"]
		cb.toggled.connect(func(on): _toggle_weapon(id, on))
		wg.add_child(cb)
		_weapon_checks.append(cb)

	# --- 中、右：兩方編成 ---
	for side in 2:
		var col := _section(cols, BattleSetup.SIDE_NAMES[side] + ("（西側）" if side == 0 else "（東側）"), 0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var presets := HBoxContainer.new()
		var pl := Label.new()
		pl.text = "快速範本："
		presets.add_child(pl)
		for n in [10, 25, 50, 100, 200]:
			var b := Button.new()
			b.text = str(n)
			b.pressed.connect(func():
				setup.apply_preset(side, n)
				_refresh_army(side))
			presets.add_child(b)
		col.add_child(presets)
		var head := HBoxContainer.new()
		for h in [["兵種", 90], ["武器配置", 150], ["人數", 110]]:
			var l := Label.new()
			l.text = h[0]
			l.custom_minimum_size = Vector2(h[1], 0)
			l.modulate = Color(1, 1, 1, 0.6)
			head.add_child(l)
		col.add_child(head)
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.custom_minimum_size = Vector2(0, 220)
		col.add_child(scroll)
		var rows := VBoxContainer.new()
		rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(rows)
		_army_boxes[side] = rows
		var add := Button.new()
		add.text = "＋ 新增一列"
		add.pressed.connect(func():
			setup.armies[side].append({"unit": 0, "loadout": "sword_shield", "count": 10})
			_refresh_army(side))
		col.add_child(add)
		_side_totals[side] = Label.new()
		col.add_child(_side_totals[side])
		_ai_opts[side] = _option(col, "電腦指揮時", BattleSetup.AI_MODE_NAMES, func(i): setup.ai_mode[side] = i)

	# --- 底部 ---
	_total_label = Label.new()
	_total_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_total_label)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	root.add_child(bottom)
	var start := Button.new()
	start.text = "開始戰鬥"
	start.custom_minimum_size = Vector2(220, 52)
	start.add_theme_font_size_override("font_size", 22)
	var ss := StyleBoxFlat.new()
	ss.bg_color = Color(0.20, 0.45, 0.28)
	ss.set_corner_radius_all(6)
	start.add_theme_stylebox_override("normal", ss)
	var sh := ss.duplicate() as StyleBoxFlat
	sh.bg_color = Color(0.26, 0.56, 0.34)
	start.add_theme_stylebox_override("hover", sh)
	start.pressed.connect(func(): _go_battle(true))
	bottom.add_child(start)
	var reset := Button.new()
	reset.text = "恢復預設"
	reset.custom_minimum_size = Vector2(0, 52)
	reset.pressed.connect(func():
		setup = BattleSetup.make_default()
		_refresh_all())
	bottom.add_child(reset)
	var siege := Button.new()
	siege.text = "攻城戰（固定編成）"
	siege.custom_minimum_size = Vector2(0, 52)
	siege.pressed.connect(func():
		GameConfig.siege_mode = true
		GameConfig.siege_side = -1
		get_tree().change_scene_to_file(BATTLE_SCENE))
	bottom.add_child(siege)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	var quit := Button.new()
	quit.text = "結束"
	quit.custom_minimum_size = Vector2(100, 52)
	quit.pressed.connect(func(): get_tree().quit())
	bottom.add_child(quit)


func _section(parent: Control, title: String, width: float) -> VBoxContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.17)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	pc.add_theme_stylebox_override("panel", sb)
	if width > 0.0:
		pc.custom_minimum_size = Vector2(width, 0)
	parent.add_child(pc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pc.add_child(box)
	_header(box, title)
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL if width <= 0.0 else Control.SIZE_FILL
	return box


func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", Color(1.0, 0.88, 0.6))
	parent.add_child(l)


func _row(parent: Control, label: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(110, 0)
	r.add_child(l)
	parent.add_child(r)
	return r


func _option(parent: Control, label: String, items: Array, cb: Callable) -> OptionButton:
	var r := _row(parent, label)
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.item_selected.connect(cb)
	r.add_child(o)
	return o


func _check(parent: Control, text: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


# ---------------------------------------------------------------------------
# 資料 → 畫面
# ---------------------------------------------------------------------------
func _refresh_all() -> void:
	_terrain_opt.select(setup.terrain_type)
	_size_opt.select(maxi(BattleSetup.MAP_SIZES.find(setup.map_size), 0))
	_seed_spin.set_value_no_signal(setup.seed_value)
	_seed_random.set_pressed_no_signal(setup.random_seed)
	_time_opt.select(maxi(TIME_LIMITS.find(setup.time_limit), 0))
	_side_opt.select(2 if setup.player_side < 0 else setup.player_side)
	_mounted_chk.set_pressed_no_signal(setup.player_mounted)
	_counts_chk.set_pressed_no_signal(setup.player_counts)
	_respawn_chk.set_pressed_no_signal(setup.player_respawn)
	for k in _weapon_checks.size():
		_weapon_checks[k].set_pressed_no_signal(setup.player_weapons.has(WeaponDefs.ALL[k]["id"]))
	for side in 2:
		_ai_opts[side].select(setup.ai_mode[side])
		_refresh_army(side)


func _refresh_army(side: int) -> void:
	var box := _army_boxes[side]
	for c in box.get_children():
		c.queue_free()
	var rows: Array = setup.armies[side]
	for k in rows.size():
		box.add_child(_army_row(side, k))
	_refresh_totals()


func _army_row(side: int, k: int) -> HBoxContainer:
	var r: Dictionary = setup.armies[side][k]
	var h := HBoxContainer.new()
	var unit := OptionButton.new()
	unit.custom_minimum_size = Vector2(90, 0)
	for n in BattleSetup.UNIT_NAMES:
		unit.add_item(n)
	unit.select(int(r["unit"]))
	unit.item_selected.connect(func(i):
		r["unit"] = i
		r["loadout"] = UnitDefs.get_def(UnitDefs.default_for(i))["id"]
		_refresh_army(side))
	h.add_child(unit)
	var lo := OptionButton.new()
	lo.custom_minimum_size = Vector2(150, 0)
	var opts := UnitDefs.options_for(int(r["unit"]))
	var cur := UnitDefs.resolve(str(r["loadout"]), int(r["unit"]))
	for i in opts.size():
		lo.add_item(UnitDefs.get_def(opts[i])["name"])
		if opts[i] == cur:
			lo.select(i)
	lo.item_selected.connect(func(i): r["loadout"] = UnitDefs.get_def(opts[i])["id"])
	h.add_child(lo)
	var cnt := SpinBox.new()
	cnt.min_value = 0
	cnt.max_value = 1000
	cnt.custom_minimum_size = Vector2(110, 0)
	cnt.value = int(r["count"])
	cnt.value_changed.connect(func(v):
		r["count"] = int(v)
		_refresh_totals())
	h.add_child(cnt)
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "刪除這一列"
	del.pressed.connect(func():
		setup.armies[side].remove_at(k)
		_refresh_army(side))
	h.add_child(del)
	return h


func _refresh_totals() -> void:
	for side in 2:
		if _side_totals[side] == null:
			continue
		var n := setup.side_total(side)
		var extra := ""
		if setup.player_side == side:
			extra = "　＋你（已計入）" if setup.player_counts else "　＋你"
		_side_totals[side].text = "合計 %d 人%s" % [n, extra]
	if _total_label == null:
		return
	var total := setup.total()
	var txt := "雙方合計 %d 人　實際地圖 %d m　場地 %s" % [total, setup.resolved_map_size(), BattleTerrain.TYPE_NAMES[setup.terrain_type]]
	_total_label.remove_theme_color_override("font_color")
	if setup.side_total(0) == 0 or setup.side_total(1) == 0:
		txt += "　｜　兩方都至少要有 1 人才能開打"
		_total_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	elif total > BattleSetup.TESTED_TOTAL:
		txt += "　｜　超過目前測試過的 %d 人，可能會卡，仍可開打" % BattleSetup.TESTED_TOTAL
		_total_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_total_label.text = txt


func _toggle_weapon(id: String, on: bool) -> void:
	if on and not setup.player_weapons.has(id):
		setup.player_weapons.append(id)
	elif not on:
		if setup.player_weapons.size() <= 1:
			# 至少要帶一把：把勾選還原
			_refresh_all()
			return
		setup.player_weapons.erase(id)


func _go_battle(from_menu: bool) -> void:
	if from_menu:
		if setup.side_total(0) == 0 or setup.side_total(1) == 0:
			return
		if setup.random_seed:
			setup.seed_value = randi() % 100000
		setup.save_json(GameConfig.LAST_SETUP_PATH)
		GameConfig.setup = setup
		GameConfig.siege_mode = false
		GameConfig.from_menu = true
	get_tree().change_scene_to_file(BATTLE_SCENE)
