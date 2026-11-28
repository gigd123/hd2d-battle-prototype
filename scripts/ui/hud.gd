class_name BattleHUD
extends CanvasLayer
## 畫面資訊：效能、戰況、玩家狀態、操作說明。只讀資料，不改任何狀態。

var player: PlayerController
var battle: Node = null
var _info: Label
var _help: Label
var _toast: Label
var _crosshair: Label                 # 弓箭瞄準時的準心（拉滿變紅）
var _hitmark: Label                   # 箭射中時準心外圍閃一下的 ✕（擊殺是紅色、比較大）
var _hittext: Label                   # 準心下方的「命中 32」「擊殺！」
var _hit_t := 0.0
var _toast_time := 0.0
var _cmd: Label                       # 右上角：部隊指揮狀態
## 由戰場每幀寫入（空字串就不顯示）
var command_text := ""


func _ready() -> void:
	_info = _make_label(Vector2(12, 10), 15)
	_help = _make_label(Vector2(12, 0), 14)
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.offset_top = -215
	_help.text = "\n".join([
		"WASD 移動　Shift 奔跑/奔馳　E 上馬/下馬　左鍵/空白 攻擊（弓：按住拉弓、放開射出）　右鍵/C 舉盾或格擋",
		"Q／Z 換下一把／上一把武器　F 弓的瞄準視角：肩後 ⇄ 第一人稱",
		"滑鼠 旋轉相機　滾輪 縮放　Esc 暫停／回選單",
		"指揮　1 全軍 2 步兵 3 弓兵 4 騎兵（Shift 加選）　G 衝鋒　H 在此集結　T 跟隨我　B 移動到準心處　X 前進（Shift 後退）　N 攻擊準心處敵隊",
		"陣型　5 橫隊　6 緊密　7 鬆散　8 楔形　9 保持陣型 開／關",
		"R 重開戰局　F2 切換方向數　F3 除錯繪製　F4 士兵畫面後端　F5 後製效果　F6 Billboard 方式",
		"F8 換場地　F9 隨機場地　V 觀戰鏡頭　F10 野戰 ⇄ 攻城戰　F11 攻城戰換邊",
	])
	_help.offset_top = -255
	_cmd = _make_label(Vector2.ZERO, 15)
	_cmd.anchor_left = 1.0
	_cmd.anchor_right = 1.0
	_cmd.offset_left = -470
	_cmd.offset_right = -12
	_cmd.offset_top = 10
	_cmd.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_crosshair = _make_label(Vector2.ZERO, 26)
	_crosshair.text = "+"
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.offset_left = -20
	_crosshair.offset_right = 20
	_crosshair.offset_top = -18
	_crosshair.offset_bottom = 18
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hitmark = _make_label(Vector2.ZERO, 44)
	_hitmark.text = "✕"
	for l in [_hitmark]:
		l.anchor_left = 0.5
		l.anchor_right = 0.5
		l.anchor_top = 0.5
		l.anchor_bottom = 0.5
		l.offset_left = -40
		l.offset_right = 40
		l.offset_top = -32
		l.offset_bottom = 32
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.visible = false
	_hittext = _make_label(Vector2.ZERO, 20)
	_hittext.anchor_left = 0.5
	_hittext.anchor_right = 0.5
	_hittext.anchor_top = 0.5
	_hittext.anchor_bottom = 0.5
	_hittext.offset_left = -120
	_hittext.offset_right = 120
	_hittext.offset_top = 30
	_hittext.offset_bottom = 60
	_hittext.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hittext.visible = false
	_toast = _make_label(Vector2(0, 120), 22)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_left = -300
	_toast.offset_right = 300
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _make_label(pos: Vector2, font_size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	add_child(l)
	return l


## 玩家的箭射中：準心閃 ✕，下方顯示傷害或擊殺
func on_arrow_hit(_point: Vector3, damage: float, killed: bool) -> void:
	_hit_t = 0.6 if killed else 0.4
	_hitmark.modulate = Color(1.0, 0.25, 0.2) if killed else Color(1, 1, 1)
	_hitmark.add_theme_font_size_override("font_size", 56 if killed else 40)
	_hittext.text = ("擊殺！ %d" if killed else "命中 %d") % int(damage)
	_hittext.modulate = Color(1.0, 0.35, 0.3) if killed else Color(1.0, 0.95, 0.6)


func toast(text: String, seconds := 1.5) -> void:
	_toast.text = text
	_toast_time = seconds


func _process(delta: float) -> void:
	_toast_time -= delta
	_toast.visible = _toast_time > 0.0
	_cmd.text = command_text
	_cmd.visible = command_text != ""
	_hit_t = maxf(_hit_t - delta / maxf(Engine.time_scale, 0.001), 0.0)
	_hitmark.visible = _hit_t > 0.0
	_hittext.visible = _hit_t > 0.0
	if _hit_t > 0.0:
		var a := clampf(_hit_t / 0.25, 0.0, 1.0)
		_hitmark.modulate.a = a
		_hittext.modulate.a = a
	_crosshair.visible = player != null and player.aim_view_active()
	if _crosshair.visible:
		var pw := player.draw_power()
		_crosshair.modulate = Color(1.0, 1.0 - 0.7 * pw, 1.0 - 0.7 * pw)
		_crosshair.scale = Vector2.ONE
	var lines: Array[String] = []
	var fps := Engine.get_frames_per_second()
	lines.append("FPS %d　幀時間 %.1f ms　Process %.2f ms　Physics %.2f ms" % [
		fps, 1000.0 / maxf(fps, 1.0),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	if battle != null:
		lines.append(battle.call("stats_text"))
	if battle != null and battle.get("terrain") != null:
		lines.append("場地：%s" % (battle.get("terrain") as BattleTerrain).type_name())
	lines.append("方向：%s　士兵畫面：%s　Billboard：%s　後製：%s" % [GameConfig.direction_mode_name(), GameConfig.backend_name(), "面向相機" if GameConfig.full_billboard else "Y 軸", "開" if GameConfig.postfx_enabled else "關"])
	if player:
		var state := "騎馬" if player.mounted else "步行"
		if player.dead:
			state = "倒地（數秒後重生）"
		var spd := player.move_velocity().length()
		if player.blocking:
			state += "・舉盾" if player.wdef["block"] == "shield" else "・格擋"
		if player.is_aiming():
			state += "・拉弓 %d%%" % int(player.draw_power() * 100.0)
		lines.append("玩家：%s　武器 %s　生命 %d/%d　速度 %.1f m/s　擊殺 %d" % [state, player.weapon_name(), player.hp, player.max_hp, spd, player.total_kills])
		if not player.mounted and player.horse and player.global_position.distance_to(player.horse.global_position) < player.mount_range:
			lines.append("按 E 上馬")
	_info.text = "\n".join(lines)
