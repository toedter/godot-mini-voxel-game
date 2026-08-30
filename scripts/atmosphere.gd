class_name Atmosphere
extends WorldEnvironment

## Distance haze, and the handover from the streamed chunks to the mesh of the
## whole island behind them.
##
## The haze used to be a curtain: its range came straight from VoxelWorld's view
## distance, because the world really did stop there. Now that VoxelWorld also
## carries a coarse mesh of the entire island, the two jobs are separate. How
## far you can see is authored here (`ground_range`, opening up to `vista_range`
## as the player climbs), while the streamed radius only decides where the
## chunks dissolve into that mesh.
##
## The haze also drifts from a cool blue mist over grassland to warm dust over
## the desert. The sky's ground hemisphere is retinted to match, otherwise the
## tinted fog would leave a visible seam along the horizon where the terrain
## ends and the sky starts.

@export var world_path: NodePath = ^"../VoxelWorld"
@export var player_path: NodePath = ^"../Player"
@export var sun_path: NodePath = ^"../Sun"
## Where the haze starts, as a fraction of the guaranteed streamed distance.
@export_range(0.0, 1.0, 0.01) var haze_begin: float = 0.35
## Trees are meshed with the chunk their trunk sits in, but their canopy hangs
## a few metres out of it, so the handover has to start that much earlier.
@export var feature_overhang: float = 4.0
## Where the streamed chunks start dissolving into the distant island mesh, as
## a fraction of the radius out to which they are guaranteed to be loaded. Kept
## short: the dissolve punches its holes per voxel, so a boulder caught in the
## band crumbles into flecks rather than fading away as one thing, and the less
## depth that band has the less of that there is to see.
@export_range(0.2, 0.95, 0.01) var dissolve_start: float = 0.86
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
## The sea is one plane, not streamed geometry, so it has nothing to hide and
## can stay visible far past the point where the terrain has to be gone. Giving
## it its own, much longer haze range is what lets the water read as an open
## sea rather than as a white band a few steps off the beach.
@export_range(1.0, 8.0, 0.1) var sea_haze_scale: float = 3.2
## How far (m) you can see standing on the plain. This used to be tied to the
## streamed chunk radius, because past it the world simply stopped; now that
## VoxelWorld carries a mesh of the whole island behind the chunks there is
## something out there to look at, and the haze is free to be a mood rather
## than a curtain.
@export_range(40.0, 1200.0, 10.0) var ground_range: float = 250.0
## How far (m) you can see once you are up on a summit. The haze opens up from
## `ground_range` to this as the player climbs, and the coarse mesh of the
## whole island (VoxelWorld's far terrain) is what fills the view up there.
@export_range(100.0, 2000.0, 10.0) var vista_range: float = 900.0
## Eye heights (world Y) between which the haze opens up. The island's plain
## sits at roughly 31 m, the summits reach into the eighties.
@export var vista_low: float = 42.0
@export var vista_high: float = 66.0
## How quickly the view opens up and closes again, in units per second.
@export_range(0.05, 4.0, 0.05) var vista_speed: float = 0.5
## The mist lies on the ground. Above this height the air thins out over
## `mist_depth` metres down to `mist_floor` of its density, which is what makes
## the mountains stand out of the haze long before the plain around them does.
@export var mist_top: float = 44.0
@export var mist_depth: float = 24.0
@export_range(0.02, 1.0, 0.01) var mist_floor: float = 0.10

var _env: Environment
var _sky: ProceduralSkyMaterial
var _world: VoxelWorld
var _player: Node3D
var _day: DayNight
var _dust := 0.0
var _wet := 0.0
var _vista := 0.0
var _reach := 38.4


func _ready() -> void:
	_env = environment
	_world = get_node_or_null(world_path) as VoxelWorld
	_player = get_node_or_null(player_path) as Node3D
	_day = get_node_or_null(sun_path) as DayNight
	if _env != null and _env.sky != null:
		_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_apply_range()
	_apply_tint(0.0)


## Works out how far the streamed chunks are guaranteed to reach. Called again
## whenever the view distance changes at runtime.
func _apply_range() -> void:
	if _env == null:
		return
	# Chunks are loaded in a square of `view_distance` chunks around the one the
	# player stands in, and the player can be anywhere inside that chunk, so the
	# nearest point where geometry may be missing is one chunk closer than the
	# nominal radius. That is where the handover has to be finished.
	var reach := 38.4
	if _world != null:
		reach = float(maxi(_world.view_distance - 1, 1)) * VoxelDefs.CHUNK_METERS
	_reach = maxf(reach - feature_overhang, 8.0)
	# The voxel shaders fog themselves so that distant geometry fades into the
	# sky gradient rather than into one flat colour; the Environment's own fog
	# would only fight with that.
	_env.fog_enabled = false
	_push_range()


## Under water the haze doubles as the murk: it closes in much sooner and the
## shaders below tint it green blue, which is what makes being submerged read
## as being submerged.
##
## Climbing does the opposite: from a summit the haze is pushed back to
## `vista_range`, which is what turns the streamed bubble around the player into
## a view over the whole island.
func _push_range() -> void:
	var sea_mat: ShaderMaterial = null if _world == null else _world.sea_material()
	var open: float = lerpf(ground_range, vista_range, _vista)
	var air: float = lerpf(open, minf(water_visibility, open), _wet)
	# Under water the murk swallows the sea plane just as fast as everything
	# else, so both ranges collapse onto the same short reach.
	var sea: float = lerpf(maxf(_reach * sea_haze_scale, open), minf(water_visibility, open), _wet)
	for m in _materials():
		var reach: float = sea if m == sea_mat else air
		m.set_shader_parameter("haze_begin", reach * lerpf(haze_begin, 0.1, _wet))
		m.set_shader_parameter("haze_end", reach)
		m.set_shader_parameter("haze_curve", haze_curve)
		# Under water there is no mist layer, only murk, and it is the same
		# everywhere.
		m.set_shader_parameter("mist_top", mist_top)
		m.set_shader_parameter("mist_depth", mist_depth)
		m.set_shader_parameter("mist_floor", lerpf(mist_floor, 1.0, _wet))

	# Where the streamed chunks hand over to the coarse mesh of the island.
	# The band ends at the radius out to which chunks are guaranteed to be
	# loaded, so past it the terrain is cut off cleanly in every direction
	# instead of showing the ragged edge of the loaded area. It starts well
	# inside that now: the mesh behind it is fine enough to take over, and a
	# long fade reads better than a rim of holes.
	if _world != null:
		var edge := _reach + feature_overhang
		var begin: float = edge * dissolve_start
		for m in _world.chunk_materials():
			m.set_shader_parameter("dissolve_begin", begin)
			m.set_shader_parameter("dissolve_end", edge)
		# The canopy of the distant mesh comes in exactly as the real trees go,
		# so the woods are never handed over to nobody. Only the canopy: the
		# ground of that mesh has to be solid behind the dissolving chunks.
		var canopy := _world.far_canopy_material()
		canopy.set_shader_parameter("canopy_begin", begin)
		canopy.set_shader_parameter("canopy_end", edge)


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
	# The canopy of the distant mesh is dithered away around the eye, and its
	# shadow pass has to agree with the colour pass about where that is.
	_world.set_far_eye(eye)
	var wet := 1.0 if eye_y < VoxelDefs.SEA_LEVEL else 0.0
	# Short fade so ducking through the surface is a wipe rather than a snap.
	_wet = move_toward(_wet, wet, delta * 6.0)
	# The higher the eye, the further the haze is pushed back. Eased over a
	# couple of seconds so cresting a ridge opens the view instead of snapping
	# it, and so a jump does not flick the whole island in and out.
	var vista := smoothstep(vista_low, vista_high, eye_y)
	_vista = move_toward(_vista, vista, delta * vista_speed)
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
