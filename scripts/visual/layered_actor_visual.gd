class_name LayeredActorVisual
extends Node3D
## 單一角色的「視覺代理」：主圖層＋（可選）附掛圖層＋腳下圓形陰影。
##
## 例：馬是主圖層，騎士是附掛圖層，騎士的「座位錨點」對齊馬當前幀的「鞍座錨點」。
## 這個節點設為 top_level，只接收邏輯層給的位置、朝向、動作列，自己不做任何遊戲邏輯；
## 之後換成預渲染 3D、MultiMesh 或別的畫法，只要提供同樣的 update_visual() 即可。
##
## 預渲染圖（BakedSpriteSet）多一種「疊加層」：同一次烘焙出來的身體、武器共用同一個原點與幀，
## 直接疊在一起即可（遮擋已在烘焙時處理好），換武器只要換疊加層的貼圖或開關它。

const SPRITE_LAYER := 2          # Sprite 放在第 2 層，避免被陰影 Decal 投到
const LAYER_GAP := 0.08          # 前後圖層沿鏡頭方向的距離（公尺）
const OVERLAY_GAP := 0.02        # 疊加層（武器等）在本體前方的距離

var main_sprite: Sprite3D
var attach_sprite: Sprite3D
var main_anchors: AnchorSet
var attach_anchors: AnchorSet
var parent_point := "saddle"
var child_point := "seat"
var shadow: Decal
## 疊加層：圖層名 → Sprite3D（跟主圖層／附掛圖層同幀同位置）
var main_overlays: Dictionary = {}
var attach_overlays: Dictionary = {}

## 最近一次更新的結果（給除錯與命中判定參考用）
var last_column := 0
var last_flip := false
var last_attach_origin := Vector3.ZERO


func _init() -> void:
	top_level = true


## origin：精靈原點（腳底中心）在幀內的像素座標；(-1,-1) = 幀底部中央
static func make_sprite(tex: Texture2D, frame_size: Vector2i, rows: int, pixel_size := PlaceholderArt.PIXEL_SIZE, origin := Vector2(-1, -1)) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = tex
	s.hframes = 8
	s.vframes = rows
	s.pixel_size = pixel_size
	s.billboard = GameConfig.billboard_mode()
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.centered = true
	# 讓精靈的原點落在節點原點
	var o := origin if origin.x >= 0.0 else Vector2(frame_size.x * 0.5, frame_size.y)
	s.offset = Vector2(frame_size.x * 0.5 - o.x, o.y - frame_size.y * 0.5)
	s.layers = 1 << (SPRITE_LAYER - 1)
	return s


func setup_main(tex: Texture2D, frame_size: Vector2i, rows: int, anchors: AnchorSet = null, shadow_size := 1.2, pixel_size := PlaceholderArt.PIXEL_SIZE, origin := Vector2(-1, -1)) -> void:
	main_sprite = make_sprite(tex, frame_size, rows, pixel_size, origin)
	main_sprite.name = "Main"
	main_anchors = anchors
	add_child(main_sprite)
	shadow = Decal.new()
	shadow.name = "BlobShadow"
	shadow.texture_albedo = PlaceholderArt.blob_shadow()
	shadow.size = Vector3(shadow_size, 3.0, shadow_size)
	shadow.cull_mask = 1
	shadow.upper_fade = 0.3
	shadow.lower_fade = 0.3
	add_child(shadow)


func setup_attach(tex: Texture2D, frame_size: Vector2i, rows: int, anchors: AnchorSet, p_parent_point: String, p_child_point: String, pixel_size := PlaceholderArt.PIXEL_SIZE, origin := Vector2(-1, -1)) -> void:
	attach_sprite = make_sprite(tex, frame_size, rows, pixel_size, origin)
	attach_sprite.name = "Attach"
	attach_anchors = anchors
	parent_point = p_parent_point
	child_point = p_child_point
	add_child(attach_sprite)
	attach_sprite.visible = false


## 用預渲染圖集建立主圖層：layer_names[0] 是本體，其餘是疊加層（武器等）
func setup_main_baked(bs: BakedSpriteSet, layer_names: Array, tint := Color(0, 0, 0, 0), shadow_size := 1.2) -> void:
	setup_main(bs.texture(layer_names[0], tint), bs.frame_size, bs.rows, bs.anchors, shadow_size, bs.pixel_size, bs.origin)
	for i in range(1, layer_names.size()):
		var s := make_sprite(bs.texture(layer_names[i], tint), bs.frame_size, bs.rows, bs.pixel_size, bs.origin)
		s.name = "Overlay_" + layer_names[i]
		add_child(s)
		main_overlays[layer_names[i]] = s


func setup_attach_baked(bs: BakedSpriteSet, layer_names: Array, p_parent_point: String, p_child_point: String, tint := Color(0, 0, 0, 0)) -> void:
	setup_attach(bs.texture(layer_names[0], tint), bs.frame_size, bs.rows, bs.anchors, p_parent_point, p_child_point, bs.pixel_size, bs.origin)
	for i in range(1, layer_names.size()):
		var s := make_sprite(bs.texture(layer_names[i], tint), bs.frame_size, bs.rows, bs.pixel_size, bs.origin)
		s.name = "AttachOverlay_" + layer_names[i]
		s.visible = false
		add_child(s)
		attach_overlays[layer_names[i]] = s


## 整個角色（含疊加層）乘上顏色：受擊閃紅等
func set_tint(c: Color) -> void:
	for n in get_children():
		if n is Sprite3D:
			(n as Sprite3D).modulate = c


## 只染附掛圖層（騎士）
func set_attach_tint(c: Color) -> void:
	if attach_sprite:
		attach_sprite.modulate = c
	for k in attach_overlays:
		(attach_overlays[k] as Sprite3D).modulate = c


func set_attach_visible(v: bool) -> void:
	if attach_sprite:
		attach_sprite.visible = v
	for k in attach_overlays:
		(attach_overlays[k] as Sprite3D).visible = v


## world_pos：角色腳底位置；facing：水平朝向；main_row / attach_row：動作列。
func update_visual(world_pos: Vector3, facing: Vector3, cam: Camera3D, main_row: int, attach_row := 0) -> void:
	if cam == null:
		return
	var cam_basis := cam.global_basis
	var dir := DirectionUtil.resolve(facing, cam_basis)
	last_column = dir.x
	last_flip = dir.y == 1
	var bb := GameConfig.billboard_mode()
	var st := GameConfig.billboard_stretch(cam)
	var sc := Vector3(1.0, st, 1.0)
	for n in get_children():
		if n is Sprite3D:
			(n as Sprite3D).scale = sc
	main_sprite.global_position = world_pos
	main_sprite.frame = main_row * 8 + dir.x
	main_sprite.flip_h = last_flip
	main_sprite.billboard = bb
	shadow.global_position = world_pos + Vector3(0, 0.5, 0)
	var to_cam := cam.global_position - world_pos
	to_cam.y = 0
	to_cam = to_cam.normalized() if to_cam.length_squared() > 0.0001 else Vector3.BACK
	var k := 1
	for key in main_overlays:
		var o: Sprite3D = main_overlays[key]
		o.global_position = world_pos + to_cam * (OVERLAY_GAP * k)
		o.frame = main_sprite.frame
		o.flip_h = last_flip
		o.billboard = bb
		k += 1
	if attach_sprite and attach_sprite.visible and main_anchors and attach_anchors:
		var cam_right := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
		var p := main_anchors.to_offset(main_anchors.get_point(parent_point, dir.x, main_row), last_flip)
		var c := attach_anchors.to_offset(attach_anchors.get_point(child_point, dir.x, attach_row), last_flip)
		var layer := main_anchors.layer_for(dir.x)
		# 錨點的「上」方向要跟 Billboard 方式一致，騎士才會黏在鞍上
		var up := cam_basis.y if GameConfig.full_billboard else Vector3.UP
		var right := cam_basis.x if GameConfig.full_billboard else cam_right
		last_attach_origin = world_pos + right * p.x + up * p.y
		last_attach_origin = world_pos + right * p.x + up * p.y * st
		var pos := world_pos + right * (p.x - c.x) + up * (p.y - c.y) * st + to_cam * (LAYER_GAP * layer)
		attach_sprite.global_position = pos
		attach_sprite.frame = attach_row * 8 + dir.x
		attach_sprite.flip_h = last_flip
		attach_sprite.billboard = bb
		k = 1
		for key in attach_overlays:
			var o: Sprite3D = attach_overlays[key]
			o.global_position = pos + to_cam * (OVERLAY_GAP * k)
			o.frame = attach_sprite.frame
			o.flip_h = last_flip
			o.billboard = bb
			k += 1
