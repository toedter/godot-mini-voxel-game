class_name VoxelWorld
extends Node3D

## Streams voxel chunks around the player on worker threads.
##
## There is one resolution and only one: the world is 10 cm voxels in 6.4 m
## chunks, everywhere, out to `view_distance`. Nothing is ever redrawn at a
## coarser grain as it moves away, which is what the mist is for - Atmosphere
## closes the haze in a little short of the streamed radius, so chunks come and
## go well behind an opaque wall of it. What you can see, you can see at full
## detail; what you cannot see is mist.
##
## Behind the mist stands FarTerrain, a static mesh of the whole island. It is
## built once and then only ever repainted when the tide moves, and on the
## plain it is as thoroughly hazed over as the chunks are. It earns its keep higher up, where the mist
## thins out and the peaks across the island rise out of it.

signal world_ready
## Fires once the tide has settled at a new level, after the distant island has
## been repainted for it. The hook a game hangs "the water reached the mark" on.
signal tide_changed(water_y: float)

@export var world_seed: int = 1337
## Radius (m) out to which chunks are streamed. Everything inside it is the
## world at full 10 cm voxels.
##
## This is the one dial that decides what the world costs. The disc holds about
## pi * r^2 / 41 chunks - roughly 300 at 64 m, 700 at 96 m, 1250 at 128 m - and
## every one of them is meshed, kept in memory and handed to the renderer.
## Atmosphere's mist is closed in to match, so raising it opens the view and
## lowering it draws the mist in.
@export_range(24.0, 256.0, 1.0) var view_distance: float = 96.0:
	set(value):
		view_distance = value
		# Before _ready the value is only stored: the materials do not exist
		# yet, and _ready reconsiders the disc anyway. After it this is a live
		# dial - Atmosphere reads the radius every frame to place the mist, so
		# the two stay together.
		if not is_node_ready():
			return
		_push_canopy_band()
		_update_center(true)
## Chunks within this radius (m) get the point lights the mushroom caps cast on
## their surroundings. Those are real nodes and the only part of a chunk that is
## not built for the whole disc; _update_lights fades them up over the last
## stretch before the boundary, so none of them is ever seen switching on.
@export_range(0.0, 100.0, 1.0) var light_range: float = 19.2
## Chunks within this radius (m) get a collision shape.
@export_range(0.0, 100.0, 1.0) var collision_range: float = 19.2
@export var max_parallel_jobs: int = 6
@export var chunks_per_frame: int = 4
## Chunks nearer than this (m) cast into the sun's shadow cascades. Further out
## a chunk's own shadow is a few pixels of the last cascade that nobody can pick
## out, but it still costs a full extra draw of its geometry. The flag follows
## the player, so a chunk gains its shadow as it is walked towards.
@export_range(0.0, 256.0, 1.0) var shadow_range: float = 48.0
## How much of the streamed radius the distant island's canopy shell takes to
## hand over to the real trees of the chunks, as a fraction of that radius. Out
## on the plain this happens inside the mist and is never seen; from up high it
## reads as a wood thinning out.
@export_range(0.05, 0.6, 0.01) var canopy_band: float = 0.25
## Carry the ground in a HeightMapShape3D instead of putting its triangles into
## the collision soup. The shape is built from the column heights the mesher
## already has, needs no BVH, and leaves the soup with nothing but the trees
## and boulders.
##
## The one behavioural difference is that a heightmap interpolates between
## column centres, so a voxel step becomes a ramp one voxel wide rather than a
## hard lip. At 10 cm that is not something you can feel underfoot, but it is
## the height the player actually rests at: everything that corrects the
## player's height asks TerrainGen.collision_y() for the ramp, not ground_y()
## for the lip. Turning this off restores the old triangle-per-face ground, and
## collision_y then reads half a voxel low on a slope rather than high.
@export var heightmap_collision: bool = true
## Global multiplier for the per-voxel colour variation.
@export_range(0.0, 3.0, 0.05) var voxel_tint: float = 1.0
## Peak sway of a grass tuft in metres, and how fast the wind travels.
@export_range(0.0, 0.2, 0.005) var wind_strength: float = 0.035
@export_range(0.0, 6.0, 0.05) var wind_speed: float = 1.9
## Colour and intensity of the glow the mushroom caps give off at night.
@export var glow_color: Color = Color(0.62, 0.30, 1.0)
@export_range(0.0, 8.0, 0.1) var glow_strength: float = 2.6
@export_range(0.0, 6.0, 0.05) var glow_pulse_speed: float = 1.1
@export_range(0.0, 1.0, 0.01) var glow_pulse_depth: float = 0.22
## Multiplier on the light the mushroom caps cast on their surroundings.
@export_range(0.0, 4.0, 0.05) var glow_light_energy: float = 1.0
## How far the cast light reaches before it has faded out completely. Must stay
## inside light_range, since that is where the lights are created.
@export_range(4.0, 40.0, 0.5) var glow_light_distance: float = 17.0
## Side length (m) of the sea plane that follows the player. Only has to reach
## past the point where the haze has closed in completely; past it the distant
## island mesh paints the rest of the sea. The sea lies at the bottom of the
## mist, where the air is at its thickest, so it never needs much more than the
## streamed radius.
@export_range(40.0, 1200.0, 10.0) var water_extent: float = 260.0
## Size (m) of one quad of the sea plane. Smaller means the swell is carried by
## the geometry rather than only by the shading. The wave normals are worked out
## per fragment, so this mostly decides how well the swell holds its shape
## against the sky rather than how detailed the water looks.
@export_range(0.5, 8.0, 0.1) var water_quad: float = 2.5
## World Y the water surface currently stands at, and the level it is easing
## towards. Everything that asks about water - buoyancy, the underwater murk,
## the sea plane, the painted ocean in the distance - reads `water_level`, and
## nothing reads VoxelDefs.SEA_DATUM, which only shapes the land.
##
## The two are equal at startup, so a world nobody moves the tide in looks
## exactly as it always did.
var water_level: float = VoxelDefs.SEA_DATUM
var _tide_target: float = VoxelDefs.SEA_DATUM
## How fast (m/s) the water rises or falls towards its target. Slow enough to
## read as a tide coming in rather than as a teleport, fast enough to iterate.
@export_range(0.05, 20.0, 0.05) var tide_speed: float = 1.5
## How far (m) one press of the tide keys moves the water.
@export_range(0.1, 20.0, 0.1) var tide_step: float = 2.0
## Limits (m, relative to the terrain datum) the tide may be driven between.
## Low tide bottoms out on the shelf; high tide stops short of drowning the
## island's dome, which sits VoxelDefs dome height above the datum.
@export var tide_low: float = -6.0
@export var tide_high: float = 10.0
## Half size (m) of the coarse mesh of the whole island. Has to reach past the
## point where the haze closes in from a mountain top, otherwise the world ends
## in a visible edge up there.
@export_range(200.0, 2000.0, 10.0) var far_extent: float = 1300.0
## Size (m) of one cell of that mesh. Only the island is meshed this finely;
## open water is folded down to one quad per 8x8 cells, which is what pays for
## it. Real voxels now reach a few hundred metres, so this only has to serve the
## view from a summit and can be coarser than it once was.
@export_range(1.0, 25.6, 0.1) var far_step: float = 3.0
## How far (m) the coarse mesh is sunk below the real surface, so that it can
## never poke through the streamed chunks in a hollow. Steep ground is sunk
## further; see FarTerrain.
@export_range(0.0, 4.0, 0.1) var far_drop: float = 0.5
@export var player_path: NodePath = ^"../Player"

var gen: TerrainGen
## True while the player stands in an interior rather than on the island.
##
## Interiors are built below the terrain, which puts the player somewhere the
## outdoor rules actively fight: both surface clamps exist to shove a body that
## has fallen through un-streamed collision back onto the heightmap, and the
## water level is far above, so buoyancy would have them swimming. One flag
## suspends all of it, read by Player, XRGroundClamp and Atmosphere.
var indoors := false

## World XZ the player was put down at. Searched for at runtime, so props that
## want to be placed near the player have to read it rather than assume one.
var spawn_xz := Vector2.ZERO

## The three materials a chunk's surfaces are drawn with: static voxels, wind
## swayed grass tufts, and the mushroom caps that glow at night.
var _material: ShaderMaterial
var _glow_material: ShaderMaterial
var _grass_material: ShaderMaterial
var _water_material: ShaderMaterial
var _far_material: ShaderMaterial
var _far_canopy_material: ShaderMaterial
var _water: MeshInstance3D
var _far: Node3D
var _far_job: int = -1
var _far_tiles: Array = []
var _far_built := false
## Water level the in flight far terrain job is painting for, and whether the
## tide has moved on since it was dispatched. The job samples the level once at
## dispatch rather than reading `water_level` off the main thread while it runs.
var _far_job_water: float = VoxelDefs.SEA_DATUM
var _far_dirty := false
## All keyed by Vector2i(chunk x, chunk z).
##
## A chunk is not a node. Its mesh is a bare RenderingServer instance, which is
## all a static lump of geometry needs and skips the scene tree entirely; only
## the few chunks that carry collision or mushroom lights own real nodes. The
## entry holds {inst, mesh, body, lights, lit, collision, shadows} - `mesh`
## is kept purely to hold a reference, since freeing the ArrayMesh would take
## its RID out from under the instance.
var _chunks := {}
## Collision bodies of unloaded chunks, kept in the tree with their shapes
## cleared and handed straight back out when a chunk needs one. These are the
## nearest chunks, so they are also the ones that churn most as the player
## walks.
var _body_pool: Array[StaticBody3D] = []
const BODY_POOL_MAX := 64
## Stride of the mesher's height grid: the chunk plus a one column margin.
const HM_STRIDE := VoxelDefs.CHUNK_SIZE + 2
var _jobs := {} # -> task id
var _queue: Array[Vector2i] = []
var _done: Array = []
var _mutex := Mutex.new()
## The chunk the player stands in. The disc is only reconsidered when this
## moves, so walking a few metres costs nothing.
var _center := Vector2i(0x7fffffff, 0)
var _spawned := false
## Every mushroom light currently in the scene, so the day/night cycle can dim
## them all at once.
var _mushroom_lights: Array[OmniLight3D] = []
var _glow_level := 0.0
var _glow_time := 0.0


func _ready() -> void:
	# Props reparent themselves as they are picked up and put down, so they
	# cannot hold a NodePath to the world; they look it up by group instead.
	add_to_group("voxel_world")
	add_to_group("savable")
	gen = TerrainGen.new(world_seed)
	# Before anything is meshed: chunk jobs read the set from worker threads and
	# nothing may write to it once they are running.
	gen.structures = StructureSet.for_island(gen)
	_ensure_materials()
	_create_water()
	_create_far_terrain()
	_spawn_player()
	_update_center(true)


## The materials are created on demand because Atmosphere, which pushes the
## haze settings into them, is readied before this node.
func haze_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_material, _glow_material, _grass_material, _water_material,
		_far_material, _far_canopy_material]


## The materials of the streamed chunks.
func chunk_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_material, _glow_material, _grass_material]


## The two materials of the distant island: the ground and the canopy shell
## over its woods.
func far_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_far_material, _far_canopy_material]


func far_canopy_material() -> ShaderMaterial:
	_ensure_materials()
	return _far_canopy_material


## Where the eye is. Only the distant island's canopy still reads it, and it
## does so as a uniform rather than as the camera position the shader already
## has, so that the shadow pass drops exactly the crowns the colour pass does
## instead of casting shadows for geometry that was never drawn.
func set_eye(pos: Vector3) -> void:
	for m in haze_materials():
		m.set_shader_parameter("eye_pos", pos)


## Shows or hides the distant island. Under water it would only show as a false
## floor a few metres down.
func set_far_visible(on: bool) -> void:
	if _far != null:
		_far.visible = on


## The sea's material. Atmosphere hazes it over a longer range than the rest.
func sea_material() -> ShaderMaterial:
	_ensure_materials()
	return _water_material


## How brightly the mushrooms glow, 0 by day and 1 at night. Drives both the
## cap shader and the light the caps cast on their surroundings.
func set_glow_level(amount: float) -> void:
	_glow_level = amount
	_glow_material.set_shader_parameter("glow_amount", amount)


func _ensure_materials() -> void:
	if _material != null:
		return
	var lin := glow_color.srgb_to_linear()
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/voxel.gdshader")
	_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_material.set_shader_parameter("tint_scale", voxel_tint)

	_glow_material = ShaderMaterial.new()
	_glow_material.shader = load("res://shaders/voxel_glow.gdshader")
	_glow_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_glow_material.set_shader_parameter("tint_scale", voxel_tint)
	_glow_material.set_shader_parameter("glow_color", Vector3(lin.r, lin.g, lin.b))
	_glow_material.set_shader_parameter("glow_strength", glow_strength)
	_glow_material.set_shader_parameter("pulse_speed", glow_pulse_speed)
	_glow_material.set_shader_parameter("pulse_depth", glow_pulse_depth)

	_grass_material = ShaderMaterial.new()
	_grass_material.shader = load("res://shaders/voxel_grass.gdshader")
	_grass_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_grass_material.set_shader_parameter("tint_scale", voxel_tint)
	_grass_material.set_shader_parameter("wind_strength", wind_strength)
	_grass_material.set_shader_parameter("wind_speed", wind_speed)
	_water_material = ShaderMaterial.new()
	_water_material.shader = load("res://shaders/water.gdshader")
	var far_shader := load("res://shaders/far_terrain.gdshader")
	_far_material = ShaderMaterial.new()
	_far_material.shader = far_shader
	_far_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_far_canopy_material = ShaderMaterial.new()
	_far_canopy_material.shader = far_shader
	_push_canopy_band()


## The distant island wears a shell of canopy over its woods, which stands in
## for trees the streamed chunks are not there to grow. Where the chunks do
## reach it has to get out of the way, so it is dithered off over the outer
## `canopy_band` of the streamed disc - out on the plain, deep inside the mist.
func _push_canopy_band() -> void:
	_far_canopy_material.set_shader_parameter("canopy_begin",
		view_distance * (1.0 - canopy_band))
	_far_canopy_material.set_shader_parameter("canopy_end", view_distance)
	_far_canopy_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)


## The distant island is static, so it is built once on a worker thread and
## then left alone. Until it arrives the world simply ends in the haze, exactly
## as it did before.
func _create_far_terrain() -> void:
	_far = Node3D.new()
	_far.name = "FarTerrain"
	_far.visible = false
	add_child(_far)
	_dispatch_far_terrain()


func _dispatch_far_terrain() -> void:
	_far_dirty = false
	_far_job_water = water_level
	_mutex.lock()
	_far_built = false
	_far_tiles = []
	_mutex.unlock()
	_far_job = WorkerThreadPool.add_task(_far_job_run, false, "far_terrain")


## Repaints the distant island for the level the water now stands at. The land
## it carries has not changed - only which of it reads as ocean and how deep
## that ocean looks - but that is baked into the mesh, so the mesh is rebuilt.
##
## A job already in flight is left to finish rather than cancelled, and the
## rebuild is folded into the moment it lands.
func _rebuild_far_terrain() -> void:
	if _far_job >= 0:
		_far_dirty = true
		return
	_dispatch_far_terrain()


func _far_job_run() -> void:
	var tiles := FarTerrain.build(gen, _far_job_water, far_extent, far_step,
		far_drop)
	_mutex.lock()
	_far_tiles = tiles
	_far_built = true
	_mutex.unlock()


## Hands the finished tiles over on the main thread.
func _integrate_far_terrain() -> void:
	if _far_job < 0:
		return
	_mutex.lock()
	var done := _far_built
	var tiles: Array = _far_tiles
	_mutex.unlock()
	if not done:
		return
	WorkerThreadPool.wait_for_task_completion(_far_job)
	_far_job = -1
	_far_tiles = []
	if _far == null:
		return
	# A repaint replaces the whole mesh; on the first build there is nothing
	# hanging here yet and this does nothing.
	for old in _far.get_children():
		_far.remove_child(old)
		old.queue_free()
	for t in tiles:
		var mi := MeshInstance3D.new()
		mi.mesh = t["mesh"]
		mi.position = t["pos"]
		mi.set_surface_override_material(0, _far_material)
		var canopy: int = t["canopy_surface"]
		if canopy >= 0:
			mi.set_surface_override_material(canopy, _far_canopy_material)
		# Distant hills are what puts a mountain shadow across the island, but
		# a tile of open water is flat and at the waterline, so it can only
		# cost cascade time.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if t["has_land"] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_far.add_child(mi)
	# The tide moved again while this mesh was being painted, so the mesh that
	# just landed is already out of date; go round again rather than announcing
	# a level the water has left.
	if _far_dirty:
		_rebuild_far_terrain()
	else:
		tide_changed.emit(water_level)


## The sea is a single plane that is kept centred on the player. Its waves are
## a function of world position, so sliding it along produces no visible motion
## of its own; it is snapped to whole quads anyway so that the tessellation
## never crawls through the swell.
func _create_water() -> void:
	var subdiv := maxi(int(round(water_extent / water_quad)) - 1, 1)
	var plane := PlaneMesh.new()
	plane.size = Vector2(water_extent, water_extent)
	plane.subdivide_width = subdiv
	plane.subdivide_depth = subdiv
	_water = MeshInstance3D.new()
	_water.name = "Sea"
	_water.mesh = plane
	_water.material_override = _water_material
	# A flat plane has a zero height AABB, and the waves push it out of that.
	_water.extra_cull_margin = 2.0
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_water)
	_update_water()


## Drives the water towards its target. The land is untouched by this: the
## heightmap, the materials baked into the chunks and the collision under the
## player are all functions of the fixed datum, so a tide is only ever the
## surface moving over ground that was already there.
func _advance_tide(delta: float) -> void:
	if is_equal_approx(water_level, _tide_target):
		return
	water_level = move_toward(water_level, _tide_target, tide_speed * delta)
	# The painted ocean out past the mist is baked, so it is repainted once the
	# water comes to rest rather than on every frame of the climb. Until then
	# the far mesh is a little stale, which the haze covers.
	if is_equal_approx(water_level, _tide_target):
		water_level = _tide_target
		_rebuild_far_terrain()


## Sets the level the water eases towards, clamped to the tide's range.
## `immediate` snaps to it instead, which is what loading a save wants.
func set_tide(water_y: float, immediate := false) -> void:
	_tide_target = clampf(water_y, VoxelDefs.SEA_DATUM + tide_low,
		VoxelDefs.SEA_DATUM + tide_high)
	if immediate:
		water_level = _tide_target
		_rebuild_far_terrain()


## The tide target, so a HUD can show where the water is heading.
func tide_target() -> float:
	return _tide_target


## Height (m) of the water above the datum the land was shaped around.
func tide_offset() -> float:
	return water_level - VoxelDefs.SEA_DATUM


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	match (event as InputEventKey).keycode:
		KEY_PAGEUP:
			set_tide(_tide_target + tide_step)
		KEY_PAGEDOWN:
			set_tide(_tide_target - tide_step)
		KEY_HOME:
			set_tide(VoxelDefs.SEA_DATUM)
		KEY_T:
			_teleport_to_structures()


## Debug scaffolding, same family as the tide keys. The shallows are only ever
## at the coast, so the drowned ruin stands a few hundred metres from a spawn
## that is by construction up on the island's dome; walking there to check a
## change is not iteration.
func _teleport_to_structures() -> void:
	if gen == null or gen.structures == null or gen.structures.size() == 0:
		return
	var first := gen.structures.all()[0]
	var x := float(first["x"]) * VoxelDefs.VOXEL_SIZE
	var z := float(first["z"]) * VoxelDefs.VOXEL_SIZE
	# Stood back a little and above the ground, so the arrival looks at the
	# ruin rather than inside a wall.
	var back := Vector2(x, z).normalized() * 6.0
	x += back.x
	z += back.y
	var p := get_node_or_null(player_path) as Node3D
	if p == null:
		return
	p.global_position = Vector3(x, gen.ground_y(x, z) + 2.0, z)
	_update_center(true)


func _update_water() -> void:
	if _water == null:
		return
	var p := get_node_or_null(player_path)
	var pos := Vector3.ZERO if p == null else (p as Node3D).global_position
	var step: float = maxf(water_extent / float(maxi(_water.mesh.subdivide_width + 1, 1)), 0.01)
	_water.global_position = Vector3(
		snappedf(pos.x, step), water_level, snappedf(pos.z, step))


func _exit_tree() -> void:
	for id in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_jobs.clear()
	if _far_job >= 0:
		WorkerThreadPool.wait_for_task_completion(_far_job)
		_far_job = -1
	# Render instances live in the server, not in the tree, so nothing frees
	# them on our behalf, and the meshes they point at are only held by the
	# chunk entries.
	for info in _chunks.values():
		_drop_chunk(info)
	_chunks.clear()
	_body_pool.clear()
	_mushroom_lights.clear()


func _spawn_player() -> void:
	spawn_xz = _dry_spawn_point()
	var p := get_node_or_null(player_path)
	if p == null:
		return
	var spot := spawn_xz
	p.global_position = Vector3(spot.x, gen.ground_y(spot.x, spot.y) + 2.0, spot.y)


## The island's dome is always above water, but the hills on top of it can dip,
## so the spawn walks outwards in a spiral until it finds solid dry ground.
func _dry_spawn_point() -> Vector2:
	var min_y := water_level + 0.6
	if gen.height_meters(0.0, 0.0) >= min_y:
		return Vector2.ZERO
	for ring in range(1, 25):
		var r := float(ring) * 8.0
		for i in 12:
			var a := TAU * float(i) / 12.0
			var c := Vector2(cos(a) * r, sin(a) * r)
			if gen.height_meters(c.x, c.y) >= min_y:
				return c
	return Vector2.ZERO


func _process(delta: float) -> void:
	_advance_tide(delta)
	_update_center(false)
	_update_water()
	_integrate_far_terrain()
	_pump_jobs()
	_integrate_results()
	_update_lights(delta)


## Keeps the point lights in step with the caps: same day/night level, and the
## same pulse, so a mushroom and the pool of light under it breathe together.
func _update_lights(delta: float) -> void:
	_glow_time += delta
	var eye := Vector3.ZERO
	var p := get_node_or_null(player_path)
	if p != null:
		eye = (p as Node3D).global_position
	# A chunk only gains lights once it comes within light_range, so without a
	# fade a whole grove would light up the instant it crossed that line. Fade
	# over the last stretch before the boundary and the switch is invisible.
	var far: float = minf(glow_light_distance, light_range)
	var near := far * 0.55
	var alive: Array[OmniLight3D] = []
	for l in _mushroom_lights:
		if not is_instance_valid(l):
			continue
		alive.append(l)
		var pulse := 1.0 + glow_pulse_depth * sin(
			_glow_time * glow_pulse_speed + l.get_meta("phase", 0.0) * TAU)
		var reach := 1.0 - smoothstep(near, far, l.global_position.distance_to(eye))
		var e: float = l.get_meta("base_energy", 1.0) * glow_light_energy * _glow_level * pulse * reach
		l.light_energy = e
		l.visible = e > 0.005
	_mushroom_lights = alive


## The disc is only reconsidered when the player crosses a chunk boundary, so
## walking a few metres costs nothing.
func _update_center(force: bool) -> void:
	var p := _eye_xz()
	var m := VoxelDefs.CHUNK_METERS
	var c := Vector2i(int(floor(p.x / m)), int(floor(p.y / m)))
	if c == _center and not force:
		return
	_center = c
	_rebuild_queue()
	_unload_far()


func _eye_xz() -> Vector2:
	var p := get_node_or_null(player_path)
	if p == null:
		return Vector2.ZERO
	var pos := (p as Node3D).global_position
	return Vector2(pos.x, pos.z)


## Distance from the player to the nearest point of a chunk; 0 while standing
## in it.
func _chunk_near(key: Vector2i, p: Vector2) -> float:
	var m := VoxelDefs.CHUNK_METERS
	var x0 := float(key.x) * m
	var z0 := float(key.y) * m
	var dx := maxf(maxf(x0 - p.x, p.x - (x0 + m)), 0.0)
	var dz := maxf(maxf(z0 - p.y, p.y - (z0 + m)), 0.0)
	return sqrt(dx * dx + dz * dz)


func _rebuild_queue() -> void:
	var p := _eye_xz()
	var m := VoxelDefs.CHUNK_METERS
	# Entries are [distance, key]. The distance is the one already worked out to
	# decide whether the chunk is wanted at all, so sorting on it is free; a
	# comparator that measured the chunks itself would be thousands of square
	# roots per boundary the player crosses.
	var wanted: Array = []
	var cx0 := int(floor((p.x - view_distance) / m))
	var cx1 := int(floor((p.x + view_distance) / m))
	var cz0 := int(floor((p.y - view_distance) / m))
	var cz1 := int(floor((p.y + view_distance) / m))
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var key := Vector2i(cx, cz)
			var near := _chunk_near(key, p)
			if near > view_distance:
				continue
			if _jobs.has(key):
				continue
			if _chunks.has(key):
				# upgrade a chunk that came into the light / collision range
				var info: Dictionary = _chunks[key]
				if (_wants_lights(near) and not info["lit"]) or (_wants_collision(near) and not info["collision"]):
					wanted.append([near, key])
				continue
			wanted.append([near, key])
	# Nearest first, so the ground the player is standing on is there before the
	# far edge of the disc is.
	wanted.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_queue.clear()
	_queue.resize(wanted.size())
	for i in wanted.size():
		_queue[i] = wanted[i][1]


## Mushroom lights and collision belong to the ground the player is standing on
## rather than to the view, so they are only built for the chunks close enough
## to matter. Everything else a chunk is made of, grass included, comes with the
## chunk itself.
func _wants_lights(near: float) -> bool:
	return near <= light_range


func _wants_collision(near: float) -> bool:
	return near <= collision_range


func _pump_jobs() -> void:
	var p := _eye_xz()
	while _jobs.size() < max_parallel_jobs and not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if _jobs.has(key):
			continue
		var near := _chunk_near(key, p)
		var lit := _wants_lights(near)
		var coll := _wants_collision(near)
		var id := WorkerThreadPool.add_task(_job.bind(key, lit, coll), false, "voxel_chunk")
		_jobs[key] = id


func _job(key: Vector2i, lit: bool, coll: bool) -> void:
	var res := ChunkBuilder.build(gen, key.x, key.y, lit, coll,
		heightmap_collision)
	res["lit"] = lit
	res["collision"] = coll
	_mutex.lock()
	_done.append(res)
	_mutex.unlock()


func _integrate_results() -> void:
	var batch: Array = []
	_mutex.lock()
	var n: int = mini(chunks_per_frame, _done.size())
	for i in n:
		batch.append(_done.pop_front())
	_mutex.unlock()

	var p := _eye_xz()
	for res in batch:
		var key := Vector2i(res["cx"], res["cz"])
		if _jobs.has(key):
			WorkerThreadPool.wait_for_task_completion(_jobs[key])
			_jobs.erase(key)
		if _chunks.has(key):
			_drop_chunk(_chunks[key])
			_chunks.erase(key)
		if _chunk_near(key, p) > view_distance:
			continue
		_chunks[key] = _spawn_chunk(key, res)

	if not _spawned and _jobs.is_empty() and _queue.is_empty():
		_spawned = true
		world_ready.emit()


func _spawn_chunk(key: Vector2i, res: Dictionary) -> Dictionary:
	var m := VoxelDefs.CHUNK_METERS
	var origin := Vector3(float(key.x) * m, 0.0, float(key.y) * m)
	var lights: Array[OmniLight3D] = []
	var shadows := _chunk_near(key, _eye_xz()) <= shadow_range
	var info := {
		"inst": RID(),
		"mesh": null,
		"body": null,
		"lights": lights,
		"lit": res["lit"],
		"collision": res["collision"],
		"shadows": shadows,
	}

	var mesh: ArrayMesh = res["mesh"]
	if mesh != null:
		var inst := RenderingServer.instance_create2(mesh.get_rid(), get_world_3d().scenario)
		RenderingServer.instance_set_transform(inst, Transform3D(Basis(), origin))
		var sway_surface: int = res.get("sway_surface", -1)
		var glow_surface: int = res.get("glow_surface", -1)
		for s in mesh.get_surface_count():
			var mat := _material
			if s == sway_surface:
				mat = _grass_material
			elif s == glow_surface:
				mat = _glow_material
			RenderingServer.instance_set_surface_override_material(inst, s, mat.get_rid())
		if sway_surface >= 0:
			# the wind pushes grass a few centimetres outside the baked AABB
			RenderingServer.instance_set_extra_visibility_margin(inst, 0.25)
		RenderingServer.instance_geometry_set_cast_shadows_setting(inst,
			RenderingServer.SHADOW_CASTING_SETTING_ON if shadows
			else RenderingServer.SHADOW_CASTING_SETTING_OFF)
		info["inst"] = inst
		# The instance holds only the mesh's RID, so something has to keep the
		# ArrayMesh itself alive for as long as the instance is up.
		info["mesh"] = mesh

	var heights = res.get("heights")
	var soup: ConcavePolygonShape3D = res["shape"]
	if heights != null or soup != null:
		var body := _acquire_body()
		body.position = origin
		var ground := body.get_child(0) as CollisionShape3D
		if heights != null:
			var hs := HeightMapShape3D.new()
			hs.map_width = HM_STRIDE
			hs.map_depth = HM_STRIDE
			hs.map_data = heights
			ground.shape = hs
			# The samples are the columns' centres and the grid carries a
			# margin column on each side, so it runs from -0.5 to CS + 0.5
			# voxels. Godot centres a heightmap on its own origin, hence the
			# half chunk offset; the data is in voxels, hence the scale.
			var vs := VoxelDefs.VOXEL_SIZE
			ground.position = Vector3(32.0 * vs, 0.0, 32.0 * vs)
			ground.scale = Vector3(vs, vs, vs)
			ground.disabled = false
		var feats := body.get_child(1) as CollisionShape3D
		if soup != null:
			feats.shape = soup
			feats.disabled = false
		info["body"] = body

	for spec in res.get("lights", []):
		var light := OmniLight3D.new()
		# No chunk node to parent to any more, so the light is placed straight
		# into world space.
		light.position = origin + spec["pos"]
		light.omni_range = spec["radius"]
		light.light_color = glow_color
		# Shadows would cost far more than they add for a soft glow that sits
		# under a cap and mostly lights the ground right below it.
		light.shadow_enabled = false
		light.light_energy = 0.0
		light.visible = false
		light.set_meta("base_energy", spec["energy"])
		light.set_meta("phase", spec["phase"])
		add_child(light)
		lights.append(light)
		_mushroom_lights.append(light)
	return info


## Tears a chunk down: the render instance goes back to the server, the
## collision body to the pool, the lights to the tree.
func _drop_chunk(info: Dictionary) -> void:
	var inst: RID = info["inst"]
	if inst.is_valid():
		RenderingServer.free_rid(inst)
	info["inst"] = RID()
	info["mesh"] = null
	var body: StaticBody3D = info["body"]
	if body != null and is_instance_valid(body):
		_release_body(body)
	info["body"] = null
	for l in info["lights"]:
		if is_instance_valid(l):
			l.queue_free()
	info["lights"] = []


## A body with its two shape slots ready: the ground heightmap and the feature
## triangle soup.
func _acquire_body() -> StaticBody3D:
	if not _body_pool.is_empty():
		return _body_pool.pop_back()
	var body := StaticBody3D.new()
	var ground := CollisionShape3D.new()
	ground.name = "Ground"
	ground.disabled = true
	body.add_child(ground)
	var feats := CollisionShape3D.new()
	feats.name = "Features"
	feats.disabled = true
	body.add_child(feats)
	add_child(body)
	return body


func _release_body(body: StaticBody3D) -> void:
	for c in body.get_children():
		var cs := c as CollisionShape3D
		cs.disabled = true
		cs.shape = null
		cs.position = Vector3.ZERO
		cs.scale = Vector3.ONE
	if _body_pool.size() < BODY_POOL_MAX:
		_body_pool.append(body)
	else:
		body.queue_free()


## Runs over the loaded chunks whenever the player crosses a chunk boundary:
## drops the ones that have fallen out of the disc, with one chunk of slack so
## that walking back and forth over the edge does not rebuild the same chunk
## again and again, and keeps the rest in step with `shadow_range`.
func _unload_far() -> void:
	var p := _eye_xz()
	var slack := VoxelDefs.CHUNK_METERS
	var drop: Array[Vector2i] = []
	for key in _chunks.keys():
		var near := _chunk_near(key, p)
		if near > view_distance + slack:
			drop.append(key)
			continue
		_update_shadows(_chunks[key], near)
	for key in drop:
		_drop_chunk(_chunks[key])
		_chunks.erase(key)


## A chunk casts into the sun's cascades while it is inside `shadow_range`, and
## gains and loses that as the player walks. The switch has a chunk of slack on
## the far side, so one sitting on the line does not flip every time the player
## steps over a boundary.
func _update_shadows(info: Dictionary, near: float) -> void:
	var inst: RID = info["inst"]
	if not inst.is_valid():
		return
	var on: bool = info["shadows"]
	if near <= shadow_range:
		on = true
	elif near > shadow_range + VoxelDefs.CHUNK_METERS:
		on = false
	if on == info["shadows"]:
		return
	info["shadows"] = on
	RenderingServer.instance_geometry_set_cast_shadows_setting(inst,
		RenderingServer.SHADOW_CASTING_SETTING_ON if on
		else RenderingServer.SHADOW_CASTING_SETTING_OFF)
func biome_name_at(pos: Vector3) -> String:
	var g := gen.height_meters(pos.x, pos.z)
	if g < water_level - 0.05:
		return "Ocean"
	if g < gen.beach_top(pos.x, pos.z):
		return "Beach"
	if g >= gen.snow_line(pos.x, pos.z):
		return "Summit"
	if g >= gen.rock_line(pos.x, pos.z):
		return "Mountains"
	return "Desert" if gen.is_desert(pos.x, pos.z) else "Grassland"


func loaded_chunks() -> int:
	return _chunks.size()


# --------------------------------------------------------------------------
# saving
# --------------------------------------------------------------------------

## Nothing about the island is saved: it is a pure function of `world_seed`,
## which SaveGame checks separately. Only what the player moved.
func save_state() -> Dictionary:
	# Only where the water is heading. A save taken while the tide is still
	# coming in restores it already arrived: a load is not the moment to
	# resume an animation, and honouring a half finished one would leave the
	# far terrain painted for a level the water is not at.
	return {"tide_target": _tide_target, "indoors": indoors}


func load_state(d: Dictionary) -> void:
	indoors = bool(d.get("indoors", false))
	# Straight to the level rather than easing to it: a load is not a tide
	# coming in, and the far terrain has to be repainted for where the water
	# actually is before the player sees anything.
	set_tide(float(d.get("tide_target", VoxelDefs.SEA_DATUM)), true)


## Before anything that depends on the tide or on being indoors.
func save_priority() -> int:
	return 0
