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


## 命中聲：低頻「咚」（下滑的正弦）＋很短的噪音「啪」。
static func hit() -> AudioStreamWAV:
	if not _cache.has("hit"):
		_cache["hit"] = _thump(0.14, 150.0, 55.0, 0.035, 0.9)
	return _cache["hit"]


## 擊殺聲：較長、較低的命中聲。
static func kill() -> AudioStreamWAV:
	if not _cache.has("kill"):
		_cache["kill"] = _thump(0.28, 110.0, 38.0, 0.06, 1.0)
	return _cache["kill"]


static func _thump(length: float, f0: float, f1: float, noise_len: float, gain: float) -> AudioStreamWAV:
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
	return _make(data)


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
