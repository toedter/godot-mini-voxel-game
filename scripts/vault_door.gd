class_name VaultDoor
extends Interactable

## The threshold between the island and an interior.
##
## Two of these exist per vault: one standing in the ruin outside, one on the
## inside of the room it leads to. They do the same thing in opposite
## directions, so they are the same script with a flag.

@export var interior_path: NodePath
## False on the door standing outside, true on the one inside the room.
@export var leads_out: bool = false
## Drawn as a dark opening rather than a solid slab, so it reads as somewhere
## to walk into.
@export var frame_material: int = VoxelDefs.STONE

var _interior: Interior


func _ready() -> void:
	prompt = "Climb back out" if leads_out else "Go inside"
	super()
	label_height = 1.4
	# A door built in code is bound before it is added to the tree, since
	# get_path_to needs both ends already in it. Only a door placed in a scene
	# has a path to resolve.
	if _interior == null and not interior_path.is_empty():
		_interior = get_node_or_null(interior_path) as Interior
	_build_body()


## Points the door at its interior directly. Call before add_child.
func bind(interior: Interior) -> void:
	_interior = interior


func _build_body() -> void:
	var frame := StandardMaterial3D.new()
	frame.albedo_color = VoxelDefs.COLORS[frame_material]
	frame.roughness = 0.95

	# A dark slab standing in the opening. Unshaded, so it stays a hole in the
	# wall rather than picking up whatever light is around it.
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.02, 0.03, 0.05)
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var slab := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.1, 1.9, 0.08)
	slab.mesh = bm
	slab.material_override = dark
	slab.position = Vector3(0.0, 0.95, 0.0)
	add_child(slab)

	var sill := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(1.3, 0.1, 0.3)
	sill.mesh = sm
	sill.material_override = frame
	sill.position = Vector3(0.0, 0.05, 0.0)
	add_child(sill)

	# The doorway is walked through, not walked into, so the body it presents
	# to the interaction ray is a thin plate rather than a blocking slab.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 2.0, 0.12)
	shape.shape = box
	shape.position = Vector3(0.0, 1.0, 0.0)
	add_child(shape)


func _on_use(actor: Node3D) -> void:
	if _interior == null:
		return
	var aim := actor as Interactor
	var body := null if aim == null else aim.body()
	if body == null:
		return
	if leads_out:
		_interior.leave(body)
	else:
		_interior.enter(body)
