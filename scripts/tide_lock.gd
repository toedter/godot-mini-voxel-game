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
## Placed relative to wherever the player actually spawned, since the spawn
## point is searched for at runtime and is not known when this scene is built.
@export var place_near_player: bool = true
@export var player_path: NodePath = ^"../Player"
## Close enough that the player spawns within the Interactor's reach of it,
## and off to one side so it is not the first thing filling the view.
@export var spawn_offset: Vector3 = Vector3(1.2, 0.0, -2.2)

var _world: VoxelWorld
var _index := 1
var _wheel: Node3D


func _ready() -> void:
	super()
	_world = get_node_or_null(world_path) as VoxelWorld
	_build_body()
	_place()
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


## Drops the lock onto the ground. The heightmap is a pure function, so this
## needs no streamed chunk to be loaded first.
func _place() -> void:
	if place_near_player:
		var p := get_node_or_null(player_path) as Node3D
		if p != null:
			global_position = p.global_position + spawn_offset
	if _world != null and _world.gen != null:
		global_position.y = _world.gen.collision_y(global_position.x, global_position.z)


func _nearest_notch(offset: float) -> int:
	var best := 0
	for i in notches.size():
		if absf(notches[i] - offset) < absf(notches[best] - offset):
			best = i
	return best


func _name_of(i: int) -> String:
	return notch_names[i] if i < notch_names.size() else "%+.0f m" % notches[i]


func _update_prompt() -> void:
	var next := (_index + 1) % notches.size()
	prompt = "Turn the lock to %s" % _name_of(next)
	refresh_prompt()


func _on_use(_actor: Node3D) -> void:
	if _world == null or notches.is_empty():
		return
	_index = (_index + 1) % notches.size()
	_world.set_tide(VoxelDefs.SEA_DATUM + notches[_index])
	if _wheel != null:
		var t := create_tween()
		t.tween_property(_wheel, "rotation:y",
			_wheel.rotation.y + TAU / 8.0, 0.45).set_trans(Tween.TRANS_CUBIC)
	_update_prompt()
