class_name CombatFX
extends Node3D
## 揮擊與命中的「手感」回饋：全部是畫面／聲音，判定邏輯完全不依賴這裡。
## 拿掉這個節點，戰鬥結果不會有任何改變。
##
## - 刀光拖尾：每幀沿著揮擊弧線取樣，畫成淡出的帶狀網格
## - 命中停頓（hit stop）：短暫把 Engine.time_scale 降低，擊殺停更久
## - 鏡頭微震、火花粒子、傷害數字、佔位音效（揮空、命中、擊殺）
## 數值都 export，方便邊玩邊調。

@export var hitstop_hit := 0.055        # 秒（真實時間）
@export var hitstop_kill := 0.10
@export var hitstop_scale := 0.05
@export var shake_hit := 0.35
@export var shake_kill := 0.55
@export var shake_damaged := 0.25
@export var trail_length := 0.55        # 拖尾覆蓋的揮擊進度長度（0..1）
@export var trail_samples := 18

@export var shake_trample := 0.5
@export var clash_max_per_sec := 10.0   # 士兵交戰聲的上限，避免大軍時變成噪音牆

var player: PlayerController
var cam_rig: OrbitFollowCamera
var battle: BattleManager

var _trail := ImmediateMesh.new()
var _trail_mi: MeshInstance3D
var _trail_fade := 0.0
var _last_t := -1.0
var _hitstop_left := 0.0
var _sparks: Array[CPUParticles3D] = []
var _spark_i := 0
var _audio: Array[AudioStreamPlayer] = []
var _audio_i := 0
var _numbers: Array = []                # [Label3D, 剩餘秒數, 起點]
var _audio3d: Array[AudioStreamPlayer3D] = []
var _audio3d_i := 0
var _clash_budget := 0.0
var _vignette: ColorRect
var _vignette_a := 0.0


func setup(p_player: PlayerController, p_cam: OrbitFollowCamera, p_battle: BattleManager = null) -> void:
	player = p_player
	cam_rig = p_cam
	battle = p_battle
	if battle:
		battle.soldier_struck.connect(_on_soldier_struck)
		battle.trampled.connect(_on_trampled)
		battle.arrow_fired.connect(func(pt: Vector3): _play3d(pt, PlaceholderAudio.bow(), randf_range(0.9, 1.15), -12.0))
		battle.arrow_hit.connect(func(pt: Vector3, on_unit: bool): _play3d(pt, PlaceholderAudio.thunk(), randf_range(0.9, 1.2) * (1.0 if on_unit else 1.3), -8.0 if on_unit else -16.0))
		battle.cavalry_impact.connect(_on_cavalry_impact)
	player.swing_started.connect(_on_swing_started)
	player.hit_detail.connect(_on_hit)
	player.damaged.connect(_on_damaged)


func _ready() -> void:
	_trail_mi = MeshInstance3D.new()
	_trail_mi.name = "WeaponTrail"
	_trail_mi.mesh = _trail
	_trail_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	_trail_mi.material_override = mat
	add_child(_trail_mi)
	_build_vignette()
	for i in 8:
		_sparks.append(_make_sparks())
	for i in 6:
		var a := AudioStreamPlayer.new()
		a.bus = "Master"
		add_child(a)
		_audio.append(a)
	for i in 16:
		var a3 := AudioStreamPlayer3D.new()
		a3.unit_size = 8.0
		a3.max_distance = 60.0
		a3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(a3)
		_audio3d.append(a3)


# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var real_dt := delta / maxf(Engine.time_scale, 0.001)
	_update_hitstop(real_dt)
	_update_trail(real_dt)
	_update_numbers(real_dt)
	_clash_budget = minf(_clash_budget + real_dt * clash_max_per_sec, 3.0)
	_vignette_a = maxf(0.0, _vignette_a - real_dt * 2.2)
	if _vignette:
		_vignette.visible = _vignette_a > 0.001
		(_vignette.material as ShaderMaterial).set_shader_parameter("strength", _vignette_a)


func _update_hitstop(real_dt: float) -> void:
	if _hitstop_left > 0.0:
		_hitstop_left -= real_dt
		if _hitstop_left <= 0.0:
			Engine.time_scale = 1.0


func _hitstop(seconds: float) -> void:
	_hitstop_left = maxf(_hitstop_left, seconds)
	Engine.time_scale = hitstop_scale


func _update_trail(real_dt: float) -> void:
	_trail.clear_surfaces()
	if player == null:
		return
	var t := player.swing_progress()
	if t >= 0.0:
		_last_t = t
		_trail_fade = 1.0
	elif _trail_fade > 0.0:
		_trail_fade = maxf(0.0, _trail_fade - real_dt * 6.0)
	if _trail_fade <= 0.0 or _last_t < 0.0:
		return
	var head := _last_t
	var tail := maxf(0.0, head - trail_length)
	if head - tail < 0.01:
		return
	_trail.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for k in trail_samples + 1:
		var u := float(k) / trail_samples          # 0 = 尾端，1 = 刀尖目前位置
		var g: Array = player.blade_at(lerpf(tail, head, u))
		var hilt: Vector3 = g[0]
		var tip: Vector3 = g[1]
		var inner := hilt.lerp(tip, 0.45)
		var a := u * u * _trail_fade
		_trail.surface_set_color(Color(1.0, 0.95, 0.75, a * 0.9))
		_trail.surface_add_vertex(tip)
		_trail.surface_set_color(Color(0.6, 0.75, 1.0, 0.0))
		_trail.surface_add_vertex(inner)
	_trail.surface_end()


func _update_numbers(real_dt: float) -> void:
	for i in range(_numbers.size() - 1, -1, -1):
		var e: Array = _numbers[i]
		var lbl: Label3D = e[0]
		e[1] -= real_dt
		var life: float = e[1]
		if life <= 0.0:
			lbl.queue_free()
			_numbers.remove_at(i)
			continue
		var k := 1.0 - life / 0.8
		lbl.global_position = (e[2] as Vector3) + Vector3(0, 0.3 + k * 1.1, 0)
		lbl.modulate.a = clampf(life / 0.3, 0.0, 1.0)
		lbl.outline_modulate.a = lbl.modulate.a


# ---------------------------------------------------------------------------
func _on_swing_started(mounted: bool) -> void:
	_play(PlaceholderAudio.whoosh(), randf_range(0.9, 1.15) * (0.85 if mounted else 1.0), -6.0)


func _on_hit(point: Vector3, damage: float, killed: bool, closing: float) -> void:
	var strength := clampf(closing / 13.0, 0.0, 1.0)
	_hitstop((hitstop_kill if killed else hitstop_hit) * (1.0 + strength * 0.5))
	if cam_rig:
		cam_rig.add_shake((shake_kill if killed else shake_hit) * (0.7 + strength * 0.6))
	_burst(point, killed)
	_spawn_number(point, damage, killed)
	if killed:
		_play(PlaceholderAudio.kill(), randf_range(0.9, 1.05), 0.0)
	else:
		_play(PlaceholderAudio.hit(), randf_range(0.95, 1.2), -2.0)


func _on_trampled(point: Vector3, speed: float, killed: bool) -> void:
	var strength := clampf(speed / 13.0, 0.0, 1.0)
	_hitstop(hitstop_hit * (0.8 + strength))
	if cam_rig:
		cam_rig.add_shake(shake_trample * (0.6 + strength * 0.6))
	_burst(point, true)
	_play(PlaceholderAudio.impact(), randf_range(0.9, 1.1), 0.0)
	if killed:
		_spawn_number(point, 0.0, true)


func _on_soldier_struck(point: Vector3, landed: bool) -> void:
	_play3d(point, PlaceholderAudio.hit() if landed and randf() < 0.4 else PlaceholderAudio.clang(), randf_range(0.85, 1.2), -10.0)


func _on_cavalry_impact(point: Vector3, speed: float) -> void:
	_play3d(point, PlaceholderAudio.impact(), randf_range(0.85, 1.05), -4.0, true)
	if cam_rig and player and point.distance_to(player.global_position) < 12.0:
		cam_rig.add_shake(0.15 * clampf(speed / 9.0, 0.3, 1.0))


## 3D 定位音效，共用每秒上限（important 不受上限限制）
func _play3d(point: Vector3, stream: AudioStream, pitch: float, db: float, important := false) -> void:
	if not important:
		if _clash_budget < 1.0:
			return
		_clash_budget -= 1.0
	var a := _audio3d[_audio3d_i]
	_audio3d_i = (_audio3d_i + 1) % _audio3d.size()
	a.global_position = point
	a.stream = stream
	a.pitch_scale = pitch
	a.volume_db = db
	a.play()


## 玩家受擊：鏡頭震動、短暫停頓、受傷音效、畫面邊緣泛紅、紅色傷害數字（閃紅與擊退在玩家身上）
func _on_damaged(amount: float) -> void:
	var k := clampf(amount / 15.0, 0.5, 1.5)
	if cam_rig:
		cam_rig.add_shake(shake_damaged * k + 0.1)
	_hitstop(0.035 * k)
	_play(PlaceholderAudio.hurt(), randf_range(0.92, 1.08), -1.0)
	_vignette_a = minf(1.0, _vignette_a + 0.45 * k)
	if player:
		var at := player.body_center() + Vector3(0, 0.6, 0)
		_spawn_number(at, amount, false)
		var lbl: Label3D = _numbers[-1][0]
		lbl.modulate = Color(1.0, 0.2, 0.2)
		lbl.font_size = 22


func _build_vignette() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform float strength = 0.0;
void fragment() {
	vec2 d = UV - 0.5;
	float r = length(d * vec2(1.0, 0.75)) * 2.0;
	float a = smoothstep(0.55, 1.15, r) * strength * 0.75;
	COLOR = vec4(0.75, 0.0, 0.0, a);
}"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_vignette.material = mat
	_vignette.visible = false
	layer.add_child(_vignette)


# ---------------------------------------------------------------------------
func _play(stream: AudioStream, pitch: float, db: float) -> void:
	var a := _audio[_audio_i]
	_audio_i = (_audio_i + 1) % _audio.size()
	a.stream = stream
	a.pitch_scale = pitch
	a.volume_db = db
	a.play()


func _make_sparks() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.amount = 16
	p.lifetime = 0.35
	p.explosiveness = 1.0
	p.direction = Vector3(0, 1, 0)
	p.spread = 180.0
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 6.0
	p.gravity = Vector3(0, -14, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 0.9, 0.55)
	quad.material = mat
	p.mesh = quad
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 0.85))
	grad.set_color(1, Color(1.0, 0.45, 0.15))
	p.color_ramp = grad
	add_child(p)
	return p


func _burst(at: Vector3, big: bool) -> void:
	var p := _sparks[_spark_i]
	_spark_i = (_spark_i + 1) % _sparks.size()
	p.global_position = at
	p.amount = 26 if big else 14
	p.restart()
	p.emitting = true


func _spawn_number(at: Vector3, damage: float, killed: bool) -> void:
	var l := Label3D.new()
	l.text = "擊倒！" if damage <= 0.0 else (("%d!" if killed else "%d") % int(damage))
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0012
	l.font_size = 30 if killed else 24
	l.outline_size = 8
	l.modulate = Color(1.0, 0.35, 0.25) if killed else Color(1.0, 0.92, 0.5)
	l.outline_modulate = Color(0, 0, 0)
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	add_child(l)
	l.global_position = at
	_numbers.append([l, 0.8, at])
