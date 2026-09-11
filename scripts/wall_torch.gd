class_name WallTorch
extends StaticBody3D

## A sconce, fixed to a wall and always burning. Built from the same
## masonry-and-fire kit as the carried torch and the braziers, but it is
## neither: nobody picks this up, and nothing waits on it.
##
## Deliberately dim and short-ranged, and deliberately rare. The vault's own
## puzzle is finding three braziers in the dark, and a sconce that lit more
## than the room it stands in would be doing that puzzle's job for it. This
## is mood at the threshold, not light carried into the maze - VaultPlan only
## ever places these in the antechamber, and this script has no opinion about
## that; it just burns wherever it is put.

@export_range(0.0, 4.0, 0.1) var light_energy: float = 0.9
@export_range(0.2, 6.0, 0.1) var light_range: float = 2.4
@export_range(0.0, 0.6, 0.01) var flicker_depth: float = 0.28
@export_range(0.5, 12.0, 0.5) var flicker_speed: float = 8.0

var _light: OmniLight3D
var _flame_mat: StandardMaterial3D
var _noise := FastNoiseLite.new()
var _time := 0.0


func _ready() -> void:
	_build_body()
	_noise.frequency = 1.0
	_noise.seed = randi()
	_time = randf() * 1000.0


func _build_body() -> void:
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.12, 0.11, 0.11)
	iron.roughness = 0.7
	iron.metallic = 0.3

	# The bracket: a stub out of the wall and a short cup to hold the flame,
	# rather than the stem-and-bowl a free-standing brazier can afford to be.
	# Built along -Z, the way Node3D's own forward points, so a sconce whose
	# yaw is worked out from "face this way" actually projects into the room
	# it is mounted in rather than back through the wall behind it.
	var arm := MeshInstance3D.new()
	var am := BoxMesh.new()
	am.size = Vector3(0.08, 0.08, 0.22)
	arm.mesh = am
	arm.material_override = iron
	arm.position = Vector3(0.0, 0.0, -0.11)
	add_child(arm)

	var cup := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.16, 0.06, 0.16)
	cup.mesh = cm
	cup.material_override = iron
	cup.position = Vector3(0.0, 0.03, -0.24)
	add_child(cup)

	_flame_mat = StandardMaterial3D.new()
	_flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flame_mat.emission_enabled = true
	_flame_mat.emission = Color(1.0, 0.62, 0.24)
	_flame_mat.albedo_color = Color(1.0, 0.62, 0.24)
	_flame_mat.emission_energy_multiplier = 2.2
	var flame := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.1, 0.16, 0.1)
	flame.mesh = fm
	flame.material_override = _flame_mat
	flame.position = Vector3(0.0, 0.12, -0.24)
	add_child(flame)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.68, 0.3)
	_light.light_energy = light_energy
	_light.omni_range = light_range
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 0.14, -0.24)
	add_child(_light)

	# A small solid bump, the same as every other free-standing prop in the
	# vault, so the sconce is something a player brushing past it actually
	# catches on rather than something they can walk their head through.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.18, 0.2, 0.3)
	shape.shape = box
	shape.position = Vector3(0.0, 0.07, -0.15)
	add_child(shape)


func _process(delta: float) -> void:
	if _light == null:
		return
	_time += delta * flicker_speed
	var n := _noise.get_noise_1d(_time)
	_light.light_energy = light_energy * (1.0 + n * flicker_depth)
	if _flame_mat != null:
		_flame_mat.emission_energy_multiplier = 2.2 * (1.0 + n * flicker_depth)
