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
## carried torch and every chunk currently streamed, and charge for all of
## it again on the way out. Instead Main stays exactly as it is and the player
## is moved, with `VoxelWorld.indoors` suspending the outdoor rules that would
## otherwise drag them back to the surface.
##
## The rooms are placed directly under the ruin they belong to, so the streamed
## disc is centred on the same columns whether the player is inside or out and
## nothing is loaded or dropped by going in.
##
## What the vault is made of is VaultPlan's business. This node owns the
## threshold, the props that stand in the rooms, and the one rule that ties
## them together: the way out is sealed until the three braziers are lit.

## How far (m) below the terrain the rooms sit. Far enough that the mountain
## roots never reach them, near enough to stay in the same streamed chunks.
@export var depth: float = 300.0
@export var world_path: NodePath = ^"../VoxelWorld"
## Braziers that have to be burning before the way out will open. Two of them
## also raise the gate into the inner vault, where the third one is - so the
## count is the whole puzzle, and the gate is what makes the order matter.
@export var braziers_for_gate: int = 2

signal entered()
signal left()

var _world: VoxelWorld
var _plan: VaultPlan
var _entry: Vector3
var _outside_door: VaultDoor
var _inside_door: VaultDoor
var _gate: StoneGate
var _braziers: Array[Brazier] = []
var _return_to := Vector3.ZERO
var _return_yaw := 0.0
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


## How many of the vault's braziers are alight. The puzzle, counted.
func lit_count() -> int:
	var n := 0
	for b in _braziers:
		if b.is_burning():
			n += 1
	return n


func _build(arch: Dictionary) -> void:
	var vs := VoxelDefs.VOXEL_SIZE
	var ax := float(arch["x"]) * vs
	var az := float(arch["z"]) * vs

	_plan = VaultPlan.new()
	var rooms := _plan.build()
	# Hung so that where the player arrives is straight down from the archway,
	# rather than where the plan happens to have its origin. The vault is now
	# thirteen metres long - two chunks - so the difference decides whether
	# going inside quietly re-streams the island overhead.
	global_position = Vector3(ax - _plan.entry.x, -depth, az - _plan.entry.z)
	var out: Dictionary = rooms.build()
	var body := StaticBody3D.new()
	body.name = "Shell"
	var mi := MeshInstance3D.new()
	mi.mesh = out["mesh"]
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.96
	mi.material_override = mat
	# Nothing outside can see in, and the rooms are lit by what the player
	# carries and by what they light; a shadow pass over them would be spent on
	# nothing.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	var shape := CollisionShape3D.new()
	shape.shape = out["shape"]
	body.add_child(shape)
	add_child(body)

	_entry = global_position + _plan.entry
	_build_doors(ax, az)
	_build_props()


func _build_doors(ax: float, az: float) -> void:
	# Sealed from the moment it is built. The player is not shut in by this -
	# the torch that opens it is on a plinth a couple of paces away - but the
	# vault has to say, the moment they arrive, that it wants something.
	_inside_door = VaultDoor.new()
	_inside_door.name = "InsideDoor"
	_inside_door.leads_out = true
	_inside_door.sealed = true
	_inside_door.bind(self)
	_inside_door.position = _plan.exit_door
	add_child(_inside_door)

	_outside_door = VaultDoor.new()
	_outside_door.name = "ArchDoor"
	_outside_door.leads_out = false
	_outside_door.bind(self)
	add_child(_outside_door)
	# Standing in the archway, at ground level up on the island.
	_outside_door.global_position = Vector3(ax,
		_world.gen.collision_y(ax, az), az)


## Everything in the rooms that is not masonry. Built in code and named, rather
## than authored in the scene, because none of it can be positioned until the
## island has decided where the ruin above it stands - and because a save is
## keyed by node name, the names have to be spelled out here and be unlike any
## other in the tree.
func _build_props() -> void:
	_gate = StoneGate.new()
	_gate.name = "VaultGate"
	# The plan cut the hole, so the plan is what says how big the slab is.
	_gate.opening = _plan.door_clear()
	_gate.position = _plan.gate
	add_child(_gate)

	for i in _plan.braziers.size():
		var b := Brazier.new()
		b.name = "VaultBrazier%d" % (i + 1)
		b.position = _plan.braziers[i]
		b.lit.connect(_on_brazier_lit)
		add_child(b)
		_braziers.append(b)

	# A torch, left burning on the plinth by whoever sealed the place. It is
	# the puzzle's only tool, and it is inside the puzzle: a player who climbs
	# down with empty hands has to be able to finish.
	var torch := Torch.new()
	torch.name = "VaultTorch"
	# Before it enters the tree: Carryable notes where it was put down as it is
	# readied, and a torch added at the origin would remember the origin.
	torch.position = _plan.torch_rest
	add_child(torch)

	# Fixed light and set dressing. Neither is savable state - a sconce is
	# always burning and a barrel never moves - so both are just built fresh
	# from the plan's anchors every time the vault is.
	for i in _plan.wall_torches.size():
		var anchor: Dictionary = _plan.wall_torches[i]
		var sconce := WallTorch.new()
		sconce.name = "VaultWallTorch%d" % (i + 1)
		sconce.position = anchor["pos"]
		sconce.rotation.y = anchor["yaw"]
		add_child(sconce)

	for i in _plan.clutter.size():
		var item: Dictionary = _plan.clutter[i]
		var prop: Node3D
		if item["kind"] == "barrel":
			prop = Barrel.new()
		else:
			prop = Crate.new()
		prop.name = "VaultClutter%d" % (i + 1)
		prop.position = item["pos"]
		prop.rotation.y = item["yaw"]
		add_child(prop)


## The one rule of the vault. Two braziers raise the gate that stands between
## the gallery and the inner vault; the third, which is behind that gate, lifts
## the seal on the way out.
func _on_brazier_lit(by_hand: bool) -> void:
	var n := lit_count()
	if n >= braziers_for_gate and _gate != null:
		_gate.open(by_hand)
	if n >= _braziers.size() and _inside_door != null:
		_inside_door.unseal()


## Moves the player in. Whatever they are carrying comes with them: a held
## object is parented to the camera or the hand, so it is already part of the
## thing being moved.
func enter(body: Node3D) -> void:
	if not _built or _world == null or body == null:
		return
	_return_to = body.global_position
	_return_yaw = body.global_rotation.y
	_has_return = true
	_world.indoors = true
	body.global_position = _entry
	# Facing the length of the vault rather than whichever way they happened to
	# be looking at the archway. The rooms run away from the door along -Z,
	# which is where a yaw of zero looks.
	body.global_rotation.y = 0.0
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO
	entered.emit()


func leave(body: Node3D) -> void:
	if _world == null or body == null:
		return
	_world.indoors = false
	if _has_return:
		body.global_position = _return_to
		body.global_rotation.y = _return_yaw
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO
	left.emit()


## Only the way back out. The rooms themselves are rebuilt from their plan
## every run, exactly as the island is rebuilt from its seed, and the state of
## the puzzle is saved by the braziers: the gate and the seal are worked out
## again from them as they come back up.
func save_state() -> Dictionary:
	return {
		"return_to": SaveGame.pack(_return_to),
		"return_yaw": _return_yaw,
		"has_return": _has_return,
	}


func load_state(d: Dictionary) -> void:
	_return_to = SaveGame.unpack(d.get("return_to", [0, 0, 0]))
	_return_yaw = float(d.get("return_yaw", 0.0))
	_has_return = bool(d.get("has_return", false))
