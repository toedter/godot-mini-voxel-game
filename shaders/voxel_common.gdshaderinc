// Shared per-voxel shading. Every 10 cm cube gets a deterministic brightness
// offset so that large greedy-merged quads still read as individual voxels.

uniform float voxel_size = 0.1;
// Global multiplier on the per-material tint strength stored in COLOR.a.
uniform float tint_scale : hint_range(0.0, 3.0) = 1.0;

varying vec3 v_world;
varying vec3 v_world_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

vec3 voxel_albedo(vec3 world, vec3 world_normal, vec4 color) {
	// Step half a voxel along the inward normal so a face samples the cube it
	// belongs to instead of landing exactly on the boundary with its neighbour.
	vec3 cell = floor((world - world_normal * (voxel_size * 0.5)) / voxel_size);
	float h = hash13(cell);
	float tint = 1.0 + (h - 0.5) * 2.0 * color.a * tint_scale;
	// Vertex colours are authored in sRGB, the renderer works in linear space.
	vec3 base = pow(clamp(color.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));
	return base * tint;
}
