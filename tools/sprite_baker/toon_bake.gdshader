shader_type spatial;
// 烘焙用的分階明暗（cel shading）：光源固定在鏡頭座標系，所以 8 個方向的受光一致，
// 像素圖看起來像同一個畫師畫的。不吃場景燈光，輸出顏色完全可預測。
render_mode unshaded, cull_back;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_nearest, hint_default_white;
uniform vec3 light_dir_view = vec3(-0.45, 0.65, 0.62);   // 鏡頭座標：左上前方打光
uniform float shade_mid = 0.80;      // 中間調亮度
uniform float shade_dark = 0.58;     // 陰影亮度
uniform float band_hi = 0.45;        // N·L 高於此值 = 亮面
uniform float band_lo = 0.0;         // N·L 低於此值 = 陰影
uniform vec3 shadow_tint = vec3(0.86, 0.88, 1.0);  // 陰影偏冷色，像素畫常見手法

void fragment() {
	vec3 base = albedo.rgb * texture(albedo_tex, UV).rgb;
	float nl = dot(normalize(NORMAL), normalize(light_dir_view));
	vec3 c;
	if (nl > band_hi) {
		c = base;
	} else if (nl > band_lo) {
		c = base * shade_mid;
	} else {
		c = base * shade_dark * shadow_tint;
	}
	ALBEDO = c;
}
