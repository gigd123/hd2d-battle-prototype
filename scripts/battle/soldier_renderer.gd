class_name SoldierRenderer
extends Node3D
## 士兵的「視覺代理」介面：只讀 BattleManager 的資料陣列，決定每個士兵畫哪一幀。
## 實作可替換（Sprite3D／MultiMesh／之後的預渲染 3D），戰鬥邏輯完全不用改。
## 子類別實作 _create() 與 _draw_soldier()；共用的方向、動作幀、陰影、箭矢在這裡處理。

const TEAM_COLORS := [Color(0.40, 0.60, 1.0), Color(1.0, 0.38, 0.32)]

var _shadow_mm: MultiMesh
var _shadow_mmi: MultiMeshInstance3D
var _arrow_mm: MultiMesh
var _arrow_mmi: MultiMeshInstance3D
var _n := 0


## 每種武器配置的圖集（索引 = UnitDefs 編號；沒用到的配置是 null，不合成），依 GameConfig.art_mode 決定
var _arts: Array[SoldierArt] = []


func setup(bm: BattleManager) -> void:
	_n = bm.count
	_arts.clear()
	_arts.resize(UnitDefs.count())
	for i in bm.count:
		var l := bm.lo[i]
		if _arts[l] == null:
			_arts[l] = SoldierArt.for_loadout(l)
	_create(bm)
	_setup_shadows(_n)
	_setup_arrows()


func _create(_bm: BattleManager) -> void:
	pass


## frame：列*8+欄；flash：受擊閃白 0..1；dark：倒地變暗 0..1
func _draw_soldier(_i: int, _p: Vector3, _frame: int, _flip: bool, _flash: float, _dark: float, _visible: bool) -> void:
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
	var shadow_buf := _shadow_mm.buffer if (_shadow_mm and _n > 0) else PackedFloat32Array()
	for i in _n:
		var st := bm.state[i]
		var ut := bm.utype[i]
		var p := bm.prev_pos[i].lerp(bm.pos[i], frac)
		var dead := st == BattleManager.State.DEAD
		var visible_now := not dead or (now - bm.dead_time[i]) < bm.corpse_time
		var dir := DirectionUtil.resolve_with(bm.facing[i], cam_basis, dir_count, mirror)
		var art: SoldierArt = _arts[bm.lo[i]]
		var anim := bm.atk_anim[i]
		var kind := SoldierArt.Kind.IDLE
		var t := now + i * 0.37
		var progress := 0.0
		var spd := 0.0
		if dead:
			kind = SoldierArt.Kind.DEAD
			t = now - bm.dead_time[i]
		elif anim > 0.0:
			# 一邊移動一邊出手：下半身（或馬）繼續走
			kind = SoldierArt.Kind.WALK_ATTACK if bm.vel[i].length() > 0.8 else SoldierArt.Kind.ATTACK
			progress = 1.0 - anim / (0.6 if ut == BattleManager.UnitType.ARCHER else 0.45)
		elif st == BattleManager.State.MOVE:
			spd = bm.vel[i].length()
			var run_at := 7.0 if ut == BattleManager.UnitType.CAVALRY else 3.6
			kind = SoldierArt.Kind.RUN if spd > run_at else SoldierArt.Kind.WALK
		var row := art.row_for(kind, t, progress, spd)
		var flash := 1.0 if (bm.hit_flash[i] > 0.0 and not dead) else 0.0
		_draw_soldier(i, p, row * 8 + dir.x, dir.y == 1, flash, 1.0 if dead else 0.0, visible_now)
		# 腳下陰影（騎兵較大）
		var o := i * 12
		if visible_now and not dead:
			var sc := 2.2 if ut == BattleManager.UnitType.CAVALRY else 1.0
			shadow_buf[o] = sc
			shadow_buf[o + 10] = sc
			shadow_buf[o + 3] = p.x
			shadow_buf[o + 7] = p.y + 0.06
			shadow_buf[o + 11] = p.z
		else:
			shadow_buf[o + 7] = -10000.0
	if _shadow_mm and _n > 0:
		_shadow_mm.buffer = shadow_buf
	_render_arrows(bm)
	_end_frame()


func _render_arrows(bm: BattleManager) -> void:
	if _arrow_mm == null or bm.arrow_state.size() != BattleManager.MAX_ARROWS:
		return
	var buf := PackedFloat32Array()
	buf.resize(BattleManager.MAX_ARROWS * 12)
	for k in BattleManager.MAX_ARROWS:
		var o := k * 12
		if bm.arrow_state[k] == 0:
			buf[o + 7] = -10000.0
			buf[o] = 1.0
			buf[o + 5] = 1.0
			buf[o + 10] = 1.0
			continue
		var v := bm.arrow_vel[k]
		var z := v.normalized() if v.length_squared() > 0.0001 else Vector3.FORWARD
		var x := Vector3.UP.cross(z)
		x = x.normalized() if x.length_squared() > 0.0001 else Vector3.RIGHT
		var y := z.cross(x)
		var p := bm.arrow_pos[k]
		# MultiMesh 緩衝區是 3x4 列主序：每列 = (basis 各軸的同一分量, origin 分量)
		buf[o] = x.x; buf[o + 1] = y.x; buf[o + 2] = z.x; buf[o + 3] = p.x
		buf[o + 4] = x.y; buf[o + 5] = y.y; buf[o + 6] = z.y; buf[o + 7] = p.y
		buf[o + 8] = x.z; buf[o + 9] = y.z; buf[o + 10] = z.z; buf[o + 11] = p.z
	_arrow_mm.buffer = buf


func _setup_arrows() -> void:
	if _arrow_mmi:
		_arrow_mmi.queue_free()
	var box := BoxMesh.new()
	box.size = Vector3(0.05, 0.05, 0.8)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.25, 0.15)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = mat
	_arrow_mm = MultiMesh.new()
	_arrow_mm.transform_format = MultiMesh.TRANSFORM_3D
	_arrow_mm.mesh = box
	_arrow_mm.instance_count = BattleManager.MAX_ARROWS
	_arrow_mmi = MultiMeshInstance3D.new()
	_arrow_mmi.name = "Arrows"
	_arrow_mmi.multimesh = _arrow_mm
	_arrow_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arrow_mmi.custom_aabb = AABB(Vector3(-200, -50, -200), Vector3(400, 150, 400))
	add_child(_arrow_mmi)


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
