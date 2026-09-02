class_name Brazier
extends Interactable

## A stone bowl of cold ash. Hold a cut glow-cap against it and it catches.
##
## The vault's puzzle is made of these, and they are deliberately made of the
## verbs the game already has rather than of a new mechanism: the player is
## already carrying a light, because the vault is dark, and using a thing while
## holding another thing is what the sockets outside already ask for. Nothing
## here needs a gesture, so it plays the same at a desk and in a headset.
##
## A brazier keeps the cap. Lighting one costs nothing but the walk, which is
## the point - the puzzle is finding the three of them in the dark, not
## rationing anything.

## What has to be in hand for the ash to catch. Empty lights from anything.
@export var accepts: StringName = &"glow_cap"
## The three states of the prompt: nothing in hand, the right thing in hand,
## and already burning.
@export var cold_prompt: String = "Cold ash, long dead"
@export var light_prompt: String = "Set the cap to the ash"
@export var burning_prompt: String = "It is burning"
@export_range(0.0, 12.0, 0.1) var light_energy: float = 3.4
@export_range(0.5, 24.0, 0.5) var light_range: float = 11.0
## How much the flame breathes, and how fast. Faster and shallower than a
## glow-cap: one is a fire, the other is a mushroom.
@export_range(0.0, 0.6, 0.01) var pulse_depth: float = 0.18
@export_range(0.1, 8.0, 0.1) var pulse_speed: float = 3.7

## Fires when the ash catches. `by_hand` is false when a restored save is
## bringing the brazier back up, so whatever is listening can put itself
## straight into the finished state instead of playing the moment again.
signal lit(by_hand: bool)

var burning := false

var _light: OmniLight3D
var _flame: MeshInstance3D
var _flame_mat: StandardMaterial3D
var _phase := 0.0


func _ready() -> void:
	prompt = cold_prompt
	# Read by Interactable._ready, so it has to be set before it runs.
	label_height = 1.2
	super()
	add_to_group("savable")
	_build_body()
	_phase = randf() * TAU
	_show_state()


## True once the ash has caught. What the vault counts.
func is_burning() -> bool:
	return burning


## Lights it. Public, and told whether a hand did it, because a restored save
## has to bring one back up with nobody standing in front of it holding a cap.
func kindle(by_hand: bool = true) -> void:
	if burning:
		return
	burning = true
	_show_state()
	lit.emit(by_hand)


func _build_body() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = VoxelDefs.COLORS[VoxelDefs.STONE]
	stone.roughness = 0.95

	# A stem and a bowl: three boxes, in the palette of the world, for the same
	# reason the lock and the sockets outside are built this way.
	var stem := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.22, 0.72, 0.22)
	stem.mesh = sm
	stem.material_override = stone
	stem.position = Vector3(0.0, 0.36, 0.0)
	add_child(stem)

	var foot := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.46, 0.1, 0.46)
	foot.mesh = fm
	foot.material_override = stone
	foot.position = Vector3(0.0, 0.05, 0.0)
	add_child(foot)

	var bowl := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.16, 0.5)
	bowl.mesh = bm
	bowl.material_override = stone
	bowl.position = Vector3(0.0, 0.8, 0.0)
	add_child(bowl)

	# What the ash looks like, cold and lit. Unlit it is a dark slab in the
	# bowl; lit, the same slab is emissive and the light sits just above it.
	_flame_mat = StandardMaterial3D.new()
	_flame_mat.albedo_color = Color(0.09, 0.08, 0.08)
	_flame_mat.roughness = 1.0
	_flame = MeshInstance3D.new()
	var am := BoxMesh.new()
	am.size = Vector3(0.36, 0.14, 0.36)
	_flame.mesh = am
	_flame.material_override = _flame_mat
	_flame.position = Vector3(0.0, 0.9, 0.0)
	add_child(_flame)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.72, 0.36)
	_light.omni_range = light_range
	# Same trade the carried cap makes: a shadow casting light in a room full
	# of masonry is a second render of the whole vault, twice over in XR.
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 1.0, 0.0)
	_light.visible = false
	add_child(_light)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.52, 1.0, 0.52)
	shape.shape = box
	shape.position = Vector3(0.0, 0.5, 0.0)
	add_child(shape)


## Cold ash or a fire, in the mesh, the light and the prompt.
func _show_state() -> void:
	if _flame_mat != null:
		_flame_mat.albedo_color = Color(0.95, 0.55, 0.22) if burning \
			else Color(0.09, 0.08, 0.08)
		_flame_mat.emission_enabled = burning
		_flame_mat.emission = Color(1.0, 0.66, 0.3)
		_flame_mat.emission_energy_multiplier = 2.6
	if _light != null:
		_light.visible = burning
		_light.light_energy = light_energy
	if burning:
		prompt = burning_prompt
		refresh_prompt()


## The prompt depends on what the player is holding, so it is worked out as the
## brazier is looked at rather than only when something changes. Same reason
## the sockets outside do it.
func _on_focus(on: bool) -> void:
	if not on:
		return
	_update_prompt(_looking_actor())
	refresh_prompt()


func _looking_actor() -> Interactor:
	for n in get_tree().get_nodes_in_group("interactor"):
		var it := n as Interactor
		if it != null and it.focus() == self:
			return it
	return null


func _update_prompt(aim: Interactor) -> void:
	if burning:
		prompt = burning_prompt
		return
	prompt = light_prompt if _holding_light(aim) else cold_prompt


func _holding_light(aim: Interactor) -> bool:
	var held := null if aim == null else aim.carried() as Carryable
	if held == null:
		return false
	return accepts == &"" or held.item_id == accepts


func _on_use(actor: Node3D) -> void:
	var aim := actor as Interactor
	if burning or not _holding_light(aim):
		_update_prompt(aim)
		return
	kindle()


## The flame breathes. Only while lit: an unlit brazier is a rock and should
## not cost a frame.
func _process(delta: float) -> void:
	if not burning or _light == null:
		return
	_phase += delta * pulse_speed
	_light.light_energy = light_energy * (1.0 + sin(_phase) * pulse_depth)


func save_state() -> Dictionary:
	return {"burning": burning}


func load_state(d: Dictionary) -> void:
	if bool(d.get("burning", false)):
		kindle(false)
