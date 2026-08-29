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
const VS := VoxelDefs.VOXEL_SIZE
const MS := CS + 2 # stride of the heightmap incl. a 1 column margin

var _gen: TerrainGen
var _cx: int
var _cz: int
var _ox: int # origin in world voxel coordinates
var _oz: int

var _heights := PackedInt32Array()
var _mats := PackedByteArray()
var _extras := {} # Vector3i (local voxel) -> material

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
## Local voxel -> phase of the mushroom it belongs to. Written while the
## mushroom is placed, because the meshing pass only sees the material.
var _glow_phase := {}
## Point lights the mushroom caps cast on their surroundings, in chunk local
## space. Only filled for chunks close enough to the player to get detail.
var _lights: Array[Dictionary] = []

var _want_detail := false
var _want_collision := true


static func build(gen: TerrainGen, cx: int, cz: int, want_detail: bool, want_collision: bool) -> Dictionary:
	var b := ChunkBuilder.new()
	b._gen = gen
	b._cx = cx
	b._cz = cz
	b._ox = cx * CS
	b._oz = cz * CS
	b._want_detail = want_detail
	b._want_collision = want_collision
	return b._run()


func _run() -> Dictionary:
	_sample_columns()
	_place_features()
	_mesh_terrain_top()
	_mesh_terrain_sides()
	_mesh_features()

	var result := {"cx": _cx, "cz": _cz, "mesh": null, "shape": null, "lights": _lights}
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
	_heights.resize(MS * MS)
	_mats.resize(MS * MS)
	var desert_flags := PackedByteArray()
	desert_flags.resize(MS * MS)

	for lz in range(-1, CS + 1):
		for lx in range(-1, CS + 1):
			var i := (lz + 1) * MS + (lx + 1)
			var mx := float(_ox + lx) * VS
			var mz := float(_oz + lz) * VS
			_heights[i] = int(floor(_gen.height_meters(mx, mz) / VS))
			desert_flags[i] = 1 if _gen.is_desert(mx, mz) else 0

	for lz in range(-1, CS + 1):
		for lx in range(-1, CS + 1):
			var i := (lz + 1) * MS + (lx + 1)
			var h := _heights[i]
			var slope := 0
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx - 1, lz)]))
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx + 1, lz)]))
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx, lz - 1)]))
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx, lz + 1)]))
			var desert := desert_flags[i] != 0
			var m := VoxelDefs.SAND if desert else VoxelDefs.GRASS
			if slope > 16:
				m = VoxelDefs.STONE
			elif slope > 6:
				m = VoxelDefs.SANDSTONE if desert else VoxelDefs.DIRT
			_mats[i] = m


func _clamp_idx(lx: int, lz: int) -> int:
	return (clampi(lz, -1, CS) + 1) * MS + (clampi(lx, -1, CS) + 1)


func _h(lx: int, lz: int) -> int:
	return _heights[(lz + 1) * MS + (lx + 1)]


func _m(lx: int, lz: int) -> int:
	return _mats[(lz + 1) * MS + (lx + 1)]


# --------------------------------------------------------------------------
# geometry helpers
# --------------------------------------------------------------------------

## Emits a quad. Corners must be given counter-clockwise as seen from `n`;
## Godot's front faces are clockwise, so the indices are reversed here.
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, collide: bool) -> void:
	if _sway:
		var s := _sway_verts.size()
		_sway_verts.push_back(a)
		_sway_verts.push_back(b)
		_sway_verts.push_back(c)
		_sway_verts.push_back(d)
		for k in 4:
			_sway_norms.push_back(n)
			_sway_cols.push_back(col)
			_sway_uvs.push_back(_sway_uv)
		_sway_idx.push_back(s)
		_sway_idx.push_back(s + 2)
		_sway_idx.push_back(s + 1)
		_sway_idx.push_back(s)
		_sway_idx.push_back(s + 3)
		_sway_idx.push_back(s + 2)
		return
	if _glow:
		var g := _glow_verts.size()
		_glow_verts.push_back(a)
		_glow_verts.push_back(b)
		_glow_verts.push_back(c)
		_glow_verts.push_back(d)
		for k in 4:
			_glow_norms.push_back(n)
			_glow_cols.push_back(col)
			_glow_uvs.push_back(_glow_uv)
		_glow_idx.push_back(g)
		_glow_idx.push_back(g + 2)
		_glow_idx.push_back(g + 1)
		_glow_idx.push_back(g)
		_glow_idx.push_back(g + 3)
		_glow_idx.push_back(g + 2)
		if collide and _want_collision:
			_col_faces.push_back(a)
			_col_faces.push_back(c)
			_col_faces.push_back(b)
			_col_faces.push_back(a)
			_col_faces.push_back(d)
			_col_faces.push_back(c)
		return
	var base := _verts.size()
	_verts.push_back(a)
	_verts.push_back(b)
	_verts.push_back(c)
	_verts.push_back(d)
	for k in 4:
		_norms.push_back(n)
		_cols.push_back(col)
	_idx.push_back(base)
	_idx.push_back(base + 2)
	_idx.push_back(base + 1)
	_idx.push_back(base)
	_idx.push_back(base + 3)
	_idx.push_back(base + 2)
	if collide and _want_collision:
		_col_faces.push_back(a)
		_col_faces.push_back(c)
		_col_faces.push_back(b)
		_col_faces.push_back(a)
		_col_faces.push_back(d)
		_col_faces.push_back(c)


# --------------------------------------------------------------------------
# terrain meshing
# --------------------------------------------------------------------------

func _mesh_terrain_top() -> void:
	var used := PackedByteArray()
	used.resize(CS * CS)
	for z in CS:
		for x in CS:
			if used[z * CS + x] != 0:
				continue
			var h := _h(x, z)
			var m := _m(x, z)
			var w := 1
			while x + w < CS and used[z * CS + x + w] == 0 and _h(x + w, z) == h and _m(x + w, z) == m:
				w += 1
			var d := 1
			while z + d < CS:
				var ok := true
				for i in w:
					if used[(z + d) * CS + x + i] != 0 or _h(x + i, z + d) != h or _m(x + i, z + d) != m:
						ok = false
						break
				if not ok:
					break
				d += 1
			for dz in d:
				for dx in w:
					used[(z + dz) * CS + x + dx] = 1

			var y := float(h) * VS
			var x0 := float(x) * VS
			var x1 := float(x + w) * VS
			var z0 := float(z) * VS
			var z1 := float(z + d) * VS
			_quad(
				Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
				Vector3.UP, VoxelDefs.color_of(m), true)


func _mesh_terrain_sides() -> void:
	# +X / -X : runs merge along Z
	for x in CS:
		for dir in [1, -1]:
			var z := 0
			while z < CS:
				var h := _h(x, z)
				var nh := _h(x + dir, z)
				if h <= nh:
					z += 1
					continue
				var m := _m(x, z)
				var run := 1
				while z + run < CS and _h(x, z + run) == h and _h(x + dir, z + run) == nh and _m(x, z + run) == m:
					run += 1
				var px := float(x + (1 if dir > 0 else 0)) * VS
				var z0 := float(z) * VS
				var z1 := float(z + run) * VS
				for band in _bands(h, nh, m):
					var y0: float = band[0]
					var y1: float = band[1]
					var col: Color = band[2]
					if dir > 0:
						_quad(Vector3(px, y0, z1), Vector3(px, y0, z0), Vector3(px, y1, z0), Vector3(px, y1, z1),
							Vector3.RIGHT, col, true)
					else:
						_quad(Vector3(px, y0, z0), Vector3(px, y0, z1), Vector3(px, y1, z1), Vector3(px, y1, z0),
							Vector3.LEFT, col, true)
				z += run

	# +Z / -Z : runs merge along X
	for z in CS:
		for dir in [1, -1]:
			var x := 0
			while x < CS:
				var h := _h(x, z)
				var nh := _h(x, z + dir)
				if h <= nh:
					x += 1
					continue
				var m := _m(x, z)
				var run := 1
				while x + run < CS and _h(x + run, z) == h and _h(x + run, z + dir) == nh and _m(x + run, z) == m:
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
							Vector3.BACK, col, true)
					else:
						_quad(Vector3(x1, y0, pz), Vector3(x0, y0, pz), Vector3(x0, y1, pz), Vector3(x1, y1, pz),
							Vector3.FORWARD, col, true)
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

func _put(x: int, y: int, z: int, mat: int) -> void:
	if x < 0 or x >= CS or z < 0 or z >= CS or y < 0:
		return
	# The column fills y = 0 .. h-1, so anything below h would sit inside the
	# terrain. Keeping the topmost terrain voxel too would emit a second set of
	# coplanar faces on top of the ground surface and make the two z-fight.
	if y < _h(x, z):
		return # buried inside the terrain
	_extras[Vector3i(x, y, z)] = mat


func _place_features() -> void:
	for fcz in range(_cz - 1, _cz + 2):
		for fcx in range(_cx - 1, _cx + 2):
			var f := _gen.feature_in_cell(fcx, fcz)
			if f.is_empty():
				continue
			var lx: int = int(f["x"]) - _ox
			var lz: int = int(f["z"]) - _oz
			var base_y := _gen.height_at(int(f["x"]), int(f["z"]))
			var rng := RandomNumberGenerator.new()
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
	if _want_detail:
		_add_ground_cover()


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
		var tr2 := maxi(taper, 1) * maxi(taper, 1)
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
	for i in arms:
		var side := 1 if rng.randf() < 0.5 else -1
		var axis_x := rng.randf() < 0.5
		var ay := base_y + rng.randi_range(int(h * 0.4), int(h * 0.7))
		var reach := rng.randi_range(5, 9)
		for k in range(1, reach + 1):
			for dy in range(-1, 2):
				for dd in range(-1, 2):
					if axis_x:
						_put(lx + side * (r + k), ay + dy, lz + dd, VoxelDefs.CACTUS)
					else:
						_put(lx + dd, ay + dy, lz + side * (r + k), VoxelDefs.CACTUS)
		var tip := rng.randi_range(6, 12)
		for k in tip:
			for dy in range(-1, 2):
				for dd in range(-1, 2):
					if axis_x:
						_put(lx + side * (r + reach) + dy, ay + k, lz + dd, VoxelDefs.CACTUS)
					else:
						_put(lx + dd, ay + k, lz + side * (r + reach) + dy, VoxelDefs.CACTUS)


func _add_boulder(lx: int, lz: int, base_y: int, rng: RandomNumberGenerator) -> void:
	var rad := rng.randi_range(4, 11)
	var lobes := [{
		"c": Vector3i(lx, base_y + rad / 3, lz),
		"r": Vector3i(rad, int(rad * 0.8), rad + rng.randi_range(-2, 2)),
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
		var my := _gen.height_at(_ox + mx, _oz + mz)
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
		var r := maxi(int(round(float(stem_r) * flare)), 1)
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
	if not _want_detail:
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
	_put(x, y, z, mat)
	var key := Vector3i(x, y, z)
	if _extras.has(key):
		_glow_phase[key] = phase


## Small grass tufts / desert pebbles, only generated for nearby chunks.
func _add_ground_cover() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = TerrainGen.hash2i(_cx, _cz, _gen.world_seed ^ 0x5eed)
	for i in 170:
		var x := rng.randi_range(0, CS - 1)
		var z := rng.randi_range(0, CS - 1)
		var m := _m(x, z)
		var h := _h(x, z)
		if m == VoxelDefs.GRASS:
			var n := rng.randi_range(1, 4)
			for k in n:
				_put(x, h + k, z, VoxelDefs.BLADE)
			if rng.randf() < 0.35:
				var ox := rng.randi_range(-1, 1)
				var oz := rng.randi_range(-1, 1)
				for k in maxi(n - 1, 1):
					_put(x + ox, _h(clampi(x + ox, 0, CS - 1), clampi(z + oz, 0, CS - 1)) + k, z + oz, VoxelDefs.BLADE)
		elif m == VoxelDefs.SAND and rng.randf() < 0.06:
			_put(x, h, z, VoxelDefs.STONE)


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

	var sx := mx.x - mn.x + 1
	var sy := mx.y - mn.y + 1
	var sz := mx.z - mn.z + 1
	var inside := PackedByteArray()
	inside.resize(sx * sy * sz)

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
				for x in range(maxi(c.x - r.x, mn.x), mini(c.x + r.x, mx.x) + 1):
					var fx := float(x - c.x) * irx
					var d := fyz + fx * fx
					var jitter := (float(TerrainGen.hash2i(x * 31 + y, z, 7) & 1023) / 1023.0 - 0.5) * rough
					if d < 1.0 + jitter:
						inside[row + x - mn.x] = 1

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


const _NEIGHBOURS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func _mesh_features() -> void:
	for key in _extras:
		var p: Vector3i = key
		var mat: int = _extras[key]
		var col := VoxelDefs.color_of(mat)
		var collide: bool = VoxelDefs.SOLID_FEATURES.has(mat)
		_sway = mat == VoxelDefs.BLADE
		if _sway:
			_sway_uv = _sway_data(p)
		_glow = VoxelDefs.GLOW.has(mat)
		if _glow:
			_glow_uv = Vector2(VoxelDefs.GLOW[mat], _glow_phase.get(p, 0.0))
		var x0 := float(p.x) * VS
		var x1 := x0 + VS
		var y0 := float(p.y) * VS
		var y1 := y0 + VS
		var z0 := float(p.z) * VS
		var z1 := z0 + VS
		for n in _NEIGHBOURS:
			var q := p + n
			if _extras.has(q):
				continue
			if q.x >= -1 and q.x <= CS and q.z >= -1 and q.z <= CS and q.y < _h(q.x, q.z):
				continue # hidden by terrain
			if n.x == 1:
				_quad(Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1),
					Vector3.RIGHT, col, collide)
			elif n.x == -1:
				_quad(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0),
					Vector3.LEFT, col, collide)
			elif n.y == 1:
				_quad(Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0),
					Vector3.UP, col, collide)
			elif n.y == -1:
				_quad(Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1),
					Vector3.DOWN, col, collide)
			elif n.z == 1:
				_quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1),
					Vector3.BACK, col, collide)
			else:
				_quad(Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0),
					Vector3.FORWARD, col, collide)

	_sway = false
	_glow = false


## Wind data baked into the UV of a grass voxel: how stiff it is (0 at the
## ground, 1 at the tip of a tuft) and a phase that is unique per tuft column
## so neighbouring tufts do not sway in lockstep.
func _sway_data(p: Vector3i) -> Vector2:
	var above := float(p.y - _h(clampi(p.x, -1, CS), clampi(p.z, -1, CS))) * VS
	return Vector2(clampf(above / 0.4, 0.0, 1.0), _gen.rand01(_ox + p.x, _oz + p.z, 0x21ad))