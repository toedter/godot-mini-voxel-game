class_name TerrainGen
extends RefCounted

## Deterministic, thread-safe terrain description.
##
## The world is a single island: a heightmap of 10 cm voxel columns that rises
## out of the sea, plus sparse "feature" voxels (trees, cacti, boulders,
## mushrooms, grass blades) that are placed per feature cell. Outside the
## island the same heightmap keeps going as a sea bed, so the coast, the
## shallows and the open water are all one continuous surface.

const VS := VoxelDefs.VOXEL_SIZE
## Size of a feature cell in voxels (equals one chunk => 6.4 m).
const FEATURE_CELL := VoxelDefs.CHUNK_SIZE

## How far (meters) the biome mask is displaced before it is sampled. This is
## what turns the border into a meandering line with bays and peninsulas.
const BIOME_WARP := 42.0
## How strongly the fine grained edge noise may push a column across the
## grass/sand decision. Since the mask runs from 0 to 1 and the decision sits
## at 0.5, only columns that are already close to the border can be flipped.
const BIOME_EDGE_JITTER := 0.42

## World Y of the sea surface.
const SEA_LEVEL := VoxelDefs.SEA_LEVEL
## Distance (m) from the origin to the average waterline.
const ISLAND_RADIUS := 400.0
## How far (m) the coastline noise may pull the waterline in or out. Large
## enough for proper headlands and deep bays, small against the radius so the
## island never breaks apart.
const COAST_WARP := 110.0
## Height (m) the island's core is lifted above the waterline before the hills
## and dunes are added on top.
const ISLAND_DOME := 13.0
## World Y of the flat sea floor out in open water.
const SEA_FLOOR := 3.0
## Mean of the raw land height field, subtracted to get the local relief.
const LAND_MEAN := 12.0
## Never let a column fall below this, columns start at y = 0.
const MIN_HEIGHT := 0.5

var world_seed: int = 1337

var _n_cont := FastNoiseLite.new()
var _n_hill := FastNoiseLite.new()
var _n_detail := FastNoiseLite.new()
var _n_dune := FastNoiseLite.new()
var _n_biome := FastNoiseLite.new()
var _n_forest := FastNoiseLite.new()
var _n_warp_x := FastNoiseLite.new()
var _n_warp_z := FastNoiseLite.new()
var _n_edge := FastNoiseLite.new()
var _n_coast := FastNoiseLite.new()


func _init(s: int = 1337) -> void:
	world_seed = s

	_n_cont.seed = s
	_n_cont.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_cont.frequency = 0.0035
	_n_cont.fractal_octaves = 3

	_n_hill.seed = s + 11
	_n_hill.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_hill.frequency = 0.018
	_n_hill.fractal_octaves = 3

	_n_detail.seed = s + 23
	_n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_detail.frequency = 0.09
	_n_detail.fractal_octaves = 2

	_n_dune.seed = s + 37
	_n_dune.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_dune.frequency = 0.022
	_n_dune.fractal_octaves = 2

	_n_biome.seed = s + 53
	_n_biome.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_biome.frequency = 0.0016
	_n_biome.fractal_octaves = 2

	_n_forest.seed = s + 71
	_n_forest.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_forest.frequency = 0.012

	# The two warp fields are sampled with several octaves so the border wanders
	# on more than one scale: broad bays plus smaller nooks along their shore.
	_n_warp_x.seed = s + 89
	_n_warp_x.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_warp_x.frequency = 0.004
	_n_warp_x.fractal_octaves = 3

	_n_warp_z.seed = s + 97
	_n_warp_z.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_warp_z.frequency = 0.004
	_n_warp_z.fractal_octaves = 3

	_n_edge.seed = s + 103
	_n_edge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_edge.frequency = 0.075
	_n_edge.fractal_octaves = 3

	# Low base frequency with several octaves: broad lobes and peninsulas with
	# smaller coves cut into them.
	_n_coast.seed = s + 131
	_n_coast.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_coast.frequency = 0.0016
	_n_coast.fractal_octaves = 4
	_n_coast.fractal_gain = 0.45


## 0.0 = pure grassland, 1.0 = pure desert. Continuous, so the terrain height
## and the haze can cross fade over the whole width of the border region.
func biome_at(mx: float, mz: float) -> float:
	# Domain warping: the mask itself is smooth and would meet the 0.5 level
	# along a near straight line, so the sample point is displaced first.
	var wx := mx + _n_warp_x.get_noise_2d(mx, mz) * BIOME_WARP
	var wz := mz + _n_warp_z.get_noise_2d(mx, mz) * BIOME_WARP
	var b := _n_biome.get_noise_2d(wx, wz)
	# A wide band keeps the gradient gentle, which gives the dithering below
	# enough room to spread the two ground materials into each other.
	return smoothstep(-0.06, 0.34, b)


## Whether the ground at this spot is sand rather than grass. Close to the
## border a mid frequency noise decides, so the two materials interlock in
## patches over several metres instead of meeting along a clean edge.
func is_desert(mx: float, mz: float) -> bool:
	return biome_at(mx, mz) + _n_edge.get_noise_2d(mx, mz) * BIOME_EDGE_JITTER >= 0.5


## Distance from the island's centre, normalised so that 1.0 is the average
## waterline. Below 1.0 is land, above it the sea bed drops away.
##
## The radius is displaced by a multi octave noise field rather than by a
## function of the angle: that keeps the outline continuous while still
## producing headlands, deep bays and the odd offshore shallow.
func shore_u(mx: float, mz: float) -> float:
	var d := sqrt(mx * mx + mz * mz) + _n_coast.get_noise_2d(mx, mz) * COAST_WARP
	return d / ISLAND_RADIUS


## The land/sea profile, ignoring the local hills. 1.0 on the island's dome,
## 0.0 at the waterline.
func land_amount(mx: float, mz: float) -> float:
	return smoothstep(1.0, 0.62, shore_u(mx, mz))


func height_meters(mx: float, mz: float) -> float:
	var b := biome_at(mx, mz)
	var cont := _n_cont.get_noise_2d(mx, mz)
	var base := LAND_MEAN + cont * 9.0

	var hills := _n_hill.get_noise_2d(mx, mz) * 2.6 + _n_detail.get_noise_2d(mx, mz) * 0.5
	var grass_h := base + hills

	var dune := absf(_n_dune.get_noise_2d(mx, mz))
	var desert_h := base * 0.92 + 1.5 + dune * 4.5 \
		+ _n_detail.get_noise_2d(mx, mz) * 0.45 \
		+ _n_hill.get_noise_2d(mx * 1.7, mz * 1.7) * 0.6

	# The hills, dunes and continental swell are only the *relief*; where that
	# relief sits vertically is decided by the island profile below.
	var relief := lerpf(grass_h, desert_h, b) - LAND_MEAN

	var u := shore_u(mx, mz)
	# Depth profile of the sea bed, in metres below the waterline. It drops
	# away quickly for the first stretch, so that water within sight of the
	# beach is already properly deep, and then eases onto the shelf that runs
	# out to the open sea.
	var near := smoothstep(1.0, 1.18, u)
	var far := smoothstep(1.18, 1.95, u)
	var depth := 6.0 * near + (SEA_LEVEL - SEA_FLOOR - 6.0) * far
	# Carries on from the waterline up onto the island's dome. Its range meets
	# the sea bed's at u = 1.0, which is therefore where the coast sits before
	# the local relief pushes it in or out.
	var land := smoothstep(1.0, 0.62, u)
	var profile := SEA_LEVEL - depth + ISLAND_DOME * land

	# Relief is damped under water so the sea bed stays a calm slope, but not
	# removed: what is left keeps the coastline ragged and carves the odd
	# lagoon or sand bar out of the shallows.
	return maxf(profile + relief * lerpf(0.28, 1.0, land), MIN_HEIGHT)


## Height of a column in voxels (the column occupies y = 0 .. h-1).
func height_at(wx: int, wz: int) -> int:
	return int(floor(height_meters(float(wx) * VS, float(wz) * VS) / VS))


## World-space Y (meters) of the ground surface at a world XZ position.
func ground_y(x: float, z: float) -> float:
	return float(height_at(int(floor(x / VS)), int(floor(z / VS)))) * VS


## Whether the ground at this spot lies below the sea surface.
func is_submerged(x: float, z: float) -> bool:
	return height_meters(x, z) < SEA_LEVEL


## Top of the beach: the height up to which the shore is washed often enough to
## stay bare sand. Jittered so the sand does not stop along a perfect contour.
func beach_top(mx: float, mz: float) -> float:
	return SEA_LEVEL + 1.25 + _n_edge.get_noise_2d(mx * 0.55, mz * 0.55) * 0.9


# --------------------------------------------------------------------------
# deterministic hashing
# --------------------------------------------------------------------------

static func hash2i(a: int, b: int, salt: int) -> int:
	var h := a * 73856093 ^ b * 19349663 ^ salt * 83492791
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


func rand01(a: int, b: int, salt: int) -> float:
	return float(hash2i(a, b, salt ^ world_seed)) / 2147483647.0


# --------------------------------------------------------------------------
# features
# --------------------------------------------------------------------------

## Describes the feature (if any) rooted in the given feature cell.
## Returns an empty dictionary when the cell is empty.
func feature_in_cell(cell_x: int, cell_z: int) -> Dictionary:
	var jx := rand01(cell_x, cell_z, 1)
	var jz := rand01(cell_x, cell_z, 2)
	var roll := rand01(cell_x, cell_z, 3)

	var wx := cell_x * FEATURE_CELL + int(jx * float(FEATURE_CELL))
	var wz := cell_z * FEATURE_CELL + int(jz * float(FEATURE_CELL))
	var mx := float(wx) * VS
	var mz := float(wz) * VS
	var b := biome_at(mx, mz)

	# Nothing takes root in the surf. Boulders are allowed a little lower than
	# the plants, so the shore keeps a few rocks standing in the shallows.
	var ground := height_meters(mx, mz)
	if ground < SEA_LEVEL - 1.2:
		return {}
	var planted := ground >= beach_top(mx, mz)

	# Uses the same dithered decision as the ground material, so a lone patch of
	# sand inside the grassland grows cacti and a green nook keeps its trees.
	if not is_desert(mx, mz):
		var forest: float = maxf(_n_forest.get_noise_2d(mx, mz), 0.0)
		var density: float = 0.20 + forest * 0.55
		# Thins the woods out towards the desert without cutting them off
		# before the border is actually reached.
		density *= maxf(1.0 - b * 1.15, 0.08)
		if roll < density:
			if planted:
				return {"kind": "tree", "x": wx, "z": wz}
			return {}
		if roll < density + 0.08:
			return {"kind": "boulder", "x": wx, "z": wz}
		# Mushrooms favour the shady, densely wooded spots, so they come up in
		# small groves rather than being spread evenly over the grassland.
		if roll < density + 0.08 + 0.035 + forest * 0.10:
			if planted:
				return {"kind": "mushroom", "x": wx, "z": wz}
			return {}
	else:
		if roll < 0.04 + 0.08 * b:
			if planted:
				return {"kind": "cactus", "x": wx, "z": wz}
			return {}
		if roll < 0.04 + 0.08 * b + 0.10:
			return {"kind": "boulder", "x": wx, "z": wz}
	return {}
