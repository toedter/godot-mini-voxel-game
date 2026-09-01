extends Node3D

## The debug jump to the ruins, on a controller button.
##
## The tide keys and the T key are how this is reached at a desk; in a headset
## there is no keyboard, and the drowned ruin is a few hundred metres from
## spawn. Same scaffolding, same lifetime: it goes when the island has real
## landmarks to walk between.

## Boolean OpenXR action. Bound to X on the left Touch controller.
@export var action: StringName = &"go_to_ruins"

var _controller: XRController3D


func _ready() -> void:
	_controller = get_parent() as XRController3D
	if _controller != null:
		_controller.button_pressed.connect(_on_button)


func _on_button(name: StringName) -> void:
	if name != action:
		return
	var world := get_tree().get_first_node_in_group("voxel_world") as VoxelWorld
	if world != null:
		world.teleport_to_structures()
