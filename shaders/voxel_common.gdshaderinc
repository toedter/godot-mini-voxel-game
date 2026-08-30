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

// Distance haze.
//
// The Environment's own fog fades everything towards a single flat colour, so
// anything that sticks out above the horizon ends up as a pale silhouette
// against the blue sky and pops into view the moment its chunk streams in.
// This fog instead fades towards the colour of the sky in the direction the
// fragment is seen, so distant geometry dissolves into whatever is behind it.
// Atmosphere.gd keeps these uniforms in sync with the sky material.

uniform vec3 haze_horizon = vec3(0.7, 0.8, 0.92);
uniform vec3 haze_top = vec3(0.25, 0.48, 0.9);
uniform vec3 haze_ground = vec3(0.7, 0.8, 0.92);
uniform float haze_sky_curve = 0.5;
uniform float haze_begin = 12.0;
uniform float haze_end = 34.4;
uniform float haze_curve = 1.6;
// The mist lies on the ground: above `mist_top` the air thins out over
// `mist_depth` metres, down to `mist_floor` of its density at the bottom. This
// is what lets a mountain be seen from right across the island while the plain
// it stands on still fades out after a few dozen metres.
uniform float mist_top = 44.0;
uniform float mist_depth = 24.0;
uniform float mist_floor : hint_range(0.02, 1.0) = 0.10;

// Handover between levels of detail.
//
// Chunks are streamed at several voxel sizes: 10 cm close to the player, then
// 20, 40, 80 cm further out, and finally the coarse mesh of the whole island.
// Where two levels meet they are both drawn across a band and dither into one
// another.
//
// The trick that makes the switch hard to catch is that the two sides are
// exactly complementary. Both work out the same `t` from the same distance and
// hash the same world cell, and then the finer level drops precisely the cells
// the coarser one keeps. So no sky is ever visible through the band: every hole
// one level opens is already filled by the other level's voxels, and what you
// see is one resolution handing over to another rather than a rim of holes.
//
// Distance is measured from `eye_pos` rather than from the fragment's view
// space depth, so the shadow pass, which renders from the light, drops the same
// voxels as the colour pass instead of casting the shadows of geometry that was
// never drawn.
uniform vec3 eye_pos = vec3(0.0);

// The band this level fades IN over, where it is the coarser of the pair, and
// the band it fades OUT over, where it is the finer one. `cell` is the size of
// the hash cell and has to match on both sides of a band. A band with
// end <= begin is switched off, which is what the innermost level wants below
// and the outermost above.
uniform float fade_in_begin = -1.0;
uniform float fade_in_end = -1.0;
uniform float fade_in_cell = 0.4;
uniform float fade_out_begin = -1.0;
uniform float fade_out_end = -1.0;
uniform float fade_out_cell = 0.4;

// True when this fragment belongs to a cell that a neighbouring level is
// drawing instead.
bool lod_hidden(vec3 world) {
	float d = distance(world, eye_pos);
	if (fade_out_end > fade_out_begin) {
		float t = smoothstep(fade_out_begin, fade_out_end, d);
		if (t >= 1.0) {
			return true;
		}
		// The finer side gives up the cells the coarser one has taken over.
		if (t > 0.0 && hash13(floor(world / max(fade_out_cell, 0.001))) < t) {
			return true;
		}
	}
	if (fade_in_end > fade_in_begin) {
		float t = smoothstep(fade_in_begin, fade_in_end, d);
		if (t <= 0.0) {
			return true;
		}
		// The coarser side takes only the cells the finer one has given up.
		if (t < 1.0 && hash13(floor(world / max(fade_in_cell, 0.001))) >= t) {
			return true;
		}
	}
	return false;
}

// Same gradient as the ProceduralSkyMaterial of the WorldEnvironment.
vec3 haze_sky(vec3 dir) {
	float up = clamp(dir.y, -1.0, 1.0);
	if (up <= 0.0) {
		return haze_ground;
	}
	float c = 1.0 - acos(up) / (PI * 0.5);
	float t = clamp(1.0 - pow(1.0 - c, 1.0 / haze_sky_curve), 0.0, 1.0);
	return mix(haze_horizon, haze_top, t);
}

// Returns the haze colour in rgb and how much of it covers the fragment in a.
// `world_y` is the height the fragment sits at, which decides how thick the
// air between it and the eye is.
vec4 haze_over(vec3 view_pos, mat4 inv_view, float world_y) {
	float thickness = clamp(
		exp(-max(world_y - mist_top, 0.0) / max(mist_depth, 0.001)), mist_floor, 1.0);
	float a = pow(smoothstep(haze_begin, haze_end, length(view_pos) * thickness), haze_curve);
	vec3 dir = normalize((inv_view * vec4(view_pos, 0.0)).xyz);
	return vec4(haze_sky(dir), a);
}
