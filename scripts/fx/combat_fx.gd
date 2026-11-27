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

var player: PlayerController
var cam_rig: OrbitFollowCamera

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


func setup(p_player: PlayerController, p_cam: OrbitFollowCamera) -> void:
	player = p_player
	cam_rig = p_cam
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
	for i in 8:
		_sparks.append(_make_sparks())
	for i in 6:
		var a := AudioStreamPlayer.new()
		a.bus = "Master"
		add_child(a)
		_audio.append(a)


# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var real_dt := delta / maxf(Engine.time_scale, 0.001)
	_update_hitstop(real_dt)
	_update_trail(real_dt)
	_update_numbers(real_dt)


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


func _on_damaged(_amount: float) -> void:
	if cam_rig:
		cam_rig.add_shake(shake_damaged)


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
	l.text = ("%d!" if killed else "%d") % int(damage)
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
