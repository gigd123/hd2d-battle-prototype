class_name BattleSetup
extends RefCounted
## 一場野戰的全部設定：初始選單只負責填這份資料，戰場只負責讀它。
## 可以存成 JSON（user://last_setup.json 記住上次的選擇；啟動參數 --setup=檔案.json 直接開打），
## 之後 AI 對打批次測試也用同一份格式，不必改程式就能換測試條件。

const SIDE_NAMES := ["藍軍", "紅軍"]
const UNIT_NAMES := ["步兵", "弓兵", "騎兵"]
## 地圖尺寸檔位（公尺，正方形邊長）。0 = 依人數自動選
const MAP_SIZES := [0, 160, 240, 320]
const MAP_SIZE_NAMES := ["自動（依人數）", "小 160 m", "中 240 m", "大 320 m"]
## 已在雲端測過的總人數；超過只提醒、不阻擋
const TESTED_TOTAL := 400

## 非玩家控制的一方怎麼打
enum AiMode { NORMAL, CHARGE, HOLD }
const AI_MODE_NAMES := ["一般（列隊推進，接近後衝鋒）", "開戰立即衝鋒", "守位（敵人逼近才迎戰）"]

## 玩家陣營：0 藍、1 紅、-1 觀戰（沒有玩家）
var terrain_type := 1
var map_size := 0
var seed_value := 12345
var random_seed := false
## 兩方的編成：每列 {"unit": 0..2, "loadout": 配置 id, "count": 人數}
var armies: Array = [[], []]
var ai_mode := [AiMode.NORMAL, AiMode.NORMAL]
var player_side := 0
var player_mounted := false
## 玩家攜帶的武器（WeaponDefs 的 id），Q／Z 在這幾把之間切換
var player_weapons: Array = ["sword", "spear", "bow"]
## 玩家是否算在己方人數裡（算的話從己方同類兵種扣 1 人）
var player_counts := false
## 玩家陣亡後：true = 4 秒後在後方重生；false = 改成觀戰直到分出勝負
var player_respawn := false
## 時間上限（秒），0 = 不限；時間到以剩餘人數判勝負
var time_limit := 0.0


static func make_default() -> BattleSetup:
	var s := BattleSetup.new()
	s.apply_preset(0, 50)
	s.apply_preset(1, 50)
	return s


## 快速範本：每方 n 人，沿用改版前的編成規則（以 10 人小隊計：約 60% 步兵、25% 弓兵、15% 騎兵）
func apply_preset(side: int, n: int) -> void:
	var squads := int(ceil(n / 10.0))
	var cav := roundi(squads * 0.15)
	var arc := roundi(squads * 0.25)
	if squads >= 4:
		cav = maxi(cav, 1)
	if squads >= 3:
		arc = maxi(arc, 1)
	var inf := maxi(squads - cav - arc, 1)
	arc = mini(arc, squads - inf)
	cav = squads - inf - arc
	var arc_n := arc * 10
	var cav_n := cav * 10
	var inf_n := maxi(n - arc_n - cav_n, 0)
	var rows: Array = []
	if inf_n > 0:
		rows.append({"unit": 0, "loadout": "spear_shield", "count": inf_n})
	if arc_n > 0:
		rows.append({"unit": 1, "loadout": "bow", "count": arc_n})
	if cav_n > 0:
		rows.append({"unit": 2, "loadout": "lance", "count": cav_n})
	armies[side] = rows


func side_total(side: int) -> int:
	var n := 0
	for r in armies[side]:
		n += int(r["count"])
	return n


func total() -> int:
	return side_total(0) + side_total(1)


## 實際使用的地圖邊長
func resolved_map_size() -> int:
	if map_size > 0:
		return map_size
	var biggest := maxi(side_total(0), side_total(1))
	if biggest <= 50:
		return 160
	if biggest <= 120:
		return 240
	return 320


## 玩家算進人數時，要從哪一列扣 1 人：騎馬→騎兵列，拿弓→弓兵列，其他→步兵列；找不到就扣人最多的一列
func player_slot_row() -> int:
	if player_side < 0 or not player_counts:
		return -1
	var want := 0
	if player_mounted:
		want = 2
	elif not player_weapons.is_empty() and player_weapons[0] == "bow":
		want = 1
	var rows: Array = armies[player_side]
	var best := -1
	for k in rows.size():
		if int(rows[k]["count"]) <= 0:
			continue
		if int(rows[k]["unit"]) == want:
			return k
		if best < 0 or int(rows[k]["count"]) > int(rows[best]["count"]):
			best = k
	return best


func duplicate_setup() -> BattleSetup:
	return BattleSetup.from_dict(to_dict())


func to_dict() -> Dictionary:
	return {
		"version": 1,
		"terrain": BattleTerrain.TYPE_KEYS[terrain_type],
		"map_size": map_size,
		"seed": seed_value,
		"random_seed": random_seed,
		"armies": armies.duplicate(true),
		"ai_mode": ai_mode.duplicate(),
		"player_side": player_side,
		"player_mounted": player_mounted,
		"player_weapons": player_weapons.duplicate(),
		"player_counts": player_counts,
		"player_respawn": player_respawn,
		"time_limit": time_limit,
	}


static func from_dict(d: Dictionary) -> BattleSetup:
	var s := BattleSetup.make_default()
	var tk := BattleTerrain.type_from_key(str(d.get("terrain", "hills")))
	if tk >= 0:
		s.terrain_type = tk
	s.map_size = int(d.get("map_size", 0))
	if not MAP_SIZES.has(s.map_size):
		s.map_size = 0
	s.seed_value = int(d.get("seed", 12345))
	s.random_seed = bool(d.get("random_seed", false))
	var arm = d.get("armies", null)
	if arm is Array and (arm as Array).size() == 2:
		for side in 2:
			var rows: Array = []
			for r in arm[side]:
				if not (r is Dictionary):
					continue
				var u := clampi(int(r.get("unit", 0)), 0, 2)
				var lo := UnitDefs.resolve(str(r.get("loadout", "")), u)
				rows.append({"unit": u, "loadout": UnitDefs.get_def(lo)["id"], "count": clampi(int(r.get("count", 0)), 0, 2000)})
			s.armies[side] = rows
	var am = d.get("ai_mode", null)
	if am is Array and (am as Array).size() == 2:
		s.ai_mode = [clampi(int(am[0]), 0, 2), clampi(int(am[1]), 0, 2)]
	s.player_side = clampi(int(d.get("player_side", 0)), -1, 1)
	s.player_mounted = bool(d.get("player_mounted", false))
	var pw = d.get("player_weapons", null)
	if pw is Array:
		var ws: Array = []
		for w in pw:
			if WeaponDefs.index_of(str(w)) >= 0 and WeaponDefs.ALL[WeaponDefs.index_of(str(w))]["id"] == str(w) and not ws.has(str(w)):
				ws.append(str(w))
		if not ws.is_empty():
			s.player_weapons = ws
	s.player_counts = bool(d.get("player_counts", false))
	s.player_respawn = bool(d.get("player_respawn", false))
	s.time_limit = maxf(0.0, float(d.get("time_limit", 0.0)))
	return s


func save_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(), "  "))
	return true


static func load_json(path: String) -> BattleSetup:
	if not FileAccess.file_exists(path):
		return null
	var txt := FileAccess.get_file_as_string(path)
	var d = JSON.parse_string(txt)
	if not (d is Dictionary):
		return null
	return BattleSetup.from_dict(d)


## 一行摘要（結算畫面、複製結果用）
func summary() -> String:
	var parts: Array[String] = []
	for side in 2:
		var rows: Array[String] = []
		for r in armies[side]:
			if int(r["count"]) <= 0:
				continue
			var lo := UnitDefs.resolve(str(r["loadout"]), int(r["unit"]))
			rows.append("%s(%s)%d" % [UNIT_NAMES[int(r["unit"])], UnitDefs.get_def(lo)["name"], int(r["count"])])
		parts.append("%s %d：%s" % [SIDE_NAMES[side], side_total(side), "、".join(rows)])
	var who := "觀戰"
	if player_side >= 0:
		var ws: Array[String] = []
		for w in player_weapons:
			ws.append(str(WeaponDefs.get_def(WeaponDefs.index_of(str(w)))["name"]))
		who = "%s・%s・%s%s" % [SIDE_NAMES[player_side], "騎馬" if player_mounted else "步行", "／".join(ws), "（計入人數）" if player_counts else ""]
	return "%s　%s　地圖 %d m　｜　%s　｜　玩家：%s" % [
		BattleTerrain.TYPE_NAMES[terrain_type], "種子 %d" % seed_value, resolved_map_size(), "　".join(parts), who]
