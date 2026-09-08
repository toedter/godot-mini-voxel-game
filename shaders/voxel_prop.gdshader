shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, fog_disabled;

// Same per-voxel dithering as voxel.gdshader, but for small props that move:
// a torch, or anything else carried in a hand. The terrain shader hashes on
// world position, which is fine while the geometry never moves, but a carried
// object's world position changes every frame, so that grid would slide
// across its surface instead of sitting still on it. Hashing on local
// (model-space) position instead ties the voxel grid to the mesh, so it rides
// along with the object rather than the world it is moving through.

uniform float voxel_size = 0.1;
uniform float tint_scale : hint_range(0.0, 3.0) = 1.0;

varying vec3 v_local;
varying vec3 v_local_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	v_local = VERTEX;
	// NORMAL is model space here; in fragment() it would already be view
	// space, which would offset the voxel grid depending on where the camera
	// looks.
	v_local_normal = NORMAL;
}

void fragment() {
	// Step half a voxel along the inward normal so a face samples the cube it
	// belongs to instead of landing exactly on the boundary with its neighbour.
	vec3 cell = floor((v_local - v_local_normal * (voxel_size * 0.5)) / voxel_size);
	float h = hash13(cell);
	float tint = 1.0 + (h - 0.5) * 2.0 * COLOR.a * tint_scale;
	// Vertex colours are authored in sRGB, the renderer works in linear space.
	vec3 base = pow(clamp(COLOR.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));
	ALBEDO = base * tint;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
}
