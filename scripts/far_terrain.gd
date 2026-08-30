class_name FarTerrain
extends RefCounted

## The distant island: a coarse, static mesh of the entire world.
##
## Streamed chunks only ever cover a few dozen metres around the player, which
## is fine down among the trees but leaves nothing to look at once the haze is
## allowed to open up. This builds a flat shaded mesh of the whole height field
## that carries the island, and the sea it sits in, out to the horizon.
##
## Detail is spent where it is seen. The mesh is laid out in blocks of BLOCK
## cells; a block that lies in open water, and whose neighbours do too, becomes
## a single quad, everything else is meshed at the full step. Three quarters of
## the covered square is water, so folding that away buys a much finer land
## surface for the same budget.
##
## Three things keep the mesh from fighting with the streamed chunks:
##
##  * every grid point is dropped below the real surface by an amount that grows
##    with how steeply and how sharply the ground turns there, so the coarse
##    surface stays underneath the real one and never pokes through the ground
##    in front of the player,
##  * the chunks dissolve into it (see voxel_common.gdshaderinc) instead of
##    ending along a hard circle, and
##  * the canopy, a second surface laid over the woods, is dithered away close
##    to the eye, where the real trees of the streamed chunks stand.
##
## Below the waterline the mesh doubles as the open sea: it follows the sea bed
## through the shallows, where the water is clear enough to show it and the
## water plane needs the real depth, and levels out just under the surface
## further out, where the water is opaque anyway.
##
## The result is handed back as a list of tiles rather than as one mesh, so that
## frustum and shadow culling have something to work with. As one mesh the whole
## island would be redrawn into every shadow cascade every frame.

const SEA := VoxelDefs.SEA_LEVEL
## Deepest the painted ocean surface may sit below the waterline, and the depth
## range over which it eases from the sea bed onto that level.
const SEA_SHELF := 4.0
const SHELF_BEGIN := 6.0
const SHELF_END := 14.0
## Body colour of the far water. Matches water.gdshader so the sea plane around
## the player and the painted sea beyond it read as the same water.
const SHALLOW_COLOR := Color(0.10, 0.44, 0.44)
const DEEP_COLOR := Color(0.01, 0.09, 0.19)
const DEPTH_FADE := 3.2
## How far the ground colour of a wooded cell is pulled towards the colour of a
## canopy. The canopy shell above it only shows at a distance, so near the
## handover the ground has to carry the woods on its own.
const CANOPY_TINT := 0.45

## Cells along the edge of one block, and how much water has to stand over a
## block before it may be folded down to a single quad. Six metres is well past
## the point where the water shader has gone opaque, so nothing that can still
## be made out through the surface is ever folded.
const BLOCK := 8
const COARSE_DEPTH := 6.0

## The drop below the real surface fades out towards the waterline, so that the
## folded water blocks and the fine cells bordering them agree exactly along
## their shared edge. Steeper ground is dropped further, since a coarse cell
## cuts a bigger corner off a slope than off a plain.
const DROP_BAND := 3.0
const DROP_SLOPE := 0.35
const DROP_BOW := 0.5
const DROP_MAX := 4.0

## Rough side length (m) of one tile of the finished mesh.
const TILE_METERS := 256.0

## Canopy. Crowns are blobs on the same 6.4 m grid the chunk builder plants its
## trees on, so a distant wood breaks up at the scale it really has. The heights
## match ChunkBuilder, whose trunks run 2.8 m to 7.4 m plus their leaves.
const CROWN_CELL := VoxelDefs.CHUNK_METERS
const CANOPY_MIN := 0.10
const CANOPY_THRESH := 0.30
const CANOPY_GAIN := 12.0
const CANOPY_MAX := 7.0

var _gen: TerrainGen
var _step: float
var _drop: float
var _block_m: float
## Blocks along one side, block corners along one side, and fine grid points
## along one side.
var _nb: int
var _cs: int
var _side: int
## Blocks per tile.
var _tb: int
var _origin: float

var _craw := PackedFloat32Array()
var _coarse := PackedByteArray()
var _state := PackedByteArray()
var _fraw := PackedFloat32Array()
var _fy := PackedFloat32Array()
var _wood := PackedFloat32Array()
var _can := PackedFloat32Array()


## Builds the tiles. Deterministic and free of any scene access, so it can run
## on a worker thread.
##
## `extent` is the half size (m) of the square the mesh covers, `step` the size
## of one cell of the fine grid and `drop` how far the land is sunk below the
## real surface.
##
## Returns an array of {pos, mesh, canopy_surface, has_land}: where the tile
## goes, what to draw, which of its surfaces is the canopy shell (-1 when it
## carries no woods) and whether it holds anything worth casting a shadow.
static func build(gen: TerrainGen, extent: float, step: float, drop: float) -> Array:
	return FarTerrain.new()._run(gen, extent, step, drop)


func _run(gen: TerrainGen, extent: float, step: float, drop: float) -> Array:
	_gen = gen
	_step = step
	_drop = drop
	_block_m = step * float(BLOCK)
	_nb = maxi(int(ceil(extent * 2.0 / _block_m)), 1)
	_cs = _nb + 1
	_side = _nb * BLOCK + 1
	_tb = maxi(int(round(TILE_METERS / _block_m)), 1)
	_origin = -float(_nb) * _block_m * 0.5

	_sample_blocks()
	_classify()
	_sample_fine()
	_resolve_fine()
	_seal_edges()
	return _emit()


## World position of a fine grid index along one axis. Block corners are
## addressed through their fine index too, so both passes sample a shared point
## at bit identical coordinates and the two resolutions meet exactly.
func _at(i: int) -> float:
	return _origin + float(i) * _step


# --------------------------------------------------------------------------
# blocks
# --------------------------------------------------------------------------

func _sample_blocks() -> void:
	_craw.resize(_cs * _cs)
	for bz in _cs:
		var z := _at(bz * BLOCK)
		var row := bz * _cs
		for bx in _cs:
			_craw[row + bx] = _gen.height_meters(_at(bx * BLOCK), z)


## A block may be folded to one quad only when it and all eight of its
## neighbours lie in open water. That dilation is what guarantees that the fine
## cells bordering a folded block are themselves deep enough to be dropped by
## nothing, which is what lets the two agree along their shared edge.
func _classify() -> void:
	var limit := SEA - COARSE_DEPTH
	var deep := PackedByteArray()
	deep.resize(_nb * _nb)
	for bz in _nb:
		var c0 := bz * _cs
		for bx in _nb:
			var i := c0 + bx
			deep[bz * _nb + bx] = 1 if (_craw[i] < limit and _craw[i + 1] < limit \
				and _craw[i + _cs] < limit and _craw[i + _cs + 1] < limit) else 0

	_coarse.resize(_nb * _nb)
	for bz in _nb:
		for bx in _nb:
			var ok := 1
			for dz in range(-1, 2):
				var nz := bz + dz
				if nz < 0 or nz >= _nb:
					continue
				for dx in range(-1, 2):
					var nx := bx + dx
					if nx < 0 or nx >= _nb:
						continue
					if deep[nz * _nb + nx] == 0:
						ok = 0
			_coarse[bz * _nb + bx] = ok


# --------------------------------------------------------------------------
# fine grid
# --------------------------------------------------------------------------

## Raw heights for every grid point of every unfolded block. Points on a shared
## block edge are visited twice, hence the state byte: 0 untouched, 1 sampled,
## 2 resolved.
func _sample_fine() -> void:
	var n := _side * _side
	_state.resize(n)
	_fraw.resize(n)
	_fy.resize(n)
	_wood.resize(n)
	_can.resize(n)
	for bz in _nb:
		for bx in _nb:
			if _coarse[bz * _nb + bx] != 0:
				continue
			var gx0 := bx * BLOCK
			var gz0 := bz * BLOCK
			for lz in BLOCK + 1:
				var gz := gz0 + lz
				var row := gz * _side
				var z := _at(gz)
				for lx in BLOCK + 1:
					var gi := row + gx0 + lx
					if _state[gi] != 0:
						continue
					_state[gi] = 1
					_fraw[gi] = _gen.height_meters(_at(gx0 + lx), z)


## Turns the raw heights into the surface the mesh is drawn at, and works out
## how much canopy stands on each point. Kept apart from the sampling pass
## because the drop needs the raw heights of the four neighbours, and those may
## belong to the next block along.
func _resolve_fine() -> void:
	for bz in _nb:
		for bx in _nb:
			if _coarse[bz * _nb + bx] != 0:
				continue
			var gx0 := bx * BLOCK
			var gz0 := bz * BLOCK
			for lz in BLOCK + 1:
				var gz := gz0 + lz
				var row := gz * _side
				for lx in BLOCK + 1:
					var gx := gx0 + lx
					var gi := row + gx
					if _state[gi] != 1:
						continue
					_state[gi] = 2
					var raw := _fraw[gi]
					var west := gx > 0 and _state[gi - 1] != 0
					var east := gx < _side - 1 and _state[gi + 1] != 0
					var north := gz > 0 and _state[gi - _side] != 0
					var south := gz < _side - 1 and _state[gi + _side] != 0
					var grad := 0.0
					if west:
						grad = maxf(grad, absf(raw - _fraw[gi - 1]))
					if east:
						grad = maxf(grad, absf(raw - _fraw[gi + 1]))
					if north:
						grad = maxf(grad, absf(raw - _fraw[gi - _side]))
					if south:
						grad = maxf(grad, absf(raw - _fraw[gi + _side]))
					# How far the ground bows away below a straight line drawn
					# over it. A cell is exactly such a line, so this is the
					# part of the error the gradient alone does not see: a wide
					# shallow hollow is barely sloped and still leaves the cell
					# hanging in the air over it.
					var bow := 0.0
					if west and east:
						bow = maxf(bow, (_fraw[gi - 1] + _fraw[gi + 1]) * 0.5 - raw)
					if north and south:
						bow = maxf(bow, (_fraw[gi - _side] + _fraw[gi + _side]) * 0.5 - raw)
					_fy[gi] = _point_y(raw, grad, maxf(bow, 0.0))
					if raw <= SEA:
						continue
					var mx := _at(gx)
					var mz := _at(gz)
					var w := _gen.woodland(mx, mz)
					_wood[gi] = w
					if w >= CANOPY_MIN:
						_can[gi] = _crown_height(mx, mz, raw, w)


## Height of the coarse surface at one point. The drop fades out below the
## waterline: down there nothing is ever seen next to a streamed chunk, and it
## is what lets a folded water block agree with its fine neighbours.
func _point_y(raw: float, grad: float, bow: float) -> float:
	var y := raw
	var k := smoothstep(SEA - DROP_BAND, SEA + 1.0, raw)
	if k > 0.0:
		y -= k * minf(_drop + DROP_SLOPE * grad + DROP_BOW * bow, DROP_MAX)
	var depth := SEA - y
	if depth <= 0.0:
		return y
	return SEA - lerpf(depth, SEA_SHELF, smoothstep(SHELF_BEGIN, SHELF_END, depth))


## Where a fine block meets a folded one the folded side is a straight line
## between two block corners while the fine side follows the sea bed, which
## would leave a crack. Both blocks share those corners exactly, so laying the
## fine edge onto the straight line between them closes it.
func _seal_edges() -> void:
	for bz in _nb:
		for bx in _nb:
			if _coarse[bz * _nb + bx] != 0:
				continue
			var gx0 := bx * BLOCK
			var gz0 := bz * BLOCK
			if bx > 0 and _coarse[bz * _nb + bx - 1] != 0:
				_seal(gx0, gz0, 0, 1)
			if bx < _nb - 1 and _coarse[bz * _nb + bx + 1] != 0:
				_seal(gx0 + BLOCK, gz0, 0, 1)
			if bz > 0 and _coarse[(bz - 1) * _nb + bx] != 0:
				_seal(gx0, gz0, 1, 0)
			if bz < _nb - 1 and _coarse[(bz + 1) * _nb + bx] != 0:
				_seal(gx0, gz0 + BLOCK, 1, 0)


func _seal(gx: int, gz: int, dx: int, dz: int) -> void:
	var a := _fy[gz * _side + gx]
	var b := _fy[(gz + dz * BLOCK) * _side + gx + dx * BLOCK]
	for k in range(1, BLOCK):
		_fy[(gz + dz * k) * _side + gx + dx * k] = lerpf(a, b, float(k) / float(BLOCK))


# --------------------------------------------------------------------------
# canopy
# --------------------------------------------------------------------------

## Smooth blobs on the same 6.4 m grid the trees themselves are planted on.
func _crown(mx: float, mz: float) -> float:
	var gx := mx / CROWN_CELL
	var gz := mz / CROWN_CELL
	var ix := int(floor(gx))
	var iz := int(floor(gz))
	var fx := gx - float(ix)
	var fz := gz - float(iz)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fz = fz * fz * (3.0 - 2.0 * fz)
	var a := _crown_at(ix, iz)
	var b := _crown_at(ix + 1, iz)
	var c := _crown_at(ix, iz + 1)
	var d := _crown_at(ix + 1, iz + 1)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)


func _crown_at(a: int, b: int) -> float:
	return float(TerrainGen.hash2i(a, b, 0x3c0a ^ _gen.world_seed) & 0xffff) / 65535.0


## How tall the canopy stands over one point, 0 where nothing grows. Uses the
## same limits as TerrainGen.feature_in_cell, so the woods of the distant mesh
## stop at the beach and at the tree line exactly where the real ones do.
func _crown_height(mx: float, mz: float, ground: float, wood: float) -> float:
	if ground < _gen.beach_top(mx, mz) or ground >= _gen.rock_line(mx, mz):
		return 0.0
	var cover := wood * (0.40 + 0.75 * _crown(mx, mz))
	if cover <= CANOPY_THRESH:
		return 0.0
	return minf((cover - CANOPY_THRESH) * CANOPY_GAIN, CANOPY_MAX)


# --------------------------------------------------------------------------
# colour
# --------------------------------------------------------------------------

## Open water, shaded by how deep it is. Alpha marks the cell as water for the
## shader sky reflection.
func _water_color(y: float) -> Color:
	var depth: float = clampf((SEA - y) / DEPTH_FADE, 0.0, 1.0)
	var c := SHALLOW_COLOR.lerp(DEEP_COLOR, depth)
	c.a = 1.0
	return c


## The ground material the chunk mesher would use at the same spot, pulled
## towards the colour of a canopy where the woods are.
func _land_color(mx: float, mz: float, y: float, gradient: float, wood: float,
		cx: int, cz: int) -> Color:
	var mat := _gen.surface_material(mx, mz, y, int(gradient))
	var col: Color = VoxelDefs.COLORS.get(mat, Color.MAGENTA)
	if wood > 0.0 and (mat == VoxelDefs.GRASS or mat == VoxelDefs.DIRT):
		col = col.lerp(VoxelDefs.COLORS[VoxelDefs.LEAF], wood * CANOPY_TINT)
	return _jitter(col, cx, cz, 0x7a11, 0.09)


## A little variation per cell, so large stretches of one material do not read
## as a flat sheet of colour.
func _jitter(col: Color, cx: int, cz: int, salt: int, amount: float) -> Color:
	var t := 1.0 + (float(TerrainGen.hash2i(cx, cz, salt) & 255) / 255.0 - 0.5) * amount
	return Color(col.r * t, col.g * t, col.b * t, 0.0)


# --------------------------------------------------------------------------
# meshing
# --------------------------------------------------------------------------

## Cells whose four corners together carry less canopy than this (m) are left
## to the ground surface alone, so a wood is not fringed with slivers.
const CANOPY_FLOOR := 2.0

## One quad is being written at a time into these, and they are handed over to
## a surface and reset once a pass over the tile is done. Members rather than
## locals because packed arrays are copy on write, so a function that took them
## as arguments would fill a copy and throw it away.
var _qv := PackedVector3Array()
var _qnrm := PackedVector3Array()
var _qcol := PackedColorArray()
var _qidx := PackedInt32Array()
var _qn := 0


## Cuts the grid into tiles and meshes each one. Tile local coordinates keep the
## vertex values small and give frustum and shadow culling something to work
## with; as a single mesh the whole island would be redrawn into every cascade.
func _emit() -> Array:
	var tiles: Array = []
	var nt := int(ceil(float(_nb) / float(_tb)))
	for tz in nt:
		for tx in nt:
			var tile := _emit_tile(tx * _tb, tz * _tb,
				mini((tx + 1) * _tb, _nb), mini((tz + 1) * _tb, _nb))
			if not tile.is_empty():
				tiles.append(tile)
	return tiles


func _emit_tile(bx0: int, bz0: int, bx1: int, bz1: int) -> Dictionary:
	if bx0 >= bx1 or bz0 >= bz1:
		return {}
	var cells := (bx1 - bx0) * (bz1 - bz0) * BLOCK * BLOCK
	var ox := _at(bx0 * BLOCK)
	var oz := _at(bz0 * BLOCK)

	_begin(cells)
	_emit_ground(bx0, bz0, bx1, bz1, ox, oz)
	var ground := _finish()
	if ground.is_empty():
		return {}

	_begin(cells)
	_emit_canopy(bx0, bz0, bx1, bz1, ox, oz)
	var canopy := _finish()

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ground)
	var canopy_surface := -1
	if not canopy.is_empty():
		canopy_surface = mesh.get_surface_count()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, canopy)

	# A tile that is nothing but folded water is flat and lies at the waterline,
	# so it can never shadow anything; saying so keeps it out of the cascades.
	var has_land := false
	for bz in range(bz0, bz1):
		for bx in range(bx0, bx1):
			if _coarse[bz * _nb + bx] == 0:
				has_land = true
				break
		if has_land:
			break

	return {
		"pos": Vector3(ox, 0.0, oz),
		"mesh": mesh,
		"canopy_surface": canopy_surface,
		"has_land": has_land,
	}


func _emit_ground(bx0: int, bz0: int, bx1: int, bz1: int, ox: float, oz: float) -> void:
	for bz in range(bz0, bz1):
		for bx in range(bx0, bx1):
			var gx0 := bx * BLOCK
			var gz0 := bz * BLOCK
			if _coarse[bz * _nb + bx] != 0:
				# Open water: the whole block collapses onto a single quad
				# spanning its four corners.
				var c0 := bz * _cs + bx
				var y00 := _point_y(_craw[c0], 0.0, 0.0)
				var y10 := _point_y(_craw[c0 + 1], 0.0, 0.0)
				var y01 := _point_y(_craw[c0 + _cs], 0.0, 0.0)
				var y11 := _point_y(_craw[c0 + _cs + 1], 0.0, 0.0)
				_quad(_at(gx0) - ox, _at(gz0) - oz, _block_m, y00, y10, y01, y11,
					_water_color((y00 + y10 + y01 + y11) * 0.25))
				continue

			for lz in BLOCK:
				var r0 := (gz0 + lz) * _side + gx0
				var r1 := r0 + _side
				for lx in BLOCK:
					var i0 := r0 + lx
					var i1 := r1 + lx
					var h00 := _fy[i0]
					var h10 := _fy[i0 + 1]
					var h01 := _fy[i1]
					var h11 := _fy[i1 + 1]
					var cx := gx0 + lx
					var cz := gz0 + lz
					var mid := (h00 + h10 + h01 + h11) * 0.25
					var col: Color
					if _fraw[i0] < SEA and _fraw[i0 + 1] < SEA \
							and _fraw[i1] < SEA and _fraw[i1 + 1] < SEA:
						col = _water_color(mid)
					else:
						var grad := maxf(absf(h10 - h00), absf(h01 - h00)) / _step
						var wood := (_wood[i0] + _wood[i0 + 1] + _wood[i1] + _wood[i1 + 1]) * 0.25
						col = _land_color(_at(cx) + _step * 0.5, _at(cz) + _step * 0.5,
							mid, grad, wood, cx, cz)
					_quad(_at(cx) - ox, _at(cz) - oz, _step, h00, h10, h01, h11, col)


## The woods, as a shell floating over the ground surface. Sinks back onto the
## ground wherever the crowns run out, so a wood has sloping edges rather than
## standing on a cliff of leaves.
func _emit_canopy(bx0: int, bz0: int, bx1: int, bz1: int, ox: float, oz: float) -> void:
	var leaf: Color = VoxelDefs.COLORS[VoxelDefs.LEAF]
	for bz in range(bz0, bz1):
		for bx in range(bx0, bx1):
			if _coarse[bz * _nb + bx] != 0:
				continue
			var gx0 := bx * BLOCK
			var gz0 := bz * BLOCK
			for lz in BLOCK:
				var r0 := (gz0 + lz) * _side + gx0
				var r1 := r0 + _side
				for lx in BLOCK:
					var i0 := r0 + lx
					var i1 := r1 + lx
					var a00 := _can[i0]
					var a10 := _can[i0 + 1]
					var a01 := _can[i1]
					var a11 := _can[i1 + 1]
					if a00 + a10 + a01 + a11 <= CANOPY_FLOOR:
						continue
					var cx := gx0 + lx
					var cz := gz0 + lz
					_quad(_at(cx) - ox, _at(cz) - oz, _step,
						_fy[i0] + a00, _fy[i0 + 1] + a10, _fy[i1] + a01, _fy[i1 + 1] + a11,
						_jitter(leaf, cx, cz, 0x51d3, 0.26))


func _begin(cells: int) -> void:
	_qv.resize(cells * 4)
	_qnrm.resize(cells * 4)
	_qcol.resize(cells * 4)
	_qidx.resize(cells * 6)
	_qn = 0


## Cuts what was actually written out of the buffers and packs it into surface
## arrays. Empty when the pass produced nothing.
##
## The slices matter: handing the buffers over as they are would leave the mesh
## holding the same storage the next tile is about to write into.
func _finish() -> Array:
	if _qn == 0:
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _qv.slice(0, _qn)
	arrays[Mesh.ARRAY_NORMAL] = _qnrm.slice(0, _qn)
	arrays[Mesh.ARRAY_COLOR] = _qcol.slice(0, _qn)
	arrays[Mesh.ARRAY_INDEX] = _qidx.slice(0, _qn / 4 * 6)
	return arrays


## One flat shaded quad. Same corner order as the top faces of the chunk
## mesher, so both read the same way under the same light.
func _quad(x0: float, z0: float, size: float,
		h00: float, h10: float, h01: float, h11: float, col: Color) -> void:
	var x1 := x0 + size
	var z1 := z0 + size
	var a := Vector3(x0, h00, z0)
	var b := Vector3(x0, h01, z1)
	var c := Vector3(x1, h11, z1)
	var d := Vector3(x1, h10, z0)
	var nrm := (c - a).cross(d - b).normalized()
	if nrm.y < 0.0:
		nrm = -nrm

	var v := _qn
	_qv[v] = a
	_qv[v + 1] = b
	_qv[v + 2] = c
	_qv[v + 3] = d
	for k in 4:
		_qnrm[v + k] = nrm
		_qcol[v + k] = col
	var i := v / 4 * 6
	_qidx[i] = v
	_qidx[i + 1] = v + 2
	_qidx[i + 2] = v + 1
	_qidx[i + 3] = v
	_qidx[i + 4] = v + 3
	_qidx[i + 5] = v + 2
	_qn = v + 4
