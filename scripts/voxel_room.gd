class_name VoxelRoom
extends RefCounted

## A small, bounded voxel volume built by filling and carving boxes.
##
## Interiors are authored, not generated, and they are not part of the
## heightmap: the terrain is one surface per column and can hold no room under
## it. So an interior is its own little mesh, built once, standing wherever it
## is put. That also means it costs the streaming nothing - it is not a chunk
## and never rebuilds.
##
## Fill and carve are the whole authoring language. At 10 cm even a modest room
## is tens of thousands of voxels, so it has to be described by the boxes it is
## made of rather than voxel by voxel; carving is what puts a doorway through a
## wall that has already been built.

const VS := VoxelDefs.VOXEL_SIZE

## Voxels keyed by Vector3i. The chunk mesher packs its keys into an int
## because it writes hundreds of thousands of them per chunk and the allocation
## shows; a room is built once and holds tens of thousands, where the clearer
## key costs nothing worth measuring.
var _v := {}


func solid_count() -> int:
	return _v.size()


## Fills the inclusive box between two voxel coordinates.
func fill(a: Vector3i, b: Vector3i, mat: int) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	for y in range(lo.y, hi.y + 1):
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				_v[Vector3i(x, y, z)] = mat


## Empties the inclusive box. Doorways, windows and the room's own air.
func carve(a: Vector3i, b: Vector3i) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	for y in range(lo.y, hi.y + 1):
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				_v.erase(Vector3i(x, y, z))


## A hollow chamber: the air volume you give it, wrapped in walls, a floor and
## a ceiling. The floor and ceiling are their own materials rather than the
## walls' - a vault reads as built rather than carved when the ground underfoot
## and the timber overhead are not the same stone the walls are.
##
## Takes the air rather than the outside of the masonry, because a floor plan
## is drawn in walkable rectangles, and because filling a solid block and
## carving it hollow again costs the whole volume: a chamber 4 m square is a
## hundred thousand dictionary writes to leave twenty thousand voxels standing.
## Six slabs cost only the masonry.
func chamber(air_lo: Vector3i, air_hi: Vector3i, wall: int, cap: int,
		wall_mat: int, floor_mat: int, ceil_mat: int) -> void:
	var lo := Vector3i(mini(air_lo.x, air_hi.x), mini(air_lo.y, air_hi.y),
		mini(air_lo.z, air_hi.z))
	var hi := Vector3i(maxi(air_lo.x, air_hi.x), maxi(air_lo.y, air_hi.y),
		maxi(air_lo.z, air_hi.z))
	# Floor and ceiling run the whole footprint, so the corners come from them
	# and the four walls only have to reach between.
	fill(Vector3i(lo.x - wall, lo.y - cap, lo.z - wall),
		Vector3i(hi.x + wall, lo.y - 1, hi.z + wall), floor_mat)
	fill(Vector3i(lo.x - wall, hi.y + 1, lo.z - wall),
		Vector3i(hi.x + wall, hi.y + cap, hi.z + wall), ceil_mat)
	fill(Vector3i(lo.x - wall, lo.y, lo.z - wall),
		Vector3i(lo.x - 1, hi.y, hi.z + wall), wall_mat)
	fill(Vector3i(hi.x + 1, lo.y, lo.z - wall),
		Vector3i(hi.x + wall, hi.y, hi.z + wall), wall_mat)
	fill(Vector3i(lo.x, lo.y, lo.z - wall),
		Vector3i(hi.x, hi.y, lo.z - 1), wall_mat)
	fill(Vector3i(lo.x, lo.y, hi.z + 1),
		Vector3i(hi.x, hi.y, hi.z + wall), wall_mat)


## Deterministic per-voxel brightness, so a flat wall still reads as individual
## 10 cm cubes. The world's shader does this per fragment; a room is a static
## mesh, so it is baked into the vertex colour instead.
func _shade(p: Vector3i, mat: int) -> Color:
	var c: Color = VoxelDefs.COLORS.get(mat, Color.MAGENTA)
	var tint: float = VoxelDefs.TINT.get(mat, 0.12)
	var h := TerrainGen.hash2i(p.x * 73 + p.y, p.z * 31 + p.y, 0x5eed)
	var k := 1.0 + (float(h) / 2147483647.0 - 0.5) * tint
	return Color(c.r * k, c.g * k, c.b * k)


## Meshes the volume with plain face culling and returns
## {mesh: ArrayMesh, shape: ConcavePolygonShape3D, count: int}.
func build() -> Dictionary:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	const DIRS := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	for p in _v:
		var mat: int = _v[p]
		# Shaded on the first face that actually gets emitted. Most of a
		# building is masonry nobody can see - a vault of five rooms is ninety
		# thousand voxels with maybe a third of them showing - and the tint is
		# a hash and a handful of dictionary lookups per voxel.
		var col := Color.BLACK
		var shaded := false
		for d in DIRS:
			if _v.has(p + d):
				continue
			if not shaded:
				col = _shade(p, mat)
				shaded = true
			_face(verts, norms, cols, idx, p, d, col)
	if verts.is_empty():
		return {"mesh": null, "shape": null, "count": 0}

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# The collision soup is the same faces. Interiors are small and static, so
	# there is nothing to gain from a second, coarser representation.
	var soup := PackedVector3Array()
	soup.resize(idx.size())
	for i in idx.size():
		soup[i] = verts[idx[i]]
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(soup)
	return {"mesh": mesh, "shape": shape, "count": _v.size()}


## One outward facing quad on the given side of a voxel.
func _face(verts: PackedVector3Array, norms: PackedVector3Array,
		cols: PackedColorArray, idx: PackedInt32Array,
		p: Vector3i, d: Vector3i, col: Color) -> void:
	var o := Vector3(p) * VS
	var n := Vector3(d)
	# Two axes perpendicular to the face, so the quad can be laid out without a
	# separate case for each of the six directions.
	var u := Vector3(n.y, n.z, n.x)
	var w := n.cross(u)
	# The face sits on the far side of the voxel for a positive normal, and on
	# the near side for a negative one.
	var base := o + Vector3(VS, VS, VS) * 0.5 + n * (VS * 0.5)
	var a := base - (u + w) * (VS * 0.5)
	var b := base + (u - w) * (VS * 0.5)
	var c := base + (u + w) * (VS * 0.5)
	var e := base - (u - w) * (VS * 0.5)
	var start := verts.size()
	verts.append_array([a, b, c, e])
	for i in 4:
		norms.append(n)
		cols.append(col)
	# Clockwise seen from the front, which is what Godot treats as the facing
	# side - for the renderer and, more importantly here, for the collision
	# shape. Wound the other way the floor is a back face: bodies fall straight
	# through it from above and are only caught on the way back up.
	# Same order ChunkBuilder._quad uses.
	idx.append_array([start, start + 2, start + 1,
		start, start + 3, start + 2])
