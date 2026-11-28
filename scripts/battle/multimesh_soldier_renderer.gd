class_name MultiMeshSoldierRenderer
extends SoldierRenderer
## 實作 B：每種武器配置一個 MultiMesh（用到幾種就幾次 draw call），幀、翻轉、閃白、變暗放在每實例的自訂資料，
## 陣營色放在實例顏色，由 soldier_billboard.gdshader 在 GPU 上做 Billboard、切幀與調色盤交換。
## 所有士兵的實例資料放在同一塊 PackedFloat32Array（_all），每幀寫完後再切成各 MultiMesh 的緩衝區。
## （以前每種配置各一塊、放在 Array 裡，每寫一個士兵都會觸發整塊複製，人多時很慢。）

const STRIDE := 20      # 12（transform）+ 4（color）+ 4（custom）

var _mms: Array[MultiMesh] = []
var _all := PackedFloat32Array()        # 全部士兵的實例資料，依配置分段
var _range := PackedInt32Array()        # 配置 k 在 _all 的 [起點, 終點)：_range[2k], _range[2k+1]
var _off := PackedInt32Array()          # 士兵 i 在 _all 的起點
var _mats: Array[ShaderMaterial] = []
var _mmis: Array[MultiMeshInstance3D] = []
var _kind := PackedByteArray()          # 士兵 i 屬於哪個 MultiMesh
var _slot := PackedInt32Array()         # 士兵 i 在該 MultiMesh 的實例編號


func _create(bm: BattleManager) -> void:
	for m in _mmis:
		m.queue_free()
	_mmis.clear()
	_mms.clear()
	_mats.clear()
	var counts := []
	counts.resize(UnitDefs.count())
	counts.fill(0)
	_kind.resize(bm.count)
	_slot.resize(bm.count)
	_off.resize(bm.count)
	for i in bm.count:
		var l := bm.lo[i]
		_kind[i] = l
		_slot[i] = counts[l]
		counts[l] += 1
	_range.resize(UnitDefs.count() * 2)
	var start := 0
	for k in UnitDefs.count():
		_range[k * 2] = start * STRIDE
		start += int(counts[k])
		_range[k * 2 + 1] = start * STRIDE
	_all = PackedFloat32Array()
	_all.resize(start * STRIDE)
	for i in bm.count:
		_off[i] = _range[_kind[i] * 2] + _slot[i] * STRIDE
	var shader: Shader = load("res://shaders/soldier_billboard.gdshader")
	for ut in UnitDefs.count():
		var art: SoldierArt = _arts[ut]
		if art == null:
			# 沒用到的配置：放一個空的佔位，讓索引對齊
			_mms.append(null)
			_mats.append(null)
			continue
		var frame := art.frame
		var quad := QuadMesh.new()
		quad.size = Vector2(frame) * art.pixel_size
		# 原點（腳底）不一定在幀底部：預渲染圖腳下有留邊
		var below := (frame.y - art.origin.y) * art.pixel_size if art.origin.x >= 0.0 else 0.0
		quad.center_offset = Vector3(0, quad.size.y * 0.5 - below, 0)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("atlas", art.shader_atlas())
		mat.set_shader_parameter("grid", Vector2(8, art.rows))
		mat.set_shader_parameter("alpha_team_mask", art.baked)
		mat.set_shader_parameter("pitch_comp", GameConfig.pitch_compensation)
		quad.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = counts[ut]
		for k in counts[ut]:
			var o: int = _range[ut * 2] + k * STRIDE
			_all[o] = 1.0
			_all[o + 5] = 1.0
			_all[o + 10] = 1.0
			_all[o + 7] = -10000.0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Soldiers_%d" % ut
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.layers = 1 << (LayeredActorVisual.SPRITE_LAYER - 1)
		# Billboard 在著色器中旋轉，引擎算不到真正範圍，直接給整個戰場大小避免被裁掉
		mmi.custom_aabb = AABB(Vector3(-200, -50, -200), Vector3(400, 100, 400))
		add_child(mmi)
		_mms.append(mm)
		_mats.append(mat)
		_mmis.append(mmi)
	# 陣營色是固定的，建立時就寫進實例顏色
	for i in bm.count:
		var o := _off[i]
		var c: Color = TEAM_COLORS[bm.team[i]]
		_all[o + 12] = c.r
		_all[o + 13] = c.g
		_all[o + 14] = c.b
		_all[o + 15] = 1.0


func _draw_soldier(i: int, p: Vector3, frame: int, flip: bool, flash: float, dark: float, vis: bool) -> void:
	var o := _off[i]
	_all[o + 3] = p.x
	_all[o + 7] = p.y if vis else -10000.0
	_all[o + 11] = p.z
	_all[o + 16] = float(frame)
	_all[o + 17] = 1.0 if flip else 0.0
	_all[o + 18] = flash
	_all[o + 19] = dark


func _end_frame() -> void:
	for k in _mms.size():
		if _mms[k] == null:
			continue
		_mats[k].set_shader_parameter("full_billboard", GameConfig.use_full_billboard())
		if _mms[k].instance_count > 0:
			_mms[k].buffer = _all.slice(_range[k * 2], _range[k * 2 + 1])
