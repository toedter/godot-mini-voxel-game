class_name DayNight
extends DirectionalLight3D

## Drives the sun and the moon, and provides the sky palette for that time.
##
## This node only moves and colours the light. Everything that is painted with
## the palette (sky material, ambient level, distance haze) is applied by
## Atmosphere, which owns the Environment, so there is exactly one writer per
## property.

## Seconds for a full 24 hour cycle.
@export var day_length: float = 300.0
## 0 is midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
@export_range(0.0, 1.0, 0.001) var start_time: float = 0.3
@export var paused: bool = false
## Tilt of the sun's arc. Keeps the sun off the zenith, which both looks better
## and stops the light direction from lining up with the world up axis.
@export_range(5.0, 80.0, 1.0) var arc_tilt: float = 35.0
@export var sun_energy: float = 0.9
@export var moon_energy: float = 0.16
## How far a single manual nudge moves the sun/moon along their arc: 1/48 of a
## day is half an hour. Mirrors VoxelWorld's tide_step - a debug control today,
## and the same knob a future mechanic keyed off light (crop growth, something
## that only comes out at night) would want to drive directly.
@export_range(0.001, 0.25, 0.001) var time_step: float = 1.0 / 48.0

const DAY_TOP := Color(0.25, 0.48, 0.9)
const DAY_HORIZON := Color(0.72, 0.83, 0.93)
const DUSK_TOP := Color(0.22, 0.26, 0.5)
const DUSK_HORIZON := Color(0.93, 0.56, 0.31)
const NIGHT_TOP := Color(0.015, 0.025, 0.07)
const NIGHT_HORIZON := Color(0.05, 0.07, 0.16)

const SUN_TINT := Color(1.0, 0.97, 0.9)
const DUSK_TINT := Color(1.0, 0.6, 0.34)
const MOON_TINT := Color(0.55, 0.68, 1.0)

var time_of_day: float = 0.0
## Sine of the sun's elevation: 1 at the zenith, 0 at the horizon, negative at
## night. Everything else is derived from this.
var sun_height: float = 0.0


func _ready() -> void:
	add_to_group("savable")
	set_time_of_day(start_time)


func _process(delta: float) -> void:
	if paused or day_length <= 0.0:
		return
	time_of_day = fposmod(time_of_day + delta / day_length, 1.0)
	_apply()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	match (event as InputEventKey).keycode:
		KEY_P:
			paused = not paused
		KEY_BRACKETRIGHT:
			set_time_of_day(time_of_day + time_step)
		KEY_BRACKETLEFT:
			set_time_of_day(time_of_day - time_step)
		KEY_END:
			set_time_of_day(start_time)


## Jumps the sun (and its anti-solar moon) straight to a time of day, wrapped
## to a single cycle. Used by manual scrubbing, by the reset key and by a
## restored save; the automatic advance in _process picks up smoothly from
## wherever this leaves it.
func set_time_of_day(t: float) -> void:
	time_of_day = fposmod(t, 1.0)
	_apply()


func _apply() -> void:
	var ang := TAU * (time_of_day - 0.25)
	var tilt := deg_to_rad(arc_tilt)
	var sun_pos := Vector3(cos(ang), sin(ang) * cos(tilt), -sin(ang) * sin(tilt)).normalized()
	sun_height = sun_pos.y

	var lit := smoothstep(-0.02, 0.22, sun_height)
	var e_sun := sun_energy * lit
	var e_moon := moon_energy * (1.0 - smoothstep(-0.12, 0.04, sun_height))
	# The light swaps from the sun to the anti-solar point for moonlight. Both
	# energies are near zero while that happens, so the swap is not visible.
	var to_sun := e_sun >= e_moon
	look_at(global_position + (-sun_pos if to_sun else sun_pos), Vector3.UP)
	light_energy = maxf(e_sun, e_moon)
	# Near the horizon a tree casts a shadow tens of metres long, so casters
	# outside the streamed radius would throw shadows into view and pop in with
	# their chunk. Fading the shadows out while the light is low both hides that
	# and matches how diffuse low light actually is.
	var caster_height := sun_height if to_sun else -sun_height
	shadow_opacity = smoothstep(0.04, 0.30, caster_height)
	if to_sun:
		# the lower the sun, the warmer its light
		light_color = SUN_TINT.lerp(DUSK_TINT, clampf(1.0 - sun_height / 0.3, 0.0, 1.0))
	else:
		light_color = MOON_TINT


func sky_top_color() -> Color:
	return _palette(NIGHT_TOP, DUSK_TOP, DAY_TOP)


func horizon_color() -> Color:
	return _palette(NIGHT_HORIZON, DUSK_HORIZON, DAY_HORIZON)


func ambient_energy() -> float:
	return lerpf(0.06, 0.35, smoothstep(-0.05, 0.25, sun_height))


## How strongly the mushroom caps light up. They start catching on as the sun
## goes down and are at full strength once it is properly dark, which is a wider
## window than the sky fade so the glow appears gradually during dusk.
func glow_amount() -> float:
	return 1.0 - smoothstep(-0.18, 0.16, sun_height)


func clock_text() -> String:
	var minutes := int(round(time_of_day * 1440.0)) % 1440
	return "%02d:%02d" % [minutes / 60, minutes % 60]


## Fades night to day, then lays the sunrise/sunset colour over the result
## while the sun is close to the horizon.
func _palette(night: Color, dusk: Color, day: Color) -> Color:
	var lit := smoothstep(-0.02, 0.25, sun_height)
	var low := clampf(1.0 - absf(sun_height) / 0.18, 0.0, 1.0)
	return night.lerp(day, lit).lerp(dusk, low)


func save_state() -> Dictionary:
	return {"time": time_of_day, "paused": paused}


func load_state(d: Dictionary) -> void:
	set_time_of_day(float(d.get("time", start_time)))
	paused = bool(d.get("paused", false))
