class_name BattleTerrain
extends Node3D
## 灰盒戰場地形：程式產生的高度圖。
##
## 同一份高度資料有兩個用途：
##   1. 網格＋HeightMapShape3D 靜態碰撞 → 給玩家與馬（CharacterBody3D）用
##   2. get_height() 雙線性內插 → 給戰場管理器的士兵用（士兵不進物理引擎）
## 另外放幾塊岩石作為障礙物，同時登記成圓形障礙，讓士兵的分離力可以繞開。

@export var size_m := 160          # 地圖邊長（公尺）
@export var cell := 1.0            # 取樣間距（公尺）
@export var hill_height := 7.0
@export var seed_value := 12345

var samples := 0                   # 每邊取樣點數
var heights := PackedFloat32Array()
## 圓形障礙：Vector3(x, z, 半徑)
var obstacles: Array[Vector3] = []

var _half := 0.0


func build() -> void:
	samples = int(size_m / cell) + 1
	_half = size_m * 0.5
	_generate_heights()
	_build_mesh()
	_build_collision()
	_build_obstacles()
	_build_trees()


func half_extent() -> float:
	return _half


## 世界座標 (x, z) 的地面高度（雙線性內插）。
func get_height(x: float, z: float) -> float:
	var fx := clampf((x + _half) / cell, 0.0, samples - 1.001)
	var fz := clampf((z + _half) / cell, 0.0, samples - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var i := iz * samples + ix
	var h00 := heights[i]
	var h10 := heights[i + 1]
	var h01 := heights[i + samples]
	var h11 := heights[i + samples + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func get_normal(x: float, z: float) -> Vector3:
	var e := cell
	var hl := get_height(x - e, z)
	var hr := get_height(x + e, z)
	var hd := get_height(x, z - e)
	var hu := get_height(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


func clamp_to_map(p: Vector3, margin := 2.0) -> Vector3:
	var lim := _half - margin
	return Vector3(clampf(p.x, -lim, lim), p.y, clampf(p.z, -lim, lim))


# ---------------------------------------------------------------------------
func _generate_heights() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	heights.resize(samples * samples)
	for iz in samples:
		for ix in samples:
			var x := ix * cell - _half
			var z := iz * cell - _half
			var h := noise.get_noise_2d(x, z) * hill_height
			# 中央交戰區較平緩，四周起伏較大
			var r := Vector2(x, z).length() / _half
			h *= lerpf(0.35, 1.0, smoothstep(0.15, 0.8, r))
			# 一道明確的斜坡（測試 Sprite 在斜坡上是否漂浮、馬上坡手感）
			if x > 12.0 and x < 40.0 and absf(z) < 30.0:
				h += smoothstep(12.0, 40.0, x) * 5.0
			elif x >= 40.0 and absf(z) < 30.0:
				h += 5.0
			# 地圖邊緣抬高成天然邊界
			h += pow(smoothstep(0.8, 1.0, maxf(absf(x), absf(z)) / _half), 2.0) * 18.0
			heights[iz * samples + ix] = h


func _build_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grass_a := Color(0.36, 0.52, 0.26)
	var grass_b := Color(0.46, 0.60, 0.30)
	var dirt := Color(0.55, 0.46, 0.32)
	var rock := Color(0.48, 0.47, 0.45)
	var detail := FastNoiseLite.new()
	detail.seed = seed_value + 7
	detail.frequency = 0.15
	for iz in samples:
		for ix in samples:
			var x := ix * cell - _half
			var z := iz * cell - _half
			var h := heights[iz * samples + ix]
			var n := get_normal(x, z)
			var c := grass_a.lerp(grass_b, detail.get_noise_2d(x, z) * 0.5 + 0.5)
			var slope := 1.0 - n.y
			c = c.lerp(dirt, smoothstep(0.08, 0.25, slope))
			c = c.lerp(rock, smoothstep(0.3, 0.5, slope))
			# 中央一條土路（方便看出地面與角色的接觸關係）
			if absf(z + x * 0.15) < 2.2:
				c = c.lerp(dirt, 0.7)
			st.set_color(c)
			st.set_normal(n)
			st.set_uv(Vector2(ix, iz) / float(samples - 1))
			st.add_vertex(Vector3(x, h, z))
	for iz in samples - 1:
		for ix in samples - 1:
			var i := iz * samples + ix
			st.add_index(i)
			st.add_index(i + 1)
			st.add_index(i + samples)
			st.add_index(i + 1)
			st.add_index(i + samples + 1)
			st.add_index(i + samples)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)


func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	var shape := HeightMapShape3D.new()
	shape.map_width = samples
	shape.map_depth = samples
	shape.map_data = heights
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# HeightMapShape3D 以 1 單位為取樣間距並置中，cell 不是 1 時用縮放對齊
	cs.scale = Vector3(cell, 1.0, cell)
	body.add_child(cs)
	add_child(body)


func _build_obstacles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 99
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.50, 0.48)
	mat.roughness = 1.0
	var spots := [Vector2(-8, 14), Vector2(6, -16), Vector2(-22, -6), Vector2(20, 18), Vector2(-4, -30), Vector2(-30, 24)]
	for s in spots:
		var r := rng.randf_range(1.0, 2.0)
		var hgt := rng.randf_range(1.5, 3.5)
		var p := Vector3(s.x, get_height(s.x, s.y), s.y)
		var body := StaticBody3D.new()
		body.position = p + Vector3(0, hgt * 0.5 - 0.3, 0)
		body.rotation.y = rng.randf() * TAU
		var mesh := BoxMesh.new()
		mesh.size = Vector3(r * 1.6, hgt, r * 1.4)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		body.add_child(mi)
		var shape := BoxShape3D.new()
		shape.size = mesh.size
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		add_child(body)
		obstacles.append(Vector3(p.x, p.z, r * 1.05))


func _build_trees() -> void:
	# 四周的樹（Y 軸 Billboard 的 MultiMesh），只是佈景，不參與碰撞
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 3
	var tex := PlaceholderArt.tree_texture()
	var quad := QuadMesh.new()
	quad.size = Vector2(tex.get_width(), tex.get_height()) * PlaceholderArt.PIXEL_SIZE * 2.0
	quad.center_offset = Vector3(0, quad.size.y * 0.5, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	var positions: Array[Vector3] = []
	var tries := 0
	while positions.size() < 160 and tries < 2000:
		tries += 1
		var x := rng.randf_range(-_half + 6, _half - 6)
		var z := rng.randf_range(-_half + 6, _half - 6)
		if Vector2(x, z).length() < 45.0:
			continue
		positions.append(Vector3(x, get_height(x, z) - 0.2, z))
	mm.instance_count = positions.size()
	for i in positions.size():
		var sc := rng.randf_range(0.8, 1.3)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(sc, sc, sc)), positions[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Trees"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
