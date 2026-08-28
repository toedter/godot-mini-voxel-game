class_name Atmosphere
extends WorldEnvironment

## Distance haze that hides the edge of the streamed world.
##
## The fog range is derived from VoxelWorld's view distance instead of being
## authored by hand, so terrain is always completely faded out before it reaches
## the radius where chunks appear and disappear.
##
## The haze also drifts from a cool blue mist over grassland to warm dust over
## the desert. The sky's ground hemisphere is retinted to match, otherwise the
## tinted fog would leave a visible seam along the horizon where the terrain
## ends and the sky starts.

@export var world_path: NodePath = ^"../VoxelWorld"
@export var player_path: NodePath = ^"../Player"
## Where the haze starts, as a fraction of the guaranteed streamed distance.
@export_range(0.0, 1.0, 0.01) var haze_begin: float = 0.35
## Trees are meshed with the chunk their trunk sits in, but their canopy hangs
## a few metres out of it, so the haze has to close in that much earlier.
@export var feature_overhang: float = 4.0
## Higher values keep the near range clearer and pack the fade into the
## distance.
@export_range(0.5, 4.0, 0.05) var haze_curve: float = 1.6
@export var mist_color: Color = Color(0.7, 0.8, 0.92)
@export var dust_color: Color = Color(0.85, 0.77, 0.6)
## How quickly the haze colour follows a biome change, in units per second.
@export var tint_speed: float = 0.25

var _env: Environment
var _sky: ProceduralSkyMaterial
var _world: VoxelWorld
var _player: Node3D
var _dust := 0.0


func _ready() -> void:
	_env = environment
	_world = get_node_or_null(world_path) as VoxelWorld
	_player = get_node_or_null(player_path) as Node3D
	if _env != null and _env.sky != null:
		_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_apply_range()
	_apply_tint(0.0)


## Matches the fog to the streamed radius. Called again whenever the view
## distance changes at runtime.
func _apply_range() -> void:
	if _env == null:
		return
	# Chunks are loaded in a square of `view_distance` chunks around the one the
	# player stands in, and the player can be anywhere inside that chunk, so the
	# nearest point where geometry may be missing is one chunk closer than the
	# nominal radius. The haze has to be opaque by then.
	var reach := 38.4
	if _world != null:
		reach = float(maxi(_world.view_distance - 1, 1)) * VoxelDefs.CHUNK_METERS
	reach = maxf(reach - feature_overhang, 8.0)
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_depth_begin = reach * haze_begin
	_env.fog_depth_end = reach
	_env.fog_depth_curve = haze_curve
	_env.fog_density = 1.0
	_env.fog_sky_affect = 0.0
	_env.fog_sun_scatter = 0.1
	# Aerial perspective is deliberately off: sampling the sky radiance mips
	# tints fogged geometry slightly differently from the sky behind it, which
	# makes the world edge *more* visible rather than less.
	_env.fog_aerial_perspective = 0.0


func _process(delta: float) -> void:
	if _env == null or _world == null or _player == null or _world.gen == null:
		return
	var p := _player.global_position
	var target := smoothstep(0.35, 0.65, _world.gen.biome_at(p.x, p.z))
	if is_equal_approx(target, _dust):
		return
	_apply_tint(move_toward(_dust, target, delta * tint_speed))


func _apply_tint(dust: float) -> void:
	_dust = dust
	var haze := mist_color.lerp(dust_color, dust)
	_env.fog_light_color = haze
	if _sky != null:
		# the ground hemisphere sits exactly where the terrain fades out, and
		# the horizon band has to carry the same dust so there is no seam
		_sky.ground_horizon_color = haze
		_sky.ground_bottom_color = haze
		_sky.sky_horizon_color = haze
