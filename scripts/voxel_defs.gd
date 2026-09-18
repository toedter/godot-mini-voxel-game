class_name VoxelDefs
extends RefCounted

## Global constants and the material palette of the voxel world.

## Edge length of a single voxel in meters (10 cm).
const VOXEL_SIZE := 0.1
## Number of voxel columns along X and Z of one chunk (6.4 m).
const CHUNK_SIZE := 64
## Side length of a chunk in meters.
const CHUNK_METERS := CHUNK_SIZE * VOXEL_SIZE
## World Y (meters) the island's terrain is shaped around: the height the coast
## profile, the beach band and the alpine lines are all measured from.
##
## This is a property of the *land*, not of the water, and it must stay fixed.
## The generator is a pure function of it, so moving it regenerates the island
## - a different coastline, relocated snow lines, trees appearing and vanishing.
##
## The height the water actually stands at is `VoxelWorld.water_level`, which
## is free to move at runtime and starts out equal to this datum. Anything
## asking "am I under water", "how deep is this" or "where do I draw the sea"
## wants that one. Only the terrain generator wants this one.
const SEA_DATUM := 18.0

## How far above the datum the tide's flood notch stands, in metres.
##
## The lock's own `notches` are the authored copy of this and are free to
## differ; what needs the number here is the masonry, which is generated on
## worker threads that can see neither the scene nor the lock, and which has to
## carry the lock above the water it lets in.
const TIDE_FLOOD := 6.0

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
const SHROOM_STEM := 10
const SHROOM_CAP := 11
const SHROOM_GLOW := 12
const SEABED := 13
const SNOW := 14
const ICE := 15
## The shaded side of a canopy. A crown is built from many small clumps, and the
## ones hanging under the limbs or tucked in against the trunk are given this
## instead of LEAF: without it a tree is one flat green and reads as a blob,
## with it the crown has a lit top and a dark underside from any angle, which is
## most of what makes a voxel tree look like foliage rather than like a shape.
const LEAF_DARK := 16
## The seam between two blocks of coursed masonry. Warm to match the
## sandstone wall it textures. Only ever appears baked into an interior's own
## static mesh - never part of the streamed terrain - so it needs no
## subsurface or collision entry.
const MORTAR := 29
## A vault floor's own coursed stone, dark rather than the general-purpose
## `STONE` furniture is still cut from, plus its own darker mortar, so a
## floor reads as its own, colder material next to the warm sandstone walls
## it sits between.
const FLOOR_STONE := 30
const FLOOR_MORTAR := 31
## Tonal siblings of `BRICK` and `FLOOR_STONE` that `VoxelRoom.mason` and
## `mason_flagstone` pick between one whole stone at a time, so a course or a
## flagstone floor is quarried from several honestly different-coloured rocks
## rather than one swatch stamped over and over. `SANDSTONE` keeps its own
## three for the ruin above.
const SANDSTONE_LIGHT := 32
const SANDSTONE_DARK := 33
const SANDSTONE_WARM := 34
const FLOOR_STONE_LIGHT := 35
const FLOOR_STONE_DARK := 36
const FLOOR_STONE_PALE := 37
## The dressed brick a vault's walls are built from: paler and warmer than the
## raw `SANDSTONE` the cliffs and the ruin above are made of, because a wall
## quarried into blocks and laid by hand does not read as the rock it was cut
## out of. Its own material rather than a recoloured `SANDSTONE` so that
## retuning the vault's walls never moves the colour of the island.
const BRICK := 38
const BRICK_LIGHT := 39
const BRICK_DARK := 40
const BRICK_WARM := 41
## Ceiling timber: the boards themselves in three tones, and the darker
## `BEAM` the joists and every board-to-board seam are drawn in.
const WOOD_LIGHT := 42
const WOOD_DARK := 43
const BEAM := 44
## Half-tones standing between a stone and the groove of mortar beside it.
## A voxel is either stone or mortar and nothing between, so a joint one voxel
## wide is a hard step from one to the other and every seam in the vault reads
## as the same stair-stepped line. Scattering these along the joint - only
## some of the voxels on it, not all - dithers that step into two, which at
## arm's length is what makes a wall read as rough masonry rather than as a
## grid drawn on a screen.
const MORTAR_EDGE := 45
const FLOOR_MORTAR_EDGE := 46

## Mushroom species. Each one is a cap colour paired with the bioluminescent
## colour of its gills (which is also the colour of the light it throws). The
## stem is shared and stays pale; what changes from species to species is the
## cap and the glow underneath it, so a grove reads as several kinds at once.
const CAP_VIOLET := 17
const CAP_TEAL := 18
const CAP_EMERALD := 19
const CAP_AMBER := 20
const CAP_AZURE := 21
const CAP_MAGENTA := 22
const GILL_VIOLET := 23
const GILL_TEAL := 24
const GILL_EMERALD := 25
const GILL_AMBER := 26
const GILL_AZURE := 27
const GILL_MAGENTA := 28

## A mushroom rolls one of these; it carries the cap and the gill material the
## shape is built from.
const SHROOM_SPECIES := [
	{"cap": CAP_VIOLET, "gill": GILL_VIOLET},
	{"cap": CAP_TEAL, "gill": GILL_TEAL},
	{"cap": CAP_EMERALD, "gill": GILL_EMERALD},
	{"cap": CAP_AMBER, "gill": GILL_AMBER},
	{"cap": CAP_AZURE, "gill": GILL_AZURE},
	{"cap": CAP_MAGENTA, "gill": GILL_MAGENTA},
]

const COLORS := {
	GRASS: Color(0.310, 0.600, 0.180),
	DIRT: Color(0.400, 0.290, 0.190),
	SAND: Color(0.855, 0.780, 0.545),
	SANDSTONE: Color(0.690, 0.590, 0.395),
	STONE: Color(0.560, 0.560, 0.545),
	WOOD: Color(0.395, 0.275, 0.175),
	LEAF: Color(0.255, 0.545, 0.170),
	LEAF_DARK: Color(0.140, 0.345, 0.115),
	CACTUS: Color(0.275, 0.500, 0.235),
	BLADE: Color(0.360, 0.680, 0.210),
	SHROOM_STEM: Color(0.780, 0.735, 0.690),
	SHROOM_CAP: Color(0.360, 0.170, 0.480),
	SHROOM_GLOW: Color(0.640, 0.380, 0.900),
	CAP_VIOLET: Color(0.360, 0.170, 0.480),
	CAP_TEAL: Color(0.085, 0.355, 0.410),
	CAP_EMERALD: Color(0.130, 0.415, 0.170),
	CAP_AMBER: Color(0.555, 0.295, 0.090),
	CAP_AZURE: Color(0.130, 0.245, 0.560),
	CAP_MAGENTA: Color(0.560, 0.140, 0.335),
	GILL_VIOLET: Color(0.640, 0.420, 0.950),
	GILL_TEAL: Color(0.300, 0.860, 0.820),
	GILL_EMERALD: Color(0.500, 0.950, 0.400),
	GILL_AMBER: Color(1.000, 0.660, 0.240),
	GILL_AZURE: Color(0.420, 0.600, 1.000),
	GILL_MAGENTA: Color(1.000, 0.420, 0.720),
	SEABED: Color(0.545, 0.520, 0.430),
	SNOW: Color(0.930, 0.950, 0.980),
	ICE: Color(0.735, 0.855, 0.925),
	MORTAR: Color(0.195, 0.160, 0.122),
	FLOOR_STONE: Color(0.310, 0.318, 0.336),
	FLOOR_MORTAR: Color(0.072, 0.075, 0.084),
	SANDSTONE_LIGHT: Color(0.760, 0.660, 0.470),
	SANDSTONE_DARK: Color(0.560, 0.460, 0.300),
	SANDSTONE_WARM: Color(0.630, 0.430, 0.255),
	FLOOR_STONE_LIGHT: Color(0.450, 0.460, 0.482),
	FLOOR_STONE_DARK: Color(0.170, 0.176, 0.190),
	FLOOR_STONE_PALE: Color(0.565, 0.575, 0.598),
	BRICK: Color(0.660, 0.560, 0.410),
	BRICK_LIGHT: Color(0.755, 0.655, 0.500),
	BRICK_DARK: Color(0.490, 0.395, 0.272),
	BRICK_WARM: Color(0.605, 0.460, 0.300),
	WOOD_LIGHT: Color(0.470, 0.330, 0.205),
	WOOD_DARK: Color(0.300, 0.205, 0.130),
	BEAM: Color(0.230, 0.155, 0.100),
	MORTAR_EDGE: Color(0.400, 0.335, 0.245),
	FLOOR_MORTAR_EDGE: Color(0.175, 0.180, 0.195),
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
	LEAF: 0.18,
	LEAF_DARK: 0.16,
	CACTUS: 0.09,
	BLADE: 0.22,
	SHROOM_STEM: 0.11,
	SHROOM_CAP: 0.14,
	SHROOM_GLOW: 0.08,
	CAP_VIOLET: 0.14,
	CAP_TEAL: 0.14,
	CAP_EMERALD: 0.15,
	CAP_AMBER: 0.15,
	CAP_AZURE: 0.14,
	CAP_MAGENTA: 0.15,
	GILL_VIOLET: 0.08,
	GILL_TEAL: 0.08,
	GILL_EMERALD: 0.08,
	GILL_AMBER: 0.08,
	GILL_AZURE: 0.08,
	GILL_MAGENTA: 0.08,
	SEABED: 0.20,
	SNOW: 0.09,
	ICE: 0.10,
	MORTAR: 0.22,
	FLOOR_STONE: 0.24,
	FLOOR_MORTAR: 0.22,
	SANDSTONE_LIGHT: 0.18,
	SANDSTONE_DARK: 0.18,
	SANDSTONE_WARM: 0.18,
	FLOOR_STONE_LIGHT: 0.24,
	FLOOR_STONE_DARK: 0.24,
	FLOOR_STONE_PALE: 0.24,
	BRICK: 0.26,
	BRICK_LIGHT: 0.26,
	BRICK_DARK: 0.26,
	BRICK_WARM: 0.26,
	WOOD_LIGHT: 0.10,
	WOOD_DARK: 0.10,
	BEAM: 0.09,
	MORTAR_EDGE: 0.22,
	FLOOR_MORTAR_EDGE: 0.24,
}

## Materials drawn with the glow shader, and how brightly each one lights up
## once it gets dark. Only the gills under the cap glow; the cap itself is an
## ordinary surface that stays dark until the light from the gills reaches it.
const GLOW := {
	GILL_VIOLET: 1.0,
	GILL_TEAL: 1.0,
	GILL_EMERALD: 1.0,
	GILL_AMBER: 1.0,
	GILL_AZURE: 1.0,
	GILL_MAGENTA: 1.0,
}

## Material shown on the vertical sides underneath the surface voxel.
const SUBSURFACE := {
	GRASS: DIRT,
	DIRT: DIRT,
	SAND: SANDSTONE,
	SANDSTONE: SANDSTONE,
	STONE: STONE,
	SEABED: SANDSTONE,
	# Snow and ice are a thin cover: anything more than one voxel deep shows
	# the rock of the mountain underneath.
	SNOW: STONE,
	ICE: STONE,
}

## Materials that the player collides with (leaves and grass are walk-through).
const SOLID_FEATURES := {
	WOOD: true, CACTUS: true, STONE: true,
	SHROOM_STEM: true, SHROOM_CAP: true,
	CAP_VIOLET: true, CAP_TEAL: true, CAP_EMERALD: true, CAP_AMBER: true, CAP_AZURE: true, CAP_MAGENTA: true,
}

## Returns the material colour; the alpha channel carries the per-voxel tint
## strength, which the voxel shader reads (the surface itself stays opaque).
static func color_of(mat: int) -> Color:
	var c: Color = COLORS.get(mat, Color.MAGENTA)
	c.a = TINT.get(mat, 0.12)
	return c
