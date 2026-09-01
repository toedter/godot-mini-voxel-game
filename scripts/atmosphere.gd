class_name Atmosphere
extends WorldEnvironment

## Distance haze: how far you can see, and what colour the air is.
##
## The haze is deliberately a curtain. VoxelWorld streams one resolution of
## voxels out to `view_distance` and nothing beyond it, so the mist is closed in
## short of that radius: by the time a chunk is loaded or dropped it is behind
## an opaque wall of air, and the end of the streamed world is never something
## you can watch happening.
##
## The one thing that does reach past the curtain is height. The mist lies on
## the ground and thins out above `mist_top`, so the peaks across the island -
## drawn by VoxelWorld's static far terrain mesh, which is hazed by exactly the
## same air - rise out of it while the plain they stand on is gone after a few
## dozen metres. Keep `mist_top` near the tree line: below it nothing can be
## seen at the range where the chunks end, which is what keeps a wood from
## sprouting into view as it is walked towards.
##
## The haze also drifts from a cool blue mist over grassland to warm dust over
## the desert. The sky's ground hemisphere is retinted to match, otherwise the
## tinted fog would leave a visible seam along the horizon where the terrain
## ends and the sky starts.

@export var world_path: NodePath = ^"../VoxelWorld"
@export var player_path: NodePath = ^"../Player"
@export var sun_path: NodePath = ^"../Sun"
## Where the haze starts, as a fraction of the distance at which it has closed
## in completely.
@export_range(0.0, 1.0, 0.01) var haze_begin: float = 0.3
## Where the mist goes fully opaque, as a fraction of the radius VoxelWorld
## streams its chunks to.
##
## Short of 1 on purpose. The last stretch of the streamed disc is where a tree
## whose trunk sits in a chunk that is not loaded yet would be missing its
## crown, and where the distant island's canopy shell is handing over, so all of
## that has to be behind opaque air. Raising it towards 1 opens the view and
## brings those seams closer to visible; lowering it wastes chunks on ground
## nobody can see.
@export_range(0.5, 1.0, 0.01) var reach_fraction: float = 0.9
## Reach (m) used before there is a world to ask.
@export var fallback_range: float = 86.0
## Higher values keep the near range clearer and pack the fade into the
## distance.
@export_range(0.5, 4.0, 0.05) var haze_curve: float = 1.6
## Reference colours of clear and of dusty air at midday. Only the ratio
## between them is used, so the dust survives the day/night cycle as a warm
## shift of whatever colour the sky currently has instead of a fixed sand
## colour that would still glow at midnight.
@export var mist_color: Color = Color(0.7, 0.8, 0.92)
@export var dust_color: Color = Color(0.85, 0.77, 0.6)
## How quickly the haze colour follows a biome change, in units per second.
@export var tint_speed: float = 0.25
## Colour the world takes on once the camera dips below the sea surface, and
## how far you can still see down there.
@export var water_color: Color = Color(0.06, 0.28, 0.34)
@export var water_deep_color: Color = Color(0.02, 0.12, 0.20)
@export_range(2.0, 60.0, 0.5) var water_visibility: float = 14.0
## The mist lies on the ground. Up to this height (world Y) the air is at full
## thickness, so everything below it is gone by the time the chunks end. The
## island's plain sits at roughly 31 m, bare rock starts at 48 m and the summits
## reach into the eighties, so a value just above the tree line hides the woods
## and lets the peaks through.
@export var mist_top: float = 50.0
## Metres over which the air thins out above `mist_top`, down to `mist_floor` of
## its density. Short, so that the peaks come out of the mist as peaks rather
## than the whole island slowly surfacing.
@export var mist_depth: float = 12.0
@export_range(0.02, 1.0, 0.01) var mist_floor: float = 0.08

var _env: Environment
var _sky: ProceduralSkyMaterial
var _world: VoxelWorld
var _player: Node3D
var _day: DayNight
var _dust := 0.0
var _wet := 0.0


func _ready() -> void:
	_env = environment
	_world = get_node_or_null(world_path) as VoxelWorld
	_player = get_node_or_null(player_path) as Node3D
	_day = get_node_or_null(sun_path) as DayNight
	if _env != null and _env.sky != null:
		_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_apply_range()
	_apply_tint(0.0)


## Called again whenever anything the haze depends on changes at runtime.
func _apply_range() -> void:
	if _env == null:
		return
	# The voxel shaders fog themselves so that distant geometry fades into the
	# sky gradient rather than into one flat colour; the Environment's own fog
	# would only fight with that.
	_env.fog_enabled = false
	_push_range()


## Everything in the world is hazed over the same reach, chunks and sea plane
## and distant island alike. That is the whole trick: at the distance the chunks
## stop, the mesh standing in for them behind is just as thoroughly gone, so
## there is no edge to catch and no seam to see - only height lifts anything out
## of it.
##
## Under water the haze doubles as the murk: it closes in much sooner and the
## shaders below tint it green blue, which is what makes being submerged read as
## being submerged.
func _push_range() -> void:
	var open := _reach()
	var reach: float = lerpf(open, minf(water_visibility, open), _wet)
	for m in _materials():
		m.set_shader_parameter("haze_begin", reach * lerpf(haze_begin, 0.1, _wet))
		m.set_shader_parameter("haze_end", reach)
		m.set_shader_parameter("haze_curve", haze_curve)
		# Under water there is no mist layer, only murk, and it is the same
		# everywhere.
		m.set_shader_parameter("mist_top", mist_top)
		m.set_shader_parameter("mist_depth", mist_depth)
		m.set_shader_parameter("mist_floor", lerpf(mist_floor, 1.0, _wet))


## Where the mist has closed in completely, in metres: a little short of the
## radius the chunks are streamed to.
func _reach() -> float:
	if _world == null:
		return fallback_range
	return _world.view_distance * reach_fraction


func _materials() -> Array[ShaderMaterial]:
	return _world.haze_materials() if _world != null else [] as Array[ShaderMaterial]


func _process(delta: float) -> void:
	if _env == null or _world == null or _player == null or _world.gen == null:
		return
	var p := _player.global_position
	var target := smoothstep(0.35, 0.65, _world.gen.biome_at(p.x, p.z))

	# Tracks the active camera, not the player node, so it also works in XR and
	# when the head alone dips below the surface.
	var cam := get_viewport().get_camera_3d()
	var eye := p + Vector3.UP * 1.6 if cam == null else cam.global_position
	var eye_y := eye.y
	# The distant island's canopy hands over at a distance from the eye, and the
	# shadow pass has to agree with the colour pass about where that is.
	_world.set_eye(eye)
	# Against the tide's level, not the datum the land was shaped around, so
	# the murk closes over the eye wherever the water actually stands.
	var wet := 1.0 if eye_y < _world.water_level else 0.0
	# Short fade so ducking through the surface is a wipe rather than a snap.
	_wet = move_toward(_wet, wet, delta * 6.0)
	# The coarse mesh of the island stands in for everything the streamed
	# chunks cannot reach. Under water it would only show as a false floor a
	# few metres down, and nothing is visible out there anyway.
	_world.set_far_visible(_wet <= 0.0)
	_push_range()

	# Applied every frame, not just when the biome changes, because the day
	# night cycle keeps moving the palette underneath it.
	_apply_tint(move_toward(_dust, target, delta * tint_speed))


func _apply_tint(dust: float) -> void:
	_dust = dust
	var top := DayNight.DAY_TOP
	var haze := mist_color
	var curve := 0.5
	if _day != null:
		top = _day.sky_top_color()
		haze = _day.horizon_color()
		_env.ambient_light_energy = _day.ambient_energy()
		if _world != null:
			_world.set_glow_level(_day.glow_amount())
	if _sky != null:
		curve = _sky.sky_curve
	# Dust is a warm shift relative to clear air rather than a colour of its
	# own, so a dusty midnight stays dark instead of glowing sand coloured.
	var warm := Color(
		lerpf(1.0, dust_color.r / mist_color.r, dust),
		lerpf(1.0, dust_color.g / mist_color.g, dust),
		lerpf(1.0, dust_color.b / mist_color.b, dust))
	haze = Color(haze.r * warm.r, haze.g * warm.g, haze.b * warm.b)
	top = Color(top.r * lerpf(1.0, warm.r, 0.4), top.g * lerpf(1.0, warm.g, 0.4), top.b * lerpf(1.0, warm.b, 0.4))

	# Under water the whole palette collapses into the murk. The zenith keeps a
	# little more light than the rest so that looking up still leads towards
	# the bright surface instead of into a flat wall of green.
	var deep := haze.lerp(water_deep_color, _wet)
	haze = haze.lerp(water_color, _wet)
	top = top.lerp(water_color, _wet * 0.8)
	if _wet > 0.0:
		_env.ambient_light_energy *= lerpf(1.0, 0.5, _wet)
	if _sky != null:
		# the ground hemisphere sits exactly where the terrain fades out, and
		# the horizon band has to carry the same dust so there is no seam
		_sky.ground_horizon_color = deep
		_sky.ground_bottom_color = deep
		_sky.sky_horizon_color = haze
		_sky.sky_top_color = top
	# The sky material treats its colours as sRGB, the shader works in linear
	# space, so the haze has to be converted the same way the sky is.
	var lin_haze := haze.srgb_to_linear()
	var lin_deep := deep.srgb_to_linear()
	var lin_top := top.srgb_to_linear()
	for m in _materials():
		m.set_shader_parameter("haze_horizon", Vector3(lin_haze.r, lin_haze.g, lin_haze.b))
		m.set_shader_parameter("haze_ground", Vector3(lin_deep.r, lin_deep.g, lin_deep.b))
		m.set_shader_parameter("haze_top", Vector3(lin_top.r, lin_top.g, lin_top.b))
		m.set_shader_parameter("haze_sky_curve", curve)
