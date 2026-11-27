extends Node
## 3D → 像素 Sprite Sheet 烘焙器。
##
## 讀一份 JSON 設定（模型來源、圖層、動作、錨點），把 3D 模型從 8 個方向逐幀渲染，
## 縮成像素圖、加外框，輸出成原型可以直接讀的分層圖集＋錨點資料。
##
## 用法（在專案資料夾執行，需要有顯示卡的一般 Godot，不能用 --headless）：
##   godot --path . res://tools/sprite_baker/bake_sprites.tscn
##       → 烘焙預設的兩份設定（knight、horse）
##   godot --path . res://tools/sprite_baker/bake_sprites.tscn -- --config=res://tools/sprite_baker/configs/knight.json
##       → 只烘焙指定設定（可用逗號分隔多份）
##   godot --path . res://tools/sprite_baker/bake_sprites.tscn -- --export-glb=res://art_src
##       → 把內建的程式模型匯出成 glb（可在 Blender 打開，當作自己做模型的範本）
## 在編輯器裡也可以直接開啟 bake_sprites.tscn 按 F6 執行（等同第一種）。
##
## 輸出（預設 res://art/baked/<name>/）：
##   <layer>.png        每個圖層一張圖集：8 欄（方向 S,SE,E,NE,N,NW,W,SW）× N 列（動作幀）
##   <layer>_team.png   陣營色遮罩（白 = 這個像素要乘上陣營色），只有含 Team 零件的圖層才有
##   sprites.json       幀大小、每公尺像素、原點、動作表、每格錨點
##   preview.png        所有圖層疊起來的總覽（套藍色陣營色），方便檢查

const DEFAULT_CONFIGS := [
	"res://tools/sprite_baker/configs/horse.json",
	"res://tools/sprite_baker/configs/knight.json",
]
const DIR_NAMES := ["S", "SE", "E", "NE", "N", "NW", "W", "SW"]
const KEY := Color(1, 0, 1)
const PREVIEW_TINT := Color(0.40, 0.60, 1.0)

var _vp: SubViewport
var _cam: Camera3D
var _turntable: Node3D
var _toon_shader: Shader = preload("res://tools/sprite_baker/toon_bake.gdshader")
var _flat_shader: Shader = preload("res://tools/sprite_baker/flat_color.gdshader")
var _key_mat: ShaderMaterial
var _white_mat: ShaderMaterial
var _black_mat: ShaderMaterial
var _captures := 0


func _ready() -> void:
	get_window().size = Vector2i(256, 160)
	var configs: Array = []
	var export_dir := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--config="):
			for c in a.get_slice("=", 1).split(",", false):
				configs.append(c)
		elif a.begins_with("--export-glb="):
			export_dir = a.get_slice("=", 1)
	if configs.is_empty() and export_dir == "":
		configs = DEFAULT_CONFIGS.duplicate()
	_key_mat = _flat(KEY)
	_white_mat = _flat(Color.WHITE)
	_black_mat = _flat(Color.BLACK)
	_setup_viewport()
	if export_dir != "":
		_export_builtin(export_dir)
	var t0 := Time.get_ticks_msec()
	for c in configs:
		await _bake_config(c)
	print("[baker] 全部完成，共 %d 次渲染，%.1f 秒" % [_captures, (Time.get_ticks_msec() - t0) / 1000.0])
	get_tree().quit()


func _flat(c: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _flat_shader
	m.set_shader_parameter("color", c)
	return m


func _setup_viewport() -> void:
	_vp = SubViewport.new()
	_vp.name = "BakeViewport"
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_vp.use_taa = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = false
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_WIDTH
	_cam.environment = env
	_cam.near = 0.05
	_cam.far = 200.0
	_vp.add_child(_cam)
	_cam.current = true
	_turntable = Node3D.new()
	_turntable.name = "Turntable"
	_vp.add_child(_turntable)


# ---------------------------------------------------------------------------
# 模型來源
# ---------------------------------------------------------------------------
func _load_source(src: String, cfg_path: String) -> Node3D:
	if src.begins_with("builtin:"):
		return ProceduralRigs.build(src.get_slice(":", 1))
	var path := src
	if not path.begins_with("res://") and not path.begins_with("user://") and not path.is_absolute_path():
		path = cfg_path.get_base_dir().path_join(src)
	var ext := path.get_extension().to_lower()
	if ext == "glb" or ext == "gltf":
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var err := doc.append_from_file(ProjectSettings.globalize_path(path), st)
		if err != OK:
			push_error("[baker] 讀不到 glTF：%s（錯誤 %d）" % [path, err])
			return null
		return doc.generate_scene(st) as Node3D
	if ext == "tscn" or ext == "scn":
		var ps := load(path) as PackedScene
		return ps.instantiate() as Node3D if ps else null
	push_error("[baker] 不支援的模型格式：" + path)
	return null


func _export_builtin(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for n in ["knight", "horse"]:
		var rig := ProceduralRigs.build(n)
		add_child(rig)
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var err := doc.append_from_scene(rig, st)
		if err == OK:
			err = doc.write_to_filesystem(st, ProjectSettings.globalize_path(dir.path_join(n + ".glb")))
		print("[baker] 匯出 %s.glb → %s（%s）" % [n, dir, "成功" if err == OK else "失敗 %d" % err])
		rig.free()


static func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r:
			return r
	return null


static func _matches(node_name: String, patterns: Array) -> bool:
	for p in patterns:
		if node_name.matchn(str(p)):
			return true
	return false


## 找錨點：先找同名節點，再找同名骨頭（自動掛 BoneAttachment3D）
static func _find_anchor(rig: Node3D, anchor_name: String) -> Node3D:
	var n := rig.find_child(anchor_name, true, false) as Node3D
	if n:
		return n
	for sk in rig.find_children("*", "Skeleton3D", true, false):
		var skel := sk as Skeleton3D
		var bi := skel.find_bone(anchor_name)
		if bi < 0:
			bi = skel.find_bone(anchor_name.replace(":", "_"))
		if bi >= 0:
			var ba := BoneAttachment3D.new()
			ba.bone_idx = bi
			skel.add_child(ba)
			return ba
	return null


# ---------------------------------------------------------------------------
# 烘焙一份設定
# ---------------------------------------------------------------------------
func _bake_config(cfg_path: String) -> void:
	var text := FileAccess.get_file_as_string(cfg_path)
	var cfg = JSON.parse_string(text)
	if typeof(cfg) != TYPE_DICTIONARY:
		push_error("[baker] 設定檔讀取失敗：" + cfg_path)
		return
	var set_name: String = cfg.get("name", cfg_path.get_file().get_basename())
	var out_dir: String = cfg.get("output", "res://art/baked/" + set_name)
	var fw := int(cfg["frame_size"][0])
	var fh := int(cfg["frame_size"][1])
	var ps := float(cfg.get("pixel_size", 0.045))
	var pitch := deg_to_rad(float(cfg.get("pitch_deg", 30.0)))
	var ss := int(cfg.get("supersample", 4))
	var margin := int(cfg.get("bottom_margin", 6))
	var yaw_offset := 180.0 if str(cfg.get("forward", "+Z")) == "-Z" else 0.0
	yaw_offset += float(cfg.get("yaw_offset_deg", 0.0))
	var post := {
		"alpha_threshold": float(cfg.get("alpha_threshold", 0.5)),
		"color_levels": int(cfg.get("color_levels", 24)),
		"outline": bool(cfg.get("outline", true)),
		"outline_darken": float(cfg.get("outline_darken", 0.32)),
	}
	print("[baker] 開始烘焙 %s（%dx%d 像素，每像素 %.3f 公尺）" % [set_name, fw, fh, ps])

	var rig := _load_source(str(cfg["source"]), cfg_path)
	if rig == null:
		return
	rig.scale *= float(cfg.get("scale", 1.0))
	_turntable.rotation = Vector3.ZERO
	_turntable.add_child(rig)
	var ap := _find_anim_player(rig)
	if ap == null:
		push_error("[baker] 模型裡找不到 AnimationPlayer：" + set_name)
		rig.queue_free()
		return
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL

	# 圖層與零件
	var layers: Array = cfg["layers"]
	var meshes: Array = []          # [MeshInstance3D, layer_idx, is_team, toon_materials]
	var light_dir: Array = cfg.get("light_dir_view", [-0.45, 0.65, 0.62])
	for mi_node in rig.find_children("*", "MeshInstance3D", true, false):
		var mi := mi_node as MeshInstance3D
		var li := -1
		var team := false
		for i in layers.size():
			var L: Dictionary = layers[i]
			if _matches(mi.name, L.get("include", ["*"])) and not _matches(mi.name, L.get("exclude", [])):
				li = i
				team = _matches(mi.name, L.get("team", []))
				break
		var toon: Array = []
		if mi.mesh:
			for s in mi.mesh.get_surface_count():
				toon.append(_make_toon(mi.get_active_material(s), light_dir, cfg))
		meshes.append([mi, li, team, toon])
		if li < 0:
			mi.visible = false

	# 錨點
	var anchor_nodes := {}
	var anchors_cfg: Dictionary = cfg.get("anchors", {})
	for an in anchors_cfg:
		var node := _find_anchor(rig, str(anchors_cfg[an]))
		if node:
			anchor_nodes[an] = node
		else:
			push_warning("[baker] 找不到錨點 %s（%s）" % [an, anchors_cfg[an]])

	# 遮擋物（例如騎乘動作時的馬）：只寫深度、輸出時挖空，讓騎士被馬擋住的部分自動消失
	var holdouts: Array = []
	for h in cfg.get("holdouts", []):
		var hrig := _load_source(str(h["source"]), cfg_path)
		if hrig == null:
			continue
		_turntable.add_child(hrig)
		for m in hrig.find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).material_override = _key_mat
		var hap := _find_anim_player(hrig)
		if hap:
			hap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			if h.has("anim") and hap.has_animation(h["anim"]):
				hap.play(h["anim"])
				hap.seek(float(h.get("time", 0.0)), true)
		var align: Array = h.get("align", [])
		var self_node: Node3D = _find_anchor(rig, align[0]) if align.size() == 2 else null
		var other_node: Node3D = _find_anchor(hrig, align[1]) if align.size() == 2 else null
		holdouts.append({"rig": hrig, "actions": h.get("actions", ["*"]), "self": self_node, "other": other_node})

	# 鏡頭：KEEP_WIDTH，寬 = fw*ps；高度方向乘 cos(俯角) 補償，讓 1 公尺高的柱子在圖上也是 1/ps 像素
	var W := fw * ss
	var Hs := maxi(1, int(round(fh * ss * cos(pitch))))
	_vp.size = Vector2i(W, Hs)
	_cam.size = fw * ps
	var ev := fw * ps * float(Hs) / float(W)        # 畫面垂直方向的世界長度
	var v_ps := ev / float(fh)                      # 每輸出像素列對應的鏡頭平面長度
	var origin_px := Vector2(fw * 0.5, fh - margin)
	var cb := Basis(Vector3.RIGHT, -pitch)
	var center := cb.y * ((origin_px.y - fh * 0.5) * v_ps) - cb.x * ((origin_px.x - fw * 0.5) * ps)
	_cam.global_transform = Transform3D(cb, center + cb.z * 40.0)

	# 動作表
	var actions: Array = []
	var total_rows := 0
	for a in cfg["actions"]:
		var anim_name: String = a.get("anim", a["name"])
		if not ap.has_animation(anim_name):
			push_warning("[baker] 動畫不存在，略過：" + anim_name)
			continue
		var frames := int(a.get("frames", 6))
		actions.append({"name": a["name"], "anim": anim_name, "frames": frames, "fps": float(a.get("fps", 10.0)),
			"loop": bool(a.get("loop", true)), "row": total_rows,
			"start": float(a.get("start", 0.0)), "end": float(a.get("end", ap.get_animation(anim_name).length))})
		total_rows += frames

	var sheets: Array[Image] = []
	var team_sheets: Array = []
	for i in layers.size():
		sheets.append(Image.create_empty(fw * 8, fh * total_rows, false, Image.FORMAT_RGBA8))
		var has_team := false
		for m in meshes:
			if m[1] == i and m[2]:
				has_team = true
		team_sheets.append(Image.create_empty(fw * 8, fh * total_rows, false, Image.FORMAT_L8) if has_team else null)
	var anchor_data := {}
	for an in anchor_nodes:
		var arr := PackedFloat32Array()
		arr.resize(8 * total_rows * 2)
		anchor_data[an] = arr

	var t0 := Time.get_ticks_msec()
	for act in actions:
		ap.play(act["anim"])
		var active_holdouts: Array = []
		for h in holdouts:
			var on := _matches(act["name"], h["actions"])
			(h["rig"] as Node3D).visible = on
			if on:
				active_holdouts.append(h)
		for f in int(act["frames"]):
			var span: float = act["end"] - act["start"]
			var t: float = act["start"] + (span * f / act["frames"] if act["loop"] else span * f / maxi(1, act["frames"] - 1))
			var row: int = act["row"] + f
			for d in 8:
				_turntable.rotation = Vector3(0, deg_to_rad(d * 45.0 + yaw_offset), 0)
				ap.seek(t, true)
				for h in active_holdouts:
					var hr := h["rig"] as Node3D
					hr.position = Vector3.ZERO
					if h["self"] and h["other"]:
						hr.global_position += (h["self"] as Node3D).global_position - (h["other"] as Node3D).global_position
				# 錨點投影到幀內像素
				for an in anchor_nodes:
					var p: Vector3 = (anchor_nodes[an] as Node3D).global_position - center
					var px := fw * 0.5 + p.dot(cb.x) / ps
					var py := fh * 0.5 - p.dot(cb.y) / v_ps
					var ai: int = (row * 8 + d) * 2
					anchor_data[an][ai] = snappedf(px, 0.1)
					anchor_data[an][ai + 1] = snappedf(py, 0.1)
				# 逐層渲染
				for li in layers.size():
					var needs_silhouette := li > 0 or not active_holdouts.is_empty()
					var sil := PackedByteArray()
					if needs_silhouette and post["outline"]:
						_apply_pass(meshes, li, "solo", active_holdouts)
						sil = _reduce(await _capture(), fw, fh, ss, post, PackedByteArray(), true)["opaque"]
					_apply_pass(meshes, li, "color", active_holdouts)
					var res := _reduce(await _capture(), fw, fh, ss, post, sil, false)
					sheets[li].blit_rect(res["image"], Rect2i(0, 0, fw, fh), Vector2i(d * fw, row * fh))
					if team_sheets[li] != null:
						_apply_pass(meshes, li, "team", active_holdouts)
						var team_img := _team_mask(await _capture(), fw, fh, ss, res["opaque"])
						(team_sheets[li] as Image).blit_rect(team_img, Rect2i(0, 0, fw, fh), Vector2i(d * fw, row * fh))
		print("[baker]   %s：%d 幀 × 8 方向（累計 %.1f 秒）" % [act["name"], act["frames"], (Time.get_ticks_msec() - t0) / 1000.0])

	# 存檔
	var abs_dir := ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var layer_meta: Array = []
	for li in layers.size():
		var ln: String = layers[li]["name"]
		sheets[li].save_png(abs_dir.path_join(ln + ".png"))
		var lm := {"name": ln, "image": ln + ".png"}
		if team_sheets[li] != null:
			(team_sheets[li] as Image).save_png(abs_dir.path_join(ln + "_team.png"))
			lm["team_mask"] = ln + "_team.png"
		lm["default_visible"] = bool(layers[li].get("default_visible", true))
		layer_meta.append(lm)
	var act_meta := {}
	for act in actions:
		act_meta[act["name"]] = {"row": act["row"], "frames": act["frames"], "fps": act["fps"], "loop": act["loop"]}
	var anchor_meta := {}
	for an in anchor_data:
		anchor_meta[an] = Array(anchor_data[an])
	var meta := {
		"format": "hd2d-baked-sprites", "version": 1,
		"name": set_name,
		"source": cfg["source"],
		"frame_size": [fw, fh],
		"pixel_size": ps,
		"pitch_deg": rad_to_deg(pitch),
		"origin": [origin_px.x, origin_px.y],
		"columns": 8, "rows": total_rows,
		"directions": DIR_NAMES,
		"layers": layer_meta,
		"actions": act_meta,
		"anchors": anchor_meta,
	}
	var fa := FileAccess.open(abs_dir.path_join("sprites.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(meta, "  ", false))
	fa.close()
	_save_preview(abs_dir, sheets, team_sheets, layers)
	print("[baker] %s 完成 → %s（%d 列 × 8 方向）" % [set_name, out_dir, total_rows])

	rig.queue_free()
	for h in holdouts:
		(h["rig"] as Node3D).queue_free()
	await get_tree().process_frame


func _make_toon(src: Material, light_dir: Array, cfg: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _toon_shader
	var col := Color.WHITE
	var tex: Texture2D = null
	if src is BaseMaterial3D:
		col = (src as BaseMaterial3D).albedo_color
		tex = (src as BaseMaterial3D).albedo_texture
	m.set_shader_parameter("albedo", col)
	if tex:
		m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("light_dir_view", Vector3(light_dir[0], light_dir[1], light_dir[2]))
	for k in ["shade_mid", "shade_dark", "band_hi", "band_lo"]:
		if cfg.has(k):
			m.set_shader_parameter(k, float(cfg[k]))
	return m


## mode："color" 本層上色、較低層挖空；"team" 本層白/黑遮罩；"solo" 只畫本層（算完整輪廓用）
func _apply_pass(meshes: Array, li: int, mode: String, holdouts: Array) -> void:
	for m in meshes:
		var mi: MeshInstance3D = m[0]
		var ml: int = m[1]
		if ml < 0:
			continue
		if ml > li or (mode == "solo" and ml != li):
			mi.visible = false
			continue
		mi.visible = true
		if ml < li:
			mi.material_override = _key_mat
		elif mode == "team":
			mi.material_override = _white_mat if m[2] else _black_mat
		else:
			mi.material_override = null
			var toon: Array = m[3]
			for s in toon.size():
				mi.set_surface_override_material(s, toon[s])
	# 遮擋物：solo 模式藏起來，其他模式顯示
	for h in holdouts:
		(h["rig"] as Node3D).visible = mode != "solo"


func _capture() -> Image:
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	_captures += 1
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img


## 把超取樣的渲染結果縮成一格像素圖：面積平均 → 透明度門檻 → 顏色量化 → 外框。
## 洋紅色像素是遮擋物，算成「被擋住」而不是顏色。
## silhouette：本層完整輪廓（不含遮擋），用來判斷外框要不要畫：
##   本層被別的東西擋住的交界不畫框，本層壓在別的東西前面的交界要畫框。
func _reduce(img: Image, fw: int, fh: int, ss: int, post: Dictionary, silhouette: PackedByteArray, ignore_key: bool) -> Dictionary:
	var W := img.get_width()
	var H := img.get_height()
	var src := img.get_data()
	var n := fw * fh
	var acc_r := PackedFloat32Array(); acc_r.resize(n)
	var acc_g := PackedFloat32Array(); acc_g.resize(n)
	var acc_b := PackedFloat32Array(); acc_b.resize(n)
	var acc_a := PackedFloat32Array(); acc_a.resize(n)
	var acc_k := PackedFloat32Array(); acc_k.resize(n)
	var rows_per := PackedInt32Array(); rows_per.resize(fh)
	for y in H:
		var oy := (y * fh) / H
		rows_per[oy] += 1
		var base := y * W * 4
		var obase := oy * fw
		for x in W:
			var i := base + x * 4
			var a := src[i + 3]
			if a == 0:
				continue
			var r := src[i]
			var g := src[i + 1]
			var b := src[i + 2]
			var o := obase + x / ss
			if r > 248 and g < 8 and b > 248:
				acc_k[o] += 1.0
				if not ignore_key:
					continue
			acc_r[o] += r * a
			acc_g[o] += g * a
			acc_b[o] += b * a
			acc_a[o] += a
	var out := PackedByteArray(); out.resize(n * 4)
	var opaque := PackedByteArray(); opaque.resize(n)
	var keyc := PackedFloat32Array(); keyc.resize(n)
	var thr: float = post["alpha_threshold"]
	var levels: int = post["color_levels"]
	var step := 255.0 / float(maxi(1, levels - 1))
	for oy in fh:
		var cnt := float(rows_per[oy] * ss) * 255.0
		for ox in fw:
			var o := oy * fw + ox
			keyc[o] = acc_k[o] * 255.0 / maxf(1.0, cnt)
			if acc_a[o] / maxf(1.0, cnt) < thr:
				continue
			var inv := 1.0 / acc_a[o]
			var cr := acc_r[o] * inv
			var cg := acc_g[o] * inv
			var cb := acc_b[o] * inv
			if levels > 1:
				cr = roundf(cr / step) * step
				cg = roundf(cg / step) * step
				cb = roundf(cb / step) * step
			out[o * 4] = clampi(int(cr), 0, 255)
			out[o * 4 + 1] = clampi(int(cg), 0, 255)
			out[o * 4 + 2] = clampi(int(cb), 0, 255)
			out[o * 4 + 3] = 255
			opaque[o] = 1
	if post["outline"] and not ignore_key:
		var dk: float = post["outline_darken"]
		var add := PackedInt32Array()
		for oy in fh:
			for ox in fw:
				var o := oy * fw + ox
				if opaque[o] == 1:
					continue
				# 本層自己的輪廓內（只是被擋住）→ 不畫框
				if silhouette.size() == n and silhouette[o] == 1:
					continue
				var best := -1
				var best_l := 999.0
				for d in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
					var nx: int = ox + d[0]
					var ny: int = oy + d[1]
					if nx < 0 or ny < 0 or nx >= fw or ny >= fh:
						continue
					var q := ny * fw + nx
					if opaque[q] == 1:
						var l := out[q * 4] * 0.3 + out[q * 4 + 1] * 0.59 + out[q * 4 + 2] * 0.11
						if l < best_l:
							best_l = l
							best = q
				if best >= 0:
					add.append(o)
					add.append(best)
		for k in range(0, add.size(), 2):
			var o := add[k]
			var q := add[k + 1]
			out[o * 4] = int(out[q * 4] * dk)
			out[o * 4 + 1] = int(out[q * 4 + 1] * dk)
			out[o * 4 + 2] = int(out[q * 4 + 2] * dk * 1.15)
			out[o * 4 + 3] = 255
	return {"image": Image.create_from_data(fw, fh, false, Image.FORMAT_RGBA8, out), "opaque": opaque, "key": keyc}


## 陣營色遮罩：本層零件白色 = 可換色，黑色 = 原色；只在顏色層不透明的像素上有效
func _team_mask(img: Image, fw: int, fh: int, ss: int, opaque: PackedByteArray) -> Image:
	var W := img.get_width()
	var H := img.get_height()
	var src := img.get_data()
	var n := fw * fh
	var lum := PackedFloat32Array(); lum.resize(n)
	var cov := PackedFloat32Array(); cov.resize(n)
	for y in H:
		var oy := (y * fh) / H
		var base := y * W * 4
		for x in W:
			var i := base + x * 4
			if src[i + 3] == 0:
				continue
			var r := src[i]
			var g := src[i + 1]
			var b := src[i + 2]
			if r > 248 and g < 8 and b > 248:
				continue
			var o := oy * fw + x / ss
			cov[o] += 1.0
			lum[o] += g
	var out := PackedByteArray(); out.resize(n)
	for o in n:
		if opaque[o] == 1 and cov[o] > 0.0 and lum[o] / cov[o] > 127.0:
			out[o] = 255
	return Image.create_from_data(fw, fh, false, Image.FORMAT_L8, out)


func _save_preview(abs_dir: String, sheets: Array[Image], team_sheets: Array, layers: Array) -> void:
	var w := sheets[0].get_width()
	var h := sheets[0].get_height()
	var pv := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	pv.fill(Color(0.80, 0.78, 0.70))
	for li in sheets.size():
		if not bool(layers[li].get("default_visible", true)):
			continue
		var img: Image = sheets[li].duplicate()
		if team_sheets[li] != null:
			var mask: Image = team_sheets[li]
			for y in h:
				for x in w:
					if mask.get_pixel(x, y).r > 0.5:
						var c := img.get_pixel(x, y)
						img.set_pixel(x, y, Color(c.r * PREVIEW_TINT.r, c.g * PREVIEW_TINT.g, c.b * PREVIEW_TINT.b, c.a))
		pv.blend_rect(img, Rect2i(0, 0, w, h), Vector2i.ZERO)
	pv.save_png(abs_dir.path_join("preview.png"))
