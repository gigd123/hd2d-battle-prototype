extends Node
## 階段 3：壓力測試（決策點）
##
## 在同一個戰場場景依序跑 50／100／200 名士兵（雙方合計），可選兩種士兵畫面後端，
## 記錄每幀幀時間與各子系統耗時，最後輸出：
##   - 畫面上的摘要表（同時複製到剪貼簿，可直接貼回對話）
##   - user://stress_results/ 下的摘要 CSV、摘要文字檔、每次測試的逐幀 CSV
## 暫不設幀率門檻，只記錄數據，由使用者判斷要繼續、改寫熱點或檢討架構。
##
## 命令列參數（放在 `--` 之後）：
##   --counts=50,100,200        士兵總數（雙方合計）
##   --backends=sprite,multimesh
##   --duration=20  --warmup=3  每次測試秒數與暖機秒數
##   --immortal                 士兵不死亡，整段測試維持固定人數
##   --no-postfx                關閉景深/泛光/SSAO/霧
##   --quit                     測完自動結束（批次執行用）

const BATTLEFIELD := preload("res://scenes/battlefield.tscn")

var counts: Array[int] = [50, 100, 200]
var backends: Array[int] = [GameConfig.SoldierBackend.SPRITE3D, GameConfig.SoldierBackend.MULTIMESH]
var duration := 20.0
var warmup := 3.0
var immortal := false
var quit_when_done := false

var _runs: Array[Dictionary] = []      # 待跑清單 {count, backend}
var _run_index := -1
var _bf: Battlefield
var _elapsed := 0.0
var _frame_ms := PackedFloat32Array()
var _process_ms := PackedFloat32Array()
var _physics_ms := PackedFloat32Array()
var _render_update_ms := PackedFloat32Array()
var _gpu_ms := PackedFloat32Array()
var _cpu_render_ms := PackedFloat32Array()
var _draw_calls := PackedFloat32Array()
var _sim_total := PackedFloat32Array()
var _sim_grid := PackedFloat32Array()
var _sim_think := PackedFloat32Array()
var _sim_move := PackedFloat32Array()
var _results: Array[Dictionary] = []
var _label: Label
var _started_at := ""
var _headless := false


func _ready() -> void:
	_parse_args()
	_headless = DisplayServer.get_name() == "headless"
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_started_at = Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	for b in backends:
		for c in counts:
			_runs.append({"count": c, "backend": b})
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_label)
	_next_run()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var key := a.get_slice("=", 0)
		var val := a.get_slice("=", 1) if a.contains("=") else ""
		match key:
			"--counts":
				counts.clear()
				for v in val.split(",", false):
					counts.append(int(v))
			"--backends":
				backends.clear()
				for v in val.split(",", false):
					backends.append(GameConfig.SoldierBackend.MULTIMESH if v.strip_edges() == "multimesh" else GameConfig.SoldierBackend.SPRITE3D)
			"--duration":
				duration = float(val)
			"--warmup":
				warmup = float(val)
			"--immortal":
				immortal = true
			"--quit":
				quit_when_done = true


func _next_run() -> void:
	if _bf:
		_bf.queue_free()
		_bf = null
	_run_index += 1
	if _run_index >= _runs.size():
		_finish()
		return
	var run := _runs[_run_index]
	GameConfig.soldier_backend = run["backend"]
	GameConfig.battle_seed = 12345          # 每次測試同一種子
	_bf = BATTLEFIELD.instantiate()
	_bf.stress_mode = true
	_bf.soldiers_per_team = int(run["count"]) / 2
	add_child(_bf)
	_bf.battle.immortal = immortal
	_elapsed = 0.0
	_frame_ms = PackedFloat32Array()
	_process_ms = PackedFloat32Array()
	_physics_ms = PackedFloat32Array()
	_render_update_ms = PackedFloat32Array()
	_gpu_ms = PackedFloat32Array()
	_cpu_render_ms = PackedFloat32Array()
	_draw_calls = PackedFloat32Array()
	_sim_total = PackedFloat32Array()
	_sim_grid = PackedFloat32Array()
	_sim_think = PackedFloat32Array()
	_sim_move = PackedFloat32Array()


func _process(delta: float) -> void:
	if _bf == null:
		return
	_elapsed += delta
	var run := _runs[_run_index]
	var phase := "暖機" if _elapsed < warmup else "記錄中"
	_label.text = "壓力測試 %d/%d：士兵 %d 人（%s）　%s %.0f/%.0f 秒\nFPS %d　存活 %d：%d" % [
		_run_index + 1, _runs.size(), run["count"], _backend_name(run["backend"]), phase,
		maxf(0.0, _elapsed - warmup), duration, Engine.get_frames_per_second(),
		_bf.battle.alive_count[0], _bf.battle.alive_count[1]]
	if _elapsed < warmup:
		return
	var vp := get_viewport().get_viewport_rid()
	_frame_ms.append(delta * 1000.0)
	_process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_render_update_ms.append(_bf.battle.t_render / 1000.0)
	_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
	_cpu_render_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
	_draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	if _elapsed >= warmup + duration:
		_collect(run)
		_next_run()


func _physics_process(_delta: float) -> void:
	# 每個物理步記錄一次戰場邏輯耗時（讀到的是上一個物理步的值，每步一筆）
	if _bf == null or _elapsed < warmup:
		return
	var bm := _bf.battle
	_sim_total.append(bm.t_total / 1000.0)
	_sim_grid.append(bm.t_grid / 1000.0)
	_sim_think.append(bm.t_think / 1000.0)
	_sim_move.append(bm.t_move / 1000.0)


func _collect(run: Dictionary) -> void:
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var n := sorted.size()
	var avg := _avg(_frame_ms)
	var worst_n := maxi(1, n / 100)
	var worst_sum := 0.0
	for k in worst_n:
		worst_sum += sorted[n - 1 - k]
	var r := {
		"backend": _backend_name(run["backend"]),
		"soldiers": run["count"],
		"frames": n,
		"avg_fps": 1000.0 / maxf(avg, 0.001),
		"avg_frame_ms": avg,
		"p50_frame_ms": _pct(sorted, 0.50),
		"p95_frame_ms": _pct(sorted, 0.95),
		"p99_frame_ms": _pct(sorted, 0.99),
		"max_frame_ms": sorted[n - 1] if n > 0 else 0.0,
		"low1_fps": 1000.0 / maxf(worst_sum / worst_n, 0.001),
		"sim_avg_ms": _avg(_sim_total),
		"sim_max_ms": _max(_sim_total),
		"sim_grid_ms": _avg(_sim_grid),
		"sim_think_ms": _avg(_sim_think),
		"sim_move_ms": _avg(_sim_move),
		"visual_update_ms": _avg(_render_update_ms),
		"process_ms": _avg(_process_ms),
		"physics_ms": _avg(_physics_ms),
		"cpu_render_ms": _avg(_cpu_render_ms),
		"gpu_ms": _avg(_gpu_ms),
		"draw_calls": _avg(_draw_calls),
		"alive_end": "%d:%d" % [_bf.battle.alive_count[0], _bf.battle.alive_count[1]],
		"mem_static_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	}
	_results.append(r)
	_write_frames_csv(r)
	print("[stress] ", _row_text(r))


func _finish() -> void:
	var report := _report_text()
	print(report)
	var dir := "user://stress_results"
	DirAccess.make_dir_recursive_absolute(dir)
	var txt_path := dir.path_join("stress_%s.txt" % _started_at)
	var f := FileAccess.open(txt_path, FileAccess.WRITE)
	if f:
		f.store_string(report)
		f.close()
	var csv_path := dir.path_join("stress_%s_summary.csv" % _started_at)
	var c := FileAccess.open(csv_path, FileAccess.WRITE)
	if c and not _results.is_empty():
		c.store_line(",".join(PackedStringArray(_results[0].keys())))
		for r in _results:
			var vals := PackedStringArray()
			for k in r.keys():
				var v = r[k]
				vals.append(("%.3f" % v) if v is float else str(v))
			c.store_line(",".join(vals))
		c.close()
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not _headless:
		DisplayServer.clipboard_set(report)
	_label.text = report + "\n\n結果已存到：%s\n（摘要已複製到剪貼簿，可直接貼回對話）\n按 Esc 結束" % abs_dir
	print("[stress] 結果資料夾：", abs_dir)
	if quit_when_done:
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse") and _run_index >= _runs.size():
		get_tree().quit()


func _report_text() -> String:
	var lines: Array[String] = []
	lines.append("=== HD-2D 戰場原型 壓力測試 ===")
	lines.append("時間：%s　Godot %s　%s" % [Time.get_datetime_string_from_system(), Engine.get_version_info().string, RenderingServer.get_current_rendering_method()])
	lines.append("CPU：%s（%d 執行緒）　OS：%s" % [OS.get_processor_name(), OS.get_processor_count(), OS.get_name()])
	lines.append("GPU：%s %s" % [RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_name()])
	lines.append("視窗：%s　VSync 關　後製：%s　士兵不死：%s　每次 %.0f 秒（暖機 %.0f 秒）" % [
		str(get_viewport().get_visible_rect().size), "開" if GameConfig.postfx_enabled else "關", "是" if immortal else "否", duration, warmup])
	if _headless:
		lines.append("※ headless 模式沒有實際繪圖，只有「戰場邏輯」數據有參考價值")
	lines.append("")
	lines.append("後端       人數  平均FPS  1%低FPS  平均幀ms  P99幀ms  最差幀ms | 邏輯平均ms 最差ms (網格/決策/移動) | 畫面更新ms  CPU繪製ms  GPU ms  DrawCalls  結束存活")
	for r in _results:
		lines.append(_row_text(r))
	return "\n".join(lines)


func _row_text(r: Dictionary) -> String:
	return "%-9s %5d  %7.1f  %7.1f  %8.2f  %7.2f  %8.2f | %9.2f %6.2f (%.2f/%.2f/%.2f) | %9.2f  %9.2f  %6.2f  %9.0f  %s" % [
		r["backend"], r["soldiers"], r["avg_fps"], r["low1_fps"], r["avg_frame_ms"], r["p99_frame_ms"], r["max_frame_ms"],
		r["sim_avg_ms"], r["sim_max_ms"], r["sim_grid_ms"], r["sim_think_ms"], r["sim_move_ms"],
		r["visual_update_ms"], r["cpu_render_ms"], r["gpu_ms"], r["draw_calls"], r["alive_end"]]


func _write_frames_csv(r: Dictionary) -> void:
	var dir := "user://stress_results"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("stress_%s_%s_%d_frames.csv" % [_started_at, r["backend"], r["soldiers"]])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("frame,frame_ms,process_ms,physics_ms,visual_update_ms,cpu_render_ms,gpu_ms,draw_calls")
	for i in _frame_ms.size():
		f.store_line("%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d" % [i, _frame_ms[i], _process_ms[i], _physics_ms[i], _render_update_ms[i], _cpu_render_ms[i], _gpu_ms[i], int(_draw_calls[i])])
	f.close()


static func _backend_name(b: int) -> String:
	return "MultiMesh" if b == GameConfig.SoldierBackend.MULTIMESH else "Sprite3D"


static func _avg(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


static func _pct(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(q * (sorted.size() - 1)), 0, sorted.size() - 1)]
