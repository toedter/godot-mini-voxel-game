class_name Player
extends CharacterBody3D

## First person controller: WASD + mouse look, Space to jump, Shift to sprint.

@export var walk_speed := 4.5
@export var sprint_speed := 8.5
@export var jump_velocity := 5.0
@export var mouse_sensitivity := 0.0022
@export var accel_ground := 14.0
@export var accel_air := 3.0
## Maximum height (m) the player automatically steps up, ~4 voxels.
@export var step_height := 0.45
@export var world_path: NodePath = ^"../VoxelWorld"

@onready var _camera: Camera3D = $Head/Camera3D

var _pitch := 0.0
var _world: VoxelWorld


func _ready() -> void:
	_world = get_node_or_null(world_path) as VoxelWorld
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.4


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		rotate_y(-mm.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - mm.relative.y * mouse_sensitivity, -1.5, 1.5)
		_camera.rotation.x = _pitch
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if input.length_squared() > 1.0:
		input = input.normalized()
	var dir := (transform.basis * Vector3(input.x, 0.0, input.y))
	dir.y = 0.0
	if dir.length_squared() > 0.0:
		dir = dir.normalized()

	var speed := sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	var target := dir * speed
	var a := accel_ground if is_on_floor() else accel_air
	velocity.x = move_toward(velocity.x, target.x, a * speed * delta)
	velocity.z = move_toward(velocity.z, target.z, a * speed * delta)

	if is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity
	else:
		velocity += get_gravity() * delta

	var was_on_floor := is_on_floor()
	var before := global_position
	move_and_slide()

	if was_on_floor and is_on_wall():
		_try_step_up(before, Vector3(velocity.x, 0.0, velocity.z) * delta)

	_clamp_to_terrain()


## Lets the capsule climb the small 10 cm terrain steps without stopping.
func _try_step_up(before: Vector3, motion: Vector3) -> void:
	if motion.length_squared() < 1e-8:
		return
	var moved := global_position - before
	moved.y = 0.0
	if moved.length() > motion.length() * 0.7:
		return # we made progress anyway

	var t := global_transform
	t.origin = before
	var up := Vector3.UP * step_height
	if test_move(t, up):
		return
	t.origin = before + up
	if test_move(t, motion):
		return
	global_position = before + up + motion
	move_and_collide(Vector3.DOWN * (step_height + 0.05))


## Safety net so the player never falls through chunks whose collision shape
## has not been streamed in yet.
func _clamp_to_terrain() -> void:
	if _world == null or _world.gen == null:
		return
	var g := _world.gen.ground_y(global_position.x, global_position.z)
	if global_position.y < g:
		global_position.y = g
		if velocity.y < 0.0:
			velocity.y = 0.0
