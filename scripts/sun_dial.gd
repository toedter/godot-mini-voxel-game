class_name SunDial
extends Interactable

## A dial the player turns to move the sun and moon.
##
## This is the day/night cycle's game verb, the same way TideLock is the
## tide's: the debug keys scrub time in half-hour steps because that is useful
## while building, but a dial instead steps between a few named times of day,
## because a lever a puzzle can be built against needs a short, predictable
## list of states rather than a slider.

## The times of day this dial cycles through, as DayNight.time_of_day
## fractions (0 midnight, 0.25 dawn, 0.5 noon, 0.75 dusk). Ordered so that
## repeated turns follow the sun across an actual day.
@export var notches: PackedFloat32Array = PackedFloat32Array([0.25, 0.5, 0.75, 0.0])
@export var notch_names: PackedStringArray = PackedStringArray(["dawn", "noon", "dusk", "midnight"])
@export var day_path: NodePath = ^"../Sun"

var _day: DayNight
var _index := 0
var _dial: Node3D
var _sun: MeshInstance3D
var _moon: MeshInstance3D
var _angle := 0.0

const RADIUS := 0.26


func _ready() -> void:
	super()
	_day = get_node_or_null(day_path) as DayNight
	_build_body()
	# Start facing wherever the sun already is, so the first turn moves
	# somewhere the player has not just been.
	if _day != null:
		_index = _nearest_notch(_day.time_of_day)
		_orient_dial(false)
	_update_prompt()


## A stone plinth with an armillary needle on top: sun and moon spheres ride
## opposite ends of a rotating bar, tracing the same vertical arc the light
## itself follows, so the player can see where a notch will land before
## committing to it.
func _build_body() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = VoxelDefs.COLORS[VoxelDefs.STONE]
	stone.roughness = 0.95
	var brass := StandardMaterial3D.new()
	brass.albedo_color = Color(0.72, 0.58, 0.28)
	brass.roughness = 0.4
	var sun_mat := StandardMaterial3D.new()
	sun_mat.albedo_color = Color(1.0, 0.85, 0.35)
	sun_mat.emission_enabled = true
	sun_mat.emission = Color(1.0, 0.75, 0.25)
	sun_mat.emission_energy_multiplier = 1.4
	var moon_mat := StandardMaterial3D.new()
	moon_mat.albedo_color = Color(0.75, 0.8, 0.95)
	moon_mat.emission_enabled = true
	moon_mat.emission = Color(0.55, 0.68, 1.0)
	moon_mat.emission_energy_multiplier = 0.6

	var plinth := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.6, 1.0, 0.6)
	plinth.mesh = pm
	plinth.material_override = stone
	plinth.position = Vector3(0.0, 0.5, 0.0)
	add_child(plinth)

	_dial = Node3D.new()
	_dial.position = Vector3(0.0, 1.05, 0.0)
	add_child(_dial)

	var needle := MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(0.05, RADIUS * 2.0, 0.05)
	needle.mesh = nm
	needle.material_override = brass
	_dial.add_child(needle)

	_sun = MeshInstance3D.new()
	var ss := SphereMesh.new()
	ss.radius = 0.09
	ss.height = 0.18
	_sun.mesh = ss
	_sun.material_override = sun_mat
	_sun.position = Vector3(0.0, RADIUS, 0.0)
	_dial.add_child(_sun)

	_moon = MeshInstance3D.new()
	var ms := SphereMesh.new()
	ms.radius = 0.07
	ms.height = 0.14
	_moon.mesh = ms
	_moon.material_override = moon_mat
	_moon.position = Vector3(0.0, -RADIUS, 0.0)
	_dial.add_child(_moon)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.7, 1.15, 0.7)
	shape.shape = box
	shape.position = Vector3(0.0, 0.575, 0.0)
	add_child(shape)


func _on_use(_actor: Node3D) -> void:
	if _day == null or notches.is_empty():
		return
	_index = (_index + 1) % notches.size()
	_day.set_time_of_day(notches[_index])
	_orient_dial(true)
	_update_prompt()


## Rotates the needle so the sun sphere sits where the notch puts it in the
## sky (up at noon, down at midnight, level with the plinth at dawn/dusk).
## Always spins forward rather than snapping back, the same feedback the tide
## lock's wheel gives: something visibly happened before the light catches up.
func _orient_dial(animate: bool) -> void:
	if _dial == null:
		return
	var target := fposmod(TAU * (notches[_index] - 0.5), TAU)
	if animate:
		var delta := target - fposmod(_angle, TAU)
		if delta <= 0.0:
			delta += TAU
		_angle += delta
		var t := create_tween()
		t.tween_property(_dial, "rotation:x", _angle, 0.5).set_trans(Tween.TRANS_CUBIC)
	else:
		_angle = target
		_dial.rotation.x = _angle


func _nearest_notch(t: float) -> int:
	var best := 0
	for i in notches.size():
		if absf(notches[i] - t) < absf(notches[best] - t):
			best = i
	return best


func _name_of(i: int) -> String:
	return notch_names[i] if i < notch_names.size() else "%.2f" % notches[i]


func _update_prompt() -> void:
	var next := (_index + 1) % notches.size()
	prompt = "Turn the dial to %s" % _name_of(next)
	refresh_prompt()
