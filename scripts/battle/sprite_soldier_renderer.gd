class_name SpriteSoldierRenderer
extends SoldierRenderer
## 實作 A：每個士兵一個 Sprite3D（研究報告建議的原型起點，最直觀、好除錯）。
## 代價是每個士兵一個節點與一次繪製，人數多時可與 MultiMesh 實作比較。

var _sprites: Array[Sprite3D] = []
var _mode := BaseMaterial3D.BILLBOARD_FIXED_Y


func render(bm: BattleManager, cam: Camera3D, frac: float) -> void:
	_mode = GameConfig.billboard_mode()
	super.render(bm, cam, frac)


func _create(n: int) -> void:
	for s in _sprites:
		s.queue_free()
	_sprites.clear()
	var tex := PlaceholderArt.human_atlas()
	for i in n:
		var s := LayeredActorVisual.make_sprite(tex, PlaceholderArt.HUMAN_FRAME, PlaceholderArt.HUMAN_ROWS)
		s.name = "Soldier%d" % i
		add_child(s)
		_sprites.append(s)


func _draw_soldier(i: int, p: Vector3, frame: int, flip: bool, color: Color, vis: bool) -> void:
	var s := _sprites[i]
	if s.visible != vis:
		s.visible = vis
	if not vis:
		return
	if s.billboard != _mode:
		s.billboard = _mode
	s.position = p
	s.frame = frame
	s.flip_h = flip
	s.modulate = color
