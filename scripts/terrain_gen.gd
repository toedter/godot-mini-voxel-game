class_name TerrainGen
extends RefCounted

## Deterministic, thread-safe terrain description.
##
## The world is a heightmap of 10 cm voxel columns plus sparse "feature" voxels
## (trees, cacti, boulders, mushrooms, grass blades) that are placed per feature
## cell.

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


func height_meters(mx: float, mz: float) -> float:
	var b := biome_at(mx, mz)
	var cont := _n_cont.get_noise_2d(mx, mz)
	var base := 12.0 + cont * 9.0

	var hills := _n_hill.get_noise_2d(mx, mz) * 2.6 + _n_detail.get_noise_2d(mx, mz) * 0.5
	var grass_h := base + hills

	var dune := absf(_n_dune.get_noise_2d(mx, mz))
	var desert_h := base * 0.92 + 1.5 + dune * 4.5 \
		+ _n_detail.get_noise_2d(mx, mz) * 0.45 \
		+ _n_hill.get_noise_2d(mx * 1.7, mz * 1.7) * 0.6

	return lerpf(grass_h, desert_h, b)


## Height of a column in voxels (the column occupies y = 0 .. h-1).
func height_at(wx: int, wz: int) -> int:
	return int(floor(height_meters(float(wx) * VS, float(wz) * VS) / VS))


## World-space Y (meters) of the ground surface at a world XZ position.
func ground_y(x: float, z: float) -> float:
	return float(height_at(int(floor(x / VS)), int(floor(z / VS)))) * VS


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

	# Uses the same dithered decision as the ground material, so a lone patch of
	# sand inside the grassland grows cacti and a green nook keeps its trees.
	if not is_desert(mx, mz):
		var forest: float = maxf(_n_forest.get_noise_2d(mx, mz), 0.0)
		var density: float = 0.20 + forest * 0.55
		# Thins the woods out towards the desert without cutting them off
		# before the border is actually reached.
		density *= maxf(1.0 - b * 1.15, 0.08)
		if roll < density:
			return {"kind": "tree", "x": wx, "z": wz}
		if roll < density + 0.08:
			return {"kind": "boulder", "x": wx, "z": wz}
		# Mushrooms favour the shady, densely wooded spots, so they come up in
		# small groves rather than being spread evenly over the grassland.
		if roll < density + 0.08 + 0.035 + forest * 0.10:
			return {"kind": "mushroom", "x": wx, "z": wz}
	else:
		if roll < 0.04 + 0.08 * b:
			return {"kind": "cactus", "x": wx, "z": wz}
		if roll < 0.04 + 0.08 * b + 0.10:
			return {"kind": "boulder", "x": wx, "z": wz}
	return {}
