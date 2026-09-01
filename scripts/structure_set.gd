class_name StructureSet
extends RefCounted

## The authored buildings of the world: where each one stands and what shape it
## is. Read by ChunkBuilder while it meshes, on a worker thread.
##
## Structures deliberately do not go into the world as objects. The terrain is a
## pure function of the seed and chunks are rebuilt from scratch every time they
## come back into range, so anything that has to survive that has to be a
## function too. A placement here is data the mesher consults, exactly as it
## consults the noise fields; nothing is ever stamped into a live chunk.
##
## That also means the set has to be finished before the first chunk is built
## and never written to again, which is what makes it safe to read from several
## worker threads at once without a lock.

## Kinds ChunkBuilder knows how to build. Each is a parametric shape rather
## than a block of authored voxels: at 10 cm a modest ruin is tens of thousands
## of voxels, far past what is worth storing or hand placing.
const WALL := &"wall"
const PILLAR := &"pillar"
const ARCH := &"arch"

## Every placement is a dictionary:
##   kind   one of the constants above
##   x, z   world voxel coordinates of the anchor
##   base   world voxel Y the foundation sits at
##   r      XZ radius in voxels covering the whole footprint, used for the
##          chunk overlap test and nothing else
##   plus the kind's own parameters, all counted in voxels.
var _items: Array[Dictionary] = []


func size() -> int:
	return _items.size()


func all() -> Array[Dictionary]:
	return _items


## Everything whose footprint reaches into the square of `span` voxels starting
## at (ox, oz).
##
## A linear scan. The island carries a handful of ruins, so an index would cost
## more to maintain than it saves; if structures ever number in the thousands
## this is the place to put a coarse grid.
func overlapping(ox: int, oz: int, span: int) -> Array[Dictionary]:
	var hit: Array[Dictionary] = []
	for it in _items:
		var r: int = it["r"]
		if int(it["x"]) + r < ox or int(it["x"]) - r >= ox + span:
			continue
		if int(it["z"]) + r < oz or int(it["z"]) - r >= oz + span:
			continue
		hit.append(it)
	return hit


## A straight run of masonry. `axis` 0 runs along X, 1 along Z. The anchor is
## the centre of the run.
func add_wall(gen: TerrainGen, wx: int, wz: int, axis: int, length: int,
		height: int, thickness: int, mat: int) -> void:
	var half := length / 2
	var r := maxi(half, thickness) + 2
	_items.append({
		"kind": WALL, "x": wx, "z": wz, "base": _ground(gen, wx, wz), "r": r,
		"axis": axis, "length": length, "height": height,
		"thickness": thickness, "mat": mat,
	})


func add_pillar(gen: TerrainGen, wx: int, wz: int, height: int, radius: int,
		mat: int) -> void:
	_items.append({
		"kind": PILLAR, "x": wx, "z": wz, "base": _ground(gen, wx, wz),
		"r": radius + 2, "height": height, "radius": radius, "mat": mat,
	})


## A freestanding doorway: two jambs and a lintel across them. The silhouette a
## vault entrance reads as from a distance, and the thing a player walks
## through once the water is out of the way.
func add_arch(gen: TerrainGen, wx: int, wz: int, axis: int, width: int,
		height: int, thickness: int, mat: int) -> void:
	var r := maxi(width / 2, thickness) + 2
	_items.append({
		"kind": ARCH, "x": wx, "z": wz, "base": _ground(gen, wx, wz), "r": r,
		"axis": axis, "width": width, "height": height,
		"thickness": thickness, "mat": mat,
	})


## Foundation height at a spot, in voxels.
func _ground(gen: TerrainGen, wx: int, wz: int) -> int:
	return gen.height_at(wx, wz)


# --------------------------------------------------------------------------
# the island's own structures
# --------------------------------------------------------------------------

## Builds the set the island ships with.
##
## Positions are searched for rather than written down, because the terrain is
## generated: a coordinate typed in by hand lands wherever the noise happens to
## put it, which for a drowned ruin is the difference between a landmark and a
## few stones buried in a hillside. The search is a pure function of the seed,
## so every run and every worker thread agrees on the answer.
static func for_island(gen: TerrainGen) -> StructureSet:
	var set := StructureSet.new()
	var site := _shallow_site(gen)
	if site == Vector2i.MAX:
		return set
	set._build_drowned_ruin(gen, site.x, site.y)
	return set


## A ruin standing in the shallows: under water at the default tide, high and
## dry at low water. The whole point of the tide in one building.
func _build_drowned_ruin(gen: TerrainGen, cx: int, cz: int) -> void:
	var stone := VoxelDefs.STONE
	var sandstone := VoxelDefs.SANDSTONE
	# A room roughly 7 m square, its seaward side fallen away, with the doorway
	# facing back towards the shore.
	var half := 35 # voxels, 3.5 m
	add_wall(gen, cx, cz - half, 0, half * 2, 24, 4, sandstone)
	add_wall(gen, cx - half, cz, 1, half * 2, 20, 4, sandstone)
	add_wall(gen, cx + half, cz, 1, half * 2, 14, 4, sandstone)
	add_arch(gen, cx, cz + half, 0, 18, 26, 4, stone)
	# Two columns inside, one of them snapped off short.
	add_pillar(gen, cx - 16, cz - 12, 30, 4, stone)
	add_pillar(gen, cx + 16, cz - 12, 13, 4, stone)


## Finds a patch of sea bed shallow enough to be uncovered at low water and
## deep enough to be under the surface at the default tide, and flat enough to
## stand a building on.
##
## Walks outwards from the origin in rings, like the player spawn search, so
## the ruin ends up within reach of wherever the player starts.
static func _shallow_site(gen: TerrainGen) -> Vector2i:
	var datum := VoxelDefs.SEA_DATUM
	for ring in range(6, 90):
		var r := float(ring) * 8.0
		for i in 36:
			var a := TAU * float(i) / 36.0
			var mx := cos(a) * r
			var mz := sin(a) * r
			var h := gen.height_meters(mx, mz)
			# Between a metre and three under the surface: a low tide of -5 m
			# leaves it standing clear, the default tide covers its floor.
			if h > datum - 1.0 or h < datum - 3.0:
				continue
			if not _flat_enough(gen, mx, mz):
				continue
			return Vector2i(int(floor(mx / VoxelDefs.VOXEL_SIZE)),
				int(floor(mz / VoxelDefs.VOXEL_SIZE)))
	return Vector2i.MAX


## True when the sea bed over the ruin's footprint does not vary by more than a
## metre, so the building does not end up half swallowed by a slope.
static func _flat_enough(gen: TerrainGen, mx: float, mz: float) -> bool:
	var lo := INF
	var hi := -INF
	for dz in [-4.0, 0.0, 4.0]:
		for dx in [-4.0, 0.0, 4.0]:
			var h := gen.height_meters(mx + dx, mz + dz)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return hi - lo <= 1.0
