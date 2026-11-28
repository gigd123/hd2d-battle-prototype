class_name WeaponDefs
extends RefCounted
## 武器定義表（資料驅動）：新增武器 = 在 ALL 加一筆，再在烘焙設定加一個同名圖層。
##
## 欄位說明（沒寫的用 DEFAULT 的值）：
##   name        顯示名稱
##   layer       預渲染圖層名（art/baked/knight/<layer>.png）
##   kind        "swing" 揮砍｜"thrust" 前刺｜"bow" 弓
##   anim        動作組："swing"（單手）｜"heavy"（雙手）｜"thrust"｜"bow"
##   hands       1 或 2；雙手武器不能拿盾
##   shield      是否帶盾（右鍵舉盾，擋得住箭）
##   block       "shield" 舉盾｜"weapon" 用武器格擋（只擋近戰）｜"none"
##   block_reduce / block_angle_deg   擋下時減傷比例、正前方左右幾度內擋得下
##   reach_foot / reach_mounted       攻擊距離（公尺，從肩膀算）
##   damage      基礎傷害；speed_damage = 每 m/s 迎面相對速度加成
##   windup / swing / recover         蓄力、揮出、收招秒數（越短攻速越快）
##   arc_deg     揮砍掃過的角度（越大越容易一次砍到多人）
##   max_targets 一次揮擊最多命中幾人
##   knockback   擊退距離倍率（錘子高：把人打退、打出硬直）
##   min_dist    目標比這更近就是「貼身」：close_mult 傷害倍率；stuck = 刺不出去、動作直接中斷
##   attack_move 出手時的移動速度倍率
const DEFAULT := {
	"name": "?", "layer": "sword", "kind": "swing", "anim": "swing", "hands": 1,
	"shield": true, "block": "shield", "block_reduce": 0.85, "block_angle_deg": 75.0,
	"reach_foot": 1.45, "reach_mounted": 1.9, "damage": 20.0, "speed_damage": 3.0,
	"windup": 0.16, "swing": 0.14, "recover": 0.20, "arc_deg": 110.0, "max_targets": 3,
	"knockback": 1.0, "min_dist": 0.0, "close_mult": 1.0, "stuck": false, "attack_move": 0.55,
}

const ALL := [
	{"id": "sword", "name": "單手劍", "layer": "sword"},
	{"id": "spear", "name": "長槍", "layer": "spear", "kind": "thrust", "anim": "thrust",
		"reach_foot": 2.7, "reach_mounted": 3.3, "damage": 22.0, "speed_damage": 4.2,
		"windup": 0.20, "swing": 0.14, "recover": 0.30, "max_targets": 2,
		"min_dist": 1.1, "close_mult": 0.35, "stuck": true},
	{"id": "greatsword", "name": "大劍", "layer": "greatsword", "anim": "heavy", "hands": 2,
		"shield": false, "block": "weapon", "block_reduce": 0.7, "block_angle_deg": 60.0,
		"reach_foot": 2.05, "reach_mounted": 2.4, "damage": 32.0,
		"windup": 0.28, "swing": 0.20, "recover": 0.32, "arc_deg": 170.0, "max_targets": 5,
		"knockback": 1.3, "attack_move": 0.4},
	{"id": "axe_hs", "name": "單手短柄斧", "layer": "axe_hs",
		"reach_foot": 1.2, "reach_mounted": 1.7, "damage": 25.0,
		"windup": 0.18, "swing": 0.14, "recover": 0.26, "arc_deg": 90.0, "max_targets": 2, "knockback": 1.1},
	{"id": "axe_hl", "name": "單手長柄斧", "layer": "axe_hl",
		"reach_foot": 1.55, "reach_mounted": 2.0, "damage": 27.0,
		"windup": 0.22, "swing": 0.16, "recover": 0.28, "arc_deg": 100.0, "max_targets": 2, "knockback": 1.1},
	{"id": "axe_ts", "name": "雙手短柄斧", "layer": "axe_ts", "anim": "heavy", "hands": 2,
		"shield": false, "block": "weapon", "block_reduce": 0.55, "block_angle_deg": 55.0,
		"reach_foot": 1.7, "reach_mounted": 2.1, "damage": 36.0,
		"windup": 0.30, "swing": 0.20, "recover": 0.36, "arc_deg": 140.0, "max_targets": 3,
		"knockback": 1.4, "attack_move": 0.4},
	{"id": "axe_tl", "name": "雙手長柄斧", "layer": "axe_tl", "anim": "heavy", "hands": 2,
		"shield": false, "block": "weapon", "block_reduce": 0.55, "block_angle_deg": 55.0,
		"reach_foot": 2.4, "reach_mounted": 2.8, "damage": 42.0, "speed_damage": 3.6,
		"windup": 0.38, "swing": 0.22, "recover": 0.42, "arc_deg": 130.0, "max_targets": 3,
		"knockback": 1.5, "min_dist": 1.0, "close_mult": 0.5, "attack_move": 0.35},
	{"id": "mace_hs", "name": "單手短柄錘", "layer": "mace_hs",
		"reach_foot": 1.15, "reach_mounted": 1.6, "damage": 18.0,
		"windup": 0.16, "swing": 0.14, "recover": 0.22, "arc_deg": 90.0, "max_targets": 2, "knockback": 2.0},
	{"id": "mace_hl", "name": "單手長柄錘", "layer": "mace_hl",
		"reach_foot": 1.5, "reach_mounted": 1.95, "damage": 20.0,
		"windup": 0.20, "swing": 0.16, "recover": 0.26, "arc_deg": 100.0, "max_targets": 2, "knockback": 2.2},
	{"id": "mace_ts", "name": "雙手短柄錘", "layer": "mace_ts", "anim": "heavy", "hands": 2,
		"shield": false, "block": "weapon", "block_reduce": 0.5, "block_angle_deg": 55.0,
		"reach_foot": 1.6, "reach_mounted": 2.0, "damage": 30.0,
		"windup": 0.32, "swing": 0.22, "recover": 0.40, "arc_deg": 130.0, "max_targets": 3,
		"knockback": 3.2, "attack_move": 0.4},
	{"id": "mace_tl", "name": "雙手長柄錘", "layer": "mace_tl", "anim": "heavy", "hands": 2,
		"shield": false, "block": "weapon", "block_reduce": 0.5, "block_angle_deg": 55.0,
		"reach_foot": 2.3, "reach_mounted": 2.7, "damage": 34.0, "speed_damage": 3.6,
		"windup": 0.40, "swing": 0.22, "recover": 0.44, "arc_deg": 120.0, "max_targets": 3,
		"knockback": 3.4, "min_dist": 1.0, "close_mult": 0.5, "attack_move": 0.35},
	{"id": "bow", "name": "弓", "layer": "bow", "kind": "bow", "anim": "bow", "hands": 2,
		"shield": false, "block": "none", "max_targets": 1, "attack_move": 0.5,
		"draw_time": 0.8, "min_draw": 0.25, "arrow_dmg_min": 18.0, "arrow_dmg_max": 45.0,
		"arrow_speed_min": 32.0, "arrow_speed_max": 62.0, "recover": 0.35},
]

static var _resolved: Array = []


## 第 i 把武器（已補上預設值）
static func get_def(i: int) -> Dictionary:
	if _resolved.is_empty():
		for d in ALL:
			var r: Dictionary = DEFAULT.duplicate()
			r.merge(d, true)
			_resolved.append(r)
	return _resolved[posmod(i, ALL.size())]


static func count() -> int:
	return ALL.size()


static func index_of(id: String) -> int:
	for i in ALL.size():
		if ALL[i]["id"] == id:
			return i
	return 0


## 一行說明（換武器時的提示）
static func summary(d: Dictionary) -> String:
	if d["kind"] == "bow":
		return "%s：按住左鍵拉弓、放開射出（拉滿 %.1f 秒，傷害 %d～%d）；F 切換肩後／第一人稱瞄準" % [
			d["name"], d["draw_time"], int(d["arrow_dmg_min"]), int(d["arrow_dmg_max"])]
	var guard := "右鍵舉盾"
	if d["block"] == "weapon":
		guard = "沒有盾，右鍵用武器格擋（擋不了箭）"
	var extra := ""
	if d["stuck"]:
		extra = "，貼太近會卡住"
	elif float(d["min_dist"]) > 0.0:
		extra = "，貼太近傷害減半"
	return "%s（%s手）：距離 %.1f m、傷害 %d、最多 %d 人%s；%s" % [
		d["name"], "單" if int(d["hands"]) == 1 else "雙", float(d["reach_foot"]), int(d["damage"]),
		int(d["max_targets"]), extra, guard]
