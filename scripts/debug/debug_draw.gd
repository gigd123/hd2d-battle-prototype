class_name DebugDraw
extends MeshInstance3D
## 除錯線段繪製（F3 開關）：玩家武器掃掠軌跡、小隊目標點等。
## 只在開啟時每幀重建 ImmediateMesh，關閉時不花任何成本。

var player: PlayerController
var battle: Node = null
var _im := ImmediateMesh.new()


func _ready() -> void:
	mesh = _im
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = 10
	material_override = mat
	top_level = true


func _process(_delta: float) -> void:
	_im.clear_surfaces()
	if not GameConfig.debug_draw:
		return
	var pts := PackedVector3Array()
	var cols := PackedColorArray()
	if player:
		for s in player.debug_sweeps:
			var a: float = clampf(s[3] / 0.6, 0.0, 1.0)
			var c := Color(1.0, 0.85, 0.2, a)
			# 刀尖軌跡＋刀身（構成掃掠面）
			pts.append(s[0]); pts.append(s[1]); cols.append(c); cols.append(c)
			pts.append(s[2]); pts.append(s[1]); cols.append(c * Color(1, 1, 1, 0.5)); cols.append(c * Color(1, 1, 1, 0.5))
		if player.horse:
			var hp := player.horse.global_position + Vector3(0, 0.3, 0)
			pts.append(hp); pts.append(hp + player.horse.forward() * (1.0 + player.horse.speed * 0.3))
			cols.append(Color.CYAN); cols.append(Color.CYAN)
	if battle != null and battle.has_method("append_debug_lines"):
		battle.call("append_debug_lines", pts, cols)
	if pts.is_empty():
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in pts.size():
		_im.surface_set_color(cols[i])
		_im.surface_add_vertex(pts[i])
	_im.surface_end()
