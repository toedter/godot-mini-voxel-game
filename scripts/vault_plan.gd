class_name VaultPlan
extends RefCounted

## The floor plan of the vault under the drowned ruin: what rooms it has, what
## stands in them, and where the things that are not masonry go.
##
## Separate from Interior because the two answer different questions. Interior
## is about interiors in general - how a room hangs under the terrain, how the
## player gets in and out of one. This is one authored building, and the only
## thing it knows how to do is describe itself.
##
## Everything here is in voxels, local to the Interior's own origin, y up, and
## the anchors handed back are the same coordinates in metres. Chambers are
## laid out so that neighbours share a wall exactly: a doorway is then a hole
## cut through one piece of masonry, rather than a hole opening onto the empty
## space between two boxes that were built apart.

const VS := VoxelDefs.VOXEL_SIZE

## Uniform enlargement of the whole floor plan. Every dimension below is this
## many times the vault's original size, so the rooms keep exactly the same
## proportions and the same relation to one another - just bigger and taller,
## like a blueprint redrawn to a larger scale rather than a different building.
const SCALE := 2

## Masonry, in voxels. Walls are what neighbouring chambers share, so their
## thickness is also the spacing of the plan; floors and ceilings only have to
## be thick enough not to be cut through by what is carved into them.
const WALL := 3 * SCALE
const CAP := 2 * SCALE
## Head height of every chamber, in voxels: 4.7 m.
const HEAD := 23 * SCALE
## Doorways: 2.5 m wide, 3.9 m tall, comfortably more than the 0.6 m player
## capsule.
const DOOR_HALF := 6 * SCALE
const DOOR_TOP := 19 * SCALE

## The chambers, as their air volumes. The gallery is the spine; the other four
## hang off it and share its walls.
const GALLERY_LO := Vector3i(54 * SCALE, 0, 44 * SCALE)
const GALLERY_HI := Vector3i(71 * SCALE, HEAD, 87 * SCALE)
## Where the player arrives, and the only way back to the island.
const ANTE_LO := Vector3i(40 * SCALE, 0, 91 * SCALE)
const ANTE_HI := Vector3i(83 * SCALE, HEAD, 126 * SCALE)
## A sunken basin, dry for a very long time.
const CISTERN_LO := Vector3i(15 * SCALE, 0, 50 * SCALE)
const CISTERN_HI := Vector3i(50 * SCALE, HEAD, 85 * SCALE)
## Niches cut into the far wall, and a bench under them.
const RELIC_LO := Vector3i(75 * SCALE, 0, 50 * SCALE)
const RELIC_HI := Vector3i(110 * SCALE, HEAD, 85 * SCALE)
## Behind the gate: whatever the vault was built to hold - a labyrinth,
## its size following from a comfortable corridor width and a wall thickness
## rather than the other way round, cell walls built the way any text-book
## maze generator builds them: a grid of cells, each with its own four walls, torn down one
## at a time between neighbours until every cell is reachable. Its near edge
## is where the old single room's was, so the door cut into the gallery wall
## still opens onto it exactly, and it is centred on the gallery's own axis
## rather than the gallery's footprint, so the door lines up with the middle
## of the maze rather than with whichever cell the maze happens to leave open
## there.
const LABY_CELL_M := 2.0
const LABY_WALL_M := 0.5
## Odd, so the maze has one cell dead in the middle rather than a crossroads
## of four - somewhere to put the last brazier that is actually the centre.
const LABY_CELLS := 7
const LABY_CELL := int(LABY_CELL_M / VS)
const LABY_WALL := int(LABY_WALL_M / VS)
const LABY_SIZE := LABY_CELLS * LABY_CELL + (LABY_CELLS - 1) * LABY_WALL
const INNER_MX := (GALLERY_LO.x + GALLERY_HI.x) / 2
const INNER_HI := Vector3i(INNER_MX + LABY_SIZE / 2 - 1, HEAD, 40 * SCALE)
const INNER_LO := Vector3i(INNER_HI.x - LABY_SIZE + 1, 0, INNER_HI.z - LABY_SIZE + 1)

## The basin sunk into the cistern floor. The floor is not thickened for it -
## that would carry stone under the whole chamber to serve one corner of it -
## so an apron is laid under the basin instead, proud of it on every side.
const BASIN_DEPTH := 3 * SCALE
const BASIN_LO := Vector3i(22 * SCALE, -BASIN_DEPTH, 58 * SCALE)
## The rim sits flush with the floor regardless of scale, so its top stays one
## voxel below y = 0 rather than growing with everything else.
const BASIN_HI := Vector3i(43 * SCALE, -1, 79 * SCALE)

## Where the player is put down when they come in: inside the antechamber,
## clear of the doorway, facing down the vault.
var entry := Vector3.ZERO
## The doorway back to the surface, and the gate into the inner vault.
var exit_door := Vector3.ZERO
var gate := Vector3.ZERO
## Cistern, reliquary, inner vault - the order the puzzle expects to be lit in
## is not this one; any two of the first two open the gate.
var braziers: Array[Vector3] = []
## The plinth in the antechamber, where a torch has been left burning.
var torch_rest := Vector3.ZERO


## Clear size (m) of a doorway. The gate that fills one is built from this
## rather than from a default of its own: the plan cuts the hole, so the plan
## is what knows how big it is.
func door_clear() -> Vector2:
	return Vector2(float(DOOR_HALF * 2 + 1), float(DOOR_TOP + 1)) * VS


## Builds the whole vault and fills in the anchors. One pass, on the main
## thread, so it is written to touch each voxel once where it can.
func build() -> VoxelRoom:
	var room := VoxelRoom.new()
	# Walls keep the sandstone the ruin above is built from; the floor and
	# ceiling are their own materials, so a chamber reads as built - flagstones
	# underfoot, timber overhead - rather than as a stone box.
	var sandstone := VoxelDefs.SANDSTONE
	var stone := VoxelDefs.STONE
	var wood := VoxelDefs.WOOD
	room.chamber(GALLERY_LO, GALLERY_HI, WALL, CAP, sandstone, stone, wood)
	room.chamber(ANTE_LO, ANTE_HI, WALL, CAP, sandstone, stone, wood)
	room.chamber(CISTERN_LO, CISTERN_HI, WALL, CAP, sandstone, stone, wood)
	room.chamber(RELIC_LO, RELIC_HI, WALL, CAP, sandstone, stone, wood)
	room.chamber(INNER_LO, INNER_HI, WALL, CAP, sandstone, stone, wood)
	_furnish(room)
	_build_labyrinth(room)
	# Cut last, so a maze wall or a piece of furniture that lands on a doorway
	# never gets the last word: the way through is carved back open regardless
	# of what stood there a moment before.
	_cut_doors(room)
	_anchors()
	return room


## Doorways, cut after every chamber is standing: a door between two of them
## goes through masonry they both wrote, and carving one before the other was
## built would only have it filled straight back in.
func _cut_doors(room: VoxelRoom) -> void:
	# Gallery to antechamber, and gallery to the inner vault. Both are on the
	# gallery's centre line, so the vault reads as one axis from the door in.
	var mx := (GALLERY_LO.x + GALLERY_HI.x) / 2
	_cut_z(room, mx, GALLERY_HI.z, ANTE_LO.z)
	_cut_z(room, mx, INNER_HI.z, GALLERY_LO.z)
	# Gallery to the two side chambers, on the shared walls either side.
	var mz := (GALLERY_LO.z + GALLERY_HI.z) / 2
	_cut_x(room, mz, CISTERN_HI.x, GALLERY_LO.x)
	_cut_x(room, mz, GALLERY_HI.x, RELIC_LO.x)
	# And the way out, straight through the antechamber's far wall. Cut a
	# little under the doorways inside, because the door that stands in it is a
	# slab rather than an opening and has to cover it completely: behind this
	# one there is no next room, only the dark the vault is buried in.
	room.carve(Vector3i(mx - 5 * SCALE, 0, ANTE_HI.z + 1),
		Vector3i(mx + 5 * SCALE, DOOR_TOP - 1, ANTE_HI.z + WALL))


## An opening through the masonry between two air volumes that face each other
## along Z. Carved from air to air, so no lip of wall is left at either side.
func _cut_z(room: VoxelRoom, cx: int, near: int, far: int) -> void:
	room.carve(Vector3i(cx - DOOR_HALF, 0, near),
		Vector3i(cx + DOOR_HALF, DOOR_TOP, far))


func _cut_x(room: VoxelRoom, cz: int, near: int, far: int) -> void:
	room.carve(Vector3i(near, 0, cz - DOOR_HALF),
		Vector3i(far, DOOR_TOP, cz + DOOR_HALF))


## What stands in the rooms. All of it is boxes: at 10 cm a bench is a slab and
## a broken column is two, and anything finer would be a mesh rather than part
## of the building. Scaled with everything else, so the furniture still sits
## the same distance from the walls it always did.
func _furnish(room: VoxelRoom) -> void:
	var stone := VoxelDefs.STONE
	var sandstone := VoxelDefs.SANDSTONE

	# Antechamber: a low plinth with the torch on it, and a bench along the
	# wall. The plinth is the first thing lit when the player comes in, so it
	# stands square in front of the door.
	room.fill(Vector3i(58, 0, 100) * SCALE, Vector3i(66, 7, 108) * SCALE, stone)
	room.fill(Vector3i(41, 0, 96) * SCALE, Vector3i(46, 4, 120) * SCALE, sandstone)

	# Cistern: a basin sunk into the floor on its own apron of stone, and the
	# rubble of whatever fell in and was never fished out.
	room.fill(BASIN_LO + Vector3i(-1, -2, -1) * SCALE,
		BASIN_HI + Vector3i(1, 0, 1) * SCALE, sandstone)
	room.carve(BASIN_LO, BASIN_HI)
	room.fill(Vector3i(17, 0, 81) * SCALE, Vector3i(24, 3, 85) * SCALE, stone)
	room.fill(Vector3i(19, 0, 78) * SCALE, Vector3i(22, 1, 80) * SCALE, stone)

	# Reliquary: shelves cut into the far wall, one of them with something
	# still on it, and a bench under them. Two voxels deep into a three voxel
	# wall, scaled with WALL, so the room stays sealed. The near face has to
	# stay at the wall's own +1 - the same fixed adjacency `chamber` builds its
	# wall from - rather than scale away from the opening it is cut into.
	for z0 in [58 * SCALE, 70 * SCALE]:
		room.carve(Vector3i(RELIC_HI.x + 1, 8 * SCALE, z0),
			Vector3i(RELIC_HI.x + 2 * SCALE, 15 * SCALE, z0 + 6 * SCALE))
	room.fill(Vector3i(RELIC_HI.x + 1, 12 * SCALE, 71 * SCALE),
		Vector3i(RELIC_HI.x + 2 * SCALE, 13 * SCALE, 74 * SCALE), stone)
	room.fill(Vector3i(88, 0, 81) * SCALE, Vector3i(108, 3, 85) * SCALE, sandstone)


## Each of the labyrinth's cells has its own four walls, torn down between it
## and whichever neighbours a depth-first search reaches it through - the same
## recursive-backtracker every text-book maze generator uses, adapted from a
## boolean per wall to a `Dictionary` keyed by direction rather than one struct
## field each, since GDScript has no structs of its own.
enum { N, S, E, W }


## The labyrinth's own wall grid: `LABY_CELLS` x `LABY_CELLS` cells, each still
## holding all four of its walls except where the search below has knocked one
## down. Visits every cell exactly once, so the maze it leaves is the kind
## with exactly one route between the entrance and any other cell, the middle
## among them.
func _laby_grid() -> Array:
	var walls := []
	var visited := []
	walls.resize(LABY_CELLS)
	visited.resize(LABY_CELLS)
	for i in LABY_CELLS:
		var col_w := []
		var col_v := []
		col_w.resize(LABY_CELLS)
		col_v.resize(LABY_CELLS)
		for j in LABY_CELLS:
			col_w[j] = {N: true, S: true, E: true, W: true}
			col_v[j] = false
		walls[i] = col_w
		visited[i] = col_v

	# Fixed rather than drawn from the world seed: the vault is authored, and
	# an authored building reads the same maze every time it is entered.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xFA6E
	var start := _laby_entry_cell()
	visited[start.x][start.y] = true
	var stack: Array[Vector2i] = [start]
	while not stack.is_empty():
		var cur: Vector2i = stack.back()
		var options := _laby_unvisited_neighbors(cur, visited)
		if options.is_empty():
			stack.pop_back()
			continue
		var nxt: Vector2i = options[rng.randi() % options.size()]
		_laby_remove_wall(walls, cur, nxt)
		visited[nxt.x][nxt.y] = true
		stack.append(nxt)
	return walls


## The cell's own unvisited neighbours - north, south, east, west, in that
## order, exactly as the reference generator lists them.
func _laby_unvisited_neighbors(cell: Vector2i, visited: Array) -> Array[Vector2i]:
	var list: Array[Vector2i] = []
	if cell.y > 0 and not visited[cell.x][cell.y - 1]:
		list.append(Vector2i(cell.x, cell.y - 1))
	if cell.y < LABY_CELLS - 1 and not visited[cell.x][cell.y + 1]:
		list.append(Vector2i(cell.x, cell.y + 1))
	if cell.x < LABY_CELLS - 1 and not visited[cell.x + 1][cell.y]:
		list.append(Vector2i(cell.x + 1, cell.y))
	if cell.x > 0 and not visited[cell.x - 1][cell.y]:
		list.append(Vector2i(cell.x - 1, cell.y))
	return list


## Knocks down the one wall a and b share. Both sides are written, since a's
## east is b's west and nothing else ever reads just one of them.
func _laby_remove_wall(walls: Array, a: Vector2i, b: Vector2i) -> void:
	if b.y == a.y - 1:
		walls[a.x][a.y][N] = false
		walls[b.x][b.y][S] = false
	elif b.y == a.y + 1:
		walls[a.x][a.y][S] = false
		walls[b.x][b.y][N] = false
	elif b.x == a.x + 1:
		walls[a.x][a.y][E] = false
		walls[b.x][b.y][W] = false
	elif b.x == a.x - 1:
		walls[a.x][a.y][W] = false
		walls[b.x][b.y][E] = false


## The low corner (voxels) of a cell's own open floor.
func _laby_cell_x0(i: int) -> int:
	return INNER_LO.x + i * (LABY_CELL + LABY_WALL)


func _laby_cell_z0(j: int) -> int:
	return INNER_LO.z + j * (LABY_CELL + LABY_WALL)


## The cell nearest the door in from the gallery: centred on the maze's own
## entrance column, in the row that borders the gallery. Increasing z is
## increasing row, so that row is the last one.
func _laby_entry_cell() -> Vector2i:
	return Vector2i(LABY_CELLS / 2, LABY_CELLS - 1)


## The cell in the dead centre of the maze, where the last brazier stands.
func _laby_center_cell() -> Vector2i:
	return Vector2i(LABY_CELLS / 2, LABY_CELLS / 2)


## The middle of a cell's open floor, in metres.
func _laby_cell_center(cell: Vector2i) -> Vector3:
	var x := float(_laby_cell_x0(cell.x) + LABY_CELL / 2) * VS
	var z := float(_laby_cell_z0(cell.y) + LABY_CELL / 2) * VS
	return Vector3(x, 0.0, z)


## Builds the labyrinth from its wall grid: a slab floor to ceiling wherever a
## wall is still standing between two cells, and - regardless of whether
## either of them is - a post at every junction where four cells meet, so two
## walls that turn a corner there always actually join rather than leaving the
## junction's own square as a gap on the diagonal.
func _build_labyrinth(room: VoxelRoom) -> void:
	var walls := _laby_grid()
	var sandstone := VoxelDefs.SANDSTONE
	for i in LABY_CELLS:
		for j in LABY_CELLS:
			var w: Dictionary = walls[i][j]
			if w[E] and i < LABY_CELLS - 1:
				room.fill(
					Vector3i(_laby_cell_x0(i) + LABY_CELL, 0, _laby_cell_z0(j)),
					Vector3i(_laby_cell_x0(i + 1) - 1, HEAD, _laby_cell_z0(j) + LABY_CELL - 1),
					sandstone)
			if w[S] and j < LABY_CELLS - 1:
				room.fill(
					Vector3i(_laby_cell_x0(i), 0, _laby_cell_z0(j) + LABY_CELL),
					Vector3i(_laby_cell_x0(i) + LABY_CELL - 1, HEAD, _laby_cell_z0(j + 1) - 1),
					sandstone)
	for i in LABY_CELLS - 1:
		for j in LABY_CELLS - 1:
			room.fill(
				Vector3i(_laby_cell_x0(i) + LABY_CELL, 0, _laby_cell_z0(j) + LABY_CELL),
				Vector3i(_laby_cell_x0(i + 1) - 1, HEAD, _laby_cell_z0(j + 1) - 1),
				sandstone)


## The anchors, in metres. Everything that is not masonry is placed off these,
## so moving a room moves what stands in it.
func _anchors() -> void:
	# The centre of the openings, not of the gallery: a doorway cut at DOOR_HALF
	# either side of voxel n is 2*DOOR_HALF+1 voxels wide, so its middle is half
	# a voxel further on. Five centimetres, and the width of the slit left down
	# one side of every door hung on the wrong one.
	var mx := (float(GALLERY_LO.x + GALLERY_HI.x) + 1.0) * 0.5 * VS
	# A pace inside the antechamber's door, looking down the vault. The floor
	# is the top of the air volume's bottom, which is y = 0, and a fingernail
	# of clearance keeps the capsule off it.
	entry = Vector3(mx, 0.05, float(ANTE_HI.z - 8 * SCALE) * VS)
	exit_door = Vector3(mx, 0.0, float(ANTE_HI.z + 1) * VS)
	gate = Vector3(mx, 0.0, float(GALLERY_LO.z - 2 * SCALE) * VS)
	torch_rest = Vector3(float(62 * SCALE) * VS, float(8 * SCALE) * VS, float(104 * SCALE) * VS)
	# Each one deep in its own chamber, for two reasons. A brazier near a shared
	# wall shines through it - nothing down here casts a shadow - and a brazier
	# near a doorway is something to catch on in the dark, which at the far side
	# of a gate the player has just earned is the worst possible place for it.
	# The last of the three is what the maze is for, so it stands in the one
	# cell every path through the labyrinth was built to lead to.
	braziers = [
		Vector3(float(19 * SCALE) * VS, 0.0, float(54 * SCALE) * VS),
		Vector3(float(104 * SCALE) * VS, 0.0, float(54 * SCALE) * VS),
		_laby_cell_center(_laby_center_cell()),
	]
