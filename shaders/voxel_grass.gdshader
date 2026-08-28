shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, fog_disabled;

// Grass tufts. Identical shading to voxel.gdshader, but every voxel is pushed
// sideways by a travelling wind wave so the grass sways.
//
// UV carries the sway data baked by ChunkBuilder:
//   UV.x = stiffness factor, 0 at the ground and 1 at the tip of the tuft
//   UV.y = random phase per tuft, so neighbouring tufts do not move in lockstep
//
// The whole voxel shares one UV, so each 10 cm cube is translated rigidly and
// stays a cube; only the steps between stacked voxels bend.

#include "res://shaders/voxel_common.gdshaderinc"

uniform vec2 wind_dir = vec2(1.0, 0.35);
// Peak horizontal displacement of the tip of a tuft, in metres.
uniform float wind_strength : hint_range(0.0, 0.2) = 0.035;
uniform float wind_speed = 1.9;
// How quickly the wave travels across the world (1 / wavelength in metres).
uniform float wind_wavelength = 0.55;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The hash grid must follow the voxel's rest position, otherwise the tint
	// of a blade would flicker as it crosses a cell boundary while swaying.
	v_world = world;
	// NORMAL is model space here; in fragment() it would already be view space,
	// which would offset the voxel grid depending on where the camera looks.
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);

	vec2 dir = normalize(wind_dir);
	float travel = dot(world.xz, dir) * wind_wavelength;
	float phase = UV.y * 6.2831853;
	float wave = sin(TIME * wind_speed + travel + phase);
	// A slow second wave makes the wind come in gusts instead of ticking along
	// at one constant rate.
	float gust = 0.6 + 0.4 * sin(TIME * 0.31 + travel * 0.22 + phase * 0.5);
	float bend = UV.x * UV.x * wind_strength * wave * gust;
	// Chunks are only ever translated, never rotated, so a world space offset
	// can be added to the model space vertex directly.
	VERTEX.xz += dir * bend;
}

void fragment() {
	vec4 haze = haze_over(VERTEX, INV_VIEW_MATRIX);
	ALBEDO = voxel_albedo(v_world, v_world_normal, COLOR) * (1.0 - haze.a);
	EMISSION = haze.rgb * haze.a;
	ROUGHNESS = 0.95;
	SPECULAR = 0.1 * (1.0 - haze.a);
}
