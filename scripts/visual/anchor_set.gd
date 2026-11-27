class_name AnchorSet
extends Resource
## 一組精靈圖集的錨點資料。
##
## 研究報告的建議：馬、騎士、武器各是一層，用「馬的當前幀提供的錨點」定位其他層。
## 原型用程式產生的佔位圖，錨點也由程式填入；之後換成正式美術時，
## 只要從 Aseprite 匯出的 JSON 轉成同樣的資料即可，視覺代理的程式不用改。
##
## 座標單位是「圖集內單幀的像素」，原點在幀的左上角。

@export var frame_size := Vector2i(16, 16)
@export var columns := 8
@export var rows := 1
## 每像素對應的世界公尺數（與 Sprite3D.pixel_size 相同）
@export var pixel_size := 0.06
## name -> PackedVector2Array（索引 = row * columns + col）
@export var points: Dictionary = {}
## 精靈「原點」（對應角色腳底中心）在幀內的像素座標；(-1,-1) = 幀底部中央（佔位圖的慣例）。
## 預渲染的圖會在腳下留邊（斜看時前腳會低於原點），所以原點不一定在最底下。
@export var origin := Vector2(-1, -1)
## 每個方向欄位的圖層順序：+1 = 此層的「附掛層」畫在前面，-1 = 畫在後面
@export var attach_layer: PackedInt32Array = PackedInt32Array()


func set_point(point_name: String, col: int, row: int, p: Vector2) -> void:
	if not points.has(point_name):
		var arr := PackedVector2Array()
		arr.resize(columns * rows)
		points[point_name] = arr
	var a: PackedVector2Array = points[point_name]
	a[row * columns + col] = p
	points[point_name] = a


func get_point(point_name: String, col: int, row: int) -> Vector2:
	var a: PackedVector2Array = points.get(point_name, PackedVector2Array())
	var i := row * columns + col
	if i < 0 or i >= a.size():
		return Vector2(frame_size.x * 0.5, frame_size.y)
	return a[i]


## 把幀內像素座標換成「相對於精靈原點（腳底中心）」的公尺偏移：x 向畫面右、y 向上。
## flip：此幀是否水平翻轉（鏡像模式）。
func to_offset(p: Vector2, flip: bool) -> Vector2:
	var o := origin_px()
	var x := p.x - o.x
	if flip:
		x = -x
	return Vector2(x * pixel_size, (o.y - p.y) * pixel_size)


func origin_px() -> Vector2:
	return origin if origin.x >= 0.0 else Vector2(frame_size.x * 0.5, frame_size.y)


func layer_for(col: int) -> int:
	if col < 0 or col >= attach_layer.size():
		return 1
	return attach_layer[col]
