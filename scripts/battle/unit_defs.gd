class_name UnitDefs
extends RefCounted
## 士兵的「武器配置」資料表（資料驅動，跟玩家的 WeaponDefs 分開）。
##
## 兵種（BattleManager.UnitType）決定身體：生命、速度、半徑、AI 類型（近戰／弓兵／騎兵）。
## 武器配置決定手上拿什麼：攻擊距離、傷害、出手間隔、揮砍角度、一次最多砍到幾人、盾。
## 每個配置只屬於一個兵種，所以「配置編號」同時也是士兵圖集的編號（畫面依它組圖）。
##
## 欄位（沒寫的用 DEFAULT）：
##   unit          屬於哪個兵種（0 步兵、1 弓兵、2 騎兵、3 劍盾兵［攻城戰守方專用］）
##   layer / anim  預渲染圖層與動作組（"swing" 揮砍、"thrust" 前刺、"heavy" 雙手重擊、"bow"）
##   shield        有沒有盾（畫面）；block = 正面近戰擋下機率；arrow_mult = 正面中箭的傷害倍率
##   reach         近戰攻擊距離（公尺）
##   dmg_min/max   每一擊的傷害範圍；cd_min/max = 出手間隔（秒）
##   arc_deg       揮砍角度：出手那一刻，正前方這個角度內、距離內的敵人都可能被砍到
##   max_targets   一擊最多命中幾人
##   accuracy      每個目標的命中率（代表閃避、擦過，沒有實際格擋動作前先用機率）
##   min_dist      目標比這更近：傷害 × close_mult；backoff = 會往後退拉開距離（長槍）
##   knock         擊退倍率
##   vs_cavalry    打騎兵的傷害倍率（長槍類較高）
##   charge_mult   騎兵衝撞的傷害倍率（騎槍較高）
const DEFAULT := {
	"id": "?", "name": "?", "unit": 0, "layer": "sword", "anim": "swing", "shield": false,
	"block": 0.0, "arrow_mult": 1.0, "reach": 1.5, "dmg_min": 10.0, "dmg_max": 15.0,
	"cd_min": 1.2, "cd_max": 1.8, "arc_deg": 100.0, "max_targets": 2, "accuracy": 0.75,
	"min_dist": 0.0, "close_mult": 1.0, "backoff": false, "knock": 1.0, "vs_cavalry": 1.0,
	"charge_mult": 1.0,
}

const ALL := [
	# --- 步兵 ---
	{"id": "spear_shield", "name": "長槍＋盾", "unit": 0, "layer": "spear", "anim": "thrust", "shield": true,
		"block": 0.15, "arrow_mult": 0.75, "reach": 2.1, "dmg_min": 9.0, "dmg_max": 14.0,
		"arc_deg": 30.0, "max_targets": 1, "min_dist": 1.0, "close_mult": 0.5, "backoff": true, "vs_cavalry": 1.3},
	{"id": "sword_shield", "name": "劍＋盾", "unit": 0, "layer": "sword", "anim": "swing", "shield": true,
		"block": 0.3, "arrow_mult": 0.6, "reach": 1.5, "dmg_min": 10.0, "dmg_max": 15.0,
		"cd_min": 0.85, "cd_max": 1.25, "arc_deg": 110.0, "max_targets": 2},
	{"id": "pike", "name": "雙手長槍", "unit": 0, "layer": "spear", "anim": "thrust",
		"reach": 2.5, "dmg_min": 11.0, "dmg_max": 16.0, "arc_deg": 30.0, "max_targets": 1,
		"min_dist": 1.1, "close_mult": 0.5, "backoff": true, "vs_cavalry": 1.8},
	{"id": "greatsword", "name": "大劍", "unit": 0, "layer": "greatsword", "anim": "heavy",
		"reach": 2.0, "dmg_min": 15.0, "dmg_max": 21.0, "cd_min": 1.6, "cd_max": 2.2,
		"arc_deg": 160.0, "max_targets": 3, "knock": 1.3},
	{"id": "axe_2h", "name": "雙手斧", "unit": 0, "layer": "axe_ts", "anim": "heavy",
		"reach": 1.7, "dmg_min": 17.0, "dmg_max": 24.0, "cd_min": 1.7, "cd_max": 2.3,
		"arc_deg": 140.0, "max_targets": 2, "knock": 1.4},
	{"id": "mace_2h", "name": "雙手錘", "unit": 0, "layer": "mace_ts", "anim": "heavy",
		"reach": 1.6, "dmg_min": 13.0, "dmg_max": 19.0, "cd_min": 1.6, "cd_max": 2.2,
		"arc_deg": 130.0, "max_targets": 2, "knock": 3.0},
	# --- 弓兵（近戰只在 6 公尺內、用弓身與短刀，傷害低） ---
	{"id": "bow", "name": "弓", "unit": 1, "layer": "bow", "anim": "bow",
		"reach": 1.4, "dmg_min": 5.0, "dmg_max": 8.0, "arc_deg": 90.0, "max_targets": 1},
	# --- 騎兵 ---
	{"id": "lance", "name": "騎槍＋盾", "unit": 2, "layer": "spear", "anim": "thrust", "shield": true,
		"block": 0.15, "arrow_mult": 0.75, "reach": 2.0, "dmg_min": 11.0, "dmg_max": 16.0,
		"arc_deg": 40.0, "max_targets": 1, "charge_mult": 1.3},
	{"id": "cav_sword", "name": "劍＋盾", "unit": 2, "layer": "sword", "anim": "swing", "shield": true,
		"block": 0.3, "arrow_mult": 0.6, "reach": 1.9, "dmg_min": 11.0, "dmg_max": 16.0,
		"cd_min": 0.9, "cd_max": 1.3, "arc_deg": 110.0, "max_targets": 2},
	# --- 攻城戰守方的劍盾兵（數值沿用攻城平衡版本） ---
	{"id": "siege_sword_shield", "name": "劍盾兵", "unit": 3, "layer": "sword", "anim": "swing", "shield": true,
		"block": 0.4, "arrow_mult": 0.5, "reach": 1.5, "dmg_min": 10.0, "dmg_max": 15.0,
		"cd_min": 0.85, "cd_max": 1.25, "arc_deg": 110.0, "max_targets": 1},
]

static var _resolved: Array = []


static func count() -> int:
	return ALL.size()


static func get_def(i: int) -> Dictionary:
	if _resolved.is_empty():
		for d in ALL:
			var r: Dictionary = DEFAULT.duplicate()
			r.merge(d, true)
			_resolved.append(r)
	return _resolved[clampi(i, 0, ALL.size() - 1)]


static func index_of(id: String) -> int:
	for i in ALL.size():
		if ALL[i]["id"] == id:
			return i
	return -1


## 這個兵種可以選的配置（編號）。劍盾兵是攻城戰專用，不出現在選單裡
static func options_for(unit: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in ALL.size():
		if int(ALL[i]["unit"]) == unit:
			out.append(i)
	return out


## 兵種的預設配置（沿用改版前的裝備：步兵長槍盾、弓兵弓、騎兵騎槍盾、劍盾兵）
static func default_for(unit: int) -> int:
	match unit:
		1:
			return index_of("bow")
		2:
			return index_of("lance")
		3:
			return index_of("siege_sword_shield")
	return index_of("spear_shield")


## 配置 id 轉編號；找不到或不屬於該兵種時退回該兵種的預設
static func resolve(id: String, unit: int) -> int:
	var i := index_of(id)
	if i < 0 or int(ALL[i]["unit"]) != unit:
		return default_for(unit)
	return i
