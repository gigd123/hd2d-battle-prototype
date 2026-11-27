class_name BattleManager
extends Node3D
## 集中式戰場管理器：擁有所有士兵資料與 AI（研究報告的核心建議）。
##
## - 士兵「不是」節點、不進物理引擎：所有資料是平行的 Packed 陣列（SoA），
##   位置直接取地形高度圖，彼此用空間網格做分離與找敵。
## - AI 分三層：軍隊（雙方指揮，約每 1.5 秒）、小隊（命令與隊形槽位，每 0.5 秒）、
##   個人（交戰中/靠近玩家每 0.15 秒決策，遠處每 0.6 秒；每幀都移動）。
##   個人決策以各自的倒數計時錯開，避免所有人同一幀思考造成尖峰。
## - 玩家命令只是「寫入命令佇列」，由小隊層下一次決策時取用，不直接改士兵狀態。
## - 戰鬥結算在 _physics_process（固定 60Hz 步長），幀率高低不影響結果。
## - 畫面由 SoldierRenderer 讀取這些陣列繪製；邏輯完全不知道畫面怎麼畫。

signal battle_finished(winner_team: int)
## 以下訊號只給畫面／音效回饋用
signal soldier_struck(point: Vector3, landed: bool)          # 士兵之間出手（命中或被擋）
signal trampled(point: Vector3, speed: float, killed: bool)   # 玩家騎馬撞上敵兵

enum State { IDLE, MOVE, ENGAGE, DEAD }
enum Order { HOLD, FOLLOW, CHARGE }

const TARGET_PLAYER := -2
const NO_TARGET := -1

# --- 可調參數（待實測調整）---
@export var squad_size := 10
@export var soldier_radius := 0.38
@export var walk_speed := 3.0
@export var run_speed := 4.2
@export var attack_range := 1.5
@export var engage_radius := 16.0       # 守位/跟隨時，敵人進入此半徑就脫離隊形交戰
@export var search_radius := 30.0       # 衝鋒時找敵半徑（超過則全場找最近）
@export var max_attackers := 3          # 攻擊槽位：一個目標最多同時被幾人圍攻
@export var max_attackers_player := 4
@export var think_near := 0.15          # 交戰中/靠近玩家的決策間隔
@export var think_far := 0.6            # 遠處未交戰的決策間隔
@export var squad_think := 0.5
@export var army_think := 1.5
@export var corpse_time := 25.0
@export var cell_size := 3.0
@export var trample_speed := 5.0        # 騎馬超過此速度（m/s）撞到敵兵會造成衝撞傷害與擊飛
@export var trample_cooldown := 0.8

# --- 士兵資料（平行陣列）---
var count := 0
var pos := PackedVector3Array()
var prev_pos := PackedVector3Array()
var vel := PackedVector3Array()
var facing := PackedVector3Array()
var team := PackedByteArray()
var squad := PackedInt32Array()
var slot := PackedInt32Array()          # 在小隊中的編號（決定隊形槽位）
var hp := PackedFloat32Array()
var state := PackedByteArray()
var target := PackedInt32Array()
var think_timer := PackedFloat32Array()
var atk_cooldown := PackedFloat32Array()
var atk_anim := PackedFloat32Array()    # >0：攻擊動作播放中
var atk_hit_at := PackedFloat32Array()  # >0：倒數到 0 時結算這一擊
var stun := PackedFloat32Array()
var hit_flash := PackedFloat32Array()
var dead_time := PackedFloat32Array()
var attackers := PackedInt32Array()     # 每個目標目前被幾人鎖定（每步重算）
var trample_cd := PackedFloat32Array()  # 被馬撞後的冷卻（避免同一人每步都被撞）

# --- 小隊資料 ---
var squad_count := 0
var squad_team := PackedByteArray()
var squad_order := PackedByteArray()
var squad_anchor := PackedVector3Array()
var squad_facing := PackedVector3Array()
var squad_timer := PackedFloat32Array()
var squad_alive := PackedInt32Array()

# --- 軍隊 ---
var alive_count := PackedInt32Array([0, 0])
var kills := PackedInt32Array([0, 0])
var command_queue: Array[Dictionary] = []
var enemy_ai_charge_at := 10.0          # 敵方指揮官：開戰後幾秒全軍衝鋒
var auto_charge_both := false           # 壓力測試：雙方都直接衝鋒
var immortal := false                   # 壓力測試選項：不死亡，維持固定負載
var battle_time := 0.0
var winner := -1
var _army_timer := 0.0
var _enemy_charged := false

# --- 外部參照 ---
var terrain: BattleTerrain
var player: PlayerController            # 可為 null（壓力測試）
var renderer: SoldierRenderer
var rng := RandomNumberGenerator.new()

# --- 空間網格（每步重建的串列頭/next 表）---
var _grid_w := 0
var _grid_origin := 0.0
var _cell_head := PackedInt32Array()
var _cell_next := PackedInt32Array()

# --- 效能量測（微秒）---
var t_grid := 0
var t_think := 0
var t_move := 0
var t_total := 0
var t_render := 0
var think_calls := 0


func setup(p_terrain: BattleTerrain, p_player: PlayerController) -> void:
	terrain = p_terrain
	player = p_player
	rng.seed = GameConfig.battle_seed
	_grid_origin = -terrain.half_extent()
	_grid_w = int(ceil(terrain.size_m / cell_size)) + 1
	_cell_head.resize(_grid_w * _grid_w)


func set_renderer(r: SoldierRenderer) -> void:
	if renderer:
		renderer.queue_free()
	renderer = r
	add_child(renderer)
	renderer.setup(self)


# ---------------------------------------------------------------------------
# 生成
# ---------------------------------------------------------------------------
## 雙方各 per_team 人，以 squad_size 人為一隊排成橫列。
func spawn_armies(per_team: int, center := Vector3.ZERO, gap := 36.0) -> void:
	_clear()
	for t in 2:
		var sign_x := -1.0 if t == 0 else 1.0
		var fwd := Vector3(-sign_x, 0, 0)
		var n_squads := int(ceil(float(per_team) / squad_size))
		var cols := mini(n_squads, 6)
		var squad_w := 5 * 1.4 + 2.5
		var remaining := per_team
		for s in n_squads:
			var c := s % cols
			var r := s / cols
			var lateral := (c - (cols - 1) * 0.5) * squad_w
			var anchor := center + Vector3(sign_x * (gap * 0.5 + r * 5.0), 0, lateral)
			var sq := _add_squad(t, anchor, fwd)
			var members := mini(squad_size, remaining)
			remaining -= members
			for k in members:
				_add_soldier(t, sq, k)
	if renderer:
		renderer.setup(self)


func _clear() -> void:
	# Packed 陣列是值型別，必須直接重新指派，不能放進陣列迴圈裡 resize
	count = 0
	squad_count = 0
	pos = PackedVector3Array()
	prev_pos = PackedVector3Array()
	vel = PackedVector3Array()
	facing = PackedVector3Array()
	team = PackedByteArray()
	squad = PackedInt32Array()
	slot = PackedInt32Array()
	hp = PackedFloat32Array()
	state = PackedByteArray()
	target = PackedInt32Array()
	think_timer = PackedFloat32Array()
	atk_cooldown = PackedFloat32Array()
	atk_anim = PackedFloat32Array()
	atk_hit_at = PackedFloat32Array()
	stun = PackedFloat32Array()
	hit_flash = PackedFloat32Array()
	dead_time = PackedFloat32Array()
	attackers = PackedInt32Array()
	trample_cd = PackedFloat32Array()
	squad_team = PackedByteArray()
	squad_order = PackedByteArray()
	squad_anchor = PackedVector3Array()
	squad_facing = PackedVector3Array()
	squad_timer = PackedFloat32Array()
	squad_alive = PackedInt32Array()
	alive_count = PackedInt32Array([0, 0])
	kills = PackedInt32Array([0, 0])
	command_queue.clear()
	battle_time = 0.0
	winner = -1
	_enemy_charged = false
	_army_timer = 0.0


func _add_squad(t: int, anchor: Vector3, fwd: Vector3) -> int:
	squad_team.append(t)
	squad_order.append(Order.CHARGE if auto_charge_both else Order.HOLD)
	squad_anchor.append(anchor)
	squad_facing.append(fwd)
	squad_timer.append(rng.randf() * squad_think)
	squad_alive.append(0)
	squad_count += 1
	return squad_count - 1


func _add_soldier(t: int, sq: int, k: int) -> void:
	var p := slot_position(sq, k)
	p.y = terrain.get_height(p.x, p.z)
	pos.append(p)
	prev_pos.append(p)
	vel.append(Vector3.ZERO)
	facing.append(squad_facing[sq])
	team.append(t)
	squad.append(sq)
	slot.append(k)
	hp.append(100.0)
	state.append(State.IDLE)
	target.append(NO_TARGET)
	think_timer.append(rng.randf() * think_far)
	atk_cooldown.append(rng.randf() * 1.0)
	atk_anim.append(0.0)
	atk_hit_at.append(0.0)
	stun.append(0.0)
	hit_flash.append(0.0)
	dead_time.append(0.0)
	attackers.append(0)
	trample_cd.append(0.0)
	squad_alive[sq] += 1
	alive_count[t] += 1
	count += 1


## 小隊隊形槽位：5 人一列，列距 1.4 公尺。
func slot_position(sq: int, k: int) -> Vector3:
	var f := squad_facing[sq]
	var right := Vector3(-f.z, 0, f.x)
	var file := k % 5
	var rank := k / 5
	return squad_anchor[sq] + right * ((file - 2) * 1.4) - f * (rank * 1.4)


# ---------------------------------------------------------------------------
# 命令（玩家輸入只寫入佇列）
# ---------------------------------------------------------------------------
func issue_order(t: int, order: int, at: Vector3, fwd: Vector3) -> void:
	command_queue.append({"team": t, "order": order, "pos": at, "fwd": fwd})


func order_name(o: int) -> String:
	match o:
		Order.HOLD:
			return "守位"
		Order.FOLLOW:
			return "跟隨"
		_:
			return "衝鋒"


# ---------------------------------------------------------------------------
# 主迴圈（固定物理步）
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if count == 0:
		return
	var t0 := Time.get_ticks_usec()
	battle_time += delta
	prev_pos = pos.duplicate()

	_rebuild_grid()
	var t1 := Time.get_ticks_usec()

	_army_tick(delta)
	_squad_tick(delta)
	_recount_attackers()
	think_calls = 0
	for i in count:
		if state[i] == State.DEAD:
			continue
		think_timer[i] -= delta
		if think_timer[i] <= 0.0:
			_think(i)
	var t2 := Time.get_ticks_usec()

	_move_and_fight(delta)
	var t3 := Time.get_ticks_usec()

	t_grid = t1 - t0
	t_think = t2 - t1
	t_move = t3 - t2
	t_total = t3 - t0
	_check_victory()


func _rebuild_grid() -> void:
	_cell_head.fill(-1)
	_cell_next.resize(count)
	for i in count:
		if state[i] == State.DEAD:
			continue
		var c := _cell_of(pos[i].x, pos[i].z)
		_cell_next[i] = _cell_head[c]
		_cell_head[c] = i


func _cell_of(x: float, z: float) -> int:
	var cx := clampi(int((x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var cz := clampi(int((z - _grid_origin) / cell_size), 0, _grid_w - 1)
	return cz * _grid_w + cx


func _army_tick(delta: float) -> void:
	_army_timer -= delta
	if _army_timer > 0.0:
		return
	_army_timer = army_think
	# 敵方指揮官（佔位）：開戰一段時間後，或玩家方逼近時，全軍衝鋒
	if not _enemy_charged:
		var close := false
		for s in squad_count:
			if squad_team[s] == 0 and squad_alive[s] > 0:
				for e in squad_count:
					if squad_team[e] == 1 and squad_alive[e] > 0 and squad_anchor[s].distance_to(squad_anchor[e]) < 22.0:
						close = true
		if battle_time >= enemy_ai_charge_at or close or auto_charge_both:
			_enemy_charged = true
			issue_order(1, Order.CHARGE, Vector3.ZERO, Vector3.ZERO)


func _squad_tick(delta: float) -> void:
	# 新命令：由小隊層在下一次決策時取用（玩家方命令延遲 ≤ squad_think）
	var pending := command_queue.duplicate()
	command_queue.clear()
	for s in squad_count:
		squad_timer[s] -= delta
		var take_now := false
		for cmd in pending:
			if int(cmd["team"]) == squad_team[s]:
				take_now = true
		if squad_timer[s] > 0.0 and not take_now:
			continue
		squad_timer[s] = squad_think
		for cmd in pending:
			if int(cmd["team"]) != squad_team[s]:
				continue
			squad_order[s] = int(cmd["order"])
			if squad_order[s] == Order.HOLD:
				# 在指定點集結：各小隊在該點附近排成橫列
				var fwd: Vector3 = cmd["fwd"]
				if fwd.length() < 0.1:
					fwd = squad_facing[s]
				squad_facing[s] = fwd
				squad_anchor[s] = _rally_point(s, cmd["pos"], fwd)
		if squad_order[s] == Order.FOLLOW and player != null:
			var pf := player.facing
			squad_facing[s] = pf
			squad_anchor[s] = _rally_point(s, player.global_position - pf * 8.0, pf)


## 第 s 個小隊在集結點附近的位置（同陣營小隊依序橫向排開）。
func _rally_point(s: int, at: Vector3, fwd: Vector3) -> Vector3:
	var idx := 0
	var total := 0
	for o in squad_count:
		if squad_team[o] == squad_team[s]:
			if o < s:
				idx += 1
			total += 1
	var right := Vector3(-fwd.z, 0, fwd.x)
	var cols := mini(total, 4)
	var c := idx % cols
	var r := idx / cols
	return at + right * ((c - (cols - 1) * 0.5) * 9.5) - fwd * (r * 5.0)


func _recount_attackers() -> void:
	attackers.fill(0)
	for i in count:
		var tg := target[i]
		if tg >= 0 and state[i] != State.DEAD:
			attackers[tg] += 1


# ---------------------------------------------------------------------------
# 個人決策：選目標
# ---------------------------------------------------------------------------
func _think(i: int) -> void:
	think_calls += 1
	var my_team := team[i]
	var sq := squad[i]
	var order := squad_order[sq]
	var p := pos[i]
	# 目前目標仍有效且不太遠就保留（避免換目標抖動）
	var tg := target[i]
	if tg >= 0 and (state[tg] == State.DEAD or p.distance_squared_to(pos[tg]) > 900.0):
		tg = NO_TARGET
	if tg == TARGET_PLAYER and (player == null or not player.is_targetable()):
		tg = NO_TARGET

	var radius := search_radius if order == Order.CHARGE else engage_radius
	var best := _find_enemy(i, p, my_team, radius)
	if best != NO_TARGET:
		tg = best
	elif tg == NO_TARGET and order == Order.CHARGE:
		tg = _find_enemy_global(p, my_team)
	# 敵方士兵也會把玩家當目標
	if my_team == 1 and player != null and player.is_targetable():
		var pd := p.distance_to(player.global_position)
		var cur_d := 1e9
		if tg >= 0:
			cur_d = p.distance_to(pos[tg])
		if pd < radius and pd < cur_d and _player_attackers() < max_attackers_player:
			tg = TARGET_PLAYER
	if tg != target[i]:
		if target[i] >= 0:
			attackers[target[i]] -= 1
		if tg >= 0:
			attackers[tg] += 1
	target[i] = tg

	# 交戰中或靠近玩家 → 高頻決策；否則低頻
	var near_player := player != null and p.distance_squared_to(player.global_position) < 400.0
	var engaged := tg != NO_TARGET and _target_pos(tg).distance_squared_to(p) < 64.0
	think_timer[i] = (think_near if (engaged or near_player) else think_far) * rng.randf_range(0.8, 1.2)


func _find_enemy(i: int, p: Vector3, my_team: int, radius: float) -> int:
	var best := NO_TARGET
	var best_d := radius * radius
	var r_cells := int(ceil(radius / cell_size))
	var c0x := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var c0z := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
	# 由近到遠一圈一圈找，找到就提早結束（超過已找到距離的圈不再找）
	for ring in r_cells + 1:
		if best != NO_TARGET and float(ring - 1) * cell_size > sqrt(best_d):
			break
		for cz in range(c0z - ring, c0z + ring + 1):
			if cz < 0 or cz >= _grid_w:
				continue
			for cx in range(c0x - ring, c0x + ring + 1):
				if cx < 0 or cx >= _grid_w:
					continue
				if maxi(absi(cx - c0x), absi(cz - c0z)) != ring:
					continue
				var j := _cell_head[cz * _grid_w + cx]
				while j != -1:
					if team[j] != my_team:
						var d := p.distance_squared_to(pos[j])
						# 攻擊槽位已滿的目標降低優先度（除非就在身邊）
						if attackers[j] >= max_attackers and target[i] != j and d > 4.0:
							d *= 4.0
						if d < best_d:
							best_d = d
							best = j
					j = _cell_next[j]
	return best


func _find_enemy_global(p: Vector3, my_team: int) -> int:
	var best := NO_TARGET
	var best_d := INF
	for j in count:
		if state[j] == State.DEAD or team[j] == my_team:
			continue
		var d := p.distance_squared_to(pos[j])
		if d < best_d:
			best_d = d
			best = j
	return best


func _player_attackers() -> int:
	var n := 0
	for i in count:
		if target[i] == TARGET_PLAYER and state[i] != State.DEAD:
			n += 1
	return n


func _target_pos(tg: int) -> Vector3:
	if tg == TARGET_PLAYER:
		return player.global_position if player else Vector3.ZERO
	return pos[tg]


# ---------------------------------------------------------------------------
# 每步移動與戰鬥（所有活著的士兵）
# ---------------------------------------------------------------------------
func _move_and_fight(delta: float) -> void:
	var has_player := player != null and not player.dead
	var pl_pos := Vector3.ZERO
	var pl_fwd := Vector3.ZERO
	var pl_speed := 0.0
	var pl_radius := 0.5
	if has_player:
		pl_pos = player.global_position
		var mv := player.move_velocity()
		pl_speed = mv.length()
		pl_fwd = mv / pl_speed if pl_speed > 0.1 else player.facing
		pl_radius = 1.3 if player.mounted else 0.5
	var sep_dist := soldier_radius * 2.0 + 0.1
	var sep_d2 := sep_dist * sep_dist
	var obstacles := terrain.obstacles

	for i in count:
		if state[i] == State.DEAD:
			if hit_flash[i] > 0.0:
				hit_flash[i] -= delta
			# 致命一擊的擊退：屍體滑出去後停下
			var dv := vel[i]
			if dv.length_squared() > 0.01:
				var dp := pos[i] + dv * delta
				dp = terrain.clamp_to_map(dp, 4.0)
				dp.y = terrain.get_height(dp.x, dp.z)
				pos[i] = dp
				vel[i] = dv * maxf(0.0, 1.0 - 6.0 * delta)
			continue
		var p := pos[i]
		var v := vel[i]
		var tg := target[i]
		var desired := Vector3.ZERO
		var face := facing[i]
		hit_flash[i] = maxf(hit_flash[i] - delta, 0.0)
		atk_cooldown[i] -= delta
		atk_anim[i] = maxf(atk_anim[i] - delta, 0.0)

		if stun[i] > 0.0:
			stun[i] -= delta
		elif tg != NO_TARGET:
			var tp := _target_pos(tg)
			var to := tp - p
			to.y = 0.0
			var d := to.length()
			var reach := attack_range + (0.9 if tg == TARGET_PLAYER and player.mounted else 0.0)
			if d > 0.001:
				face = to / d
			if d > reach * 0.85:
				desired = face * (run_speed if d > 6.0 else walk_speed)
			elif atk_cooldown[i] <= 0.0 and atk_hit_at[i] <= 0.0:
				# 出手：蓄力 0.25 秒後結算
				atk_anim[i] = 0.45
				atk_hit_at[i] = 0.25
				atk_cooldown[i] = rng.randf_range(1.2, 1.8)
		else:
			var order := squad_order[squad[i]]
			if order != Order.CHARGE:
				var sp := slot_position(squad[i], slot[i])
				var to := sp - p
				to.y = 0.0
				var d := to.length()
				if d > 0.4:
					desired = to / d * (run_speed if d > 8.0 else walk_speed) * minf(1.0, d / 1.5)
					face = to / d
				else:
					face = squad_facing[squad[i]]

		# 攻擊結算
		if atk_hit_at[i] > 0.0:
			atk_hit_at[i] -= delta
			if atk_hit_at[i] <= 0.0 and tg != NO_TARGET:
				var tp2 := _target_pos(tg)
				var reach2 := attack_range + 0.4 + (0.9 if tg == TARGET_PLAYER and player.mounted else 0.0)
				if Vector2(tp2.x - p.x, tp2.z - p.z).length() <= reach2 and rng.randf() < 0.75:
					var dmg := rng.randf_range(9.0, 14.0)
					if tg == TARGET_PLAYER:
						player.take_damage(dmg)
					else:
						apply_damage(tg, dmg, face * 0.15)
					soldier_struck.emit(p + face * 0.6 + Vector3(0, 1.2, 0), true)
				else:
					soldier_struck.emit(p + face * 0.6 + Vector3(0, 1.2, 0), false)

		# 分離力（網格鄰居）
		var push := Vector3.ZERO
		var cx := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
		var cz := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
		for gz in range(maxi(cz - 1, 0), mini(cz + 2, _grid_w)):
			for gx in range(maxi(cx - 1, 0), mini(cx + 2, _grid_w)):
				var j := _cell_head[gz * _grid_w + gx]
				while j != -1:
					if j != i:
						var dx := p.x - pos[j].x
						var dz := p.z - pos[j].z
						var d2 := dx * dx + dz * dz
						if d2 < sep_d2 and d2 > 0.000001:
							var dd := sqrt(d2)
							var k := (sep_dist - dd) / dd
							push.x += dx * k
							push.z += dz * k
					j = _cell_next[j]
		# 地形障礙（岩石）
		for ob in obstacles:
			var ox := p.x - ob.x
			var oz := p.z - ob.y
			var rr := ob.z + soldier_radius
			var od2 := ox * ox + oz * oz
			if od2 < rr * rr and od2 > 0.000001:
				var od := sqrt(od2)
				push.x += ox / od * (rr - od) * 2.0
				push.z += oz / od * (rr - od) * 2.0
		# 玩家與馬：重疊就推開；高速奔馳時前方的士兵會往側邊閃避
		if has_player:
			var rx := p.x - pl_pos.x
			var rz := p.z - pl_pos.z
			var rd2 := rx * rx + rz * rz
			var min_d := pl_radius + soldier_radius
			trample_cd[i] = maxf(trample_cd[i] - delta, 0.0)
			if rd2 < min_d * min_d and rd2 > 0.000001:
				var rd := sqrt(rd2)
				push.x += rx / rd * (min_d - rd) * 3.0
				push.z += rz / rd * (min_d - rd) * 3.0
				# 衝撞：高速騎馬正面撞上敵兵 → 傷害＋往前擊飛（速度越快越痛、飛越遠）
				var ahead_d := rx * pl_fwd.x + rz * pl_fwd.z
				if player.mounted and pl_speed > trample_speed and team[i] != player.team \
						and trample_cd[i] <= 0.0 and ahead_d > -0.3:
					trample_cd[i] = trample_cooldown
					var radial := Vector3(rx / rd, 0, rz / rd)
					var knock := (pl_fwd * 0.7 + radial * 0.6).normalized() * (0.6 + pl_speed * 0.1)
					var killed := apply_damage(i, 6.0 + pl_speed * 1.2, knock)
					v = vel[i]
					trampled.emit(p + Vector3(0, 1.0, 0), pl_speed, killed)
			# 只有友軍會讓路；敵軍不閃避（否則衝鋒永遠撞不到人）
			if team[i] == player.team and pl_speed > 3.0 and rd2 < 25.0:
				var ahead := rx * pl_fwd.x + rz * pl_fwd.z
				var lateral := rx * -pl_fwd.z + rz * pl_fwd.x
				if ahead > 0.0 and ahead < 5.0 and absf(lateral) < 1.6:
					var side := 1.0 if lateral >= 0.0 else -1.0
					desired += Vector3(-pl_fwd.z, 0, pl_fwd.x) * side * 3.5

		v = v.lerp(desired, minf(1.0, 8.0 * delta))
		p.x += (v.x + push.x * 4.0) * delta
		p.z += (v.z + push.z * 4.0) * delta
		p = terrain.clamp_to_map(p, 4.0)
		p.y = terrain.get_height(p.x, p.z)
		pos[i] = p
		vel[i] = v
		facing[i] = face
		if atk_anim[i] > 0.0:
			state[i] = State.ENGAGE
		elif v.length_squared() > 0.09:
			state[i] = State.MOVE
		else:
			state[i] = State.IDLE


# ---------------------------------------------------------------------------
# 給玩家武器與馬使用的查詢
# ---------------------------------------------------------------------------
func soldier_position(i: int) -> Vector3:
	return pos[i]


func soldier_velocity(i: int) -> Vector3:
	return vel[i]


## 回傳 true 表示這一擊造成死亡。knock：水平擊退位移（公尺）。
func apply_damage(i: int, dmg: float, knock: Vector3) -> bool:
	if state[i] == State.DEAD:
		return false
	hit_flash[i] = 0.15
	stun[i] = 0.25 + knock.length() * 0.15
	atk_hit_at[i] = 0.0          # 被打中會中斷出手
	# 擊退改成速度衝量：硬直期間速度以每秒 8 倍衰減，總位移約等於 knock 長度，畫面上是滑出去而不是瞬移
	vel[i] = vel[i] + Vector3(knock.x, 0, knock.z) * 8.0
	if immortal:
		return false
	hp[i] -= dmg
	if hp[i] <= 0.0:
		_kill(i)
		return true
	return false


func _kill(i: int) -> void:
	state[i] = State.DEAD
	hp[i] = 0.0
	dead_time[i] = battle_time
	target[i] = NO_TARGET
	atk_anim[i] = 0.0
	alive_count[team[i]] -= 1
	kills[1 - team[i]] += 1
	squad_alive[squad[i]] -= 1


## 線段掃掠命中：前一步刀身 (a0→b0) 到這一步刀身 (a1→b1) 掃過的四邊形，
## 對每個敵方士兵的身體（腳、胸、頭三個球）求距離。exclude 是本次揮擊已命中的目標。
func sweep_query(a0: Vector3, b0: Vector3, a1: Vector3, b1: Vector3, radius: float, attacker_team: int, exclude: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	var lo := Vector3(minf(minf(a0.x, b0.x), minf(a1.x, b1.x)), 0, minf(minf(a0.z, b0.z), minf(a1.z, b1.z)))
	var hi := Vector3(maxf(maxf(a0.x, b0.x), maxf(a1.x, b1.x)), 0, maxf(maxf(a0.z, b0.z), maxf(a1.z, b1.z)))
	var margin := 1.0
	var c_lo_x := clampi(int((lo.x - margin - _grid_origin) / cell_size), 0, _grid_w - 1)
	var c_lo_z := clampi(int((lo.z - margin - _grid_origin) / cell_size), 0, _grid_w - 1)
	var c_hi_x := clampi(int((hi.x + margin - _grid_origin) / cell_size), 0, _grid_w - 1)
	var c_hi_z := clampi(int((hi.z + margin - _grid_origin) / cell_size), 0, _grid_w - 1)
	var hit_r := radius + soldier_radius
	var heights := [0.5, 1.1, 1.6]
	for cz in range(c_lo_z, c_hi_z + 1):
		for cx in range(c_lo_x, c_hi_x + 1):
			var j := _cell_head[cz * _grid_w + cx]
			while j != -1:
				if team[j] != attacker_team and state[j] != State.DEAD and not exclude.has(j):
					for h in heights:
						var c: Vector3 = pos[j] + Vector3(0, h, 0)
						if _dist_point_tri(c, a0, b0, b1) <= hit_r or _dist_point_tri(c, a0, b1, a1) <= hit_r:
							out.append(j)
							break
				j = _cell_next[j]
	return out


## 給馬用：p 周圍半徑 r 內有幾個活著的士兵（雙方都算，人牆會擋馬）。
func count_blockers(p: Vector3, r: float) -> int:
	var n := 0
	var r2 := r * r
	var cx := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var cz := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
	for gz in range(maxi(cz - 1, 0), mini(cz + 2, _grid_w)):
		for gx in range(maxi(cx - 1, 0), mini(cx + 2, _grid_w)):
			var j := _cell_head[gz * _grid_w + gx]
			while j != -1:
				var dx := p.x - pos[j].x
				var dz := p.z - pos[j].z
				if dx * dx + dz * dz < r2:
					n += 1
				j = _cell_next[j]
	return n


static func _dist_point_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	return p.distance_to(_closest_on_tri(p, a, b, c))


## Ericson《Real-Time Collision Detection》的點到三角形最近點。
static func _closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := va + vb + vc
	if absf(denom) < 1e-9:
		return a
	var v := vb / denom
	var w := vc / denom
	return a + ab * v + ac * w


# ---------------------------------------------------------------------------
func _check_victory() -> void:
	if winner != -1:
		return
	if alive_count[0] <= 0 or alive_count[1] <= 0:
		winner = 1 if alive_count[0] <= 0 else 0
		battle_finished.emit(winner)


func stats_text() -> String:
	var s := "我軍 %d　敵軍 %d　擊殺 %d：%d　戰鬥 %.0f 秒" % [alive_count[0], alive_count[1], kills[0], kills[1], battle_time]
	if squad_count > 0:
		s += "　我軍命令：%s" % order_name(_first_order(0))
	s += "\n戰場邏輯 %.2f ms（網格 %.2f／決策 %.2f［%d 次］／移動戰鬥 %.2f）　士兵畫面 %.2f ms" % [
		t_total / 1000.0, t_grid / 1000.0, t_think / 1000.0, think_calls, t_move / 1000.0, t_render / 1000.0]
	if winner != -1:
		s += "\n%s勝利！按 R 重開" % ("我軍" if winner == 0 else "敵軍")
	return s


func _first_order(t: int) -> int:
	for s in squad_count:
		if squad_team[s] == t:
			return squad_order[s]
	return Order.HOLD


func append_debug_lines(pts: PackedVector3Array, cols: PackedColorArray) -> void:
	# 小隊集結點（十字）與每個士兵指向目標的線（只畫前 200 條）
	for s in squad_count:
		if squad_alive[s] <= 0 or squad_order[s] == Order.CHARGE:
			continue
		var a := squad_anchor[s]
		a.y = terrain.get_height(a.x, a.z) + 0.2
		var c := Color(0.3, 0.6, 1.0) if squad_team[s] == 0 else Color(1.0, 0.4, 0.3)
		pts.append(a - Vector3(1, 0, 0)); pts.append(a + Vector3(1, 0, 0)); cols.append(c); cols.append(c)
		pts.append(a - Vector3(0, 0, 1)); pts.append(a + Vector3(0, 0, 1)); cols.append(c); cols.append(c)
	var drawn := 0
	for i in count:
		if drawn >= 200:
			break
		if state[i] == State.DEAD or target[i] == NO_TARGET:
			continue
		var c2 := Color(0.3, 0.6, 1.0, 0.5) if team[i] == 0 else Color(1.0, 0.4, 0.3, 0.5)
		pts.append(pos[i] + Vector3(0, 1.0, 0))
		pts.append(_target_pos(target[i]) + Vector3(0, 1.0, 0))
		cols.append(c2); cols.append(c2)
		drawn += 1


func _process(_delta: float) -> void:
	if renderer == null:
		return
	var t0 := Time.get_ticks_usec()
	renderer.render(self, get_viewport().get_camera_3d(), Engine.get_physics_interpolation_fraction())
	t_render = Time.get_ticks_usec() - t0
