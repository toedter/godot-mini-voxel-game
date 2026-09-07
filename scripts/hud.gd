extends CanvasLayer

## Minimal debug HUD: position, biome, chunk count and FPS.

@export var world_path: NodePath = ^"../VoxelWorld"
@export var player_path: NodePath = ^"../Player"
@export var music_path: NodePath = ^"../Music"
@export var sun_path: NodePath = ^"../Sun"

@onready var _label: Label = $Info
@onready var _crosshair: ColorRect = $Crosshair

## Tint the crosshair takes while something usable is under it, so the flat
## player gets the same "this is live" feedback the floating label gives.
const AIM_IDLE := Color(1.0, 1.0, 1.0, 0.75)
const AIM_LIVE := Color(1.0, 0.86, 0.45, 1.0)

var _world: VoxelWorld
var _player: Node3D
var _music: AmbientMusic
var _day: DayNight
## Hides the stats line and the control hints, on H. The interaction prompt
## stays up regardless - that is not debug output, it is how the player finds
## out what is under the crosshair.
var _debug_visible := true


func _ready() -> void:
	_world = get_node_or_null(world_path) as VoxelWorld
	_player = get_node_or_null(player_path) as Node3D
	_music = get_node_or_null(music_path) as AmbientMusic
	_day = get_node_or_null(sun_path) as DayNight


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_H:
			_debug_visible = not _debug_visible


func _process(_delta: float) -> void:
	if _world == null or _player == null:
		return
	var p := _player.global_position
	var hint := "WASD move   Shift sprint   Space jump / swim up   Ctrl dive   Mouse look   Esc release cursor"
	hint += "   PgUp/PgDn tide   Home reset tide   T go to ruins   F5 save   F9 load   H debug info"
	if _music != null:
		hint += "   M music: %s" % ("on" if _music.is_music_enabled() else "off")
	if _day != null:
		hint += "   P pause time"
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		hint = "Click into the window to capture the mouse and look around"

	var aim := _active_interactor()
	var prompt := "" if aim == null else aim.focus_prompt()
	if _crosshair != null:
		_crosshair.color = AIM_IDLE if prompt.is_empty() else AIM_LIVE
	if not _debug_visible:
		_label.text = "" if prompt.is_empty() else "[E] %s" % prompt
		return
	if not prompt.is_empty():
		hint = "[E] %s" % prompt
	# The tide reads as its offset from the datum the land was shaped around,
	# which is the number that means something: 0.0 is the island as generated.
	var tide := "tide %+.1f m" % _world.tide_offset()
	if not is_equal_approx(_world.water_level, _world.tide_target()):
		tide += " -> %+.1f" % (_world.tide_target() - VoxelDefs.SEA_DATUM)
	_label.text = "%d FPS   |   %s   |   %s   |   %s   |   XYZ %.1f / %.1f / %.1f   |   chunks %d\n%s" % [
		Engine.get_frames_per_second(),
		_world.biome_name_at(p),
		_day.clock_text() if _day != null else "--:--",
		tide,
		p.x, p.y, p.z,
		_world.loaded_chunks(),
		hint,
	]


## The interactor is found by group rather than by path, because XRMode swaps
## the whole player out and the XR rig brings its own. The desktop one is only
## queued for deletion during that swap, so for a frame there are two in the
## group and the disabled one has to be stepped over.
func _active_interactor() -> Interactor:
	for n in get_tree().get_nodes_in_group("interactor"):
		var it := n as Interactor
		if it != null and not it.is_queued_for_deletion() and it.can_process():
			return it
	return null
