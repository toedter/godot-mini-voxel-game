class_name GlowCap
extends Carryable

## A mushroom cap that has been cut and still glows. The design's portable
## light: the engine already grows glowing caps all over the island, so a
## carried one reads as something taken from the world rather than as a torch
## bolted onto a fantasy setting.

@export_range(0.0, 8.0, 0.1) var light_energy: float = 2.2
@export_range(0.5, 20.0, 0.5) var light_range: float = 7.0
## How much the glow breathes, and how fast. The caps in the world pulse, so a
## cut one does too.
@export_range(0.0, 0.5, 0.01) var pulse_depth: float = 0.12
@export_range(0.1, 4.0, 0.1) var pulse_speed: float = 1.1

var _light: OmniLight3D
var _phase := 0.0


func _ready() -> void:
	item_id = &"glow_cap"
	take_prompt = "Take the glow-cap"
	drop_prompt = "Put the glow-cap down"
	super()
	_build_body()
	_phase = randf() * TAU


func _build_body() -> void:
	var cap := StandardMaterial3D.new()
	cap.albedo_color = VoxelDefs.COLORS[VoxelDefs.SHROOM_CAP]
	cap.emission_enabled = true
	cap.emission = VoxelDefs.COLORS[VoxelDefs.SHROOM_GLOW]
	cap.emission_energy_multiplier = 1.4
	cap.roughness = 0.7

	var stem := StandardMaterial3D.new()
	stem.albedo_color = VoxelDefs.COLORS[VoxelDefs.SHROOM_STEM]
	stem.roughness = 0.9

	var dome := MeshInstance3D.new()
	var dm := SphereMesh.new()
	dm.radius = 0.17
	dm.height = 0.2
	dm.is_hemisphere = true
	dome.mesh = dm
	dome.material_override = cap
	dome.position = Vector3(0.0, 0.1, 0.0)
	add_child(dome)

	var stalk := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.07, 0.11, 0.07)
	stalk.mesh = sm
	stalk.material_override = stem
	stalk.position = Vector3(0.0, 0.05, 0.0)
	add_child(stalk)

	_light = OmniLight3D.new()
	_light.light_color = VoxelDefs.COLORS[VoxelDefs.SHROOM_GLOW]
	_light.light_energy = light_energy
	_light.omni_range = light_range
	# A carried light that casts shadows re-renders the world every time the
	# player turns their head, and in XR it does it twice.
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 0.14, 0.0)
	add_child(_light)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.34, 0.22, 0.34)
	shape.shape = box
	shape.position = Vector3(0.0, 0.11, 0.0)
	add_child(shape)


func _process(delta: float) -> void:
	if _light == null:
		return
	_phase += delta * pulse_speed
	_light.light_energy = light_energy * (1.0 + sin(_phase) * pulse_depth)
