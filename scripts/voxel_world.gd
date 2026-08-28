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
@export var player_path: NodePath = ^"../Player"

var gen: TerrainGen

var _material: ShaderMaterial
var _grass_material: ShaderMaterial
var _chunks := {} # Vector2i -> Dictionary {node, detail, collision}
var _jobs := {} # Vector2i -> task id
var _queue: Array[Vector2i] = []
var _done: Array = []
var _mutex := Mutex.new()
var _center := Vector2i(0x7fffffff, 0)
var _spawned := false


func _ready() -> void:
	gen = TerrainGen.new(world_seed)
	_ensure_materials()
	_spawn_player()
	_update_center(true)


## The materials are created on demand because Atmosphere, which pushes the
## haze settings into them, is readied before this node.
func haze_materials() -> Array[ShaderMaterial]:
	_ensure_materials()
	return [_material, _grass_material]


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


func _exit_tree() -> void:
	for id in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(id)
	_jobs.clear()


func _spawn_player() -> void:
	var p := get_node_or_null(player_path)
	if p == null:
		return
	var y := gen.ground_y(0.0, 0.0)
	p.global_position = Vector3(0.0, y + 2.0, 0.0)


func _process(_delta: float) -> void:
	_update_center(false)
	_pump_jobs()
	_integrate_results()


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
		for s in mesh.get_surface_count():
			mi.set_surface_override_material(s, _grass_material if s == sway_surface else _material)
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
	return "Desert" if gen.biome_at(pos.x, pos.z) >= 0.5 else "Grassland"


func loaded_chunks() -> int:
	return _chunks.size()
