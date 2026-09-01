class_name SpawnPlace
extends Node

## Spike scaffolding: puts its parent down relative to wherever the player
## actually spawned.
##
## The spawn point is searched for at runtime (VoxelWorld spirals outwards from
## the origin until it finds dry land), so it is not known when the scene is
## built and props cannot simply be placed in the editor. Real levels will
## have authored positions and will not need this; until there are levels,
## this is what makes a prop reliably findable.

## Where the prop goes, relative to the spawn point, in metres.
@export var offset: Vector3 = Vector3.ZERO
## Drop it onto the terrain rather than trusting the offset's Y.
@export var snap_to_ground: bool = true


func _ready() -> void:
	var parent := get_parent() as Node3D
	var world := get_tree().get_first_node_in_group("voxel_world") as VoxelWorld
	if parent == null or world == null or world.gen == null:
		return
	var spot := world.spawn_xz + Vector2(offset.x, offset.z)
	var y := offset.y
	if snap_to_ground:
		y += world.gen.collision_y(spot.x, spot.y)
	parent.global_position = Vector3(spot.x, y, spot.y)
