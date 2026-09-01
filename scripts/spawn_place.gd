class_name SpawnPlace
extends Node

## Spike scaffolding: puts its parent down somewhere the terrain decides.
##
## The island is generated, so nothing can be positioned in the editor: a
## coordinate typed in by hand lands wherever the noise happens to put it,
## which is as likely to be a cliff face or the sea bed as a spot worth
## standing on. Both anchors below are searches, and both are pure functions of
## the seed, so every run agrees on the answer. Real levels will have authored
## positions and will not need this.

enum Anchor {
	## Straight off the player's spawn point.
	SPAWN,
	## The nearest patch of desert that lies below the spawn.
	DESERT_DOWNHILL,
}

## The site to measure `offset` from.
@export var anchor: Anchor = Anchor.SPAWN
## Where the prop goes relative to that site, in metres.
@export var offset: Vector3 = Vector3.ZERO
## Drop it onto the terrain rather than trusting the offset's Y.
@export var snap_to_ground: bool = true

## Search parameters for DESERT_DOWNHILL. Constants rather than exports on
## purpose: every prop using this anchor has to arrive at the same site, and a
## per-node setting is a silent way to scatter them across the island.
##
## The drop is what makes it read as downhill without being a hike, and the
## clearance above the datum keeps the site dry at the default tide while
## leaving high water able to reach it.
const DESERT_MIN_DROP := 5.0
const DESERT_MIN_ABOVE_DATUM := 2.5
## Ring spacing and how far out to look before giving up, in metres.
const SEARCH_STEP := 6.0
const SEARCH_RINGS := 60
const SEARCH_SPOKES := 48
## How much the ground may vary over the prop's footprint.
const SITE_FLATNESS := 1.2


func _ready() -> void:
	var parent := get_parent() as Node3D
	var world := get_tree().get_first_node_in_group("voxel_world") as VoxelWorld
	if parent == null or world == null or world.gen == null:
		return
	var base := world.spawn_xz
	if anchor == Anchor.DESERT_DOWNHILL:
		base = desert_downhill(world.gen, world.spawn_xz)
	var spot := base + Vector2(offset.x, offset.z)
	var y := offset.y
	if snap_to_ground:
		y += world.gen.collision_y(spot.x, spot.y)
	parent.global_position = Vector3(spot.x, y, spot.y)


## The nearest desert ground that sits a good way below `from` and is flat
## enough to stand a prop on. Falls back to `from` if the island has no such
## spot within reach, so a prop is never lost.
static func desert_downhill(gen: TerrainGen, from: Vector2) -> Vector2:
	var start := gen.height_meters(from.x, from.y)
	for ring in range(3, SEARCH_RINGS):
		var r := float(ring) * SEARCH_STEP
		for i in SEARCH_SPOKES:
			var a := TAU * float(i) / float(SEARCH_SPOKES)
			var c := from + Vector2(cos(a) * r, sin(a) * r)
			var h := gen.height_meters(c.x, c.y)
			if h > start - DESERT_MIN_DROP:
				continue
			if h < VoxelDefs.SEA_DATUM + DESERT_MIN_ABOVE_DATUM:
				continue
			if not gen.is_desert(c.x, c.y):
				continue
			if not _flat_enough(gen, c):
				continue
			return c
	return from


static func _flat_enough(gen: TerrainGen, c: Vector2) -> bool:
	var lo := INF
	var hi := -INF
	for dz in [-3.0, 0.0, 3.0]:
		for dx in [-3.0, 0.0, 3.0]:
			var h := gen.height_meters(c.x + dx, c.y + dz)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return hi - lo <= SITE_FLATNESS
