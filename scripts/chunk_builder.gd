class_name ChunkBuilder
extends RefCounted

## Builds the render mesh (and collision shape) of one chunk.
##
## Terrain is a heightmap, so only the visible top faces and the vertical steps
## between neighbouring columns are emitted. Top faces are merged with a 2D
## greedy algorithm, step faces are merged along their run direction. Features
## (trees, cacti, boulders, grass) live in a sparse voxel dictionary and are
## meshed with simple face culling.

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

	var result := {"cx": _cx, "cz": _cz, "mesh": null, "shape": null}
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
	var biomes := PackedFloat32Array()
	biomes.resize(MS * MS)

	for lz in range(-1, CS + 1):
		for lx in range(-1, CS + 1):
			var i := (lz + 1) * MS + (lx + 1)
			var mx := float(_ox + lx) * VS
			var mz := float(_oz + lz) * VS
			_heights[i] = int(floor(_gen.height_meters(mx, mz) / VS))
			biomes[i] = _gen.biome_at(mx, mz)

	for lz in range(-1, CS + 1):
		for lx in range(-1, CS + 1):
			var i := (lz + 1) * MS + (lx + 1)
			var h := _heights[i]
			var slope := 0
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx - 1, lz)]))
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx + 1, lz)]))
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx, lz - 1)]))
			slope = maxi(slope, absi(h - _heights[_clamp_idx(lx, lz + 1)]))
			var desert := biomes[i] >= 0.5
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
	if y < _h(x, z) - 1:
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


## Wind data baked into the UV of a grass voxel: how stiff it is (0 at the
## ground, 1 at the tip of a tuft) and a phase that is unique per tuft column
## so neighbouring tufts do not sway in lockstep.
func _sway_data(p: Vector3i) -> Vector2:
	var above := float(p.y - _h(clampi(p.x, -1, CS), clampi(p.z, -1, CS))) * VS
	return Vector2(clampf(above / 0.4, 0.0, 1.0), _gen.rand01(_ox + p.x, _oz + p.z, 0x21ad))