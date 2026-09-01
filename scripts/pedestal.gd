class_name Pedestal
extends Interactable

## A socket that takes one particular carried object and reports when it is
## filled. The other half of every "fetch the thing, put it where it belongs"
## puzzle, and the piece that turns carrying from a toy into a mechanism.

## Which item_id this will accept. Empty accepts anything carryable.
@export var accepts: StringName = &""
## Wording when the player is empty handed, holding the right thing, and
## holding the wrong thing.
@export var empty_prompt: String = "An empty socket"
@export var place_prompt: String = "Set it in the socket"
@export var wrong_prompt: String = "It does not fit here"
@export var take_back_prompt: String = "Take it back"
## Height (m) above the pedestal's origin the item sits at.
@export var slot_height: float = 1.0

signal filled(item: Carryable)
signal emptied(item: Carryable)

var _slot: Node3D
var _item: Carryable


func _ready() -> void:
	super()
	_build_body()
	_slot = Node3D.new()
	_slot.position = Vector3.UP * slot_height
	add_child(_slot)


func _build_body() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = VoxelDefs.COLORS[VoxelDefs.SANDSTONE]
	stone.roughness = 0.95

	var column := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.34, 0.9, 0.34)
	column.mesh = cm
	column.material_override = stone
	column.position = Vector3(0.0, 0.45, 0.0)
	add_child(column)

	var top := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.52, 0.12, 0.52)
	top.mesh = tm
	top.material_override = stone
	top.position = Vector3(0.0, 0.96, 0.0)
	add_child(top)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.55, 1.02, 0.55)
	shape.shape = box
	shape.position = Vector3(0.0, 0.51, 0.0)
	add_child(shape)


func is_filled() -> bool:
	return _item != null


func item() -> Carryable:
	return _item


## The prompt depends on what the player is holding, so it is recomputed as the
## socket is looked at rather than only when its contents change.
func _on_focus(on: bool) -> void:
	if on:
		_update_prompt(_looking_actor())
		refresh_prompt()


func _looking_actor() -> Interactor:
	for n in get_tree().get_nodes_in_group("interactor"):
		var it := n as Interactor
		if it != null and it.focus() == self:
			return it
	return null


func _update_prompt(aim: Interactor) -> void:
	if _item != null:
		prompt = take_back_prompt
		return
	var held := null if aim == null else aim.carried() as Carryable
	if held == null:
		prompt = empty_prompt
	elif _fits(held):
		prompt = place_prompt
	else:
		prompt = wrong_prompt


func _fits(c: Carryable) -> bool:
	return accepts == &"" or c.item_id == accepts


func _on_use(actor: Node3D) -> void:
	var aim := actor as Interactor
	if _item != null:
		_take_back(aim)
		return
	var held := null if aim == null else aim.carried() as Carryable
	if held == null or not _fits(held):
		_update_prompt(aim)
		return
	_item = held
	held.stow(_slot)
	held.position = Vector3.ZERO
	held.rotation = Vector3.ZERO
	_update_prompt(aim)
	filled.emit(_item)


func _take_back(aim: Interactor) -> void:
	var was := _item
	_item = null
	was.unstow()
	# Straight into the hand if it is free, otherwise onto the ground.
	if aim != null and aim.carried() == null:
		was.use(aim)
	_update_prompt(aim)
	emptied.emit(was)
