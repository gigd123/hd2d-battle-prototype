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
signal arrow_fired(point: Vector3)
signal arrow_hit(point: Vector3, on_unit: bool)
signal cavalry_impact(point: Vector3, speed: float)            # 騎兵衝撞敵兵
signal siege_event(text: String)                               # 攻城戰的戰況提示（城門被攻破等）

enum State { IDLE, MOVE, ENGAGE, DEAD }
enum Order { HOLD, FOLLOW, CHARGE, MOVE, ATTACK }
## 小隊陣型：橫隊（預設）、緊密（盾牆）、鬆散（減少箭傷集中）、楔形（騎兵衝鋒）
enum Form { LINE, TIGHT, LOOSE, WEDGE }
const FORM_NAMES := ["橫隊", "緊密", "鬆散", "楔形"]
## 指令要給哪些兵種（位元遮罩）：劍盾兵算步兵
const MASK_INF := 1 | 8
const MASK_ARC := 2
const MASK_CAV := 4
const MASK_ALL := 15
const ADVANCE_STOP := 52.0           # 電腦推進到雙方相距約這麼遠（剛好在弓兵射程外一點）
const MARCH_SPEED := 2.6        # 列隊行進時集結點的移動速度（m/s，比步兵走路慢一點，隊伍跟得上）
const LEASH := 3.5              # 保持陣型時，離開自己槽位超過這個距離就回位
## 兵種（與 PlaceholderArt.Unit 相同順序）
enum UnitType { INFANTRY, ARCHER, CAVALRY, SWORDSMAN }

# --- 兵種數值表（索引 = UnitType）。原型暫定值，待遊玩調整 ---
const U_WALK := [3.0, 3.0, 5.0, 3.0]
const U_RUN := [4.2, 4.0, 9.5, 4.2]
const U_HP := [100.0, 70.0, 150.0, 100.0]
# 攻擊距離、傷害、出手間隔、盾等「手上拿什麼」的數值在 UnitDefs（scripts/battle/unit_defs.gd）的武器配置表
const U_RADIUS := [0.38, 0.38, 0.75, 0.38]
const U_HEIGHT := [1.8, 1.8, 2.5, 1.8]
const U_SPACING := [1.4, 1.4, 2.4, 1.4]       # 隊形間距
const U_NAMES := ["步兵", "弓兵", "騎兵", "劍盾兵"]
## 劍盾兵（目前只有攻城戰守方用）：出手比長槍快，正面的盾有機率擋下近戰、減少箭傷
## 雲梯上腳步不穩：爬梯的人出手傷害 ×0.8（被打不加傷害）
const LADDER_DEAL_MULT := 0.8

# 弓兵
const ARCHER_RANGE := 42.0
## 高地優勢：每高出 1 公尺，射程 +1.5 公尺（上限 +12）、箭傷 +4%（上限 +35%）；低處射高處則相反
const HIGH_GROUND_RANGE_PER_M := 1.5
const HIGH_GROUND_RANGE_MAX := 12.0
const HIGH_GROUND_DMG_PER_M := 0.04
const ARCHER_MIN_RANGE := 6.0
const ARROW_GRAVITY := 12.0
const ARROW_SPEED := 24.0              # 用來估算飛行時間（距離 / 速度）
const ARROW_DAMAGE_MIN := 10.0
const ARROW_DAMAGE_MAX := 15.0
const ARROW_DAMAGE_PLAYER := 8.0
const MAX_ARROWS := 384
const ARROW_STUCK_TIME := 4.0
# 騎兵
const CAV_CHARGE_SPEED := 6.0          # 超過此速度撞到敵兵算衝撞
const CAV_MELEE_TIME := 4.0            # 纏鬥這麼久就脫離、跑遠再衝
const CAV_DISENGAGE_TIME := 2.2
## 騎兵轉向速度（弧度／秒）：低速 → 全速。馬不能平移，只能邊前進邊轉
const CAV_TURN_SLOW := 3.2
const CAV_TURN_FAST := 1.6
## 騎兵被分離力推動的比例（馬比步兵重，比較不會被人群推著橫移）
const CAV_PUSH_SCALE := 0.35

## 攻城戰的小隊任務
enum Role { NORMAL, RAM, RESERVE, WALLGUARD, GATE }

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
@export var cell_size := 1.6
@export var trample_speed := 5.0        # 騎馬超過此速度（m/s）撞到敵兵會造成衝撞傷害與擊飛
@export var trample_cooldown := 0.8

# --- 士兵資料（平行陣列）---
var count := 0
var pos := PackedVector3Array()
var prev_pos := PackedVector3Array()
## 士兵模擬分攤（見 _physics_process）：總人數達到 SIM_DIV_FROM 就讓每個士兵每 2 個物理步更新一次（30Hz），兩半輪流
const SIM_DIV_FROM := 300
## 推擠：一個士兵最多同時被幾個重疊的鄰居推（擠成一團時不必每個都算，效果差不多）
const MAX_CONTACTS := 8
var sim_div := 1
var _sim_phase := 0
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
var utype := PackedByteArray()          # 兵種
var rad := PackedFloat32Array()         # 碰撞半徑（依兵種）
var engage_t := PackedFloat32Array()    # 騎兵：已纏鬥秒數
var disengage_t := PackedFloat32Array() # 騎兵：>0 時正在脫離（往前跑開）
var push_s := PackedVector3Array()      # 平滑後的推擠速度（避免人群裡每步來回抖動）
var lvl := PackedByteArray()            # 攻城戰：所在層（0 地面、1 牆頂／坡道、2 雲梯上）；野戰永遠 0
var lo := PackedByteArray()             # 武器配置（UnitDefs 的編號），也是士兵圖集的編號

# --- 箭矢（固定容量環狀緩衝）---
var arrow_pos := PackedVector3Array()
var arrow_vel := PackedVector3Array()
var arrow_team := PackedByteArray()
var arrow_state := PackedByteArray()    # 0 無、1 飛行中、2 插在地上
var arrow_life := PackedFloat32Array()
var arrow_mult := PackedFloat32Array()   # 高地優勢的傷害倍率
var arrow_dmg := PackedFloat32Array()    # >0：玩家射的箭（固定傷害，命中回報給玩家）
var _arrow_next := 0
var arrows_in_flight := 0

## 編成比例（每方）：其餘為步兵
@export var archer_ratio := 0.25
@export var cavalry_ratio := 0.15

# --- 小隊資料 ---
var squad_count := 0
var squad_team := PackedByteArray()
var squad_order := PackedByteArray()
var squad_anchor := PackedVector3Array()
var squad_facing := PackedVector3Array()
var squad_timer := PackedFloat32Array()
var squad_alive := PackedInt32Array()
var squad_type := PackedByteArray()
var squad_zone := PackedByteArray()     # 攻城戰：小隊集結點所在區域（SiegeMap.Zone）
var squad_role := PackedByteArray()     # 攻城戰：小隊任務（Role）
var squad_ladder := PackedInt32Array()  # 攻城戰：攻方小隊指定的雲梯（-1 = 自己挑）
var squad_lo := PackedByteArray()       # 小隊的武器配置
var squad_form := PackedByteArray()     # 陣型（Form）
var squad_keep := PackedByteArray()     # 1 = 保持陣型：只打槽位附近的敵人，打完回位
var squad_off := PackedVector2Array()   # 群組排列中的位置（x = 往右、y = 往後，公尺），跟隨與移動時沿用
var squad_goal := PackedVector3Array()  # MOVE：集結點最後要到的位置
var squad_tsq := PackedInt32Array()     # ATTACK：目標敵方小隊
var squad_center := PackedVector3Array() # 每步重算：活著隊員的平均位置
var squad_spread := PackedFloat32Array() # 每步重算：隊員離中心最遠的距離
var _sq_head := PackedInt32Array()      # 每步重算：小隊成員串列（活著的）
var _sq_next := PackedInt32Array()
var _player_att_n := 0                  # 每步重算：正在打玩家的士兵數
var _ai_charge_t := [0.0, 0.0]          # 電腦指揮官下令衝鋒的時間
var _ai_phase := [0, 0]                 # 電腦指揮官：0 待命、1 列隊推進中、2 步騎已衝鋒、3 全軍衝鋒

# 武器配置表展開成陣列（每步迴圈裡查表比查 Dictionary 快）
var _l_reach := PackedFloat32Array()
var _l_dmg_min := PackedFloat32Array()
var _l_dmg_max := PackedFloat32Array()
var _l_cd_min := PackedFloat32Array()
var _l_cd_max := PackedFloat32Array()
var _l_cos_half := PackedFloat32Array()
var _l_max_t := PackedInt32Array()
var _l_acc := PackedFloat32Array()
var _l_block := PackedFloat32Array()
var _l_arrow := PackedFloat32Array()
var _l_min_d := PackedFloat32Array()
var _l_close := PackedFloat32Array()
var _l_backoff := PackedByteArray()
var _l_knock := PackedFloat32Array()
var _l_vs_cav := PackedFloat32Array()
var _l_charge := PackedFloat32Array()

# ---- 戰鬥統計（結算畫面） ----
## 擊殺來源
enum Src { MELEE, ARROW, CHARGE, PLAYER }
const SRC_NAMES := ["近戰", "弓箭", "騎兵衝撞", "玩家"]
## [陣營 * 4 + 兵種]：開場人數、陣亡人數
var stat_start := PackedInt32Array()
var stat_dead := PackedInt32Array()
## [陣營 * 4 + 來源]：這一方用哪種方式擊殺了多少敵人
var stat_kill_src := PackedInt32Array()
## 每一方的 AI 指揮官設定（BattleSetup.AiMode）；ai_team[t] = false 表示由玩家指揮
var ai_team := [false, true]
var ai_mode := [BattleSetup.AiMode.HOLD, BattleSetup.AiMode.NORMAL]
var _ai_charged := [false, false]
## 野戰時間上限（秒，0 = 不限）；時間到以剩餘人數判勝負，相同算平手（winner = 2）
var time_limit := 0.0
## 雙方開戰時的陣線距離（spawn_from_setup 依弓兵射程與地圖大小決定）與各方後方位置
var deploy_gap := 36.0
var rear_x := [-30.0, 30.0]

# --- 軍隊 ---
var alive_count := PackedInt32Array([0, 0])
var kills := PackedInt32Array([0, 0])
var command_queue: Array[Dictionary] = []
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

# --- 攻城戰（siege == null 時是一般野戰，以下都不作用）---
var siege: SiegeMap = null
var siege_attacker := 1                 # 攻方陣營；守方 = 1 - siege_attacker
var siege_start_delay := 6.0            # 開局幾秒後攻方開始進攻
var siege_time_limit := 600.0           # 時間到攻方還沒打下來 → 守方勝
var siege_started := false
var sortie := false                     # 守方出城追擊（攻方快死光時）
var _gate_event_done := false
var _siege_start_counts := PackedInt32Array([0, 0])

# --- 空間網格（每步重建的串列頭/next 表）---
var _grid_w := 0
var _grid_origin := 0.0
var _cell_head := PackedInt32Array()
var _cell_next := PackedInt32Array()

# --- 效能量測（微秒）---
var t_grid := 0
var t_think := 0
var t_move := 0
var t_arrows := 0
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
	_build_loadout_tables()


func _build_loadout_tables() -> void:
	var n := UnitDefs.count()
	# Packed 陣列是值型別，要逐一 resize（放進陣列迴圈 resize 的是複本）
	_l_reach.resize(n); _l_dmg_min.resize(n); _l_dmg_max.resize(n); _l_cd_min.resize(n); _l_cd_max.resize(n)
	_l_cos_half.resize(n); _l_acc.resize(n); _l_block.resize(n); _l_arrow.resize(n); _l_min_d.resize(n)
	_l_close.resize(n); _l_knock.resize(n); _l_vs_cav.resize(n); _l_charge.resize(n)
	_l_max_t.resize(n)
	_l_backoff.resize(n)
	for k in n:
		var d := UnitDefs.get_def(k)
		_l_reach[k] = d["reach"]
		_l_dmg_min[k] = d["dmg_min"]
		_l_dmg_max[k] = d["dmg_max"]
		_l_cd_min[k] = d["cd_min"]
		_l_cd_max[k] = d["cd_max"]
		_l_cos_half[k] = cos(deg_to_rad(float(d["arc_deg"]) * 0.5))
		_l_max_t[k] = d["max_targets"]
		_l_acc[k] = d["accuracy"]
		_l_block[k] = d["block"]
		_l_arrow[k] = d["arrow_mult"]
		_l_min_d[k] = d["min_dist"]
		_l_close[k] = d["close_mult"]
		_l_backoff[k] = 1 if d["backoff"] else 0
		_l_knock[k] = d["knock"]
		_l_vs_cav[k] = d["vs_cavalry"]
		_l_charge[k] = d["charge_mult"]


func set_renderer(r: SoldierRenderer) -> void:
	if renderer:
		renderer.queue_free()
	renderer = r
	add_child(renderer)
	renderer.setup(self)


# ---------------------------------------------------------------------------
# 生成
# ---------------------------------------------------------------------------
## 雙方各 per_team 人，以 squad_size 人為一隊。
## 編成：步兵小隊在前排、弓兵小隊在步兵後方、騎兵小隊在兩翼。
func spawn_armies(per_team: int, center := Vector3.ZERO, gap := 36.0) -> void:
	_clear()
	_reset_arrows()
	for t in 2:
		var sign_x := -1.0 if t == 0 else 1.0
		var fwd := Vector3(-sign_x, 0, 0)
		var n_squads := int(ceil(float(per_team) / squad_size))
		var n_cav := roundi(n_squads * cavalry_ratio)
		var n_arc := roundi(n_squads * archer_ratio)
		if n_squads >= 4:
			n_cav = maxi(n_cav, 1)
		if n_squads >= 3:
			n_arc = maxi(n_arc, 1)
		var n_inf := maxi(n_squads - n_cav - n_arc, 1)
		n_arc = mini(n_arc, n_squads - n_inf)
		n_cav = n_squads - n_inf - n_arc
		var types: Array[int] = []
		for k in n_inf:
			types.append(UnitType.INFANTRY)
		for k in n_arc:
			types.append(UnitType.ARCHER)
		for k in n_cav:
			types.append(UnitType.CAVALRY)
		var remaining := per_team
		var inf_cols := mini(n_inf, 6)
		var line_w := inf_cols * 9.5
		var idx := {UnitType.INFANTRY: 0, UnitType.ARCHER: 0, UnitType.CAVALRY: 0}
		for s_i in types.size():
			var ut: int = types[s_i]
			var k: int = idx[ut]
			idx[ut] = k + 1
			var depth := 0.0
			var lateral := 0.0
			match ut:
				UnitType.INFANTRY:
					lateral = (k % inf_cols - (inf_cols - 1) * 0.5) * 9.5
					depth = (k / inf_cols) * 5.0
				UnitType.ARCHER:
					var ac := mini(n_arc, 6)
					lateral = (k % ac - (ac - 1) * 0.5) * 9.5
					depth = ceil(float(n_inf) / inf_cols) * 5.0 + 3.0 + (k / ac) * 5.0
				UnitType.CAVALRY:
					var side := -1.0 if k % 2 == 0 else 1.0
					lateral = side * (line_w * 0.5 + 8.0 + (k / 2) * 13.0)
					depth = 2.0
			var anchor := center + Vector3(sign_x * (gap * 0.5 + depth), 0, lateral)
			var sq := _add_squad(t, anchor, fwd, ut)
			var members := mini(squad_size, remaining)
			remaining -= members
			for m in members:
				_add_soldier(t, sq, m)
	_init_offsets()
	if renderer:
		renderer.setup(self)


## 開局先算好群組排列位移（「跟隨我」要用）
func _init_offsets() -> void:
	for t in 2:
		_arrange(_select(t, MASK_ALL))


## 依戰鬥設定生成雙方部隊（初始選單用）。每一列編成依 squad_size 切成小隊：
## 步兵小隊排成前排（最多 6 隊一排）、弓兵在步兵後方、騎兵在兩翼。
## 雙方陣線距離 = 弓兵射程＋接近緩衝（地圖越大緩衝越長），開局不會直接落在射程內。
func spawn_from_setup(st: BattleSetup) -> void:
	_clear()
	_reset_arrows()
	var size := terrain.size_m
	var buffer := 20.0 if size <= 160 else (28.0 if size <= 240 else 38.0)
	deploy_gap = ARCHER_RANGE + buffer
	ai_team = [st.player_side != 0, st.player_side != 1]
	ai_mode = st.ai_mode.duplicate()
	time_limit = st.time_limit
	var skip_row := st.player_slot_row()
	var lim := terrain.half_extent() - 10.0
	for t in 2:
		var sign_x := -1.0 if t == 0 else 1.0
		var fwd := Vector3(-sign_x, 0, 0)
		var groups := [[], [], []]           # 步兵、弓兵、騎兵：每項 [配置, 人數]
		var rows: Array = st.armies[t]
		for k in rows.size():
			var n := int(rows[k]["count"])
			if t == st.player_side and k == skip_row:
				n -= 1
			var u := clampi(int(rows[k]["unit"]), 0, 2)
			var l := UnitDefs.resolve(str(rows[k]["loadout"]), u)
			while n > 0:
				var m := mini(n, squad_size)
				groups[u].append([l, m])
				n -= m
		var n_inf: int = groups[0].size()
		var n_arc: int = groups[1].size()
		var inf_cols := clampi(n_inf, 1, 6)
		var arc_cols := clampi(n_arc, 1, 6)
		var line_w: float = maxf(inf_cols if n_inf > 0 else arc_cols, 1) * 9.5
		var inf_depth: float = ceil(float(n_inf) / inf_cols) * 5.0 if n_inf > 0 else 0.0
		var max_depth := 0.0
		for u in 3:
			var list: Array = groups[u]
			for k in list.size():
				var depth := 0.0
				var lateral := 0.0
				match u:
					0:
						lateral = (k % inf_cols - (inf_cols - 1) * 0.5) * 9.5
						depth = (k / inf_cols) * 5.0
					1:
						var row_n := mini(arc_cols, n_arc - (k / arc_cols) * arc_cols)
						lateral = (k % arc_cols - (row_n - 1) * 0.5) * 9.5
						depth = inf_depth + (3.0 if n_inf > 0 else 0.0) + (k / arc_cols) * 5.0
					2:
						# 兩翼各最多 4 隊並排，再多就往後排
						var side := -1.0 if k % 2 == 0 else 1.0
						var w := k / 2
						lateral = side * (line_w * 0.5 + 8.0 + (w % 4) * 13.0)
						depth = 2.0 + (w / 4) * 8.0
				max_depth = maxf(max_depth, depth)
				var anchor := Vector3(sign_x * (deploy_gap * 0.5 + depth), 0, clampf(lateral, -lim, lim))
				anchor.x = clampf(anchor.x, -lim, lim)
				var sq := _add_squad(t, anchor, fwd, u, int(list[k][0]))
				for m in int(list[k][1]):
					_add_soldier(t, sq, m)
		rear_x[t] = clampf(sign_x * (deploy_gap * 0.5 + max_depth + 9.0), -lim, lim)
	_init_offsets()
	if renderer:
		renderer.setup(self)


func _reset_arrows() -> void:
	arrow_pos = PackedVector3Array()
	arrow_vel = PackedVector3Array()
	arrow_team = PackedByteArray()
	arrow_state = PackedByteArray()
	arrow_life = PackedFloat32Array()
	arrow_mult = PackedFloat32Array()
	arrow_mult.resize(MAX_ARROWS)
	arrow_dmg = PackedFloat32Array()
	arrow_dmg.resize(MAX_ARROWS)
	arrow_pos.resize(MAX_ARROWS)
	arrow_vel.resize(MAX_ARROWS)
	arrow_team.resize(MAX_ARROWS)
	arrow_state.resize(MAX_ARROWS)
	arrow_life.resize(MAX_ARROWS)
	_arrow_next = 0
	arrows_in_flight = 0


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
	utype = PackedByteArray()
	rad = PackedFloat32Array()
	engage_t = PackedFloat32Array()
	disengage_t = PackedFloat32Array()
	push_s = PackedVector3Array()
	lvl = PackedByteArray()
	lo = PackedByteArray()
	squad_lo = PackedByteArray()
	squad_form = PackedByteArray()
	squad_keep = PackedByteArray()
	squad_off = PackedVector2Array()
	squad_goal = PackedVector3Array()
	squad_tsq = PackedInt32Array()
	squad_center = PackedVector3Array()
	squad_spread = PackedFloat32Array()
	_ai_phase = [0, 0]
	_ai_charge_t = [0.0, 0.0]
	stat_start = PackedInt32Array(); stat_start.resize(8)
	stat_dead = PackedInt32Array(); stat_dead.resize(8)
	stat_kill_src = PackedInt32Array(); stat_kill_src.resize(8)
	_ai_charged = [false, false]
	squad_zone = PackedByteArray()
	squad_role = PackedByteArray()
	squad_ladder = PackedInt32Array()
	squad_type = PackedByteArray()
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
	siege_started = false
	sortie = false
	_gate_event_done = false


func _add_squad(t: int, anchor: Vector3, fwd: Vector3, ut: int = UnitType.INFANTRY, loadout := -1) -> int:
	squad_team.append(t)
	squad_type.append(ut)
	if loadout < 0:
		loadout = UnitDefs.siege_default_for(ut) if siege != null else UnitDefs.default_for(ut)
	squad_lo.append(loadout)
	squad_form.append(Form.LINE)
	squad_keep.append(0)
	squad_off.append(Vector2.ZERO)
	squad_goal.append(anchor)
	squad_tsq.append(-1)
	squad_center.append(anchor)
	squad_spread.append(0.0)
	squad_order.append(Order.CHARGE if auto_charge_both else Order.HOLD)
	squad_anchor.append(anchor)
	squad_facing.append(fwd)
	squad_timer.append(rng.randf() * squad_think)
	squad_alive.append(0)
	squad_zone.append(0)
	squad_role.append(Role.NORMAL)
	squad_ladder.append(-1)
	squad_count += 1
	return squad_count - 1


func _add_soldier(t: int, sq: int, k: int) -> void:
	var p := slot_position(sq, k)
	var lv := 1 if (siege != null and squad_zone[sq] == SiegeMap.Zone.WALL) else 0
	lvl.append(lv)
	p.y = _floor_y(lv, p)
	pos.append(p)
	prev_pos.append(p)
	vel.append(Vector3.ZERO)
	facing.append(squad_facing[sq])
	var ut := squad_type[sq]
	utype.append(ut)
	lo.append(squad_lo[sq])
	stat_start[t * 4 + ut] += 1
	rad.append(U_RADIUS[ut])
	engage_t.append(0.0)
	disengage_t.append(0.0)
	push_s.append(Vector3.ZERO)
	team.append(t)
	squad.append(sq)
	slot.append(k)
	hp.append(U_HP[ut])
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


## 小隊隊形槽位（依陣型）：橫隊 5 人一列；緊密縮小間距；鬆散加大間距；楔形 1-2-3-4 人的三角形，尖端朝前。
func slot_position(sq: int, k: int) -> Vector3:
	if siege != null and squad_role[sq] == Role.RAM and not siege.gate_broken:
		return siege.ram_slot(k + maxi(squad_ladder[sq], 0))
	var f := squad_facing[sq]
	var right := Vector3(-f.z, 0, f.x)
	var sp: float = U_SPACING[squad_type[sq]]
	var lat := 0.0
	var back := 0.0
	match squad_form[sq]:
		Form.WEDGE:
			var row := int(floor((sqrt(8.0 * k + 1.0) - 1.0) * 0.5))
			var idx := k - row * (row + 1) / 2
			lat = (idx - row * 0.5) * sp * 1.15
			back = row * sp
		_:
			var m := 0.72 if squad_form[sq] == Form.TIGHT else (1.9 if squad_form[sq] == Form.LOOSE else 1.0)
			lat = ((k % 5) - 2) * sp * m
			back = (k / 5) * sp * m
	return squad_anchor[sq] + right * lat - f * back


## 小隊在群組排列中佔的寬度、深度（公尺）
func _squad_size(s: int) -> Vector2:
	var sp: float = U_SPACING[squad_type[s]]
	match squad_form[s]:
		Form.TIGHT:
			return Vector2(4.0 * sp * 0.72, 1.0 * sp * 0.72)
		Form.LOOSE:
			return Vector2(4.0 * sp * 1.9, 1.0 * sp * 1.9)
		Form.WEDGE:
			return Vector2(3.0 * sp * 1.15, 3.0 * sp)
	return Vector2(4.0 * sp, sp)


static func _type_bit(ut: int) -> int:
	return 1 << ut


# ---------------------------------------------------------------------------
# 命令（玩家輸入只寫入佇列，下一個物理步由小隊層取用）
# ---------------------------------------------------------------------------
## order：Order；mask：哪些兵種（MASK_*）；at／fwd：集結點與面向（HOLD、MOVE）
func issue_order(t: int, order: int, at: Vector3, fwd: Vector3, mask := MASK_ALL, target_sq := -1) -> void:
	command_queue.append({"team": t, "kind": "order", "order": order, "pos": at, "fwd": fwd, "mask": mask, "tsq": target_sq})


## 前進（dist > 0）或後退（dist < 0）：每個小隊從目前位置沿面向移動，列隊行進
func issue_advance(t: int, dist: float, fwd: Vector3, mask := MASK_ALL) -> void:
	command_queue.append({"team": t, "kind": "advance", "dist": dist, "fwd": fwd, "mask": mask})


## 行進中的小隊就地停下（改成守位）
func issue_halt(t: int, mask := MASK_ALL) -> void:
	command_queue.append({"team": t, "kind": "halt", "mask": mask})


func issue_formation(t: int, form: int, mask := MASK_ALL) -> void:
	command_queue.append({"team": t, "kind": "form", "form": form, "mask": mask})


func issue_keep(t: int, keep: bool, mask := MASK_ALL) -> void:
	command_queue.append({"team": t, "kind": "keep", "keep": keep, "mask": mask})


func order_name(o: int) -> String:
	match o:
		Order.HOLD:
			return "守位"
		Order.FOLLOW:
			return "跟隨"
		Order.MOVE:
			return "行進"
		Order.ATTACK:
			return "攻擊目標"
		_:
			return "衝鋒"


## 離 p 最近的敵方小隊（以隊員中心算，扣掉散開範圍），超過 max_d 公尺回傳 -1。「攻擊指定敵隊」用
func nearest_enemy_squad(t: int, p: Vector3, max_d := 25.0) -> int:
	var best := -1
	var best_d := max_d
	for s in squad_count:
		if squad_team[s] == t or squad_alive[s] <= 0:
			continue
		var d := maxf(Vector2(squad_center[s].x - p.x, squad_center[s].z - p.z).length() - squad_spread[s], 0.0)
		if d < best_d:
			best_d = d
			best = s
	return best


## 選取的小隊裡有沒有正在「保持陣型」的
func keep_on(t: int, mask: int) -> bool:
	for s in _select(t, mask):
		if squad_keep[s] == 1:
			return true
	return false


## HUD 用：每個兵種一行「兵種（幾隊・幾人）命令・陣型」，被選取的前面加 ▶
func command_status(t: int, mask: int) -> String:
	var names := ["步兵", "弓兵", "騎兵"]
	var bits := [MASK_INF, MASK_ARC, MASK_CAV]
	var lines: Array[String] = []
	for k in 3:
		var sel := _select(t, bits[k])
		if sel.is_empty():
			continue
		var men := 0
		var orders := {}
		var forms := {}
		var keep := false
		for s in sel:
			men += squad_alive[s]
			orders[order_name(squad_order[s])] = true
			forms[FORM_NAMES[squad_form[s]]] = true
			keep = keep or squad_keep[s] == 1
		lines.append("%s%s %d 隊 %d 人　%s・%s%s" % ["▶ " if (mask & bits[k]) != 0 else "　 ", names[k], sel.size(), men,
			"／".join(orders.keys()), "／".join(forms.keys()), "・保持陣型" if keep else ""])
	return "\n".join(lines)


## 陣營 t 中符合兵種遮罩、還活著的小隊
func _select(t: int, mask: int) -> Array[int]:
	var out: Array[int] = []
	for s in squad_count:
		if squad_team[s] == t and squad_alive[s] > 0 and (mask & _type_bit(squad_type[s])) != 0:
			out.append(s)
	return out


## 群組排列：步兵在前（最多 6 隊一排）、弓兵在步兵後、騎兵在兩翼；只有一種兵種時就排成一橫列。
## 結果寫進 squad_off（往右、往後的位移），中心是 (0, 0)。
func _arrange(sel: Array[int]) -> void:
	var groups := [[], [], []]
	for s in sel:
		var ut := squad_type[s]
		groups[0 if (ut == UnitType.INFANTRY or ut == UnitType.SWORDSMAN) else ut].append(s)
	var front: Array = groups[0] if not groups[0].is_empty() else groups[1]
	var back: Array = groups[1] if not groups[0].is_empty() else []
	var wings: Array = groups[2]
	if front.is_empty() and back.is_empty():
		front = wings
		wings = []
	var cols := clampi(front.size(), 1, 6)
	var col_w := 0.0
	var row_d := 0.0
	for s in front:
		var sz := _squad_size(s)
		col_w = maxf(col_w, sz.x + 4.0)
		row_d = maxf(row_d, sz.y + 3.5)
	var rows := int(ceil(float(front.size()) / cols))
	for k in front.size():
		var in_row := mini(cols, front.size() - (k / cols) * cols)
		squad_off[front[k]] = Vector2((k % cols - (in_row - 1) * 0.5) * col_w, (k / cols) * row_d)
	var line_w := cols * col_w
	if not back.is_empty():
		var bc := clampi(back.size(), 1, 6)
		var bw := 0.0
		for s in back:
			bw = maxf(bw, _squad_size(s).x + 4.0)
		for k in back.size():
			var in_row := mini(bc, back.size() - (k / bc) * bc)
			squad_off[back[k]] = Vector2((k % bc - (in_row - 1) * 0.5) * bw, rows * row_d + 3.0 + (k / bc) * 5.0)
	for k in wings.size():
		var side := -1.0 if k % 2 == 0 else 1.0
		var w := k / 2
		var cw := _squad_size(wings[k]).x + 5.0
		squad_off[wings[k]] = Vector2(side * (line_w * 0.5 + 6.0 + cw * 0.5 + (w % 4) * cw), (w / 4) * 8.0)


## 群組中心 + 排列位移 → 世界座標
func _place(center: Vector3, fwd: Vector3, off: Vector2) -> Vector3:
	var right := Vector3(-fwd.z, 0, fwd.x)
	var p := center + right * off.x - fwd * off.y
	return terrain.clamp_to_map(p, 6.0)


## 一群小隊的中心：用它們目前的集結點（衝鋒中的用隊員平均位置）
func _group_center(sel: Array[int]) -> Vector3:
	var c := Vector3.ZERO
	for s in sel:
		c += squad_anchor[s] if squad_order[s] != Order.CHARGE and squad_order[s] != Order.ATTACK else squad_center[s]
	return c / maxf(sel.size(), 1)


func _apply_command(cmd: Dictionary) -> void:
	var t := int(cmd["team"])
	var sel := _select(t, int(cmd.get("mask", MASK_ALL)))
	if sel.is_empty():
		return
	match str(cmd.get("kind", "order")):
		"form":
			var f := int(cmd["form"])
			for s in sel:
				squad_form[s] = f
			_rearrange(sel)
		"halt":
			for s in sel:
				if squad_order[s] == Order.MOVE:
					squad_order[s] = Order.HOLD
		"keep":
			for s in sel:
				squad_keep[s] = 1 if cmd["keep"] else 0
		"advance":
			var fwd: Vector3 = cmd["fwd"]
			for s in sel:
				var f := fwd if fwd.length() > 0.1 else squad_facing[s]
				var base := squad_anchor[s] if squad_order[s] == Order.HOLD or squad_order[s] == Order.MOVE else squad_center[s]
				if squad_order[s] == Order.MOVE:
					base = squad_goal[s]
				squad_facing[s] = f
				_start_move(s, base, terrain.clamp_to_map(base + f * float(cmd["dist"]), 6.0))
		_:
			var order := int(cmd["order"])
			var at: Vector3 = cmd["pos"]
			var fwd: Vector3 = cmd["fwd"]
			if order == Order.HOLD or order == Order.MOVE or order == Order.FOLLOW:
				_arrange(sel)
			for s in sel:
				if siege != null and squad_role[s] == Role.RAM and order != Order.CHARGE:
					squad_role[s] = Role.NORMAL
				var f := fwd if fwd.length() > 0.1 else squad_facing[s]
				match order:
					Order.HOLD:
						squad_order[s] = order
						squad_facing[s] = f
						squad_anchor[s] = _place(at, f, squad_off[s])
						if siege != null:
							squad_zone[s] = _point_zone(at)
							if squad_zone[s] == SiegeMap.Zone.WALL:
								squad_anchor[s] = _wall_rally(s, at)
					Order.MOVE:
						squad_facing[s] = f
						var from := squad_center[s] if squad_order[s] == Order.CHARGE or squad_order[s] == Order.ATTACK else squad_anchor[s]
						_start_move(s, from, _place(at, f, squad_off[s]))
					Order.ATTACK:
						squad_order[s] = order
						squad_tsq[s] = int(cmd.get("tsq", -1))
					_:
						squad_order[s] = order
			if order == Order.FOLLOW:
				for s in sel:
					squad_timer[s] = 0.0      # 下一步就更新跟隨位置


func _start_move(s: int, from: Vector3, goal: Vector3) -> void:
	squad_order[s] = Order.MOVE
	squad_anchor[s] = Vector3(from.x, 0, from.z)
	squad_goal[s] = goal


## 換陣型後就地重排（守位、行進中的小隊）
func _rearrange(sel: Array[int]) -> void:
	var still: Array[int] = []
	for s in sel:
		if squad_order[s] == Order.HOLD or squad_order[s] == Order.MOVE:
			still.append(s)
	if still.is_empty() or siege != null:
		return
	var moving := squad_order[still[0]] == Order.MOVE
	var c := Vector3.ZERO
	for s in still:
		c += squad_goal[s] if moving else squad_anchor[s]
	c /= still.size()
	var f := squad_facing[still[0]]
	_arrange(still)
	for s in still:
		if moving:
			squad_goal[s] = _place(c, f, squad_off[s])
		else:
			squad_anchor[s] = _place(c, f, squad_off[s])


## 列隊行進：集結點以固定速度往目標走；隊伍落後太多（集結點離隊員中心超過 6 公尺）就等一下
func _march(delta: float) -> void:
	for s in squad_count:
		if squad_order[s] != Order.MOVE or squad_alive[s] <= 0:
			continue
		var a := squad_anchor[s]
		var g := squad_goal[s]
		var lead := Vector2(a.x - squad_center[s].x, a.z - squad_center[s].z).length()
		var spd := MARCH_SPEED * (1.6 if squad_type[s] == UnitType.CAVALRY else 1.0) * (0.25 if lead > 6.0 else 1.0)
		var to := Vector2(g.x - a.x, g.z - a.z)
		var d := to.length()
		if d < 0.3:
			squad_anchor[s] = g
			squad_order[s] = Order.HOLD
			continue
		var step := minf(d, spd * delta)
		squad_anchor[s] = Vector3(a.x + to.x / d * step, 0, a.z + to.y / d * step)


# ---------------------------------------------------------------------------
# 主迴圈（固定物理步）
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if count == 0:
		return
	var t0 := Time.get_ticks_usec()
	battle_time += delta
	# 士兵模擬分攤：人多時（≥ SIM_DIV_FROM）士兵分成兩半輪流更新，每個士兵每 2 個物理步更新一次（時間步長 ×2），
	# 每一幀的工作量只有一半而且平均，不會一幀重一幀輕。畫面用 interp_fraction() 內插，看起來一樣平滑。
	# 軍隊、小隊、箭矢、玩家與馬仍是每步更新。
	# 攻城戰先不分組：雲梯排隊、梯頂卡位這些逐步判定對更新頻率很敏感，分組後攻守平衡會跑掉（雲端實測）
	sim_div = 1 if (count < SIM_DIV_FROM or siege != null or GameConfig.no_sim_split) else 2
	_sim_phase = (_sim_phase + 1) % sim_div
	var sd := delta * sim_div

	_rebuild_grid()
	var t1 := Time.get_ticks_usec()

	if siege != null:
		_siege_army_tick(delta)
		_siege_step(delta)
	else:
		_army_tick(delta)
	_squad_tick(delta)
	_recount_attackers()
	think_calls = 0
	for i in range(_sim_phase, count, sim_div):
		if state[i] == State.DEAD:
			continue
		think_timer[i] -= sd
		if think_timer[i] <= 0.0:
			_think(i)
	var t2 := Time.get_ticks_usec()

	_move_and_fight(sd)
	var t3 := Time.get_ticks_usec()
	_update_arrows(delta)
	var t4 := Time.get_ticks_usec()
	t_arrows = t4 - t3

	t_grid = t1 - t0
	t_think = t2 - t1
	t_move = t3 - t2
	t_total = t4 - t0
	_check_victory()


func _rebuild_grid() -> void:
	_cell_head.fill(-1)
	_cell_next.resize(count)
	_sq_head.resize(squad_count)
	_sq_head.fill(-1)
	_sq_next.resize(count)
	var sums := PackedVector3Array()
	sums.resize(squad_count)
	var ns := PackedInt32Array()
	ns.resize(squad_count)
	for i in count:
		if state[i] == State.DEAD:
			continue
		var c := _cell_of(pos[i].x, pos[i].z)
		_cell_next[i] = _cell_head[c]
		_cell_head[c] = i
		var sq := squad[i]
		_sq_next[i] = _sq_head[sq]
		_sq_head[sq] = i
		sums[sq] += pos[i]
		ns[sq] += 1
	for s in squad_count:
		if ns[s] > 0:
			squad_center[s] = sums[s] / ns[s]
		var far := 0.0
		var j := _sq_head[s]
		var c2 := squad_center[s]
		while j != -1:
			far = maxf(far, Vector2(pos[j].x - c2.x, pos[j].z - c2.z).length_squared())
			j = _sq_next[j]
		squad_spread[s] = sqrt(far)


func _cell_of(x: float, z: float) -> int:
	var cx := clampi(int((x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var cz := clampi(int((z - _grid_origin) / cell_size), 0, _grid_w - 1)
	return cz * _grid_w + cx


func _army_tick(delta: float) -> void:
	_army_timer -= delta
	if _army_timer > 0.0:
		return
	_army_timer = army_think
	# 電腦指揮官：用跟玩家一樣的指令
	#   一般：開戰 2 秒後全軍列隊推進到離敵軍約 34 公尺，敵人逼近、推進完成或 60 秒後，步兵與騎兵衝鋒（弓兵原地放箭）
	#   立即衝鋒：開戰就全軍衝；守位：原地等，敵人逼近才衝
	for t in 2:
		if ai_team[t] and _ai_phase[t] == 2:
			# 已衝鋒：步兵騎兵打光了，或衝鋒 45 秒後，弓兵也壓上去（避免最後剩弓兵遠遠對射拖很久）
			if _select(t, MASK_INF | MASK_CAV).is_empty() or battle_time > _ai_charge_t[t] + 45.0:
				_ai_phase[t] = 3
				issue_order(t, Order.CHARGE, Vector3.ZERO, Vector3.ZERO, MASK_ARC)
			continue
		if not ai_team[t] or _ai_phase[t] >= 2:
			continue
		var mode: int = ai_mode[t]
		if auto_charge_both or mode == BattleSetup.AiMode.CHARGE:
			_ai_charge(t, MASK_ALL)
			continue
		if mode == BattleSetup.AiMode.HOLD:
			if _enemy_near_squads(t, 24.0):
				_ai_charge(t, MASK_ALL)
			continue
		if _ai_phase[t] == 0:
			if battle_time < 2.0:
				continue
			var mine := _army_center(t)
			var theirs := _army_center(1 - t)
			var dir := theirs - mine
			dir.y = 0.0
			var dist := dir.length()
			if dist > 0.1:
				dir /= dist
			_ai_phase[t] = 1
			# 對方也是一般模式的電腦時兩邊都會前進，各走一半
			var both: bool = ai_team[1 - t] and ai_mode[1 - t] == BattleSetup.AiMode.NORMAL
			var adv: float = (dist - ADVANCE_STOP) * (0.5 if both else 1.0)
			if adv > 4.0:
				issue_advance(t, adv, dir, MASK_ALL)
			continue
		var marching := false
		for s in squad_count:
			if squad_team[s] == t and squad_alive[s] > 0 and squad_order[s] == Order.MOVE:
				marching = true
		if _enemy_near_squads(t, 30.0) or not marching or battle_time > 60.0:
			_ai_charge(t, MASK_INF | MASK_CAV)


func _ai_charge(t: int, mask: int) -> void:
	_ai_phase[t] = 2 if mask != MASK_ALL else 3
	_ai_charge_t[t] = battle_time
	_ai_charged[t] = true
	_enemy_charged = true
	issue_order(t, Order.CHARGE, Vector3.ZERO, Vector3.ZERO, mask)
	if mask != MASK_ALL:
		issue_halt(t, MASK_ALL & ~mask)     # 沒衝鋒的（弓兵）停在原地放箭


## 陣營 t 所有活著士兵的平均位置
func _army_center(t: int) -> Vector3:
	var c := Vector3.ZERO
	var n := 0
	for s in squad_count:
		if squad_team[s] == t and squad_alive[s] > 0:
			c += squad_center[s] * squad_alive[s]
			n += squad_alive[s]
	return c / maxf(n, 1)


## 有沒有敵方士兵（或敵方玩家）進入陣營 t 任一小隊集結點的 r 公尺內
func _enemy_near_squads(t: int, r: float) -> bool:
	var r2 := r * r
	for s in squad_count:
		if squad_team[s] != t or squad_alive[s] <= 0:
			continue
		var a := squad_anchor[s]
		if player != null and player.team != t and not player.dead and a.distance_squared_to(player.global_position) < r2:
			return true
		# 先用敵方小隊中心＋散開半徑粗篩，再看隊員
		for e in squad_count:
			if squad_team[e] == t or squad_alive[e] <= 0:
				continue
			var re := r + squad_spread[e]
			if Vector2(squad_center[e].x - a.x, squad_center[e].z - a.z).length_squared() > re * re:
				continue
			var j := _sq_head[e]
			while j != -1:
				if a.distance_squared_to(pos[j]) < r2:
					return true
				j = _sq_next[j]
	return false


## 玩家所屬陣營（沒有玩家時當作 0，只影響「誰會把玩家當目標」這類判斷）
func player_team() -> int:
	return player.team if player != null else 0


func _squad_tick(delta: float) -> void:
	var pending := command_queue.duplicate()
	command_queue.clear()
	for cmd in pending:
		_apply_command(cmd)
	_march(delta)
	for s in squad_count:
		squad_timer[s] -= delta
		if squad_timer[s] > 0.0:
			continue
		squad_timer[s] = squad_think
		if squad_order[s] == Order.FOLLOW and player != null:
			var pf := player.facing
			squad_facing[s] = pf
			squad_anchor[s] = _place(player.global_position - pf * 8.0, pf, squad_off[s])
			if siege != null:
				squad_zone[s] = _point_zone(player.global_position)
				if squad_zone[s] == SiegeMap.Zone.WALL:
					squad_anchor[s] = _wall_rally(s, player.global_position)
		elif squad_order[s] == Order.ATTACK:
			var ts := squad_tsq[s]
			if ts < 0 or ts >= squad_count or squad_alive[ts] <= 0:
				squad_order[s] = Order.CHARGE     # 目標小隊被消滅：改成自由衝鋒


## 第 s 個小隊在集結點附近的位置（舊介面，攻城戰牆頂集結仍用到）
func _rally_point(s: int, at: Vector3, fwd: Vector3) -> Vector3:
	return _place(at, fwd, squad_off[s])


func _recount_attackers() -> void:
	attackers.fill(0)
	_player_att_n = 0
	for i in count:
		var tg := target[i]
		if state[i] == State.DEAD:
			continue
		if tg >= 0:
			attackers[tg] += 1
		elif tg == TARGET_PLAYER:
			_player_att_n += 1


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
	if siege != null and tg >= 0 and not _siege_can_target(i, tg):
		tg = NO_TARGET

	var radius := search_radius if (order == Order.CHARGE or order == Order.ATTACK) else engage_radius
	var leash := squad_keep[sq] == 1 and order != Order.CHARGE and order != Order.ATTACK
	if leash:
		radius = _l_reach[lo[i]] + LEASH + 1.0       # 保持陣型：只理會身邊的敵人
	if utype[i] == UnitType.ARCHER:
		radius = maxf(radius, ARCHER_RANGE + HIGH_GROUND_RANGE_MAX)
	var best := NO_TARGET
	if order == Order.ATTACK and squad_tsq[sq] >= 0 and squad_alive[squad_tsq[sq]] > 0:
		# 攻擊指定敵隊：身邊 3 公尺內有別的敵人先應付，否則找目標小隊最近的人
		best = _find_enemy(i, p, my_team, 3.0)
		if best == NO_TARGET:
			best = _nearest_in_squad(p, squad_tsq[sq])
	else:
		best = _find_enemy(i, p, my_team, radius)
	if best != NO_TARGET:
		tg = best
	elif tg == NO_TARGET and order == Order.CHARGE:
		tg = _find_enemy_global(p, my_team, i)
	if leash and tg >= 0 and utype[i] != UnitType.ARCHER and pos[tg].distance_to(slot_position(sq, slot[i])) > _l_reach[lo[i]] + LEASH + 1.5:
		tg = NO_TARGET
	# 敵方士兵也會把玩家當目標
	if my_team != player_team() and player != null and player.is_targetable():
		var pd := p.distance_to(player.global_position)
		var cur_d := 1e9
		if tg >= 0:
			cur_d = p.distance_to(pos[tg])
		if pd < radius and pd < cur_d and _player_att_n < max_attackers_player and (siege == null or _siege_can_target_player(i)):
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
	# 半徑稍大（守位接敵 16 m、弓兵射程、衝鋒）時，網格要掃的格子太多：改用小隊層級由近到遠找
	if radius > 8.0:
		return _nearest_by_squads(i, p, my_team, radius)
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
					if team[j] != my_team and (siege == null or _siege_can_target(i, j)):
						var d := p.distance_squared_to(pos[j])
						# 攻擊槽位已滿的目標降低優先度（除非就在身邊）
						if attackers[j] >= max_attackers and target[i] != j and d > 4.0:
							d *= 4.0
						if d < best_d:
							best_d = d
							best = j
					j = _cell_next[j]
	return best


## 附近沒有敵人時：找最近的敵方小隊（以中心距離扣掉隊伍散開範圍估計），再取該隊最近的人
func _find_enemy_global(p: Vector3, my_team: int, i := -1) -> int:
	if siege != null:
		# 攻城戰：有些敵人打不到（隔著城牆、不同層），不能只看最近的小隊
		return _nearest_by_squads(i, p, my_team, INF)
	var best_s := -1
	var best_sd := INF
	for s in squad_count:
		if squad_team[s] == my_team or squad_alive[s] <= 0:
			continue
		var d := Vector2(squad_center[s].x - p.x, squad_center[s].z - p.z).length() - squad_spread[s]
		if d < best_sd:
			best_sd = d
			best_s = s
	if best_s < 0:
		return NO_TARGET
	return _nearest_in_squad(p, best_s)


## 依「敵方小隊中心距離－散開半徑」由近到遠檢查各隊隊員，下一隊的最近可能距離已經比目前找到的遠就停止。
## 攻擊槽位已滿的目標距離 ×4（降低優先度，除非就在身邊）；攻城戰另外過濾打不到的目標。
## 一般只要看 1～3 隊就結束，不必掃全部士兵。
func _nearest_by_squads(i: int, p: Vector3, my_team: int, max_d: float) -> int:
	var lb := PackedFloat32Array()
	lb.resize(squad_count)
	for s in squad_count:
		if squad_team[s] == my_team or squad_alive[s] <= 0:
			lb[s] = INF
		else:
			lb[s] = maxf(Vector2(squad_center[s].x - p.x, squad_center[s].z - p.z).length() - squad_spread[s], 0.0)
	var best := NO_TARGET
	var best_d := max_d * max_d if max_d < INF else INF
	var cur := target[i] if i >= 0 else NO_TARGET
	while true:
		var ns := -1
		var nd := INF
		for s in squad_count:
			if lb[s] < nd:
				nd = lb[s]
				ns = s
		if ns < 0 or nd * nd > best_d:
			break
		lb[ns] = INF
		var j := _sq_head[ns]
		while j != -1:
			var d := p.distance_squared_to(pos[j])
			if attackers[j] >= max_attackers and cur != j and d > 4.0:
				d *= 4.0
			if d < best_d and (siege == null or i < 0 or _siege_can_target(i, j)):
				best_d = d
				best = j
			j = _sq_next[j]
	return best


func _nearest_in_squad(p: Vector3, s: int) -> int:
	var best := NO_TARGET
	var best_d := INF
	var j := _sq_head[s]
	while j != -1:
		var d := p.distance_squared_to(pos[j])
		if d < best_d:
			best_d = d
			best = j
		j = _sq_next[j]
	return best


func _player_attackers() -> int:
	return _player_att_n


func _target_pos(tg: int) -> Vector3:
	if tg == TARGET_PLAYER:
		return player.global_position if player else Vector3.ZERO
	return pos[tg]


# ---------------------------------------------------------------------------
# 每步移動與戰鬥（所有活著的士兵）
# ---------------------------------------------------------------------------
func _move_and_fight(delta: float) -> void:
	var has_player := player != null and not player.dead
	if siege != null:
		_build_ladder_queue()
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

	for i in range(_sim_phase, count, sim_div):
		prev_pos[i] = pos[i]
		if state[i] == State.DEAD:
			if hit_flash[i] > 0.0:
				hit_flash[i] -= delta
			# 致命一擊的擊退：屍體滑出去後停下
			var dv := vel[i]
			if dv.length_squared() > 0.01:
				var dp := pos[i] + dv * delta
				dp = terrain.clamp_to_map(dp, 4.0)
				dp.y = _floor_y(lvl[i], dp)
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

		var ut := utype[i]
		var walk: float = U_WALK[ut]
		var run: float = U_RUN[ut]
		trample_cd[i] = maxf(trample_cd[i] - delta, 0.0)
		var climb := 0                  # 攻城戰：這一步想往上爬（+1）或往下（-1）
		var use_slot := tg == NO_TARGET
		if stun[i] > 0.0:
			stun[i] -= delta
			use_slot = false
		elif ut == UnitType.CAVALRY and disengage_t[i] > 0.0:
			# 騎兵脫離：沿目前朝向全速跑開，之後重新找目標衝鋒
			disengage_t[i] -= delta
			desired = face * run
			use_slot = false
		elif tg != NO_TARGET:
			var tp := _target_pos(tg)
			var nav := false
			if siege != null:
				# 攻城戰：目標在別層（牆上／城外）就先走導航點（梯子、坡道、城門）
				var mode := _siege_mode(i, tg, tp)
				if mode == 2:
					use_slot = true
				elif mode == 1:
					nav = true
					tp = siege.waypoint(lvl[i], p, tp, _target_zone(tg), _ladder_pref(i))
					climb = siege.last_climb if ut != UnitType.CAVALRY else 0
			if not use_slot:
				var to := tp - p
				to.y = 0.0
				var d := to.length()
				var reach: float = _l_reach[lo[i]] + (0.9 if tg == TARGET_PLAYER and player.mounted else 0.0)
				if d > 0.001:
					face = to / d
				if nav:
					desired = face * run
				elif ut == UnitType.ARCHER and (d > ARCHER_MIN_RANGE or (siege != null and absf(tp.y - p.y) > 1.7)):
					# 弓兵：射程內站定放箭，射程外前進；行進命令中先走到隊形位置再射
					if squad_order[squad[i]] == Order.MOVE and p.distance_squared_to(slot_position(squad[i], slot[i])) > 9.0:
						use_slot = true
					elif d > archer_range(p.y - tp.y):
						if squad_keep[squad[i]] == 1 and squad_order[squad[i]] != Order.CHARGE:
							use_slot = true       # 保持陣型：射程外不追，留在隊形裡
						else:
							desired = face * run
					elif atk_cooldown[i] <= 0.0:
						atk_anim[i] = 0.6
						atk_cooldown[i] = rng.randf_range(2.4, 3.2)
						_fire_arrow(i, p, tg, d)
				elif d > reach * 0.85:
					desired = face * (run if (d > 6.0 or ut == UnitType.CAVALRY) else walk)
				else:
					if _l_backoff[lo[i]] and d < _l_min_d[lo[i]]:
						desired = -face * walk * 0.6
					if ut == UnitType.CAVALRY:
						engage_t[i] += delta
						if engage_t[i] > CAV_MELEE_TIME:
							engage_t[i] = 0.0
							disengage_t[i] = CAV_DISENGAGE_TIME
							face = (-face).rotated(Vector3.UP, rng.randf_range(-0.7, 0.7))
					if atk_cooldown[i] <= 0.0 and atk_hit_at[i] <= 0.0:
						# 出手：蓄力 0.25 秒後結算
						atk_anim[i] = 0.45
						atk_hit_at[i] = 0.25
						atk_cooldown[i] = rng.randf_range(_l_cd_min[lo[i]], _l_cd_max[lo[i]])
		if use_slot:
			var sq_i := squad[i]
			var order := squad_order[sq_i]
			var goal := Vector3.INF
			var goal_zone := 0
			if order != Order.CHARGE or (siege != null and squad_role[sq_i] == Role.RAM and not siege.gate_broken):
				goal = slot_position(sq_i, slot[i])
				if siege != null:
					goal_zone = squad_zone[sq_i]
			if order == Order.ATTACK and squad_tsq[sq_i] >= 0 and squad_alive[squad_tsq[sq_i]] > 0:
				goal = squad_center[squad_tsq[sq_i]]
			elif order == Order.CHARGE and siege != null and goal == Vector3.INF:
				goal = _siege_objective(i)
				goal_zone = _obj_zone
			if goal != Vector3.INF:
				var far := false
				if siege != null and (lvl[i] == 2 or siege.zone_of(lvl[i], p.x) != goal_zone):
					goal = siege.waypoint(lvl[i], p, goal, goal_zone, _ladder_pref(i))
					climb = siege.last_climb if ut != UnitType.CAVALRY else 0
					far = true
				var to := goal - p
				to.y = 0.0
				var d := to.length()
				if d > 0.4 or far:
					desired = to / maxf(d, 0.001) * (run_speed if (d > 8.0 or far) else walk_speed) * (1.0 if far else minf(1.0, d / 1.5))
					face = to / maxf(d, 0.001)
				else:
					face = squad_facing[squad[i]]

		# 攻擊結算：出手那一刻，依武器配置的距離與揮砍角度找命中對象（可一次砍到多人）
		if atk_hit_at[i] > 0.0:
			atk_hit_at[i] -= delta
			if atk_hit_at[i] <= 0.0 and tg != NO_TARGET:
				_resolve_strike(i, p, face, tg)

		# 分離力（網格鄰居）
		var push := Vector3.ZERO
		var my_r := rad[i]
		var my_team := team[i]
		var cav_speed := v.length() if ut == UnitType.CAVALRY else 0.0
		# 排隊：前進方向正前方有同隊友軍時放慢，而不是硬擠過去（擠在一起卡卡的主因）
		var block := 0.0
		var ddl := Vector2(desired.x, desired.z).length()
		var ddx := desired.x / ddl if ddl > 0.1 else 0.0
		var ddz := desired.z / ddl if ddl > 0.1 else 0.0
		var cx := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
		var cz := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
		var contacts := 0
		for gz in range(maxi(cz - 1, 0), mini(cz + 2, _grid_w)):
			if contacts >= MAX_CONTACTS:
				break
			for gx in range(maxi(cx - 1, 0), mini(cx + 2, _grid_w)):
				if contacts >= MAX_CONTACTS:
					break
				var j := _cell_head[gz * _grid_w + gx]
				while j != -1 and contacts < MAX_CONTACTS:
					if j != i and (siege == null or absf(pos[j].y - p.y) < 1.3):
						var dx := p.x - pos[j].x
						var dz := p.z - pos[j].z
						var d2 := dx * dx + dz * dz
						if ddl > 0.1 and team[j] == my_team and d2 < 2.6 and state[j] != State.DEAD:
							var ahead_j := -(dx * ddx + dz * ddz)
							if ahead_j > 0.0 and ahead_j * ahead_j > d2 * 0.6:
								block = maxf(block, 1.0 - sqrt(d2) / 1.6)
						var sd := my_r + rad[j] + 0.1
						if d2 < sd * sd and d2 > 0.000001:
							contacts += 1
							var dd := sqrt(d2)
							var k := (sd - dd) / dd
							push.x += dx * k
							push.z += dz * k
							# 騎兵衝撞：高速撞上前方的敵兵 → 傷害＋擊飛，自己也減速
							if cav_speed > CAV_CHARGE_SPEED and team[j] != my_team and trample_cd[j] <= 0.0 \
									and (-dx * v.x - dz * v.z) > 0.0:
								trample_cd[j] = trample_cooldown
								var vdir := v / cav_speed
								apply_damage(j, (10.0 + cav_speed * 1.5) * _l_charge[lo[i]], vdir * (0.5 + cav_speed * 0.08), Src.CHARGE)
								cavalry_impact.emit(pos[j] + Vector3(0, 1.0, 0), cav_speed)
								v *= 0.6
								cav_speed = v.length()
					j = _cell_next[j]
		# 地形障礙（岩石）
		for ob in terrain.obstacles_near(p.x, p.z):
			var ox := p.x - ob.x
			var oz := p.z - ob.y
			var rr := ob.z + my_r
			var od2 := ox * ox + oz * oz
			if od2 < rr * rr and od2 > 0.000001:
				var od := sqrt(od2)
				push.x += ox / od * (rr - od) * 2.0
				push.z += oz / od * (rr - od) * 2.0
		# 玩家與馬：重疊就推開；高速奔馳時前方的士兵會往側邊閃避
		if has_player and (siege == null or absf(pl_pos.y - p.y) < 1.5):
			var rx := p.x - pl_pos.x
			var rz := p.z - pl_pos.z
			var rd2 := rx * rx + rz * rz
			var min_d := pl_radius + my_r
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
					var killed := apply_damage(i, 6.0 + pl_speed * 1.2, knock, Src.PLAYER)
					player.dmg_dealt += 6.0 + pl_speed * 1.2
					if killed:
						player.total_kills += 1
					v = vel[i]
					trampled.emit(p + Vector3(0, 1.0, 0), pl_speed, killed)
			# 只有友軍會讓路；敵軍不閃避（否則衝鋒永遠撞不到人）
			if team[i] == player.team and pl_speed > 3.0 and rd2 < 25.0:
				var ahead := rx * pl_fwd.x + rz * pl_fwd.z
				var lateral := rx * -pl_fwd.z + rz * pl_fwd.x
				if ahead > 0.0 and ahead < 5.0 and absf(lateral) < 1.6:
					var side := 1.0 if lateral >= 0.0 else -1.0
					desired += Vector3(-pl_fwd.z, 0, pl_fwd.x) * side * 3.5

		# 地形：上坡變慢、下坡稍快，涉水與積雪減速
		var dl := Vector2(desired.x, desired.z).length()
		if dl > 0.1 and lvl[i] == 0:
			desired *= terrain.move_factor(p.x, p.z, desired.x / dl, desired.z / dl)
		if ut == UnitType.CAVALRY:
			# 馬不能橫著走：身體朝向以有限速度轉向目標方向，速度只沿身體朝向
			var want := face
			var dlen := Vector2(desired.x, desired.z).length()
			if dlen > 0.1:
				want = desired / dlen
			var cur := atan2(facing[i].x, facing[i].z)
			var diff := wrapf(atan2(want.x, want.z) - cur, -PI, PI)
			var tr := lerpf(CAV_TURN_SLOW, CAV_TURN_FAST, clampf(Vector2(v.x, v.z).length() / run, 0.0, 1.0))
			cur += clampf(diff, -tr * delta, tr * delta)
			face = Vector3(sin(cur), 0.0, cos(cur))
			if dlen > 0.1:
				# 急轉彎時減速（轉彎半徑），不會原地甩頭
				desired = face * dlen * clampf(cos(diff), 0.25, 1.0)
			push *= CAV_PUSH_SCALE
		elif ddl > 0.1:
			desired *= 1.0 - block * 0.75
			# 步兵／弓兵的朝向也限制轉速，人群裡不會每幀換方向圖
			var cur_a := atan2(facing[i].x, facing[i].z)
			var dif_a := wrapf(atan2(face.x, face.z) - cur_a, -PI, PI)
			cur_a += clampf(dif_a, -9.0 * delta, 9.0 * delta)
			face = Vector3(sin(cur_a), 0.0, cos(cur_a))
		else:
			var cur_b := atan2(facing[i].x, facing[i].z)
			var dif_b := wrapf(atan2(face.x, face.z) - cur_b, -PI, PI)
			cur_b += clampf(dif_b, -9.0 * delta, 9.0 * delta)
			face = Vector3(sin(cur_b), 0.0, cos(cur_b))
		v = v.lerp(desired, minf(1.0, 8.0 * delta))
		# 推擠速度平滑＋上限：重疊時逐漸分開，不會一步彈開、下一步又擠回來
		var pv := push * 4.0
		var pl := pv.length()
		if pl > 4.0:
			pv *= 4.0 / pl
		var ps := push_s[i].lerp(pv, minf(1.0, 14.0 * delta))
		push_s[i] = ps
		if siege != null and lvl[i] == 2:
			# 雲梯上：只能沿梯子上下，速度有上限
			v.z = 0.0
			v.x = clampf(v.x, -SiegeMap.LADDER_SPEED, SiegeMap.LADDER_SPEED)
			ps = Vector3(clampf(ps.x, -1.5, 1.5), 0, 0)
		p.x += (v.x + ps.x) * delta
		p.z += (v.z + ps.z) * delta
		if siege != null:
			if lvl[i] == 0 and climb > 0 and _ladder_foot_busy(p.z):
				climb = 0              # 梯腳有人正在爬：排隊等
			elif lvl[i] == 2:
				p.x = minf(p.x, _ladder_ahead_limit(i))
			p = siege.resolve(lvl[i], pos[i], p, my_r, climb)
			if lvl[i] == 2 and siege.last_level == 1 and _ladder_top_blocked(i, p):
				# 梯頂有敵人擋著：上不去，只能在梯頂跟他打
				p = pos[i]
				p.x = minf(p.x, SiegeMap.WALK_X0 - 0.15)
			else:
				lvl[i] = siege.last_level
			p = terrain.clamp_to_map(p, 4.0)
			p.y = _floor_y(lvl[i], p)
		else:
			p = terrain.clamp_to_map(p, 4.0)
			p.y = terrain.get_height(p.x, p.z)
		pos[i] = p
		vel[i] = v
		facing[i] = face
		if atk_anim[i] > 0.0:
			state[i] = State.ENGAGE
		elif v.length_squared() > (0.09 if state[i] == State.MOVE else 0.36):
			state[i] = State.MOVE
		else:
			state[i] = State.IDLE


## 士兵出手結算（命中幀）：目標是玩家 → 只打玩家；否則在武器距離內、正前方揮砍角度內找敵人，
## 由近到遠最多 max_targets 人（主要目標優先）。每個目標各自擲命中率，正面有盾的有機率擋下。
## 這等於在命中那一刻對整段揮砍弧做一次扇形檢查，不會因為士兵移動快而漏判。
func _resolve_strike(i: int, p: Vector3, face: Vector3, tg: int) -> void:
	var l := lo[i]
	var fx_point := p + face * 0.6 + Vector3(0, 1.2, 0)
	var acc := _l_acc[l]
	if tg == TARGET_PLAYER:
		var tp := _target_pos(tg)
		var reach_p := _l_reach[l] + 0.4 + (0.9 if player.mounted else 0.0)
		if Vector2(tp.x - p.x, tp.z - p.z).length() <= reach_p and rng.randf() < acc and (siege == null or absf(tp.y - p.y) < 1.8):
			var pd := rng.randf_range(_l_dmg_min[l], _l_dmg_max[l])
			if siege != null and lvl[i] == 2:
				pd *= LADDER_DEAL_MULT
			player.take_damage(pd, p)
			soldier_struck.emit(fx_point, true)
		else:
			soldier_struck.emit(fx_point, false)
		return
	var reach2 := _l_reach[l] + 0.4
	var cos_half := _l_cos_half[l]
	var my_team := team[i]
	var cand: Array[Vector2] = []
	var rc := int(ceil(reach2 / cell_size))
	var cx := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var cz := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
	for gz in range(maxi(cz - rc, 0), mini(cz + rc + 1, _grid_w)):
		for gx in range(maxi(cx - rc, 0), mini(cx + rc + 1, _grid_w)):
			var j := _cell_head[gz * _grid_w + gx]
			while j != -1:
				if team[j] != my_team and state[j] != State.DEAD and (siege == null or absf(pos[j].y - p.y) < 1.8):
					var dx := pos[j].x - p.x
					var dz := pos[j].z - p.z
					var d := sqrt(dx * dx + dz * dz)
					if d <= reach2 and (j == tg or d < 0.3 or (dx * face.x + dz * face.z) / d >= cos_half):
						# 主要目標排最前面
						cand.append(Vector2(-1.0 if j == tg else d, j))
				j = _cell_next[j]
	if cand.is_empty():
		soldier_struck.emit(fx_point, false)
		return
	cand.sort()
	var landed := false
	var n := mini(cand.size(), _l_max_t[l])
	for k in n:
		var j := int(cand[k].y)
		if rng.randf() >= acc:
			continue
		var to := pos[j] - p
		to.y = 0.0
		var d := to.length()
		var dir := to / d if d > 0.001 else face
		if _l_block[lo[j]] > 0.0 and stun[j] <= 0.0 and facing[j].dot(-dir) > 0.3 and rng.randf() < _l_block[lo[j]]:
			continue                   # 正面被盾擋下
		var dmg := rng.randf_range(_l_dmg_min[l], _l_dmg_max[l])
		if d < _l_min_d[l]:
			dmg *= _l_close[l]
		if utype[j] == UnitType.CAVALRY:
			dmg *= _l_vs_cav[l]
		if siege != null and lvl[i] == 2:
			dmg *= LADDER_DEAL_MULT
		if apply_damage(j, dmg, dir * 0.15 * _l_knock[l], Src.MELEE):
			dbg_melee_kills[my_team] += 1
		landed = true
	soldier_struck.emit(fx_point, landed)


# ---------------------------------------------------------------------------
# 箭矢：拋物線飛行，預判目標移動；只在接近地面高度時才做命中檢查
# ---------------------------------------------------------------------------
func _fire_arrow(i: int, p: Vector3, tg: int, d: float) -> void:
	var start := p + Vector3(0, 1.5, 0)
	var tp := _target_pos(tg)
	if siege != null and lvl[i] == 1 and p.x < SiegeMap.WALL_X1 and tp.x < SiegeMap.WALL_X0:
		# 牆頂弓兵探出城垛往下射：箭從女兒牆外側出發，射得到牆腳
		start.x = SiegeMap.WALL_X0 - 0.2
	var tvel := vel[tg] if tg >= 0 else player.move_velocity()
	var flight := clampf(d / ARROW_SPEED, 0.45, 2.0)
	var aim_h := 1.0
	if tg == TARGET_PLAYER and player.mounted:
		aim_h = 1.8
	var spread := d * 0.035
	var aim := tp + tvel * flight + Vector3(rng.randfn(0.0, spread), aim_h, rng.randfn(0.0, spread))
	var v0 := (aim - start) / flight + Vector3(0, 0.5 * ARROW_GRAVITY * flight, 0)
	var k := _arrow_next
	_arrow_next = (k + 1) % MAX_ARROWS
	arrow_pos[k] = start
	arrow_vel[k] = v0
	arrow_team[k] = team[i]
	arrow_state[k] = 1
	arrow_life[k] = 4.0
	arrow_mult[k] = 1.0 + clampf((p.y - tp.y) * HIGH_GROUND_DMG_PER_M, -0.15, 0.35)
	arrow_dmg[k] = 0.0
	dbg_fired[team[i]] += 1
	arrow_fired.emit(start)


## 玩家射箭：初速由拉弓程度決定，傷害固定；命中時呼叫 player.on_arrow_hit
func fire_player_arrow(start: Vector3, v0: Vector3, dmg: float, shooter_team: int) -> void:
	var k := _arrow_next
	_arrow_next = (k + 1) % MAX_ARROWS
	arrow_pos[k] = start
	arrow_vel[k] = v0
	arrow_team[k] = shooter_team
	arrow_state[k] = 1
	arrow_life[k] = 5.0
	arrow_mult[k] = 1.0
	arrow_dmg[k] = dmg
	arrow_fired.emit(start)


func _update_arrows(delta: float) -> void:
	var g := Vector3(0, -ARROW_GRAVITY, 0)
	var pl_ok := player != null and not player.dead
	var pl_center := player.body_center() if pl_ok else Vector3.ZERO
	var pl_r := (1.2 if player.mounted else 0.7) if pl_ok else 0.0
	arrows_in_flight = 0
	for k in MAX_ARROWS:
		var st := arrow_state[k]
		if st == 0:
			continue
		if st == 2:
			arrow_life[k] -= delta
			if arrow_life[k] <= 0.0:
				arrow_state[k] = 0
			continue
		arrows_in_flight += 1
		# 玩家的箭很快（最高 60 m/s），一步會飛將近 1 公尺，切成小步檢查才不會穿過人
		var steps := 1 if arrow_dmg[k] <= 0.0 else clampi(int(ceil(arrow_vel[k].length() * delta / 0.35)), 1, 6)
		for sub in steps:
			if arrow_state[k] != 1:
				break
			_step_arrow(k, delta / steps, g, pl_ok, pl_center, pl_r)


func _step_arrow(k: int, delta: float, g: Vector3, pl_ok: bool, pl_center: Vector3, pl_r: float) -> void:
	var v := arrow_vel[k] + g * delta
	var p := arrow_pos[k] + v * delta
	arrow_vel[k] = v
	arrow_pos[k] = p
	arrow_life[k] -= delta
	var ground := terrain.get_height(p.x, p.z)
	if p.y <= ground + 0.05 or arrow_life[k] <= 0.0:
		arrow_state[k] = 2
		arrow_life[k] = ARROW_STUCK_TIME
		arrow_pos[k] = Vector3(p.x, ground + 0.2, p.z)
		arrow_hit.emit(arrow_pos[k], false)
		return
	if siege != null and siege.blocks_arrow(p, v.x):
		# 插在城牆、女兒牆或城門上
		dbg_wall_block[arrow_team[k]] += 1
		arrow_state[k] = 2
		arrow_life[k] = ARROW_STUCK_TIME
		arrow_hit.emit(p, false)
		return
	if p.y - ground > (3.0 if siege == null else SiegeMap.WALL_H + 3.0):
		return
	var tm := arrow_team[k]
	var hit := -1
	var cx := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var cz := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
	for gz in range(maxi(cz - 1, 0), mini(cz + 2, _grid_w)):
		if hit != -1:
			break
		for gx in range(maxi(cx - 1, 0), mini(cx + 2, _grid_w)):
			var j := _cell_head[gz * _grid_w + gx]
			while j != -1:
				if team[j] != tm and state[j] != State.DEAD:
					var dx := p.x - pos[j].x
					var dz := p.z - pos[j].z
					var r := rad[j] + 0.15
					if dx * dx + dz * dz < r * r and p.y >= pos[j].y and p.y <= pos[j].y + U_HEIGHT[utype[j]]:
						hit = j
						break
				j = _cell_next[j]
			if hit != -1:
				break
	if hit != -1:
		var flat := Vector3(v.x, 0, v.z).normalized()
		if arrow_dmg[k] > 0.0:
			var killed := apply_damage(hit, arrow_dmg[k], flat * 0.35, Src.PLAYER)
			if player:
				player.on_arrow_hit(p, arrow_dmg[k], killed)
		else:
			dbg_arrow_hits[tm] += 1
			var cover := 1.0
			if siege != null and lvl[hit] == 1 and pos[hit].x < SiegeMap.WALL_X1:
				cover = SIEGE_WALL_ARROW_MULT
			if _l_arrow[lo[hit]] < 1.0 and facing[hit].dot(-flat) > 0.3:
				cover *= _l_arrow[lo[hit]]       # 正面中箭：盾擋掉一部分
			if apply_damage(hit, rng.randf_range(ARROW_DAMAGE_MIN, ARROW_DAMAGE_MAX) * arrow_mult[k] * cover, flat * 0.25, Src.ARROW):
				dbg_arrow_kills[tm] += 1
		arrow_state[k] = 0
		arrow_hit.emit(p, true)
		return
	if pl_ok and tm != player.team and p.distance_to(pl_center) < pl_r:
		player.take_damage(ARROW_DAMAGE_PLAYER * arrow_mult[k], p - v.normalized(), true)
		arrow_state[k] = 0
		arrow_hit.emit(p, true)


# ---------------------------------------------------------------------------
# 給玩家武器與馬使用的查詢
# ---------------------------------------------------------------------------
## 弓兵有效射程：dh = 射手高度 − 目標高度
static func archer_range(dh: float) -> float:
	return ARCHER_RANGE + clampf(dh * HIGH_GROUND_RANGE_PER_M, -6.0, HIGH_GROUND_RANGE_MAX)


func soldier_position(i: int) -> Vector3:
	return pos[i]


func soldier_velocity(i: int) -> Vector3:
	return vel[i]


## 回傳 true 表示這一擊造成死亡。knock：水平擊退位移（公尺）。
func apply_damage(i: int, dmg: float, knock: Vector3, src: int = Src.MELEE) -> bool:
	if state[i] == State.DEAD:
		return false
	_last_src = src
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


var _last_src := 0


func _kill(i: int) -> void:
	stat_dead[team[i] * 4 + utype[i]] += 1
	stat_kill_src[(1 - team[i]) * 4 + _last_src] += 1
	state[i] = State.DEAD
	hp[i] = 0.0
	dead_time[i] = battle_time
	target[i] = NO_TARGET
	atk_anim[i] = 0.0
	alive_count[team[i]] -= 1
	kills[1 - team[i]] += 1
	squad_alive[squad[i]] -= 1
	if siege != null and lvl[i] == 2:
		# 從雲梯上被打下來：掉到梯腳
		lvl[i] = 0
		var q := pos[i]
		q.x = minf(q.x, SiegeMap.WALL_X0 - 0.5)
		q.y = terrain.get_height(q.x, q.z)
		pos[i] = q


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
	var heights := [0.3, 0.7, 1.1, 1.5, 1.9, 2.3]
	for cz in range(c_lo_z, c_hi_z + 1):
		for cx in range(c_lo_x, c_hi_x + 1):
			var j := _cell_head[cz * _grid_w + cx]
			while j != -1:
				if team[j] != attacker_team and state[j] != State.DEAD and not exclude.has(j):
					var hit_r := radius + rad[j]
					for h in heights:
						if h > U_HEIGHT[utype[j]]:
							break
						var c: Vector3 = pos[j] + Vector3(0, h, 0)
						if _dist_point_tri(c, a0, b0, b1) <= hit_r or _dist_point_tri(c, a0, b1, a1) <= hit_r:
							out.append(j)
							break
				j = _cell_next[j]
	return out


## 玩家馬上出手輔助：p 前方（與 fwd 夾角的 cos ≥ min_cos）半徑 r 內最近的敵兵，沒有回傳 -1
func nearest_enemy_in_cone(p: Vector3, fwd: Vector3, r: float, min_cos: float, my_team: int) -> int:
	var best := -1
	var best_d := r * r
	var rc := int(ceil(r / cell_size))
	var c0x := clampi(int((p.x - _grid_origin) / cell_size), 0, _grid_w - 1)
	var c0z := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
	for cz in range(maxi(c0z - rc, 0), mini(c0z + rc + 1, _grid_w)):
		for cx in range(maxi(c0x - rc, 0), mini(c0x + rc + 1, _grid_w)):
			var j := _cell_head[cz * _grid_w + cx]
			while j != -1:
				if team[j] != my_team and state[j] != State.DEAD:
					var dx := pos[j].x - p.x
					var dz := pos[j].z - p.z
					var d2 := dx * dx + dz * dz
					if d2 < best_d and d2 > 0.0001 and (dx * fwd.x + dz * fwd.z) >= min_cos * sqrt(d2):
						best_d = d2
						best = j
				j = _cell_next[j]
	return best


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
				if dx * dx + dz * dz < r2 and absf(pos[j].y - p.y) < 2.0:
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
	if OS.get_cmdline_user_args().has("--trace") and int(battle_time * 60.0) % 120 == 0:
		var od := []
		for s in squad_count:
			od.append("%d%s" % [squad_order[s], "ABC"[squad_type[s] % 3]])
		print("t=%.0f alive %d/%d fired %d/%d ai %s %s gap %.1f" % [battle_time, alive_count[0], alive_count[1], dbg_fired[0], dbg_fired[1], str(_ai_phase), " ".join(od), _army_center(1).x - _army_center(0).x])
	if siege != null and battle_time >= siege_time_limit and alive_count[0] > 0 and alive_count[1] > 0:
		winner = 1 - siege_attacker
		battle_finished.emit(winner)
		return
	if alive_count[0] <= 0 or alive_count[1] <= 0:
		winner = 1 if alive_count[0] <= 0 else 0
		battle_finished.emit(winner)
		return
	if siege == null and time_limit > 0.0 and battle_time >= time_limit:
		# 時間到：剩餘人數多的一方勝，相同算平手
		winner = 0 if alive_count[0] > alive_count[1] else (1 if alive_count[1] > alive_count[0] else 2)
		battle_finished.emit(winner)


func stats_text() -> String:
	if siege != null:
		return _siege_stats_text()
	var pt := player_team() if player != null else -1
	var s := "藍軍%s %d　紅軍%s %d　擊殺 %d：%d　戰鬥 %.0f 秒" % [
		"（你）" if pt == 0 else "", alive_count[0], "（你）" if pt == 1 else "", alive_count[1], kills[0], kills[1], battle_time]
	if time_limit > 0.0:
		s += "／%.0f" % time_limit
	s += "\n戰場邏輯 %.2f ms（網格 %.2f／決策 %.2f［%d 次］／移動戰鬥 %.2f／箭矢 %.2f［%d 支］）　士兵畫面 %.2f ms" % [
		t_total / 1000.0, t_grid / 1000.0, t_think / 1000.0, think_calls, t_move / 1000.0, t_arrows / 1000.0, arrows_in_flight, t_render / 1000.0]
	if winner != -1:
		s += "\n%s！按 R 重開" % winner_text(winner)
	return s


func winner_text(w: int) -> String:
	if w == 2:
		return "平手"
	var t := "藍軍勝利" if w == 0 else "紅軍勝利"
	if player != null:
		t += "（你方）" if w == player.team else "（敵方）"
	return t


## 陣營 t、兵種 ut 的開場／陣亡人數
func stat_unit(t: int, ut: int) -> Vector2i:
	return Vector2i(stat_start[t * 4 + ut], stat_dead[t * 4 + ut])


func append_debug_lines(pts: PackedVector3Array, cols: PackedColorArray) -> void:
	# 小隊集結點（十字）與每個士兵指向目標的線（只畫前 200 條）
	for s in squad_count:
		if squad_alive[s] <= 0 or squad_order[s] == Order.CHARGE or squad_order[s] == Order.ATTACK:
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


## 畫面內插比例：第 q 組士兵（編號 % sim_div == q）上一次更新（prev_pos）到這一次（pos）之間走到哪裡（0..1）
func interp_fraction(q := 0) -> float:
	if sim_div <= 1:
		return Engine.get_physics_interpolation_fraction()
	var since := posmod(_sim_phase - q, sim_div)
	return clampf((float(since) + Engine.get_physics_interpolation_fraction()) / sim_div, 0.0, 1.0)


func _process(_delta: float) -> void:
	if renderer == null:
		return
	var t0 := Time.get_ticks_usec()
	renderer.render(self, get_viewport().get_camera_3d(), interp_fraction())
	t_render = Time.get_ticks_usec() - t0


# ---------------------------------------------------------------------------
# 攻城戰
# ---------------------------------------------------------------------------
## 牆頂守軍有城垛掩護：受到的箭傷乘上這個倍率
const SIEGE_WALL_ARROW_MULT := 0.5
var _obj_zone := 0                      # _siege_objective() 的附帶結果：目標點所在區域


func defender_team() -> int:
	return 1 - siege_attacker


func _floor_y(level: int, p: Vector3) -> float:
	if siege != null:
		return siege.floor_y(level, p)
	return terrain.get_height(p.x, p.z)


func _point_zone(p: Vector3) -> int:
	return siege.zone_of_point(p) if siege != null else 0


func _target_zone(tg: int) -> int:
	if tg == TARGET_PLAYER:
		return siege.zone_of_point(player.global_position)
	return siege.zone_of(lvl[tg], pos[tg].x)


func _ladder_pref(i: int) -> int:
	var sq := squad[i]
	if squad_role[sq] == Role.RAM:
		return -1
	return squad_ladder[sq]


## 攻城戰的目標過濾：守方近戰不追出城外（城門破了才守門口）、不追梯子下半段的人；騎兵不上牆
func _siege_can_target(i: int, j: int) -> bool:
	var zj := siege.zone_of(lvl[j], pos[j].x)
	if utype[i] == UnitType.CAVALRY and (zj == SiegeMap.Zone.WALL or zj == SiegeMap.Zone.LADDER):
		return false
	if team[i] == siege_attacker or utype[i] == UnitType.ARCHER or sortie:
		return true
	if zj == SiegeMap.Zone.OUT:
		return false            # 守方近戰不出城（城門破了也是在門內列陣堵門）
	if zj == SiegeMap.Zone.LADDER:
		return pos[j].y > siege.wall_top() - 2.6
	return true


func _siege_can_target_player(i: int) -> bool:
	var zp := siege.zone_of_point(player.global_position)
	if utype[i] == UnitType.CAVALRY and (zp == SiegeMap.Zone.WALL or zp == SiegeMap.Zone.LADDER):
		return false
	if team[i] == siege_attacker or utype[i] == UnitType.ARCHER or sortie:
		return true
	if zp == SiegeMap.Zone.OUT:
		return false
	if zp == SiegeMap.Zone.LADDER:
		return player.global_position.y > siege.wall_top() - 2.6
	return true


## 0 = 直接對目標行動（走過去打／射箭）、1 = 目標在別層，走導航點、2 = 不理目標，回到隊形位置
func _siege_mode(i: int, tg: int, tp: Vector3) -> int:
	var p := pos[i]
	var dy := absf(tp.y - p.y)
	var hd := Vector2(tp.x - p.x, tp.z - p.z).length()
	var sq := squad[i]
	if squad_role[sq] == Role.RAM and not siege.gate_broken:
		# 推槌兵：只還手貼身的敵人，其餘時間顧著推槌
		return 0 if (dy < 1.7 and hd < 2.6) else 2
	var mz := siege.zone_of(lvl[i], p.x)
	var tz := _target_zone(tg)
	var order := squad_order[sq]
	if utype[i] == UnitType.ARCHER and (hd > ARCHER_MIN_RANGE or dy > 1.7):
		if hd <= archer_range(p.y - tp.y):
			return 0
		if order == Order.CHARGE:
			return 0 if mz == tz else 1
		return 2
	if dy < 1.7:
		if lvl[i] == 0 and siege.gate_broken and siege.crosses_wall(p, tp):
			return 1
		return 0
	if order != Order.CHARGE and squad_role[sq] != Role.NORMAL and hd > engage_radius:
		return 2
	return 1


## 衝鋒但附近沒有可打的敵人時要去哪裡：攻方 → 指定雲梯的梯頂（城門破了就進城）；守方 → 原位
func _siege_objective(i: int) -> Vector3:
	var sq := squad[i]
	if squad_team[sq] == siege_attacker:
		if siege.gate_broken or siege.zone_of(lvl[i], pos[i].x) == SiegeMap.Zone.WALL:
			_obj_zone = SiegeMap.Zone.IN
			return Vector3(30.0, 0, clampf(pos[i].z, -20.0, 20.0))
		var lk := squad_ladder[sq] if squad_ladder[sq] >= 0 else siege.nearest_ladder(pos[i].z)
		_obj_zone = SiegeMap.Zone.WALL
		return Vector3(SiegeMap.WALK_X0 + 1.4, 0, SiegeMap.LADDER_Z[lk])
	_obj_zone = squad_zone[sq]
	return slot_position(sq, slot[i])


## 在牆頂集結：同陣營小隊沿走道南北排開
func _wall_rally(s: int, at: Vector3) -> Vector3:
	var idx := 0
	var total := 0
	for o in squad_count:
		if squad_team[o] == squad_team[s]:
			if o < s:
				idx += 1
			total += 1
	return Vector3(SiegeMap.WALK_X0 + 0.8, 0, at.z + (idx - (total - 1) * 0.5) * 7.5)


## 攻城戰開局：攻方 n_att 人在城外西側，守方 n_def 人在牆上與城內
func spawn_siege(attacker: int, n_att := 400, n_def := 200) -> void:
	_clear()
	_reset_arrows()
	siege_attacker = attacker
	siege.reset()
	var defender := 1 - attacker
	var fwd_a := Vector3(1, 0, 0)
	var fwd_d := Vector3(-1, 0, 0)
	var ladders: Array = SiegeMap.LADDER_Z
	# ---- 攻方 ----
	var n_sq := int(ceil(float(n_att) / squad_size))
	var n_arc := roundi(n_sq * 0.20)
	var n_cav := roundi(n_sq * 0.10)
	var n_ram := 2
	var n_lad := n_sq - n_arc - n_cav - n_ram
	var remaining := n_att
	var plan: Array = []          # [type, anchor, role, ladder/offset, order, zone]
	for k in n_ram:
		plan.append([UnitType.INFANTRY, siege.ram_pos, Role.RAM, k * 10, Order.CHARGE, SiegeMap.Zone.OUT])
	for k in n_lad:
		var lk := k % ladders.size()
		var j := k / ladders.size()
		var col := j % 2
		var row := j / 2
		var lz: float = ladders[lk]
		plan.append([UnitType.INFANTRY, Vector3(-24.0 - row * 5.5, 0, lz + (col - 0.5) * 7.5), Role.NORMAL, lk, Order.HOLD, SiegeMap.Zone.OUT])
	var arc_z := [-47.0, -40.0, -22.0, -6.0, 6.0, 29.0, 37.0, 45.0, -56.0, 53.0]
	for k in n_arc:
		var az: float = arc_z[k % arc_z.size()] + (k / arc_z.size()) * 3.0
		plan.append([UnitType.ARCHER, Vector3(-19.0 - (k / arc_z.size()) * 4.0, 0, az), Role.NORMAL, -1, Order.HOLD, SiegeMap.Zone.OUT])
	var cav_z := [-12.0, 12.0, -40.0, 40.0, -26.0, 26.0]
	for k in n_cav:
		plan.append([UnitType.CAVALRY, Vector3(-52.0, 0, cav_z[k % cav_z.size()]), Role.RESERVE, -1, Order.HOLD, SiegeMap.Zone.OUT])
	for e in plan:
		var sq := _add_squad(attacker, e[1], fwd_a, e[0])
		squad_role[sq] = e[2]
		squad_ladder[sq] = e[3]
		squad_order[sq] = e[4]
		squad_zone[sq] = e[5]
		var members := mini(squad_size, remaining)
		remaining -= members
		for m in members:
			_add_soldier(attacker, sq, m)
	# ---- 守方 ----
	n_sq = int(ceil(float(n_def) / squad_size))
	n_arc = roundi(n_sq * 0.35)
	var n_inf := n_sq - n_arc
	remaining = n_def
	plan.clear()
	var wall_x := SiegeMap.WALK_X0 + 0.7
	var d_arc_z := [-38.0, -22.0, -7.0, 7.0, 26.0, 34.0, -48.0, 46.0]
	for k in n_arc:
		plan.append([UnitType.ARCHER, Vector3(wall_x, 0, d_arc_z[k % d_arc_z.size()]), Role.WALLGUARD, -1, SiegeMap.Zone.WALL])
	var placed := 0
	for lz in ladders:
		for s in [-1.0, 1.0]:
			if placed < n_inf:
				plan.append([UnitType.SWORDSMAN, Vector3(wall_x + 0.4, 0, lz + s * 3.6), Role.WALLGUARD, -1, SiegeMap.Zone.WALL])
				placed += 1
	for s in [-1.0, 1.0]:
		if placed < n_inf:
			plan.append([UnitType.SWORDSMAN, Vector3(16.5, 0, s * 3.4), Role.GATE, -1, SiegeMap.Zone.IN])
			placed += 1
	var r_i := 0
	while placed < n_inf:
		plan.append([UnitType.SWORDSMAN, Vector3(27.0 + (r_i / 3) * 6.0, 0, -14.0 + (r_i % 3) * 14.0), Role.RESERVE, -1, SiegeMap.Zone.IN])
		placed += 1
		r_i += 1
	for e in plan:
		var sq := _add_squad(defender, e[1], fwd_d, e[0])
		squad_role[sq] = e[2]
		squad_ladder[sq] = e[3]
		squad_order[sq] = Order.HOLD
		squad_zone[sq] = e[4]
		var members := mini(squad_size, remaining)
		remaining -= members
		for m in members:
			_add_soldier(defender, sq, m)
	_siege_start_counts = PackedInt32Array([alive_count[0], alive_count[1]])
	if renderer:
		renderer.setup(self)


## 攻城槌：數槌旁的推槌兵、推進、撞門
func _siege_step(delta: float) -> void:
	var crew := 0
	var rp := siege.ram_pos
	for i in count:
		if state[i] != State.DEAD and lvl[i] == 0 and squad_role[squad[i]] == Role.RAM:
			var dx := pos[i].x - rp.x
			var dz := pos[i].z - rp.z
			if dx * dx + dz * dz < 10.0:
				crew += 1
	if siege.step_ram(delta, crew, siege_started):
		cavalry_impact.emit(siege.gate_point() + Vector3(0, 2.0, 0), 14.0)
		if siege.gate_broken:
			_on_gate_broken()


func _on_gate_broken() -> void:
	if _gate_event_done:
		return
	_gate_event_done = true
	siege_event.emit("城門被攻破！")
	for s in squad_count:
		if squad_team[s] == siege_attacker:
			if squad_role[s] == Role.RAM or squad_role[s] == Role.RESERVE:
				squad_role[s] = Role.NORMAL
				squad_order[s] = Order.CHARGE
				squad_ladder[s] = -1
	# 守方：城門守衛和還沒派上牆的預備隊在門洞後面列陣堵門（不出城）
	var gate_slots := [Vector2(15.5, -3.6), Vector2(15.5, 3.6), Vector2(19.0, -6.5), Vector2(19.0, 0.0), Vector2(19.0, 6.5), Vector2(22.5, -3.6), Vector2(22.5, 3.6)]
	var g := 0
	for s in squad_count:
		if squad_team[s] != siege_attacker and squad_alive[s] > 0 and squad_order[s] == Order.HOLD \
				and (squad_role[s] == Role.GATE or squad_role[s] == Role.RESERVE):
			var gs: Vector2 = gate_slots[mini(g, gate_slots.size() - 1)]
			squad_role[s] = Role.GATE
			squad_zone[s] = SiegeMap.Zone.IN
			squad_anchor[s] = Vector3(gs.x, 0, gs.y)
			squad_facing[s] = Vector3(-1, 0, 0)
			g += 1


## 雙方指揮官（攻城戰版）
func _siege_army_tick(delta: float) -> void:
	_army_timer -= delta
	if _army_timer > 0.0:
		return
	_army_timer = army_think
	var att := siege_attacker
	var dfd := 1 - att
	if not siege_started and battle_time >= siege_start_delay:
		siege_started = true
		for s in squad_count:
			if squad_team[s] == att and squad_type[s] == UnitType.INFANTRY:
				squad_order[s] = Order.CHARGE
		siege_event.emit("攻城開始！")
	if siege.gate_broken:
		_on_gate_broken()
	# 守方：哪道梯子有攻方爬上牆，就從城內預備隊派一隊上去
	var on_wall := PackedInt32Array([0, 0, 0])
	var att_melee := 0
	for i in count:
		if state[i] == State.DEAD or team[i] != att:
			continue
		if utype[i] == UnitType.INFANTRY or utype[i] == UnitType.SWORDSMAN:
			att_melee += 1
		if lvl[i] != 0:
			var lk := siege.nearest_ladder(pos[i].z)
			if absf(pos[i].z - SiegeMap.LADDER_Z[lk]) < 14.0:
				on_wall[lk] += 1
	for lk in on_wall.size():
		if on_wall[lk] < 3:
			continue
		for s in squad_count:
			if squad_team[s] == dfd and squad_role[s] == Role.RESERVE and squad_alive[s] > 0 and squad_order[s] == Order.HOLD:
				squad_role[s] = Role.WALLGUARD
				squad_zone[s] = SiegeMap.Zone.WALL
				squad_anchor[s] = Vector3(SiegeMap.WALK_X0 + 1.0, 0, SiegeMap.LADDER_Z[lk] + rng.randf_range(-5.0, 5.0))
				siege_event.emit("守軍增援第 %d 道雲梯" % (lk + 1))
				break
	# 攻方近戰兵死光了：弓兵也拔刀爬梯
	if siege_started and att_melee == 0:
		for s in squad_count:
			if squad_team[s] == att and squad_order[s] != Order.CHARGE:
				squad_order[s] = Order.CHARGE
	# 攻方快打光了：守方出城追擊
	if not sortie and siege_started and alive_count[att] <= maxi(12, alive_count[dfd]):
		sortie = true
		siege_event.emit("守軍出城追擊！")
		for s in squad_count:
			if squad_team[s] == dfd:
				squad_order[s] = Order.CHARGE


func _siege_stats_text() -> String:
	var att := siege_attacker
	var dfd := 1 - att
	var you := "攻方" if att == 0 else "守方"
	var left := maxf(siege_time_limit - battle_time, 0.0)
	var ram := ""
	if siege.gate_broken:
		ram = "城門已破"
	elif siege.ram_at_gate:
		ram = "攻城槌撞門中（推槌 %d 人）" % siege.ram_crew
	else:
		ram = "攻城槌距城門 %.0f m（推槌 %d 人）" % [SiegeMap.RAM_STOP_X - siege.ram_pos.x, siege.ram_crew]
	var s := "攻城戰（你是%s）　攻方 %d/%d　守方 %d/%d　城門 %d/%d　%s　剩餘 %d:%02d" % [
		you, alive_count[att], _siege_start_counts[att], alive_count[dfd], _siege_start_counts[dfd],
		int(siege.gate_hp), int(SiegeMap.GATE_HP), ram, int(left) / 60, int(left) % 60]
	s += "\n戰場邏輯 %.2f ms（網格 %.2f／決策 %.2f［%d 次］／移動戰鬥 %.2f／箭矢 %.2f［%d 支］）　士兵畫面 %.2f ms" % [
		t_total / 1000.0, t_grid / 1000.0, t_think / 1000.0, think_calls, t_move / 1000.0, t_arrows / 1000.0, arrows_in_flight, t_render / 1000.0]
	if winner != -1:
		var w := "攻方" if winner == att else "守方"
		s += "\n%s勝利！%s（按 R 重開）" % [w, "（時間到）" if alive_count[0] > 0 and alive_count[1] > 0 else ""]
	return s


var dbg_arrow_kills := PackedInt32Array([0, 0])
var dbg_melee_kills := PackedInt32Array([0, 0])
var dbg_arrow_hits := PackedInt32Array([0, 0])
var dbg_wall_block := PackedInt32Array([0, 0])
var dbg_fired := PackedInt32Array([0, 0])


func siege_debug() -> String:
	var z := [[0, 0, 0, 0], [0, 0, 0, 0]]
	for i in count:
		if state[i] != State.DEAD:
			z[team[i]][siege.zone_of(lvl[i], pos[i].x)] += 1
	return "zones t0 %s t1 %s  arrowK %s meleeK %s fired %s hits %s wallblock %s" % [str(z[0]), str(z[1]), str(dbg_arrow_kills), str(dbg_melee_kills), str(dbg_fired), str(dbg_arrow_hits), str(dbg_wall_block)]


# --- 雲梯排隊：每道梯子同時只能一個接一個爬（間距 LADDER_GAP），梯頂有敵人擋就上不去 ---
const LADDER_GAP := 0.9
var _lad_ids: Array = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]


func _build_ladder_queue() -> void:
	for k in _lad_ids.size():
		_lad_ids[k] = PackedInt32Array()
	for i in count:
		if lvl[i] == 2 and state[i] != State.DEAD:
			var k := siege.nearest_ladder(pos[i].z)
			var a: PackedInt32Array = _lad_ids[k]
			a.append(i)
			_lad_ids[k] = a


func _ladder_foot_busy(z: float) -> bool:
	var k := siege.nearest_ladder(z)
	if absf(z - SiegeMap.LADDER_Z[k]) > SiegeMap.LADDER_HALF + 0.5:
		return false
	var foot := SiegeMap.WALL_X0 - SiegeMap.LADDER_RUN
	for j in _lad_ids[k]:
		if state[j] != State.DEAD and pos[j].x < foot + LADDER_GAP * 1.5:
			return true
	return false


func _ladder_ahead_limit(i: int) -> float:
	var k := siege.nearest_ladder(pos[i].z)
	var lim := INF
	var xi := pos[i].x
	for j in _lad_ids[k]:
		if j != i and state[j] != State.DEAD and pos[j].x > xi - 0.01 and (pos[j].x > xi or j > i):
			lim = minf(lim, pos[j].x - LADDER_GAP)
	return maxf(lim, xi) if lim != INF else INF


func _ladder_top_blocked(i: int, p: Vector3) -> bool:
	var top := siege.wall_top()
	var ex := SiegeMap.WALK_X0 + 0.4
	# 只看梯頂附近的網格（以前是掃全部士兵）
	var rc := int(ceil(1.3 / cell_size))
	var c0x := clampi(int((ex - _grid_origin) / cell_size), 0, _grid_w - 1)
	var c0z := clampi(int((p.z - _grid_origin) / cell_size), 0, _grid_w - 1)
	for cz in range(maxi(c0z - rc, 0), mini(c0z + rc + 1, _grid_w)):
		for cx in range(maxi(c0x - rc, 0), mini(c0x + rc + 1, _grid_w)):
			var j := _cell_head[cz * _grid_w + cx]
			while j != -1:
				if team[j] != team[i] and state[j] != State.DEAD and lvl[j] == 1:
					var dx := pos[j].x - ex
					var dz := pos[j].z - p.z
					if dx * dx + dz * dz < 1.3 * 1.3 and absf(pos[j].y - top) < 0.5:
						return true
				j = _cell_next[j]
	return false

