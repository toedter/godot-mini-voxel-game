class_name VoxelWorld
extends Node3D

## Streams voxel chunks around the player on worker threads.

signal world_ready

@export var world_seed: int = 1337
## Radius (in chunks) of loaded terrain. 1 chunk = 6.4 m.
@export var view_distance: int = 7
## Chunks within this radius also get grass tufts / pebbles.
@export var detail_distance: int = 3
## Chunks within this radius get a collision shape.
@export var collision_distance: int = 3
@export var max_parallel_jobs: int = 6
@export var chunks_per_frame: int = 2
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
## inside detail_distance, since that is where the lights are created.
@export_range(4.0, 40.0, 0.5) var glow_light_distance: float = 17.0
## Side length (m) of the sea plane that follows the player. Only has to reach
## past the point where the haze has closed in completely; past it the distant
## island mesh paints the rest of the sea.
@export_range(40.0, 1200.0, 10.0) var water_extent: float = 560.0
## Size (m) of one quad of the sea plane. Smaller means the swell is carried by
## the geometry rather than only by the shading. The wave normals are worked out
## per fragment, so this mostly decides how well the swell holds its shape
## against the sky rather than how detailed the water looks.
@export_range(0.5, 8.0, 0.1) var water_quad: float = 2.5
## Half size (m) of the coarse mesh of the whole island. Has to reach past the
## point where the haze closes in from a mountain top, otherwise the world ends
## in a visible edge up there.
@export_range(200.0, 2000.0, 10.0) var far_extent: float = 1300.0
## Size (m) of one cell of that mesh. Only the island is meshed this finely;
## open water is folded down to one quad per 8x8 cells, which is what pays for
## it. Raise it for a cheaper build and a smaller mesh (XR).
@export_range(1.0, 25.6, 0.1) var far_step: float = 2.0
## How far (m) the coarse mesh is sunk below the real surface, so that it can
## never poke through the streamed chunks in a hollow. Steep ground is sunk
## further; see FarTerrain.
@export_range(0.0, 4.0, 0.1) var far_drop: float = 0.5
@export var player_path: NodePath = ^"../Player"

var gen: TerrainGen

var _material: ShaderMaterial
var _grass_material: ShaderMaterial
var _glow_material: ShaderMaterial
var _water_material: ShaderMaterial
var _far_material: ShaderMaterial
var _far_canopy_material: ShaderMaterial
var _water: MeshInstance3D
var _far: Node3D
var _far_job: int = -1
var _far_tiles: Array = []
var _far_built := false
var _chunks := {} # Vector2i -> Dictionary {node, detail, collision}
var _jobs := {} # Vector2i -> task id
var _queue: Array[Vector2i] = []
var _done: Array = []
var _mutex := Mutex.new()
var _center := Vector2i(0x7fffffff, 0)
var _spawned := false
## Every mushroom light currently in the scene, so the day/night cycle can dim
## them all at once.
var _mushroom_lights: Array[OmniLight3D] = []
var _glow_level := 0.0
var _glow_time := 0.0


func _ready() -> void:
	gen = TerrainGen.new(world_seed)
	_ensure_materials()
	_create_water()
	_create_far_terrain()
	_spawn_player()
	_update_center(true)


## The materials are created on demand because Atmosphere, which pushes the
## haze settings into them, is readied before this node.
func haze_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_material, _grass_material, _glow_material, _water_material,
		_far_material, _far_canopy_material]


## The materials of the streamed chunks. These are the ones that dissolve into
## the distant island at the edge of the loaded area.
func chunk_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_material, _grass_material, _glow_material]


## The two materials of the distant island: the ground and the canopy shell
## over its woods. Atmosphere hands the canopy the band it has to fade in over,
## which is the same one the chunks dissolve across.
func far_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_far_material, _far_canopy_material]


func far_canopy_material() -> ShaderMaterial:
	_ensure_materials()
	return _far_canopy_material


## Where the eye is, for the canopy handover. A uniform rather than the camera
## position the shader already has, so that the shadow pass drops the same
## crowns the colour pass does.
func set_far_eye(pos: Vector3) -> void:
	for m in far_materials():
		m.set_shader_parameter("eye_pos", pos)


## Shows or hides the distant island. Under water it would only show as a false
## floor a few metres down.
func set_far_visible(on: bool) -> void:
	if _far != null:
		_far.visible = on


## The material the glowing mushroom caps are drawn with. Atmosphere drives its
## glow level from the time of day.
func glow_material() -> ShaderMaterial:
	_ensure_materials()
	return _glow_material


## The sea's material. Atmosphere hazes it over a longer range than the rest.
func sea_material() -> ShaderMaterial:
	_ensure_materials()
	return _water_material


## How brightly the mushrooms glow, 0 by day and 1 at night. Drives both the
## cap shader and the light the caps cast on their surroundings.
func set_glow_level(amount: float) -> void:
	_glow_level = amount
	glow_material().set_shader_parameter("glow_amount", amount)


func _ensure_materials() -> void:
	if _material != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/voxel.gdshader")
	_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_material.set_shader_parameter("tint_scale", voxel_tint)
	_grass_material = ShaderMaterial.new()
	_grass_material.shader = load("res://shaders/voxel_grass.gdshader")
	_grass_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_grass_material.set_shader_parameter("tint_scale", voxel_tint)
	_grass_material.set_shader_parameter("wind_strength", wind_strength)
	_grass_material.set_shader_parameter("wind_speed", wind_speed)
	_glow_material = ShaderMaterial.new()
	_glow_material.shader = load("res://shaders/voxel_glow.gdshader")
	_glow_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_glow_material.set_shader_parameter("tint_scale", voxel_tint)
	var lin := glow_color.srgb_to_linear()
	_glow_material.set_shader_parameter("glow_color", Vector3(lin.r, lin.g, lin.b))
	_glow_material.set_shader_parameter("glow_strength", glow_strength)
	_glow_material.set_shader_parameter("pulse_speed", glow_pulse_speed)
	_glow_material.set_shader_parameter("pulse_depth", glow_pulse_depth)
	_water_material = ShaderMaterial.new()
	_water_material.shader = load("res://shaders/water.gdshader")
	var far_shader := load("res://shaders/far_terrain.gdshader")
	_far_material = ShaderMaterial.new()
	_far_material.shader = far_shader
	_far_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)
	_far_canopy_material = ShaderMaterial.new()
	_far_canopy_material.shader = far_shader
	_far_canopy_material.set_shader_parameter("voxel_size", VoxelDefs.VOXEL_SIZE)


## The distant island is static, so it is built once on a worker thread and
## then left alone. Until it arrives the world simply ends in the haze, exactly
## as it did before.
func _create_far_terrain() -> void:
	_far = Node3D.new()
	_far.name = "FarTerrain"
	_far.visible = false
	add_child(_far)
	_far_job = WorkerThreadPool.add_task(_far_job_run, false, "far_terrain")


func _far_job_run() -> void:
	var tiles := FarTerrain.build(gen, far_extent, far_step, far_drop)
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


func _update_water() -> void:
	if _water == null:
		return
	var p := get_node_or_null(player_path)
	var pos := Vector3.ZERO if p == null else (p as Node3D).global_position
	var step: float = maxf(water_extent / float(maxi(_water.mesh.subdivide_width + 1, 1)), 0.01)
	_water.global_position = Vector3(
		snappedf(pos.x, step), VoxelDefs.SEA_LEVEL, snappedf(pos.z, step))


func _exit_tree() -> void:
	for id in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_jobs.clear()
	if _far_job >= 0:
		WorkerThreadPool.wait_for_task_completion(_far_job)
		_far_job = -1


func _spawn_player() -> void:
	var p := get_node_or_null(player_path)
	if p == null:
		return
	var spot := _dry_spawn_point()
	p.global_position = Vector3(spot.x, gen.ground_y(spot.x, spot.y) + 2.0, spot.y)


## The island's dome is always above water, but the hills on top of it can dip,
## so the spawn walks outwards in a spiral until it finds solid dry ground.
func _dry_spawn_point() -> Vector2:
	var min_y := VoxelDefs.SEA_LEVEL + 0.6
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
	# A chunk only gains lights once it comes within detail_distance, so without
	# a fade a whole grove would light up the instant it crossed that line.
	# Fade over the last chunk before the boundary and the switch is invisible.
	var far: float = minf(glow_light_distance, float(detail_distance) * VoxelDefs.CHUNK_METERS)
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


func player_chunk() -> Vector2i:
	var p := get_node_or_null(player_path)
	var pos := Vector3.ZERO if p == null else (p as Node3D).global_position
	return Vector2i(
		int(floor(pos.x / VoxelDefs.CHUNK_METERS)),
		int(floor(pos.z / VoxelDefs.CHUNK_METERS)))


func _update_center(force: bool) -> void:
	var c := player_chunk()
	if not force and c == _center:
		return
	_center = c
	_rebuild_queue()
	_unload_far()


func _rebuild_queue() -> void:
	var wanted: Array[Vector2i] = []
	for dz in range(-view_distance, view_distance + 1):
		for dx in range(-view_distance, view_distance + 1):
			if dx * dx + dz * dz > view_distance * view_distance:
				continue
			var c := _center + Vector2i(dx, dz)
			if _jobs.has(c):
				continue
			if _chunks.has(c):
				# upgrade a chunk that came into the detail / collision radius
				var info: Dictionary = _chunks[c]
				var d := _chebyshev(c)
				var need_detail := d <= detail_distance
				var need_col := d <= collision_distance
				if (need_detail and not info["detail"]) or (need_col and not info["collision"]):
					wanted.append(c)
				continue
			wanted.append(c)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - _center).length_squared() < (b - _center).length_squared())
	_queue = wanted


func _chebyshev(c: Vector2i) -> int:
	return maxi(absi(c.x - _center.x), absi(c.y - _center.y))


func _pump_jobs() -> void:
	while _jobs.size() < max_parallel_jobs and not _queue.is_empty():
		var c: Vector2i = _queue.pop_front()
		if _jobs.has(c):
			continue
		var d := _chebyshev(c)
		var detail := d <= detail_distance
		var coll := d <= collision_distance
		var id := WorkerThreadPool.add_task(_job.bind(c, detail, coll), false, "voxel_chunk")
		_jobs[c] = id


func _job(c: Vector2i, detail: bool, coll: bool) -> void:
	var res := ChunkBuilder.build(gen, c.x, c.y, detail, coll)
	res["detail"] = detail
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

	for res in batch:
		var c := Vector2i(res["cx"], res["cz"])
		if _jobs.has(c):
			WorkerThreadPool.wait_for_task_completion(_jobs[c])
			_jobs.erase(c)
		if _chunks.has(c):
			var old: Dictionary = _chunks[c]
			if is_instance_valid(old["node"]):
				old["node"].queue_free()
			_chunks.erase(c)
		if _chebyshev(c) > view_distance:
			continue
		var node := _spawn_chunk(c, res)
		_chunks[c] = {"node": node, "detail": res["detail"], "collision": res["collision"]}

	if not _spawned and _jobs.is_empty() and _queue.is_empty():
		_spawned = true
		world_ready.emit()


func _spawn_chunk(c: Vector2i, res: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [c.x, c.y]
	root.position = Vector3(c.x * VoxelDefs.CHUNK_METERS, 0.0, c.y * VoxelDefs.CHUNK_METERS)
	add_child(root)
	if res["mesh"] != null:
		var mi := MeshInstance3D.new()
		var mesh: ArrayMesh = res["mesh"]
		mi.mesh = mesh
		var sway_surface: int = res.get("sway_surface", -1)
		var glow_surface: int = res.get("glow_surface", -1)
		for s in mesh.get_surface_count():
			var m := _material
			if s == sway_surface:
				m = _grass_material
			elif s == glow_surface:
				m = _glow_material
			mi.set_surface_override_material(s, m)
		if sway_surface >= 0:
			# the wind pushes grass a few centimetres outside the baked AABB
			mi.extra_cull_margin = 0.25
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mi)
	if res["shape"] != null:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = res["shape"]
		body.add_child(cs)
		root.add_child(body)
	for spec in res.get("lights", []):
		var light := OmniLight3D.new()
		light.position = spec["pos"]
		light.omni_range = spec["radius"]
		light.light_color = glow_color
		# Shadows would cost far more than they add for a soft glow that sits
		# under a cap and mostly lights the ground right below it.
		light.shadow_enabled = false
		light.light_energy = 0.0
		light.visible = false
		light.set_meta("base_energy", spec["energy"])
		light.set_meta("phase", spec["phase"])
		root.add_child(light)
		_mushroom_lights.append(light)
	return root


func _unload_far() -> void:
	var drop: Array[Vector2i] = []
	for c in _chunks.keys():
		if _chebyshev(c) > view_distance + 1:
			drop.append(c)
	for c in drop:
		var info: Dictionary = _chunks[c]
		if is_instance_valid(info["node"]):
			info["node"].queue_free()
		_chunks.erase(c)


func biome_name_at(pos: Vector3) -> String:
	var g := gen.height_meters(pos.x, pos.z)
	if g < VoxelDefs.SEA_LEVEL - 0.05:
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
