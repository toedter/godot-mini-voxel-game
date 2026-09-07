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
## A plinth of masonry with a stair up one side. Not a ruin: this is the thing
## the tide lock stands on, and it exists so the lock can be reached at every
## notch the lock itself offers.
const TERRACE := &"terrace"

## Terrace masonry, in voxels. The stair's 30 cm rise on a 40 cm tread is
## comfortably inside the player's 45 cm step, and reads as a stair rather than
## as a ramp; the walls are thin because the plinth is a shell, which nothing
## can see into and nothing can reach.
const STAIR_RISE := 3
const STAIR_TREAD := 4
const TERRACE_WALL := 2
const TERRACE_SLAB := 4
## Half the deck, and half the width of the stair, in voxels: a 3.6 m square
## with a 1.4 m stair off one side.
const TERRACE_HALF := 18
const STAIR_HALF := 7
## How far (m) the deck stands above the tide's flood notch. Enough to keep the
## player's feet dry with the sea at its highest, little enough that high water
## is visibly lapping at the masonry rather than somewhere below.
const TERRACE_FREEBOARD := 0.8

## Every placement is a dictionary:
##   kind   one of the constants above
##   x, z   world voxel coordinates of the anchor
##   base   world voxel Y the foundation sits at
##   r      XZ radius in voxels covering the whole footprint, used for the
##          chunk overlap test and nothing else
##   plus the kind's own parameters, all counted in voxels.
var _items: Array[Dictionary] = []

## Where the drowned ruin ended up, in metres, or Vector2.INF while there is
## none. Written once as the set is built, like the placements themselves, so
## the worker threads may read it just as freely.
var _ruin_centre := Vector2.INF

## Where the lock's terrace stands, in metres, and the world Y (m) of its deck.
## Same contract as the ruin's centre: written while the set is built, read
## from anywhere afterwards.
var _terrace_centre := Vector2.INF
var _terrace_top := 0.0


func size() -> int:
	return _items.size()


func all() -> Array[Dictionary]:
	return _items


## The centre of the drowned ruin, in metres, or Vector2.INF when the island
## has none. Everything laid out around the ruin - the player's start, the
## lock, its socket - measures from here rather than guessing from the anchor
## of one of its walls.
func ruin_centre() -> Vector2:
	return _ruin_centre


## Where the lock's terrace stands, in metres, or Vector2.INF when the island
## has none.
func terrace_centre() -> Vector2:
	return _terrace_centre


## World Y (m) of the terrace deck over a spot, or -INF anywhere the terrace is
## not. This is what a prop dropped there lands on, and the floor the player's
## fallback clamp holds them at while the chunk's collision is still being
## built - without it they would spawn on the deck and sink through it into the
## masonry before the mesher caught up.
##
## The stair is deliberately not in here. It is a slope, its height is the
## builder's business, and anything standing on it is standing on collision
## that has already been built.
func deck_y(mx: float, mz: float) -> float:
	if _terrace_centre == Vector2.INF:
		return -INF
	var half := float(TERRACE_HALF) * VoxelDefs.VOXEL_SIZE
	if absf(mx - _terrace_centre.x) > half or absf(mz - _terrace_centre.y) > half:
		return -INF
	return _terrace_top


## The first placement of a kind, or an empty dictionary. Used by anything that
## has to stand somewhere a structure put itself, such as the door in the
## ruin's archway.
func first_of(kind: StringName) -> Dictionary:
	for it in _items:
		if it["kind"] == kind:
			return it
	return {}


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


## True when a structure has claimed the ground at (mx, mz), counting
## `clearance` metres of room around its footprint.
##
## The terrain generator scatters its trees and boulders from noise alone and
## knows nothing about the masonry, so without this a tree roots on the lock's
## terrace: the builder stamps stone through the half of the trunk that is
## inside the deck and leaves the rest of it standing in the middle of the one
## place on the island the player has to walk around. A feature is placed by its
## foot, so the clearance is what the caller reckons that kind can reach - see
## `TerrainGen.FEATURE_CLEARANCE`.
##
## Measured against each kind's own footprint rather than the bounding radius
## `overlapping` uses - that one is a circle drawn round the longest dimension,
## and clearing it would leave a bald field around every wall.
func blocks_feature(mx: float, mz: float, clearance: float) -> bool:
	var vs := VoxelDefs.VOXEL_SIZE
	for it in _items:
		# Half extents of the footprint along X and Z, in metres.
		var hx := 0.0
		var hz := 0.0
		# Where the footprint's centre is, which is the anchor for everything
		# except a terrace, whose stair pushes it off to one side.
		var cx := float(it["x"]) * vs
		var cz := float(it["z"]) * vs
		match it["kind"]:
			WALL:
				var along := float(int(it["length"]) / 2) * vs
				var across := float(int(it["thickness"]) / 2) * vs
				hx = along if int(it["axis"]) == 0 else across
				hz = across if int(it["axis"]) == 0 else along
			PILLAR:
				hx = float(it["radius"]) * vs
				hz = hx
			ARCH:
				# The jambs stand outside the clear span, so the built width is
				# the opening plus a jamb either side.
				var half_t := int(it["thickness"]) / 2
				var span := float(int(it["width"]) / 2 + 2 * half_t + 1) * vs
				var deep := float(half_t) * vs
				hx = span if int(it["axis"]) == 0 else deep
				hz = deep if int(it["axis"]) == 0 else span
			TERRACE:
				var half := float(it["half"]) * vs
				# Only as many steps as it takes to reach the ground: `steps`
				# carries spares for slopes that keep falling away, and a step
				# already under the terrain builds nothing.
				var used := (int(it["top"]) - int(it["base"])) / int(it["rise"]) + 1
				var run := float(maxi(used, 0) * int(it["tread"])) * vs
				# The stair comes off one side only, so the box is stretched by
				# the run and its centre slid half a run that way.
				var shift := run * 0.5 * float(int(it["dir"]))
				var along := half + run * 0.5
				if int(it["axis"]) == 0:
					cx += shift
					hx = along
					hz = half
				else:
					cz += shift
					hx = half
					hz = along
			_:
				continue
		if absf(mx - cx) <= hx + clearance and absf(mz - cz) <= hz + clearance:
			return true
	return false


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


## A plinth to stand the tide lock on, and a stair up to it. `top` is a world
## voxel Y rather than a height, because the whole point of the thing is to put
## its deck at a level the tide cannot reach.
##
## `axis` 0 runs the stair along X, 1 along Z, and `dir` says which end of that
## axis it comes off. The stair is only ever axis aligned - the voxel grid has
## no other direction - so the caller picks whichever of the four sides points
## nearest the way it wants.
func add_terrace(gen: TerrainGen, wx: int, wz: int, top: int, axis: int,
		dir: int, mat: int) -> void:
	var base := _ground(gen, wx, wz)
	# One step per rise from the deck down to the foundation, and a few spare
	# for ground that keeps falling away. A step whose tread is already under
	# the terrain builds nothing, so overshooting costs only the loop.
	var steps := (top - base) / STAIR_RISE + 4
	_items.append({
		"kind": TERRACE, "x": wx, "z": wz, "base": base,
		"r": TERRACE_HALF + steps * STAIR_TREAD + 2, "half": TERRACE_HALF,
		"top": top, "axis": axis, "dir": dir, "steps": steps,
		"rise": STAIR_RISE, "tread": STAIR_TREAD, "stair_half": STAIR_HALF,
		"wall": TERRACE_WALL, "slab": TERRACE_SLAB, "mat": mat,
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
	set._build_lock_terrace(gen)
	return set


## The plinth the tide lock stands on, on the shore beside the ruin.
##
## The lock has to survive its own high water: standing it on the beach means
## the one notch that floods the bay puts the lock several metres under, and a
## control the player can drown by using it is a trap rather than a puzzle. The
## coast here shelves too gently to offer any ground that high, so the masonry
## makes some.
func _build_lock_terrace(gen: TerrainGen) -> void:
	var shore := shore_site(gen)
	if shore == Vector2.INF:
		return
	var top := int(round((VoxelDefs.SEA_DATUM + VoxelDefs.TIDE_FLOOD
		+ TERRACE_FREEBOARD) / VoxelDefs.VOXEL_SIZE))
	var wx := int(floor(shore.x / VoxelDefs.VOXEL_SIZE))
	var wz := int(floor(shore.y / VoxelDefs.VOXEL_SIZE))
	# The stair comes off the side facing away from the ruin, so the player
	# climbs towards it and the deck's seaward edge stays clear to look over.
	var away := shore - _ruin_centre
	var axis := 0 if absf(away.x) >= absf(away.y) else 1
	var along := away.x if axis == 0 else away.y
	_terrace_centre = Vector2(float(wx), float(wz)) * VoxelDefs.VOXEL_SIZE
	_terrace_top = float(top) * VoxelDefs.VOXEL_SIZE
	add_terrace(gen, wx, wz, top, axis, 1 if along >= 0.0 else -1, VoxelDefs.STONE)


## A ruin standing in the shallows: under water at the default tide, high and
## dry at low water. The whole point of the tide in one building.
func _build_drowned_ruin(gen: TerrainGen, cx: int, cz: int) -> void:
	_ruin_centre = Vector2(float(cx), float(cz)) * VoxelDefs.VOXEL_SIZE
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


## Dry ground beside the ruin: where the terrace goes, and with it the player's
## start and the frame the lock, the socket and the cap are laid out in.
## Vector2.INF when there is no ruin or nowhere around it to stand, and the
## caller falls back to its own spawn search.
##
## Rings outwards from the ruin in metres, so the nearest shore wins. Ground
## that clears high water on its own is taken at once, since a terrace on it
## need be no more than a step; failing that, the driest of the spots within
## ten metres of that first shore, and the masonry makes up the rest.
func shore_site(gen: TerrainGen) -> Vector2:
	if _ruin_centre == Vector2.INF:
		return Vector2.INF
	var datum := VoxelDefs.SEA_DATUM
	var best := Vector2.INF
	var best_h := -INF
	var found := -1
	# Out from clear of the ruin's own walls, in 2 m steps, as far as a coast
	# that shelves gently can put its first dry ground.
	for ring in range(5, 61):
		# Ten metres past the nearest shore is far enough to take the drier of
		# two neighbouring spots. Beyond that the player is being walked away
		# from the ruin for a hand's breadth of height.
		if found >= 0 and ring > found + 5:
			break
		var r := float(ring) * 2.0
		for i in 24:
			var a := TAU * float(i) / 24.0
			var c := _ruin_centre + Vector2(cos(a) * r, sin(a) * r)
			var h := gen.height_meters(c.x, c.y)
			# Two metres of freeboard at the default tide: dry to stand on,
			# low enough that the ruin is still what the player looks at.
			if h < datum + 2.0 or not _flat_enough(gen, c.x, c.y):
				continue
			if found < 0:
				found = ring
			if h >= datum + VoxelDefs.TIDE_FLOOD + TERRACE_FREEBOARD:
				return c
			if h > best_h:
				best_h = h
				best = c
	return best


## Finds a patch of sea bed shallow enough to be uncovered at low water and
## deep enough to be under the surface at the default tide, and flat enough to
## stand a building on.
##
## Walks outwards from the origin in rings, so the ruin is the first such patch
## out from the middle of the island. The player then starts on the shore beside
## it, rather than the ruin being a walk away from where they woke up.
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


## True when the ground over a building or a prop's footprint does not vary by
## more than a metre, so nothing ends up half swallowed by a slope.
static func _flat_enough(gen: TerrainGen, mx: float, mz: float) -> bool:
	var lo := INF
	var hi := -INF
	for dz in [-4.0, 0.0, 4.0]:
		for dx in [-4.0, 0.0, 4.0]:
			var h := gen.height_meters(mx + dx, mz + dz)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return hi - lo <= 1.0
