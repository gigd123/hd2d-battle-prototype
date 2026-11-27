class_name BattleTerrain
extends Node3D
## 灰盒戰場地形：程式產生的高度圖，有多種場地類型。
##
## 同一份高度資料有兩個用途：
##   1. 網格＋HeightMapShape3D 靜態碰撞 → 給玩家與馬（CharacterBody3D）用
##   2. get_height() 雙線性內插 → 給戰場管理器的士兵用（士兵不進物理引擎）
## 另外放岩石與（森林／河谷的）樹作為障礙物，同時登記成圓形障礙，讓士兵的分離力可以繞開。
##
## 場地類型只改「地形資料」：高度、地面倍率（水、雪）、障礙、顏色與天氣。
## 戰鬥邏輯只透過 get_height / move_factor / obstacles_near 讀取，不知道目前是哪種場地。

enum Type { PLAINS, HILLS, FOREST, RIVER, SNOW }
const TYPE_NAMES := ["平原", "丘陵", "森林", "河谷", "雪地"]
const TYPE_KEYS := ["plains", "hills", "forest", "river", "snow"]
const TYPE_HINTS := [
	"地勢平坦開闊，騎兵最好發揮",
	"敵軍佔據東側山脊，居高臨下；上坡會變慢",
	"林間有成片樹叢阻擋，陣形會被打散",
	"中央一條河，涉水很慢；南北各有一處淺灘",
	"積雪讓所有人都慢一點，起伏較大",
]

@export var terrain_type: int = Type.HILLS
@export var size_m := 160          # 地圖邊長（公尺）
@export var cell := 1.0            # 取樣間距（公尺）
@export var seed_value := 12345

## 上坡減速：坡度（高度差／水平距離）每 1.0 減少的速度比例
@export var uphill_penalty := 1.1
## 下坡加速：坡度每 1.0 增加的速度比例（上限見 move_factor）
@export var downhill_bonus := 0.35

var samples := 0                   # 每邊取樣點數
var heights := PackedFloat32Array()
## 圓形障礙：Vector3(x, z, 半徑)
var obstacles: Array[Vector3] = []
## 水面高度；沒有水的場地為 -INF
var water_level := -INF
## 地面本身的移動倍率（雪地 < 1）
var ground_speed := 1.0

const OB_CELL := 8.0
var _ob_grid: Array = []           # 每格一個 Array[Vector3]
var _ob_w := 0
var _ob_empty: Array[Vector3] = []
var _half := 0.0
var _noise := FastNoiseLite.new()
var _grove := FastNoiseLite.new()


static func type_from_key(key: String) -> int:
	return TYPE_KEYS.find(key)


func type_name() -> String:
	return TYPE_NAMES[terrain_type]


func build() -> void:
	samples = int(size_m / cell) + 1
	_half = size_m * 0.5
	_noise.seed = seed_value
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.012
	_noise.fractal_octaves = 3
	_grove.seed = seed_value + 51
	_grove.frequency = 0.045
	match terrain_type:
		Type.RIVER:
			water_level = -0.3
		Type.SNOW:
			ground_speed = 0.88
			_noise.frequency = 0.016
	_generate_heights()
	_build_mesh()
	_build_collision()
	_build_water()
	_build_obstacles()
	_build_trees()
	_build_obstacle_grid()


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


## 水深（沒有水或在岸上回傳 0）
func water_depth(x: float, z: float) -> float:
	if water_level == -INF:
		return 0.0
	return maxf(0.0, water_level - get_height(x, z))


## 地面本身的速度倍率：雪地、涉水
func ground_factor(x: float, z: float) -> float:
	var f := ground_speed
	if water_level != -INF:
		var depth := water_level - get_height(x, z)
		if depth > 0.0:
			f *= lerpf(0.9, 0.42, clampf(depth / 0.7, 0.0, 1.0))
	return f


## 往 (dx, dz)（單位向量）方向移動時的速度倍率 = 坡度 × 地面。
## 士兵、馬、步行玩家共用同一條規則。
func move_factor(x: float, z: float, dx: float, dz: float) -> float:
	var h0 := get_height(x, z)
	var grade := (get_height(x + dx * 1.5, z + dz * 1.5) - h0) / 1.5
	var f := 1.0
	if grade > 0.0:
		f = maxf(0.35, 1.0 - grade * uphill_penalty)
	else:
		f = 1.0 + minf(-grade, 0.4) * downhill_bonus
	if ground_speed != 1.0:
		f *= ground_speed
	if water_level != -INF and h0 < water_level:
		f *= lerpf(0.9, 0.42, clampf((water_level - h0) / 0.7, 0.0, 1.0))
	return f


## 附近的圓形障礙（以 8 公尺格子索引，避免每個士兵掃描全部障礙）
func obstacles_near(x: float, z: float) -> Array[Vector3]:
	if _ob_w == 0:
		return _ob_empty
	var cx := clampi(int((x + _half) / OB_CELL), 0, _ob_w - 1)
	var cz := clampi(int((z + _half) / OB_CELL), 0, _ob_w - 1)
	return _ob_grid[cz * _ob_w + cx]


## 河道中心線（河谷場地）：沿 Z 方向蜿蜒
func river_center(z: float) -> float:
	return sin(z * 0.035) * 7.0 + sin(z * 0.011 + 1.3) * 4.0


## 淺灘（0..1）
func _ford(z: float) -> float:
	return maxf(1.0 - smoothstep(3.0, 8.0, absf(z + 24.0)), 1.0 - smoothstep(3.0, 8.0, absf(z - 22.0)))


static func _bump(x: float, z: float, cx: float, cz: float, r: float) -> float:
	var d := Vector2(x - cx, z - cz).length() / r
	return 1.0 - smoothstep(0.0, 1.0, d)


# ---------------------------------------------------------------------------
func _height_at(x: float, z: float) -> float:
	var r := Vector2(x, z).length() / _half
	var n := _noise.get_noise_2d(x, z)
	var h := 0.0
	match terrain_type:
		Type.PLAINS:
			h = n * 2.2 * lerpf(0.4, 1.0, smoothstep(0.2, 0.8, r))
		Type.HILLS:
			h = n * 9.0 * lerpf(0.4, 1.0, smoothstep(0.15, 0.8, r))
			# 敵軍陣地的山脊（東側），我方要仰攻
			var zf := 1.0 - smoothstep(26.0, 46.0, absf(z))
			h += smoothstep(8.0, 34.0, x) * 9.0 * zf
			# 我方後方的小丘與北側高地
			h += _bump(x, z, -44.0, 24.0, 15.0) * 6.0
			h += _bump(x, z, -6.0, -46.0, 18.0) * 8.0
		Type.FOREST:
			h = n * 4.0 * lerpf(0.5, 1.0, smoothstep(0.15, 0.8, r))
		Type.RIVER:
			var dx := absf(x - river_center(z))
			h = smoothstep(4.0, 48.0, dx) * 9.0 + n * 2.0 * smoothstep(8.0, 24.0, dx)
			var bed := lerpf(-1.15, -0.42, _ford(z))
			h = lerpf(bed, h, smoothstep(3.0, 7.0, dx))
		Type.SNOW:
			# 稜線狀的起伏（取雜訊絕對值）＋一般起伏
			var ridge := 1.0 - absf(_grove.get_noise_2d(x * 0.35, z * 0.35))
			h = n * 6.0 * lerpf(0.5, 1.0, smoothstep(0.1, 0.7, r)) + ridge * ridge * 3.5
	# 地圖邊緣抬高成天然邊界
	h += pow(smoothstep(0.8, 1.0, maxf(absf(x), absf(z)) / _half), 2.0) * 18.0
	return h


func _generate_heights() -> void:
	heights.resize(samples * samples)
	for iz in samples:
		for ix in samples:
			heights[iz * samples + ix] = _height_at(ix * cell - _half, iz * cell - _half)


func _palette() -> Dictionary:
	match terrain_type:
		Type.PLAINS:
			return {"a": Color(0.44, 0.60, 0.28), "b": Color(0.58, 0.68, 0.32), "dirt": Color(0.60, 0.50, 0.34), "rock": Color(0.52, 0.50, 0.46), "road": true}
		Type.FOREST:
			return {"a": Color(0.24, 0.40, 0.19), "b": Color(0.33, 0.47, 0.22), "dirt": Color(0.42, 0.34, 0.22), "rock": Color(0.42, 0.42, 0.40), "road": true}
		Type.RIVER:
			return {"a": Color(0.38, 0.54, 0.26), "b": Color(0.48, 0.60, 0.30), "dirt": Color(0.56, 0.47, 0.33), "rock": Color(0.48, 0.47, 0.45), "road": false}
		Type.SNOW:
			return {"a": Color(0.86, 0.89, 0.95), "b": Color(0.94, 0.95, 0.98), "dirt": Color(0.66, 0.64, 0.64), "rock": Color(0.40, 0.40, 0.44), "road": true}
	return {"a": Color(0.36, 0.52, 0.26), "b": Color(0.46, 0.60, 0.30), "dirt": Color(0.55, 0.46, 0.32), "rock": Color(0.48, 0.47, 0.45), "road": true}


func _build_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pal := _palette()
	var grass_a: Color = pal["a"]
	var grass_b: Color = pal["b"]
	var dirt: Color = pal["dirt"]
	var rock: Color = pal["rock"]
	var road: bool = pal["road"]
	var sand := Color(0.66, 0.60, 0.44)
	var bed := Color(0.34, 0.32, 0.27)
	var litter := Color(0.20, 0.28, 0.14)
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
			if terrain_type == Type.FOREST:
				c = c.lerp(litter, smoothstep(0.05, 0.35, _grove.get_noise_2d(x, z)) * 0.7)
			c = c.lerp(dirt, smoothstep(0.08, 0.25, slope))
			c = c.lerp(rock, smoothstep(0.3, 0.5, slope))
			if water_level != -INF:
				c = c.lerp(sand, 1.0 - smoothstep(water_level + 0.2, water_level + 0.9, h))
				c = c.lerp(bed, 1.0 - smoothstep(water_level - 0.5, water_level, h))
			# 中央一條土路（方便看出地面與角色的接觸關係）
			if road and absf(z + x * 0.15) < 2.2:
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


func _build_water() -> void:
	if water_level == -INF:
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2(size_m, size_m)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.44, 0.58, 0.62)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	mat.metallic_specular = 0.8
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = plane
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0, water_level, 0)
	add_child(mi)


func _build_obstacles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 99
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.50, 0.48) if terrain_type != Type.SNOW else Color(0.46, 0.46, 0.50)
	mat.roughness = 1.0
	var spots := [Vector2(-8, 14), Vector2(6, -16), Vector2(-22, -6), Vector2(20, 18), Vector2(-4, -30), Vector2(-30, 24)]
	if terrain_type == Type.PLAINS:
		spots = [Vector2(-8, 14), Vector2(20, 18), Vector2(-4, -30)]
	elif terrain_type == Type.SNOW or terrain_type == Type.HILLS:
		spots.append_array([Vector2(28, -22), Vector2(34, 10), Vector2(-40, -18)])
	for s in spots:
		var r := rng.randf_range(1.0, 2.0)
		var hgt := rng.randf_range(1.5, 3.5)
		if water_depth(s.x, s.y) > 0.0 or (water_level != -INF and get_height(s.x, s.y) < water_level + 0.5):
			continue
		_add_box(Vector3(s.x, get_height(s.x, s.y), s.y), Vector3(r * 1.6, hgt, r * 1.4), rng.randf() * TAU, mat)
		obstacles.append(Vector3(s.x, s.y, r * 1.05))


func _add_box(p: Vector3, size: Vector3, rot_y: float, mat: Material) -> void:
	var body := StaticBody3D.new()
	body.position = p + Vector3(0, size.y * 0.5 - 0.3, 0)
	body.rotation.y = rot_y
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


## 樹分兩種：
## - 佈景樹：交戰區外圍，不參與碰撞
## - 林中樹（森林、河岸）：在交戰區內，登記成障礙（士兵繞開）並加圓柱碰撞（玩家與馬會被擋住）
func _build_trees() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 3
	var decor_count := 160
	var tex := PlaceholderArt.tree_texture()
	var tint := Color.WHITE
	match terrain_type:
		Type.PLAINS:
			decor_count = 60
		Type.FOREST:
			decor_count = 260
			tint = Color(0.85, 0.92, 0.85)
		Type.RIVER:
			decor_count = 120
		Type.SNOW:
			decor_count = 130
			tex = _pine_texture(true)
	var decor: Array[Vector3] = []
	var tries := 0
	while decor.size() < decor_count and tries < 4000:
		tries += 1
		var x := rng.randf_range(-_half + 6, _half - 6)
		var z := rng.randf_range(-_half + 6, _half - 6)
		if Vector2(x, z).length() < 45.0 or water_depth(x, z) > 0.0:
			continue
		decor.append(Vector3(x, get_height(x, z) - 0.2, z))

	# 林中樹
	var solid: Array[Vector3] = []
	var want := 0
	match terrain_type:
		Type.FOREST:
			want = 170
		Type.RIVER:
			want = 45
	tries = 0
	while solid.size() < want and tries < 6000:
		tries += 1
		var x := rng.randf_range(-52.0, 52.0)
		var z := rng.randf_range(-48.0, 48.0)
		if terrain_type == Type.FOREST:
			if _grove.get_noise_2d(x, z) < 0.12:
				continue
		else:
			# 河岸兩側的樹帶
			var dx := absf(x - river_center(z))
			if dx < 7.5 or dx > 16.0 or _ford(z) > 0.2 or rng.randf() < 0.4:
				continue
		# 玩家出生點、土路留空
		if Vector2(x + 30.0, z).length() < 7.0 or absf(z + x * 0.15) < 3.0:
			continue
		var ok := true
		for q in solid:
			if Vector2(q.x - x, q.z - z).length_squared() < 7.0:
				ok = false
				break
		if ok:
			solid.append(Vector3(x, get_height(x, z) - 0.2, z))
	for q in solid:
		var body := StaticBody3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.45
		shape.height = 4.0
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		body.position = q + Vector3(0, 2.0, 0)
		add_child(body)
		obstacles.append(Vector3(q.x, q.z, 0.6))

	var all := decor.duplicate()
	all.append_array(solid)
	_add_tree_multimesh(all, tex, tint, rng)


func _add_tree_multimesh(positions: Array, tex: Texture2D, tint: Color, rng: RandomNumberGenerator) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(tex.get_width(), tex.get_height()) * PlaceholderArt.PIXEL_SIZE * 2.0
	quad.center_offset = Vector3(0, quad.size.y * 0.5, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = tint
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
	mm.instance_count = positions.size()
	for i in positions.size():
		var sc := rng.randf_range(0.8, 1.3)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(sc, sc, sc)), positions[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Trees"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## 針葉樹佔位圖（雪地用，可加積雪）
static func _pine_texture(snowy: bool) -> Texture2D:
	var w := 26
	var h := 46
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var trunk := Color(0.32, 0.22, 0.15)
	for y in range(36, 46):
		for x in range(11, 15):
			img.set_pixel(x, y, trunk)
	var dark := Color(0.12, 0.28, 0.20)
	var mid := Color(0.17, 0.36, 0.25)
	var snow := Color(0.93, 0.95, 1.0)
	# 三層三角形樹冠
	var tiers := [[2, 16, 6], [10, 26, 9], [19, 38, 12]]
	for t in tiers:
		var top: int = t[0]
		var bottom: int = t[1]
		var half_w: int = t[2]
		for y in range(top, bottom):
			var k := float(y - top) / float(bottom - top)
			var hw := int(round(lerpf(1.0, half_w, k)))
			for x in range(13 - hw, 13 + hw):
				if x < 0 or x >= w:
					continue
				var c := mid if x < 13 else dark
				if snowy and (y - top < 2 or (k > 0.75 and (x + y) % 3 == 0)):
					c = snow
				img.set_pixel(x, y, c)
	# 外框
	var out := img.duplicate() as Image
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a > 0.5:
				continue
			for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q: Vector2i = Vector2i(x, y) + o
				if q.x >= 0 and q.y >= 0 and q.x < w and q.y < h and img.get_pixel(q.x, q.y).a > 0.5:
					out.set_pixel(x, y, Color(0.08, 0.10, 0.12))
					break
	return ImageTexture.create_from_image(out)


func _build_obstacle_grid() -> void:
	_ob_w = int(ceil(size_m / OB_CELL))
	_ob_grid.resize(_ob_w * _ob_w)
	for i in _ob_grid.size():
		var a: Array[Vector3] = []
		_ob_grid[i] = a
	for ob in obstacles:
		# 登記到所有可能碰到的格子（障礙半徑＋最大士兵半徑）
		var reach := ob.z + 1.0
		var x0 := clampi(int((ob.x - reach + _half) / OB_CELL), 0, _ob_w - 1)
		var x1 := clampi(int((ob.x + reach + _half) / OB_CELL), 0, _ob_w - 1)
		var z0 := clampi(int((ob.y - reach + _half) / OB_CELL), 0, _ob_w - 1)
		var z1 := clampi(int((ob.y + reach + _half) / OB_CELL), 0, _ob_w - 1)
		for cz in range(z0, z1 + 1):
			for cx in range(x0, x1 + 1):
				(_ob_grid[cz * _ob_w + cx] as Array).append(ob)


## 天氣與光線（由戰場套用到環境）
func environment_settings() -> Dictionary:
	match terrain_type:
		Type.PLAINS:
			return {"sky_top": Color(0.32, 0.52, 0.84), "horizon": Color(0.82, 0.80, 0.72), "fog": Color(0.80, 0.82, 0.86), "fog_density": 0.0015, "sun": Color(1.0, 0.95, 0.84), "sun_energy": 1.3, "ambient": 0.45}
		Type.FOREST:
			return {"sky_top": Color(0.36, 0.52, 0.70), "horizon": Color(0.70, 0.74, 0.66), "fog": Color(0.62, 0.70, 0.62), "fog_density": 0.006, "sun": Color(1.0, 0.92, 0.78), "sun_energy": 1.1, "ambient": 0.40}
		Type.RIVER:
			return {"sky_top": Color(0.40, 0.56, 0.80), "horizon": Color(0.86, 0.80, 0.70), "fog": Color(0.80, 0.80, 0.82), "fog_density": 0.003, "sun": Color(1.0, 0.88, 0.70), "sun_energy": 1.2, "ambient": 0.45}
		Type.SNOW:
			return {"sky_top": Color(0.55, 0.62, 0.74), "horizon": Color(0.84, 0.86, 0.90), "fog": Color(0.86, 0.88, 0.93), "fog_density": 0.007, "sun": Color(0.92, 0.95, 1.0), "sun_energy": 0.9, "ambient": 0.55}
	return {"sky_top": Color(0.38, 0.55, 0.80), "horizon": Color(0.80, 0.78, 0.72), "fog": Color(0.78, 0.80, 0.86), "fog_density": 0.002, "sun": Color(1.0, 0.94, 0.84), "sun_energy": 1.2, "ambient": 0.45}
