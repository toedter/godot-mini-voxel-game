@tool
class_name XRSnapTurn
extends GXDKMovementProvider

## Snap turn that fires the moment the thumbstick is pushed past a threshold.
##
## GXDKDirectMovement integrates the stick over time and only turns once the
## accumulated angle passes the step size, which feels sluggish. Here the first
## frame past the threshold turns straight away; the stick then has to fall
## back to centre before it can fire again, so a held stick gives a steady
## repeat rather than a spin.

#region Export variables
## The action in the OpenXR action map that controls turning
@export var turn_action: String = "move"

## How far the stick must be pushed sideways before a turn triggers
@export_range(0.1, 1.0, 0.05) var deadzone: float = 0.5

## The stick must fall back below this before another turn can trigger
@export_range(0.05, 0.9, 0.05) var release_zone: float = 0.3

## How far we turn per snap
@export_range(5.0, 90.0, 1.0, "radians_as_degrees") var step_angle: float = deg_to_rad(30.0)

## Hold the stick to keep turning at this interval. Zero means one turn per
## push, requiring a release before the next.
@export_range(0.0, 1.0, 0.01, "suffix:s") var repeat_delay: float = 0.25
#endregion

#region Private variables
var _xr_controller: XRController3D

# Sign of the turn we last fired, 0 when the stick is centred and ready again
var _armed_dir: int = 0

# Seconds until a held stick repeats
var _repeat_timer: float = 0.0
#endregion

#region Private functions
func _enter_tree() -> void:
	super._enter_tree()
	_xr_controller = GXDK.get_xr_controller(self)


func _exit_tree() -> void:
	super._exit_tree()
	_xr_controller = null


func _get_input() -> Vector2:
	if _xr_controller:
		return _xr_controller.get_vector2(turn_action)

	# Not parented to a controller, so accept either one.
	var total := Vector2.ZERO
	var trackers := XRServer.get_trackers(XRServer.TRACKER_CONTROLLER)
	for path in trackers:
		var input: Variant = (trackers[path] as XRControllerTracker).get_input(turn_action)
		if input is Vector2:
			total += input as Vector2
	return total


## Called by our locomotion handler.
func _process_locomotion(delta: float) -> void:
	if not enabled or not _character_body:
		return

	var x: float = _get_input().x

	if absf(x) < release_zone:
		# Back at centre: ready for the next push.
		_armed_dir = 0
		_repeat_timer = 0.0
		return

	var dir: int = signi(int(signf(x)))

	if _armed_dir == dir:
		# Still held in the same direction.
		if repeat_delay <= 0.0:
			return
		_repeat_timer -= delta
		if _repeat_timer > 0.0:
			return
	elif absf(x) < deadzone:
		# Between the two zones and not yet triggered: wait for a firm push.
		return

	_armed_dir = dir
	_repeat_timer = repeat_delay
	_turn(-float(dir) * step_angle)


func _turn(angle: float) -> void:
	var basis: Basis = _character_body.global_basis
	_character_body.global_basis = basis.rotated(basis.y, angle)
#endregion
