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
## The gallery's ceiling is vaulted rather than flat: a true semicircle across
## its own width, so the crown rises exactly half that width above HEAD.
const GALLERY_RISE := (GALLERY_HI.x - GALLERY_LO.x) / 2
## The chamber needs a thicker cap than an ordinary one so there is still roof
## standing once the crown is carved out of it, plus a little to spare.
const GALLERY_CAP := CAP + GALLERY_RISE + CAP
## Where the player arrives, and the only way back to the island.
const ANTE_LO := Vector3i(40 * SCALE, 0, 91 * SCALE)
const ANTE_HI := Vector3i(83 * SCALE, HEAD, 126 * SCALE)
## A sunken basin, dry for a very long time.
const CISTERN_LO := Vector3i(15 * SCALE, 0, 50 * SCALE)
const CISTERN_HI := Vector3i(50 * SCALE, HEAD, 85 * SCALE)
## Niches cut into the far wall, and a bench under them.
const RELIC_LO := Vector3i(75 * SCALE, 0, 50 * SCALE)
const RELIC_HI := Vector3i(110 * SCALE, HEAD, 85 * SCALE)
## Behind the gate: whatever the vault was built to hold - an inner sanctum,
## a single square chamber on the gallery's own axis with the last brazier
## standing in the middle of it. Its near edge is where the gallery's far wall
## is, so the door cut between them opens straight onto it, and it is centred
## on the gallery's centre line rather than on its footprint, so walking in
## from the gallery puts the brazier dead ahead.
const INNER_MX := (GALLERY_LO.x + GALLERY_HI.x) / 2
const INNER_HALF := 18 * SCALE
const INNER_DEPTH := 36 * SCALE
const INNER_HI := Vector3i(INNER_MX + INNER_HALF, HEAD, 40 * SCALE)
const INNER_LO := Vector3i(INNER_MX - INNER_HALF, 0, INNER_HI.z - INNER_DEPTH + 1)

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
## Sconces mounted on the antechamber's own walls: {pos, yaw}. Deliberately
## confined to the one chamber that is already "solved" the moment the player
## arrives - a little warmth at the threshold, not light carried into the
## puzzle. Everywhere past the gallery door stays exactly as dark as the three
## braziers were built to matter.
var wall_torches: Array[Dictionary] = []
## Barrels and crates standing against the walls: {kind, pos, yaw}. Set
## dressing only - nothing here is interactive, and nothing here throws light.
var clutter: Array[Dictionary] = []


## Clear size (m) of a doorway. The gate that fills one is built from this
## rather than from a default of its own: the plan cuts the hole, so the plan
## is what knows how big it is.
func door_clear() -> Vector2:
	return Vector2(float(DOOR_HALF * 2 + 1), float(DOOR_TOP + 1)) * VS


## Builds the whole vault and fills in the anchors. One pass, on the main
## thread, so it is written to touch each voxel once where it can.
func build() -> VoxelRoom:
	var room := VoxelRoom.new()
	# Walls are dressed brick - the pale, warm stone a vault was built out of,
	# rather than the raw sandstone of the cliffs the ruin above sits on. The
	# floor and the ceiling are their own materials again, so a chamber reads
	# as built: grey flagstone underfoot, boarded timber overhead.
	var brick := VoxelDefs.BRICK
	var floor_stone := VoxelDefs.FLOOR_STONE
	var wood := VoxelDefs.WOOD
	# The gallery alone is vaulted rather than flat-capped: its timber is bent
	# over a barrel arch instead of laid flat, which is the one place in the
	# vault where the ceiling is worth looking at.
	room.chamber(GALLERY_LO, GALLERY_HI, WALL, GALLERY_CAP, brick, floor_stone, wood)
	room.vault_ceiling(GALLERY_LO, GALLERY_HI, GALLERY_RISE)
	room.chamber(ANTE_LO, ANTE_HI, WALL, CAP, brick, floor_stone, wood)
	room.chamber(CISTERN_LO, CISTERN_HI, WALL, CAP, brick, floor_stone, wood)
	room.chamber(RELIC_LO, RELIC_HI, WALL, CAP, brick, floor_stone, wood)
	room.chamber(INNER_LO, INNER_HI, WALL, CAP, brick, floor_stone, wood)
	# Boarded after every ceiling is standing, and after the gallery's has been
	# carved into its arch: the boarding follows whatever shape it finds, so
	# curving a ceiling it had already been laid on would strip the timber
	# straight back off again.
	room.plank_ceiling(GALLERY_LO, GALLERY_HI, WALL, GALLERY_CAP, wood, 0x1a01)
	room.plank_ceiling(ANTE_LO, ANTE_HI, WALL, CAP, wood, 0x1a02)
	room.plank_ceiling(CISTERN_LO, CISTERN_HI, WALL, CAP, wood, 0x1a03)
	room.plank_ceiling(RELIC_LO, RELIC_HI, WALL, CAP, wood, 0x1a04)
	room.plank_ceiling(INNER_LO, INNER_HI, WALL, CAP, wood, 0x1a05)
	_furnish(room)
	# Cut last, so a piece of furniture that lands on a doorway never gets the
	# last word: the way through is carved back open regardless of what stood
	# there a moment before.
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

	# Inner sanctum: four squat piers standing clear of the walls, and a single
	# low step ringing the middle of the floor, so the last brazier stands on
	# something rather than in the centre of an empty box. The step is filled
	# and then carved hollow again: the brazier and whoever comes to light it
	# both stand on the floor itself, inside the ring, not on top of it.
	var sc := _inner_center_voxel()
	for dx: int in [-1, 1]:
		for dz: int in [-1, 1]:
			var px := sc.x + dx * 11 * SCALE
			var pz := sc.y + dz * 11 * SCALE
			room.fill(Vector3i(px - 2 * SCALE, 0, pz - 2 * SCALE),
				Vector3i(px + 2 * SCALE, HEAD, pz + 2 * SCALE), sandstone)
	room.fill(Vector3i(sc.x - 5 * SCALE, 0, sc.y - 5 * SCALE),
		Vector3i(sc.x + 5 * SCALE, 1 * SCALE, sc.y + 5 * SCALE), stone)
	room.carve(Vector3i(sc.x - 4 * SCALE, 0, sc.y - 4 * SCALE),
		Vector3i(sc.x + 4 * SCALE, 1 * SCALE, sc.y + 4 * SCALE))


## The middle of the inner sanctum's floor, in voxels (x, z).
func _inner_center_voxel() -> Vector2i:
	return Vector2i((INNER_LO.x + INNER_HI.x) / 2, (INNER_LO.z + INNER_HI.z) / 2)


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
	# The last of the three is what the gate is for, so it stands in the middle
	# of the inner sanctum, inside its ring of piers.
	var inner := _inner_center_voxel()
	braziers = [
		Vector3(float(19 * SCALE) * VS, 0.0, float(54 * SCALE) * VS),
		Vector3(float(104 * SCALE) * VS, 0.0, float(54 * SCALE) * VS),
		Vector3(float(inner.x) * VS, 0.0, float(inner.y) * VS),
	]
	wall_torches = _wall_torch_anchors()
	clutter = _clutter_anchors()


## A wall-mounted sconce, in metres: low enough to read as hand height, and
## the yaw that turns its bracket away from the wall to face into the room.
## `WallTorch` builds its arm and flame along its own -Z, so the direction a
## yaw of 0 projects is world -Z; matching that to an arbitrary `facing`
## takes the negative of both its components, not just the Z one - the sign
## this previously dropped was what had every sconce built facing back into
## the masonry it is mounted on rather than out into the room.
func _wall_torch(x: int, z: int, facing: Vector3) -> Dictionary:
	return {
		"pos": Vector3(float(x) * VS, 1.6, float(z) * VS),
		"yaw": atan2(-facing.x, -facing.z),
	}


## Sconces for the antechamber alone, two pairs facing each other across the
## room: one flanking the way in from the surface, one either side of the
## plinth. The one chamber the player is never in the dark in reads as lit by
## more than the torch they are about to carry through the rest of the vault.
func _wall_torch_anchors() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	var near_entry := ANTE_HI.z - 12 * SCALE
	var near_plinth := ANTE_LO.z + 10 * SCALE
	# The low wall's inner face sits exactly at its own coordinate; the high
	# wall's is one voxel past its own, since `chamber` fills that wall
	# starting at hi + 1 rather than at hi itself.
	list.append(_wall_torch(ANTE_LO.x, near_entry, Vector3.RIGHT))
	list.append(_wall_torch(ANTE_HI.x + 1, near_entry, Vector3.LEFT))
	list.append(_wall_torch(ANTE_LO.x, near_plinth, Vector3.RIGHT))
	list.append(_wall_torch(ANTE_HI.x + 1, near_plinth, Vector3.LEFT))
	return list


## A barrel or crate standing on the floor, in metres. `x1`/`z1` are the
## plan's own unscaled units, exactly like the furniture in `_furnish`, so a
## piece of clutter can be placed by eye against the room it is dressing
## rather than against the doubled numbers `SCALE` turns them into.
func _clutter(kind: String, x1: int, z1: int, yaw: float = 0.0) -> Dictionary:
	return {
		"kind": kind,
		"pos": Vector3(float(x1 * SCALE) * VS, 0.0, float(z1 * SCALE) * VS),
		"yaw": yaw,
	}


## Barrels and crates: nothing here is a puzzle piece, only the cargo a vault
## this size would actually have been stocked with, standing clear of the
## doorways and of the furniture `_furnish` already built.
func _clutter_anchors() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	# Antechamber: flanking the way in, and again by the plinth.
	list.append(_clutter("barrel", 48, 122))
	list.append(_clutter("crate", 74, 122, 0.3))
	list.append(_clutter("crate", 52, 96, -0.2))
	list.append(_clutter("barrel", 72, 96))
	# The gallery spine, the same corridor clutter reads as everywhere else.
	list.append(_clutter("barrel", 56, 50))
	list.append(_clutter("crate", 69, 80, 0.4))
	# One more just inside where each side chamber's own door lets onto the
	# gallery.
	list.append(_clutter("barrel", 48, 63))
	list.append(_clutter("crate", 81, 63, -0.3))
	return list
