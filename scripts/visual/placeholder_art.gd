class_name PlaceholderArt
extends RefCounted
## 程式產生的佔位像素圖（原型階段不投入正式美術）。
##
## 所有圖集都按「8 個方向欄 × N 個動作列」排列，與 DirectionUtil 的欄位定義一致。
## 圖形刻意簡單：色塊人形、簡單馬形，但仍按「馬／騎士（含武器）」分層並附錨點，
## 以驗證分層同步機制。正式美術只要遵守同樣的欄列規格與錨點資料即可替換。
##
## 全部是原創佔位圖形，不引用任何既有遊戲素材。

const PIXEL_SIZE := 0.06

# 士兵／步行角色：8 欄 × 4 列（0 待機/走 A、1 走 B、2 攻擊、3 倒地）
const HUMAN_FRAME := Vector2i(20, 30)
const HUMAN_ROWS := 4
const ROW_IDLE := 0
const ROW_WALK := 1
const ROW_ATTACK := 2
const ROW_DEAD := 3

# 馬：8 欄 × 2 列（0 站立/奔馳 A、1 奔馳 B）
const HORSE_FRAME := Vector2i(48, 36)
const HORSE_ROWS := 2

# 騎士（馬上上半身）：8 欄 × 3 列（0 待機、1 蓄力、2 揮擊）
const RIDER_FRAME := Vector2i(22, 24)
const RIDER_ROWS := 3
const RIDER_IDLE := 0
const RIDER_WINDUP := 1
const RIDER_SWING := 2

# 騎兵（馬＋騎士合成一張）：8 欄 × 4 列（0 奔馳 A、1 奔馳 B、2 攻擊、3 倒地）
const CAV_FRAME := Vector2i(48, 48)
const CAV_ROWS := 4

## 兵種（與 BattleManager.UnitType 相同順序）
enum Unit { INFANTRY, ARCHER, CAVALRY }

## 陣營色遮罩：純白 (1,1,1) 的像素是「可換色」區域（調色盤交換），其餘顏色保持原樣
const TEAM_MASK := Color(1, 1, 1)

const OUTLINE := Color(0.08, 0.07, 0.10, 1.0)

static var _cache: Dictionary = {}


# ---------------------------------------------------------------------------
# 對外 API（結果會快取，多次呼叫共用同一張貼圖）
# ---------------------------------------------------------------------------
static func human_atlas() -> Texture2D:
	return unit_atlas(Unit.INFANTRY)


## 兵種圖集（白色衣服＝陣營色遮罩，給 MultiMesh 著色器做調色盤交換）
static func unit_atlas(unit: int) -> Texture2D:
	var key := "unit_%d" % unit
	if not _cache.has(key):
		_cache[key] = ImageTexture.create_from_image(_unit_image(unit))
	return _cache[key]


## 已換好陣營色的兵種圖集（給 Sprite3D 用；在 CPU 上把遮罩像素乘上陣營色）
static func unit_atlas_tinted(unit: int, tint: Color) -> Texture2D:
	var key := "unit_%d_%s" % [unit, tint.to_html()]
	if not _cache.has(key):
		var img: Image = _unit_image(unit).duplicate()
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.a > 0.5 and c.r > 0.99 and c.g > 0.99 and c.b > 0.99:
					img.set_pixel(x, y, Color(tint.r, tint.g, tint.b, 1.0))
		_cache[key] = ImageTexture.create_from_image(img)
	return _cache[key]


static func unit_frame(unit: int) -> Vector2i:
	return CAV_FRAME if unit == Unit.CAVALRY else HUMAN_FRAME


static func unit_rows(unit: int) -> int:
	return CAV_ROWS if unit == Unit.CAVALRY else HUMAN_ROWS


static func _unit_image(unit: int) -> Image:
	var key := "img_%d" % unit
	if not _cache.has(key):
		match unit:
			Unit.ARCHER:
				_cache[key] = _build_human(true)
			Unit.CAVALRY:
				_cache[key] = _build_cavalry()
			_:
				_cache[key] = _build_human(false)
	return _cache[key]


static func horse_atlas() -> Texture2D:
	if not _cache.has("horse"):
		_build_horse_and_anchors()
	return _cache["horse"]


static func horse_anchors() -> AnchorSet:
	if not _cache.has("horse_anchors"):
		_build_horse_and_anchors()
	return _cache["horse_anchors"]


static func rider_atlas() -> Texture2D:
	if not _cache.has("rider"):
		_build_rider_and_anchors()
	return _cache["rider"]


static func rider_anchors() -> AnchorSet:
	if not _cache.has("rider_anchors"):
		_build_rider_and_anchors()
	return _cache["rider_anchors"]


static func blob_shadow() -> Texture2D:
	if not _cache.has("shadow"):
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		for y in 32:
			for x in 32:
				var d := Vector2((x - 15.5) / 15.5, (y - 15.5) / 15.5).length()
				var a := clampf(1.0 - d, 0.0, 1.0)
				a = smoothstep(0.0, 0.6, a) * 0.55
				img.set_pixel(x, y, Color(0, 0, 0, a))
		_cache["shadow"] = ImageTexture.create_from_image(img)
	return _cache["shadow"]


static func tree_texture() -> Texture2D:
	if not _cache.has("tree"):
		var w := 28
		var h := 44
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_rect(img, 12, 30, 4, 14, Color(0.36, 0.24, 0.15))
		var greens := [Color(0.16, 0.34, 0.18), Color(0.22, 0.44, 0.22), Color(0.30, 0.54, 0.26)]
		var blobs := [[14, 22, 11], [9, 16, 8], [19, 15, 8], [14, 9, 8]]
		for i in blobs.size():
			var b: Array = blobs[i]
			_disc(img, b[0], b[1], b[2], greens[0])
		for i in blobs.size():
			var b: Array = blobs[i]
			_disc(img, b[0] - 1, b[1] - 2, b[2] - 3, greens[1])
		_disc(img, 12, 10, 4, greens[2])
		_disc(img, 8, 15, 3, greens[2])
		_outline(img, Rect2i(0, 0, w, h))
		_cache["tree"] = ImageTexture.create_from_image(img)
	return _cache["tree"]


# ---------------------------------------------------------------------------
# 步行人形
# ---------------------------------------------------------------------------
static func _build_human(archer: bool) -> Image:
	var fw := HUMAN_FRAME.x
	var fh := HUMAN_FRAME.y
	var img := Image.create(fw * 8, fh * HUMAN_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for col in 8:
		var a := col * TAU / 8.0
		var sx := sin(a)          # >0：面向畫面右
		var toward := cos(a)      # >0：面向鏡頭
		for row in HUMAN_ROWS:
			var ox := col * fw
			var oy := row * fh
			if row == ROW_DEAD:
				_draw_human_dead(img, ox, oy, sx)
			else:
				_draw_human(img, ox, oy, sx, toward, row, archer)
			_outline(img, Rect2i(ox, oy, fw, fh))
	return img


static func _draw_human(img: Image, ox: int, oy: int, sx: float, toward: float, row: int, archer := false) -> void:
	var cx := ox + 10
	var side := absf(sx) > 0.6
	var body := TEAM_MASK                    # 會被換成陣營色
	var dark := Color(0.35, 0.33, 0.36)
	var skin := Color(0.92, 0.80, 0.68)
	var metal := Color(0.70, 0.72, 0.78)
	var wood := Color(0.55, 0.42, 0.30)
	# 腿
	var leg_y := oy + 22
	if row == ROW_WALK:
		if side:
			_rect(img, cx - 4, leg_y, 2, 7, dark)
			_rect(img, cx + 2, leg_y, 2, 7, dark)
		else:
			_rect(img, cx - 3, leg_y, 2, 7, dark)
			_rect(img, cx + 1, leg_y, 2, 5, dark)
	else:
		_rect(img, cx - 3, leg_y, 2, 7, dark)
		_rect(img, cx + 1, leg_y, 2, 7, dark)
	# 身體
	var bw := 6 if side else 8
	_rect(img, cx - bw / 2, oy + 12, bw, 10, body)
	_rect(img, cx - bw / 2, oy + 19, bw, 1, dark)
	# 頭與頭盔
	_rect(img, cx - 3, oy + 5, 6, 7, skin)
	_rect(img, cx - 3, oy + 4, 6, 3, metal)
	if toward < -0.3:
		_rect(img, cx - 3, oy + 7, 6, 4, Color(0.30, 0.22, 0.16))  # 後腦
	else:
		var ex := cx + roundi(sx * 2.0)
		if side:
			_px(img, ex, oy + 8, OUTLINE)
		else:
			_px(img, ex - 1, oy + 8, OUTLINE)
			_px(img, ex + 2, oy + 8, OUTLINE)
	# 武器（長槍）與盾：右手的畫面位置隨朝向改變
	var hand_x := cx + roundi(-toward * 5.0 + sx * 1.0)
	var shield_x := cx + roundi(toward * 5.0 - sx * 1.0)
	if archer:
		_draw_bow(img, cx, oy, sx, toward, row, hand_x, wood)
		# 弓兵：帽子取代頭盔、背上箭袋
		_rect(img, cx - 3, oy + 4, 6, 2, Color(0.30, 0.45, 0.25))
		if toward < 0.3:
			_rect(img, cx + roundi(toward * 3.0) - 1, oy + 11, 3, 8, Color(0.45, 0.30, 0.20))
		return
	if row == ROW_ATTACK:
		var tip := Vector2i(cx + roundi(sx * 9.0), oy + 9 + roundi(maxf(toward, 0.0) * 3.0))
		_line(img, Vector2i(hand_x, oy + 17), tip, wood)
		_px(img, tip.x, tip.y, Color(0.95, 0.95, 1.0))
	else:
		_rect(img, hand_x, oy + 2, 1, 24, wood)
		_rect(img, hand_x, oy + 1, 1, 2, Color(0.95, 0.95, 1.0))
	if toward > -0.5:
		_rect(img, shield_x - 2, oy + 13, 4, 6, Color(0.60, 0.60, 0.62))


## 弓：待機時垂直握在手邊；攻擊列＝拉弓瞄準前方（弓身往朝向那側伸出）
static func _draw_bow(img: Image, cx: int, oy: int, sx: float, toward: float, row: int, hand_x: int, wood: Color) -> void:
	var string_c := Color(0.85, 0.85, 0.80)
	if row == ROW_ATTACK:
		var bx := cx + roundi(sx * 7.0)
		var by := oy + 13
		var bend := 1 if sx >= 0.0 else -1
		if absf(sx) < 0.4:
			# 正面／背面：弓橫在胸前
			_line(img, Vector2i(cx - 6, by - 1), Vector2i(cx + 6, by - 1), wood)
			_px(img, cx - 6, by, wood)
			_px(img, cx + 6, by, wood)
		else:
			_line(img, Vector2i(bx, by - 6), Vector2i(bx + bend, by), wood)
			_line(img, Vector2i(bx + bend, by), Vector2i(bx, by + 6), wood)
			_line(img, Vector2i(bx, by - 6), Vector2i(cx - bend, by), string_c)
			_line(img, Vector2i(cx - bend, by), Vector2i(bx, by + 6), string_c)
	else:
		_line(img, Vector2i(hand_x, oy + 7), Vector2i(hand_x + 1, oy + 15), wood)
		_line(img, Vector2i(hand_x + 1, oy + 15), Vector2i(hand_x, oy + 23), wood)
		_line(img, Vector2i(hand_x, oy + 7), Vector2i(hand_x, oy + 23), string_c)


static func _draw_human_dead(img: Image, ox: int, oy: int, sx: float) -> void:
	var dir := 1 if sx >= 0.0 else -1
	var cx := ox + 10
	_rect(img, cx - 6, oy + 24, 12, 4, TEAM_MASK)
	_rect(img, cx + dir * 6 - (2 if dir < 0 else 0), oy + 23, 4, 5, Color(0.92, 0.80, 0.68))
	_line(img, Vector2i(ox + 2, oy + 28), Vector2i(ox + 18, oy + 26), Color(0.55, 0.42, 0.30))


# ---------------------------------------------------------------------------
# 馬（含鞍座錨點）
# ---------------------------------------------------------------------------
static func _build_horse_and_anchors() -> void:
	var fw := HORSE_FRAME.x
	var fh := HORSE_FRAME.y
	var img := Image.create(fw * 8, fh * HORSE_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var anchors := AnchorSet.new()
	anchors.frame_size = HORSE_FRAME
	anchors.columns = 8
	anchors.rows = HORSE_ROWS
	anchors.pixel_size = PIXEL_SIZE
	anchors.attach_layer.resize(8)
	var coat := Color(0.55, 0.36, 0.22)
	var coat_dark := Color(0.40, 0.25, 0.15)
	var mane := Color(0.18, 0.12, 0.10)
	var saddle := Color(0.55, 0.12, 0.12)
	for col in 8:
		var a := col * TAU / 8.0
		var sx := sin(a)
		var toward := cos(a)
		var s := absf(sx)
		var dir := 1 if sx >= 0.0 else -1
		# 面向鏡頭時，馬頭在騎士前面；其餘方向騎士在前
		anchors.attach_layer[col] = -1 if toward > 0.6 else 1
		for row in HORSE_ROWS:
			var ox := col * fw
			var oy := row * fh
			var cx := ox + fw / 2
			var body_len := int(lerpf(12.0, 32.0, s))
			var body_top := oy + 14
			var bob := 1 if row == 1 else 0
			# 尾巴（頭的反方向；背對時在正中）
			if toward < 0.6:
				var tail_x := cx - dir * (body_len / 2 + 1) if s > 0.3 else cx
				_rect(img, tail_x - 1, body_top + 1 - bob, 3, 11, mane)
			# 腿：奔馳兩幀交錯
			var leg_xs: Array[int] = []
			if s > 0.3:
				leg_xs = [cx - body_len / 2 + 2, cx - body_len / 2 + 5, cx + body_len / 2 - 6, cx + body_len / 2 - 3]
			else:
				leg_xs = [cx - 5, cx - 2, cx + 1, cx + 4]
			for i in 4:
				var lift := 0
				if row == 1:
					lift = 3 if i % 2 == 0 else 0
				else:
					lift = 0 if i % 2 == 0 else 2
				var lc := coat_dark if i % 2 == 1 else coat
				_rect(img, leg_xs[i] - 1, body_top + 10 - bob, 3, 11 - lift, lc)
				_rect(img, leg_xs[i] - 1, body_top + 20 - bob - lift, 3, 1, mane)
			# 身體
			_rect(img, cx - body_len / 2, body_top - bob, body_len, 11, coat)
			_rect(img, cx - body_len / 2, body_top + 8 - bob, body_len, 3, coat_dark)
			# 鞍
			var saddle_x := cx - dir * roundi(s * 3.0)
			_rect(img, saddle_x - 4, body_top - 1 - bob, 8, 4, saddle)
			# 頭頸
			if s > 0.3:
				var hx := cx + dir * (body_len / 2 - 1)
				_rect(img, hx - 2, body_top - 8 - bob, 5, 10, coat)          # 頸
				_rect(img, hx - 2 + dir * 2, body_top - 10 - bob, 6, 5, coat)  # 頭
				_rect(img, hx - 3 - (dir * 1), body_top - 9 - bob, 2, 8, mane)  # 鬃
				_px(img, hx + dir * 4, body_top - 9 - bob, OUTLINE)           # 眼
			elif toward >= 0.0:
				# 面向鏡頭：頭在身體正前方偏下
				_rect(img, cx - 3, body_top - 9 - bob, 6, 14, coat)
				_rect(img, cx - 2, body_top + 3 - bob, 4, 3, coat_dark)
				_rect(img, cx - 1, body_top - 10 - bob, 2, 6, mane)
				_px(img, cx - 2, body_top - 6 - bob, OUTLINE)
				_px(img, cx + 1, body_top - 6 - bob, OUTLINE)
			else:
				# 背對鏡頭：只看到耳朵
				_rect(img, cx - 3, body_top - 4 - bob, 2, 4, coat)
				_rect(img, cx + 1, body_top - 4 - bob, 2, 4, coat)
			_outline(img, Rect2i(ox, oy, fw, fh))
			# 鞍座錨點（騎士腰部要對齊的位置），奔馳幀會跟著上下起伏
			anchors.set_point("saddle", col, row, Vector2(saddle_x - ox, body_top - bob - oy + 1))
	_cache["horse"] = ImageTexture.create_from_image(img)
	_cache["horse_anchors"] = anchors


# ---------------------------------------------------------------------------
# 騎士（馬上姿勢，含座位錨點與武器尖端錨點）
# ---------------------------------------------------------------------------
static func _build_rider_and_anchors() -> void:
	var img := _build_rider_image(Color(0.25, 0.45, 0.85))   # 玩家固定藍色
	_cache["rider"] = ImageTexture.create_from_image(img)


static func _build_rider_image(body: Color) -> Image:
	var fw := RIDER_FRAME.x
	var fh := RIDER_FRAME.y
	var img := Image.create(fw * 8, fh * RIDER_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var anchors := AnchorSet.new()
	anchors.frame_size = RIDER_FRAME
	anchors.columns = 8
	anchors.rows = RIDER_ROWS
	anchors.pixel_size = PIXEL_SIZE
	var dark := Color(0.20, 0.20, 0.26)
	var skin := Color(0.92, 0.80, 0.68)
	var metal := Color(0.80, 0.82, 0.88)
	var blade := Color(0.95, 0.96, 1.0)
	for col in 8:
		var a := col * TAU / 8.0
		var sx := sin(a)
		var toward := cos(a)
		var side := absf(sx) > 0.6
		for row in RIDER_ROWS:
			var ox := col * fw
			var oy := row * fh
			var cx := ox + fw / 2
			var seat_y := oy + 19
			# 腿（跨坐）：側面只見一條，正背面兩側各一
			if side:
				_rect(img, cx - 1, seat_y - 1, 3, 5, dark)
			else:
				_rect(img, cx - 5, seat_y - 1, 2, 5, dark)
				_rect(img, cx + 3, seat_y - 1, 2, 5, dark)
			# 軀幹與頭
			var bw := 6 if side else 8
			_rect(img, cx - bw / 2, oy + 10, bw, 10, body)
			_rect(img, cx - 3, oy + 3, 6, 7, skin)
			_rect(img, cx - 3, oy + 2, 6, 3, metal)
			if toward < -0.3:
				_rect(img, cx - 3, oy + 5, 6, 4, Color(0.30, 0.22, 0.16))
			else:
				var ex := cx + roundi(sx * 2.0)
				if side:
					_px(img, ex, oy + 6, OUTLINE)
				else:
					_px(img, ex - 1, oy + 6, OUTLINE)
					_px(img, ex + 2, oy + 6, OUTLINE)
			# 劍：右手畫面位置
			var hand := Vector2i(cx + roundi(-toward * 5.0 + sx * 1.0), oy + 14)
			var tip := Vector2i()
			match row:
				RIDER_IDLE:
					tip = Vector2i(hand.x, oy + 5)
				RIDER_WINDUP:
					tip = Vector2i(hand.x - roundi(sx * 5.0), oy + 1)
				_:
					tip = Vector2i(cx + roundi(sx * 10.0), oy + 13 + roundi(maxf(toward, 0.0) * 3.0))
			tip.x = clampi(tip.x, ox + 1, ox + fw - 2)
			tip.y = clampi(tip.y, oy + 1, oy + fh - 2)
			_line(img, hand, tip, blade)
			_rect(img, hand.x - 1, hand.y, 3, 2, Color(0.55, 0.42, 0.30))
			_outline(img, Rect2i(ox, oy, fw, fh))
			anchors.set_point("seat", col, row, Vector2(cx - ox, seat_y - oy))
			anchors.set_point("weapon_tip", col, row, Vector2(tip.x - ox, tip.y - oy))
	_cache["rider_anchors"] = anchors
	return img


# ---------------------------------------------------------------------------
# 繪圖小工具
# ---------------------------------------------------------------------------
static func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)


static func _rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	if w <= 0 or h <= 0:
		return
	var r := Rect2i(x, y, w, h).intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	if r.size.x > 0 and r.size.y > 0:
		img.fill_rect(r, c)


static func _disc(img: Image, cx: int, cy: int, r: int, c: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r:
				_px(img, x, y, c)


static func _line(img: Image, a: Vector2i, b: Vector2i, c: Color) -> void:
	var n := maxi(absi(b.x - a.x), absi(b.y - a.y))
	if n == 0:
		_px(img, a.x, a.y, c)
		return
	for i in n + 1:
		var t := float(i) / float(n)
		_px(img, roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t)), c)


## 在一個幀範圍內，為不透明像素加上 1px 深色外框（提升像素角色在 3D 場景的辨識度）。
static func _outline(img: Image, r: Rect2i) -> void:
	var marks: Array[Vector2i] = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if img.get_pixel(x, y).a > 0.5:
				continue
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if nx < r.position.x or ny < r.position.y or nx >= r.end.x or ny >= r.end.y:
					continue
				var p := img.get_pixel(nx, ny)
				if p.a > 0.5 and p != OUTLINE:
					marks.append(Vector2i(x, y))
					break
	for m in marks:
		img.set_pixel(m.x, m.y, OUTLINE)


# ---------------------------------------------------------------------------
# 騎兵：把馬幀與（白衣）騎士幀依錨點合成一張，給大量士兵用
# ---------------------------------------------------------------------------
static func _build_cavalry() -> Image:
	horse_atlas()                      # 確保馬圖與錨點已產生
	var horse_img: Image = (_cache["horse"] as ImageTexture).get_image()
	var anchors: AnchorSet = _cache["horse_anchors"]
	var rider_img := _build_rider_image(TEAM_MASK)
	var rider_anchors_set: AnchorSet = _cache["rider_anchors"]
	var fw := CAV_FRAME.x
	var fh := CAV_FRAME.y
	var img := Image.create(fw * 8, fh * CAV_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var y_off := fh - HORSE_FRAME.y
	for col in 8:
		var a := col * TAU / 8.0
		var sx := sin(a)
		for row in CAV_ROWS:
			var ox := col * fw
			var oy := row * fh
			if row == 3:
				_draw_cavalry_dead(img, ox, oy, sx)
				continue
			var horse_row := 1 if row == 1 else 0
			var rider_row := RIDER_SWING if row == 2 else RIDER_IDLE
			var saddle := anchors.get_point("saddle", col, horse_row)
			var seat := rider_anchors_set.get_point("seat", col, rider_row)
			var h_src := Rect2i(col * HORSE_FRAME.x, horse_row * HORSE_FRAME.y, HORSE_FRAME.x, HORSE_FRAME.y)
			var r_src := Rect2i(col * RIDER_FRAME.x, rider_row * RIDER_FRAME.y, RIDER_FRAME.x, RIDER_FRAME.y)
			var r_dst := Vector2i(ox + int(saddle.x - seat.x), oy + y_off + int(saddle.y - seat.y))
			if anchors.layer_for(col) < 0:
				img.blend_rect(rider_img, r_src, r_dst)
				img.blend_rect(horse_img, h_src, Vector2i(ox, oy + y_off))
			else:
				img.blend_rect(horse_img, h_src, Vector2i(ox, oy + y_off))
				img.blend_rect(rider_img, r_src, r_dst)
	return img


static func _draw_cavalry_dead(img: Image, ox: int, oy: int, sx: float) -> void:
	var dir := 1 if sx >= 0.0 else -1
	var cx := ox + CAV_FRAME.x / 2
	var by := oy + CAV_FRAME.y - 10
	var coat := Color(0.55, 0.36, 0.22)
	_rect(img, cx - 14, by, 28, 8, coat)                         # 倒地的馬身
	_rect(img, cx + dir * 14 - (5 if dir < 0 else 0), by + 2, 6, 5, coat)   # 頭
	for i in 4:
		_rect(img, cx - 10 + i * 6, by - 3, 2, 4, Color(0.40, 0.25, 0.15))  # 朝上的腿
	_rect(img, cx - dir * 10 - 4, by + 4, 9, 4, TEAM_MASK)        # 摔落的騎士
	_rect(img, cx - dir * 10 + (5 if dir < 0 else -7), by + 3, 3, 4, Color(0.92, 0.80, 0.68))
	_outline(img, Rect2i(ox, oy, CAV_FRAME.x, CAV_FRAME.y))
