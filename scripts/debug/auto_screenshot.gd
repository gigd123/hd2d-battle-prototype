extends Node
## 開發用：命令列加上 `-- --screenshot=路徑.png [--screenshot-frames=180]`
## 會在指定幀數後存一張畫面截圖並結束程式（用於自動化檢查畫面）。

var path := ""
var frames := 180
var _count := 0


func _process(_delta: float) -> void:
	_count += 1
	if _count == frames:
		var img := get_viewport().get_texture().get_image()
		img.save_png(path)
		print("[auto_screenshot] saved ", path)
		get_tree().quit()
