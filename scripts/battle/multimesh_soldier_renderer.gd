class_name MultiMeshSoldierRenderer
extends SoldierRenderer
## 實作 B：所有士兵一個 MultiMesh（1 次 draw call），幀與翻轉放在每實例的自訂資料，
## 由 soldier_billboard.gdshader 在 GPU 上做 Billboard 與切幀。
## 每幀用一整塊 PackedFloat32Array 更新（比逐一 set_instance_transform 快）。

const STRIDE := 20      # 12（transform）+ 4（color）+ 4（custom）

var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _buf := PackedFloat32Array()
var _mat: ShaderMaterial


func _create(n: int) -> void:
	if _mmi:
		_mmi.queue_free()
	var quad := QuadMesh.new()
	quad.size = Vector2(PlaceholderArt.HUMAN_FRAME) * PlaceholderArt.PIXEL_SIZE
	quad.center_offset = Vector3(0, quad.size.y * 0.5, 0)
	var mat := ShaderMaterial.new()
	_mat = mat
	mat.shader = load("res://shaders/soldier_billboard.gdshader")
	mat.set_shader_parameter("atlas", PlaceholderArt.human_atlas())
	mat.set_shader_parameter("grid", Vector2(8, PlaceholderArt.HUMAN_ROWS))
	quad.material = mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = quad
	_mm.instance_count = n
	_buf.resize(n * STRIDE)
	_buf.fill(0.0)
	for i in n:
		var o := i * STRIDE
		_buf[o] = 1.0
		_buf[o + 5] = 1.0
		_buf[o + 10] = 1.0
		_buf[o + 7] = -10000.0
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Soldiers"
	_mmi.multimesh = _mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.layers = 1 << (LayeredActorVisual.SPRITE_LAYER - 1)
	# Billboard 在著色器中旋轉，引擎算不到真正範圍，直接給整個戰場大小避免被裁掉
	_mmi.custom_aabb = AABB(Vector3(-200, -50, -200), Vector3(400, 100, 400))
	add_child(_mmi)


func _draw_soldier(i: int, p: Vector3, frame: int, flip: bool, color: Color, vis: bool) -> void:
	var o := i * STRIDE
	_buf[o + 3] = p.x
	_buf[o + 7] = p.y if vis else -10000.0
	_buf[o + 11] = p.z
	_buf[o + 12] = color.r
	_buf[o + 13] = color.g
	_buf[o + 14] = color.b
	_buf[o + 15] = 1.0
	_buf[o + 16] = float(frame)
	_buf[o + 17] = 1.0 if flip else 0.0


func _end_frame() -> void:
	_mat.set_shader_parameter("full_billboard", GameConfig.full_billboard)
	if _n > 0:
		_mm.buffer = _buf
