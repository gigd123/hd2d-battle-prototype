class_name DirectionUtil
extends RefCounted
## 把「角色在 3D 世界中的朝向」換算成「該畫哪一張方向圖」。
##
## 方向圖欄位固定為 8 欄（架構上限），依「相對於相機」的角度排列：
##   0=S(面向鏡頭) 1=SE 2=E(面向畫面右) 3=NE 4=N(背對鏡頭) 5=NW 6=W 7=SW
## 4 方向模式只用 0,2,4,6；鏡像模式把 1,2,3 改用 7,6,5 並水平翻轉。
## 這讓美術方向數可以晚點決定：素材永遠按 8 欄擺，缺的欄位由設定決定怎麼補。

const COLUMN_NAMES := ["S", "SE", "E", "NE", "N", "NW", "W", "SW"]


## 回傳 Vector2i(欄位, 是否水平翻轉 0/1)。
## facing：角色的水平朝向（世界座標）；cam_basis：相機的 basis。
static func resolve(facing: Vector3, cam_basis: Basis) -> Vector2i:
	return resolve_with(facing, cam_basis, GameConfig.direction_count(), GameConfig.mirror_enabled())


static func resolve_with(facing: Vector3, cam_basis: Basis, count: int, mirror: bool) -> Vector2i:
	var cam_right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z)
	var cam_fwd := Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z)
	var fx := facing.x * cam_right.x + facing.z * cam_right.z
	var fz := facing.x * cam_fwd.x + facing.z * cam_fwd.z
	return resolve_angle(atan2(fx, -fz), count, mirror)


## angle：0 = 面向鏡頭，+PI/2 = 面向畫面右，PI = 背對鏡頭。
static func resolve_angle(angle: float, count: int, mirror: bool) -> Vector2i:
	var step := TAU / float(count)
	var idx := wrapi(roundi(angle / step), 0, count)
	# 換算成 8 欄的欄位編號
	var col := idx * (GameConfig.MAX_DIRECTIONS / count)
	var flip := 0
	if mirror and col > 0 and col < 4:
		col = 8 - col
		flip = 1
	return Vector2i(col, flip)


## 給 MultiMesh 等需要「連續角度」的地方使用（0..TAU，0 = 面向鏡頭）。
static func relative_angle(facing: Vector3, cam_basis: Basis) -> float:
	var cam_right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z)
	var cam_fwd := Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z)
	var fx := facing.x * cam_right.x + facing.z * cam_right.z
	var fz := facing.x * cam_fwd.x + facing.z * cam_fwd.z
	return atan2(fx, -fz)
