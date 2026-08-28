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

var world_seed: int = 1337

var _n_cont := FastNoiseLite.new()
var _n_hill := FastNoiseLite.new()
var _n_detail := FastNoiseLite.new()
var _n_dune := FastNoiseLite.new()
var _n_biome := FastNoiseLite.new()
var _n_forest := FastNoiseLite.new()


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


## 0.0 = pure grassland, 1.0 = pure desert.
func biome_at(mx: float, mz: float) -> float:
	var b := _n_biome.get_noise_2d(mx, mz)
	return smoothstep(0.02, 0.26, b)


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

	if b < 0.5:
		var forest: float = maxf(_n_forest.get_noise_2d(mx, mz), 0.0)
		var density: float = 0.20 + forest * 0.55
		density *= 1.0 - b * 1.6
		if roll < density:
			return {"kind": "tree", "x": wx, "z": wz}
		if roll < density + 0.08:
			return {"kind": "boulder", "x": wx, "z": wz}
		# Mushrooms favour the shady, densely wooded spots, so they come up in
		# small groves rather than being spread evenly over the grassland.
		if roll < density + 0.08 + 0.035 + forest * 0.10:
			return {"kind": "mushroom", "x": wx, "z": wz}
	else:
		if roll < 0.10 * b:
			return {"kind": "cactus", "x": wx, "z": wz}
		if roll < 0.10 * b + 0.10:
			return {"kind": "boulder", "x": wx, "z": wz}
	return {}
