class_name StoneGate
extends StaticBody3D

## A slab standing in a doorway, which grinds up out of the way when whatever
## holds it shut is satisfied.
##
## Not an Interactable on purpose. A gate the player can push on is a door, and
## a door is a thing you try; this is the answer to a puzzle, and the only way
## to move it is to solve that. So it has no prompt and no verb - it opens
## because something else happened, somewhere else in the vault.

## Clear size (m) of the opening it fills. The slab is built a little proud of
## it on every side so no seam of the doorway shows around the edge.
@export var opening: Vector2 = Vector2(1.2, 2.0)
@export var thickness: float = 0.3
## How long the grind takes.
@export var travel_time: float = 1.6

signal opened()

var _open := false
var _shape: CollisionShape3D
var _shut_y := 0.0


func _ready() -> void:
	_build_body()
	_shut_y = position.y


func is_open() -> bool:
	return _open


## Opens the gate. Animated when a hand caused it, so the player sees what
## their brazier did; instant when a restored save is only putting the vault
## back the way it was left.
func open(animate: bool = true) -> void:
	if _open:
		return
	_open = true
	var lifted := _shut_y + opening.y + 0.1
	if not animate:
		position.y = lifted
		_set_solid(false)
		opened.emit()
		return
	var t := create_tween()
	t.tween_property(self, "position:y", lifted, travel_time) \
		.set_trans(Tween.TRANS_SINE)
	# The slab is solid the whole way up, so walking under a gate that is still
	# moving is not a thing the player can do.
	t.finished.connect(func() -> void:
		_set_solid(false)
		opened.emit())


func _build_body() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = VoxelDefs.COLORS[VoxelDefs.STONE]
	stone.roughness = 0.92

	var slab := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(opening.x + 0.12, opening.y + 0.08, thickness)
	slab.mesh = bm
	slab.material_override = stone
	slab.position = Vector3(0.0, (opening.y + 0.08) * 0.5, 0.0)
	# The vault is lit by what the player carries and by what they light, and
	# every one of those is a shadowless point light already.
	slab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(slab)

	_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(opening.x + 0.12, opening.y + 0.08, thickness)
	_shape.shape = box
	_shape.position = Vector3(0.0, (opening.y + 0.08) * 0.5, 0.0)
	add_child(_shape)


func _set_solid(on: bool) -> void:
	if _shape != null:
		_shape.disabled = not on
