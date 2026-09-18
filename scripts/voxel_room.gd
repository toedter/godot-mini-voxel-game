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

	# Texture the surfaces a player actually reads - the walls at eye height,
	# the floor underfoot - into individual stones of their own. The ceiling is
	# left to `plank_ceiling`, which has to run after a chamber that is vaulted
	# rather than flat-capped has had its arc carved, and so cannot be done
	# from here. The wall is coursed ashlar quarried from several tones of the
	# same pale brick; the floor is crazy-paved flagstone in its own colder
	# greys, so the two still read as different masonry up close rather than
	# the same texture recoloured.
	var mortar := VoxelDefs.MORTAR
	var floor_mortar := VoxelDefs.FLOOR_MORTAR
	var wall_stones := _family(wall_mat, _WALL_FAMILY)
	var floor_stones := _family(floor_mat, _FLOOR_FAMILY)
	var wy := hi.y - lo.y + 1
	var wall_z := hi.z - lo.z + 1 + wall * 2
	var wall_x := hi.x - lo.x + 1
	mason(Vector3i(lo.x - 1, lo.y, lo.z - wall), Vector3i(0, 1, 0),
		Vector3i(0, 0, 1), Vector3i(1, 0, 0), wy, wall_z, wall_stones, mortar,
		3, 4, 5, 9, _face_seed(lo, 0))
	mason(Vector3i(hi.x + 1, lo.y, lo.z - wall), Vector3i(0, 1, 0),
		Vector3i(0, 0, 1), Vector3i(-1, 0, 0), wy, wall_z, wall_stones, mortar,
		3, 4, 5, 9, _face_seed(lo, 1))
	mason(Vector3i(lo.x, lo.y, lo.z - 1), Vector3i(0, 1, 0),
		Vector3i(1, 0, 0), Vector3i(0, 0, 1), wy, wall_x, wall_stones, mortar,
		3, 4, 5, 9, _face_seed(lo, 2))
	mason(Vector3i(lo.x, lo.y, hi.z + 1), Vector3i(0, 1, 0),
		Vector3i(1, 0, 0), Vector3i(0, 0, -1), wy, wall_x, wall_stones, mortar,
		3, 4, 5, 9, _face_seed(lo, 3))
	mason_flagstone(Vector3i(lo.x - wall, lo.y - 1, lo.z - wall),
		Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 1, 0),
		wall_x + wall * 2, wall_z, floor_stones, floor_mortar, 7,
		_face_seed(lo, 4))
	# And dither every joint that has just been cut, so a seam reads as a
	# groove with a soft shoulder rather than as a one-voxel step.
	soften_joints(Vector3i(lo.x - 1, lo.y, lo.z - wall), Vector3i(0, 1, 0),
		Vector3i(0, 0, 1), wy, wall_z, mortar, VoxelDefs.MORTAR_EDGE, 2,
		_face_seed(lo, 0))
	soften_joints(Vector3i(hi.x + 1, lo.y, lo.z - wall), Vector3i(0, 1, 0),
		Vector3i(0, 0, 1), wy, wall_z, mortar, VoxelDefs.MORTAR_EDGE, 2,
		_face_seed(lo, 1))
	soften_joints(Vector3i(lo.x, lo.y, lo.z - 1), Vector3i(0, 1, 0),
		Vector3i(1, 0, 0), wy, wall_x, mortar, VoxelDefs.MORTAR_EDGE, 2,
		_face_seed(lo, 2))
	soften_joints(Vector3i(lo.x, lo.y, hi.z + 1), Vector3i(0, 1, 0),
		Vector3i(1, 0, 0), wy, wall_x, mortar, VoxelDefs.MORTAR_EDGE, 2,
		_face_seed(lo, 3))
	soften_joints(Vector3i(lo.x - wall, lo.y - 1, lo.z - wall),
		Vector3i(1, 0, 0), Vector3i(0, 0, 1), wall_x + wall * 2, wall_z,
		floor_mortar, VoxelDefs.FLOOR_MORTAR_EDGE, 3, _face_seed(lo, 4))


## Small, deliberately hand-picked families of honest tonal siblings for the
## two base materials `chamber` textures, so `mason`/`mason_flagstone` can
## pick a whole stone's colour from several close but different swatches
## instead of stamping the same one over and over. A material with no family
## of its own (furniture cut straight from `STONE`, say) just falls back to
## itself.
const _WALL_FAMILY := {
	VoxelDefs.SANDSTONE: [VoxelDefs.SANDSTONE, VoxelDefs.SANDSTONE_LIGHT,
		VoxelDefs.SANDSTONE_DARK, VoxelDefs.SANDSTONE_WARM],
	VoxelDefs.BRICK: [VoxelDefs.BRICK, VoxelDefs.BRICK_LIGHT,
		VoxelDefs.BRICK_DARK, VoxelDefs.BRICK_WARM],
}
const _FLOOR_FAMILY := {
	VoxelDefs.FLOOR_STONE: [VoxelDefs.FLOOR_STONE, VoxelDefs.FLOOR_STONE_LIGHT,
		VoxelDefs.FLOOR_STONE_DARK, VoxelDefs.FLOOR_STONE_PALE],
}
const _CEIL_FAMILY := {
	VoxelDefs.WOOD: [VoxelDefs.WOOD, VoxelDefs.WOOD_LIGHT,
		VoxelDefs.WOOD_DARK],
}


func _family(base: int, table: Dictionary) -> Array:
	return table.get(base, [base])


## A deterministic salt for one face of one chamber's masonry, so neither
## repeats another's coursing - two chambers built from the same `wall`/`cap`
## do not read as the same photograph of a wall pasted twice.
func _face_seed(lo: Vector3i, face: int) -> int:
	return TerrainGen.hash2i(lo.x * 92821 + lo.z * 6899, lo.y * 233 + face,
		0x6a17c0de)


## Textures one already-solid face of a chamber's masonry - built flat by
## `chamber` - into individual stones of their own, each a random size within
## the given range rather than one block stamped over and over, laid in a
## running bond - each course offset from the one below - so the coursing
## reads as laid stone rather than a printed grid. A medieval wall is not
## built from identical bricks either in size or in colour: each stone is a
## random pick from `mat_variants`, several honest tones of the same rock
## rather than one swatch repeated, and is occasionally proud or recessed by
## a single voxel along the outward normal `n`, so the surface catches light
## as unevenly stacked stone rather than a flat, painted slab.
##
## No stone is actually a rectangle. The coursing only decides the cell each
## stone is set into; the stone itself is laid a voxel over or under each of
## that cell's four edges and has a corner knocked off, so the joints between
## stones wander instead of ruling straight lines across the wall.
##
## Every stone is separated from its neighbours by a one-voxel groove of
## `mortar_mat` - no brighter rim around it; the tonal variety between
## neighbouring stones is what keeps the coursing from reading as a grid, not
## a highlighted bevel.
##
## `origin` is the voxel already sitting at u=0, v=0 - the one layer
## `chamber` built facing open air - and `u` is the axis a course stacks
## along (height, for a wall); `v` is the axis a course runs across.
## `course_min`/`course_max` and `block_min`/`block_max` bound a stone's size
## along each axis, in voxels. Only ever rewrites that one layer, plus the
## single voxel to either side of it that a proud or recessed stone touches -
## never the wall's own unseen bulk behind it.
func mason(origin: Vector3i, u: Vector3i, v: Vector3i, n: Vector3i,
		u_len: int, v_len: int, mat_variants: Array, mortar_mat: int,
		course_min: int, course_max: int, block_min: int, block_max: int,
		salt: int) -> void:
	if u_len <= 0 or v_len <= 0:
		return
	# The joints first, as a bed of mortar over the whole face: every stone is
	# then laid into it, and whatever is left showing between them is the
	# joint. Drawing it this way is what lets a stone be any shape at all -
	# the mortar is not a line that has to be drawn around the stone, it is
	# simply the wall wherever no stone was set.
	for pu in range(u_len):
		for pv in range(v_len):
			_v[origin + u * pu + v * pv] = mortar_mat

	var uu := 0
	var course := 0
	while uu < u_len:
		var ch := course_min + int(TerrainGen.hash2i(course, salt, 0x7a11)
			% (course_max - course_min + 1))
		var u_hi := mini(uu + ch, u_len)
		# Every other course starts half a stone further along, the way a
		# running bond staggers its joints so two courses never stack one
		# perpend directly over another.
		var phase := int(TerrainGen.hash2i(course, salt, 0x2eed)
			% (block_min + block_max)) if course % 2 == 1 else 0
		var vv := -phase
		var block := 0
		while vv < v_len:
			var bw := block_min + int(TerrainGen.hash2i(course * 733 + block,
				salt, 0x8a17) % (block_max - block_min + 1))
			_stone(origin, u, v, n, u_len, v_len, uu, u_hi - 1, vv,
				vv + bw - 1, course, block, mat_variants, salt)
			# One voxel of the mortar bed is left showing between this stone
			# and the next, before the next one starts.
			vv += bw + 1
			block += 1
		uu = u_hi + 1
		course += 1


## Sets one stone into the bed of mortar `mason` has laid, within the cell the
## coursing gave it. No stone is actually the rectangle of that cell: each of
## its four edges is pushed out into the joint or pulled back off it by a
## voxel of its own, and a corner or two is knocked off, so the stone is a
## rough quadrilateral with chipped ends - which is the whole difference
## between hand-cut stone and printed brick, and the reason the joints between
## them wander instead of ruling straight lines across the wall. The edges are
## moved a whole stone at a time rather than voxel by voxel: jittering every
## voxel of an edge separately does not read as a rough stone, it reads as
## static.
func _stone(origin: Vector3i, u: Vector3i, v: Vector3i, n: Vector3i,
		u_len: int, v_len: int, u0: int, u1: int, v0: int, v1: int,
		course: int, block: int, mat_variants: Array, salt: int) -> void:
	var key := course * 4093 + block
	var h := TerrainGen.hash2i(key, salt, 0x9e37)
	# -1 pulls the edge back off the joint, +1 pushes it into the joint and up
	# against the neighbouring stone; most edges stay where the coursing put
	# them.
	var a_u := maxi(u0 + _edge(h, 0), 0)
	var b_u := mini(u1 - _edge(h, 1), u_len - 1)
	var a_v := maxi(v0 + _edge(h, 2), 0)
	var b_v := mini(v1 - _edge(h, 3), v_len - 1)
	if a_u > b_u or a_v > b_v:
		return
	# The corner to knock a voxel off, if this stone is one of the third or so
	# that have lost one.
	var chip := (h >> 9) % 12
	var roll := TerrainGen.hash2i(key, salt, 0x51a5) % 20
	var variant: int = mat_variants[TerrainGen.hash2i(key, salt, 0x3c11)
		% mat_variants.size()]
	for pu in range(a_u, b_u + 1):
		for pv in range(a_v, b_v + 1):
			var corner := (0 if pu == a_u else 1) * 2 + (0 if pv == a_v else 1)
			var on_edge := (pu == a_u or pu == b_u) and (pv == a_v or pv == b_v)
			if chip < 4 and on_edge and corner == chip:
				continue
			var p := origin + u * pu + v * pv
			if roll == 0:
				# Recessed: bare the layer already standing behind.
				_v.erase(p)
				continue
			_v[p] = variant
			if roll == 1:
				# Proud: the whole stone stands one voxel further out than
				# its neighbours.
				_v[p + n] = variant


## One edge's own displacement, in voxels, from the four packed into a
## stone's hash.
func _edge(h: int, i: int) -> int:
	var q := (h >> (i * 3)) % 8
	if q == 0:
		return -1
	if q == 1:
		return 1
	return 0


## Textures the floor's already-solid top face into a flagstone floor: stones
## of their own irregular sizes, each one ringed all the way round by a groove
## of dark `mortar_mat`, which is what makes a floor read as paving that was
## bedded and grouted rather than as a wall laid on its back. Scatters a seed
## point into every `cell`-voxel square of the face, nudged to a random spot
## within its own square, and gives every voxel to whichever seed sits nearest
## it - a jittered Voronoi diagram, the cheap way to grow organic,
## irregularly-sized polygons from a regular grid without ever having to store
## or walk an edge list.
##
## The grout is then found rather than guessed at: a voxel whose neighbour
## belongs to a different stone is grout, so the border is continuous and
## exactly one voxel wide everywhere, however irregular the stone it runs
## around. Only the voxel on the lower-numbered side of a boundary takes it,
## or every joint would come out two voxels wide and the floor would read as
## more mortar than stone. Each stone then gets its own colour from
## `mat_variants` and its own chance to sit one voxel proud or recessed,
## exactly as `mason` gives a wall.
func mason_flagstone(origin: Vector3i, u: Vector3i, v: Vector3i, n: Vector3i,
		u_len: int, v_len: int, mat_variants: Array, mortar_mat: int,
		cell: int, salt: int) -> void:
	if u_len <= 0 or v_len <= 0:
		return
	# Which stone owns each voxel of the face, worked out once so the grout
	# pass below can simply compare neighbours.
	var owner := PackedInt32Array()
	owner.resize(u_len * v_len)
	for pu in range(u_len):
		var cu := int(floor(float(pu) / cell))
		for pv in range(v_len):
			var cv := int(floor(float(pv) / cell))
			var best_d := INF
			var best_id := 0
			for du in range(-1, 2):
				for dv in range(-1, 2):
					var gcu := cu + du
					var gcv := cv + dv
					var jx := float(TerrainGen.hash2i(gcu, gcv,
						salt ^ 0x1234) % 1000) / 1000.0
					var jy := float(TerrainGen.hash2i(gcu, gcv,
						salt ^ 0x5678) % 1000) / 1000.0
					var sx := (float(gcu) + 0.2 + jx * 0.6) * cell
					var sy := (float(gcv) + 0.2 + jy * 0.6) * cell
					var dx := float(pu) - sx
					var dy := float(pv) - sy
					var d := dx * dx + dy * dy
					if d < best_d:
						best_d = d
						best_id = TerrainGen.hash2i(gcu, gcv, salt ^ 0x9abc)
			owner[pu * v_len + pv] = best_id
	for pu in range(u_len):
		for pv in range(v_len):
			var id := owner[pu * v_len + pv]
			var p := origin + u * pu + v * pv
			var grout := false
			for d2: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				var qu := pu + d2.x
				var qv := pv + d2.y
				if qu < 0 or qu >= u_len or qv < 0 or qv >= v_len:
					continue
				var other := owner[qu * v_len + qv]
				if other > id:
					grout = true
					break
			if grout:
				_v[p] = mortar_mat
				continue
			var variant: int = mat_variants[id % mat_variants.size()]
			var roll := id % 20
			if roll == 0:
				_v.erase(p)
			else:
				_v[p] = variant
				if roll == 1:
					_v[p + n] = variant


## Dithers the joints of a face `mason` or `mason_flagstone` has just laid, by
## giving one stone voxel in `one_in` of those that border a joint a half-tone
## standing between the stone and the mortar beside them. Nothing here moves a
## stone or a seam, and the mortar itself is left alone - breaking up a groove
## that is only one voxel wide would cost the joint the continuous dark line
## that is the whole point of it. What is softened is the shoulder on the
## stone side, which turns a single hard step into two smaller ones, and that
## is as close to an anti-aliased edge as 10 cm voxels can come. A floor wants
## a thinner fringe than a wall: its stones are smaller, and a shoulder that
## is a fair share of the stone reads as dirt rather than as an edge.
##
## Every change is worked out against the face as it was found and applied
## afterwards, so a voxel that has just been softened never counts as mortar
## for its neighbour and the dithering cannot spread inward off the joint.
func soften_joints(origin: Vector3i, u: Vector3i, v: Vector3i,
		u_len: int, v_len: int, mortar_mat: int, edge_mat: int,
		one_in: int, salt: int) -> void:
	var changed := {}
	for pu in range(u_len):
		for pv in range(v_len):
			var p := origin + u * pu + v * pv
			if not _v.has(p):
				continue
			var here: int = _v[p]
			if here == mortar_mat or here == edge_mat:
				continue
			var on_joint := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				var qu := pu + d.x
				var qv := pv + d.y
				if qu < 0 or qu >= u_len or qv < 0 or qv >= v_len:
					continue
				var q := origin + u * qu + v * qv
				if _v.has(q) and _v[q] == mortar_mat:
					on_joint = true
					break
			if not on_joint:
				continue
			if TerrainGen.hash2i(pu, pv, salt ^ 0x50f7) % one_in == 0:
				changed[p] = edge_mat
	for p: Vector3i in changed:
		_v[p] = changed[p]


## Textures the underside of a ceiling already built by `chamber` into a
## boarded timber one: planks running the length of the room (Z) in their own
## tones, each separated from its neighbour by a dark seam, crossed every so
## often by a joist. Works off whatever is standing rather than off a flat
## height, so the same call boards a barrel vault carved by `vault_ceiling`
## as readily as an ordinary flat cap - each column of the footprint is walked
## upward from the air until the first solid voxel, and that one voxel, the
## only one anybody can see from below, is what gets painted.
##
## Takes the same air volume, wall and cap `chamber` was given, so a ceiling
## is boarded by repeating the call that built it rather than by working out
## the slab's own bounds again.
func plank_ceiling(air_lo: Vector3i, air_hi: Vector3i, wall: int, cap: int,
		ceil_mat: int, salt: int) -> void:
	# A board is 40-70 cm across and a joist crosses every 2.4 m, which at
	# 10 cm voxels is timber a carpenter could actually have carried in.
	const BOARD_MIN := 4
	const BOARD_MAX := 7
	const JOIST_EVERY := 24
	const JOIST_WIDE := 2
	var board_mats := _family(ceil_mat, _CEIL_FAMILY)
	var seam_mat := VoxelDefs.BEAM
	var lo := Vector3i(mini(air_lo.x, air_hi.x), mini(air_lo.y, air_hi.y),
		mini(air_lo.z, air_hi.z))
	var hi := Vector3i(maxi(air_lo.x, air_hi.x), maxi(air_lo.y, air_hi.y),
		maxi(air_lo.z, air_hi.z))
	var x0 := lo.x - wall
	var z0 := lo.z - wall
	var x_len := hi.x - lo.x + 1 + wall * 2
	var z_len := hi.z - lo.z + 1 + wall * 2
	# Lay the boards out across X once: every column of the ceiling at the
	# same x belongs to the same plank, so its width, its tone and the seam
	# that ends it are decided here rather than per voxel.
	var board_of := PackedInt32Array()
	board_of.resize(x_len)
	var xi := 0
	var board := 0
	while xi < x_len:
		var bw := BOARD_MIN + int(TerrainGen.hash2i(board, salt, 0x4b0a)
			% (BOARD_MAX - BOARD_MIN + 1))
		for k in range(xi, mini(xi + bw, x_len)):
			board_of[k] = board
		# The seam is the plank's last voxel, marked as belonging to no board.
		var seam := xi + bw
		if seam < x_len:
			board_of[seam] = -1
		xi = seam + 1
		board += 1
	for dx in range(x_len):
		var b := board_of[dx]
		var mat: int = seam_mat
		if b >= 0:
			mat = board_mats[TerrainGen.hash2i(b, salt, 0x1f0d)
				% board_mats.size()]
		for dz in range(z_len):
			# Joists cross the boards at a fixed spacing, and the butt joint
			# where one plank ends and the next begins is drawn as a seam of
			# its own so the boarding does not read as endlessly long timber.
			var m := mat
			if dz % JOIST_EVERY < JOIST_WIDE:
				m = seam_mat
			elif b >= 0 and (dz + b * 11) % (JOIST_EVERY * 2) == 0:
				m = seam_mat
			var p := Vector3i(x0 + dx, hi.y + 1, z0 + dz)
			var found := false
			for y in range(hi.y + 1, hi.y + cap + 1):
				p.y = y
				if _v.has(p):
					found = true
					break
			if found:
				_v[p] = m


## Rounds a flat ceiling, already built by `chamber`, into a shallow barrel
## vault across the room's own width (X): the crown lifts `rise` voxels above
## the flat ceiling on the corridor's centre line and eases back down to it at
## each wall, on a quarter circle, so the vault reads as an arc rather than a
## tent. Carves into the ceiling slab only - it needs a `cap` thicker than an
## ordinary chamber's, so there is still roof standing once the crown is
## carved out of it, and it touches nothing below the flat ceiling height, so
## the walls it springs from are exactly the ones `chamber` already built.
func vault_ceiling(air_lo: Vector3i, air_hi: Vector3i, rise: int) -> void:
	var lo_x := mini(air_lo.x, air_hi.x)
	var hi_x := maxi(air_lo.x, air_hi.x)
	var lo_z := mini(air_lo.z, air_hi.z)
	var hi_z := maxi(air_lo.z, air_hi.z)
	var top := maxi(air_lo.y, air_hi.y)
	var half := float(hi_x - lo_x) * 0.5
	var cx := float(lo_x + hi_x) * 0.5
	if half <= 0.0 or rise <= 0:
		return
	for x in range(lo_x, hi_x + 1):
		var t: float = clampf((float(x) - cx) / half, -1.0, 1.0)
		var h := int(round(sqrt(maxf(0.0, 1.0 - t * t)) * float(rise)))
		if h <= 0:
			continue
		carve(Vector3i(x, top + 1, lo_z), Vector3i(x, top + h, hi_z))


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
