class_name Torch
extends Carryable

## A voxel torch: the design's portable light. Built from the same blocky
## masonry-and-fire kit as the vault's braziers, so a carried light reads as
## something struck from the world's own materials rather than a prop bolted
## onto it.

@export_range(0.0, 12.0, 0.1) var light_energy: float = 3.0
@export_range(0.5, 20.0, 0.5) var light_range: float = 7.0
## How hard the flame flickers, and how fast it churns. A torch burns, it does
## not breathe, so the light rides noise rather than a single smooth sine.
@export_range(0.0, 0.6, 0.01) var flicker_depth: float = 0.32
@export_range(0.5, 12.0, 0.5) var flicker_speed: float = 9.0
## How many embers drift up off the flame at once.
@export_range(0, 40, 1) var ember_count: int = 14

## Edge length of a stem voxel, well under the world's 10 cm block so a
## hand-held torch still reads as many small blocks rather than one plank.
const WOOD_VOXEL_SIZE := 0.025
## The fire's cold and hot ends. Each little flame voxel sits somewhere
## between the two, and drifts along that range as the flame flickers.
const FLAME_COLD := Color(0.95, 0.35, 0.08)
const FLAME_HOT := Color(1.0, 0.85, 0.25)

var _light: OmniLight3D
var _flame_mats: Array[StandardMaterial3D] = []
var _particles: GPUParticles3D
var _noise := FastNoiseLite.new()
var _time := 0.0
var _wood_material: ShaderMaterial


func _ready() -> void:
	item_id = &"torch"
	take_prompt = "Take the torch"
	drop_prompt = "Put the torch down"
	super()
	_build_body()
	_noise.frequency = 1.0
	_noise.seed = randi()
	# Random phase per torch, so two burning at once do not flicker in lockstep.
	_time = randf() * 1000.0


func _build_body() -> void:
	var handle := _wood_box(Vector3(0.07, 0.5, 0.07))
	handle.position = Vector3(0.0, 0.25, 0.0)
	add_child(handle)

	var head := _wood_box(Vector3(0.14, 0.16, 0.14))
	head.position = Vector3(0.0, 0.53, 0.0)
	add_child(head)

	_build_flame()

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.66, 0.3)
	_light.light_energy = light_energy
	_light.omni_range = light_range
	# A carried light that casts shadows re-renders the world every time the
	# player turns their head, and in XR it does it twice.
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 0.7, 0.0)
	add_child(_light)

	_build_embers()

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.22, 0.76, 0.22)
	shape.shape = box
	shape.position = Vector3(0.0, 0.38, 0.0)
	add_child(shape)


## A wood-shaded box: the same per-voxel dithering the trees are built from,
## just with a voxel size small enough that a 7 cm handle still shows several
## of them, instead of one flat plank.
func _wood_box(size: Vector3) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _colored_box_mesh(size, VoxelDefs.color_of(VoxelDefs.WOOD))
	mesh_instance.material_override = _wood_material_instance()
	return mesh_instance


func _wood_material_instance() -> ShaderMaterial:
	if _wood_material == null:
		_wood_material = ShaderMaterial.new()
		_wood_material.shader = preload("res://shaders/voxel_prop.gdshader")
		_wood_material.set_shader_parameter("voxel_size", WOOD_VOXEL_SIZE)
		_wood_material.set_shader_parameter("tint_scale", 1.0)
	return _wood_material


## A box mesh carrying an explicit per-vertex colour, so it can ride the
## world's own voxel shader (which reads its tint from vertex colour) instead
## of a flat material.
func _colored_box_mesh(size: Vector3, color: Color) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.surface_get_arrays(0)
	var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var colors := PackedColorArray()
	colors.resize(vertex_count)
	colors.fill(color)
	arrays[Mesh.ARRAY_COLOR] = colors
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh


## The fire itself: a short stack of small emissive voxels, tapering as it
## rises and jittered off-centre, so it reads as a lit flame built from the
## same blocky kit as the rest of the torch rather than one smooth blob.
func _build_flame() -> void:
	const CUBE_COUNT := 6
	for i in CUBE_COUNT:
		var t := float(i) / float(CUBE_COUNT - 1)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		var col := FLAME_COLD.lerp(FLAME_HOT, t)
		mat.albedo_color = col
		mat.emission = col
		mat.emission_energy_multiplier = 2.4 + t * 1.2

		var cube := MeshInstance3D.new()
		var box := BoxMesh.new()
		var s := lerpf(0.09, 0.045, t)
		box.size = Vector3(s, s, s)
		cube.mesh = box
		cube.material_override = mat
		cube.position = Vector3(
			randf_range(-0.015, 0.015), 0.6 + t * 0.22, randf_range(-0.015, 0.015))
		add_child(cube)
		_flame_mats.append(mat)


## A thin stream of embers off the flame tip. Built entirely from a procedural
## cube and material, the same "no external art" rule everything else in the
## world follows - tiny tumbling voxels rather than flat billboards.
func _build_embers() -> void:
	var cube := BoxMesh.new()
	cube.size = Vector3(0.03, 0.03, 0.03)

	var ember_mat := StandardMaterial3D.new()
	ember_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ember_mat.vertex_color_use_as_albedo = true
	ember_mat.emission_enabled = true
	ember_mat.emission = Color(1.0, 0.6, 0.2)
	ember_mat.emission_energy_multiplier = 3.0
	cube.material = ember_mat

	var fade := Gradient.new()
	fade.set_color(0, Color(0.85, 0.35, 0.05, 1.0))
	fade.set_color(1, Color(1.0, 0.85, 0.25, 0.0))
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade

	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3(0.0, 1.0, 0.0)
	process_mat.spread = 20.0
	process_mat.initial_velocity_min = 0.25
	process_mat.initial_velocity_max = 0.55
	process_mat.gravity = Vector3(0.0, 0.35, 0.0)
	process_mat.scale_min = 0.5
	process_mat.scale_max = 1.1
	process_mat.color_ramp = fade_tex
	# Random hue drift per ember, layered on top of the lifetime gradient, so
	# no two embers read as the exact same shade of fire.
	process_mat.hue_variation_min = -0.06
	process_mat.hue_variation_max = 0.06
	# Cubes tumble instead of billboarding flat toward the camera.
	process_mat.particle_flag_rotate_y = true
	process_mat.angle_min = -180.0
	process_mat.angle_max = 180.0
	process_mat.angular_velocity_min = -180.0
	process_mat.angular_velocity_max = 180.0

	_particles = GPUParticles3D.new()
	_particles.process_material = process_mat
	_particles.draw_pass_1 = cube
	_particles.amount = ember_count
	_particles.lifetime = 1.0
	_particles.position = Vector3(0.0, 0.72, 0.0)
	add_child(_particles)


func _process(delta: float) -> void:
	if _light == null:
		return
	_time += delta * flicker_speed
	var n := _noise.get_noise_1d(_time)
	var flicker := 1.0 + n * flicker_depth
	_light.light_energy = light_energy * flicker
	# The same noise that breathes the light also drags every flame voxel
	# between the cold and hot ends of the fire, so the flame keeps shifting
	# colour for as long as it keeps throwing embers off its tip.
	var shift := clampf(n * 0.5 + 0.5, 0.0, 1.0)
	for i in _flame_mats.size():
		var mat := _flame_mats[i]
		var t := float(i) / float(maxi(_flame_mats.size() - 1, 1))
		var col := FLAME_COLD.lerp(FLAME_HOT, clampf(t * 0.7 + shift * 0.3, 0.0, 1.0))
		mat.albedo_color = col
		mat.emission = col
		mat.emission_energy_multiplier = (2.4 + t * 1.2) * flicker
