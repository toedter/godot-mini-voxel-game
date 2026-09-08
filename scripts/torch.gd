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

var _light: OmniLight3D
var _flame_mat: StandardMaterial3D
var _particles: GPUParticles3D
var _noise := FastNoiseLite.new()
var _time := 0.0


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
	var wood := StandardMaterial3D.new()
	wood.albedo_color = VoxelDefs.COLORS[VoxelDefs.WOOD]
	wood.roughness = 0.9

	var handle := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.07, 0.5, 0.07)
	handle.mesh = hm
	handle.material_override = wood
	handle.position = Vector3(0.0, 0.25, 0.0)
	add_child(handle)

	var head := MeshInstance3D.new()
	var hem := BoxMesh.new()
	hem.size = Vector3(0.14, 0.16, 0.14)
	head.mesh = hem
	head.material_override = wood
	head.position = Vector3(0.0, 0.53, 0.0)
	add_child(head)

	# What the fire looks like: an emissive block sitting in the wound head,
	# the same trick the brazier's ash bed uses.
	_flame_mat = StandardMaterial3D.new()
	_flame_mat.albedo_color = Color(0.95, 0.55, 0.22)
	_flame_mat.emission_enabled = true
	_flame_mat.emission = Color(1.0, 0.66, 0.3)
	_flame_mat.emission_energy_multiplier = 2.6
	_flame_mat.roughness = 1.0

	var flame := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.1, 0.18, 0.1)
	flame.mesh = fm
	flame.material_override = _flame_mat
	flame.position = Vector3(0.0, 0.68, 0.0)
	add_child(flame)

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
	if _flame_mat != null:
		_flame_mat.emission_energy_multiplier = 2.6 * flicker
