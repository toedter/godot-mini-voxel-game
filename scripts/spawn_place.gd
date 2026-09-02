class_name SpawnPlace
extends Node

## Spike scaffolding: puts its parent down beside wherever the player starts.
##
## The island is generated, so nothing can be positioned in the editor: a
## coordinate typed in by hand lands wherever the noise happens to put it,
## which is as likely to be a cliff face or the sea bed as a spot worth
## standing on. The start itself is a search, and a pure function of the seed,
## so every run agrees on the answer. Real levels will have authored positions
## and will not need this.
##
## The offset is read in the start's own frame rather than along the world
## axes: -Z is the way the player is facing, which is the drowned ruin, and +X
## is their right. Otherwise which side of the lock its socket stands on would
## be a property of the seed, and half the seeds would put it in the sea.

## Where the prop goes relative to the player's start, in metres: right of
## them, above the ground, and back from the ruin.
@export var offset: Vector3 = Vector3.ZERO
## Drop it onto the terrain rather than trusting the offset's Y.
@export var snap_to_ground: bool = true


func _ready() -> void:
	var parent := get_parent() as Node3D
	var world := get_tree().get_first_node_in_group("voxel_world") as VoxelWorld
	if parent == null or world == null or world.gen == null:
		return
	var forward := world.spawn_facing
	var right := Vector2(-forward.y, forward.x)
	var spot := world.spawn_xz + right * offset.x - forward * offset.z
	var y := offset.y
	if snap_to_ground:
		y += world.surface_y(spot.x, spot.y)
	parent.global_position = Vector3(spot.x, y, spot.y)
