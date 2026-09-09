extends CanvasLayer

## Loading screen shown while the initial disc of chunks around the spawn
## point is generated. Pauses the scene tree so the player cannot move or fall
## through half-built ground, then unpauses and tears itself down once
## VoxelWorld reports the world is ready.
##
## Runs at PROCESS_MODE_ALWAYS (set on the node in main.tscn) so it keeps
## ticking while everything else is paused; VoxelWorld is set the same way so
## it can keep pumping its worker threads and integrating finished chunks.

@export var world_path: NodePath = ^"../VoxelWorld"

@onready var _bar: ProgressBar = $Panel/ProgressBar
@onready var _label: Label = $Panel/Label

var _world: VoxelWorld


func _ready() -> void:
	get_tree().paused = true
	_world = get_node_or_null(world_path) as VoxelWorld
	if _world == null:
		_finish()
		return
	_world.generation_progress.connect(_on_progress)
	_world.world_ready.connect(_on_world_ready)
	# The world may have raced ahead and already finished its first disc
	# before we got here (e.g. a tiny view distance); catch up instead of
	# waiting forever for signals that already fired.
	if _world.is_world_ready():
		_on_world_ready()
		return
	_on_progress(0, _world.generation_total())


func _on_progress(done: int, total: int) -> void:
	if total <= 0:
		_bar.max_value = 1
		_bar.value = 0
		return
	_bar.max_value = total
	_bar.value = done


func _on_world_ready() -> void:
	_finish()


func _finish() -> void:
	get_tree().paused = false
	queue_free()
