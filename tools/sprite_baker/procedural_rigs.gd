class_name ProceduralRigs
extends RefCounted
## 程式生成的低模 3D 角色與馬（原創，給烘焙流程當範例與佔位）。
##
## 產出的場景結構和「AI 3D 生成 → 自動綁骨 → 匯出 glb」得到的東西一樣：
##   一個根節點、幾個 MeshInstance3D、一個 AnimationPlayer（動畫名稱 = 動作名稱）、
##   幾個空節點當錨點（Seat、Saddle、WeaponTip…）。
## 所以烘焙器只需要一套程式，就能吃這裡的內建模型，也能吃使用者自己的 glb。
##
## 座標慣例：原點在腳底，角色面向 +Z（與 glTF 相同），1 單位 = 1 公尺。
## 命名慣例：名稱含「Team」的零件是陣營色區域；「Sword」「Spear」開頭的是武器層。

const SAMPLE_FPS := 30.0

# 顏色（全部原創配色）
const C_STEEL := Color(0.62, 0.66, 0.72)
const C_STEEL_DARK := Color(0.36, 0.38, 0.44)
const C_MAIL := Color(0.48, 0.50, 0.55)
const C_TEAM := Color(0.92, 0.92, 0.92)      # 陣營色區域先用淺灰，執行期乘上陣營色
const C_LEATHER := Color(0.42, 0.27, 0.16)
const C_LEATHER_DARK := Color(0.26, 0.17, 0.11)
const C_PANTS := Color(0.33, 0.27, 0.22)
const C_SKIN := Color(0.86, 0.66, 0.52)
const C_WOOD := Color(0.55, 0.38, 0.22)
const C_GOLD := Color(0.85, 0.68, 0.30)
const C_COAT := Color(0.50, 0.33, 0.20)
const C_COAT_DARK := Color(0.34, 0.22, 0.14)
const C_MANE := Color(0.16, 0.11, 0.08)
const C_HOOF := Color(0.18, 0.15, 0.13)


static func build(rig_name: String) -> Node3D:
	match rig_name:
		"knight":
			return build_knight()
		"horse":
			return build_horse()
	push_error("ProceduralRigs: 不認識的內建模型 " + rig_name)
	return null


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m


static func _joint(parent: Node3D, n: String, pos: Vector3) -> Node3D:
	var j := Node3D.new()
	j.name = n
	j.position = pos
	parent.add_child(j)
	return j


static func _box(parent: Node3D, n: String, size: Vector3, pos: Vector3, c: Color, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _mesh(parent, n, m, pos, c, rot_deg)


static func _cyl(parent: Node3D, n: String, r_top: float, r_bottom: float, h: float, pos: Vector3, c: Color, rot_deg := Vector3.ZERO, segs := 8) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bottom
	m.height = h
	m.radial_segments = segs
	m.rings = 1
	return _mesh(parent, n, m, pos, c, rot_deg)


static func _cap(parent: Node3D, n: String, r: float, h: float, pos: Vector3, c: Color, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	m.radial_segments = 8
	m.rings = 2
	return _mesh(parent, n, m, pos, c, rot_deg)


static func _sphere(parent: Node3D, n: String, r: float, pos: Vector3, c: Color) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 8
	m.rings = 4
	return _mesh(parent, n, m, pos, c, Vector3.ZERO)


static func _mesh(parent: Node3D, n: String, m: Mesh, pos: Vector3, c: Color, rot_deg: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = m
	mi.material_override = null
	m.surface_set_material(0, _mat(c))
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi


static func _marker(parent: Node3D, n: String, pos: Vector3) -> Node3D:
	return _joint(parent, n, pos)


## 把「時間 0..1 → {關節名: [旋轉(度), 位移]}」的姿勢函式取樣成 Animation。
static func _make_anim(root: Node3D, pose_fn: Callable, length: float, loop: bool) -> Animation:
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var samples := maxi(2, int(round(length * SAMPLE_FPS)))
	var tracks := {}
	for s in samples + 1:
		var t := float(s) / float(samples)
		if loop and s == samples:
			t = 0.0                 # 循環動畫的最後一個鍵與第一個相同，接縫才平順
		var pose: Dictionary = pose_fn.call(t)
		for jn in pose:
			var node := root.find_child(jn, true, false) as Node3D
			if node == null:
				continue
			var path := str(root.get_path_to(node))
			var entry: Array = pose[jn]
			var rot: Vector3 = entry[0]
			var q := Basis.from_euler(rot * (PI / 180.0), EULER_ORDER_YXZ).get_rotation_quaternion()
			var key := "%s:rot" % path
			if not tracks.has(key):
				var ti := anim.add_track(Animation.TYPE_ROTATION_3D)
				anim.track_set_path(ti, NodePath(path))
				tracks[key] = ti
			anim.rotation_track_insert_key(tracks[key], float(s) / float(samples) * length, q)
			if entry.size() > 1:
				var pkey := "%s:pos" % path
				if not tracks.has(pkey):
					var tp := anim.add_track(Animation.TYPE_POSITION_3D)
					anim.track_set_path(tp, NodePath(path))
					tracks[pkey] = tp
				anim.position_track_insert_key(tracks[pkey], float(s) / float(samples) * length, node.get_meta("rest_pos", node.position) + (entry[1] as Vector3))
	return anim


static func _add_player(root: Node3D, anims: Dictionary) -> void:
	# 記住每個關節的靜止位置，位移軌道以它為基準
	for n in root.find_children("*", "Node3D", true, false):
		n.set_meta("rest_pos", n.position)
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	root.add_child(ap)
	var lib := AnimationLibrary.new()
	for anim_name in anims:
		var a: Array = anims[anim_name]
		lib.add_animation(anim_name, _make_anim(root, a[0], a[1], a[2]))
	ap.add_animation_library("", lib)


## 關鍵姿勢內插：keys = [[t, {關節: [rot, pos?]}], ...]，t 遞增
static func _keyed(keys: Array, t: float) -> Dictionary:
	var i := 0
	while i < keys.size() - 2 and t > keys[i + 1][0]:
		i += 1
	var a: Array = keys[i]
	var b: Array = keys[i + 1]
	var f := clampf((t - a[0]) / maxf(0.0001, b[0] - a[0]), 0.0, 1.0)
	f = f * f * (3.0 - 2.0 * f)
	var out := {}
	var da: Dictionary = a[1]
	var db: Dictionary = b[1]
	for k in da:
		var ea: Array = da[k]
		var eb: Array = db.get(k, ea)
		var r: Vector3 = (ea[0] as Vector3).lerp(eb[0], f)
		if ea.size() > 1:
			out[k] = [r, (ea[1] as Vector3).lerp(eb[1] if eb.size() > 1 else ea[1], f)]
		else:
			out[k] = [r]
	return out


static func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate()
	for k in b:
		o[k] = b[k]
	return o


# ---------------------------------------------------------------------------
# 騎士（步兵）
# ---------------------------------------------------------------------------
static func build_knight() -> Node3D:
	var root := Node3D.new()
	root.name = "Knight"
	var body := _joint(root, "Body", Vector3.ZERO)          # 倒地時以腳底為軸
	var hips := _joint(body, "Hips", Vector3(0, 0.86, 0))
	_box(hips, "Skirt_Team", Vector3(0.36, 0.22, 0.25), Vector3(0, -0.06, 0), C_TEAM)
	_box(hips, "Belt", Vector3(0.38, 0.06, 0.27), Vector3(0, 0.06, 0), C_LEATHER_DARK)
	_box(hips, "Buckle", Vector3(0.07, 0.05, 0.02), Vector3(0, 0.06, 0.14), C_GOLD)
	_marker(hips, "Seat", Vector3(0, -0.10, 0))

	var spine := _joint(hips, "Spine", Vector3(0, 0.08, 0))
	_box(spine, "Mail", Vector3(0.44, 0.46, 0.28), Vector3(0, 0.22, 0), C_MAIL)
	_box(spine, "Tunic_Team", Vector3(0.46, 0.40, 0.30), Vector3(0, 0.20, 0), C_TEAM)
	_box(spine, "TunicStripe", Vector3(0.08, 0.40, 0.305), Vector3(0, 0.20, 0.001), C_GOLD)
	_box(spine, "PauldronL", Vector3(0.18, 0.09, 0.26), Vector3(0.26, 0.44, 0), C_STEEL, Vector3(0, 0, -18))
	_box(spine, "PauldronR", Vector3(0.18, 0.09, 0.26), Vector3(-0.26, 0.44, 0), C_STEEL, Vector3(0, 0, 18))

	var neck := _joint(spine, "Neck", Vector3(0, 0.46, 0))
	_cyl(neck, "Coif", 0.09, 0.11, 0.08, Vector3(0, 0.03, 0), C_MAIL)
	var head := _joint(neck, "Head", Vector3(0, 0.06, 0))
	_cyl(head, "Helm", 0.15, 0.155, 0.30, Vector3(0, 0.15, 0), C_STEEL, Vector3.ZERO, 8)
	_cyl(head, "HelmTop", 0.05, 0.15, 0.08, Vector3(0, 0.34, 0), C_STEEL, Vector3.ZERO, 8)
	_box(head, "Visor", Vector3(0.24, 0.035, 0.03), Vector3(0, 0.17, 0.145), C_MANE)
	_box(head, "Nasal", Vector3(0.035, 0.12, 0.03), Vector3(0, 0.12, 0.155), C_STEEL_DARK)
	_box(head, "Crest_Team", Vector3(0.04, 0.09, 0.26), Vector3(0, 0.41, -0.01), C_TEAM)
	_marker(head, "HeadTop", Vector3(0, 0.40, 0))

	for side in [1.0, -1.0]:
		var s := "L" if side > 0.0 else "R"
		var sh := _joint(spine, "Shoulder" + s, Vector3(0.25 * side, 0.40, 0))
		_cap(sh, "UpperArm" + s, 0.065, 0.32, Vector3(0, -0.14, 0), C_MAIL)
		var el := _joint(sh, "Elbow" + s, Vector3(0, -0.28, 0))
		_cap(el, "Forearm" + s, 0.06, 0.28, Vector3(0, -0.12, 0), C_MAIL)
		_cyl(el, "Bracer" + s, 0.07, 0.065, 0.12, Vector3(0, -0.16, 0), C_LEATHER)
		var hand := _joint(el, "Hand" + s, Vector3(0, -0.26, 0))
		_box(hand, "Glove" + s, Vector3(0.09, 0.10, 0.09), Vector3(0, -0.03, 0.01), C_LEATHER_DARK)
		var hip := _joint(hips, "Leg" + s, Vector3(0.10 * side, -0.02, 0))
		_cap(hip, "Thigh" + s, 0.09, 0.42, Vector3(0, -0.19, 0), C_PANTS)
		var knee := _joint(hip, "Knee" + s, Vector3(0, -0.40, 0))
		_cap(knee, "Shin" + s, 0.075, 0.38, Vector3(0, -0.18, 0), C_PANTS)
		_box(knee, "Greave" + s, Vector3(0.12, 0.22, 0.11), Vector3(0, -0.21, 0.02), C_STEEL)
		var foot := _joint(knee, "Foot" + s, Vector3(0, -0.38, 0))
		_box(foot, "Boot" + s, Vector3(0.13, 0.09, 0.24), Vector3(0, -0.035, 0.04), C_LEATHER_DARK)

	# 盾綁在左前臂外側
	var elbow_l := root.find_child("ElbowL", true, false) as Node3D
	var shield := _joint(elbow_l, "ShieldMount", Vector3(0.06, -0.20, 0.06))
	shield.rotation_degrees = Vector3(0, 0, -90)     # 盾面朝前（前臂水平前伸時）
	_box(shield, "ShieldBoard", Vector3(0.04, 0.44, 0.52), Vector3.ZERO, C_WOOD)
	_box(shield, "ShieldFace_Team", Vector3(0.02, 0.36, 0.44), Vector3(0.025, 0, 0), C_TEAM)
	_box(shield, "ShieldBoss", Vector3(0.04, 0.10, 0.10), Vector3(0.04, 0, 0), C_STEEL)

	# 武器：握把在右手，劍身沿武器節點的 +Y
	var hand_r := root.find_child("HandR", true, false) as Node3D
	var wpn := _joint(hand_r, "WeaponMount", Vector3(0, -0.04, 0.02))
	wpn.rotation_degrees = Vector3(90, 0, 0)
	_cyl(wpn, "Sword_Grip", 0.02, 0.02, 0.16, Vector3(0, -0.02, 0), C_LEATHER_DARK)
	_box(wpn, "Sword_Guard", Vector3(0.22, 0.03, 0.04), Vector3(0, 0.07, 0), C_GOLD)
	_box(wpn, "Sword_Blade", Vector3(0.06, 0.82, 0.015), Vector3(0, 0.49, 0), C_STEEL)
	_sphere(wpn, "Sword_Pommel", 0.03, Vector3(0, -0.11, 0), C_GOLD)
	_marker(wpn, "WeaponTip", Vector3(0, 0.90, 0))
	# 第二把武器（長槍），示範「同一套動作、換武器只重烘武器層」
	_cyl(wpn, "Spear_Shaft", 0.022, 0.022, 2.1, Vector3(0, 0.55, 0), C_WOOD)
	_cyl(wpn, "Spear_Head", 0.0, 0.05, 0.24, Vector3(0, 1.72, 0), C_STEEL, Vector3.ZERO, 4)

	_add_player(root, {
		"idle": [_knight_idle, 1.2, true],
		"walk": [_knight_walk, 0.8, true],
		"run": [_knight_run, 0.55, true],
		"attack_a": [_knight_attack_a, 0.65, false],
		"attack_b": [_knight_attack_b, 0.65, false],
		"death": [_knight_death, 0.6, false],
		"ride_idle": [_knight_ride_idle, 1.2, true],
		"ride_attack_a": [_knight_ride_attack_a, 0.65, false],
		"ride_attack_b": [_knight_ride_attack_b, 0.65, false],
	})
	return root


static func _knight_arms_ready() -> Dictionary:
	return {
		"ShoulderR": [Vector3(-12, 0, -6)],
		"ElbowR": [Vector3(-48, 0, 0)],
		"HandR": [Vector3(10, 0, 0)],
		"ShoulderL": [Vector3(-28, 0, 10)],
		"ElbowL": [Vector3(-62, 0, 0)],
		"HandL": [Vector3(0, 0, 0)],
		"Spine": [Vector3(0, 0, 0)],
		"Head": [Vector3(0, 0, 0)],
	}


static func _knight_legs_stand() -> Dictionary:
	return {
		"Body": [Vector3.ZERO, Vector3.ZERO],
		"Hips": [Vector3.ZERO, Vector3.ZERO],
		"LegL": [Vector3(-4, 0, 3)], "LegR": [Vector3(4, 0, -3)],
		"KneeL": [Vector3(6, 0, 0)], "KneeR": [Vector3(6, 0, 0)],
		"FootL": [Vector3(-2, 0, 0)], "FootR": [Vector3(-2, 0, 0)],
	}


static func _knight_legs_ride() -> Dictionary:
	return {
		"Body": [Vector3.ZERO, Vector3.ZERO],
		"Hips": [Vector3(0, 0, 0), Vector3.ZERO],
		"LegL": [Vector3(-62, 0, 24)], "LegR": [Vector3(-62, 0, -24)],
		"KneeL": [Vector3(78, 0, 0)], "KneeR": [Vector3(78, 0, 0)],
		"FootL": [Vector3(-14, 0, 0)], "FootR": [Vector3(-14, 0, 0)],
	}


static func _knight_idle(t: float) -> Dictionary:
	var b := sin(t * TAU)
	var p := _merge(_knight_legs_stand(), _knight_arms_ready())
	p["Hips"] = [Vector3.ZERO, Vector3(0, -0.012 * (0.5 + 0.5 * b), 0)]
	p["Spine"] = [Vector3(2.0 * b, 0, 0)]
	return p


static func _knight_walk(t: float) -> Dictionary:
	var ph := t * TAU
	var s := 26.0 * sin(ph)
	var p := _knight_arms_ready()
	p["Body"] = [Vector3.ZERO, Vector3.ZERO]
	p["Hips"] = [Vector3(0, 4.0 * sin(ph), 0), Vector3(0, 0.03 * cos(2.0 * ph) - 0.02, 0)]
	p["LegL"] = [Vector3(-s, 0, 2)]
	p["LegR"] = [Vector3(s, 0, -2)]
	p["KneeL"] = [Vector3(6 + 40.0 * maxf(0.0, cos(ph)), 0, 0)]
	p["KneeR"] = [Vector3(6 + 40.0 * maxf(0.0, -cos(ph)), 0, 0)]
	p["FootL"] = [Vector3(-4, 0, 0)]
	p["FootR"] = [Vector3(-4, 0, 0)]
	p["ShoulderR"] = [Vector3(-12 - 14.0 * sin(ph), 0, -6)]
	p["ShoulderL"] = [Vector3(-28 + 8.0 * sin(ph), 0, 10)]
	p["Spine"] = [Vector3(3, -5.0 * sin(ph), 0)]
	return p


static func _knight_run(t: float) -> Dictionary:
	var ph := t * TAU
	var s := 42.0 * sin(ph)
	var p := _knight_arms_ready()
	p["Body"] = [Vector3.ZERO, Vector3.ZERO]
	p["Hips"] = [Vector3(0, 6.0 * sin(ph), 0), Vector3(0, 0.06 * cos(2.0 * ph) - 0.05, 0)]
	p["LegL"] = [Vector3(-s - 8, 0, 2)]
	p["LegR"] = [Vector3(s - 8, 0, -2)]
	p["KneeL"] = [Vector3(14 + 80.0 * maxf(0.0, cos(ph)), 0, 0)]
	p["KneeR"] = [Vector3(14 + 80.0 * maxf(0.0, -cos(ph)), 0, 0)]
	p["FootL"] = [Vector3(-6, 0, 0)]
	p["FootR"] = [Vector3(-6, 0, 0)]
	p["Spine"] = [Vector3(14, -8.0 * sin(ph), 0)]
	p["Head"] = [Vector3(-10, 0, 0)]
	p["ShoulderR"] = [Vector3(-20 - 30.0 * sin(ph), 0, -8)]
	p["ElbowR"] = [Vector3(-75, 0, 0)]
	p["ShoulderL"] = [Vector3(-30 + 20.0 * sin(ph), 0, 12)]
	p["ElbowL"] = [Vector3(-80, 0, 0)]
	return p


## 揮擊關鍵姿勢：side = +1 右→左（正手），-1 左→右（反手）；low = 往下砍的角度（騎乘用）
static func _swing_keys(side: float, low: float) -> Array:
	var y := func(v: float) -> float: return v * side
	var k := func(spine_y: float, sh_x: float, sh_y: float, el: float, hand: float) -> Dictionary:
		return {
			"Spine": [Vector3(4, y.call(spine_y), 0)],
			"ShoulderR": [Vector3(sh_x + low, y.call(sh_y), -6)],
			"ElbowR": [Vector3(el, 0, 0)],
			"HandR": [Vector3(hand, 0, 0)],
			"ShoulderL": [Vector3(-35, 0, 14)],
			"ElbowL": [Vector3(-70, 0, 0)],
			"Head": [Vector3(0, y.call(-spine_y * 0.5), 0)],
		}
	if side > 0.0:
		return [
			[0.0, k.call(-20, -60, -55, -60, 40)],
			[0.2, k.call(-42, -85, -115, -75, 70)],
			[0.4, k.call(-25, -88, -60, -15, 85)],
			[0.6, k.call(12, -88, 0, 0, 90)],
			[0.8, k.call(38, -85, 60, -10, 85)],
			[1.0, k.call(20, -65, 35, -40, 55)],
		]
	# 反手：從左側收到右側
	return [
		[0.0, k.call(-20, -70, -40, -55, 55)],
		[0.2, k.call(-42, -88, -78, -80, 75)],
		[0.4, k.call(-22, -88, -45, -20, 85)],
		[0.6, k.call(10, -88, 5, 0, 90)],
		[0.8, k.call(36, -85, 70, -12, 85)],
		[1.0, k.call(18, -65, 40, -40, 55)],
	]


static func _knight_attack(t: float, side: float) -> Dictionary:
	var legs := _knight_legs_stand()
	legs["LegL"] = [Vector3(-18, 0, 4)]
	legs["LegR"] = [Vector3(12, 0, -4)]
	legs["KneeL"] = [Vector3(14, 0, 0)]
	legs["KneeR"] = [Vector3(10, 0, 0)]
	legs["Hips"] = [Vector3(0, 0, 0), Vector3(0, -0.04, 0)]
	return _merge(legs, _keyed(_swing_keys(side, 0.0), t))


static func _knight_attack_a(t: float) -> Dictionary:
	return _knight_attack(t, 1.0)


static func _knight_attack_b(t: float) -> Dictionary:
	# 反手 = 把正手的左右鏡像：肩膀繞 Y 的角度與脊椎扭轉反過來
	return _knight_attack(t, -1.0)


static func _knight_death(t: float) -> Dictionary:
	var e := t * t
	var p := _merge(_knight_legs_stand(), _knight_arms_ready())
	p["Body"] = [Vector3(-88.0 * e, 0, 0), Vector3(0, 0.12 * e, 0.85 * e)]
	p["KneeL"] = [Vector3(6 + 40.0 * sin(t * PI), 0, 0)]
	p["KneeR"] = [Vector3(6 + 30.0 * sin(t * PI), 0, 0)]
	p["ShoulderR"] = [Vector3(-12 - 100.0 * e, 0, -6 - 40.0 * e)]
	p["ShoulderL"] = [Vector3(-28 - 80.0 * e, 0, 10 + 40.0 * e)]
	p["ElbowR"] = [Vector3(-48 + 40.0 * e, 0, 0)]
	p["Head"] = [Vector3(-20.0 * e, 0, 0)]
	return p


static func _knight_ride_idle(t: float) -> Dictionary:
	var b := sin(t * TAU)
	var p := _merge(_knight_legs_ride(), _knight_arms_ready())
	p["Spine"] = [Vector3(-2 + 2.0 * b, 0, 0)]
	p["ShoulderR"] = [Vector3(-25, 0, -10)]
	p["ElbowR"] = [Vector3(-55, 0, 0)]
	return p


static func _knight_ride_attack(t: float, side: float) -> Dictionary:
	return _merge(_knight_legs_ride(), _keyed(_swing_keys(side, 22.0), t))


static func _knight_ride_attack_a(t: float) -> Dictionary:
	return _knight_ride_attack(t, 1.0)


static func _knight_ride_attack_b(t: float) -> Dictionary:
	return _knight_ride_attack(t, -1.0)


# ---------------------------------------------------------------------------
# 馬
# ---------------------------------------------------------------------------
static func build_horse() -> Node3D:
	var root := Node3D.new()
	root.name = "Horse"
	var body := _joint(root, "Body", Vector3(0, 1.22, 0))
	_cap(body, "Barrel", 0.34, 1.6, Vector3(0, 0, -0.02), C_COAT, Vector3(90, 0, 0))
	_cap(body, "Chest", 0.33, 0.7, Vector3(0, 0.02, 0.52), C_COAT, Vector3(90, 0, 0))
	_cap(body, "Rump", 0.35, 0.7, Vector3(0, 0.03, -0.55), C_COAT, Vector3(90, 0, 0))
	# 鞍與鞍布
	_box(body, "SaddleCloth_Team", Vector3(0.66, 0.42, 0.56), Vector3(0, 0.06, 0.02), C_TEAM)
	_box(body, "SaddleClothTrim", Vector3(0.67, 0.05, 0.57), Vector3(0, -0.13, 0.02), C_GOLD)
	_box(body, "SaddleSeat", Vector3(0.40, 0.10, 0.46), Vector3(0, 0.32, 0.02), C_LEATHER)
	_box(body, "Pommel", Vector3(0.18, 0.12, 0.06), Vector3(0, 0.38, 0.24), C_LEATHER_DARK)
	_box(body, "Cantle", Vector3(0.30, 0.12, 0.06), Vector3(0, 0.38, -0.20), C_LEATHER_DARK)
	_marker(body, "Saddle", Vector3(0, 0.37, 0.0))

	var neck := _joint(body, "Neck", Vector3(0, 0.12, 0.68))
	neck.rotation_degrees = Vector3(38, 0, 0)
	_box(neck, "NeckMesh", Vector3(0.26, 0.80, 0.42), Vector3(0, 0.30, -0.02), C_COAT)
	_box(neck, "Mane", Vector3(0.08, 0.82, 0.10), Vector3(0, 0.32, -0.24), C_MANE)
	var head := _joint(neck, "HeadJ", Vector3(0, 0.66, 0.02))
	head.rotation_degrees = Vector3(62, 0, 0)
	_box(head, "HeadMesh", Vector3(0.24, 0.30, 0.44), Vector3(0, 0.0, 0.14), C_COAT)
	_box(head, "Muzzle", Vector3(0.20, 0.23, 0.24), Vector3(0, -0.02, 0.42), C_COAT_DARK)
	_box(head, "Bridle", Vector3(0.235, 0.04, 0.04), Vector3(0, 0.0, 0.34), C_LEATHER_DARK)
	_box(head, "EarL", Vector3(0.05, 0.12, 0.05), Vector3(0.07, 0.17, -0.02), C_COAT_DARK, Vector3(-15, 0, 10))
	_box(head, "EarR", Vector3(0.05, 0.12, 0.05), Vector3(-0.07, 0.17, -0.02), C_COAT_DARK, Vector3(-15, 0, -10))
	_box(head, "Forelock", Vector3(0.10, 0.06, 0.12), Vector3(0, 0.14, 0.06), C_MANE)

	var tail := _joint(body, "Tail", Vector3(0, 0.12, -0.86))
	tail.rotation_degrees = Vector3(-150, 0, 0)
	_box(tail, "TailMesh", Vector3(0.10, 0.62, 0.12), Vector3(0, 0.30, 0), C_MANE)

	for leg in [["FL", 0.17, 0.58], ["FR", -0.17, 0.58], ["HL", 0.17, -0.60], ["HR", -0.17, -0.60]]:
		var ln: String = leg[0]
		var hip := _joint(body, "Leg" + ln, Vector3(leg[1], -0.12, leg[2]))
		_cap(hip, "Upper" + ln, 0.095 if ln.begins_with("H") else 0.085, 0.50, Vector3(0, -0.20, 0), C_COAT)
		var knee := _joint(hip, "Knee" + ln, Vector3(0, -0.44, 0))
		_cyl(knee, "Lower" + ln, 0.05, 0.045, 0.46, Vector3(0, -0.22, 0), C_COAT_DARK)
		_box(knee, "Hoof" + ln, Vector3(0.11, 0.08, 0.13), Vector3(0, -0.47, 0.01), C_HOOF)

	_add_player(root, {
		"idle": [_horse_idle, 1.6, true],
		"trot": [_horse_trot, 0.7, true],
		"gallop": [_horse_gallop, 0.6, true],
	})
	return root


static func _horse_legs(fl: float, fr: float, hl: float, hr: float, amp: float, bend: float) -> Dictionary:
	var out := {}
	var phases := {"FL": fl, "FR": fr, "HL": hl, "HR": hr}
	for ln in phases:
		var ph: float = phases[ln] * TAU
		var swing := amp * sin(ph)
		var lift := maxf(0.0, cos(ph))
		out["Leg" + ln] = [Vector3(-swing, 0, 0)]
		if ln.begins_with("F"):
			out["Knee" + ln] = [Vector3(bend * 1.3 * lift, 0, 0)]       # 前膝往後折
		else:
			out["Knee" + ln] = [Vector3(-bend * lift + 6.0, 0, 0)]      # 後腳飛節往前折
	return out


static func _horse_idle(t: float) -> Dictionary:
	var b := sin(t * TAU)
	var p := _horse_legs(0, 0, 0, 0, 0, 0)
	p["Body"] = [Vector3.ZERO, Vector3(0, -0.01 * (0.5 + 0.5 * b), 0)]
	p["Neck"] = [Vector3(38 + 3.0 * b, 0, 0)]
	p["HeadJ"] = [Vector3(62, 0, 0)]
	p["Tail"] = [Vector3(-150, 6.0 * b, 0)]
	return p


static func _horse_trot(t: float) -> Dictionary:
	var p := _horse_legs(t, t + 0.5, t + 0.5, t, 24.0, 40.0)
	p["Body"] = [Vector3.ZERO, Vector3(0, 0.035 * cos(2.0 * t * TAU), 0)]
	p["Neck"] = [Vector3(40 + 3.0 * cos(2.0 * t * TAU), 0, 0)]
	p["HeadJ"] = [Vector3(60, 0, 0)]
	p["Tail"] = [Vector3(-145, 0, 0)]
	return p


static func _horse_gallop(t: float) -> Dictionary:
	# 旋轉式襲步：四蹄依序落地，身體每步前後擺一次
	var p := _horse_legs(t, t + 0.12, t + 0.5, t + 0.62, 42.0, 60.0)
	var ph := t * TAU
	p["Body"] = [Vector3(5.0 * sin(ph), 0, 0), Vector3(0, 0.07 * sin(ph + 0.6), 0)]
	p["Neck"] = [Vector3(48 - 8.0 * sin(ph), 0, 0)]
	p["HeadJ"] = [Vector3(52, 0, 0)]
	p["Tail"] = [Vector3(-120 + 8.0 * sin(ph), 0, 0)]
	return p
