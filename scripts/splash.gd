extends CanvasLayer

## Loading screen shown while the initial disc of chunks around the spawn
## point is generated. Pauses the scene tree so the player cannot move or fall
## through half-built ground, then unpauses and tears itself down once
## VoxelWorld reports the world is ready.
##
## Runs at PROCESS_MODE_ALWAYS (set on the node in main.tscn) so it keeps
## ticking while everything else is paused; VoxelWorld is set the same way so
## it can keep pumping its worker threads and integrating finished chunks.
##
## In XR the flat 2D overlay below is useless (CanvasLayer content isn't a
## comfortable way to show something in a headset), so a matching world-space
## panel is built in code and head-locked ~2m in front of the player instead.
## Everything else is blacked out for the duration by putting the panel on its
## own VisualInstance3D layer and restricting the headset camera to only that
## layer; voxel chunks are drawn as bare RenderingServer instances rather than
## scene nodes, so hiding them by Node.visible doesn't work - excluding every
## other layer from the camera is the one thing that reliably hides them too.

@export var world_path: NodePath = ^"../VoxelWorld"
@export var xr_mode_path: NodePath = ^"../XRMode"

## Distance (m) the XR panel floats in front of the headset camera.
@export var xr_panel_distance: float = 2.0

## VisualInstance3D layer (1-20) reserved for the XR splash panel. Nothing
## else in the project uses a custom layer, so this just needs to be unused.
const XR_PANEL_LAYER_BIT := 20

@onready var _bar: ProgressBar = $Panel/ProgressBar
@onready var _label: Label = $Panel/Label

var _world: VoxelWorld

var _xr_camera: Camera3D
var _xr_camera_cull_mask := 0
var _xr_root: Node3D
var _xr_fill_pivot: Node3D
var _xr_percent_label: Label3D
var _xr_panel_placed := false


func _ready() -> void:
	_world = get_node_or_null(world_path) as VoxelWorld
	# TEMP: see VoxelWorld.debug_start_in_vault - the island is never
	# streamed in this mode, so there is nothing for a loading screen to wait
	# on; skip it and drop straight into the vault.
	if _world != null and _world.debug_start_in_vault:
		queue_free()
		return
	get_tree().paused = true
	if _world == null:
		_finish()
		return
	_try_enter_xr()
	_world.generation_progress.connect(_on_progress)
	_world.world_ready.connect(_on_world_ready)
	# The world may have raced ahead and already finished its first disc
	# before we got here (e.g. a tiny view distance); catch up instead of
	# waiting forever for signals that already fired.
	if _world.is_world_ready():
		_on_world_ready()
		return
	_on_progress(0, _world.generation_total())


func _process(_delta: float) -> void:
	# Placed once from the headset's current pose and then left alone, so it
	# reads as a fixed object in the world rather than something stuck to the
	# player's view; only the first frame (once tracking has a pose) sets it.
	if _xr_camera != null and _xr_root != null and not _xr_panel_placed:
		_xr_root.global_transform = _xr_camera.global_transform.translated_local(
			Vector3(0.0, 0.0, -xr_panel_distance)
		)
		_xr_panel_placed = true


func _on_progress(done: int, total: int) -> void:
	var fraction := 0.0
	if total <= 0:
		_bar.max_value = 1
		_bar.value = 0
	else:
		_bar.max_value = total
		_bar.value = done
		fraction = clampf(float(done) / float(total), 0.0, 1.0)
	if _xr_fill_pivot != null:
		_xr_fill_pivot.scale.x = fraction
	if _xr_percent_label != null:
		_xr_percent_label.text = "%d%%" % roundi(fraction * 100.0)


func _on_world_ready() -> void:
	_finish()


func _finish() -> void:
	_leave_xr()
	get_tree().paused = false
	queue_free()


## --- XR ------------------------------------------------------------------

func _try_enter_xr() -> void:
	var xr_mode := get_node_or_null(xr_mode_path)
	if xr_mode == null or not ("xr_camera" in xr_mode):
		return
	_xr_camera = xr_mode.xr_camera
	if _xr_camera == null:
		return
	_build_xr_panel()
	_apply_black_environment()


## Restricts the headset camera to see only the panel's own layer, which
## hides every other node *and* the bare RenderingServer chunk meshes that
## Node.visible can't reach. Also blacks out the background so there is
## nothing but the panel showing where geometry would otherwise have been.
func _apply_black_environment() -> void:
	_xr_camera_cull_mask = _xr_camera.cull_mask
	_xr_camera.cull_mask = 1 << (XR_PANEL_LAYER_BIT - 1)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.fog_enabled = false
	env.glow_enabled = false
	env.ssao_enabled = false
	_xr_camera.environment = env


## Builds a small unshaded, double-sided panel (backdrop + label + progress
## bar) out of primitive meshes. Kept in code rather than the scene since it
## only ever exists while in XR and needs no editor tweaking.
func _build_xr_panel() -> void:
	_xr_root = Node3D.new()
	add_child(_xr_root)

	# Local +Z (toward the camera, since xr_root shares the camera's basis)
	# stacks nearer elements in front of farther ones so the bar fill and its
	# label aren't depth-occluded by the backdrop/background behind them.
	var splash_tex := load("res://resources/splash.jpg") as Texture2D
	if splash_tex != null:
		var backdrop_image := MeshInstance3D.new()
		backdrop_image.mesh = _quad(Vector2(3.2, 1.8))
		backdrop_image.material_override = _textured_material(splash_tex)
		# 1m behind the progress bar (which sits ~2m in front of the player).
		backdrop_image.position = Vector3(0.0, 0.0, -1.0)
		_add_to_panel_layer(backdrop_image)
		_xr_root.add_child(backdrop_image)

	var backdrop := MeshInstance3D.new()
	backdrop.mesh = _quad(Vector2(1.2, 0.5))
	backdrop.material_override = _unshaded_material(Color(0.05, 0.05, 0.05, 0.9))
	backdrop.position = Vector3(0.0, 0.0, -0.02)
	_add_to_panel_layer(backdrop)
	_xr_root.add_child(backdrop)

	var label := Label3D.new()
	label.text = _label.text
	label.font_size = 64
	label.pixel_size = 0.0015
	label.modulate = Color.WHITE
	label.double_sided = true
	label.no_depth_test = true
	label.position = Vector3(0.0, 0.12, 0.0)
	_add_to_panel_layer(label)
	_xr_root.add_child(label)

	var bar_bg := MeshInstance3D.new()
	bar_bg.mesh = _quad(Vector2(0.9, 0.08))
	bar_bg.material_override = _unshaded_material(Color(0.15, 0.15, 0.15))
	bar_bg.position = Vector3(0.0, -0.08, -0.01)
	_add_to_panel_layer(bar_bg)
	_xr_root.add_child(bar_bg)

	_xr_fill_pivot = Node3D.new()
	_xr_fill_pivot.position = Vector3(-0.45, -0.08, 0.0)
	_xr_fill_pivot.scale.x = 0.0
	_xr_root.add_child(_xr_fill_pivot)

	var bar_fill := MeshInstance3D.new()
	bar_fill.mesh = _quad(Vector2(0.9, 0.08))
	bar_fill.material_override = _unshaded_material(Color(0.2, 0.7, 0.3))
	bar_fill.position = Vector3(0.45, 0.0, 0.0)
	_add_to_panel_layer(bar_fill)
	_xr_fill_pivot.add_child(bar_fill)

	_xr_percent_label = Label3D.new()
	_xr_percent_label.text = "0%"
	_xr_percent_label.font_size = 40
	_xr_percent_label.pixel_size = 0.0018
	_xr_percent_label.modulate = Color.WHITE
	_xr_percent_label.double_sided = true
	_xr_percent_label.no_depth_test = true
	_xr_percent_label.position = Vector3(0.0, -0.08, 0.01)
	_add_to_panel_layer(_xr_percent_label)
	_xr_root.add_child(_xr_percent_label)


func _add_to_panel_layer(inst: VisualInstance3D) -> void:
	inst.layers = 1 << (XR_PANEL_LAYER_BIT - 1)


func _quad(size: Vector2) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = size
	return mesh


func _unshaded_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = (
		BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0
		else BaseMaterial3D.TRANSPARENCY_DISABLED
	)
	return mat


func _textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _leave_xr() -> void:
	if _xr_camera != null:
		_xr_camera.environment = null
		_xr_camera.cull_mask = _xr_camera_cull_mask
	# _xr_root is our own child, so queue_free() below (in _finish) tears it
	# down too.
