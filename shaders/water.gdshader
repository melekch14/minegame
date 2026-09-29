shader_type spatial;
// Tile-based water. Each 2x2 m tile is seamless because every effect is in world space.
// Depth-based colour (shallow turquoise -> deep blue), shoreline foam, gentle ripples.
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color = vec4(0.03, 0.30, 0.56, 1.0);
uniform vec4 deep_color = vec4(0.006, 0.07, 0.26, 1.0);
uniform vec4 foam_color = vec4(0.55, 0.78, 0.85, 1.0);
uniform float depth_fade = 2.6;
uniform float foam_width = 0.35;
uniform float min_alpha = 0.55;
uniform float max_alpha = 0.92;
uniform float wave_height = 0.03;
uniform float ripple_strength = 0.18;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

varying vec3 wpos;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
			   mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

float waves(vec2 p, float t) {
	return vnoise(p * 0.55 + vec2(t * 0.35, t * 0.2)) * 0.6 + vnoise(p * 1.3 - vec2(t * 0.25, -t * 0.4)) * 0.4;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += (sin(wpos.x * 0.7 + TIME * 1.1) + cos(wpos.z * 0.6 + TIME * 0.9)) * wave_height;
}

void fragment() {
	// Scene depth behind the water surface.
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	float thickness = max(-view.z - (-VERTEX.z), 0.0);
	float dk = 1.0 - exp(-thickness / depth_fade);

	// Pixel-snapped shimmer to match the voxel art direction.
	vec2 sp = floor(wpos.xz * 8.0) / 8.0;
	float wv = waves(sp, TIME);
	vec3 col = mix(shallow_color.rgb, deep_color.rgb, dk);
	col += (wv - 0.5) * 0.06;

	float foam = 1.0 - smoothstep(0.0, foam_width, thickness);
	foam *= step(0.45, vnoise(sp * 3.0 + TIME * 0.6));
	col = mix(col, foam_color.rgb, foam * 0.75);

	// Ripple normal from the wave field (world space -> view space).
	float e = 0.25;
	float hx = waves(wpos.xz + vec2(e, 0.0), TIME) - waves(wpos.xz - vec2(e, 0.0), TIME);
	float hz = waves(wpos.xz + vec2(0.0, e), TIME) - waves(wpos.xz - vec2(0.0, e), TIME);
	vec3 n_world = normalize(vec3(-hx * ripple_strength * 4.0, 1.0, -hz * ripple_strength * 4.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	ALBEDO = col;
	ALPHA = mix(min_alpha, max_alpha, dk) + foam * 0.2;
	ROUGHNESS = 0.07;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
