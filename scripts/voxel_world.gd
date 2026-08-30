class_name VoxelWorld
extends Node3D

## Streams voxel chunks around the player on worker threads, at several levels
## of detail.
##
## Level 0 is the world at full 10 cm voxels in 6.4 m chunks. Every level above
## it doubles the voxel size and so the ground one chunk covers, and is streamed
## as a ring further out: 20 cm voxels, then 40, then 80. ChunkBuilder meshes
## them all with the same code, so the distance is made of the same world at a
## coarser grain - the same hills, the same trees, the same mushrooms - rather
## than of something else that has to be faded in.
##
## Neighbouring rings overlap by `lod_band` metres and dither into one another
## there; see voxel_common.gdshaderinc for how that is made seamless.

signal world_ready

@export var world_seed: int = 1337
## How far (m) each level of detail reaches. Entry i is streamed with voxels of
## 10 cm * 2^i, so the last entry decides where the chunks stop and the coarse
## island mesh takes over.
##
## Each range should be double the one before it. That is what makes a voxel the
## same size on screen at every level - and, because a ring then covers four
## times the area with voxels four times as wide, what makes every ring cost
## about the same as the one inside it. Ranges that grow faster than doubling
## get expensive very quickly: the outermost ring is nearly all of the area.
@export var lod_ranges: PackedFloat32Array = PackedFloat32Array([24.0, 48.0, 96.0, 192.0, 384.0])
## How much of a level's reach is given over to handing on to the next one, as a
## fraction of that reach. Both levels are drawn across the overlap, so it costs
## geometry; a fraction rather than a fixed distance keeps the handover the same
## size on screen wherever it happens.
@export_range(0.05, 0.6, 0.01) var lod_band: float = 0.25
## Chunks within this radius (m) also get grass tufts / pebbles. Level 0 only.
@export_range(0.0, 100.0, 1.0) var detail_range: float = 19.2
## Chunks within this radius (m) get a collision shape. Level 0 only.
@export_range(0.0, 100.0, 1.0) var collision_range: float = 19.2
@export var max_parallel_jobs: int = 6
@export var chunks_per_frame: int = 4
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
## inside detail_range, since that is where the lights are created.
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
## it. Real voxels now reach a few hundred metres, so this only has to serve the
## view from a summit and can be coarser than it once was.
@export_range(1.0, 25.6, 0.1) var far_step: float = 3.0
## How far (m) the coarse mesh is sunk below the real surface, so that it can
## never poke through the streamed chunks in a hollow. Steep ground is sunk
## further; see FarTerrain.
@export_range(0.0, 4.0, 0.1) var far_drop: float = 0.5
@export var player_path: NodePath = ^"../Player"

var gen: TerrainGen

## One static and one glowing-mushroom material per level of detail: each level
## needs its own handover distances, and those live in the material.
var _materials: Array[ShaderMaterial] = []
var _glow_materials: Array[ShaderMaterial] = []
## The wind swayed grass has no per level copy because tufts are level 0 only.
var _grass_material: ShaderMaterial
var _water_material: ShaderMaterial
var _far_material: ShaderMaterial
var _far_canopy_material: ShaderMaterial
var _water: MeshInstance3D
var _far: Node3D
var _far_job: int = -1
var _far_tiles: Array = []
var _far_built := false
## All keyed by Vector3i(chunk x, chunk z, level).
var _chunks := {} # -> Dictionary {node, detail, collision}
var _jobs := {} # -> task id
var _queue: Array[Vector3i] = []
var _done: Array = []
var _mutex := Mutex.new()
## The chunk the player stands in, per level. A level is only requeued when its
## own centre moves, so walking one 6.4 m chunk does not disturb the 51.2 m ring.
var _centers: Array[Vector2i] = []
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
	var all: Array[ShaderMaterial] = [_grass_material, _water_material,
		_far_material, _far_canopy_material]
	all.append_array(_materials)
	all.append_array(_glow_materials)
	return all


## The materials of the streamed chunks, every level of them.
func chunk_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	var all: Array[ShaderMaterial] = [_grass_material]
	all.append_array(_materials)
	all.append_array(_glow_materials)
	return all


## The two materials of the distant island: the ground and the canopy shell
## over its woods. Atmosphere hands the canopy the band it has to fade in over,
## which is the same one the outermost chunk level fades out across.
func far_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_far_material, _far_canopy_material]


func far_canopy_material() -> ShaderMaterial:
	_ensure_materials()
	return _far_canopy_material


## Where the eye is, for every handover in the world. A uniform rather than the
## camera position the shader already has, so that the shadow pass drops exactly
## the voxels the colour pass does instead of casting shadows for geometry that
## was never drawn.
func set_eye(pos: Vector3) -> void:
	for m in haze_materials():
		m.set_shader_parameter("eye_pos", pos)


## Shows or hides the distant island. Under water it would only show as a false
## floor a few metres down.
func set_far_visible(on: bool) -> void:
	if _far != null:
		_far.visible = on


## How many levels of detail are streamed.
func lod_count() -> int:
	return maxi(lod_ranges.size(), 1)


## Side length (m) of one chunk of a level. Always CS columns across, so the
## coarser the voxels the more ground a chunk covers.
func chunk_meters(lod: int) -> float:
	return VoxelDefs.CHUNK_METERS * float(1 << lod)


## Where a level starts and stops being drawn. A level reaches inwards past the
## end of the one below it by `lod_band`, and the two dither into one another
## across that overlap.
func lod_inner(lod: int) -> float:
	return 0.0 if lod <= 0 else lod_outer(lod - 1) * (1.0 - lod_band)


func lod_outer(lod: int) -> float:
	return lod_ranges[clampi(lod, 0, lod_ranges.size() - 1)]


## Size (m) of the hash cell the handover between level `lod` and the next one
## up is dithered with. Both sides of a band have to use the same value or their
## holes stop lining up; it grows with the level so that a band always looks
## about the same size on screen, however far away it is.
func lod_cell(lod: int) -> float:
	return VoxelDefs.VOXEL_SIZE * float(1 << lod) * 4.0


## The sea's material. Atmosphere hazes it over a longer range than the rest.
func sea_material() -> ShaderMaterial:
	_ensure_materials()
	return _water_material


## How brightly the mushrooms glow, 0 by day and 1 at night. Drives both the
## cap shader and the light the caps cast on their surroundings.
func set_glow_level(amount: float) -> void:
	_glow_level = amount
	for m in _glow_materials:
		m.set_shader_parameter("glow_amount", amount)


func _ensure_materials() -> void:
	if not _materials.is_empty():
		return
	var voxel_shader := load("res://shaders/voxel.gdshader")
	var glow_shader := load("res://shaders/voxel_glow.gdshader")
	var lin := glow_color.srgb_to_linear()
	for lod in lod_count():
		# `voxel_size` is what the per voxel brightness variation is keyed to, so
		# it has to be this level's voxel and not the finest one, or a coarse
		# chunk would be speckled at a scale its geometry does not have.
		var vs := VoxelDefs.VOXEL_SIZE * float(1 << lod)
		var m := ShaderMaterial.new()
		m.shader = voxel_shader
		m.set_shader_parameter("voxel_size", vs)
		m.set_shader_parameter("tint_scale", voxel_tint)
		_materials.append(m)

		var g := ShaderMaterial.new()
		g.shader = glow_shader
		g.set_shader_parameter("voxel_size", vs)
		g.set_shader_parameter("tint_scale", voxel_tint)
		g.set_shader_parameter("glow_color", Vector3(lin.r, lin.g, lin.b))
		g.set_shader_parameter("glow_strength", glow_strength)
		g.set_shader_parameter("pulse_speed", glow_pulse_speed)
		g.set_shader_parameter("pulse_depth", glow_pulse_depth)
		_glow_materials.append(g)

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
	_push_lod_bands()


## Hands every level the two bands it shares with its neighbours: the one it
## fades in across (where it is the coarser of the pair) and the one it fades
## out across (where it is the finer). The values of a band are pushed to both
## of the levels that meet in it, which is what lets their dither interlock -
## see voxel_common.gdshaderinc.
##
## Level 0 never fades in: it is solid from the eye outwards. The last level
## fades out into the coarse island mesh, which is opaque behind it and so needs
## no complementary half.
func _push_lod_bands() -> void:
	var last := lod_count() - 1
	for lod in lod_count():
		var out_begin := lod_outer(lod) * (1.0 - lod_band)
		var out_end := lod_outer(lod)
		var out_cell := lod_cell(lod)
		var in_begin := -1.0
		var in_end := -1.0
		var in_cell := 0.4
		if lod > 0:
			in_begin = lod_inner(lod)
			in_end = lod_outer(lod - 1)
			in_cell = lod_cell(lod - 1)
		for m in [_materials[lod], _glow_materials[lod]] as Array[ShaderMaterial]:
			m.set_shader_parameter("fade_in_begin", in_begin)
			m.set_shader_parameter("fade_in_end", in_end)
			m.set_shader_parameter("fade_in_cell", in_cell)
			m.set_shader_parameter("fade_out_begin", out_begin)
			m.set_shader_parameter("fade_out_end", out_end)
			m.set_shader_parameter("fade_out_cell", out_cell)
		if lod == 0:
			# Grass tufts live only here, and go with this level.
			_grass_material.set_shader_parameter("fade_out_begin", out_begin)
			_grass_material.set_shader_parameter("fade_out_end", out_end)
			_grass_material.set_shader_parameter("fade_out_cell", out_cell)

	# The canopy of the distant island comes in exactly as the outermost level
	# of real trees goes, so the woods are never handed over to nobody.
	_far_canopy_material.set_shader_parameter("canopy_begin", lod_outer(last) * (1.0 - lod_band))
	_far_canopy_material.set_shader_parameter("canopy_end", lod_outer(last))
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
	# A chunk only gains lights once it comes within detail_range, so without a
	# fade a whole grove would light up the instant it crossed that line. Fade
	# over the last stretch before the boundary and the switch is invisible.
	var far: float = minf(glow_light_distance, detail_range)
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


## A level is requeued only when the player crosses one of *its* chunks, so
## walking a few metres does not disturb the 51.2 m ring on the horizon.
func _update_center(force: bool) -> void:
	var p := _eye_xz()
	var changed := force
	for lod in lod_count():
		var m := chunk_meters(lod)
		var c := Vector2i(int(floor(p.x / m)), int(floor(p.y / m)))
		if lod >= _centers.size():
			_centers.append(c)
			changed = true
		elif _centers[lod] != c:
			_centers[lod] = c
			changed = true
	if not changed:
		return
	_rebuild_queue()
	_unload_far()


func _eye_xz() -> Vector2:
	var p := get_node_or_null(player_path)
	if p == null:
		return Vector2.ZERO
	var pos := (p as Node3D).global_position
	return Vector2(pos.x, pos.z)


## How far a chunk is from the player: x is the distance to its nearest point,
## y the distance to its farthest corner. A chunk is worth having when some part
## of it falls inside its level's ring, which is what those two answer.
func _chunk_gap(key: Vector3i, p: Vector2) -> Vector2:
	var m := chunk_meters(key.z)
	var x0 := float(key.x) * m
	var z0 := float(key.y) * m
	var dx := maxf(maxf(x0 - p.x, p.x - (x0 + m)), 0.0)
	var dz := maxf(maxf(z0 - p.y, p.y - (z0 + m)), 0.0)
	var fx := maxf(absf(p.x - x0), absf(p.x - (x0 + m)))
	var fz := maxf(absf(p.y - z0), absf(p.y - (z0 + m)))
	return Vector2(sqrt(dx * dx + dz * dz), sqrt(fx * fx + fz * fz))


func _rebuild_queue() -> void:
	var p := _eye_xz()
	var wanted: Array[Vector3i] = []
	for lod in lod_count():
		var m := chunk_meters(lod)
		var outer := lod_outer(lod)
		var inner := lod_inner(lod)
		var cx0 := int(floor((p.x - outer) / m))
		var cx1 := int(floor((p.x + outer) / m))
		var cz0 := int(floor((p.y - outer) / m))
		var cz1 := int(floor((p.y + outer) / m))
		for cz in range(cz0, cz1 + 1):
			for cx in range(cx0, cx1 + 1):
				var key := Vector3i(cx, cz, lod)
				var gap := _chunk_gap(key, p)
				# Outside the ring entirely, or wholly inside the finer level
				# that covers this ground already.
				if gap.x > outer or gap.y < inner:
					continue
				if _jobs.has(key):
					continue
				if _chunks.has(key):
					# upgrade a chunk that came into the detail / collision range
					var info: Dictionary = _chunks[key]
					if (_wants_detail(key, gap.x) and not info["detail"]) 							or (_wants_collision(key, gap.x) and not info["collision"]):
						wanted.append(key)
					continue
				wanted.append(key)
	# Finest level first, and nearest first inside a level, so the ground the
	# player is standing on is there before the horizon is.
	wanted.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.z != b.z:
			return a.z < b.z
		return _chunk_gap(a, p).x < _chunk_gap(b, p).x)
	_queue = wanted


## Grass tufts, collision and mushroom lights are all level 0 only: nothing
## coarser is ever close enough to walk on or to look at from underneath.
func _wants_detail(key: Vector3i, near: float) -> bool:
	return key.z == 0 and near <= detail_range


func _wants_collision(key: Vector3i, near: float) -> bool:
	return key.z == 0 and near <= collision_range


func _pump_jobs() -> void:
	var p := _eye_xz()
	while _jobs.size() < max_parallel_jobs and not _queue.is_empty():
		var key: Vector3i = _queue.pop_front()
		if _jobs.has(key):
			continue
		var near := _chunk_gap(key, p).x
		var detail := _wants_detail(key, near)
		var coll := _wants_collision(key, near)
		var id := WorkerThreadPool.add_task(_job.bind(key, detail, coll), false, "voxel_chunk")
		_jobs[key] = id


func _job(key: Vector3i, detail: bool, coll: bool) -> void:
	var res := ChunkBuilder.build(gen, key.x, key.y, key.z, detail, coll)
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

	var p := _eye_xz()
	for res in batch:
		var key := Vector3i(res["cx"], res["cz"], res["lod"])
		if _jobs.has(key):
			WorkerThreadPool.wait_for_task_completion(_jobs[key])
			_jobs.erase(key)
		if _chunks.has(key):
			var old: Dictionary = _chunks[key]
			if is_instance_valid(old["node"]):
				old["node"].queue_free()
			_chunks.erase(key)
		if _chunk_gap(key, p).x > lod_outer(key.z):
			continue
		var node := _spawn_chunk(key, res)
		_chunks[key] = {"node": node, "detail": res["detail"], "collision": res["collision"]}

	if not _spawned and _jobs.is_empty() and _queue.is_empty():
		_spawned = true
		world_ready.emit()


func _spawn_chunk(key: Vector3i, res: Dictionary) -> Node3D:
	var m := chunk_meters(key.z)
	var root := Node3D.new()
	root.name = "Chunk_%d_%d_L%d" % [key.x, key.y, key.z]
	root.position = Vector3(float(key.x) * m, 0.0, float(key.y) * m)
	add_child(root)
	if res["mesh"] != null:
		var mi := MeshInstance3D.new()
		var mesh: ArrayMesh = res["mesh"]
		mi.mesh = mesh
		var sway_surface: int = res.get("sway_surface", -1)
		var glow_surface: int = res.get("glow_surface", -1)
		for s in mesh.get_surface_count():
			var mat := _materials[key.z]
			if s == sway_surface:
				mat = _grass_material
			elif s == glow_surface:
				mat = _glow_materials[key.z]
			mi.set_surface_override_material(s, mat)
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


## Drops chunks that have fallen out of their level's ring, with one chunk of
## slack either side so that walking back and forth over a boundary does not
## rebuild the same chunk again and again.
func _unload_far() -> void:
	var p := _eye_xz()
	var drop: Array[Vector3i] = []
	for key in _chunks.keys():
		var slack := chunk_meters(key.z)
		var gap := _chunk_gap(key, p)
		if gap.x > lod_outer(key.z) + slack or gap.y < lod_inner(key.z) - slack:
			drop.append(key)
	for key in drop:
		var info: Dictionary = _chunks[key]
		if is_instance_valid(info["node"]):
			info["node"].queue_free()
		_chunks.erase(key)


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
