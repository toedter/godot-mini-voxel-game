shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, fog_disabled;

// The sea around the island.
//
// One horizontal plane that follows the player. Everything that makes it read
// as water is done per fragment: crossing swells give the normals, the depth
// buffer gives the distance down to the sea bed, and that distance drives the
// colour, the transparency and the surf along the shore.
//
// It shares voxel_common's haze so the water dissolves into exactly the same
// horizon colour as the terrain and the sky do; without that the sea would end
// in a hard line at the edge of the streamed world.

#include "res://shaders/voxel_common.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

group_uniforms water;
/// Colour of a shallow, sunlit patch and of water deep enough to hide the bottom.
uniform vec3 shallow_color : source_color = vec3(0.10, 0.44, 0.44);
uniform vec3 deep_color : source_color = vec3(0.01, 0.09, 0.19);
/// Depth (m) at which the water has taken on its full deep colour.
uniform float depth_fade : hint_range(0.5, 20.0) = 3.2;
/// How many metres of water the eye can still see through.
uniform float clarity : hint_range(0.2, 12.0) = 1.7;

group_uniforms waves;
/// Height (m) of the largest swell. The sea is calm at the scale of 10 cm voxels.
uniform float wave_height : hint_range(0.0, 0.6) = 0.075;
uniform float wave_speed : hint_range(0.0, 3.0) = 1.0;
/// Extra tilt applied to the shading normals only, which keeps the surface
/// flat enough to walk out of while still glittering.
uniform float normal_strength : hint_range(0.0, 8.0) = 2.2;
/// Amplitude (m) of the fine chop. It is never displaced, only shaded, and it
/// is what breaks the mirror up into water rather than glass.
uniform float chop_strength : hint_range(0.0, 0.2) = 0.032;
/// Ceiling on the mirror reflection. Real water reaches 1.0 at the horizon,
/// but leaving a little of the body colour showing keeps the sea reading as
/// sea instead of as a sheet of white sky.
uniform float reflect_max : hint_range(0.1, 1.0) = 0.72;

group_uniforms shore;
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 0.99);
/// Water shallower than this is inside the surf zone.
uniform float foam_depth : hint_range(0.0, 4.0) = 0.42;
/// Distance (m) between two rolling lines of surf.
uniform float foam_spacing : hint_range(0.2, 8.0) = 0.9;

const float TAU_ = 6.28318530718;
const float GRAVITY = 9.81;

// Four crossing swells at decreasing scale. Each returns its contribution to
// the height and to the horizontal gradient, so the normal is analytic and
// stays correct however coarsely the plane happens to be tessellated.
void wave_sum(vec2 p, float t, out float h, out vec2 grad) {
	vec2 dirs[4];
	dirs[0] = normalize(vec2(1.00, 0.28));
	dirs[1] = normalize(vec2(-0.55, 1.00));
	dirs[2] = normalize(vec2(0.78, -0.86));
	dirs[3] = normalize(vec2(-0.92, -0.37));
	float lens[4] = {9.4, 5.1, 2.9, 1.6};
	float amps[4] = {1.00, 0.54, 0.27, 0.13};

	h = 0.0;
	grad = vec2(0.0);
	for (int i = 0; i < 4; i++) {
		float k = TAU_ / lens[i];
		// Deep water dispersion: long swells travel faster than short chop,
		// so the pattern never repeats and never looks like a marching grid.
		float w = sqrt(GRAVITY * k);
		float ph = dot(p, dirs[i]) * k + t * w;
		h += sin(ph) * amps[i];
		grad += dirs[i] * (cos(ph) * amps[i] * k);
	}
	// normalise against the summed amplitude so wave_height is in metres
	h *= 0.515;
	grad *= 0.515;
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash13(vec3(i, 0.0));
	float b = hash13(vec3(i + vec2(1.0, 0.0), 0.0));
	float c = hash13(vec3(i + vec2(0.0, 1.0), 0.0));
	float d = hash13(vec3(i + vec2(1.0, 1.0), 0.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h;
	vec2 g;
	wave_sum(w.xz, TIME * wave_speed, h, g);
	VERTEX.y += h * wave_height;
	v_world = vec3(w.x, w.y + h * wave_height, w.z);
	v_world_normal = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	// Recomputed here rather than interpolated: the plane is only tessellated
	// every couple of metres, the ripples are much finer than that.
	float h;
	vec2 g;
	wave_sum(v_world.xz, TIME * wave_speed, h, g);
	// The same field again at a quarter of the scale. Short, steep chop that
	// only exists in the normals, scattering the reflection across the whole
	// sky dome instead of leaving one flat mirror.
	float h2;
	vec2 g2;
	wave_sum(v_world.xz * 4.0, TIME * wave_speed * 2.1, h2, g2);
	vec2 slope = g * (wave_height * normal_strength) + g2 * chop_strength;
	vec3 n = normalize(vec3(-slope.x, 1.0, -slope.y));
	// Seen from below the surface is a ceiling.
	if (!FRONT_FACING) {
		n = -n;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	// How much water the view ray travels through before it hits the sea bed,
	// and how deep that sea bed lies below the surface.
	float raw = texture(depth_tex, SCREEN_UV).x;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	view.xyz /= view.w;
	float through = max(-view.z + VERTEX.z, 0.0);
	vec3 floor_world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	float below = max(v_world.y - floor_world.y, 0.0);
	// Nothing was drawn behind the water (open sea, or the sky at the horizon).
	if (raw <= 0.0) {
		through = 1000.0;
		below = 1000.0;
	}
	through = clamp(through, 0.0, 1000.0);
	below = clamp(below, 0.0, 1000.0);

	vec3 eye = normalize(-VERTEX);
	float facing = clamp(dot(NORMAL, eye), 0.0, 1.0);
	// Schlick: at a grazing angle almost everything is reflected and the water
	// turns into a mirror of the sky, which is what sells the flat expanse.
	float fresnel = FRONT_FACING ? 0.02 + (reflect_max - 0.02) * pow(1.0 - facing, 5.0) : 0.0;

	vec3 body = mix(shallow_color, deep_color, clamp(below / depth_fade, 0.0, 1.0));
	vec3 sky = haze_sky(normalize(reflect(-(INV_VIEW_MATRIX * vec4(eye, 0.0)).xyz, n)));

	// Surf: bands that sit at a fixed depth below the surface therefore follow
	// the shoreline, and sliding them shorewards over time makes them roll in.
	float shore = 1.0 - smoothstep(0.0, foam_depth, below);
	float churn = vnoise(v_world.xz * 1.7 + vec2(TIME * 0.35, TIME * -0.21));
	float rollers = sin((below / foam_spacing - TIME * 0.55 + churn * 0.6) * TAU_);
	float foam = shore * clamp(0.45 + 0.55 * rollers, 0.0, 1.0) * (0.65 + 0.35 * churn);
	// A thin permanent line of wash right where the water meets the sand.
	foam = max(foam, (1.0 - smoothstep(0.0, 0.09, below)) * (0.5 + 0.5 * churn));
	foam = FRONT_FACING ? clamp(foam, 0.0, 1.0) : 0.0;

	float alpha = clamp(max(1.0 - exp(-through / clarity), fresnel), 0.0, 1.0);
	alpha = max(alpha, foam);
	if (!FRONT_FACING) {
		// Looking up from under water: a calm, mostly clear ceiling.
		alpha = 0.45;
	}

	vec3 albedo = mix(body, foam_color, foam);
	vec4 haze = haze_over(VERTEX, INV_VIEW_MATRIX, v_world.y);
	// Far out the sea has to end up exactly sky coloured and fully opaque,
	// otherwise the horizon shows a seam where the water is still see-through.
	ALBEDO = albedo * (1.0 - haze.a);
	EMISSION = sky * fresnel * (1.0 - foam) * (1.0 - haze.a) + haze.rgb * haze.a;
	ALPHA = mix(alpha, 1.0, haze.a);
	ROUGHNESS = mix(0.06, 0.55, foam);
	SPECULAR = 0.5 * (1.0 - haze.a);
	METALLIC = 0.0;
}
