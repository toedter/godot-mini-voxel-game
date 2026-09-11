class_name Barrel
extends StaticBody3D

## A wooden barrel, standing wherever VaultPlan's clutter anchors put it.
## Pure set dressing: cargo left behind in a vault this size would have been
## stocked with, not a puzzle piece and not a light - it stands solid so the
## corridor reads as furnished rather than swept bare, and nothing else about
## it is interactive.
##
## Built the same way everything else in the world is: boxes, not a smooth
## drum. A barrel is five square courses stacked up, each a little wider than
## the last until the middle and then back in again, so the bulge is stepped
## rather than curved - the same trade the vault's own vaulted ceiling makes,
## voxels standing in for a shape they can only ever approximate.

const DIAMETER := 0.52
const HEIGHT := 0.62
const COURSES := 5
## How far the middle course bulges past the top and bottom ones, as a
## fraction of the diameter. Small - a barrel is a stack of square courses
## that only reads as round from a few steps back.
const BULGE := 0.22


func _ready() -> void:
	_build_body()


func _build_body() -> void:
	var wood := StandardMaterial3D.new()
	wood.albedo_color = VoxelDefs.COLORS[VoxelDefs.WOOD]
	wood.roughness = 0.9

	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.16, 0.14, 0.13)
	iron.roughness = 0.6
	iron.metallic = 0.2

	var course_height := HEIGHT / float(COURSES)
	var widths := PackedFloat32Array()
	var max_width := 0.0
	for i in COURSES:
		var t := float(i) / float(COURSES - 1)
		# A single hump, widest at the middle course and narrowest at the two
		# end ones - a barrel's bulge, laid out one flat course at a time.
		var w: float = DIAMETER * (1.0 - BULGE + BULGE * sin(t * PI))
		widths.append(w)
		max_width = maxf(max_width, w)

	for i in COURSES:
		var course := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(widths[i], course_height, widths[i])
		course.mesh = bm
		course.material_override = wood
		course.position = Vector3(0.0, course_height * (float(i) + 0.5), 0.0)
		course.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(course)

	# Two hoops, a course above the bottom and a course below the top, a
	# little proud of the staves so the barrel reads as banded rather than as
	# a plain stack of blocks.
	for i in [1, COURSES - 2]:
		var hoop := MeshInstance3D.new()
		var hm := BoxMesh.new()
		var w := widths[i] + 0.03
		hm.size = Vector3(w, course_height * 0.35, w)
		hoop.mesh = hm
		hoop.material_override = iron
		hoop.position = Vector3(0.0, course_height * (float(i) + 0.5), 0.0)
		hoop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(hoop)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(max_width, HEIGHT, max_width)
	shape.shape = box
	shape.position = Vector3(0.0, HEIGHT * 0.5, 0.0)
	add_child(shape)
