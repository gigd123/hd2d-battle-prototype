class_name SpriteSoldierRenderer
extends SoldierRenderer
## 實作 A：每個士兵一個 Sprite3D（研究報告建議的原型起點，最直觀、好除錯）。
## 陣營色用 CPU 預先換好色的貼圖（每兵種×陣營一張），modulate 只用來閃白與變暗。

var _sprites: Array[Sprite3D] = []
var _mode := BaseMaterial3D.BILLBOARD_FIXED_Y
var _stretch := Vector3.ONE


func render(bm: BattleManager, cam: Camera3D, frac: float) -> void:
	_mode = GameConfig.billboard_mode()
	_stretch = Vector3(1.0, GameConfig.billboard_stretch(cam), 1.0)
	super.render(bm, cam, frac)


func _create(bm: BattleManager) -> void:
	for s in _sprites:
		s.queue_free()
	_sprites.clear()
	for i in bm.count:
		var art: SoldierArt = _arts[bm.lo[i]]
		var tex := art.tinted_texture(TEAM_COLORS[bm.team[i]])
		var s := LayeredActorVisual.make_sprite(tex, art.frame, art.rows, art.pixel_size, art.origin)
		s.name = "Soldier%d" % i
		add_child(s)
		_sprites.append(s)


func _draw_soldier(i: int, p: Vector3, frame: int, flip: bool, flash: float, dark: float, vis: bool) -> void:
	var s := _sprites[i]
	if s.visible != vis:
		s.visible = vis
	if not vis:
		return
	if s.billboard != _mode:
		s.billboard = _mode
	s.position = p
	s.scale = _stretch
	s.frame = frame
	s.flip_h = flip
	if flash > 0.0:
		s.modulate = Color(2.0, 2.0, 2.0)
	elif dark > 0.0:
		s.modulate = Color(0.55, 0.55, 0.55)
	else:
		s.modulate = Color.WHITE
