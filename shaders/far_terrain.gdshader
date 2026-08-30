shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, fog_disabled;

// The distant island.
//
// One coarse, flat shaded mesh of the entire world that lies just below the
// streamed voxel surface. It is what everything past the streamed bubble is
// made of: the chunks around the player dissolve into it a few dozen metres out
// and it carries the rest of the island, and the open sea around it, to the
// horizon.
//
// It shares voxel_common's haze, so it fades into exactly the same sky colour
// as everything else; Atmosphere gives it the same reach as the terrain, which
// opens it up as the player climbs.
//
// The same shader draws the ground and the canopy shell above it. The canopy is
// dithered away close to the eye, where the streamed chunks have real trees of
// their own; on the ground surface that band is left disabled.

#include "res://shaders/voxel_common.gdshaderinc"

// COLOR.a marks the parts of the mesh that stand in for open water. Those get
// a mirror of the sky on top of their body colour, which is most of what the
// sea is at a distance and what keeps the far water matching the sea plane
// that follows the player.
uniform float reflect_max : hint_range(0.0, 1.0) = 0.72;

// Where the canopy shell hands back over to the real trees of the streamed
// chunks. Measured from voxel_common's `eye_pos`, for the same reason the level
// handover is: the shadow pass has to drop the same crowns the colour pass
// does. Left at their defaults nothing is ever dropped, which is what the
// ground surface wants.
uniform float canopy_begin = -1.0;
uniform float canopy_end = -1.0;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// True for the part of the canopy that has been handed back to the chunks. The
// pattern is keyed to the world grid, so the holes stay put instead of crawling
// over the woods as the player moves.
bool canopy_hidden(vec3 world) {
	if (canopy_end <= canopy_begin) {
		return false;
	}
	float t = 1.0 - smoothstep(canopy_begin, canopy_end, distance(world, eye_pos));
	if (t <= 0.0) {
		return false;
	}
	if (t >= 1.0) {
		return true;
	}
	// Cells around a metre across: the crowns themselves are only a few metres
	// wide, so the holes have to be coarser than the ground dissolve to read as
	// a wood thinning out rather than as noise.
	return hash13(floor(world / max(voxel_size * 12.0, 0.001))) < t;
}

void fragment() {
	if (canopy_hidden(v_world)) {
		discard;
	}
	vec4 haze = haze_over(VERTEX, INV_VIEW_MATRIX, v_world.y);
	// Vertex colours are authored in sRGB, the renderer works in linear space.
	vec3 base = pow(clamp(COLOR.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));

	vec3 view_dir = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	vec3 n = normalize(v_world_normal);
	float facing = clamp(dot(-view_dir, n), 0.0, 1.0);
	// Schlick: the flatter the angle, the more of the sky the water returns.
	float fresnel = COLOR.a * (0.02 + (reflect_max - 0.02) * pow(1.0 - facing, 5.0));

	ALBEDO = base * (1.0 - haze.a);
	EMISSION = haze_sky(reflect(view_dir, n)) * fresnel * (1.0 - haze.a) + haze.rgb * haze.a;
	ROUGHNESS = mix(0.95, 0.2, COLOR.a);
	SPECULAR = 0.1 * (1.0 - haze.a);
}
