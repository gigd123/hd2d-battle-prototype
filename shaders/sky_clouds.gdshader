shader_type sky;
// 簡單的天空：上下漸層＋太陽＋飄動的雲（雲塊邊緣量化成幾階，配合像素風）。
// 顏色由場地設定（battlefield.gd 的 _apply_terrain_environment）。

uniform vec3 sky_top : source_color = vec3(0.38, 0.55, 0.80);
uniform vec3 sky_horizon : source_color = vec3(0.80, 0.78, 0.72);
uniform vec3 ground_color : source_color = vec3(0.62, 0.60, 0.54);
uniform vec3 cloud_color : source_color = vec3(1.0, 0.99, 0.96);
uniform vec3 cloud_shade : source_color = vec3(0.78, 0.80, 0.88);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_scale = 1.2;
uniform vec2 wind = vec2(0.006, 0.002);

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 col = mix(sky_horizon, sky_top, pow(clamp(h, 0.0, 1.0), 0.6));
	if (h < 0.0) {
		col = mix(sky_horizon * 0.95, ground_color, clamp(-h * 4.0, 0.0, 1.0));
	}
	// 太陽
	if (LIGHT0_ENABLED) {
		float sd = dot(d, LIGHT0_DIRECTION);
		col += LIGHT0_COLOR * (smoothstep(0.9990, 0.9995, sd) * 2.0 + pow(max(sd, 0.0), 64.0) * 0.25);
	}
	// 雲：把方向投影到一片高空平面上
	if (h > 0.02 && !AT_CUBEMAP_PASS) {
		vec2 uv = d.xz / (h + 0.15) * cloud_scale + TIME * wind;
		float n = fbm(uv * 3.0);
		float th = 0.72 - cloud_cover * 0.35;
		float c = smoothstep(th, th + 0.1, n);
		c = floor(c * 4.0) / 4.0;                 // 量化成幾階，像素風的硬邊
		float shade = fbm(uv * 3.0 + vec2(0.08, 0.08));
		vec3 cc = mix(cloud_color, cloud_shade, clamp((shade - n) * 4.0 + 0.4, 0.0, 1.0));
		float fade = smoothstep(0.02, 0.25, h);    // 地平線附近淡掉
		col = mix(col, cc, c * fade);
	}
	COLOR = col;
}
