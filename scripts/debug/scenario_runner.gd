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
			print("[scenario] t=%.0f  玩家擊殺 %d 生命 %d  %s" % [_t, pl.get("total_kills"), pl.get("hp"), bm.call("stats_text").replace("\n", " | ")])
			if int(bm.get("winner")) != -1:
				get_tree().quit()
		"quit":
			get_tree().quit()
