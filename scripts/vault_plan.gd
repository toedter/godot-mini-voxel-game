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

## Masonry, in voxels. Walls are what neighbouring chambers share, so their
## thickness is also the spacing of the plan; floors and ceilings only have to
## be thick enough not to be cut through by what is carved into them.
const WALL := 3
const CAP := 2
## Head height of every chamber, in voxels: 2.4 m.
const HEAD := 23
## Doorways: 1.2 m wide, 2.0 m tall, which is the same clearance the way in
## has always had and comfortably more than the 0.6 m player capsule.
const DOOR_HALF := 6
const DOOR_TOP := 19

## The chambers, as their air volumes. The gallery is the spine; the other four
## hang off it and share its walls.
const GALLERY_LO := Vector3i(54, 0, 44)
const GALLERY_HI := Vector3i(71, HEAD, 87)
## Where the player arrives, and the only way back to the island.
const ANTE_LO := Vector3i(40, 0, 91)
const ANTE_HI := Vector3i(83, HEAD, 126)
## A sunken basin, dry for a very long time.
const CISTERN_LO := Vector3i(15, 0, 50)
const CISTERN_HI := Vector3i(50, HEAD, 85)
## Niches cut into the far wall, and a bench under them.
const RELIC_LO := Vector3i(75, 0, 50)
const RELIC_HI := Vector3i(110, HEAD, 85)
## Behind the gate: whatever the vault was built to hold.
const INNER_LO := Vector3i(40, 0, 5)
const INNER_HI := Vector3i(83, HEAD, 40)

## The cistern's floor is deep enough to sink a basin into without cutting
## through it.
const CISTERN_CAP := 5
const BASIN_DEPTH := 3

## Where the player is put down when they come in: inside the antechamber,
## clear of the doorway, facing down the vault.
var entry := Vector3.ZERO
## The doorway back to the surface, and the gate into the inner vault.
var exit_door := Vector3.ZERO
var gate := Vector3.ZERO
## Cistern, reliquary, inner vault - the order the puzzle expects to be lit in
## is not this one; any two of the first two open the gate.
var braziers: Array[Vector3] = []
## The plinth in the antechamber, where a cut cap has been left burning.
var cap_rest := Vector3.ZERO


## Builds the whole vault and fills in the anchors. One pass, on the main
## thread, so it is written to touch each voxel once where it can.
func build() -> VoxelRoom:
	var room := VoxelRoom.new()
	var stone := VoxelDefs.SANDSTONE
	room.chamber(GALLERY_LO, GALLERY_HI, WALL, CAP, stone)
	room.chamber(ANTE_LO, ANTE_HI, WALL, CAP, stone)
	room.chamber(CISTERN_LO, CISTERN_HI, WALL, CISTERN_CAP, stone)
	room.chamber(RELIC_LO, RELIC_HI, WALL, CAP, stone)
	room.chamber(INNER_LO, INNER_HI, WALL, CAP, stone)
	_cut_doors(room)
	_furnish(room)
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
	room.carve(Vector3i(mx - 5, 0, ANTE_HI.z + 1),
		Vector3i(mx + 5, DOOR_TOP - 1, ANTE_HI.z + WALL + 1))


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
## of the building.
func _furnish(room: VoxelRoom) -> void:
	var stone := VoxelDefs.STONE
	var sandstone := VoxelDefs.SANDSTONE

	# Antechamber: a low plinth with the cut cap on it, and a bench along the
	# wall. The plinth is the first thing lit when the player comes in, so it
	# stands square in front of the door.
	room.fill(Vector3i(58, 0, 100), Vector3i(66, 7, 108), stone)
	room.fill(Vector3i(41, 0, 96), Vector3i(46, 4, 120), sandstone)

	# Cistern: a basin sunk into the floor, and the rubble of whatever fell in
	# and was never fished out.
	room.carve(Vector3i(22, -BASIN_DEPTH, 58), Vector3i(43, -1, 79))
	room.fill(Vector3i(17, 0, 81), Vector3i(24, 3, 85), stone)
	room.fill(Vector3i(19, 0, 78), Vector3i(22, 1, 80), stone)

	# Reliquary: shelves cut into the far wall, one of them with something
	# still on it, and a bench under them. Two voxels deep into a three voxel
	# wall, so the room stays sealed.
	for z0 in [58, 70]:
		room.carve(Vector3i(RELIC_HI.x + 1, 8, z0),
			Vector3i(RELIC_HI.x + 2, 15, z0 + 6))
	room.fill(Vector3i(RELIC_HI.x + 1, 12, 71), Vector3i(RELIC_HI.x + 2, 13, 74),
		stone)
	room.fill(Vector3i(88, 0, 81), Vector3i(108, 3, 85), sandstone)

	# Inner vault: the plinth the vault was built around, a column snapped off
	# short, and the blocks it dropped.
	room.fill(Vector3i(55, 0, 12), Vector3i(70, 9, 27), stone)
	room.fill(Vector3i(45, 0, 8), Vector3i(50, 14, 13), stone)
	room.fill(Vector3i(74, 0, 30), Vector3i(80, 5, 35), stone)
	room.fill(Vector3i(76, 0, 12), Vector3i(79, 2, 15), stone)


## The anchors, in metres. Everything that is not masonry is placed off these,
## so moving a room moves what stands in it.
func _anchors() -> void:
	var mx := float((GALLERY_LO.x + GALLERY_HI.x) / 2) * VS
	# A pace inside the antechamber's door, looking down the vault. The floor
	# is the top of the air volume's bottom, which is y = 0, and a fingernail
	# of clearance keeps the capsule off it.
	entry = Vector3(mx, 0.05, float(ANTE_HI.z - 8) * VS)
	exit_door = Vector3(mx, 0.0, float(ANTE_HI.z + 1) * VS)
	gate = Vector3(mx, 0.0, float(GALLERY_LO.z - 2) * VS)
	cap_rest = Vector3(float(62) * VS, float(8) * VS, float(104) * VS)
	braziers = [
		Vector3(float(46) * VS, 0.0, float(54) * VS),
		Vector3(float(86) * VS, 0.0, float(56) * VS),
		Vector3(mx, 0.0, float(33) * VS),
	]
