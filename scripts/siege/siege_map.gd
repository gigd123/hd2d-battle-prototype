class_name SiegeMap
extends Node3D
## 攻城戰的城牆、城門、雲梯、內側坡道與攻城槌（全部佔位幾何）。
##
## 同一份配置有兩個用途（跟地形一樣）：
##   1. 方塊碰撞 → 給玩家與馬（CharacterBody3D）用：玩家可以走雲梯、坡道、牆頂
##   2. 純數學查詢 → 給戰場管理器的士兵用（士兵不進物理引擎）：
##      士兵多一個「所在層」lvl：0 地面、1 牆頂（含內側坡道）、2 雲梯上。
##      移動後由 resolve() 修正位置與層（牆擋住、從梯腳爬上去、從坡道走下來），
##      floor_y() 給高度，waypoint() 給跨層的導航點（往哪道梯子／坡道／城門走）。
##
## 座標：攻方在西（-X），城牆外側面在 x = WALL_X0，牆頂走道到 x = WALL_X1，城內在東。
## 城牆貫穿整張地圖（南北向），攻方只能爬梯或撞開城門。

const WALL_X0 := 8.0           # 城牆外側面
const WALL_X1 := 12.0          # 城牆內側面
const WALK_X0 := 8.7           # 女兒牆內側（牆頂可站的最外側）
const WALL_H := 6.5            # 牆頂高度（相對地面基準）
const PARAPET_H := 1.15        # 女兒牆高度
const GATE_HALF := 2.5         # 城門半寬（|z| < 2.5）
const GATE_TUNNEL_H := 4.9     # 城門洞高度
const GATE_HP := 2400.0
const LADDER_Z := [-30.0, -14.0, 18.0]
const LADDER_RUN := 3.4        # 雲梯水平長度（梯腳 x = WALL_X0 - LADDER_RUN）
const LADDER_HALF := 0.7       # 雲梯半寬
const LADDER_SPEED := 1.0      # 爬梯的水平速度（m/s）；約 3.4 秒爬上 6.5 公尺
const RAMP_Z := [-24.0, 9.0]   # 城內登城坡道（從牆頂往東下到地面）
const RAMP_RUN := 9.0
const RAMP_HALF := 1.5
## 城門兩側的外凸塔樓（地面障礙）：x 範圍、|z| 範圍
const BASTION_X := Vector2(5.4, 8.0)
const BASTION_Z := Vector2(3.0, 6.6)
## 攻城槌
const RAM_LEN := 4.4
const RAM_HALF_W := 0.8
const RAM_START_X := -36.0
const RAM_STOP_X := WALL_X0 - 0.35 - RAM_LEN * 0.5
const RAM_SPEED := 1.0         # 推槌人數足夠時的速度（m/s）
const RAM_CREW_FULL := 6       # 這麼多人推就是全速
const RAM_HIT_INTERVAL := 2.4
const RAM_HIT_DMG := 100.0

enum Zone { OUT, IN, WALL, LADDER }

var terrain: BattleTerrain
var base_y := 0.0              # 城牆附近的地面高度（地形在這一帶壓平）
var gate_hp := GATE_HP
var gate_broken := false
var ram_pos := Vector3.ZERO
var ram_crew := 0              # 目前在槌旁邊的人數（BattleManager 每步更新）
var ram_hit_t := 0.0
var ram_at_gate := false
var ram_swing := 0.0           # 撞擊動畫（1 → 0）

## waypoint() 的附帶結果：+1 = 想往上爬（梯／坡道），-1 = 想往下，0 = 不換層
var last_climb := 0
## resolve() 的附帶結果：修正後的層
var last_level := 0

var _gate_body: StaticBody3D
var _gate_mesh: Node3D
var _gate_broken_mesh: Node3D
var _ram_node: Node3D
var _ram_log: Node3D
var _stone: StandardMaterial3D
var _stone_dark: StandardMaterial3D
var _wood: StandardMaterial3D
var _wood_dark: StandardMaterial3D


func build(p_terrain: BattleTerrain) -> void:
	terrain = p_terrain
	base_y = terrain.get_height(10.0, 0.0)
	_stone = _mat(Color(0.62, 0.60, 0.55))
	_stone_dark = _mat(Color(0.48, 0.46, 0.43))
	_wood = _mat(Color(0.52, 0.36, 0.20))
	_wood_dark = _mat(Color(0.36, 0.25, 0.15))
	_build_walls()
	_build_gate()
	_build_ladders()
	_build_ramps()
	_build_keep()
	_build_ram()
	reset()


func reset() -> void:
	gate_hp = GATE_HP
	gate_broken = false
	ram_pos = Vector3(RAM_START_X, terrain.get_height(RAM_START_X, 0.0), 0.0)
	ram_hit_t = RAM_HIT_INTERVAL
	ram_at_gate = false
	ram_swing = 0.0
	ram_crew = 0
	if _gate_body:
		_gate_body.process_mode = Node.PROCESS_MODE_INHERIT
		(_gate_body.get_child(0) as CollisionShape3D).disabled = false
		_gate_mesh.visible = true
		_gate_broken_mesh.visible = false


func wall_top() -> float:
	return base_y + WALL_H


# ---------------------------------------------------------------------------
# 士兵查詢
# ---------------------------------------------------------------------------
## 某層某點的地面高度
func floor_y(level: int, p: Vector3) -> float:
	match level:
		1:
			if p.x > WALL_X1:
				return base_y + WALL_H * clampf(1.0 - (p.x - WALL_X1) / RAMP_RUN, 0.0, 1.0)
			return base_y + WALL_H
		2:
			var t := clampf((p.x - (WALL_X0 - LADDER_RUN)) / LADDER_RUN, 0.0, 1.0)
			return lerpf(terrain.get_height(p.x, p.z), base_y + WALL_H, t)
	return terrain.get_height(p.x, p.z)


func zone_of(level: int, x: float) -> int:
	match level:
		1:
			return Zone.WALL
		2:
			return Zone.LADDER
	return Zone.OUT if x < (WALL_X0 + WALL_X1) * 0.5 else Zone.IN


## 玩家（物理角色）所在區域：用高度判斷是否在牆上
func zone_of_point(p: Vector3) -> int:
	var above := p.y - base_y
	if above > 2.2:
		if p.x < WALK_X0 - 0.1 and nearest_ladder(p.z) >= 0 and absf(p.z - LADDER_Z[nearest_ladder(p.z)]) < LADDER_HALF + 0.3:
			return Zone.LADDER
		if p.x >= WALL_X0 - 0.2:
			return Zone.WALL
		return Zone.LADDER
	return Zone.OUT if p.x < (WALL_X0 + WALL_X1) * 0.5 else Zone.IN


func nearest_ladder(z: float) -> int:
	var best := 0
	for k in LADDER_Z.size():
		if absf(z - LADDER_Z[k]) < absf(z - LADDER_Z[best]):
			best = k
	return best


func nearest_ramp(z: float, goal_z: float) -> int:
	var best := 0
	var best_c := INF
	for k in RAMP_Z.size():
		var c := absf(z - RAMP_Z[k]) + absf(goal_z - RAMP_Z[k])
		if c < best_c:
			best_c = c
			best = k
	return best


## 跨層導航：從 (level, p) 要到 goal（所在區域 goal_zone），下一個要直走過去的點。
## ladder_pref：小隊指定的梯子（-1 = 自己挑最近的）。結果的 last_climb 表示是否要換層。
func waypoint(level: int, p: Vector3, goal: Vector3, goal_zone: int, ladder_pref := -1) -> Vector3:
	last_climb = 0
	var z := zone_of(level, p.x)
	if level == 0 and (goal_zone == Zone.OUT or goal_zone == Zone.IN) and crosses_wall(p, goal):
		# 地面上要穿過城牆（目標在門洞裡或另一邊）：先走到門洞口
		var side := -1.0 if p.x < (WALL_X0 + WALL_X1) * 0.5 else 1.0
		return Vector3(BASTION_X.x - 1.0 if side < 0.0 else WALL_X1 + 2.0, 0, 0)
	if z == goal_zone and z != Zone.LADDER:
		return goal
	match z:
		Zone.LADDER:
			var lz: float = LADDER_Z[nearest_ladder(p.z)]
			if goal_zone == Zone.OUT:
				last_climb = -1
				return Vector3(WALL_X0 - LADDER_RUN - 1.5, 0, lz)
			last_climb = 1
			return Vector3(WALK_X0 + 0.9, 0, lz)
		Zone.OUT:
			if gate_broken:
				# 城門破了：除非人就在梯腳旁，否則從城門進城（再走坡道上牆），不去梯子排隊
				var lk0 := ladder_pref if ladder_pref >= 0 else _best_ladder(p.z, goal.z)
				var near_ladder := absf(p.z - LADDER_Z[lk0]) < 3.0 and p.x > WALL_X0 - LADDER_RUN - 3.0
				if goal_zone == Zone.IN or not near_ladder:
					return _through_gate(p, 1.0)
			return _to_ladder_up(p, goal, ladder_pref)
		Zone.IN:
			if goal_zone == Zone.OUT and gate_broken:
				return _through_gate(p, -1.0)
			# 往牆上（或要從梯子下去到城外）：先走坡道上牆
			var rk := nearest_ramp(p.z, goal.z)
			var rz: float = RAMP_Z[rk]
			var bottom := Vector3(WALL_X1 + RAMP_RUN + 1.0, 0, rz)
			if absf(p.z - rz) < RAMP_HALF - 0.3 and p.x < WALL_X1 + RAMP_RUN + 1.6:
				last_climb = 1
				return Vector3(WALL_X1 - 1.0, 0, rz)
			return bottom
		Zone.WALL:
			if goal_zone == Zone.IN:
				var rk2 := nearest_ramp(p.z, goal.z)
				var rz2: float = RAMP_Z[rk2]
				if p.x > WALL_X1 - 0.6 or absf(p.z - rz2) < RAMP_HALF - 0.4:
					last_climb = -1
					return Vector3(WALL_X1 + RAMP_RUN + 2.0, 0, rz2)
				return Vector3(WALL_X1 - 1.0, 0, rz2)
			# 要去城外或梯子上：走到梯頂（goal_zone 是 LADDER 時停在梯頂等）
			var lk := ladder_pref if ladder_pref >= 0 else _best_ladder(p.z, goal.z)
			var lz2: float = LADDER_Z[lk]
			if p.x > WALL_X1 + 0.1:
				return Vector3(WALL_X1 - 1.0, 0, p.z)
			if goal_zone == Zone.LADDER:
				return Vector3(WALK_X0 + 0.4, 0, lz2)
			if absf(p.z - lz2) < LADDER_HALF - 0.2 and p.x < WALK_X0 + 1.2:
				last_climb = -1
				return Vector3(WALL_X0 - LADDER_RUN - 1.5, 0, lz2)
			return Vector3(WALK_X0 + 0.6, 0, lz2)
	return goal


## 地面上從 p 直走到 goal 會不會撞到城牆（已經在門洞通道裡就不算）
func crosses_wall(p: Vector3, goal: Vector3) -> bool:
	var in_corridor := absf(p.z) < GATE_HALF - 0.4 and p.x > BASTION_X.x - 1.5 and p.x < WALL_X1 + 2.5
	if in_corridor:
		return false
	var lo := WALL_X0 - 0.3
	var hi := WALL_X1 + 0.3
	var goal_in_band := goal.x > lo and goal.x < hi
	var other_side := (p.x < lo and goal.x > hi) or (p.x > hi and goal.x < lo)
	return goal_in_band or other_side


func _best_ladder(z: float, goal_z: float) -> int:
	var best := 0
	var best_c := INF
	for k in LADDER_Z.size():
		var c := absf(z - LADDER_Z[k]) + absf(goal_z - LADDER_Z[k])
		if c < best_c:
			best_c = c
			best = k
	return best


func _to_ladder_up(p: Vector3, goal: Vector3, ladder_pref: int) -> Vector3:
	var lk := ladder_pref if ladder_pref >= 0 else _best_ladder(p.z, goal.z)
	var lz: float = LADDER_Z[lk]
	var foot_x := WALL_X0 - LADDER_RUN
	# 正對梯腳時直接往上爬；否則先走到梯腳前方
	if absf(p.z - lz) < LADDER_HALF - 0.25 and p.x > foot_x - 1.6:
		last_climb = 1
		return Vector3(WALK_X0 + 0.9, 0, lz)
	return Vector3(foot_x - 1.0, 0, lz + clampf(p.z - lz, -0.3, 0.3))


func _through_gate(p: Vector3, dir: float) -> Vector3:
	# 先對準門洞，再直穿
	if absf(p.z) < GATE_HALF - 0.6 or (p.x > WALL_X0 - 0.5 and p.x < WALL_X1 + 0.5):
		return Vector3(p.x + dir * 6.0, 0, clampf(p.z, -1.2, 1.2))
	var front := WALL_X0 - 3.5 if dir > 0.0 else WALL_X1 + 3.0
	return Vector3(front, 0, 0)


## 移動後修正：old → new（只看 x、z），回傳修正後的位置，新層放在 last_level。
## climb：+1 想往上（梯腳或坡道底），-1 想往下（梯頂）。
func resolve(level: int, old: Vector3, p: Vector3, r: float, climb: int) -> Vector3:
	last_level = level
	match level:
		0:
			return _resolve_ground(old, p, r, climb)
		1:
			return _resolve_wall(p, r, climb)
		2:
			return _resolve_ladder(p, climb)
	return p


func _resolve_ground(old: Vector3, p: Vector3, r: float, climb: int) -> Vector3:
	# 梯腳：往上爬
	if climb > 0 and p.x < WALL_X0 and p.x > WALL_X0 - LADDER_RUN - 0.3:
		var lk := nearest_ladder(p.z)
		if absf(p.z - LADDER_Z[lk]) < LADDER_HALF:
			last_level = 2
			p.x = maxf(p.x, WALL_X0 - LADDER_RUN + 0.05)
			p.z = LADDER_Z[lk]
			return p
	# 城牆本體（城門破了以後門洞可以通過）
	if p.x > WALL_X0 - r and p.x < WALL_X1 + r:
		if gate_broken and absf(p.z) < GATE_HALF - r:
			pass
		elif gate_broken and absf(p.z) < GATE_HALF and p.x > WALL_X0 and p.x < WALL_X1:
			p.z = signf(p.z) * (GATE_HALF - r)
		else:
			p.x = WALL_X0 - r if old.x < (WALL_X0 + WALL_X1) * 0.5 else WALL_X1 + r
	# 城門兩側塔樓
	for s in [-1.0, 1.0]:
		var zc: float = s * (BASTION_Z.x + BASTION_Z.y) * 0.5
		var hz := (BASTION_Z.y - BASTION_Z.x) * 0.5 + r
		if p.x > BASTION_X.x - r and p.x < BASTION_X.y and absf(p.z - zc) < hz:
			var dx := p.x - (BASTION_X.x - r)
			var dz := hz - absf(p.z - zc)
			if dx < dz:
				p.x = BASTION_X.x - r
			else:
				p.z = zc + signf(p.z - zc) * hz
	# 坡道：從低的那端走上去；其他方向當成牆擋住
	for rz in RAMP_Z:
		if p.x > WALL_X1 and p.x < WALL_X1 + RAMP_RUN + r and absf(p.z - rz) < RAMP_HALF + r:
			if climb > 0 and p.x > WALL_X1 + RAMP_RUN - 2.5 and absf(p.z - rz) < RAMP_HALF:
				last_level = 1
				return p
			var ex := WALL_X1 + RAMP_RUN + r - p.x
			var ez := RAMP_HALF + r - absf(p.z - rz)
			if ex < ez:
				p.x = WALL_X1 + RAMP_RUN + r
			else:
				p.z = rz + signf(p.z - rz if absf(p.z - rz) > 0.001 else 1.0) * (RAMP_HALF + r)
	# 攻城槌（實心障礙；城門破了以後不再擋路，免得堵住門口）
	if not gate_broken:
		var rx := p.x - ram_pos.x
		var hx := RAM_LEN * 0.5 + r
		var hz2 := RAM_HALF_W + r
		if absf(rx) < hx and absf(p.z - ram_pos.z) < hz2:
			var ex2 := hx - absf(rx)
			var ez2 := hz2 - absf(p.z - ram_pos.z)
			if ex2 < ez2:
				p.x = ram_pos.x + signf(rx) * hx
			else:
				p.z = ram_pos.z + signf(p.z - ram_pos.z if absf(p.z - ram_pos.z) > 0.001 else 1.0) * hz2
	return p


func _resolve_wall(p: Vector3, r: float, climb: int) -> Vector3:
	# 坡道上
	if p.x > WALL_X1 - 0.05:
		var on_ramp := -1
		for k in RAMP_Z.size():
			if absf(p.z - RAMP_Z[k]) < RAMP_HALF:
				on_ramp = k
		if on_ramp >= 0:
			var rz: float = RAMP_Z[on_ramp]
			p.z = clampf(p.z, rz - RAMP_HALF + r, rz + RAMP_HALF - r)
			if p.x >= WALL_X1 + RAMP_RUN - 0.1:
				last_level = 0
				p.x = WALL_X1 + RAMP_RUN + r + 0.05
			return p
		p.x = WALL_X1 - 0.05
	# 梯頂往下
	if p.x < WALK_X0 + r:
		var lk := nearest_ladder(p.z)
		if climb < 0 and absf(p.z - LADDER_Z[lk]) < LADDER_HALF:
			last_level = 2
			p.z = LADDER_Z[lk]
			p.x = minf(p.x, WALL_X0 - 0.05)
			return p
		p.x = WALK_X0 + r
	return p


func _resolve_ladder(p: Vector3, climb: int) -> Vector3:
	var lk := nearest_ladder(p.z)
	p.z = LADDER_Z[lk]
	var foot := WALL_X0 - LADDER_RUN
	if p.x >= WALK_X0 - 0.1:
		last_level = 1
		p.x = maxf(p.x, WALK_X0 + 0.4)
		return p
	if p.x <= foot:
		if climb < 0 or p.x < foot - 0.2:
			last_level = 0
			p.x = foot - 0.4
		else:
			p.x = foot
	return p


## 箭是否撞到城牆、女兒牆、塔樓、城門
## vx：箭的水平速度 x 分量。從牆頂往外射（vx < 0）的箭不會被自己的女兒牆擋住（守軍是探出城垛射的）
func blocks_arrow(p: Vector3, vx := 1.0) -> bool:
	var y := p.y - base_y
	if p.x > WALL_X0 and p.x < WALL_X1 and y < WALL_H:
		if absf(p.z) < GATE_HALF and y < GATE_TUNNEL_H and (gate_broken or p.x > WALL_X0 + 0.5):
			return false
		return true
	if vx > 0.0 and p.x > WALL_X0 and p.x < WALK_X0 - 0.1 and y < WALL_H + PARAPET_H:
		# 城垛：每 2 公尺有 0.8 公尺的缺口；梯頂整段缺口
		var lk := nearest_ladder(p.z)
		if absf(p.z - LADDER_Z[lk]) < LADDER_HALF + 0.1:
			return false
		return y < WALL_H + 0.55 or fposmod(p.z, 2.0) > 0.8
	if p.x > BASTION_X.x and p.x < BASTION_X.y and absf(p.z) > BASTION_Z.x and absf(p.z) < BASTION_Z.y and y < WALL_H + 2.6:
		return true
	return false


## 攻城槌每步更新（由 BattleManager 呼叫，crew = 槌旁活著的推槌兵人數）。回傳 true = 這一步撞了城門。
func step_ram(delta: float, crew: int, advancing: bool) -> bool:
	ram_crew = crew
	ram_swing = maxf(ram_swing - delta * 2.2, 0.0)
	if gate_broken:
		return false
	var hit := false
	if not ram_at_gate:
		if advancing and crew >= 2:
			ram_pos.x = minf(ram_pos.x + RAM_SPEED * minf(1.0, float(crew) / RAM_CREW_FULL) * delta, RAM_STOP_X)
			ram_pos.y = terrain.get_height(ram_pos.x, ram_pos.z)
		ram_at_gate = ram_pos.x >= RAM_STOP_X - 0.01
	elif crew >= 2:
		ram_hit_t -= delta * minf(1.0, float(crew) / RAM_CREW_FULL)
		if ram_hit_t <= 0.0:
			ram_hit_t = RAM_HIT_INTERVAL
			ram_swing = 1.0
			gate_hp -= RAM_HIT_DMG
			hit = true
			if gate_hp <= 0.0:
				break_gate()
	return hit


func break_gate() -> void:
	gate_hp = 0.0
	gate_broken = true
	(_gate_body.get_child(0) as CollisionShape3D).set_deferred("disabled", true)
	_gate_mesh.visible = false
	_gate_broken_mesh.visible = true


## 攻城槌旁第 k 個推槌兵的位置（兩側各一排）
func ram_slot(k: int) -> Vector3:
	var side := -1.0 if k % 2 == 0 else 1.0
	var along := float(k / 2)
	return Vector3(ram_pos.x + RAM_LEN * 0.5 - 0.6 - along * 0.85, 0, ram_pos.z + side * (RAM_HALF_W + 0.45))


func gate_point() -> Vector3:
	return Vector3(WALL_X0, base_y, 0.0)


func _process(_delta: float) -> void:
	if _ram_node:
		_ram_node.position = ram_pos
		_ram_log.position.x = -0.8 * sin(ram_swing * PI)


# ---------------------------------------------------------------------------
# 幾何（碰撞＋畫面）
# ---------------------------------------------------------------------------
func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	return m


## 方塊：lo / hi 是世界座標的兩個角；collide = 是否加碰撞
func _box(lo: Vector3, hi: Vector3, mat: Material, collide := true, parent: Node = self) -> Node3D:
	var size := hi - lo
	var center := (lo + hi) * 0.5
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	if not collide:
		mi.position = center
		parent.add_child(mi)
		return mi
	var body := StaticBody3D.new()
	body.position = center
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	body.add_child(cs)
	body.add_child(mi)
	parent.add_child(body)
	return body


## 斜放的板子：從 a 到 b（a、b 是板子上表面中線的兩端），寬 w、厚 t，沿 z 方向展開
func _slab(a: Vector3, b: Vector3, w: float, t: float, mat: Material, collide := true) -> Node3D:
	var d := b - a
	var length := d.length()
	var ang := atan2(d.y, d.x)
	var body: Node3D = StaticBody3D.new() if collide else Node3D.new()
	var up := Vector3(-sin(ang), cos(ang), 0)
	body.position = (a + b) * 0.5 - up * t * 0.5
	body.rotation.z = ang
	var mesh := BoxMesh.new()
	mesh.size = Vector3(length, t, w)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = mesh.size
		cs.shape = sh
		body.add_child(cs)
	add_child(body)
	return body


func _build_walls() -> void:
	var b := base_y
	var top := b + WALL_H
	var zmax := 82.0
	# 牆身：門洞兩側
	for seg in [Vector2(-zmax, -GATE_HALF), Vector2(GATE_HALF, zmax)]:
		_box(Vector3(WALL_X0, b - 3.0, seg.x), Vector3(WALL_X1, top, seg.y), _stone)
	# 門洞上方
	_box(Vector3(WALL_X0, b + GATE_TUNNEL_H, -GATE_HALF), Vector3(WALL_X1, top, GATE_HALF), _stone)
	# 牆頂走道顏色（薄片，只畫面）
	_box(Vector3(WALL_X0 + 0.02, top, -zmax), Vector3(WALL_X1 - 0.02, top + 0.04, zmax), _stone_dark, false)
	# 女兒牆（梯頂留缺口）＋城垛
	var cuts: Array[float] = []
	for lz in LADDER_Z:
		cuts.append(lz)
	var z0 := -zmax
	var edges: Array[Vector2] = []
	for lz in cuts:
		edges.append(Vector2(z0, lz - LADDER_HALF - 0.1))
		z0 = lz + LADDER_HALF + 0.1
	edges.append(Vector2(z0, zmax))
	for e in edges:
		_box(Vector3(WALL_X0, top, e.x), Vector3(WALK_X0 - 0.1, top + 0.55, e.y), _stone)
		var z := ceilf(e.x / 2.0) * 2.0 + 0.8
		while z + 1.2 <= e.y:
			_box(Vector3(WALL_X0, top + 0.55, z), Vector3(WALK_X0 - 0.1, top + PARAPET_H, z + 1.2), _stone, false)
			z += 2.0
	# 城門兩側外凸塔樓
	for s in [-1.0, 1.0]:
		var zl: float = BASTION_Z.x if s > 0 else -BASTION_Z.y
		var zh: float = BASTION_Z.y if s > 0 else -BASTION_Z.x
		_box(Vector3(BASTION_X.x, b - 2.0, zl), Vector3(BASTION_X.y, top + 2.6, zh), _stone)
		var zz := zl + 0.1
		while zz + 0.8 <= zh:
			_box(Vector3(BASTION_X.x, top + 2.6, zz), Vector3(BASTION_X.x + 0.6, top + 3.3, zz + 0.8), _stone, false)
			zz += 1.4
	# 南北兩端的角樓（純佈景）
	for zc in [-46.0, 46.0]:
		_box(Vector3(WALL_X0 - 1.5, b - 2.0, zc - 3.0), Vector3(WALL_X0, top + 2.4, zc + 3.0), _stone)


func _build_gate() -> void:
	var b := base_y
	_gate_body = StaticBody3D.new()
	_gate_body.name = "Gate"
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.5, GATE_TUNNEL_H + 2.0, GATE_HALF * 2.0)
	cs.shape = sh
	_gate_body.add_child(cs)
	_gate_body.position = Vector3(WALL_X0 + 0.25, b + GATE_TUNNEL_H * 0.5 - 1.0, 0)
	add_child(_gate_body)
	_gate_mesh = Node3D.new()
	_gate_body.add_child(_gate_mesh)
	# 木門板＋鐵條
	var plank_n := 5
	for k in plank_n:
		var zl := -GATE_HALF + k * (GATE_HALF * 2.0 / plank_n)
		var mi := _box(Vector3(-0.22, -GATE_TUNNEL_H * 0.5 + 1.0, zl + 0.03), Vector3(0.22, GATE_TUNNEL_H * 0.5 + 1.0, zl + GATE_HALF * 2.0 / plank_n - 0.03), _wood if k % 2 == 0 else _wood_dark, false, _gate_mesh)
		mi.name = "Plank%d" % k
	for y in [0.0, 2.4]:
		_box(Vector3(-0.3, y - 0.12, -GATE_HALF), Vector3(-0.2, y + 0.12, GATE_HALF), _mat(Color(0.25, 0.25, 0.27)), false, _gate_mesh)
	# 破門後：倒在地上的門板碎片
	_gate_broken_mesh = Node3D.new()
	_gate_broken_mesh.visible = false
	add_child(_gate_broken_mesh)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in 6:
		var mi2 := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(rng.randf_range(1.2, 2.6), 0.18, rng.randf_range(0.5, 0.9))
		mi2.mesh = bm
		mi2.material_override = _wood if k % 2 == 0 else _wood_dark
		mi2.position = Vector3(WALL_X0 + rng.randf_range(0.3, 3.2), b + 0.12, rng.randf_range(-2.0, 2.0))
		mi2.rotation = Vector3(rng.randf_range(-0.15, 0.15), rng.randf() * TAU, rng.randf_range(-0.15, 0.15))
		_gate_broken_mesh.add_child(mi2)


func _build_ladders() -> void:
	var top := base_y + WALL_H
	for lz in LADDER_Z:
		var foot_x := WALL_X0 - LADDER_RUN
		var a := Vector3(foot_x, terrain.get_height(foot_x, lz), lz)
		var b := Vector3(WALL_X0, top + 0.05, lz)
		# 碰撞：一塊斜板（玩家走上去，見 Battlefield 對玩家坡度上限的設定）
		var slab := _slab(a, b, LADDER_HALF * 2.0, 0.12, _wood, true)
		(slab.get_child(0) as MeshInstance3D).visible = false
		# 畫面：兩根側桿＋橫檔
		var d := b - a
		var n := int(d.length() / 0.45)
		for s in [-1.0, 1.0]:
			_slab(a + Vector3(0, 0, s * (LADDER_HALF - 0.08)), b + Vector3(0, 0.6, s * (LADDER_HALF - 0.08)) + d.normalized() * 0.4, 0.14, 0.14, _wood_dark, false)
		for k in range(1, n):
			var p := a + d * (float(k) / n)
			var mi := MeshInstance3D.new()
			var cm := BoxMesh.new()
			cm.size = Vector3(0.08, 0.08, LADDER_HALF * 2.0 - 0.1)
			mi.mesh = cm
			mi.material_override = _wood
			mi.position = p + Vector3(0, 0.03, 0)
			add_child(mi)


func _build_ramps() -> void:
	var top := base_y + WALL_H
	for rz in RAMP_Z:
		var a := Vector3(WALL_X1 - 0.05, top, rz)
		var bx := WALL_X1 + RAMP_RUN
		var b := Vector3(bx, terrain.get_height(bx, rz), rz)
		_slab(a, b, RAMP_HALF * 2.0, 0.5, _stone_dark, true)
		# 底下的支撐牆（畫面）
		_box(Vector3(WALL_X1, base_y - 1.0, rz - RAMP_HALF + 0.2), Vector3(WALL_X1 + RAMP_RUN * 0.45, top - 3.4, rz + RAMP_HALF - 0.2), _stone, false)


func _build_keep() -> void:
	# 城內主堡（佈景＋障礙），讓城內看起來不是空地
	var b := terrain.get_height(54.0, 0.0)
	_box(Vector3(48.0, b - 2.0, -9.0), Vector3(60.0, b + 13.0, 9.0), _stone)
	for zc in [-9.0, 9.0]:
		_box(Vector3(46.5, b - 2.0, zc - 2.5), Vector3(51.5, b + 16.0, zc + 2.5), _stone_dark)
	for zc in [-6.0, 0.0, 6.0]:
		terrain.obstacles.append(Vector3(54.0, zc, 6.8))
	terrain.call("_build_obstacle_grid")


func _build_ram() -> void:
	_ram_node = Node3D.new()
	_ram_node.name = "Ram"
	add_child(_ram_node)
	# 車架＋屋頂＋輪子＋撞木（全部佔位方塊）
	var frame := _box(Vector3(-RAM_LEN * 0.5, 0.35, -RAM_HALF_W), Vector3(RAM_LEN * 0.5, 0.55, RAM_HALF_W), _wood_dark, false, _ram_node)
	frame.name = "Frame"
	for s in [-1.0, 1.0]:
		for xx in [-RAM_LEN * 0.5 + 0.2, RAM_LEN * 0.5 - 0.35]:
			_box(Vector3(xx, 0.55, s * RAM_HALF_W - 0.08), Vector3(xx + 0.15, 2.2, s * RAM_HALF_W + 0.08), _wood_dark, false, _ram_node)
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(RAM_LEN + 0.3, 0.12, RAM_HALF_W * 1.5)
		roof.mesh = rm
		roof.material_override = _mat(Color(0.42, 0.32, 0.22))
		roof.position = Vector3(0, 2.45, s * RAM_HALF_W * 0.62)
		roof.rotation.x = -s * 0.75
		_ram_node.add_child(roof)
		for xx in [-RAM_LEN * 0.32, RAM_LEN * 0.32]:
			var wheel := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.42
			cyl.bottom_radius = 0.42
			cyl.height = 0.16
			wheel.mesh = cyl
			wheel.material_override = _wood_dark
			wheel.rotation.x = PI * 0.5
			wheel.position = Vector3(xx, 0.42, s * (RAM_HALF_W + 0.1))
			_ram_node.add_child(wheel)
	_ram_log = Node3D.new()
	_ram_node.add_child(_ram_log)
	var log_mi := MeshInstance3D.new()
	var lm := CylinderMesh.new()
	lm.top_radius = 0.28
	lm.bottom_radius = 0.28
	lm.height = RAM_LEN + 0.4
	log_mi.mesh = lm
	log_mi.material_override = _wood
	log_mi.rotation.z = PI * 0.5
	log_mi.position = Vector3(0.2, 1.45, 0)
	_ram_log.add_child(log_mi)
	var head := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.34
	hm.bottom_radius = 0.34
	hm.height = 0.5
	head.mesh = hm
	head.material_override = _mat(Color(0.3, 0.3, 0.32))
	head.rotation.z = PI * 0.5
	head.position = Vector3(RAM_LEN * 0.5 + 0.35, 1.45, 0)
	_ram_log.add_child(head)
