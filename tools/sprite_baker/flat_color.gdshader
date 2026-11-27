shader_type spatial;
// 單色不打光：給遮擋（holdout，洋紅色）與陣營色遮罩（白／黑）用。
render_mode unshaded, cull_back;

uniform vec4 color : source_color = vec4(1.0, 0.0, 1.0, 1.0);

void fragment() {
	ALBEDO = color.rgb;
}
