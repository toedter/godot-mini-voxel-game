class_name Carryable
extends Interactable

## Something the player can pick up, carry around and put down again.
##
## Carrying is the second of the two verbs the design allows itself, and like
## the first it is driven by point-and-press so that it costs nothing to
## support both modes: the object reparents onto whatever is holding it, which
## is the camera on the desktop and the controller in XR, and rides along.
##
## This is deliberately not a physics grab. A puzzle piece that can be fumbled,
## dropped down a slope or wedged in the terrain is a puzzle piece that can
## make a room unsolvable, and there is no inventory to recover it from.

## What a pedestal checks against when deciding whether it will accept this.
@export var item_id: StringName = &"item"
## Verb shown when it is on the ground, and when it is in hand.
@export var take_prompt: String = "Take"
@export var drop_prompt: String = "Put down"

signal picked_up(actor: Node3D)
signal put_down(at: Vector3)

var _holder: Interactor
## Where it goes back to if the player drops it in mid air.
var _rest_position: Vector3
var _world: VoxelWorld


func _ready() -> void:
	super()
	prompt = take_prompt
	_rest_position = global_position
	_world = get_tree().get_first_node_in_group("voxel_world") as VoxelWorld


func is_held() -> bool:
	return _holder != null


func holder() -> Interactor:
	return _holder


func _on_use(actor: Node3D) -> void:
	var aim := actor as Interactor
	if aim == null:
		return
	if _holder == null:
		_pick_up(aim)
	else:
		drop()


func _pick_up(aim: Interactor) -> void:
	# Anything already in that hand goes down first, so the player cannot end
	# up holding two things with only one carry pose to put them in.
	var busy := aim.carried()
	if busy != null and busy is Carryable:
		(busy as Carryable).drop()
	_holder = aim
	_rest_position = global_position
	# Held objects are out of the physics world entirely: they must not shove
	# the player around, and the ray must not keep finding them.
	collision_layer = 0
	reparent(aim, true)
	prompt = drop_prompt
	refresh_prompt()
	aim.take(self)
	picked_up.emit(aim)


## Puts the object down wherever it is, on the ground under it.
func drop() -> void:
	if _holder == null:
		return
	var aim := _holder
	_holder = null
	aim.release()
	var world_pos := global_position
	reparent(_scene_root(), true)
	global_position = _grounded(world_pos)
	collision_layer = LAYER_WORLD | LAYER_INTERACTABLE
	prompt = take_prompt
	refresh_prompt()
	put_down.emit(global_position)


## Hands the object to a holder that is not the player: a pedestal slot. The
## slot owns the transform from then on.
func stow(slot: Node3D) -> void:
	if _holder != null:
		var aim := _holder
		_holder = null
		aim.release()
	collision_layer = 0
	reparent(slot, true)


## Takes it back out of a slot and puts it on the ground.
func unstow() -> void:
	var world_pos := global_position
	reparent(_scene_root(), true)
	global_position = _grounded(world_pos)
	collision_layer = LAYER_WORLD | LAYER_INTERACTABLE
	prompt = take_prompt
	refresh_prompt()


## The node carryables live under when nobody holds them. The world node is a
## poor choice: it churns its own children as chunks stream.
func _scene_root() -> Node:
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root


## Drops a position onto the terrain. The heightmap is a pure function, so this
## works whether or not the chunk under it happens to be streamed in.
func _grounded(pos: Vector3) -> Vector3:
	if _world == null or _world.gen == null:
		return pos
	# Dropped objects settle on the terrain rather than hanging where the hand
	# released them, so nothing is ever left floating or buried.
	return Vector3(pos.x, _world.gen.collision_y(pos.x, pos.z), pos.z)


func _physics_process(delta: float) -> void:
	if _holder == null:
		return
	# Eased rather than snapped, so a held object trails the head slightly and
	# reads as a thing being carried instead of a decal on the camera.
	var k: float = clampf(_holder.carry_lerp * delta, 0.0, 1.0)
	position = position.lerp(_holder.carry_offset, k)
	quaternion = quaternion.slerp(Quaternion.IDENTITY, k)
