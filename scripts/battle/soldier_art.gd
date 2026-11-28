class_name SoldierArt
extends RefCounted
## 一個兵種的士兵圖集：可以是程式佔位圖，也可以是預渲染圖（BakedSpriteSet 合成）。
## SoldierRenderer 只透過這裡拿「圖集、幀大小、原點、這個狀態該畫哪一列」，
## 所以換美術來源時，Sprite3D 與 MultiMesh 兩種畫面後端都不用改。
##
## 預渲染士兵是在載入時把分層圖合成單張圖集（士兵數量多，一人一張 Sprite 比較省）：
##   步兵 = 身體＋長槍、弓兵 = 身體＋劍（原型還沒有弓的模型）、
##   騎兵 = 馬＋騎士（依每格錨點把騎士的 seat 貼到馬的 saddle 上）。

enum Kind { IDLE, WALK, RUN, ATTACK, DEAD, WALK_ATTACK }

const CAV_TOP_PAD := 40           # 騎兵合成圖在馬的幀上方多留的高度（騎士上半身與舉劍）

var baked := false
var unit := 0
var frame := Vector2i(20, 30)
var rows := 4
var pixel_size := PlaceholderArt.PIXEL_SIZE
var origin := Vector2(-1, -1)
## 動作名 → [起始列, 幀數, fps, 是否循環]
var actions: Dictionary = {}
var _rgba: Image                  # 合成後的圖集（RGBA）
var _mask: Image                  # 陣營色遮罩（L8）
var _tex_cache: Dictionary = {}

static var _cache: Dictionary = {}


static func for_unit(ut: int) -> SoldierArt:
	var key := "%d_%d" % [ut, GameConfig.art_mode]
	if _cache.has(key):
		return _cache[key]
	var a := SoldierArt.new()
	# 劍盾兵（BattleManager.UnitType.SWORDSMAN = 3）的佔位圖沿用步兵
	var pu := PlaceholderArt.Unit.INFANTRY if ut >= 3 else ut
	a.unit = pu
	if not a._try_baked(ut):
		a.baked = false
		a.frame = PlaceholderArt.unit_frame(pu)
		a.rows = PlaceholderArt.unit_rows(pu)
	_cache[key] = a
	return a


# ---------------------------------------------------------------------------
# 給畫面後端
# ---------------------------------------------------------------------------
## Sprite3D 用：已換好陣營色的貼圖
func tinted_texture(tint: Color) -> Texture2D:
	if not baked:
		return PlaceholderArt.unit_atlas_tinted(unit, tint)
	var key := tint.to_html()
	if not _tex_cache.has(key):
		var data := _rgba.get_data()
		var md := _mask.get_data()
		for i in md.size():
			if md[i] > 127:
				data[i * 4] = int(data[i * 4] * tint.r)
				data[i * 4 + 1] = int(data[i * 4 + 1] * tint.g)
				data[i * 4 + 2] = int(data[i * 4 + 2] * tint.b)
		_tex_cache[key] = ImageTexture.create_from_image(Image.create_from_data(_rgba.get_width(), _rgba.get_height(), false, Image.FORMAT_RGBA8, data))
	return _tex_cache[key]


## MultiMesh 用：未換色的圖集。預渲染圖把陣營色遮罩編在透明度裡（0.75 = 要乘陣營色）。
func shader_atlas() -> Texture2D:
	if not baked:
		return PlaceholderArt.unit_atlas(unit)
	if not _tex_cache.has("_mm"):
		var data := _rgba.get_data()
		var md := _mask.get_data()
		for i in md.size():
			if md[i] > 127 and data[i * 4 + 3] > 0:
				data[i * 4 + 3] = 191
		_tex_cache["_mm"] = ImageTexture.create_from_image(Image.create_from_data(_rgba.get_width(), _rgba.get_height(), false, Image.FORMAT_RGBA8, data))
	return _tex_cache["_mm"]


## 該畫哪一列。t = 戰鬥時間（秒，已加上每人偏移）；progress = 攻擊進度 0..1；speed = 移動速度
func row_for(kind: int, t: float, progress: float, speed: float) -> int:
	if not baked:
		match kind:
			Kind.DEAD:
				return PlaceholderArt.ROW_DEAD
			Kind.ATTACK, Kind.WALK_ATTACK:
				return PlaceholderArt.ROW_ATTACK if progress > 0.44 else PlaceholderArt.ROW_IDLE
			Kind.WALK, Kind.RUN:
				var rate := 9.0 if unit == PlaceholderArt.Unit.CAVALRY else 5.0
				return PlaceholderArt.ROW_WALK if int(t * rate) % 2 == 0 else PlaceholderArt.ROW_IDLE
		return PlaceholderArt.ROW_IDLE
	match kind:
		Kind.DEAD:
			return _row("death", t, -1.0)
		Kind.ATTACK:
			return _row("attack", 0.0, progress)
		Kind.WALK_ATTACK:
			return _row("walk_attack" if actions.has("walk_attack") else "attack", 0.0, progress)
		Kind.RUN:
			return _row("run", t * maxf(0.6, speed / 4.0), -1.0)
		Kind.WALK:
			return _row("walk", t * maxf(0.6, speed / 3.0), -1.0)
	return _row("idle", t, -1.0)


func _row(action: String, t: float, progress: float) -> int:
	var a: Array = actions.get(action, actions.get("idle", [0, 1, 1.0, true]))
	var frames: int = a[1]
	var f: int
	if progress >= 0.0:
		f = clampi(int(floor(progress * frames)), 0, frames - 1)
	elif a[3]:
		f = posmod(int(floor(t * a[2])), frames)
	else:
		f = clampi(int(floor(t * a[2])), 0, frames - 1)
	return int(a[0]) + f


# ---------------------------------------------------------------------------
# 合成預渲染圖集
# ---------------------------------------------------------------------------
func _try_baked(ut: int) -> bool:
	var knight := GameConfig.baked_set("knight")
	if knight == null:
		return false
	if ut == PlaceholderArt.Unit.CAVALRY:
		var horse := GameConfig.baked_set("horse")
		if horse == null:
			return false
		_compose_cavalry(horse, knight)
	else:
		# 步兵：長槍＋盾；弓兵：弓（沒有盾）。舊的烘焙圖沒有弓／盾圖層時退回劍
		var weapon := "spear" if ut == PlaceholderArt.Unit.INFANTRY and knight.has_layer("spear") else "sword"
		if ut == PlaceholderArt.Unit.ARCHER and knight.has_layer("bow") and knight.has_action("bow_shoot"):
			weapon = "bow"
		if ut == 3:
			weapon = "sword"      # 劍盾兵
		_compose_foot(knight, weapon, weapon != "bow")
	baked = true
	return true


static func _layer_image(bs: BakedSpriteSet, layer: String) -> Image:
	return bs._image(bs.layers[layer]["image"])


static func _mask_image(bs: BakedSpriteSet, layer: String) -> Image:
	if not bs.layers[layer].has("team_mask"):
		return null
	return bs._image(bs.layers[layer]["team_mask"])


## 步兵／弓兵：同一組圖的 idle、walk、run、attack_a、death 五個動作，身體＋武器壓成一張
func _compose_foot(bs: BakedSpriteSet, weapon: String, with_shield := true) -> void:
	frame = bs.frame_size
	pixel_size = bs.pixel_size
	origin = bs.origin
	# 邊走邊攻擊：下半身繼續走路、上半身出手（步兵拿長槍用刺擊，弓兵拿劍用揮砍）
	var atk := "thrust" if weapon == "spear" and bs.has_action("thrust") else "attack_a"
	var watk := "walk_thrust" if weapon == "spear" else "walk_attack_a"
	if weapon == "bow":
		atk = "bow_shoot"
		watk = ""
	var pick := ["idle", "walk", "run", atk, "death"]
	var names := ["idle", "walk", "run", "attack", "death"]
	if bs.has_action(watk):
		pick.append(watk)
		names.append("walk_attack")
	var total := 0
	for n in pick:
		total += int(bs.actions[n]["frames"])
	rows = total
	_rgba = Image.create_empty(frame.x * 8, frame.y * rows, false, Image.FORMAT_RGBA8)
	_mask = Image.create_empty(frame.x * 8, frame.y * rows, false, Image.FORMAT_L8)
	var body := _layer_image(bs, "body")
	var body_mask := _mask_image(bs, "body")
	var wpn := _layer_image(bs, weapon)
	var shield: Image = _layer_image(bs, "shield") if with_shield and bs.has_layer("shield") else null
	var shield_mask: Image = _mask_image(bs, "shield") if shield else null
	var r := 0
	for k in pick.size():
		var a: Dictionary = bs.actions[pick[k]]
		var n := int(a["frames"])
		var src := Rect2i(0, int(a["row"]) * frame.y, frame.x * 8, n * frame.y)
		var dst := Vector2i(0, r * frame.y)
		_rgba.blit_rect(body, src, dst)
		if body_mask:
			_mask.blit_rect(body_mask, src, dst)
		if shield:
			_rgba.blend_rect(shield, src, dst)
			_clear_mask_under(shield, src, dst)
			if shield_mask:
				_mask.blit_rect_mask(shield_mask, shield, src, dst)
		_rgba.blend_rect(wpn, src, dst)
		_clear_mask_under(wpn, src, dst)
		actions[names[k]] = [r, n, float(a["fps"]), bool(a["loop"])]
		r += n


## 武器蓋住的像素不換陣營色（用武器的透明度當遮罩，把一張全黑圖貼上去）
var _black: Image
func _clear_mask_under(src_img: Image, src: Rect2i, dst: Vector2i) -> void:
	if _black == null or _black.get_size() != src_img.get_size():
		_black = Image.create_empty(src_img.get_width(), src_img.get_height(), false, Image.FORMAT_L8)
	_mask.blit_rect_mask(_black, src_img, src, dst)


## 騎兵：馬（gallop、idle）＋騎士（ride_idle、ride_attack_a）依錨點合成；death 用騎士倒地
func _compose_cavalry(horse: BakedSpriteSet, knight: BakedSpriteSet) -> void:
	pixel_size = horse.pixel_size
	frame = Vector2i(maxi(horse.frame_size.x, knight.frame_size.x), horse.frame_size.y + CAV_TOP_PAD)
	origin = Vector2(frame.x * 0.5, horse.origin.y + CAV_TOP_PAD)
	var gallop: Dictionary = horse.actions["gallop"]
	var h_idle: Dictionary = horse.actions["idle"]
	var r_idle: Dictionary = knight.actions["ride_idle"]
	var r_atk: Dictionary = knight.actions["ride_thrust" if knight.has_layer("spear") and knight.has_action("ride_thrust") else "ride_attack_a"]
	var trot: Dictionary = horse.actions.get("trot", gallop)
	var death: Dictionary = knight.actions["death"]
	# 每列 = [馬的列, 騎士的列 或 -1, 只畫騎士倒地]
	var plan: Array = []
	var gf := int(gallop["frames"])
	actions["run"] = [0, gf, float(gallop["fps"]), true]
	for f in gf:
		plan.append([int(gallop["row"]) + f, int(r_idle["row"]) + (f % int(r_idle["frames"])), false])
	var tf := int(trot["frames"])
	actions["walk"] = [plan.size(), tf, float(trot["fps"]), true]
	for f in tf:
		plan.append([int(trot["row"]) + f, int(r_idle["row"]) + (f % int(r_idle["frames"])), false])
	# 攻擊兩種：移動中（馬繼續跑）與原地（馬站著），騎士動作一樣
	var af := int(r_atk["frames"])
	actions["walk_attack"] = [plan.size(), af, float(r_atk["fps"]), false]
	for f in af:
		plan.append([int(gallop["row"]) + (f % gf), int(r_atk["row"]) + f, false])
	var hf := int(h_idle["frames"])
	actions["attack"] = [plan.size(), af, float(r_atk["fps"]), false]
	for f in af:
		plan.append([int(h_idle["row"]) + (f % hf), int(r_atk["row"]) + f, false])
	actions["idle"] = [plan.size(), hf, float(h_idle["fps"]), true]
	for f in hf:
		plan.append([int(h_idle["row"]) + f, int(r_idle["row"]) + (f % int(r_idle["frames"])), false])
	var df := int(death["frames"])
	actions["death"] = [plan.size(), df, float(death["fps"]), false]
	for f in df:
		plan.append([-1, int(death["row"]) + f, true])
	rows = plan.size()
	_rgba = Image.create_empty(frame.x * 8, frame.y * rows, false, Image.FORMAT_RGBA8)
	_mask = Image.create_empty(frame.x * 8, frame.y * rows, false, Image.FORMAT_L8)
	var h_img := _layer_image(horse, "horse")
	var h_mask := _mask_image(horse, "horse")
	var k_body := _layer_image(knight, "body")
	var k_mask := _mask_image(knight, "body")
	var k_wpn := _layer_image(knight, "spear" if knight.has_layer("spear") else "sword")
	var k_sh: Image = _layer_image(knight, "shield") if knight.has_layer("shield") else null
	var k_sh_mask: Image = _mask_image(knight, "shield") if k_sh else null
	var hfs := horse.frame_size
	var kfs := knight.frame_size
	for r in plan.size():
		var hr: int = plan[r][0]
		var kr: int = plan[r][1]
		for col in 8:
			var cell := Vector2i(col * frame.x, r * frame.y)
			# 馬：原點對齊合成幀的原點
			var hdst := cell + Vector2i(int(origin.x - horse.origin.x), int(origin.y - horse.origin.y))
			if hr >= 0:
				var hsrc := Rect2i(col * hfs.x, hr * hfs.y, hfs.x, hfs.y)
				_rgba.blend_rect(h_img, hsrc, hdst)
				if h_mask:
					_mask.blit_rect_mask(h_mask, h_img, hsrc, hdst)
			# 騎士：seat 錨點貼到 saddle 錨點（倒地時改成原點對原點）
			var kdst: Vector2i
			if plan[r][2]:
				kdst = cell + Vector2i(int(origin.x - knight.origin.x), int(origin.y - knight.origin.y))
			else:
				var saddle := horse.anchors.get_point("saddle", col, hr)
				var seat := knight.anchors.get_point("seat", col, kr)
				kdst = hdst + Vector2i(int(round(saddle.x - seat.x)), int(round(saddle.y - seat.y)))
			var ksrc := Rect2i(col * kfs.x, kr * kfs.y, kfs.x, kfs.y)
			_rgba.blend_rect(k_body, ksrc, kdst)
			if k_mask:
				_mask.blit_rect_mask(k_mask, k_body, ksrc, kdst)
			if k_sh:
				_rgba.blend_rect(k_sh, ksrc, kdst)
				_clear_mask_under(k_sh, ksrc, kdst)
				if k_sh_mask:
					_mask.blit_rect_mask(k_sh_mask, k_sh, ksrc, kdst)
			_rgba.blend_rect(k_wpn, ksrc, kdst)
			_clear_mask_under(k_wpn, ksrc, kdst)
