shader_type spatial;
// Recreates the Blender "voxel" node materials for a whole asset in ONE surface.
// The exporter merged each asset's Blender materials into a single slot and wrote the
// original material index into UV.x; this shader picks that material's ramp and noise
// settings. Per material: object-space position snapped to a coarse and a fine grid ->
// smooth noise mixed with white noise -> colour ramp (linear colours from the .blend).
// Per-instance variation comes from the instance origin.
// Baked mode (low-poly terrain blocks, tools/blender/bake_blocks.py): the material index and
// the surface normal come per texel from textures baked off the detailed block instead.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

const int MAX_MATS = 6;

uniform vec4 ramp_cols[30];        // MAX_MATS x 5 stops
uniform vec4 ramp_pos_a[6];        // stop positions 0..3
uniform float ramp_pos_b[6];       // stop position 4
uniform int ramp_count[6];
uniform float noise_scale[6];
uniform float snap_coarse[6];
uniform float snap_fine[6];
uniform float white_mix[6];
uniform float roughness_mat[6];
uniform float contrast = 1.7;

uniform bool baked = false;
uniform sampler2D baked_normal : hint_default_white, filter_linear_mipmap, repeat_disable;  // object-space normal
uniform sampler2D baked_mat_ao : hint_default_white, filter_nearest, repeat_disable;       // R = (id + 0.5) / 8, G = AO
uniform float baked_ao_light_affect = 0.5;

varying vec3 v_local;
varying vec3 v_nrm;
varying vec3 v_seed;
varying flat int v_mat;

void vertex() {
	v_local = VERTEX;
	v_nrm = NORMAL;
	v_seed = MODEL_MATRIX[3].xyz;
	v_mat = clamp(int(UV.x), 0, MAX_MATS - 1);
}

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

void fragment() {
	int m = v_mat;
	if (baked) {
		vec2 mat_ao = texture(baked_mat_ao, UV).rg;
		m = clamp(int(mat_ao.r * 8.0), 0, MAX_MATS - 1);
		vec3 n = texture(baked_normal, UV).rgb * 2.0 - 1.0;
		NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
		AO = mat_ao.g;
		AO_LIGHT_AFFECT = baked_ao_light_affect;
	}
	// Nudge inward so faces lying exactly on a snap boundary don't flicker.
	vec3 p = v_local - v_nrm * 0.01 + fract(v_seed * 0.1371) * 13.0;
	float sc = snap_coarse[m];
	float sf = snap_fine[m];
	vec3 pc = floor(p / sc) * sc;
	float n = vnoise(pc * noise_scale[m]) * 0.65 + vnoise(pc * noise_scale[m] * 2.07 + 17.0) * 0.35;
	n = clamp((n - 0.5) * contrast + 0.5, 0.0, 1.0);
	vec3 pf = floor(p / sf) * sf;
	float w = hash13(pf * 7.13 + 3.1);
	ALBEDO = ramp(m, mix(n, w, white_mix[m]));
	ROUGHNESS = roughness_mat[m];
	SPECULAR = 0.35;
}
