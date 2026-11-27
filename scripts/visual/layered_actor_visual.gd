class_name LayeredActorVisual
extends Node3D
## 單一角色的「視覺代理」：主圖層＋（可選）附掛圖層＋腳下圓形陰影。
##
## 例：馬是主圖層，騎士是附掛圖層，騎士的「座位錨點」對齊馬當前幀的「鞍座錨點」。
## 這個節點設為 top_level，只接收邏輯層給的位置、朝向、動作列，自己不做任何遊戲邏輯；
## 之後換成預渲染 3D、MultiMesh 或別的畫法，只要提供同樣的 update_visual() 即可。

const SPRITE_LAYER := 2          # Sprite 放在第 2 層，避免被陰影 Decal 投到
const LAYER_GAP := 0.08          # 前後圖層沿鏡頭方向的距離（公尺）

var main_sprite: Sprite3D
var attach_sprite: Sprite3D
var main_anchors: AnchorSet
var attach_anchors: AnchorSet
var parent_point := "saddle"
var child_point := "seat"
var shadow: Decal

## 最近一次更新的結果（給除錯與命中判定參考用）
var last_column := 0
var last_flip := false
var last_attach_origin := Vector3.ZERO


func _init() -> void:
	top_level = true


static func make_sprite(tex: Texture2D, frame_size: Vector2i, rows: int) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = tex
	s.hframes = 8
	s.vframes = rows
	s.pixel_size = PlaceholderArt.PIXEL_SIZE
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.shaded = false
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.centered = true
	# 讓精靈的「腳底中心」落在節點原點
	s.offset = Vector2(0, frame_size.y * 0.5)
	s.layers = 1 << (SPRITE_LAYER - 1)
	return s


func setup_main(tex: Texture2D, frame_size: Vector2i, rows: int, anchors: AnchorSet = null, shadow_size := 1.2) -> void:
	main_sprite = make_sprite(tex, frame_size, rows)
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


func setup_attach(tex: Texture2D, frame_size: Vector2i, rows: int, anchors: AnchorSet, p_parent_point: String, p_child_point: String) -> void:
	attach_sprite = make_sprite(tex, frame_size, rows)
	attach_sprite.name = "Attach"
	attach_anchors = anchors
	parent_point = p_parent_point
	child_point = p_child_point
	add_child(attach_sprite)
	attach_sprite.visible = false


func set_attach_visible(v: bool) -> void:
	if attach_sprite:
		attach_sprite.visible = v


## world_pos：角色腳底位置；facing：水平朝向；main_row / attach_row：動作列。
func update_visual(world_pos: Vector3, facing: Vector3, cam: Camera3D, main_row: int, attach_row := 0) -> void:
	if cam == null:
		return
	var cam_basis := cam.global_basis
	var dir := DirectionUtil.resolve(facing, cam_basis)
	last_column = dir.x
	last_flip = dir.y == 1
	main_sprite.global_position = world_pos
	main_sprite.frame = main_row * 8 + dir.x
	main_sprite.flip_h = last_flip
	shadow.global_position = world_pos + Vector3(0, 0.5, 0)
	if attach_sprite and attach_sprite.visible and main_anchors and attach_anchors:
		var cam_right := Vector3(cam_basis.x.x, 0, cam_basis.x.z).normalized()
		var to_cam := cam.global_position - world_pos
		to_cam.y = 0
		to_cam = to_cam.normalized() if to_cam.length_squared() > 0.0001 else Vector3.BACK
		var p := main_anchors.to_offset(main_anchors.get_point(parent_point, dir.x, main_row), last_flip)
		var c := attach_anchors.to_offset(attach_anchors.get_point(child_point, dir.x, attach_row), last_flip)
		var layer := main_anchors.layer_for(dir.x)
		last_attach_origin = world_pos + cam_right * p.x + Vector3.UP * p.y
		var pos := world_pos + cam_right * (p.x - c.x) + Vector3.UP * (p.y - c.y) + to_cam * (LAYER_GAP * layer)
		attach_sprite.global_position = pos
		attach_sprite.frame = attach_row * 8 + dir.x
		attach_sprite.flip_h = last_flip
