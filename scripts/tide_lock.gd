class_name TideLock
extends Interactable

## A lock the player turns to move the sea.
##
## This is the tide's game verb. The debug keys move the water by a metre at a
## time because that is useful while building; a lock instead steps between a
## few authored notches, because the design wants a handful of distinct islands
## that puzzles can be laid out against, not a slider.

## The notches this lock cycles through, in metres relative to the terrain
## datum. Ebb exposes the shallows, mean is the island as generated, flood
## floats the player up to the ledges.
@export var notches: PackedFloat32Array = PackedFloat32Array([-5.0, 0.0, 6.0])
@export var notch_names: PackedStringArray = PackedStringArray(["low water", "mean water", "high water"])
@export var world_path: NodePath = ^"../VoxelWorld"
## A seized lock will not turn until something releases it. This is what makes
## the lock the end of a puzzle rather than a button: the pedestal nearby has
## to be filled first.
@export var locked: bool = false
@export var locked_prompt: String = "The lock is seized"
## A pedestal that has to be filled before this lock will turn. Emptying it
## seizes the lock again, so the glow-cap stays the key rather than becoming a
## switch that is thrown once and forgotten.
@export var unlocked_by: NodePath

var _world: VoxelWorld
var _index := 1
var _wheel: Node3D


func _ready() -> void:
	super()
	_world = get_node_or_null(world_path) as VoxelWorld
	add_to_group("savable")
	_build_body()
	_bind_key()
	# Start on whichever notch the water is already at, so the first turn moves
	# somewhere the player has not just been.
	if _world != null:
		_index = _nearest_notch(_world.tide_offset())
	_update_prompt()


## A stone plinth with a wheel on top. Built in code rather than authored as a
## scene because the whole thing is four boxes and the colours have to come
## from the voxel palette to sit in the world.
func _build_body() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = VoxelDefs.COLORS[VoxelDefs.STONE]
	stone.roughness = 0.95
	var brass := StandardMaterial3D.new()
	brass.albedo_color = VoxelDefs.COLORS[VoxelDefs.SHROOM_GLOW]
	brass.emission_enabled = true
	brass.emission = VoxelDefs.COLORS[VoxelDefs.SHROOM_GLOW]
	brass.emission_energy_multiplier = 0.5
	brass.roughness = 0.5

	var plinth := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.6, 1.0, 0.6)
	plinth.mesh = pm
	plinth.material_override = stone
	plinth.position = Vector3(0.0, 0.5, 0.0)
	add_child(plinth)

	# The wheel turns a notch every time the lock is used, so the player can
	# see that something happened even before the water starts moving.
	_wheel = Node3D.new()
	_wheel.position = Vector3(0.0, 1.05, 0.0)
	add_child(_wheel)
	for i in 4:
		var spoke := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.44, 0.06, 0.06)
		spoke.mesh = sm
		spoke.material_override = brass
		spoke.rotation.y = TAU * float(i) / 8.0
		_wheel.add_child(spoke)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.7, 1.15, 0.7)
	shape.shape = box
	shape.position = Vector3(0.0, 0.575, 0.0)
	add_child(shape)


## Watches the pedestal that holds this lock's key, if there is one.
func _bind_key() -> void:
	var key := get_node_or_null(unlocked_by) as Pedestal
	if key == null:
		return
	key.filled.connect(_on_key_placed)
	key.emptied.connect(_on_key_removed)
	locked = not key.is_filled()


func _on_key_placed(_item: Carryable) -> void:
	unlock()


func _on_key_removed(_item: Carryable) -> void:
	locked = true
	_update_prompt()


## Releases the lock, so it can be turned. Wired to a pedestal being filled.
func unlock() -> void:
	if not locked:
		return
	locked = false
	_update_prompt()


func _nearest_notch(offset: float) -> int:
	var best := 0
	for i in notches.size():
		if absf(notches[i] - offset) < absf(notches[best] - offset):
			best = i
	return best


func _name_of(i: int) -> String:
	return notch_names[i] if i < notch_names.size() else "%+.0f m" % notches[i]


func _update_prompt() -> void:
	if locked:
		prompt = locked_prompt
		refresh_prompt()
		return
	var next := (_index + 1) % notches.size()
	prompt = "Turn the lock to %s" % _name_of(next)
	refresh_prompt()


func _on_use(_actor: Node3D) -> void:
	if locked or _world == null or notches.is_empty():
		return
	_index = (_index + 1) % notches.size()
	_world.set_tide(VoxelDefs.SEA_DATUM + notches[_index])
	if _wheel != null:
		var t := create_tween()
		t.tween_property(_wheel, "rotation:y",
			_wheel.rotation.y + TAU / 8.0, 0.45).set_trans(Tween.TRANS_CUBIC)
	_update_prompt()


func save_state() -> Dictionary:
	return {"notch": _index, "locked": locked}


func load_state(d: Dictionary) -> void:
	_index = clampi(int(d.get("notch", 0)), 0, maxi(notches.size() - 1, 0))
	locked = bool(d.get("locked", false))
	_update_prompt()


## After the pedestal, whose filling would otherwise unlock this again on the
## way past and overwrite what was saved.
func save_priority() -> int:
	return 15
