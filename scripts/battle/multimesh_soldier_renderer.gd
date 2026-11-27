class_name MultiMeshSoldierRenderer
extends SoldierRenderer
## 實作 B：每個兵種一個 MultiMesh（共 3 次 draw call），幀、翻轉、閃白、變暗放在每實例的自訂資料，
## 陣營色放在實例顏色，由 soldier_billboard.gdshader 在 GPU 上做 Billboard、切幀與調色盤交換。
## 每幀用一整塊 PackedFloat32Array 更新（比逐一 set_instance_transform 快）。

const STRIDE := 20      # 12（transform）+ 4（color）+ 4（custom）

var _mms: Array[MultiMesh] = []
var _bufs: Array[PackedFloat32Array] = []
var _mats: Array[ShaderMaterial] = []
var _mmis: Array[MultiMeshInstance3D] = []
var _kind := PackedByteArray()          # 士兵 i 屬於哪個 MultiMesh
var _slot := PackedInt32Array()         # 士兵 i 在該 MultiMesh 的實例編號


func _create(bm: BattleManager) -> void:
	for m in _mmis:
		m.queue_free()
	_mmis.clear()
	_mms.clear()
	_bufs.clear()
	_mats.clear()
	var counts := [0, 0, 0]
	_kind.resize(bm.count)
	_slot.resize(bm.count)
	for i in bm.count:
		var ut := bm.utype[i]
		_kind[i] = ut
		_slot[i] = counts[ut]
		counts[ut] += 1
	var shader: Shader = load("res://shaders/soldier_billboard.gdshader")
	for ut in 3:
		var art: SoldierArt = _arts[ut]
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
		var buf := PackedFloat32Array()
		buf.resize(counts[ut] * STRIDE)
		for k in counts[ut]:
			var o: int = k * STRIDE
			buf[o] = 1.0
			buf[o + 5] = 1.0
			buf[o + 10] = 1.0
			buf[o + 7] = -10000.0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Soldiers_%d" % ut
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.layers = 1 << (LayeredActorVisual.SPRITE_LAYER - 1)
		# Billboard 在著色器中旋轉，引擎算不到真正範圍，直接給整個戰場大小避免被裁掉
		mmi.custom_aabb = AABB(Vector3(-200, -50, -200), Vector3(400, 100, 400))
		add_child(mmi)
		_mms.append(mm)
		_bufs.append(buf)
		_mats.append(mat)
		_mmis.append(mmi)
	# 陣營色是固定的，建立時就寫進實例顏色
	for i in bm.count:
		var o := _slot[i] * STRIDE
		var c: Color = TEAM_COLORS[bm.team[i]]
		var b: PackedFloat32Array = _bufs[_kind[i]]
		b[o + 12] = c.r
		b[o + 13] = c.g
		b[o + 14] = c.b
		b[o + 15] = 1.0
		_bufs[_kind[i]] = b


func _draw_soldier(i: int, p: Vector3, frame: int, flip: bool, flash: float, dark: float, vis: bool) -> void:
	var k := _kind[i]
	var o := _slot[i] * STRIDE
	var b := _bufs[k]
	b[o + 3] = p.x
	b[o + 7] = p.y if vis else -10000.0
	b[o + 11] = p.z
	b[o + 16] = float(frame)
	b[o + 17] = 1.0 if flip else 0.0
	b[o + 18] = flash
	b[o + 19] = dark
	_bufs[k] = b


func _end_frame() -> void:
	for k in _mms.size():
		_mats[k].set_shader_parameter("full_billboard", GameConfig.use_full_billboard())
		if _mms[k].instance_count > 0:
			_mms[k].buffer = _bufs[k]
