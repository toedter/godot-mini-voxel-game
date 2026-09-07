shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, fog_disabled;

// The distant island.
//
// One coarse, flat shaded mesh of the entire world that lies just below the
// streamed voxel surface. It is what everything past the streamed bubble is
// made of, and it carries the island, and the open sea around it, to the
// horizon.
//
// It shares voxel_common's haze, so it fades into exactly the same sky colour
// as everything else and, at the distance the chunks end, is just as thoroughly
// hidden by the mist as they are. What it is there for is the parts of the
// world that stand out of the mist: from a summit the peaks across the island
// rise out of it, and this is what they are made of.
//
// The same shader draws the ground and the canopy shell above it. The canopy is
// dithered away close to the eye, where the streamed chunks have real trees of
// their own; on the ground surface that band is left disabled.
//
// The mesh carries the sea bed, not the sea. Everything the tide touches is
// done here from `sea_y`: the ocean surface is floated onto the bed, the water
// is coloured by how deep it is, and woods that the water has risen over are
// drowned. That is what lets the tide move the painted sea in the same frame it
// moves the sea plane, instead of waiting on a repaint of a mesh this size.

#include "res://shaders/voxel_common.gdshaderinc"

// Water deep enough to hide its bed gets a mirror of the sky on top of its body
// colour, which is most of what the sea is at a distance and what keeps the far
// water matching the sea plane that follows the player.
uniform float reflect_max : hint_range(0.0, 1.0) = 0.72;

group_uniforms tide;
// World Y the water stands at. VoxelWorld pushes this every frame, so it is
// always the level the sea plane is at too.
uniform float sea_y = 18.0;
// How far under the surface the painted ocean settles once the water is deep
// enough to be opaque, and the depth range it eases onto that level over.
// FarTerrain owns these values and the rule that binds shelf_end to the depth
// at which it folds a block away; see SEA_SHELF there.
uniform float sea_shelf = 4.0;
uniform float shelf_begin = 2.0;
uniform float shelf_end = 6.0;

group_uniforms water;
// Body colour of the far sea. Matches water.gdshader, so the plane around the
// player and the painted sea beyond it read as one body of water.
uniform vec3 shallow_color : source_color = vec3(0.10, 0.44, 0.44);
uniform vec3 deep_color : source_color = vec3(0.01, 0.09, 0.19);
uniform float depth_fade : hint_range(0.5, 20.0) = 3.2;

group_uniforms;

// Set on the canopy material only. The shell floats above the ground rather
// than lying on it, so it wants neither the ocean lift nor the water colour -
// what it wants is to disappear when the tide closes over the wood it stands
// in.
uniform bool is_canopy = false;

// World Y of the ground under this fragment: the bed the sea lies on, which for
// the canopy is several metres below the vertex itself. Carried in UV.x because
// the vertex has been moved by the time anything downstream could work it out.
varying float v_ground;

// Where the canopy shell hands back over to the real trees of the streamed
// chunks. Measured from voxel_common's `eye_pos` rather than from the depth of
// the fragment, so that the shadow pass drops the same crowns the colour pass
// does. Left at their defaults nothing is ever dropped, which is what the
// ground surface wants.
//
// VoxelWorld puts this band at the outer edge of the streamed disc, which out
// on the plain is deep inside the mist and never seen.
uniform float canopy_begin = -1.0;
uniform float canopy_end = -1.0;

// How much of the ocean surface, rather than of the bed, is drawn at a given
// depth of water. 0 in the shallows, where the sea plane draws the surface and
// the bed below it is meant to show through; 1 once the water is deep enough to
// be opaque, where this mesh is the sea.
float sea_weight(float depth) {
	return smoothstep(shelf_begin, shelf_end, depth);
}

void vertex() {
	v_ground = UV.x;
	if (!is_canopy) {
		float depth = sea_y - v_ground;
		if (depth > 0.0) {
			// Float the surface off the bed. Where a folded block meets its
			// finely meshed neighbours the water is deeper than shelf_end on
			// both sides, so both sit flat at sea_y - sea_shelf and the seam
			// between the two tessellations closes exactly.
			VERTEX.y = sea_y - mix(depth, sea_shelf, sea_weight(depth));
			// A flattened quad is not facing where its baked normal says.
			NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), sea_weight(depth)));
		}
	}
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
	float depth = sea_y - v_ground;
	// A wood the tide has closed over. Nothing is left standing out of the
	// water: the crowns are only a few metres tall and the shell has no trunks
	// under it, so a half drowned one would read as leaves floating on the sea.
	if (is_canopy && depth > 0.0) {
		discard;
	}
	vec4 haze = haze_over(VERTEX, INV_VIEW_MATRIX, v_world.y);
	// Vertex colours are authored in sRGB, the renderer works in linear space.
	vec3 base = pow(clamp(COLOR.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));
	// The shoreline is drawn here rather than baked into the cells, so it is a
	// curve across a cell and it moves with the tide the frame the tide moves.
	float wet = is_canopy ? 0.0 : step(0.0, depth);
	base = mix(base, mix(shallow_color, deep_color,
		clamp(depth / depth_fade, 0.0, 1.0)), wet);

	vec3 view_dir = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	vec3 n = normalize(v_world_normal);
	float facing = clamp(dot(-view_dir, n), 0.0, 1.0);
	// Schlick: the flatter the angle, the more of the sky the water returns.
	float fresnel = wet * (0.02 + (reflect_max - 0.02) * pow(1.0 - facing, 5.0));

	ALBEDO = base * (1.0 - haze.a);
	EMISSION = haze_sky(reflect(view_dir, n)) * fresnel * (1.0 - haze.a) + haze.rgb * haze.a;
	ROUGHNESS = mix(0.95, 0.2, wet);
	SPECULAR = 0.1 * (1.0 - haze.a);
}
