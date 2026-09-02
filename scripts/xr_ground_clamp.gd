extends Node3D

## Holds the XR body on the ground. Two jobs.
##
## The first is the safety net Player._clamp_to_terrain() is for the desktop
## rig: chunks stream in on worker threads, so the player can stand where no
## collision shape exists yet, and the heightmap is always available to fall
## back on.
##
## The second is standing still. GXDKRaycastBody carries the body's height with
## a PID controller while the locomotion handler adds a full step of gravity
## every frame, so the two settle into a spring rather than a rest: the body
## sinks until the proportional term balances gravity, the integral term winds
## up and lifts it back out, and round it goes. In a headset that is nausea. But
## on terrain there is nothing for a controller to solve - the ground height is
## known exactly - so the body is pinned to it and the vertical velocity the
## spring built up is dropped. Standing still is then perfectly still, and
## walking follows the same ramp the collision shape has.
##
## Anything more than `pin_band` above the terrain - a boulder, a branch, a drop
## off a ledge - is left to the normal physics.

@export var world_path: NodePath = ^"../../VoxelWorld"
## How far above the terrain the body may be and still count as resting on it.
## Half a voxel: enough to swallow the PID's overshoot, too little to reach the
## top of anything the player could be standing on instead.
@export var pin_band := 0.05

var _body: CharacterBody3D
var _world: VoxelWorld


func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	_world = get_node_or_null(world_path) as VoxelWorld
	# The locomotion handler runs at -92 and calls move_and_slide, so the
	# default priority puts this correction right after it.
	process_physics_priority = 0


func _physics_process(_delta: float) -> void:
	if _body == null or _world == null or _world.gen == null:
		return
	# Interiors sit below the terrain, so the pin would drag the player up
	# through the floor and out onto the island.
	if _world.indoors:
		return
	# A body on its way up has just been pushed, so it is not resting on
	# anything. Without this the pin catches a jump on its first frame - at
	# 90 Hz a 5 m/s launch clears barely more than `pin_band` in one step -
	# and cancels it before it leaves the ground.
	if _body.velocity.y > 0.0:
		return
	var p := _body.global_position
	# The height the collision shape really has. The voxel lip from ground_y()
	# stands up to half a voxel above it on a slope, and correcting to that
	# every frame is itself a bump.
	var g: float = _world.surface_y(p.x, p.z)
	if p.y > g + pin_band:
		return # in the air, or standing on something that is not the ground
	_body.global_position.y = g
	_body.velocity.y = 0.0
