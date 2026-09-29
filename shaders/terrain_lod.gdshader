shader_type spatial;
// Merged-mesh terrain (distance LOD + far chunks). UV.x = material id (0 grass, 1 dirt,
// 2 stone, 3 sand), UV.y = 1 on the sides of grass-topped blocks (draws the grass rim).
// Ramps are filled from the same Blender material table the real blocks use
// (WorldAssetLibrary), so both representations share colours and pixel-noise style.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 ramp_cols[20];     // 4 materials x 5 stops (linear rgb)
uniform vec4 ramp_pos_a[4];     // stop positions 0..3 per material
uniform float ramp_pos_b[4];    // stop position 4 per material
uniform int ramp_count[4];
uniform float roughness_mat[4];
uniform float white_mix = 0.35;
uniform float contrast = 1.7;
uniform float snap = 0.25;       // coarser than the near blocks to avoid shimmer at distance
uniform float level_height = 2.0;
uniform float lip_height = 0.3;

varying vec3 wpos;
varying vec3 wnrm;
varying flat int mat_id;
varying float lip_flag;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
				  mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
				  mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

vec3 ramp(int m, float t) {
	int base = m * 5;
	float p[5] = float[](ramp_pos_a[m].x, ramp_pos_a[m].y, ramp_pos_a[m].z, ramp_pos_a[m].w, ramp_pos_b[m]);
	int n = ramp_count[m];
	if (t <= p[0]) return ramp_cols[base].rgb;
	vec3 col = ramp_cols[base + n - 1].rgb;
	for (int k = 1; k < 5; k++) {
		if (k >= n) break;
		if (t <= p[k]) {
			col = mix(ramp_cols[base + k - 1].rgb, ramp_cols[base + k].rgb, (t - p[k - 1]) / max(p[k] - p[k - 1], 1e-4));
			break;
		}
	}
	return col;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = NORMAL;
	mat_id = clamp(int(UV.x), 0, 3);
	lip_flag = UV.y;
}

void fragment() {
	int m = mat_id;
	// Grass rim along the top edge of grass-block sides.
	if (lip_flag > 0.5 && fract(wpos.y / level_height + 0.001) > 1.0 - lip_height / level_height) {
		m = 0;
	}
	vec3 p = wpos - wnrm * 0.01;
	vec3 pc = floor(p / snap) * snap;
	float n = vnoise(pc * 1.6) * 0.65 + vnoise(pc * 3.3 + 17.0) * 0.35;
	n = clamp((n - 0.5) * contrast + 0.5, 0.0, 1.0);
	float w = hash13(floor(p / snap) * 7.13 + 3.1);
	float t = mix(n, w, white_mix);
	ALBEDO = ramp(m, t);
	ROUGHNESS = roughness_mat[m];
	SPECULAR = 0.35;
}
