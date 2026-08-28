extends CanvasLayer

## Minimal debug HUD: position, biome, chunk count and FPS.

@export var world_path: NodePath = ^"../VoxelWorld"
@export var player_path: NodePath = ^"../Player"

@onready var _label: Label = $Info

var _world: VoxelWorld
var _player: Node3D


func _ready() -> void:
	_world = get_node_or_null(world_path) as VoxelWorld
	_player = get_node_or_null(player_path) as Node3D


func _process(_delta: float) -> void:
	if _world == null or _player == null:
		return
	var p := _player.global_position
	var hint := "WASD move   Shift sprint   Space jump   Mouse look   Esc release cursor"
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		hint = "Click into the window to capture the mouse and look around"
	_label.text = "%d FPS   |   %s   |   XYZ %.1f / %.1f / %.1f   |   chunks %d\n%s" % [
		Engine.get_frames_per_second(),
		_world.biome_name_at(p),
		p.x, p.y, p.z,
		_world.loaded_chunks(),
		hint,
	]
