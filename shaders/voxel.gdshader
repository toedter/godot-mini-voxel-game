shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Per-voxel shading: every 10 cm cube gets a deterministic brightness offset so
// that large greedy-merged quads still read as individual voxels.

uniform float voxel_size = 0.1;
// Global multiplier on the per-material tint strength stored in COLOR.a.
uniform float tint_scale : hint_range(0.0, 3.0) = 1.0;

varying vec3 v_world;
varying vec3 v_world_normal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// NORMAL is model space here; in fragment() it would already be view space,
	// which would offset the voxel grid depending on where the camera looks.
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	// Step half a voxel along the inward normal so a face samples the cube it
	// belongs to instead of landing exactly on the boundary with its neighbour.
	vec3 cell = floor((v_world - v_world_normal * (voxel_size * 0.5)) / voxel_size);
	float h = hash13(cell);
	float tint = 1.0 + (h - 0.5) * 2.0 * COLOR.a * tint_scale;
	// Vertex colours are authored in sRGB, the renderer works in linear space.
	vec3 base = pow(clamp(COLOR.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));
	ALBEDO = base * tint;
	ROUGHNESS = 0.95;
	SPECULAR = 0.1;
}
