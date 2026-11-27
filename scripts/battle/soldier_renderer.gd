class_name SoldierRenderer
extends Node3D
## 士兵的「視覺代理」介面：只讀 BattleManager 的資料陣列，決定每個士兵畫哪一幀。
## 實作可替換（Sprite3D／MultiMesh／之後的預渲染 3D），戰鬥邏輯完全不用改。
## 子類別實作 _create(n) 與 _draw_soldier(...)；共用的方向、動作幀、陰影在這裡處理。

const TEAM_COLORS := [Color(0.40, 0.60, 1.0), Color(1.0, 0.38, 0.32)]

var _shadow_mm: MultiMesh
var _shadow_mmi: MultiMeshInstance3D
var _n := 0


func setup(bm: BattleManager) -> void:
	_n = bm.count
	_create(_n)
	_setup_shadows(_n)


func _create(_count: int) -> void:
	pass


func _draw_soldier(_i: int, _p: Vector3, _frame: int, _flip: bool, _color: Color, _visible: bool) -> void:
	pass


func _end_frame() -> void:
	pass


func render(bm: BattleManager, cam: Camera3D, frac: float) -> void:
	if cam == null or bm.count != _n:
		return
	var cam_basis := cam.global_basis
	var dir_count := GameConfig.direction_count()
	var mirror := GameConfig.mirror_enabled()
	var now := bm.battle_time
	var shadow_buf := _shadow_mm.buffer if _shadow_mm else PackedFloat32Array()
	for i in _n:
		var st := bm.state[i]
		var p := bm.prev_pos[i].lerp(bm.pos[i], frac)
		var dead := st == BattleManager.State.DEAD
		var visible_now := not dead or (now - bm.dead_time[i]) < bm.corpse_time
		var dir := DirectionUtil.resolve_with(bm.facing[i], cam_basis, dir_count, mirror)
		var row := PlaceholderArt.ROW_IDLE
		if dead:
			row = PlaceholderArt.ROW_DEAD
		elif bm.atk_anim[i] > 0.0 and bm.atk_anim[i] < 0.25:
			row = PlaceholderArt.ROW_ATTACK
		elif st == BattleManager.State.MOVE:
			row = PlaceholderArt.ROW_WALK if int(now * 5.0 + i * 0.37) % 2 == 0 else PlaceholderArt.ROW_IDLE
		var c: Color = TEAM_COLORS[bm.team[i]]
		if dead:
			c = c.darkened(0.45)
		elif bm.hit_flash[i] > 0.0:
			c = Color(2.0, 2.0, 2.0)
		_draw_soldier(i, p, row * 8 + dir.x, dir.y == 1, c, visible_now)
		# 腳下陰影
		var o := i * 12
		if visible_now and not dead:
			shadow_buf[o + 3] = p.x
			shadow_buf[o + 7] = p.y + 0.06
			shadow_buf[o + 11] = p.z
		else:
			shadow_buf[o + 7] = -10000.0
	if _shadow_mm:
		_shadow_mm.buffer = shadow_buf
	_end_frame()


func _setup_shadows(n: int) -> void:
	if _shadow_mmi:
		_shadow_mmi.queue_free()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.95, 0.95)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = PlaceholderArt.blob_shadow()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.material = mat
	_shadow_mm = MultiMesh.new()
	_shadow_mm.transform_format = MultiMesh.TRANSFORM_3D
	_shadow_mm.mesh = plane
	_shadow_mm.instance_count = n
	var buf := PackedFloat32Array()
	buf.resize(n * 12)
	for i in n:
		var o := i * 12
		buf[o] = 1.0
		buf[o + 5] = 1.0
		buf[o + 10] = 1.0
		buf[o + 7] = -10000.0
	if n > 0:
		_shadow_mm.buffer = buf
	_shadow_mmi = MultiMeshInstance3D.new()
	_shadow_mmi.name = "SoldierShadows"
	_shadow_mmi.multimesh = _shadow_mm
	_shadow_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow_mmi.custom_aabb = AABB(Vector3(-200, -50, -200), Vector3(400, 100, 400))
	add_child(_shadow_mmi)
