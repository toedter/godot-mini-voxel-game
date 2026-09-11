class_name Crate
extends StaticBody3D

## A wooden crate, standing wherever VaultPlan's clutter anchors put it.
## The same kind of cargo a Barrel is, in a box instead of a drum: plain set
## dressing, solid to walk into, nothing to interact with and nothing that
## throws light.

const SIZE := Vector3(0.46, 0.46, 0.46)


func _ready() -> void:
	_build_body()


func _build_body() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = VoxelDefs.COLORS[VoxelDefs.WOOD]
	wood.roughness = 0.92

	var trim := StandardMaterial3D.new()
	trim.albedo_color = (VoxelDefs.COLORS[VoxelDefs.WOOD] as Color).darkened(0.4)
	trim.roughness = 0.92

	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = SIZE
	body.mesh = bm
	body.material_override = wood
	body.position = Vector3(0.0, SIZE.y * 0.5, 0.0)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(body)

	# Four batten strips up the vertical edges, so a crate reads as boarded
	# rather than as one bare plank box.
	var batten := Vector3(0.05, SIZE.y + 0.01, 0.05)
	var half_x := SIZE.x * 0.5 - batten.x * 0.5
	var half_z := SIZE.z * 0.5 - batten.z * 0.5
	for signs in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
		var edge := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = batten
		edge.mesh = em
		edge.material_override = trim
		edge.position = Vector3(signs.x * half_x, SIZE.y * 0.5, signs.y * half_z)
		edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(edge)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	shape.shape = box
	shape.position = Vector3(0.0, SIZE.y * 0.5, 0.0)
	add_child(shape)
