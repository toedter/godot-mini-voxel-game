class_name ChunkBuilder
extends RefCounted

## Builds the render mesh (and collision shape) of one chunk.
##
## Terrain is a heightmap, so only the visible top faces and the vertical steps
## between neighbouring columns are emitted. Top faces are merged with a 2D
## greedy algorithm, step faces are merged along their run direction. Features
## (trees, cacti, boulders, mushrooms, grass) live in a sparse voxel dictionary
## and are meshed with simple face culling.
##
## The mesh has up to three surfaces, because some voxels need their own shader:
## the static one, the wind swayed grass, and the mushroom caps that glow at
## night.

const CS := VoxelDefs.CHUNK_SIZE

## Feature voxels are held in a dictionary keyed by a packed integer rather
## than by a Vector3i. A Vector3i key allocates a variant and hashes three
## components on every read and write, and the blob fills below do hundreds of
## thousands of them per chunk; an int key is a plain machine word. X and Z are
## bounded by the chunk, Y only by the world, so Y gets the low bits and the
## other two are shifted clear of it.
const KEY_X := 21
const KEY_Z := 27
const KEY_Y_MASK := (1 << KEY_X) - 1
const KEY_XY := 63 # mask for a packed X or Z once shifted down
## Steps from one packed key to the neighbouring voxel.
const KEY_DX := 1 << KEY_X
const KEY_DZ := 1 << KEY_Z
## Edge length (m) of a voxel. Feature dimensions and the coordinates the
## terrain generator hands out are all counted in these.
const VS := VoxelDefs.VOXEL_SIZE
const MS := CS + 2 # stride of the heightmap incl. a 1 column margin

var _gen: TerrainGen
var _cx: int
var _cz: int
var _ox: int # chunk origin in world voxel coordinates
var _oz: int
var _heights := PackedInt32Array()
var _mats := PackedByteArray()
var _extras := {} # packed local voxel key -> material

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()
var _col_faces := PackedVector3Array()

# Grass tufts go into a second surface that is drawn with the wind shader.
# UV carries the sway data: x = stiffness (0 at the ground, 1 at the tip),
# y = a random phase per tuft.
var _sway_verts := PackedVector3Array()
var _sway_norms := PackedVector3Array()
var _sway_cols := PackedColorArray()
var _sway_uvs := PackedVector2Array()
var _sway_idx := PackedInt32Array()
var _sway := false
var _sway_uv := Vector2.ZERO

# Glowing mushroom voxels go into a third surface drawn with the glow shader.
# UV carries the glow data: x = how brightly the voxel lights up, y = a phase
# that is constant across one mushroom so a cap pulses as a single body.
var _glow_verts := PackedVector3Array()
var _glow_norms := PackedVector3Array()
var _glow_cols := PackedColorArray()
var _glow_uvs := PackedVector2Array()
var _glow_idx := PackedInt32Array()
var _glow := false
var _glow_uv := Vector2.ZERO
## Packed voxel key -> phase of the mushroom it belongs to. Written while the
## mushroom is placed, because the meshing pass only sees the material.
var _glow_phase := {}
## Point lights the mushroom caps cast on their surroundings, in chunk local
## space. Only filled for the chunks close enough to the player for lights.
var _lights: Array[Dictionary] = []

## Mushroom lights are real nodes and only the chunks near the player get
## them. Ground cover is not gated: every chunk grows its own, so that grass is
## never seen appearing.
var _want_lights := false
var _want_collision := true
## When set, the ground is not put into the triangle soup at all: the column
## heights are handed back instead and the world turns them into a
## HeightMapShape3D, which costs nothing to build and needs no BVH. Only the
## features still need real triangles.
var _heightmap_collision := true


static func build(gen: TerrainGen, cx: int, cz: int,
		want_lights: bool, want_collision: bool,
		heightmap_collision: bool = true) -> Dictionary:
	var b := ChunkBuilder.new()
	b._gen = gen
	b._cx = cx
	b._cz = cz
	b._ox = cx * CS
	b._oz = cz * CS
	b._want_lights = want_lights
	b._want_collision = want_collision
	b._heightmap_collision = heightmap_collision
	return b._run()


func _run() -> Dictionary:
	_sample_columns()
	_place_features()
	_mesh_terrain_top()
	_mesh_terrain_sides()
	_mesh_features()

	var result := {"cx": _cx, "cz": _cz, "mesh": null, "shape": null,
		"heights": null, "lights": _lights}
	if _want_collision and _heightmap_collision:
		# The grid the shape wants is exactly the one already sampled, margin
		# included: MS by MS, row major, in voxels. The margin is what makes
		# neighbouring chunks overlap by a column instead of leaving a seam the
		# player could catch a foot in.
		var hm := PackedFloat32Array()
		hm.resize(MS * MS)
		for i in MS * MS:
			hm[i] = float(_heights[i])
		result["heights"] = hm
	var mesh: ArrayMesh = null
	if not _verts.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _verts
		arrays[Mesh.ARRAY_NORMAL] = _norms
		arrays[Mesh.ARRAY_COLOR] = _cols
		arrays[Mesh.ARRAY_INDEX] = _idx
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if not _sway_verts.is_empty():
		var sway_arrays := []
		sway_arrays.resize(Mesh.ARRAY_MAX)
		sway_arrays[Mesh.ARRAY_VERTEX] = _sway_verts
		sway_arrays[Mesh.ARRAY_NORMAL] = _sway_norms
		sway_arrays[Mesh.ARRAY_COLOR] = _sway_cols
		sway_arrays[Mesh.ARRAY_TEX_UV] = _sway_uvs
		sway_arrays[Mesh.ARRAY_INDEX] = _sway_idx
		if mesh == null:
			mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sway_arrays)
		result["sway_surface"] = mesh.get_surface_count() - 1
	if not _glow_verts.is_empty():
		var glow_arrays := []
		glow_arrays.resize(Mesh.ARRAY_MAX)
		glow_arrays[Mesh.ARRAY_VERTEX] = _glow_verts
		glow_arrays[Mesh.ARRAY_NORMAL] = _glow_norms
		glow_arrays[Mesh.ARRAY_COLOR] = _glow_cols
		glow_arrays[Mesh.ARRAY_TEX_UV] = _glow_uvs
		glow_arrays[Mesh.ARRAY_INDEX] = _glow_idx
		if mesh == null:
			mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, glow_arrays)
		result["glow_surface"] = mesh.get_surface_count() - 1
	result["mesh"] = mesh
	if _want_collision and not _col_faces.is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(_col_faces)
		result["shape"] = shape
	return result


# --------------------------------------------------------------------------
# columns
# --------------------------------------------------------------------------

func _sample_columns() -> void:
	_gen.sample_chunk(_ox, _oz, VS, CS, _heights, _mats)


func _h(lx: int, lz: int) -> int:
	return _heights[(lz + 1) * MS + (lx + 1)]


func _m(lx: int, lz: int) -> int:
	return _mats[(lz + 1) * MS + (lx + 1)]


# --------------------------------------------------------------------------
# geometry helpers
# --------------------------------------------------------------------------

## Emits a quad. Corners must be given counter-clockwise as seen from `n`;
## Godot's front faces are clockwise, so the indices are reversed here.
## Every array here grows by a fixed amount per quad, so each one is resized
## once and then written by index. `push_back` on a packed array re-checks and
## grows its buffer on every single call, and this is the busiest function in
## the builder.
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, collide: bool) -> void:
	if _sway:
		var s := _sway_verts.size()
		var si := _sway_idx.size()
		_sway_verts.resize(s + 4)
		_sway_norms.resize(s + 4)
		_sway_cols.resize(s + 4)
		_sway_uvs.resize(s + 4)
		_sway_idx.resize(si + 6)
		_sway_verts[s] = a
		_sway_verts[s + 1] = b
		_sway_verts[s + 2] = c
		_sway_verts[s + 3] = d
		for k in 4:
			_sway_norms[s + k] = n
			_sway_cols[s + k] = col
			_sway_uvs[s + k] = _sway_uv
		_sway_idx[si] = s
		_sway_idx[si + 1] = s + 2
		_sway_idx[si + 2] = s + 1
		_sway_idx[si + 3] = s
		_sway_idx[si + 4] = s + 3
		_sway_idx[si + 5] = s + 2
		return
	if _glow:
		var g := _glow_verts.size()
		var gi := _glow_idx.size()
		_glow_verts.resize(g + 4)
		_glow_norms.resize(g + 4)
		_glow_cols.resize(g + 4)
		_glow_uvs.resize(g + 4)
		_glow_idx.resize(gi + 6)
		_glow_verts[g] = a
		_glow_verts[g + 1] = b
		_glow_verts[g + 2] = c
		_glow_verts[g + 3] = d
		for k in 4:
			_glow_norms[g + k] = n
			_glow_cols[g + k] = col
			_glow_uvs[g + k] = _glow_uv
		_glow_idx[gi] = g
		_glow_idx[gi + 1] = g + 2
		_glow_idx[gi + 2] = g + 1
		_glow_idx[gi + 3] = g
		_glow_idx[gi + 4] = g + 3
		_glow_idx[gi + 5] = g + 2
		if collide and _want_collision:
			_collide_quad(a, b, c, d)
		return
	var base := _verts.size()
	var bi := _idx.size()
	_verts.resize(base + 4)
	_norms.resize(base + 4)
	_cols.resize(base + 4)
	_idx.resize(bi + 6)
	_verts[base] = a
	_verts[base + 1] = b
	_verts[base + 2] = c
	_verts[base + 3] = d
	for k in 4:
		_norms[base + k] = n
		_cols[base + k] = col
	_idx[bi] = base
	_idx[bi + 1] = base + 2
	_idx[bi + 2] = base + 1
	_idx[bi + 3] = base
	_idx[bi + 4] = base + 3
	_idx[bi + 5] = base + 2
	if collide and _want_collision:
		_collide_quad(a, b, c, d)


func _collide_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var f := _col_faces.size()
	_col_faces.resize(f + 6)
	_col_faces[f] = a
	_col_faces[f + 1] = c
	_col_faces[f + 2] = b
	_col_faces[f + 3] = a
	_col_faces[f + 4] = d
	_col_faces[f + 5] = c


# --------------------------------------------------------------------------
# terrain meshing
# --------------------------------------------------------------------------

func _mesh_terrain_top() -> void:
	# The ground only goes into the collision triangle soup when the cheaper
	# heightmap shape is not carrying it.
	var soup := not _heightmap_collision
	var used := PackedByteArray()
	used.resize(CS * CS)
	# The row bases are hoisted and the grids indexed directly: `_h` / `_m` are
	# one array read each, but they were being reached through a function call
	# from the innermost loop of the greedy merge.
	for z in CS:
		var hrow := (z + 1) * MS + 1
		var urow := z * CS
		for x in CS:
			if used[urow + x] != 0:
				continue
			var h := _heights[hrow + x]
			var m := _mats[hrow + x]
			var w := 1
			while x + w < CS and used[urow + x + w] == 0 					and _heights[hrow + x + w] == h and _mats[hrow + x + w] == m:
				w += 1
			var d := 1
			while z + d < CS:
				var ok := true
				var hrow_d := hrow + d * MS
				var urow_d := urow + d * CS
				for i in w:
					if used[urow_d + x + i] != 0 or _heights[hrow_d + x + i] != h 							or _mats[hrow_d + x + i] != m:
						ok = false
						break
				if not ok:
					break
				d += 1
			for dz in d:
				var urow_f := urow + dz * CS
				for dx in w:
					used[urow_f + x + dx] = 1

			var y := float(h) * VS
			var x0 := float(x) * VS
			var x1 := float(x + w) * VS
			var z0 := float(z) * VS
			var z1 := float(z + d) * VS
			_quad(
				Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
				Vector3.UP, VoxelDefs.color_of(m), soup)


func _mesh_terrain_sides() -> void:
	var soup := not _heightmap_collision
	# +X / -X : runs merge along Z
	for x in CS:
		for dir: int in [1, -1]:
			# Both columns of this run sit at fixed grid columns; only the row
			# advances, so the index walks by one stride per step.
			var xc := x + 1
			var xn := x + dir + 1
			var z := 0
			while z < CS:
				var ri := (z + 1) * MS
				var h := _heights[ri + xc]
				var nh := _heights[ri + xn]
				if h <= nh:
					z += 1
					continue
				var m := _mats[ri + xc]
				var run := 1
				var rr := ri + MS
				while z + run < CS and _heights[rr + xc] == h and _heights[rr + xn] == nh 						and _mats[rr + xc] == m:
					run += 1
					rr += MS
				var px := float(x + (1 if dir > 0 else 0)) * VS
				var z0 := float(z) * VS
				var z1 := float(z + run) * VS
				for band in _bands(h, nh, m):
					var y0: float = band[0]
					var y1: float = band[1]
					var col: Color = band[2]
					if dir > 0:
						_quad(Vector3(px, y0, z1), Vector3(px, y0, z0), Vector3(px, y1, z0), Vector3(px, y1, z1),
							Vector3.RIGHT, col, soup)
					else:
						_quad(Vector3(px, y0, z0), Vector3(px, y0, z1), Vector3(px, y1, z1), Vector3(px, y1, z0),
							Vector3.LEFT, col, soup)
				z += run

	# +Z / -Z : runs merge along X
	for z in CS:
		for dir: int in [1, -1]:
			# Here it is the rows that are fixed and the column that advances.
			var rz := (z + 1) * MS + 1
			var rn := (z + dir + 1) * MS + 1
			var x := 0
			while x < CS:
				var h := _heights[rz + x]
				var nh := _heights[rn + x]
				if h <= nh:
					x += 1
					continue
				var m := _mats[rz + x]
				var run := 1
				while x + run < CS and _heights[rz + x + run] == h 						and _heights[rn + x + run] == nh and _mats[rz + x + run] == m:
					run += 1
				var pz := float(z + (1 if dir > 0 else 0)) * VS
				var x0 := float(x) * VS
				var x1 := float(x + run) * VS
				for band in _bands(h, nh, m):
					var y0: float = band[0]
					var y1: float = band[1]
					var col: Color = band[2]
					if dir > 0:
						_quad(Vector3(x0, y0, pz), Vector3(x1, y0, pz), Vector3(x1, y1, pz), Vector3(x0, y1, pz),
							Vector3.BACK, col, soup)
					else:
						_quad(Vector3(x1, y0, pz), Vector3(x0, y0, pz), Vector3(x0, y1, pz), Vector3(x1, y1, pz),
							Vector3.FORWARD, col, soup)
				x += run


## Splits a vertical step into the surface coloured top voxel and the
## sub-surface coloured remainder.
func _bands(h: int, nh: int, m: int) -> Array:
	var out := []
	var top_col := VoxelDefs.color_of(m)
	var sub_mat: int = VoxelDefs.SUBSURFACE.get(m, VoxelDefs.DIRT)
	out.append([float(h - 1) * VS, float(h) * VS, top_col])
	if h - 1 > nh:
		out.append([float(nh) * VS, float(h - 1) * VS, VoxelDefs.color_of(sub_mat)])
	return out


# --------------------------------------------------------------------------
# features
# --------------------------------------------------------------------------

## A world voxel coordinate, as `TerrainGen.feature_in_cell` hands them out, in
## this chunk's own grid.
func _to_local(v: int, origin: int) -> int:
	return v - origin


## Returns the packed key the voxel was stored under, or -1 if it fell outside
## the chunk or inside the terrain. Callers that do not care may ignore it.
func _put(x: int, y: int, z: int, mat: int) -> int:
	if x < 0 or x >= CS or z < 0 or z >= CS or y < 0:
		return -1
	# The column fills y = 0 .. h-1, so anything below h would sit inside the
	# terrain. Keeping the topmost terrain voxel too would emit a second set of
	# coplanar faces on top of the ground surface and make the two z-fight.
	if y < _heights[(z + 1) * MS + (x + 1)]:
		return -1 # buried inside the terrain
	var key := y | (x << KEY_X) | (z << KEY_Z)
	_extras[key] = mat
	return key


## Features are planted on a fixed 6.4 m grid, which is exactly one chunk, so
## the scan covers this chunk's own cell plus one either side for the parts of a
## tree or a mushroom that hang over the edge.
func _place_features() -> void:
	# One generator, reseeded per cell. Assigning `seed` restarts the stream,
	# so every feature rolls exactly what it used to; what goes away is an
	# object allocation per cell.
	var rng := RandomNumberGenerator.new()
	for fcz in range(_cz - 1, _cz + 2):
		for fcx in range(_cx - 1, _cx + 2):
			var f := _gen.feature_in_cell(fcx, fcz)
			if f.is_empty():
				continue
			var lx: int = _to_local(int(f["x"]), _ox)
			var lz: int = _to_local(int(f["z"]), _oz)
			var base_y := _gen.height_voxels(
				float(f["x"]) * VS, float(f["z"]) * VS, VS)
			rng.seed = TerrainGen.hash2i(fcx, fcz, _gen.world_seed)
			match f["kind"]:
				"tree":
					_add_tree(lx, lz, base_y, rng)
				"cactus":
					_add_cactus(lx, lz, base_y, rng)
				"boulder":
					_add_boulder(lx, lz, base_y, rng)
				"mushroom":
					_add_mushroom(lx, lz, base_y, rng, fcx, fcz)
	_add_ground_cover()
	# After the ground cover, so masonry wins over a tuft of grass standing in
	# the same voxel rather than the other way round.
	_place_structures()


# --------------------------------------------------------------------------
# structures
# --------------------------------------------------------------------------

## How far (voxels) a structure's footing is carried below its base, so that it
## meets the ground on the low side instead of standing on stilts. Anything
## that ends up under the terrain is dropped by `_put`, at no cost.
const FOOTING := 12

## Authored buildings that reach into this chunk.
##
## Every chunk a structure touches builds the whole of it and lets `_put` throw
## away what falls outside; a wall is a few thousand voxels, which is cheaper
## than working out the intersection twice. The shapes are functions of world
## coordinates only, so two chunks meshing the same wall agree on it exactly.
func _place_structures() -> void:
	if _gen.structures == null:
		return
	for it in _gen.structures.overlapping(_ox, _oz, CS):
		match it["kind"]:
			StructureSet.WALL:
				_build_wall(it)
			StructureSet.PILLAR:
				_build_pillar(it)
			StructureSet.ARCH:
				_build_arch(it)
			StructureSet.TERRACE:
				_build_terrace(it)


## 0..1 from a world column, for shapes that have to look the same from
## whichever chunk builds them.
func _stone_hash(wx: int, wz: int, salt: int) -> float:
	return float(TerrainGen.hash2i(wx, wz, _gen.world_seed ^ salt)) / 2147483647.0


## How many voxels are missing from the top of a ruined column of masonry.
##
## Two scales: a coarse one that takes whole stretches of a wall down together,
## so it reads as collapsed rather than as noise, and a fine one that roughens
## the edge it leaves behind.
func _ruin_bite(wx: int, wz: int, height: int) -> int:
	var coarse := _stone_hash(wx >> 3, wz >> 3, 0x51)
	var fine := _stone_hash(wx, wz, 0x9d)
	return int(coarse * float(height) * 0.55) + int(fine * 2.99)


## Clips an offset range of [-half, +half] about a world coordinate down to the
## part that lands in this chunk, so a wall crossing three chunks is only
## walked where it actually is. `_put` would reject the rest anyway; this is
## about not generating it in the first place.
func _clip(centre: int, half: int, origin: int) -> Vector2i:
	return Vector2i(maxi(-half, origin - centre),
		mini(half, origin + CS - 1 - centre))


## Where a column of masonry can start: no lower than the terrain surface,
## since everything under it is discarded as buried.
func _footing_start(lx: int, lz: int, base: int) -> int:
	return maxi(base - FOOTING, _heights[(lz + 1) * MS + (lx + 1)])


func _build_wall(it: Dictionary) -> void:
	var axis: int = it["axis"]
	var mat: int = it["mat"]
	var base: int = it["base"]
	var height: int = it["height"]
	var half_l: int = int(it["length"]) / 2
	var half_t: int = int(it["thickness"]) / 2
	# u runs along the wall, v across its thickness; which of those is X
	# depends on the axis, and so does which chunk edge clips each of them.
	var ur := _clip(int(it["x"] if axis == 0 else it["z"]), half_l,
		_ox if axis == 0 else _oz)
	var vr := _clip(int(it["z"] if axis == 0 else it["x"]), half_t,
		_oz if axis == 0 else _ox)
	for u in range(ur.x, ur.y + 1):
		for v in range(vr.x, vr.y + 1):
			var wx: int = int(it["x"]) + (u if axis == 0 else v)
			var wz: int = int(it["z"]) + (v if axis == 0 else u)
			var lx := wx - _ox
			var lz := wz - _oz
			var top := base + height - _ruin_bite(wx, wz, height)
			for y in range(_footing_start(lx, lz, base), top):
				_put(lx, y, lz, mat)


func _build_pillar(it: Dictionary) -> void:
	var mat: int = it["mat"]
	var base: int = it["base"]
	var height: int = it["height"]
	var radius: int = it["radius"]
	var rsq := radius * radius
	var xr := _clip(int(it["x"]), radius, _ox)
	var zr := _clip(int(it["z"]), radius, _oz)
	for dz in range(zr.x, zr.y + 1):
		for dx in range(xr.x, xr.y + 1):
			if dx * dx + dz * dz > rsq:
				continue
			var wx: int = int(it["x"]) + dx
			var wz: int = int(it["z"]) + dz
			var lx := wx - _ox
			var lz := wz - _oz
			# Only the last couple of voxels are chipped: a column that lost
			# half its width would not still be standing.
			var top := base + height - int(_stone_hash(wx, wz, 0x2b) * 2.99)
			for y in range(_footing_start(lx, lz, base), top):
				_put(lx, y, lz, mat)


## Two jambs and a lintel. The opening is left clear all the way through, so it
## can actually be walked into.
func _build_arch(it: Dictionary) -> void:
	var axis: int = it["axis"]
	var mat: int = it["mat"]
	var base: int = it["base"]
	var height: int = it["height"]
	var half_w: int = int(it["width"]) / 2
	var half_t: int = int(it["thickness"]) / 2
	# The lintel is a fifth of the height, and the jambs carry the rest.
	var lintel := maxi(height / 5, 2)
	var jamb_top := base + height - lintel
	# Jambs sit just outside the opening, so `width` is the clear span.
	var jamb := half_w + half_t + 1
	for side_of in [-jamb, jamb]:
		var side: int = side_of
		for w in range(-half_t, half_t + 1):
			for v in range(-half_t, half_t + 1):
				var off := side + w
				var wx: int = int(it["x"]) + (off if axis == 0 else v)
				var wz: int = int(it["z"]) + (v if axis == 0 else off)
				var lx := wx - _ox
				var lz := wz - _oz
				if lx < 0 or lx >= CS or lz < 0 or lz >= CS:
					continue
				for y in range(_footing_start(lx, lz, base), jamb_top):
					_put(lx, y, lz, mat)
	for u in range(-jamb - half_t, jamb + half_t + 1):
		for v in range(-half_t, half_t + 1):
			var wx: int = int(it["x"]) + (u if axis == 0 else v)
			var wz: int = int(it["z"]) + (v if axis == 0 else u)
			var lx := wx - _ox
			var lz := wz - _oz
			if lx < 0 or lx >= CS or lz < 0 or lz >= CS:
				continue
			var top := base + height - int(_stone_hash(wx, wz, 0x77) * 2.99)
			for y in range(jamb_top, top):
				_put(lx, y, lz, mat)


## The plinth the tide lock stands on: four walls carrying a slab, with a stair
## up one side.
##
## Hollow on purpose. Solid, a deck this tall is some forty thousand voxels in
## one chunk, and every one of them would be walked again by the face pass; a
## shell is a tenth of that and looks identical, since the inside is sealed.
func _build_terrace(it: Dictionary) -> void:
	var mat: int = it["mat"]
	var base: int = it["base"]
	var top: int = it["top"]
	var cx: int = it["x"]
	var cz: int = it["z"]
	var half: int = it["half"]
	var wall: int = it["wall"]
	var slab: int = it["slab"]
	var xr := _clip(cx, half, _ox)
	var zr := _clip(cz, half, _oz)
	for dz in range(zr.x, zr.y + 1):
		for dx in range(xr.x, xr.y + 1):
			var lx := cx + dx - _ox
			var lz := cz + dz - _oz
			var foot := _footing_start(lx, lz, base)
			# The walls carry down to the ground; over the middle there is only
			# the deck slab, and the ground shows through underneath.
			var from := foot if absi(dx) > half - wall or absi(dz) > half - wall \
				else maxi(top - slab, foot)
			for y in range(from, top):
				_put(lx, y, lz, mat)
	_build_stair(it)


## The stair off one side of a terrace: a run of treads on two side walls.
##
## Each step is a tread's worth of columns one rise below the last, and a step
## whose tread has already met the ground builds nothing, so the run finds the
## slope it is standing on instead of having to be told about it.
func _build_stair(it: Dictionary) -> void:
	var mat: int = it["mat"]
	var base: int = it["base"]
	var top: int = it["top"]
	var cx: int = it["x"]
	var cz: int = it["z"]
	var axis: int = it["axis"]
	var dir: int = it["dir"]
	var half: int = it["half"]
	var wall: int = it["wall"]
	var slab: int = it["slab"]
	var rise: int = it["rise"]
	var tread: int = it["tread"]
	var swide: int = it["stair_half"]
	for s in int(it["steps"]):
		var step_top := top - (s + 1) * rise
		if step_top <= 0:
			return
		for t in tread:
			var out := (half + s * tread + t + 1) * dir
			for v in range(-swide, swide + 1):
				var lx := cx + (out if axis == 0 else v) - _ox
				var lz := cz + (v if axis == 0 else out) - _oz
				if lx < 0 or lx >= CS or lz < 0 or lz >= CS:
					continue
				var foot := _footing_start(lx, lz, base)
				var from := foot if absi(v) > swide - wall \
					else maxi(step_top - slab, foot)
				for y in range(from, step_top):
					_put(lx, y, lz, mat)


func _add_tree(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator) -> void:
	var big := rng.randf() < 0.18
	var trunk_h := rng.randi_range(52, 74) if big else rng.randi_range(28, 46)
	var trunk_r := 4 if big else rng.randi_range(2, 3)
	var lean_x := rng.randf_range(-0.06, 0.06)
	var lean_z := rng.randf_range(-0.06, 0.06)

	# trunk: only the outer ring of the cylinder is stored
	for y in range(-2, trunk_h):
		var cxo := int(round(float(y) * lean_x))
		var czo := int(round(float(y) * lean_z))
		var taper := trunk_r - int(float(y) / float(trunk_h) * 1.5)
		# Zero, not one: a trunk that tapers away to a single voxel still has to
		# be recognised as its own surface by the ring test below.
		var tr2 := maxi(taper, 0) * maxi(taper, 0)
		for dz in range(-trunk_r, trunk_r + 1):
			for dx in range(-trunk_r, trunk_r + 1):
				var dd := dx * dx + dz * dz
				if dd > tr2:
					continue
				var ring := (dx + 1) * (dx + 1) + dz * dz > tr2 \
					or (dx - 1) * (dx - 1) + dz * dz > tr2 \
					or dx * dx + (dz + 1) * (dz + 1) > tr2 \
					or dx * dx + (dz - 1) * (dz - 1) > tr2 \
					or y == trunk_h - 1
				if ring or y < 2:
					_put(lx + cxo + dx, base_y + y, lz + czo + dz, VoxelDefs.WOOD)

	var top := Vector3i(
		lx + int(round(float(trunk_h) * lean_x)),
		base_y + trunk_h,
		lz + int(round(float(trunk_h) * lean_z)))

	# canopy: a couple of overlapping ellipsoid lobes, meshed as a shell
	var lobes := []
	var lobe_count := rng.randi_range(2, 3)
	var rad := rng.randi_range(20, 26) if big else rng.randi_range(12, 18)
	for i in lobe_count:
		var off := Vector3i(
			rng.randi_range(-rad / 2, rad / 2),
			rng.randi_range(-rad / 3, rad / 2),
			rng.randi_range(-rad / 2, rad / 2))
		if i == 0:
			off = Vector3i(0, rad / 3, 0)
		var rr := Vector3i(
			rad + rng.randi_range(-3, 3),
			int(rad * 0.75) + rng.randi_range(-2, 3),
			rad + rng.randi_range(-3, 3))
		lobes.append({"c": top + off, "r": rr})
		# short branch reaching into the lobe
		if i > 0:
			_line(top, top + off, 1, VoxelDefs.WOOD)
	_blob_shell(lobes, VoxelDefs.LEAF, 0.22)


func _add_cactus(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator) -> void:
	var h := rng.randi_range(14, 30)
	var r := 2
	for y in range(-2, h):
		var rr := r - 1 if y >= h - 2 else r
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dz * dz > rr * rr:
					continue
				_put(lx + dx, base_y + y, lz + dz, VoxelDefs.CACTUS)
	var arms := rng.randi_range(0, 2)
	# Half thickness of an arm.
	var aw := 1
	for i in arms:
		var side := 1 if rng.randf() < 0.5 else -1
		var axis_x := rng.randf() < 0.5
		var ay := base_y + rng.randi_range(int(h * 0.4), int(h * 0.7))
		var reach := rng.randi_range(5, 9)
		for k in range(1, reach + 1):
			for dy in range(-aw, aw + 1):
				for dd in range(-aw, aw + 1):
					if axis_x:
						_put(lx + side * (r + k), ay + dy, lz + dd, VoxelDefs.CACTUS)
					else:
						_put(lx + dd, ay + dy, lz + side * (r + k), VoxelDefs.CACTUS)
		var tip := rng.randi_range(6, 12)
		for k in tip:
			for dy in range(-aw, aw + 1):
				for dd in range(-aw, aw + 1):
					if axis_x:
						_put(lx + side * (r + reach) + dy, ay + k, lz + dd, VoxelDefs.CACTUS)
					else:
						_put(lx + dd, ay + k, lz + side * (r + reach) + dy, VoxelDefs.CACTUS)


func _add_boulder(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator) -> void:
	var rad := rng.randi_range(4, 11)
	var squash := rad + rng.randi_range(-2, 2)
	var lobes := [{
		"c": Vector3i(lx, base_y + rad / 3, lz),
		"r": Vector3i(rad, int(rad * 0.8), squash),
	}]
	_blob_shell(lobes, VoxelDefs.STONE, 0.18)


## A group of mushrooms: one big one surrounded by a few smaller ones, so they
## always come up as a little family rather than as a lone stalk.
func _add_mushroom(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator, fcx: int, fcz: int) -> void:
	_add_one_mushroom(lx, lz, base_y, rng, _gen.rand01(fcx, fcz, 0x9c0b), 1.0)
	var count := rng.randi_range(2, 5)
	var start := rng.randf() * TAU
	for i in count:
		# spread around the big one, never further than the margin the feature
		# scan covers, so no member can reach a chunk that does not know about it
		var ang := start + TAU * float(i) / float(count) + rng.randf_range(-0.4, 0.4)
		var dist := rng.randf_range(8.0, 22.0)
		var mx := lx + int(round(cos(ang) * dist))
		var mz := lz + int(round(sin(ang) * dist))
		var scale := rng.randf_range(0.3, 0.72)
		# each member sits on its own ground height, otherwise the small ones
		# float or sink on a slope
		var my := _gen.height_voxels(
			float(_ox + mx) * VS, float(_oz + mz) * VS, VS)
		_add_one_mushroom(mx, mz, my, rng, _gen.rand01(fcx, fcz, 0x9c0b + (i + 1) * 977), scale)


## Big fantasy mushroom: a thick, slightly bent stem carrying a dome shaped cap.
## The cap glows from underneath (radial gills) and from spots on its top.
## `scale` is 1.0 for the big one in a group and well below that for the rest.
func _add_one_mushroom(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator, phase: float, scale: float) -> void:
	var stem_h := maxi(int(round(float(rng.randi_range(24, 46)) * scale)), 5)
	var stem_r := maxi(int(round(float(rng.randi_range(3, 5)) * scale)), 1)
	var lean_x := rng.randf_range(-0.05, 0.05)
	var lean_z := rng.randf_range(-0.05, 0.05)

	# stem: hollow ring, flaring out towards the foot
	for y in range(-2, stem_h):
		var t := float(y) / float(stem_h)
		var flare := 1.0 + pow(1.0 - t, 3.0) * 0.8
		var r := int(round(float(stem_r) * flare))
		var r2 := r * r
		var cxo := int(round(float(y) * lean_x))
		var czo := int(round(float(y) * lean_z))
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var dd := dx * dx + dz * dz
				if dd > r2:
					continue
				var ring := (dx + 1) * (dx + 1) + dz * dz > r2 \
					or (dx - 1) * (dx - 1) + dz * dz > r2 \
					or dx * dx + (dz + 1) * (dz + 1) > r2 \
					or dx * dx + (dz - 1) * (dz - 1) > r2
				if ring or y < 1:
					_put(lx + cxo + dx, base_y + y, lz + czo + dz, VoxelDefs.SHROOM_STEM)

	var cx := lx + int(round(float(stem_h) * lean_x))
	var cz := lz + int(round(float(stem_h) * lean_z))
	# the cap sinks a little onto the stem so there is no gap at the joint
	var cap_y := base_y + stem_h - 2
	var cap_r := maxi(int(round(float(rng.randi_range(11, 20)) * scale)), 4)
	var cap_h := maxi(int(float(cap_r) * rng.randf_range(0.55, 0.8)), 3)
	var gills := maxi(int(round(float(rng.randi_range(9, 16)) * sqrt(scale))), 5)

	# glowing spots scattered over the dome
	var spots: Array[Vector3] = []
	for i in rng.randi_range(3, 6):
		var a := rng.randf() * TAU
		var st := rng.randf_range(0.1, 0.8)
		var sr := float(cap_r) * sqrt(maxf(1.0 - st * st, 0.0))
		spots.append(Vector3(cos(a) * sr, st * float(cap_h), sin(a) * sr))
	var spot_r2 := pow(maxf(float(cap_r) * 0.22, 2.0), 2.0)

	for y in range(0, cap_h + 1):
		var t := float(y) / float(cap_h)
		var r := float(cap_r) * sqrt(maxf(1.0 - t * t, 0.0))
		var ri := int(round(r))
		var r2 := r * r
		# The shell never thins below a voxel.
		var inner := maxf(r - 2.2, 0.0)
		var inner2 := inner * inner
		for dz in range(-ri, ri + 1):
			for dx in range(-ri, ri + 1):
				var dd := float(dx * dx + dz * dz)
				if dd > r2:
					continue
				# only the shell is kept: the outer skin plus the underside
				if dd < inner2 and y > 0:
					continue
				var mat := VoxelDefs.SHROOM_CAP
				if y == 0:
					# radial gills, every other wedge lit
					var ang := atan2(float(dz), float(dx))
					var wedge := int(floor((ang + PI) / TAU * float(gills) * 2.0))
					mat = VoxelDefs.SHROOM_GLOW if wedge % 2 == 0 else VoxelDefs.SHROOM_CAP
				else:
					var p := Vector3(float(dx), float(y), float(dz))
					for s in spots:
						if p.distance_squared_to(s) < spot_r2:
							mat = VoxelDefs.SHROOM_GLOW
							break
				_put_glow(cx + dx, cap_y + y, cz + dz, mat, phase)

	_add_mushroom_light(cx, base_y, stem_h, cz, cap_r, phase)


## A mushroom lights its own patch of ground. Only the chunk the cap sits in
## records the light, otherwise every neighbour that meshes part of the cap
## would add one of its own and the spot would be several times too bright.
func _add_mushroom_light(cx: int, base_y: int, stem_h: int, cz: int, cap_r: int, phase: float) -> void:
	if not _want_lights:
		return
	if cx < 0 or cx >= CS or cz < 0 or cz >= CS:
		return
	# Hangs about a third of the way up the stem: high enough to catch the stem
	# and the cap's underside, low enough to pool on the grass below.
	var y := float(base_y) + float(stem_h) * 0.35
	_lights.append({
		"pos": Vector3(float(cx) * VS, y * VS, float(cz) * VS),
		"radius": 6.0 + float(cap_r) * 0.7,
		"energy": 1.3 + float(cap_r) * 0.14,
		"phase": phase,
	})


## Places a voxel that may end up on the glow surface, remembering which
## mushroom it belongs to.
func _put_glow(x: int, y: int, z: int, mat: int, phase: float) -> void:
	var key := _put(x, y, z, mat)
	if key >= 0:
		_glow_phase[key] = phase


## Ground cover: grass and the odd pebble out on the sand.
##
## Grass grows in bushes rather than as an even stubble over the whole meadow: a
## handful of sites per chunk, each a clump of blades tallest in the middle and
## ragged at the rim. A clump also hides most of its own faces from the mesher,
## where scattered single tufts each pay for all four sides.
##
## That is what pays for the important part: ground cover is built for every
## chunk in the streamed disc rather than only for the near ones, so grass and
## pebbles arrive with the chunk they belong to - out in the mist, where a chunk
## arriving cannot be seen. There is no second radius at which the world grows
## its detail in front of you.
##
## Nothing about that depends on where the player is looking from, either: grass
## only grows on GRASS and pebbles only on SAND, both of which stop well below
## Atmosphere's `mist_top`, so ground cover is always in the thickest air there
## is and always gone by the distance the chunks end - from a summit as much as
## from the plain.
##
## Sites are attempts, not results: one that lands on the wrong material is
## simply skipped, so a chunk half meadow and half sand gets its share of each.
const BUSH_SITES := 8
const PEBBLE_SITES := 10


func _add_ground_cover() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = TerrainGen.hash2i(_cx, _cz, _gen.world_seed ^ 0x5eed)
	for i in BUSH_SITES:
		var x := rng.randi_range(0, CS - 1)
		var z := rng.randi_range(0, CS - 1)
		if _m(x, z) == VoxelDefs.GRASS:
			_add_bush(x, z, rng)
	for i in PEBBLE_SITES:
		var x := rng.randi_range(0, CS - 1)
		var z := rng.randi_range(0, CS - 1)
		if _m(x, z) == VoxelDefs.SAND:
			_put(x, _h(x, z), z, VoxelDefs.STONE)


## One clump of grass. Blades are stacked per column, so the shape is carried by
## how tall each column is: highest at the centre, one or two voxels out at the
## rim, and with the rim thinned at random so no two bushes are the same disc.
func _add_bush(lx: int, lz: int, rng: RandomNumberGenerator) -> void:
	var r := 1 if rng.randf() < 0.55 else 2
	var core := rng.randi_range(2, 4)
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var d2 := dx * dx + dz * dz
			if d2 > r * r:
				continue
			# The further from the middle, the likelier the column is left out.
			if d2 > 0 and rng.randf() < 0.22 * float(d2):
				continue
			var x := lx + dx
			var z := lz + dz
			if x < 0 or x >= CS or z < 0 or z >= CS:
				continue
			# A bush stops at the edge of the meadow rather than climbing onto
			# the sand or the rock next to it.
			if _m(x, z) != VoxelDefs.GRASS:
				continue
			var n := maxi(core - d2 + rng.randi_range(-1, 0), 1)
			var h := _h(x, z)
			for k in n:
				_put(x, h + k, z, VoxelDefs.BLADE)


func _line(a: Vector3i, b: Vector3i, r: int, mat: int) -> void:
	var d := Vector3(b - a)
	var steps := int(maxf(d.length(), 1.0))
	for s in range(steps + 1):
		var p := Vector3(a) + d * (float(s) / float(steps))
		var pi := Vector3i(round(p.x), round(p.y), round(p.z))
		for dz in range(-r, r + 1):
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					_put(pi.x + dx, pi.y + dy, pi.z + dz, mat)


## Fills the union of ellipsoids and keeps only its surface layer.
func _blob_shell(lobes: Array, mat: int, rough: float) -> void:
	if lobes.is_empty():
		return
	var mn := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var mx := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for l in lobes:
		var c: Vector3i = l["c"]
		var r: Vector3i = l["r"]
		mn.x = mini(mn.x, c.x - r.x - 1)
		mn.y = mini(mn.y, c.y - r.y - 1)
		mn.z = mini(mn.z, c.z - r.z - 1)
		mx.x = maxi(mx.x, c.x + r.x + 1)
		mx.y = maxi(mx.y, c.y + r.y + 1)
		mx.z = maxi(mx.z, c.z + r.z + 1)
	# nothing of this blob can reach the chunk -> skip the expensive fill
	if mx.x < 0 or mn.x >= CS or mx.z < 0 or mn.z >= CS or mx.y < 0:
		return

	# A tree rooted near a chunk border has most of its crown in the neighbour,
	# and filling that part here only to have `_put` throw it away is the
	# single most wasteful thing this builder used to do. One voxel of margin
	# is kept on every side, which is all the shell test below looks at, so the
	# surface that survives is identical to the unclipped one.
	mn.x = maxi(mn.x, -1)
	mn.y = maxi(mn.y, -1)
	mn.z = maxi(mn.z, -1)
	mx.x = mini(mx.x, CS)
	mx.z = mini(mx.z, CS)

	var sx := mx.x - mn.x + 1
	var sy := mx.y - mn.y + 1
	var sz := mx.z - mn.z + 1
	var inside := PackedByteArray()
	inside.resize(sx * sy * sz)

	# `TerrainGen.hash2i` inlined: it is a handful of integer ops, but it was
	# being reached through a static call once per cell of every lobe's box,
	# which is hundreds of thousands of calls for one big tree at level 0.
	# Salt 7, folded into a constant.
	const SALT7 := 7 * 83492791
	const INV_1023 := 1.0 / 1023.0

	for l in lobes:
		var c: Vector3i = l["c"]
		var r: Vector3i = l["r"]
		var irx := 1.0 / float(maxi(r.x, 1))
		var iry := 1.0 / float(maxi(r.y, 1))
		var irz := 1.0 / float(maxi(r.z, 1))
		for y in range(maxi(c.y - r.y, mn.y), mini(c.y + r.y, mx.y) + 1):
			var fy := float(y - c.y) * iry
			var fy2 := fy * fy
			for z in range(maxi(c.z - r.z, mn.z), mini(c.z + r.z, mx.z) + 1):
				var fz := float(z - c.z) * irz
				var row := ((y - mn.y) * sz + (z - mn.z)) * sx
				var fyz := fy2 + fz * fz
				if fyz > 1.3:
					continue
				var hz: int = z * 19349663 ^ SALT7
				var base := row - mn.x
				for x in range(maxi(c.x - r.x, mn.x), mini(c.x + r.x, mx.x) + 1):
					var fx := float(x - c.x) * irx
					var d := fyz + fx * fx
					var hh: int = (x * 31 + y) * 73856093 ^ hz
					hh = (hh ^ (hh >> 13)) * 1274126177
					if d < 1.0 + (float(hh & 1023) * INV_1023 - 0.5) * rough:
						inside[base + x] = 1

	for y in range(sy):
		for z in range(sz):
			var row := (y * sz + z) * sx
			for x in range(sx):
				if inside[row + x] == 0:
					continue
				var exposed := x == 0 or x == sx - 1 or y == 0 or y == sy - 1 or z == 0 or z == sz - 1 \
					or inside[row + x - 1] == 0 or inside[row + x + 1] == 0 \
					or inside[row + x - sx] == 0 or inside[row + x + sx] == 0 \
					or inside[row + x - sx * sz] == 0 or inside[row + x + sx * sz] == 0
				if exposed:
					_put(mn.x + x, mn.y + y, mn.z + z, mat)


## A neighbouring voxel hides this face if a feature voxel occupies it, or if it
## is buried in the terrain. X and Z here are always within one of the chunk,
## which is the range the height margin covers, so the terrain test is always
## available.
##
## The packed key is only usable for the lookup when the neighbour is inside the
## chunk: stepping X or Z off the edge would borrow across the bit fields and
## land on some unrelated voxel.
func _hidden(nx: int, ny: int, nz: int, nkey: int) -> bool:
	if nx >= 0 and nx < CS and nz >= 0 and nz < CS and ny >= 0 and _extras.has(nkey):
		return true
	return ny < _heights[(nz + 1) * MS + (nx + 1)]


func _mesh_features() -> void:
	for key in _extras:
		var mat: int = _extras[key]
		var y: int = key & KEY_Y_MASK
		var x: int = (key >> KEY_X) & KEY_XY
		var z: int = (key >> KEY_Z) & KEY_XY
		var col := VoxelDefs.color_of(mat)
		var collide: bool = VoxelDefs.SOLID_FEATURES.has(mat)
		_sway = mat == VoxelDefs.BLADE
		if _sway:
			_sway_uv = _sway_data(x, y, z)
		_glow = VoxelDefs.GLOW.has(mat)
		if _glow:
			_glow_uv = Vector2(VoxelDefs.GLOW[mat], _glow_phase.get(key, 0.0))
		var x0 := float(x) * VS
		var x1 := x0 + VS
		var y0 := float(y) * VS
		var y1 := y0 + VS
		var z0 := float(z) * VS
		var z1 := z0 + VS
		if not _hidden(x + 1, y, z, key + KEY_DX):
			_quad(Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1),
				Vector3.RIGHT, col, collide)
		if not _hidden(x - 1, y, z, key - KEY_DX):
			_quad(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0),
				Vector3.LEFT, col, collide)
		if not _hidden(x, y + 1, z, key + 1):
			_quad(Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0),
				Vector3.UP, col, collide)
		if not _hidden(x, y - 1, z, key - 1):
			_quad(Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1),
				Vector3.DOWN, col, collide)
		if not _hidden(x, y, z + 1, key + KEY_DZ):
			_quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1),
				Vector3.BACK, col, collide)
		if not _hidden(x, y, z - 1, key - KEY_DZ):
			_quad(Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0),
				Vector3.FORWARD, col, collide)

	_sway = false
	_glow = false


## Wind data baked into the UV of a grass voxel: how stiff it is (0 at the
## ground, 1 at the tip of a tuft) and a phase that is unique per tuft column
## so neighbouring tufts do not sway in lockstep.
func _sway_data(x: int, y: int, z: int) -> Vector2:
	var above := float(y - _heights[(z + 1) * MS + (x + 1)]) * VS
	return Vector2(clampf(above / (VS * 4.0), 0.0, 1.0), _gen.rand01(_ox + x, _oz + z, 0x21ad))
