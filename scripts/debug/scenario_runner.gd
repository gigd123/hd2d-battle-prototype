extends Node
## 開發用自動腳本：模擬按鍵操作並在指定時間截圖，用於沒有人操作時檢查功能。
## 用法：godot --path . -- --scenario=ride --shots=/某資料夾
## 每一步是 [開始秒數, 動作, 參數]。

var shots_dir := "user://scenario_shots"
var steps: Array = []
var _t := 0.0
var _i := 0
var _held: Array[StringName] = []
var _follow_cam := false


func setup(scenario: String) -> void:
	match scenario:
		"ride":
			steps = [
				[0.5, "shot", "00_start"],
				[0.6, "hold", "move_right"],      # 往馬走（馬在玩家右側 +X）
				[1.0, "release", "move_right"],
				[1.1, "tap", "interact"],
				[1.7, "shot", "01_mounted"],
				[1.8, "hold", "move_forward"],
				[1.8, "hold", "sprint"],
				[4.0, "shot", "02_gallop"],
				[4.1, "tap", "attack"],
				[4.42, "shot", "03_swing"],
				[4.6, "hold", "move_left"],
				[6.0, "shot", "04_turning"],
				[6.1, "release", "move_left"],
				[7.5, "shot", "05_battle"],
				[7.6, "tap", "attack"],
				[8.0, "release", "move_forward"],
				[8.0, "release", "sprint"],
				[9.5, "tap", "interact"],
				[10.0, "shot", "06_dismounted"],
				[10.2, "quit", ""],
			]
		"siege":
			# 攻城戰：玩家不操作，每 10 秒印一次戰況，分出勝負或時間到就結束
			for k in range(1, 62):
				steps.append([k * 10.0, "report", ""])
			steps.append([620.0, "quit", ""])
		"siege_shots":
			# 攻城戰截圖：俯瞰城牆與雲梯、攻城槌、牆頂近景
			steps = [
				[0.2, "overview_at", "6,-6,44,-2.2"],
				[3.0, "shot", "s01_overview"],
				[20.0, "shot", "s02_assault"],
				[21.0, "overview_at", "4,-20,22,-2.0"],
				[40.0, "shot", "s03_ladders"],
				[41.0, "overview_at", "2,0,20,-2.5"],
				[70.0, "shot", "s04_ram"],
				[71.0, "report", ""],
				[71.5, "quit", ""],
			]
		"ladder_test":
			steps = [
				[0.2, "teleport", "1,-14"], [0.3, "yaw", "-1.5708"], [0.5, "hold", "move_forward"],
				[1.5, "pos", ""], [2.5, "pos", ""], [3.5, "pos", ""], [4.5, "pos", ""], [4.6, "release", "move_forward"], [5.5, "pos", ""], [5.6, "quit", ""],
			]
		"siege_video":
			# 攻城戰展示影片：前半玩家當守城方（牆頂守雲梯），後半當攻城方（跟著大軍爬梯上牆）
			# 用 --siege=defend 啟動
			steps = [
				[0.0, "overview_at", "6,-8,40,-2.0"], [0.05, "caption", "攻城戰・守城方（200 人）：城牆、城門、三道雲梯"],
				[0.1, "teleport_wall", "-12.2"],
				[7.0, "playercam", "1.5708,7,24"], [7.1, "caption", "玩家守在第二道雲梯的梯頂"],
			]
			for k in 32:
				steps.append([13.0 + k * 0.6, "tap", "attack"])
			steps.append_array([
				[33.0, "siege_side", "attack"],
				[33.2, "overview_at", "-14,-4,38,-0.9"], [33.25, "caption", "攻城戰・攻城方（400 人）：攻城槌推向城門，步兵分三路爬梯"],
				[33.3, "teleport", "-21,-14.6"],
				[39.0, "playercam", "-1.5708,6.5,20"], [39.1, "caption", "玩家跟著步兵衝向雲梯"],
				[39.2, "hold", "move_forward"], [39.2, "hold", "sprint"],
				[42.6, "release", "sprint"],
				[43.5, "caption", "雲梯很陡，爬上去約 6 秒；梯頂有敵人就得先打下來"],
				[50.0, "release", "move_forward"],
			])
			for k in 15:
				steps.append([50.3 + k * 0.6, "tap", "attack"])
			steps.append_array([[59.5, "report", ""], [60.0, "quit", ""]])
		"battle":
			# 玩家完全不操作，觀察戰鬥能否自行分出勝負（每 10 秒印一次戰況）
			for k in range(1, 25):
				steps.append([k * 10.0, "report", ""])
			steps.append([240.0, "quit", ""])
		"command":
			# 騎馬中下命令：衝鋒 → 跟隨 → 集結，並截圖
			steps = [
				[0.1, "cam", "26"],
				[0.6, "hold", "move_right"], [1.0, "release", "move_right"], [1.1, "tap", "interact"],
				[1.8, "tap", "order_charge"], [2.0, "hold", "move_forward"], [3.5, "hold", "sprint"],
				[6.0, "shot", "10_charge"], [6.5, "tap", "attack"], [7.0, "tap", "attack"],
				[8.0, "shot", "11_melee"], [8.5, "tap", "order_follow"], [9.0, "hold", "move_left"],
				[11.0, "shot", "12_follow"], [11.5, "release", "move_left"], [12.0, "tap", "order_hold"],
				[14.0, "shot", "13_hold"], [14.0, "report", ""], [14.2, "quit", ""],
			]
		"demo":
			# 展示影片：上馬 → 下令衝鋒 → 奔馳衝入敵陣連續揮擊 → 回轉再衝 → 下令跟隨 → 下馬
			steps = [
				[0.0, "cam", "20"], [0.0, "followcam", ""], [0.8, "tap", "interact"],
				[1.8, "tap", "order_charge"], [2.0, "hold", "move_forward"], [2.8, "hold", "sprint"],
				[5.40, "tap", "attack"],
				[6.06, "tap", "attack"],
				[6.72, "tap", "attack"],
				[7.38, "tap", "attack"],
				[8.04, "tap", "attack"],
				[8.70, "tap", "attack"],
				[9.0, "release", "move_forward"],
				[9.0, "hold", "move_back"],
				[10.6, "release", "move_back"],
				[10.6, "hold", "move_forward"],
				[11.60, "tap", "attack"],
				[12.26, "tap", "attack"],
				[12.92, "tap", "attack"],
				[13.58, "tap", "attack"],
				[14.24, "tap", "attack"],
				[14.90, "tap", "attack"],
				[15.2, "tap", "order_follow"],
				[15.4, "release", "sprint"],
				[17.5, "release", "move_forward"],
				[19.0, "tap", "interact"],
				[20.5, "tap", "attack"],
				[22.0, "report", ""], [22.1, "quit", ""],
			]
		"feedback":
			# 試玩回饋修正展示：邊打邊退、受擊反應、遮擋淡化、俯視比例與行軍、雪地騎馬貼地
			steps = [
				[0.0, "camp", "10,28"], [0.3, "hold", "move_back"],
				[0.5, "tap", "attack"], [1.0, "shot", "f01_back_attack"], [1.2, "tap", "attack"], [1.9, "tap", "attack"],
				[2.7, "release", "move_back"],
				[3.0, "hurt", "16"], [3.08, "shot", "f02_hurt"], [3.7, "hurt", "12"], [4.5, "hurt", "20"],
				[5.4, "occlude", ""], [6.2, "shot", "f03_occlusion"], [6.4, "hold", "move_left"], [7.6, "release", "move_left"],
				[8.0, "shot", "f03b_out_of_tree"],
				[8.5, "tap", "order_follow"], [8.6, "camp", "24,62"], [9.0, "hold", "move_forward"],
				[12.5, "shot", "f04_topdown_march"], [14.0, "release", "move_forward"],
				[14.5, "terrain", "snow"], [14.8, "camp", "8,14"], [15.0, "tap", "interact"], [15.6, "followcam", ""],
				[15.8, "hold", "move_left"], [16.4, "hold", "sprint"],
				[19.0, "release", "sprint"], [19.5, "shot", "f05_horse_snow"], [20.5, "release", "move_left"],
				[21.8, "shot", "f06_horse_snow_stop"], [22.3, "quit", ""],
			]
		"cavalry":
			# 騎兵特寫：我軍右翼騎兵迎面衝向鏡頭，看馬的朝向與轉彎
			steps = [
				[0.0, "overview_at", "0,-22,30,1.2"], [0.3, "charge", ""],
				[4.0, "shot", "cav_01"], [7.0, "shot", "cav_02"], [10.0, "shot", "cav_03"], [12.0, "quit", ""],
			]
		"spectate":
			# 觀戰鏡頭：切換、截圖、切回
			steps = [
				[0.3, "tap", "order_charge"], [0.5, "tap", "spectate"], [6.0, "shot", "spectate_on"],
				[6.2, "tap", "spectate"], [8.0, "shot", "spectate_off"], [8.2, "quit", ""],
			]
		"terrains":
			# 場地展示：五種場地輪流，每種俯瞰繞場約 7 秒，雙方開場即衝鋒
			var keys := BattleTerrain.TYPE_KEYS
			for k in keys.size():
				var t0 := k * 7.0
				if k > 0:
					steps.append([t0, "terrain", keys[k]])
				steps.append([t0 + 0.2, "overview", "46"])
				steps.append([t0 + 0.3, "charge", ""])
				steps.append([t0 + 6.0, "shot", "terrain_%d_%s" % [k, keys[k]]])
			steps.append([keys.size() * 7.0, "quit", ""])
		_:
			steps = [[0.5, "quit", ""]]


func _physics_process(delta: float) -> void:
	_t += delta
	if _follow_cam:
		# 相機慢慢轉到玩家（或馬）背後
		var bf := get_tree().current_scene
		var rig: OrbitFollowCamera = bf.get("cam_rig")
		var pl: PlayerController = bf.get("player")
		var h := atan2(pl.facing.x, pl.facing.z)
		rig.yaw = lerp_angle(rig.yaw, h + PI, 0.06)
	while _i < steps.size() and _t >= steps[_i][0]:
		_run(steps[_i])
		_i += 1


func _run(step: Array) -> void:
	var action: String = step[1]
	var arg: String = step[2]
	match action:
		"hold":
			Input.action_press(arg)
		"release":
			Input.action_release(arg)
		"tap":
			# 同時送出輸入事件（_unhandled_input 用）與動作狀態（Input.is_action_* 用）
			var ev := InputEventAction.new()
			ev.action = arg
			ev.pressed = true
			Input.parse_input_event(ev)
			Input.action_press(arg)
			await get_tree().physics_frame
			await get_tree().physics_frame
			Input.action_release(arg)
		"terrain":
			GameConfig.terrain_type = BattleTerrain.type_from_key(arg)
			get_tree().reload_current_scene()
		"overview":
			# 俯瞰戰場中央並慢慢繞場
			var bf := get_tree().current_scene
			var rig: OrbitFollowCamera = bf.get("cam_rig")
			var ter: BattleTerrain = bf.get("terrain")
			rig.auto_orbit = true
			rig.auto_orbit_center = Vector3(0, ter.get_height(0, 0), 0)
			rig.auto_orbit_speed = 0.16
			rig.distance = float(arg)
			rig.yaw = -PI * 0.5 - 0.6
			rig.pitch_deg = 22.0
			# 展示用：只留場地名稱提示
			var hud: BattleHUD = bf.get("hud")
			for c in hud.get_children():
				(c as Label).visible = false
			hud.toast("場地：%s　%s" % [ter.type_name(), BattleTerrain.TYPE_HINTS[ter.terrain_type]], 6.5)
		"camp":
			# 參數：距離, 俯角
			var cv := arg.split(",")
			var crig: OrbitFollowCamera = get_tree().current_scene.get("cam_rig")
			crig.distance = float(cv[0])
			crig.pitch_deg = float(cv[1])
		"hurt":
			# 從玩家正前方 2 公尺處打玩家一下
			var hp_pl: PlayerController = get_tree().current_scene.get("player")
			hp_pl.take_damage(float(arg), hp_pl.global_position + hp_pl.facing * 2.0)
		"occlude":
			# 把玩家移到最近一棵林中樹的正後方（從鏡頭看過去被樹擋住）
			var obf := get_tree().current_scene
			var opl: PlayerController = obf.get("player")
			var oter: BattleTerrain = obf.get("terrain")
			var orig: OrbitFollowCamera = obf.get("cam_rig")
			var best := Vector3.INF
			for ob in oter.obstacles:
				if absf(ob.z - 0.6) < 0.01 and Vector2(ob.x, ob.y).distance_to(Vector2(opl.global_position.x, opl.global_position.z)) < Vector2(best.x, best.y).distance_to(Vector2(opl.global_position.x, opl.global_position.z)):
					best = ob
			if best != Vector3.INF:
				var np := Vector3(best.x, 0, best.y) + orig.flat_forward() * 1.6
				np.y = oter.get_height(np.x, np.z) + 0.05
				opl.global_position = np
				opl.velocity = Vector3.ZERO
		"overview_at":
			# 參數：中心 x, z, 距離, yaw
			var v := arg.split(",")
			var bf := get_tree().current_scene
			var rig: OrbitFollowCamera = bf.get("cam_rig")
			var ter: BattleTerrain = bf.get("terrain")
			rig.auto_orbit = true
			rig.auto_orbit_center = Vector3(float(v[0]), ter.get_height(float(v[0]), float(v[1])), float(v[1]))
			rig.auto_orbit_speed = 0.06
			rig.distance = float(v[2])
			rig.yaw = float(v[3])
			rig.pitch_deg = 26.0
			var hud: BattleHUD = bf.get("hud")
			for c in hud.get_children():
				(c as Label).visible = false
		"charge":
			var bm: BattleManager = get_tree().current_scene.get("battle")
			bm.issue_order(0, BattleManager.Order.CHARGE, Vector3.ZERO, Vector3.ZERO)
			bm.issue_order(1, BattleManager.Order.CHARGE, Vector3.ZERO, Vector3.ZERO)
		"teleport", "teleport_wall":
			# 參數：x,z（teleport）或 z（teleport_wall：站到牆頂走道）
			var tbf := get_tree().current_scene
			var tpl: PlayerController = tbf.get("player")
			var tsg = tbf.get("siege_map")
			var tv := arg.split(",")
			var np := Vector3.ZERO
			if action == "teleport_wall":
				np = Vector3(SiegeMap.WALK_X0 + 1.0, tsg.wall_top() + 0.1, float(tv[0]))
			else:
				var ter2: BattleTerrain = tbf.get("terrain")
				np = Vector3(float(tv[0]), 0, float(tv[1]))
				np.y = ter2.get_height(np.x, np.z) + 0.1
			tpl.global_position = np
			tpl.spawn_point = np
			tpl.velocity = Vector3.ZERO
		"yaw":
			var yrig: OrbitFollowCamera = get_tree().current_scene.get("cam_rig")
			yrig.yaw = float(arg)
		"playercam":
			# 回到玩家相機。參數：yaw, 距離, 俯角
			var prig: OrbitFollowCamera = get_tree().current_scene.get("cam_rig")
			var pv := arg.split(",")
			prig.auto_orbit = false
			prig.yaw = float(pv[0])
			prig.distance = float(pv[1])
			prig.pitch_deg = float(pv[2])
		"caption":
			var chud: BattleHUD = get_tree().current_scene.get("hud")
			chud.toast(arg, 5.5)
		"siege_side":
			GameConfig.siege_mode = true
			GameConfig.siege_side = 1 if arg == "defend" else 0
			get_tree().reload_current_scene()
		"pos":
			var ppl: PlayerController = get_tree().current_scene.get("player")
			print("[scenario] player pos ", ppl.global_position)
		"followcam":
			_follow_cam = true
		"cam":
			var rig: Node = get_tree().current_scene.get("cam_rig")
			rig.set("distance", float(arg))
		"shot":
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute(shots_dir)
			var img := get_viewport().get_texture().get_image()
			img.save_png(shots_dir.path_join(arg + ".png"))
			print("[scenario] shot ", arg)
		"report":
			var bf := get_tree().current_scene
			var bm: Node = bf.get("battle")
			var pl: Node = bf.get("player")
			if bm.get("siege") != null:
				print("   ", bm.call("siege_debug"))
			print("[scenario] t=%.0f  玩家擊殺 %d 生命 %d  %s" % [_t, pl.get("total_kills"), pl.get("hp"), bm.call("stats_text").replace("\n", " | ")])
			if int(bm.get("winner")) != -1:
				get_tree().quit()
		"quit":
			get_tree().quit()
