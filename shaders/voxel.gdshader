shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/voxel_common.gdshaderinc"

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// NORMAL is model space here; in fragment() it would already be view space,
	// which would offset the voxel grid depending on where the camera looks.
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = voxel_albedo(v_world, v_world_normal, COLOR);
	ROUGHNESS = 0.95;
	SPECULAR = 0.1;
}
