class_name Interior
extends Node3D

## One interior space, and the way in and out of it.
##
## The island's terrain is a heightmap - one surface per column - so it can
## hold nothing underneath it. An interior is therefore not a hole in the
## world; it is a separate little room that stands somewhere the world is not,
## and going inside is a move rather than a load.
##
## It is additive on purpose. Swapping scenes would throw away the tide, the
## carried glow-cap and every chunk currently streamed, and charge for all of
## it again on the way out. Instead Main stays exactly as it is and the player
## is moved, with `VoxelWorld.indoors` suspending the outdoor rules that would
## otherwise drag them back to the surface.
##
## The room is placed directly under the ruin it belongs to, so the streamed
## disc is centred on the same columns whether the player is inside or out and
## nothing is loaded or dropped by going in.

## How far (m) below the terrain the room sits. Far enough that the mountain
## roots never reach it, near enough to stay in the same streamed chunks.
@export var depth: float = 300.0
## Interior dimensions in voxels: 8 m by 6 m, 3 m to the ceiling.
@export var room_size: Vector3i = Vector3i(80, 30, 60)
@export var wall_thickness: int = 4
@export var world_path: NodePath = ^"../VoxelWorld"

signal entered()
signal left()

var _world: VoxelWorld
var _entry: Vector3
var _outside_door: VaultDoor
var _return_to := Vector3.ZERO
var _has_return := false
var _built := false


func _ready() -> void:
	add_to_group("savable")
	_world = get_node_or_null(world_path) as VoxelWorld
	if _world == null or _world.gen == null or _world.gen.structures == null:
		return
	var arch := _world.gen.structures.first_of(StructureSet.ARCH)
	if arch.is_empty():
		return
	_build(arch)
	_built = true


func is_built() -> bool:
	return _built


func entry_point() -> Vector3:
	return _entry


func _build(arch: Dictionary) -> void:
	var vs := VoxelDefs.VOXEL_SIZE
	var ax := float(arch["x"]) * vs
	var az := float(arch["z"]) * vs
	# Straight down from the archway, so the streamed chunks do not change.
	global_position = Vector3(ax, -depth, az)

	var room := VoxelRoom.new()
	var hi := room_size
	room.room(Vector3i.ZERO, hi, wall_thickness, VoxelDefs.SANDSTONE)
	# A doorway through the near wall, and a step up to it from inside.
	var dx := hi.x / 2
	room.carve(Vector3i(dx - 6, wall_thickness, hi.z - wall_thickness - 1),
		Vector3i(dx + 6, wall_thickness + 19, hi.z + 1))
	# A plinth at the far end: somewhere for whatever the vault is guarding.
	room.fill(Vector3i(dx - 5, wall_thickness, 12),
		Vector3i(dx + 5, wall_thickness + 7, 22), VoxelDefs.STONE)
	# Two pillars carrying the ceiling, so the room is not an empty box.
	for px in [dx - 22, dx + 22]:
		room.fill(Vector3i(px - 3, wall_thickness, 26),
			Vector3i(px + 3, hi.y - wall_thickness, 32), VoxelDefs.STONE)

	var out: Dictionary = room.build()
	var body := StaticBody3D.new()
	body.name = "Shell"
	var mi := MeshInstance3D.new()
	mi.mesh = out["mesh"]
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.96
	mi.material_override = mat
	# Nothing outside can see in, and the room is lit by what the player
	# carries; a shadow pass over it would be spent on nothing.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	var shape := CollisionShape3D.new()
	shape.shape = out["shape"]
	body.add_child(shape)
	add_child(body)

	# The player arrives just inside the doorway, facing into the room.
	_entry = global_position + Vector3(float(dx) * vs,
		float(wall_thickness) * vs + 0.05, float(hi.z - wall_thickness - 8) * vs)

	var inside := VaultDoor.new()
	inside.name = "InsideDoor"
	inside.leads_out = true
	inside.bind(self)
	inside.position = Vector3(float(dx) * vs, float(wall_thickness) * vs,
		float(hi.z - wall_thickness) * vs)
	add_child(inside)

	_outside_door = VaultDoor.new()
	_outside_door.name = "ArchDoor"
	_outside_door.leads_out = false
	_outside_door.bind(self)
	add_child(_outside_door)
	# Standing in the archway, at ground level up on the island.
	_outside_door.global_position = Vector3(ax,
		_world.gen.collision_y(ax, az), az)


## Moves the player in. Whatever they are carrying comes with them: a held
## object is parented to the camera or the hand, so it is already part of the
## thing being moved.
func enter(body: Node3D) -> void:
	if not _built or _world == null or body == null:
		return
	_return_to = body.global_position
	_has_return = true
	_world.indoors = true
	body.global_position = _entry
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO
	entered.emit()


func leave(body: Node3D) -> void:
	if _world == null or body == null:
		return
	_world.indoors = false
	if _has_return:
		body.global_position = _return_to
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO
	left.emit()


## Only the way back out. The room itself is rebuilt from its parameters every
## run, exactly as the island is rebuilt from its seed.
func save_state() -> Dictionary:
	return {"return_to": SaveGame.pack(_return_to), "has_return": _has_return}


func load_state(d: Dictionary) -> void:
	_return_to = SaveGame.unpack(d.get("return_to", [0, 0, 0]))
	_has_return = bool(d.get("has_return", false))
