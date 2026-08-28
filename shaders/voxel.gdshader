shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, fog_disabled;

#include "res://shaders/voxel_common.gdshaderinc"

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// NORMAL is model space here; in fragment() it would already be view space,
	// which would offset the voxel grid depending on where the camera looks.
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Scaling the albedo down and adding the haze as emission means the haze is
	// not affected by lighting: a fully hazed fragment is exactly sky coloured
	// no matter whether it sits in sunlight or in shadow.
	vec4 haze = haze_over(VERTEX, INV_VIEW_MATRIX);
	ALBEDO = voxel_albedo(v_world, v_world_normal, COLOR) * (1.0 - haze.a);
	EMISSION = haze.rgb * haze.a;
	ROUGHNESS = 0.95;
	SPECULAR = 0.1 * (1.0 - haze.a);
}
