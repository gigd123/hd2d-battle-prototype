extends Node
## 開發用自動腳本：模擬按鍵操作並在指定時間截圖，用於沒有人操作時檢查功能。
## 用法：godot --path . -- --scenario=ride --shots=/某資料夾
## 每一步是 [開始秒數, 動作, 參數]。

var shots_dir := "user://scenario_shots"
var steps: Array = []
var _t := 0.0
var _i := 0
var _held: Array[StringName] = []


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
		_:
			steps = [[0.5, "quit", ""]]


func _physics_process(delta: float) -> void:
	_t += delta
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
			Input.action_press(arg)
			await get_tree().physics_frame
			await get_tree().physics_frame
			Input.action_release(arg)
		"shot":
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute(shots_dir)
			var img := get_viewport().get_texture().get_image()
			img.save_png(shots_dir.path_join(arg + ".png"))
			print("[scenario] shot ", arg)
		"quit":
			get_tree().quit()
