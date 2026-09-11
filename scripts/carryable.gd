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
## This item's own collision shape, reused while held to keep it out of
## walls. Found lazily rather than in `_ready`, since a subclass (Torch)
## builds its body, and the shape with it, after calling up into this one.
var _hold_shape: CollisionShape3D
var _hold_shape_searched := false


func _ready() -> void:
	super()
	add_to_group("savable")
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
		take_by(aim)
	else:
		drop()


## Puts this into a hand. Public because a restored save has to hand the
## player back what they were carrying without going through a use.
func take_by(aim: Interactor) -> void:
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


## How far (m) below a drop an interior floor is looked for.
const INDOOR_SETTLE := 3.0


## Drops a position onto whatever is under it.
##
## Outdoors that is the heightmap, which is a pure function and so answers
## whether or not the chunk under it happens to be streamed in. Indoors there
## is no heightmap - the rooms hang hundreds of metres below it, and asking it
## would fling a torch set down in the vault up onto the island - so the floor is
## found the only way an authored room can be asked: by looking for it.
func _grounded(pos: Vector3) -> Vector3:
	if _world == null or _world.gen == null:
		return pos
	if _world.indoors:
		return _settled(pos)
	# Dropped objects settle on the terrain rather than hanging where the hand
	# released them, so nothing is ever left floating or buried.
	return Vector3(pos.x, _world.gen.collision_y(pos.x, pos.z), pos.z)


## The first solid surface under a point, within arm's reach below it. Nothing
## there - dropped over a stairwell, or through a gap - leaves the object where
## it was let go of, which is better than dropping it out of the world.
func _settled(pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return pos
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.1,
		pos + Vector3.DOWN * INDOOR_SETTLE, LAYER_WORLD)
	var hit := space.intersect_ray(q)
	return pos if hit.is_empty() else (hit["position"] as Vector3)


func _physics_process(delta: float) -> void:
	if _holder == null:
		return
	# Eased rather than snapped, so a held object trails the head slightly and
	# reads as a thing being carried instead of a decal on the camera.
	var k: float = clampf(_holder.carry_lerp * delta, 0.0, 1.0)
	var next_pos := position.lerp(_holder.carry_offset, k)
	var next_rot := quaternion.slerp(_holder.carry_rotation(), k)
	position = _clear_of_walls(next_pos, next_rot)
	quaternion = next_rot


## This item's own collision shape (the one built around its body), or null
## if it has none. A held item is taken off the world layer entirely so it
## cannot shove the player or steal the aim ray, which also means physics
## never stops it sliding into a wall on its own; this is what `_clear_of_
## walls` tests against instead.
func _hold_collision_shape() -> CollisionShape3D:
	if _hold_shape_searched:
		return _hold_shape
	_hold_shape_searched = true
	for child in get_children():
		if child is CollisionShape3D:
			_hold_shape = child as CollisionShape3D
			break
	return _hold_shape


## Whether this item's own shape, held at the given local pose, would poke
## into the world (walls, terrain, the vault shell). Layer only, not the
## item's own `collision_layer` - that is zeroed out while held, on purpose,
## so this is the one thing still checking.
func _overlaps_world(local_pos: Vector3, local_rot: Quaternion) -> bool:
	var shape_node := _hold_collision_shape()
	if shape_node == null or shape_node.shape == null or _holder == null:
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var pose := Transform3D(Basis(local_rot), local_pos) * shape_node.transform
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape_node.shape
	query.transform = _holder.global_transform * pose
	query.collision_mask = LAYER_WORLD
	query.margin = 0.02
	# The player's own body sits on the world layer too (default physics
	# layer 1), and the carry pose rides right up against it - without this,
	# every held item would read as permanently wedged into its own holder.
	var holder_body := _holder.body()
	if holder_body != null:
		query.exclude = [holder_body.get_rid()]
	return not space.intersect_shape(query, 1).is_empty()


## Pulls a carry position back toward the hand until it stops poking into a
## wall, rather than letting a held object clip straight through one. The
## hand's own origin is trusted as clear - the player cannot stand close
## enough to a wall to embed their own head in it - so the search is a
## straight line from there out to the pose the carry lerp actually wants.
func _clear_of_walls(local_pos: Vector3, local_rot: Quaternion) -> Vector3:
	if not _overlaps_world(local_pos, local_rot):
		return local_pos
	var lo := 0.0
	var hi := 1.0
	for _i in 8:
		var mid := (lo + hi) * 0.5
		if _overlaps_world(local_pos * mid, local_rot):
			hi = mid
		else:
			lo = mid
	return local_pos * lo


# --------------------------------------------------------------------------
# saving
# --------------------------------------------------------------------------

## The pedestal this is seated in, if any. Found by walking up rather than by
## being told, so the socket stays the only thing that knows it seated this.
func _pedestal_host() -> Pedestal:
	var n := get_parent()
	while n != null:
		if n is Pedestal:
			return n as Pedestal
		n = n.get_parent()
	return null


func save_state() -> Dictionary:
	var host := _pedestal_host()
	var where := "ground"
	if _holder != null:
		where = "held"
	elif host != null:
		where = "stowed"
	return {
		"where": where,
		"pos": SaveGame.pack(global_position),
		"host": "" if host == null else String(host.name),
	}


func load_state(d: Dictionary) -> void:
	# Off whatever it is on now, so restoring into a different place cannot
	# leave it seated in two.
	if _holder != null:
		drop()
	var host := _pedestal_host()
	if host != null:
		host.clear()

	match String(d.get("where", "ground")):
		"held":
			var aim := _first_interactor()
			if aim != null:
				take_by(aim)
				return
		"stowed":
			var seat := _pedestal_named(String(d.get("host", "")))
			if seat != null:
				seat.place(self)
				return
	global_position = SaveGame.unpack(d.get("pos", [0, 0, 0]))
	prompt = take_prompt
	refresh_prompt()


## Sockets are found by name through their group, for the same reason state is
## keyed by name: a path is only good until something is reparented.
func _pedestal_named(n: String) -> Pedestal:
	for p in get_tree().get_nodes_in_group("pedestal"):
		if String((p as Node).name) == n:
			return p as Pedestal
	return null


func _first_interactor() -> Interactor:
	for n in get_tree().get_nodes_in_group("interactor"):
		var it := n as Interactor
		if it != null and it.can_process():
			return it
	return null


## After the world, before the lock: seating an item in a pedestal unlocks it,
## and the lock's own saved state has to be the last word on that.
func save_priority() -> int:
	return 10
