extends Node3D

## Safety net for the XR body: chunks stream in on worker threads, so the
## player can stand where no collision shape exists yet. The heightmap is
## always available, so we can fall back on it and never drop through the
## world. Mirrors what Player._clamp_to_terrain() does for the desktop rig.

@export var world_path: NodePath = ^"../../VoxelWorld"

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
	var p := _body.global_position
	var g: float = _world.gen.ground_y(p.x, p.z)
	if p.y < g:
		_body.global_position.y = g
		if _body.velocity.y < 0.0:
			_body.velocity.y = 0.0
