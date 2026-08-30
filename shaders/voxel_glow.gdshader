shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, fog_disabled;

// Mushroom caps. They are shaded like any other voxel during the day and light
// up once it gets dark, driven by glow_amount which Atmosphere derives from the
// day/night cycle.

#include "res://shaders/voxel_common.gdshaderinc"

// Kept as a plain vec3 rather than a source_color hint so the conversion to
// linear space happens in one place in GDScript, the same way the haze colours
// are handled.
uniform vec3 glow_color = vec3(0.35, 0.08, 0.85);
// 0 in broad daylight, 1 in the middle of the night.
uniform float glow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float glow_strength : hint_range(0.0, 8.0) = 2.6;
uniform float pulse_speed : hint_range(0.0, 6.0) = 1.1;
uniform float pulse_depth : hint_range(0.0, 1.0) = 0.22;

varying float v_glow;
varying float v_phase;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// baked per voxel: how brightly this part lights up, and the phase of the
	// mushroom it belongs to
	v_glow = UV.x;
	v_phase = UV.y;
}

void fragment() {
	if (lod_hidden(v_world)) {
		discard;
	}
	vec4 haze = haze_over(VERTEX, INV_VIEW_MATRIX, v_world.y);
	vec3 base = voxel_albedo(v_world, v_world_normal, COLOR);

	float pulse = 1.0 + pulse_depth * sin(TIME * pulse_speed + v_phase * TAU);
	float lit = glow_amount * v_glow * pulse;

	// The lit parts also brighten their own albedo a little, so they do not
	// read as a dark surface with a light painted on top.
	ALBEDO = base * (1.0 + lit * 0.5) * (1.0 - haze.a);
	// Emission carries both the glow and the haze: a fully hazed fragment ends
	// up exactly sky coloured, so distant mushrooms dissolve like everything
	// else instead of staying visible as bright dots.
	EMISSION = (glow_color * glow_strength * lit) * (1.0 - haze.a) + haze.rgb * haze.a;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1 * (1.0 - haze.a);
}
