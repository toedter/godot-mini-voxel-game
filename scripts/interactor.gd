class_name Interactor
extends Node3D

## The player's end of an interaction: casts a short ray along -Z, keeps track
## of whatever Interactable it lands on, and uses it when the button goes down.
##
## One script serves both modes because both amount to "a thing in the world
## that points somewhere". On the desktop it hangs off the camera, so it points
## where the player looks; in XR it hangs off a controller, so it points where
## the hand points. Nothing else differs, which is the whole reason the
## interaction verb was picked this way.

## How far (m) the player can reach. Short on purpose: a lock you can throw
## from across the bay is not a puzzle. Measured from the eye (or the hand),
## so it has to cover a step's worth of slack when the target sits downhill.
@export var reach: float = 4.0
## Input action used on the desktop.
@export var action: StringName = &"interact"
## OpenXR action used when this hangs off a controller. Read as both a button
## and an analogue pull, since a trigger may be bound either way.
@export var xr_action: StringName = &"trigger"
## How far the analogue trigger has to be pulled to count as a press.
@export_range(0.1, 1.0, 0.05) var xr_threshold: float = 0.6

## Fires when the ray moves onto a different Interactable (or onto nothing).
signal focus_changed(target: Interactable)

var _focus: Interactable
var _controller: XRController3D
var _xr_was_down := false
## Bodies the ray must ignore: the player's own collider.
var _exclude: Array[RID] = []


func _ready() -> void:
	add_to_group("interactor")
	_controller = get_parent() as XRController3D
	var body := _find_body()
	if body != null:
		_exclude = [body.get_rid()]


## The player's collider, so the ray does not start inside it and stop dead.
func _find_body() -> CollisionObject3D:
	var n := get_parent()
	while n != null:
		if n is CollisionObject3D:
			return n as CollisionObject3D
		n = n.get_parent()
	return null


## What the player is currently pointing at, or null.
func focus() -> Interactable:
	return _focus


## The line the flat HUD shows, empty when nothing is in reach.
func focus_prompt() -> String:
	return "" if _focus == null else _focus.prompt


func _physics_process(_delta: float) -> void:
	_update_focus()
	if _focus != null and _pressed():
		_focus.use(self)


func _update_focus() -> void:
	var space := get_world_3d().direct_space_state
	var from := global_position
	var q := PhysicsRayQueryParameters3D.create(from,
		from - global_transform.basis.z * reach,
		Interactable.LAYER_WORLD | Interactable.LAYER_INTERACTABLE, _exclude)
	var hit := space.intersect_ray(q)
	# Terrain is on the world layer too, so a hill between the eye and a lock
	# comes back as the hit and the lock is correctly not focused.
	var found: Interactable = null
	if not hit.is_empty():
		found = hit["collider"] as Interactable
	if found == _focus:
		return
	if _focus != null:
		_focus.set_focused(false)
	_focus = found
	if _focus != null:
		_focus.set_focused(true)
	focus_changed.emit(_focus)


## True on the frame the use button goes down, in whichever mode is running.
func _pressed() -> bool:
	if _controller != null:
		var down := _controller.is_button_pressed(xr_action) \
			or _controller.get_float(xr_action) >= xr_threshold
		var edge := down and not _xr_was_down
		_xr_was_down = down
		return edge
	# Left click is also what recaptures the cursor, and a free cursor means the
	# player is in a menu or has stepped away; neither should reach into the
	# world. XR has no equivalent state, hence the flat-only guard.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return false
	return InputMap.has_action(action) and Input.is_action_just_pressed(action)


func _exit_tree() -> void:
	if _focus != null:
		_focus.set_focused(false)
		_focus = null
