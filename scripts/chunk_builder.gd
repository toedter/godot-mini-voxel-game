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


# --------------------------------------------------------------------------
# trees
# --------------------------------------------------------------------------

## Nothing a tree grows may reach further from its trunk than this, in voxels.
##
## `_place_features` scans the feature cell of this chunk plus one either side,
## and a cell is one chunk wide, so a tree rooted two cells out is at least 65
## voxels away. Anything reaching that far would be built by the chunk it is
## rooted in and not by this one, and the crown would be sliced off at the
## chunk border.
const TREE_REACH := 58

## The three shapes a tree comes in, and how often each turns up. A broadleaf is
## the ordinary tree of the meadow; the giant is the one standing over a
## clearing with a crown wide enough to walk under; the conifer is what fills in
## the slopes behind them.
const TREE_GIANT_CHANCE := 0.13
const TREE_CONIFER_CHANCE := 0.24


## Plants one tree.
##
## Every kind is a trunk, a set of limbs forking off it, and a crown made of
## many small clumps of foliage hung on those limbs - never one ellipsoid on a
## stick. The clumps go into a single `_blob_shell` call, so where they overlap
## they melt into one surface and where they do not the crown keeps the gaps and
## the lumpy outline that a canopy actually has.
func _add_tree(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator) -> void:
	var roll := rng.randf()
	if roll < TREE_GIANT_CHANCE:
		_tree_broadleaf(lx, lz, base_y, rng, true)
	elif roll < TREE_GIANT_CHANCE + TREE_CONIFER_CHANCE:
		_tree_conifer(lx, lz, base_y, rng)
	else:
		_tree_broadleaf(lx, lz, base_y, rng, false)


## Sideways offset (voxels) of a trunk's axis at height `y`: a steady lean plus
## a bow that is widest at mid height. Two terms rather than one because a lean
## on its own is a leaning pole - the bow is what makes the stem read as
## something that grew towards the light.
func _trunk_off(y: int, trunk_h: int, lean: Vector2, bow: Vector2) -> Vector2i:
	var t := clampf(float(y) / float(maxi(trunk_h, 1)), 0.0, 1.0)
	var o := lean * float(y) + bow * sin(PI * t)
	return Vector2i(int(round(o.x)), int(round(o.y)))


## Where the trunk's axis is at height `y`, in this chunk's grid.
func _trunk_point(lx: int, lz: int, base_y: int, y: int, trunk_h: int,
		lean: Vector2, bow: Vector2) -> Vector3i:
	var o := _trunk_off(y, trunk_h, lean, bow)
	return Vector3i(lx + o.x, base_y + y, lz + o.y)


## The stem: a hollow tapering cylinder that flares out where it meets the
## ground.
##
## Only the outer ring of each level is stored, as the inside of a trunk is
## never seen - except on the levels where the radius drops below the one under
## it, which would leave an annular ledge to look down through. Those are filled
## solid, which is a handful of levels over the whole trunk.
func _trunk(lx: int, lz: int, base_y: int, trunk_h: int, trunk_r: int,
		lean: Vector2, bow: Vector2) -> void:
	# The foot spreads by about half the trunk's own width again, over a stretch
	# a little taller than it is wide.
	var flare_r := trunk_r + maxi(trunk_r / 2, 1)
	var flare_h := trunk_r * 2 + 3
	var prev := -1
	for y in range(-4, trunk_h):
		var r := trunk_r
		if y < flare_h:
			var f := 1.0 - float(maxi(y, 0)) / float(flare_h)
			r += int(round(float(flare_r - trunk_r) * f * f))
		else:
			var up := float(y - flare_h) / float(maxi(trunk_h - flare_h, 1))
			r -= int(up * float(trunk_r) * 0.5)
		r = maxi(r, 1)
		# Solid where the trunk narrows, and at the very top, so no level ever
		# opens a window into the hollow.
		var solid := r < prev or y <= 0 or y == trunk_h - 1
		prev = r
		var r2 := r * r
		var o := _trunk_off(maxi(y, 0), trunk_h, lean, bow)
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dz * dz > r2:
					continue
				var ring := solid \
					or (dx + 1) * (dx + 1) + dz * dz > r2 \
					or (dx - 1) * (dx - 1) + dz * dz > r2 \
					or dx * dx + (dz + 1) * (dz + 1) > r2 \
					or dx * dx + (dz - 1) * (dz - 1) > r2
				if ring:
					_put(lx + o.x + dx, base_y + y, lz + o.y + dz, VoxelDefs.WOOD)


## One clump of foliage, as a lobe for `_blob_shell`. Flattened, because a
## canopy is layered: a clump is wider than it is deep, and a stack of them
## reads as branches carrying leaves rather than as a heap of spheres.
func _leaf_clump(c: Vector3i, r: int, mat: int, rng: RandomNumberGenerator) -> Dictionary:
	return {
		"c": c,
		"r": Vector3i(r + rng.randi_range(-1, 2),
			maxi(int(float(r) * 0.85) + rng.randi_range(-1, 1), 2),
			r + rng.randi_range(-1, 2)),
		"m": mat,
	}


## Hangs foliage on a branch: clumps over its outer half, growing towards the
## tip, with a shaded one slung under the end.
##
## One clump on the end of each limb is what makes a voxel tree read as a
## lollipop, or as a ring of them; a run of clumps along the branch is what
## turns the same limbs into a crown with a filled middle.
func _branch_leaves(a: Vector3i, b: Vector3i, clump: int, lobes: Array,
		rng: RandomNumberGenerator) -> void:
	var ab := Vector3(b - a)
	for k in 2:
		var t := 0.62 + 0.38 * float(k)
		var p := Vector3i((Vector3(a) + ab * t).round())
		var r := maxi(int(float(clump) * (0.78 + 0.22 * float(k))), 3)
		lobes.append(_leaf_clump(p + Vector3i(0, r / 3, 0), r, VoxelDefs.LEAF, rng))
	# The underside. Leaves in shadow are most of what gives a crown its
	# volume from below, which is the angle the player is nearly always at.
	if rng.randf() < 0.7:
		var r := maxi(clump - 3, 3)
		lobes.append(_leaf_clump(
			b + Vector3i(rng.randi_range(-2, 2), -clump / 2 - 1, rng.randi_range(-2, 2)),
			r, VoxelDefs.LEAF_DARK, rng))


## An oak: a flared trunk forking into limbs that curve up and out, each of them
## forking again and carrying leaves over its whole outer half. `big` is the one
## that stands over a clearing with a crown to walk under.
func _tree_broadleaf(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator,
		big: bool) -> void:
	var trunk_h := rng.randi_range(52, 74) if big else rng.randi_range(30, 46)
	var trunk_r := rng.randi_range(4, 5) if big else rng.randi_range(2, 3)
	var lean := Vector2(rng.randf_range(-0.05, 0.05), rng.randf_range(-0.05, 0.05))
	var bow := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) 		* (2.5 if big else 1.4)
	_trunk(lx, lz, base_y, trunk_h, trunk_r, lean, bow)

	# Buttress roots. The flare on its own is a fat cylinder; these give the
	# foot the splay that an old tree standing in a wood has.
	if big:
		var ra := rng.randf() * TAU
		for i in 5:
			var a := ra + TAU * float(i) / 5.0 + rng.randf_range(-0.3, 0.3)
			var run := rng.randi_range(7, 12)
			_limb(Vector3i(lx, base_y + rng.randi_range(4, 7), lz),
				Vector3i(lx + int(cos(a) * float(run)), base_y - 2,
					lz + int(sin(a) * float(run))),
				2.4, 1.2, VoxelDefs.WOOD)

	# The crown's envelope, and how big one clump of leaves in it is. Limb tips
	# stop a clump short of the envelope, so the leaves end where it does and
	# the crown stays inside the margin the neighbouring chunks build.
	var crown := mini(rng.randi_range(38, 46) if big else rng.randi_range(25, 31),
		TREE_REACH - 4)
	var clump := rng.randi_range(9, 12) if big else rng.randi_range(7, 9)
	var reach := float(maxi(crown - clump, 6))
	var limbs := rng.randi_range(7, 8) if big else rng.randi_range(5, 7)
	# Height (in trunk voxels) the limb tips aim for. Every limb ends near it,
	# so the crown closes over the stem instead of trailing off to one side.
	var apex := float(trunk_h) + reach * rng.randf_range(0.35, 0.6)
	# Where the crown starts. The giant forks low, so the player walks in under
	# its branches instead of past a bare pole.
	var fork := int(float(trunk_h) * (0.36 if big else 0.46))

	var lobes := []
	var a0 := rng.randf() * TAU
	for i in limbs:
		var t := float(i) / float(maxi(limbs - 1, 1))
		# Limbs spiral up the stem rather than all leaving it at one height,
		# which is what a fork looks like from the side.
		var ang := a0 + TAU * (float(i) + rng.randf_range(-0.3, 0.3)) / float(limbs)
		var y0 := fork + int(float(trunk_h - fork) * (t * 0.75 + rng.randf_range(0.0, 0.2)))
		var from := _trunk_point(lx, lz, base_y, mini(y0, trunk_h - 1), trunk_h, lean, bow)
		var dir := Vector2(cos(ang), sin(ang))
		# Limbs off the low part of the stem carry furthest out - they are the
		# wide bottom of the crown - and have the furthest to climb to reach the
		# apex. Deriving the rise from where the limb started rather than from
		# its place in the spiral is what keeps the crown from leaning: tie the
		# two together and every tree ends up low and wide on the side its first
		# limb left, high and narrow on the far side.
		var out := reach * (1.0 - 0.3 * t) * rng.randf_range(0.8, 1.05)
		var up := maxf(apex * rng.randf_range(0.84, 1.0) - float(y0), reach * 0.25)
		# The elbow sits above the straight line from fork to tip, so a limb
		# leaves the trunk steeply and flattens out as it goes.
		var mid := from + Vector3i(int(dir.x * out * 0.42), int(up * 0.62),
			int(dir.y * out * 0.42))
		var tip := from + Vector3i(int(dir.x * out), int(up), int(dir.y * out))
		var thick := 2.4 if big else 1.6
		_limb(from, mid, thick, thick * 0.6, VoxelDefs.WOOD)
		_limb(mid, tip, thick * 0.6, 1.0, VoxelDefs.WOOD)
		_branch_leaves(mid, tip, clump, lobes, rng)
		# A second fork off the elbow, thrown to one side, filling the wedge
		# between this limb and the next instead of leaving daylight there.
		if rng.randf() < 0.75:
			var sa := ang + rng.randf_range(0.5, 1.2) * (1.0 if rng.randf() < 0.5 else -1.0)
			var sd := Vector2(cos(sa), sin(sa))
			var so := out * rng.randf_range(0.45, 0.8)
			var stip := mid + Vector3i(int(sd.x * so),
				int(up * rng.randf_range(0.15, 0.55)), int(sd.y * so))
			_limb(mid, stip, thick * 0.6, 0.9, VoxelDefs.WOOD)
			_branch_leaves(mid, stip, maxi(clump - 2, 4), lobes, rng)

	# The cap over the middle, where the limbs meet: several clumps rather than
	# one, so the top of the crown is as uneven as the rest of it.
	var top := _trunk_point(lx, lz, base_y, trunk_h, trunk_h, lean, bow)
	var centre := top + Vector3i(0, int(reach * 0.5), 0)
	lobes.append(_leaf_clump(centre, clump + 1, VoxelDefs.LEAF, rng))
	for i in rng.randi_range(2, 3):
		var a := rng.randf() * TAU
		var d := reach * rng.randf_range(0.2, 0.55)
		lobes.append(_leaf_clump(
			centre + Vector3i(int(cos(a) * d), rng.randi_range(-clump, 3),
				int(sin(a) * d)),
			maxi(clump - rng.randi_range(0, 2), 3), VoxelDefs.LEAF, rng))

	_blob_shell(lobes, VoxelDefs.LEAF, 0.30)


## A conifer: a straight stem carrying whorls of short branches that get shorter
## towards the top, each tipped with a flat pad of needles. Built from the same
## clumps as the broadleaf, only laid out in a cone.
func _tree_conifer(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator) -> void:
	var trunk_h := rng.randi_range(62, 94)
	var trunk_r := rng.randi_range(2, 3)
	var lean := Vector2(rng.randf_range(-0.02, 0.02), rng.randf_range(-0.02, 0.02))
	var bow := Vector2(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.6, 0.6))
	_trunk(lx, lz, base_y, trunk_h, trunk_r, lean, bow)

	var spread := rng.randi_range(15, 23)
	var whorls := rng.randi_range(7, 10)
	# The lowest branches sit about a third of the way up: the bare stem under
	# them is most of what tells a conifer apart from a bush at a distance.
	var low := 0.28 + rng.randf() * 0.12
	var lobes := []
	for i in whorls:
		var t := float(i) / float(maxi(whorls - 1, 1))
		var y := int(float(trunk_h) * lerpf(low, 0.93, t))
		var c := _trunk_point(lx, lz, base_y, y, trunk_h, lean, bow)
		# Branch length falls off towards the top; the exponent keeps the taper
		# slightly concave, which is the profile of a spruce rather than a cone.
		var rw := maxi(int(float(spread) * pow(1.0 - t, 0.7)), 3)
		var arms := rng.randi_range(4, 6)
		var a0 := rng.randf() * TAU
		for k in arms:
			var a := a0 + TAU * float(k) / float(arms) + rng.randf_range(-0.25, 0.25)
			var d := Vector2(cos(a), sin(a))
			var run := int(float(rw) * rng.randf_range(0.7, 1.0))
			# Branches droop: the tip ends a voxel or two below where it left
			# the trunk.
			var tip := c + Vector3i(int(d.x * float(run)), rng.randi_range(-3, 0),
				int(d.y * float(run)))
			_limb(c, tip, 1.4, 0.8, VoxelDefs.WOOD)
			var cr := maxi(int(float(run) * 0.62), 3)
			lobes.append({
				"c": tip,
				"r": Vector3i(cr, maxi(int(float(cr) * 0.5), 2), cr),
				"m": VoxelDefs.LEAF if t > 0.45 or rng.randf() < 0.4 \
					else VoxelDefs.LEAF_DARK,
			})
		# A collar round the stem joins one whorl's pads into a continuous skirt
		# instead of leaving the trunk showing through between them.
		var collar := maxi(int(float(rw) * 0.55), 3)
		lobes.append({
			"c": c + Vector3i(0, 1, 0),
			"r": Vector3i(collar, maxi(collar / 2, 2), collar),
			"m": VoxelDefs.LEAF_DARK,
		})
	# The spire.
	var top := _trunk_point(lx, lz, base_y, trunk_h, trunk_h, lean, bow)
	lobes.append({
		"c": top + Vector3i(0, 2, 0),
		"r": Vector3i(4, 6, 4),
		"m": VoxelDefs.LEAF,
	})
	_blob_shell(lobes, VoxelDefs.LEAF, 0.32)


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


## A tapering branch from `a` to `b`, `r0` voxels thick where it leaves and `r1`
## where it ends.
##
## Spheres swept along the segment rather than cubes: a third of the voxels for
## the same silhouette, and two limbs meeting at an elbow join without a corner
## sticking out of the bend.
func _limb(a: Vector3i, b: Vector3i, r0: float, r1: float, mat: int) -> void:
	var d := Vector3(b - a)
	var steps := int(maxf(d.length(), 1.0))
	for s in range(steps + 1):
		var t := float(s) / float(steps)
		var p := Vector3(a) + d * t
		var pi := Vector3i(int(round(p.x)), int(round(p.y)), int(round(p.z)))
		var rr := lerpf(r0, r1, t)
		var ri := int(ceil(rr))
		# Half a voxel of slack, so a radius that lands exactly on the grid
		# still fills its own shell instead of coming out one voxel thin.
		var r2 := rr * rr + 0.25
		for dz in range(-ri, ri + 1):
			for dy in range(-ri, ri + 1):
				for dx in range(-ri, ri + 1):
					if float(dx * dx + dy * dy + dz * dz) <= r2:
						_put(pi.x + dx, pi.y + dy, pi.z + dz, mat)


## Fills the union of ellipsoids and keeps only its surface layer.
##
## A lobe may carry its own material under the key `m`; `mat` is what the rest
## use. Where two lobes overlap the later one wins, and since only the surface
## survives, a canopy's lit and shaded clumps meet along the outside of the
## union with no seam between them.
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
	# The X and Z the lobes reach on each level of the box, so the surface pass
	# below can walk what was written instead of the whole cuboid.
	#
	# It earns its keep because a crown assembled from small clumps fills very
	# little of its own bounding box: a conifer is a cone in a cuboid nine
	# metres tall, and the level at its tip spans a couple of clumps out of the
	# full width of a chunk. These are the ranges the fill scanned rather than
	# what it actually set, which is a superset and so always safe, and they
	# cost four compares per lobe per level rather than anything per voxel.
	var zlo := PackedInt32Array()
	var zhi := PackedInt32Array()
	var xlo := PackedInt32Array()
	var xhi := PackedInt32Array()
	zlo.resize(sy)
	zhi.resize(sy)
	xlo.resize(sy)
	xhi.resize(sy)
	zlo.fill(sz)
	zhi.fill(-1)
	xlo.fill(sx)
	xhi.fill(-1)

	# `TerrainGen.hash2i` inlined: it is a handful of integer ops, but it was
	# being reached through a static call once per cell of every lobe's box,
	# which is hundreds of thousands of calls for one big tree at level 0.
	# Salt 7, folded into a constant.
	const SALT7 := 7 * 83492791
	const INV_1023 := 1.0 / 1023.0

	for l in lobes:
		var c: Vector3i = l["c"]
		var r: Vector3i = l["r"]
		# Stored one above the material, so that zero stays "outside".
		var lm: int = int(l.get("m", mat)) + 1
		var rx := float(maxi(r.x, 1))
		var irx := 1.0 / rx
		var iry := 1.0 / float(maxi(r.y, 1))
		var irz := 1.0 / float(maxi(r.z, 1))
		# Box relative extent of this lobe, which is the same on every level of
		# it; only which levels it touches varies.
		var bz0 := maxi(c.z - r.z, mn.z) - mn.z
		var bz1 := mini(c.z + r.z, mx.z) - mn.z
		var bx0 := maxi(c.x - r.x, mn.x) - mn.x
		var bx1 := mini(c.x + r.x, mx.x) - mn.x
		for y in range(maxi(c.y - r.y, mn.y), mini(c.y + r.y, mx.y) + 1):
			var iy := y - mn.y
			if bz0 < zlo[iy]:
				zlo[iy] = bz0
			if bz1 > zhi[iy]:
				zhi[iy] = bz1
			if bx0 < xlo[iy]:
				xlo[iy] = bx0
			if bx1 > xhi[iy]:
				xhi[iy] = bx1
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
				# Only the span of X the test can still pass over. Scanning the
				# lobe's full width here means walking twice as many cells as
				# the ellipsoid has, and the fill is the bulk of what a crown
				# costs. The slack under the root matches the row skip above,
				# so no voxel the roughness would have kept is dropped.
				var hw := int(rx * sqrt(1.3 - fyz)) + 1
				for x in range(maxi(c.x - hw, mn.x), mini(c.x + hw, mx.x) + 1):
					var fx := float(x - c.x) * irx
					var d := fyz + fx * fx
					var hh: int = (x * 31 + y) * 73856093 ^ hz
					hh = (hh ^ (hh >> 13)) * 1274126177
					if d < 1.0 + (float(hh & 1023) * INV_1023 - 0.5) * rough:
						inside[base + x] = lm

	for y in range(sy):
		var z0: int = zlo[y]
		var z1: int = zhi[y]
		if z0 > z1:
			continue
		var x0: int = xlo[y]
		var x1: int = xhi[y]
		for z in range(z0, z1 + 1):
			var row := (y * sz + z) * sx
			for x in range(x0, x1 + 1):
				var here: int = inside[row + x]
				if here == 0:
					continue
				var exposed := x == 0 or x == sx - 1 or y == 0 or y == sy - 1 or z == 0 or z == sz - 1 \
					or inside[row + x - 1] == 0 or inside[row + x + 1] == 0 \
					or inside[row + x - sx] == 0 or inside[row + x + sx] == 0 \
					or inside[row + x - sx * sz] == 0 or inside[row + x + sx * sz] == 0
				if exposed:
					_put(mn.x + x, mn.y + y, mn.z + z, here - 1)


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
