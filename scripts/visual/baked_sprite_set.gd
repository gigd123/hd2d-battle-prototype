class_name BakedSpriteSet
extends RefCounted
## 讀取烘焙器（tools/sprite_baker）輸出的分層像素圖集。
##
## 一組 = 一個 sprites.json ＋ 每個圖層一張 PNG（＋可選的陣營色遮罩）。
## 圖集排法與佔位圖相同：8 欄方向 × N 列動作幀，所以 LayeredActorVisual 不用知道圖是怎麼來的。
## 也可以把烘焙結果拿去修圖後放回同一個位置，只要尺寸與排法不變，程式完全不用改。

const ART_ROOT := "res://art/baked/"

var set_name := ""
var dir := ""
var frame_size := Vector2i(64, 64)
var pixel_size := 0.045
var origin := Vector2(32, 64)
var rows := 1
## 動作名 → {row, frames, fps, loop}
var actions: Dictionary = {}
## 圖層名 → {image, team_mask, default_visible}
var layers: Dictionary = {}
var layer_order: Array[String] = []
var anchors: AnchorSet

static var _cache: Dictionary = {}
var _tex_cache: Dictionary = {}
var _img_cache: Dictionary = {}


## 依名稱載入（res://art/baked/<name>/sprites.json）；不存在回傳 null，呼叫端改用佔位圖。
static func get_set(name: String) -> BakedSpriteSet:
	if _cache.has(name):
		return _cache[name]
	var s := BakedSpriteSet.new()
	if not s._load(ART_ROOT + name):
		s = null
	_cache[name] = s
	return s


func _load(p_dir: String) -> bool:
	var path := p_dir.path_join("sprites.json")
	if not FileAccess.file_exists(path):
		return false
	var meta = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(meta) != TYPE_DICTIONARY:
		push_warning("BakedSpriteSet：sprites.json 格式錯誤 " + path)
		return false
	dir = p_dir
	set_name = meta.get("name", p_dir.get_file())
	frame_size = Vector2i(int(meta["frame_size"][0]), int(meta["frame_size"][1]))
	pixel_size = float(meta["pixel_size"])
	origin = Vector2(float(meta["origin"][0]), float(meta["origin"][1]))
	rows = int(meta["rows"])
	actions = meta["actions"]
	for L in meta["layers"]:
		layers[L["name"]] = L
		layer_order.append(L["name"])
	anchors = AnchorSet.new()
	anchors.frame_size = frame_size
	anchors.columns = 8
	anchors.rows = rows
	anchors.pixel_size = pixel_size
	anchors.origin = origin
	var am: Dictionary = meta.get("anchors", {})
	for an in am:
		var flat: Array = am[an]
		var arr := PackedVector2Array()
		arr.resize(flat.size() / 2)
		for i in arr.size():
			arr[i] = Vector2(flat[i * 2], flat[i * 2 + 1])
		anchors.points[an] = arr
	return true


func has_action(action: String) -> bool:
	return actions.has(action)


func has_layer(layer: String) -> bool:
	return layers.has(layer)


## 依「動作開始後經過的秒數」取列號（循環動作會繞回，非循環停在最後一幀）
func row_at_time(action: String, t: float) -> int:
	var a: Dictionary = actions.get(action, {})
	if a.is_empty():
		return 0
	var frames := int(a["frames"])
	var f := int(floor(t * float(a["fps"])))
	f = posmod(f, frames) if a["loop"] else clampi(f, 0, frames - 1)
	return int(a["row"]) + f


## 依「進度 0..1」取列號（揮擊這種跟遊戲計時對齊的動作用）
func row_at_progress(action: String, p: float) -> int:
	var a: Dictionary = actions.get(action, {})
	if a.is_empty():
		return 0
	var frames := int(a["frames"])
	var f := clampi(int(floor(p * frames)), 0, frames - 1)
	if a["loop"]:
		f = posmod(int(floor(p * frames)), frames)
	return int(a["row"]) + f


## 圖層貼圖；tint 不是透明色時，陣營色遮罩內的像素乘上 tint（保留原本的明暗）
func texture(layer: String, tint := Color(0, 0, 0, 0)) -> Texture2D:
	var key := layer + "|" + (tint.to_html() if tint.a > 0.0 else "-")
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img := _image(layers[layer]["image"])
	if img == null:
		return null
	if tint.a > 0.0 and layers[layer].has("team_mask"):
		var mask := _image(layers[layer]["team_mask"])
		img = img.duplicate()
		var data := img.get_data()
		var md := mask.get_data()
		var w := img.get_width()
		var mw := mask.get_width()
		for y in img.get_height():
			for x in w:
				if md[y * mw + x] > 127:
					var i := (y * w + x) * 4
					data[i] = int(data[i] * tint.r)
					data[i + 1] = int(data[i + 1] * tint.g)
					data[i + 2] = int(data[i + 2] * tint.b)
		img = Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


## 釋放某個圖層的貼圖與影像快取（換武器時把用不到的武器圖層丟掉）
func release_layer(layer: String) -> void:
	for k in _tex_cache.keys():
		if (k as String).begins_with(layer + "|"):
			_tex_cache.erase(k)
	if layers.has(layer):
		_img_cache.erase(layers[layer]["image"])


## 優先用編輯器匯入的資源（匯出遊戲時也有效），沒有匯入過就直接讀 PNG 檔（開發時方便）
func _image(file: String) -> Image:
	if _img_cache.has(file):
		return _img_cache[file]
	var path := dir.path_join(file)
	var img: Image = null
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex:
			img = tex.get_image()
	if img == null:
		img = Image.load_from_file(ProjectSettings.globalize_path(path))
	if img:
		if img.is_compressed():
			img.decompress()
		if file.ends_with("_team.png"):
			img.convert(Image.FORMAT_L8)
		else:
			img.convert(Image.FORMAT_RGBA8)
	_img_cache[file] = img
	return img
