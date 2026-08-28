class_name VoxelDefs
extends RefCounted

## Global constants and the material palette of the voxel world.

## Edge length of a single voxel in meters (10 cm).
const VOXEL_SIZE := 0.1
## Number of voxel columns along X and Z of one chunk (6.4 m).
const CHUNK_SIZE := 64
## Side length of a chunk in meters.
const CHUNK_METERS := CHUNK_SIZE * VOXEL_SIZE

const AIR := 0
const GRASS := 1
const DIRT := 2
const SAND := 3
const SANDSTONE := 4
const STONE := 5
const WOOD := 6
const LEAF := 7
const CACTUS := 8
const BLADE := 9

const COLORS := {
	GRASS: Color(0.310, 0.600, 0.180),
	DIRT: Color(0.400, 0.290, 0.190),
	SAND: Color(0.855, 0.780, 0.545),
	SANDSTONE: Color(0.690, 0.590, 0.395),
	STONE: Color(0.560, 0.560, 0.545),
	WOOD: Color(0.395, 0.275, 0.175),
	LEAF: Color(0.235, 0.500, 0.155),
	CACTUS: Color(0.275, 0.500, 0.235),
	BLADE: Color(0.360, 0.680, 0.210),
}

## Per-material strength of the random per-voxel brightness variation.
## Ground materials get more contrast so single 10 cm voxels stay readable.
const TINT := {
	GRASS: 0.26,
	DIRT: 0.16,
	SAND: 0.24,
	SANDSTONE: 0.18,
	STONE: 0.16,
	WOOD: 0.10,
	LEAF: 0.13,
	CACTUS: 0.09,
	BLADE: 0.22,
}

## Material shown on the vertical sides underneath the surface voxel.
const SUBSURFACE := {
	GRASS: DIRT,
	DIRT: DIRT,
	SAND: SANDSTONE,
	SANDSTONE: SANDSTONE,
	STONE: STONE,
}

## Materials that the player collides with (leaves and grass are walk-through).
const SOLID_FEATURES := {WOOD: true, CACTUS: true, STONE: true}

## Returns the material colour; the alpha channel carries the per-voxel tint
## strength, which the voxel shader reads (the surface itself stays opaque).
static func color_of(mat: int) -> Color:
	var c: Color = COLORS.get(mat, Color.MAGENTA)
	c.a = TINT.get(mat, 0.12)
	return c
