class_name PlaceholderAudio
extends RefCounted
## 程式合成的佔位音效（不使用任何外部音檔）。之後換成正式音效時，
## 只要讓 CombatFX 改讀 .wav/.ogg 即可。

const RATE := 22050

static var _cache: Dictionary = {}


## 揮空聲：濾波白噪音，音量先升後降，濾波頻率隨時間掃過，聽起來像「咻」。
static func whoosh() -> AudioStreamWAV:
	if not _cache.has("whoosh"):
		var n := int(RATE * 0.22)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var data := PackedFloat32Array()
		data.resize(n)
		var lp := 0.0
		for i in n:
			var t := float(i) / n
			var env := sin(t * PI) * (1.0 - t * 0.4)
			var cutoff := lerpf(0.05, 0.35, sin(t * PI))
			lp += (rng.randf_range(-1.0, 1.0) - lp) * cutoff
			data[i] = lp * env * 1.6
		_cache["whoosh"] = _make(data)
	return _cache["whoosh"]


## 砍中聲：高頻「嚓」的切割噪音＋低頻「咚」。
static func hit() -> AudioStreamWAV:
	if not _cache.has("hit"):
		var body := _thump_data(0.16, 150.0, 55.0, 0.0, 0.8)
		var slice := _noise_burst(0.07, 0.75, 3)
		_cache["hit"] = _make(_mix(body, slice, 0.8))
	return _cache["hit"]


## 金屬碰撞聲（士兵之間刀槍相擊）：幾個不成倍數的正弦快速衰減，像「鏘」。
static func clang() -> AudioStreamWAV:
	if not _cache.has("clang"):
		var n := int(RATE * 0.35)
		var data := PackedFloat32Array()
		data.resize(n)
		var partials := [[1240.0, 1.0, 9.0], [1810.0, 0.7, 12.0], [2730.0, 0.5, 16.0], [3920.0, 0.35, 22.0]]
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		for i in n:
			var t := float(i) / RATE
			var v := 0.0
			for pr in partials:
				v += sin(TAU * pr[0] * t) * pr[1] * exp(-pr[2] * t)
			if t < 0.008:
				v += rng.randf_range(-1.0, 1.0) * (1.0 - t / 0.008)
			data[i] = v * 0.35
		_cache["clang"] = _make(data)
	return _cache["clang"]


## 撞擊聲（騎馬衝撞）：很低的重擊＋粗糙的碎裂噪音。
static func impact() -> AudioStreamWAV:
	if not _cache.has("impact"):
		var body := _thump_data(0.32, 90.0, 32.0, 0.0, 1.0)
		var crunch := _noise_burst(0.12, 0.25, 9)
		_cache["impact"] = _make(_mix(body, crunch, 0.9))
	return _cache["impact"]


## 擊殺聲：較長、較低的命中聲。
static func kill() -> AudioStreamWAV:
	if not _cache.has("kill"):
		_cache["kill"] = _thump(0.28, 110.0, 38.0, 0.06, 1.0)
	return _cache["kill"]


static func _thump(length: float, f0: float, f1: float, noise_len: float, gain: float) -> AudioStreamWAV:
	return _make(_thump_data(length, f0, f1, noise_len, gain))


## 短噪音爆裂；brightness 越高越尖（一階濾波係數）。
static func _noise_burst(length: float, brightness: float, seed_v: int) -> PackedFloat32Array:
	var n := int(RATE * length)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var data := PackedFloat32Array()
	data.resize(n)
	var lp := 0.0
	var prev := 0.0
	for i in n:
		var k := float(i) / n
		lp += (rng.randf_range(-1.0, 1.0) - lp) * brightness
		var hp := lp - prev * 0.6
		prev = lp
		data[i] = hp * pow(1.0 - k, 2.0)
	return data


static func _mix(a: PackedFloat32Array, b: PackedFloat32Array, b_gain: float) -> PackedFloat32Array:
	var out := a.duplicate()
	if b.size() > out.size():
		out.resize(b.size())
	for i in b.size():
		out[i] = clampf(out[i] + b[i] * b_gain, -1.0, 1.0)
	return out


static func _thump_data(length: float, f0: float, f1: float, noise_len: float, gain: float) -> PackedFloat32Array:
	var n := int(RATE * length)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var data := PackedFloat32Array()
	data.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var k := t / length
		var f := lerpf(f0, f1, k)
		phase += TAU * f / RATE
		var body := sin(phase) * pow(1.0 - k, 2.0)
		var crack := 0.0
		if t < noise_len:
			crack = rng.randf_range(-1.0, 1.0) * (1.0 - t / noise_len)
		data[i] = clampf((body * 0.9 + crack * 0.6) * gain, -1.0, 1.0)
	return data


static func _make(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	return w
