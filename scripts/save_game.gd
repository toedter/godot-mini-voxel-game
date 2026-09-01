class_name SaveGame
extends Node

## Saving and loading.
##
## The island is a pure function of its seed, so none of it is written down: no
## chunks, no heightmap, no structures, not one voxel. What a save holds is the
## handful of things the player changed - where they are, what the tide is
## doing, what is sitting in which socket - which is why it is a few hundred
## bytes of JSON rather than a world file.
##
## Anything with state to keep joins the "savable" group and answers
## `save_state()` and `load_state()`. State is keyed by node *name*, not by
## path: a carryable is reparented onto whatever holds it, so its path is
## "Main/GlowCap" on the ground and "Main/Pedestal/.../GlowCap" once seated,
## and a save keyed by path would never find it again. Savable nodes therefore
## need names unique among themselves. It may also answer `save_priority()`:
## restores run in ascending order, because some state only makes sense once
## other state is in place - the player cannot be put back underground until
## the world has been told it is indoors.

const PATH := "user://save_0.json"
## Bumped when the shape of a saved state changes. An older file is refused
## rather than half read.
const VERSION := 1

signal saved()
signal loaded()
signal failed(what: String)


func has_save() -> bool:
	return FileAccess.file_exists(PATH)


func save_game() -> bool:
	var state := {}
	for n in _savables():
		state[String(n.name)] = n.call("save_state")
	var doc := {
		"version": VERSION,
		"seed": _world_seed(),
		"player": _player_state(),
		"nodes": state,
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		failed.emit("could not open %s for writing" % PATH)
		return false
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	saved.emit()
	return true


func load_game() -> bool:
	if not has_save():
		failed.emit("no save file")
		return false
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		failed.emit("could not open %s" % PATH)
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		failed.emit("save file is not readable")
		return false
	var doc: Dictionary = parsed
	if int(doc.get("version", -1)) != VERSION:
		# JSON numbers arrive as floats, so the version is cast before it is
		# shown, or it reads "version 99.0".
		failed.emit("save is version %d, this build reads %d"
			% [int(doc.get("version", -1)), VERSION])
		return false
	# The seed decides the whole island, so a save from another world would
	# restore coordinates that mean nothing here.
	if int(doc.get("seed", 0)) != _world_seed():
		failed.emit("save is from a different world seed")
		return false

	var nodes: Dictionary = doc.get("nodes", {})
	var ordered := _savables()
	ordered.sort_custom(func(a, b): return _priority(a) < _priority(b))
	for n in ordered:
		if nodes.has(String(n.name)):
			n.call("load_state", nodes[String(n.name)])
	_restore_player(doc.get("player", {}))
	loaded.emit()
	return true


func _savables() -> Array[Node]:
	var out: Array[Node] = []
	for n in get_tree().get_nodes_in_group("savable"):
		if n.has_method("save_state") and n.has_method("load_state"):
			out.append(n)
	return out


func _priority(n: Node) -> int:
	return int(n.call("save_priority")) if n.has_method("save_priority") else 0


func _world_seed() -> int:
	var w := get_tree().get_first_node_in_group("voxel_world") as VoxelWorld
	return 0 if w == null else w.world_seed


## The player's body is found through the interactor rather than by path,
## because the flat rig and the XR rig are different nodes and only one of
## them exists at a time.
func _player_body() -> Node3D:
	for n in get_tree().get_nodes_in_group("interactor"):
		var it := n as Interactor
		if it != null and it.can_process() and it.body() != null:
			return it.body()
	return null


func _player_state() -> Dictionary:
	var b := _player_body()
	if b == null:
		return {}
	return {"pos": pack(b.global_position), "yaw": b.global_rotation.y}


func _restore_player(d: Dictionary) -> void:
	var b := _player_body()
	if b == null or d.is_empty():
		return
	b.global_position = unpack(d.get("pos", [0, 0, 0]))
	b.global_rotation.y = float(d.get("yaw", 0.0))
	if b is CharacterBody3D:
		(b as CharacterBody3D).velocity = Vector3.ZERO


## JSON has no vectors, so they travel as three numbers.
static func pack(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func unpack(a) -> Vector3:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() != 3:
		return Vector3.ZERO
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	match (event as InputEventKey).keycode:
		KEY_F5:
			save_game()
		KEY_F9:
			load_game()
