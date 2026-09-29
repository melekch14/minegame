shader_type spatial;
// Recreates the player's Blender node materials: object position -> +0.014 -> snapped to a
// small grid -> 3D white noise -> mix between two colours.
// tools/blender/export_player.py baked each vertex's REST object position into the UVs
// (UV = x,y  UV2.x = z, in Blender units), so the pattern stays glued to skinned meshes
// while they animate instead of swimming through them.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Linear colours straight from the .blend (not source_color: they are already linear).
uniform vec3 color_a = vec3(0.8);
uniform vec3 color_b = vec3(0.7);
uniform float snap_size = 0.1;
uniform float roughness_value = 0.6;
uniform float metallic_value = 0.0;

varying vec3 v_rest;

void vertex() {
	// glTF flips V on export: undo it to get Blender's Y back.
	v_rest = vec3(UV.x, 1.0 - UV.y, UV2.x);
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	vec3 cell = floor((v_rest + 0.014) / snap_size);
	ALBEDO = mix(color_a, color_b, hash13(cell * 7.13 + 3.1));
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	SPECULAR = 0.4;
}
