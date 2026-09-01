extends Node3D

## Jump, on a controller button.
##
## Hangs off an XRController3D and pushes the body up when the bound action
## fires. GXDKLocomotionHandler damps horizontal velocity every frame but
## leaves the vertical component alone before adding gravity, so setting it
## here is enough; nothing has to run at a particular priority.

## Boolean OpenXR action. Bound to A on the right Touch controller.
@export var action: StringName = &"jump"
## Matches the desktop player's jump, so the same ledge is reachable in both.
@export var jump_velocity: float = 5.0
## Ignore a second press while still rising, so holding the button through a
## landing does not turn into a hop the player did not ask for.
@export var require_floor: bool = true

var _controller: XRController3D
var _body: CharacterBody3D
var _locomotion: Node


func _ready() -> void:
	_controller = get_parent() as XRController3D
	if _controller != null:
		_controller.button_pressed.connect(_on_button)
	var n := get_parent()
	while n != null:
		if n is CharacterBody3D:
			_body = n as CharacterBody3D
			break
		n = n.get_parent()
	# GXDK cannot always trust CharacterBody3D.is_on_floor for the XR body, and
	# offers its own answer; use it when it is there.
	if _body != null:
		_locomotion = _body.get_node_or_null("GXDKLocomotionHandler")


func _on_button(name: StringName) -> void:
	if name != action or _body == null:
		return
	if require_floor and not _grounded():
		return
	_body.velocity.y = jump_velocity


func _grounded() -> bool:
	if _locomotion != null and _locomotion.has_method("is_on_floor"):
		return bool(_locomotion.call("is_on_floor"))
	return _body.is_on_floor()
