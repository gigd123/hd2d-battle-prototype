// 士兵 MultiMesh 用的 Y 軸 Billboard 著色器。
// 每個實例：transform 的位移 = 腳底位置；INSTANCE_CUSTOM.x = 幀編號（列*8+欄）、.y = 是否水平翻轉；
// COLOR = 陣營色（含受擊閃白）。整群士兵只需 1 次 draw call。
shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;

uniform sampler2D atlas : source_color, filter_nearest;
uniform vec2 grid = vec2(8.0, 4.0);
// false = Y 軸 Billboard（直立紙片，畫面邊緣會有透視傾斜）；true = 完全面向相機（畫面上永遠直立）
uniform bool full_billboard = false;

varying vec4 v_color;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 world;
	if (full_billboard) {
		world = origin + INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y;
	} else {
		vec3 cam_right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
		world = origin + cam_right * VERTEX.x + vec3(0.0, VERTEX.y, 0.0);
	}
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
	float frame = INSTANCE_CUSTOM.x;
	vec2 uv = UV;
	if (INSTANCE_CUSTOM.y > 0.5) {
		uv.x = 1.0 - uv.x;
	}
	float col = mod(frame, grid.x);
	float row = floor(frame / grid.x + 0.001);
	UV = (vec2(col, row) + uv) / grid;
	// 實例顏色以 sRGB 給定（與 Sprite3D.modulate 一致），轉成線性空間
	v_color = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
}

void fragment() {
	vec4 tex = texture(atlas, UV);
	if (tex.a < 0.5) {
		discard;
	}
	ALBEDO = tex.rgb * v_color.rgb;
}
