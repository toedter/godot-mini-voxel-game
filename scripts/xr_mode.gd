class_name XRMode
extends Node3D

## Detects a VR headset at startup and, if there is one, swaps the desktop
## first person player for the XR rig from the Godot XR Development Kit.
##
## Without a headset nothing changes and the project keeps running as a normal
## mouse and keyboard game.

## The XR rig instanced in place of the desktop player.
@export var xr_player_scene: PackedScene = preload("res://scenes/xr_player.tscn")
@export var desktop_player_path: NodePath = ^"../Player"
@export var world_path: NodePath = ^"../VoxelWorld"
@export var atmosphere_path: NodePath = ^"../WorldEnvironment"
@export var sun_path: NodePath = ^"../Sun"
@export var hud_path: NodePath = ^"../HUD"

## Brings up the XR rig even when no headset is present. Only useful for
## checking the rig on a desktop, where nothing drives the camera.
@export var force_rig: bool = false

## How far (m) chunks are streamed while in XR. Stereo rendering costs roughly
## twice as much as the flat view, and the whole disc is full detail voxels, so
## it is pulled in to hold the headset's framerate. Atmosphere closes the mist
## in to match on its own.
@export_range(24.0, 256.0, 1.0) var xr_view_distance: float = 64.0
## SSAO is a full screen effect and gets rendered per eye; off by default in XR.
@export var xr_disable_ssao: bool = true
## Cell size (m) of the distant island mesh in XR. The mesh is drawn twice
## over, once per eye, so it is worth the coarser ground; it only ever shows
## through the mist as the peaks across the island anyway.
@export var xr_far_step: float = 4.0
## How far (m) the sun and moon cast in XR. The cascades are rendered per eye,
## so the horizon they reach to is pulled in with everything else.
@export var xr_shadow_distance: float = 120.0

var xr_active := false

var _xr_player: CharacterBody3D


func _ready() -> void:
	xr_active = _detect_headset()
	if xr_active:
		print("XR: headset detected, switching to the XR player rig")
	if xr_active or force_rig:
		activate_xr_rig()


## Replaces the desktop player with the XR rig and points everything that
## tracks the player at it. Safe to call more than once.
func activate_xr_rig() -> void:
	if _xr_player != null:
		return
	_swap_in_xr_player()
	_retarget_dependents()
	_tune_for_xr()


## True when an XR interface is present *and* it actually came up, which is the
## only reliable sign that a headset is connected and its runtime is running.
func _detect_headset() -> bool:
	var iface := XRServer.find_interface("OpenXR")
	if iface == null:
		return false
	if not iface.is_initialized() and not iface.initialize():
		return false
	var vp := get_viewport()
	vp.use_xr = true
	# The compositor paces us to the headset, so desktop vsync would only add
	# latency.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if RenderingServer.get_rendering_device():
		vp.vrs_mode = Viewport.VRS_XR
	return true


func _swap_in_xr_player() -> void:
	var desktop := get_node_or_null(desktop_player_path) as CharacterBody3D
	if desktop != null:
		# We run during _ready, while our parent is busy setting up its
		# children and so refuses add_child/remove_child. Shutting the desktop
		# player down and queueing it for deletion achieves the same without
		# touching the parent, and stops it colliding with the XR body
		# meanwhile.
		desktop.process_mode = Node.PROCESS_MODE_DISABLED
		desktop.collision_layer = 0
		desktop.collision_mask = 0
		desktop.hide()
		desktop.queue_free()

	# The rig becomes our own child; adding to ourselves is allowed here.
	_xr_player = xr_player_scene.instantiate() as CharacterBody3D
	_xr_player.name = "XRPlayer"
	add_child(_xr_player)


## The world, the atmosphere tint and the HUD all track "the player". Point
## them at the XR body. Their own _ready may already have resolved the old
## path, so refresh their cached node as well.
func _retarget_dependents() -> void:
	var path := _xr_player.get_path()
	for p: NodePath in [world_path, atmosphere_path, hud_path]:
		var n := get_node_or_null(p)
		if n != null and "player_path" in n:
			n.player_path = path
			if "_player" in n:
				n._player = _xr_player


func _tune_for_xr() -> void:
	var world := get_node_or_null(world_path)
	if world != null and "view_distance" in world:
		world.view_distance = xr_view_distance
		# Runs before VoxelWorld is ready, so the distant island is built at
		# the XR resolution rather than built twice.
		world.far_step = xr_far_step

	var sun := get_node_or_null(sun_path) as DirectionalLight3D
	if sun != null:
		sun.directional_shadow_max_distance = xr_shadow_distance

	if xr_disable_ssao:
		var we := get_node_or_null(atmosphere_path) as WorldEnvironment
		if we != null and we.environment != null:
			we.environment.ssao_enabled = false

	# No mouse look and no crosshair in a headset. Deferred because the desktop
	# player captures the mouse in its own _ready, which runs after ours.
	_release_mouse.call_deferred()
	var hud := get_node_or_null(hud_path)
	if hud != null:
		var crosshair := hud.get_node_or_null(^"Crosshair") as CanvasItem
		if crosshair != null:
			crosshair.hide()


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
