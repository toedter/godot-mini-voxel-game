class_name AmbientMusic
extends AudioStreamPlayer

## Procedurally synthesised ambient background music.
##
## A slow chord pad drifts through a four chord progression in A minor while
## occasional soft bell notes are picked from a pentatonic scale. Everything is
## generated at runtime, so there is no audio asset and the music never loops
## exactly the same way twice.

@export var music_volume_db := -13.0
@export var mix_rate := 16000.0
## Seconds each chord is held before the pad drifts into the next one.
@export var chord_seconds := 11.0
@export var fade_in_seconds := 4.0

## Chords as MIDI note numbers: Am7 - Fmaj7 - Cmaj7 - Gsus2.
const PROGRESSION := [
	[45, 52, 57, 60, 64, 67],
	[41, 48, 53, 57, 60, 64],
	[48, 55, 60, 64, 67, 71],
	[43, 50, 55, 59, 62, 69],
]
## A minor pentatonic, used for the bell melody.
const MELODY_NOTES := [69, 72, 74, 76, 79, 81, 84]

const BUS_NAME := "Music"
const TAU_F := TAU
## Sine lookup table. 8192 entries keep the quantisation noise below -75 dB,
## which is inaudible under a pad, and a table read is far cheaper in GDScript
## than a sin() call per voice per sample.
const TABLE_BITS := 13
const TABLE_SIZE := 1 << TABLE_BITS
const TABLE_MASK := TABLE_SIZE - 1

static var _sine := _build_sine()

var _playback: AudioStreamGeneratorPlayback

# Voices are kept as parallel flat arrays instead of an array of dictionaries:
# the synthesis loop then works on plain local floats.
var _v_phase := PackedFloat32Array()
var _v_step := PackedFloat32Array()
var _v_amp := PackedFloat32Array()
var _v_target := PackedFloat32Array()
var _v_pan := PackedFloat32Array()

var _mix_l := PackedFloat32Array()
var _mix_r := PackedFloat32Array()

var _bell_amp := 0.0
var _bell_phase := 0.0
var _bell_step := 0.0
var _bell_decay := 0.0
var _rng := RandomNumberGenerator.new()


static func _build_sine() -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(TABLE_SIZE)
	for i in TABLE_SIZE:
		t[i] = sin(TAU * float(i) / float(TABLE_SIZE))
	return t

var _time := 0.0
var _chord_index := -1
var _next_bell := 5.0
var _master := 0.0
var _lp_l := 0.0
var _lp_r := 0.0
var _enabled := true


func _ready() -> void:
	_rng.randomize()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = mix_rate
	gen.buffer_length = 1.0
	stream = gen
	bus = _ensure_bus()
	volume_db = music_volume_db
	autoplay = false
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback
	_advance_chord()
	# Fill the buffer straight away so the loading hitch of the first frames
	# cannot starve the audio thread.
	if _playback != null:
		_playback.push_buffer(render(_playback.get_frames_available()))


func _ensure_bus() -> String:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx != -1:
		return BUS_NAME
	idx = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, BUS_NAME)
	AudioServer.set_bus_send(idx, "Master")

	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.88
	reverb.damping = 0.65
	reverb.spread = 1.0
	reverb.wet = 0.42
	reverb.dry = 0.75
	AudioServer.add_bus_effect(idx, reverb)

	var lowpass := AudioEffectLowPassFilter.new()
	lowpass.cutoff_hz = 2600.0
	AudioServer.add_bus_effect(idx, lowpass)
	return BUS_NAME


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_M:
			set_music_enabled(not _enabled)


func set_music_enabled(on: bool) -> void:
	_enabled = on


func is_music_enabled() -> bool:
	return _enabled


func _process(_delta: float) -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	if frames > 0:
		_playback.push_buffer(render(frames))


# --------------------------------------------------------------------------
# synthesis
# --------------------------------------------------------------------------

static func note_hz(midi: int) -> float:
	return 440.0 * pow(2.0, (float(midi) - 69.0) / 12.0)


func _advance_chord() -> void:
	_chord_index += 1
	var chord: Array = PROGRESSION[_chord_index % PROGRESSION.size()]
	for i in _v_target.size():
		_v_target[i] = 0.0
	for i in chord.size():
		var midi: int = chord[i]
		# a few cents of detune keeps the pad from sounding sterile
		var cents := _rng.randf_range(-6.0, 6.0)
		var hz := note_hz(midi) * pow(2.0, cents / 1200.0)
		var gain := 0.16 if midi < 55 else 0.10
		_v_phase.append(_rng.randf() * TAU_F)
		_v_step.append(TAU_F * hz / mix_rate)
		_v_amp.append(0.0)
		_v_target.append(gain)
		_v_pan.append(clampf(0.5 + (float(i) / float(chord.size() - 1) - 0.5) * 0.8, 0.0, 1.0))


func _trigger_bell() -> void:
	var midi: int = MELODY_NOTES[_rng.randi_range(0, MELODY_NOTES.size() - 1)]
	_bell_step = TAU_F * note_hz(midi) / mix_rate
	_bell_phase = 0.0
	_bell_amp = _rng.randf_range(0.06, 0.11)
	_bell_decay = exp(-1.0 / (mix_rate * _rng.randf_range(1.6, 3.2)))
	_next_bell = _time + _rng.randf_range(3.5, 9.0)


## Renders `frames` stereo samples. Kept separate from _process so it can be
## exercised without an audio device.
##
## Voices are summed one at a time over the whole block rather than all voices
## per sample, which keeps every oscillator variable in a local float.
func render(frames: int) -> PackedVector2Array:
	if frames <= 0:
		return PackedVector2Array()

	var block := float(frames) / mix_rate

	# Musical events are seconds apart, so scheduling them once per block
	# (a few milliseconds of granularity) is plenty.
	if _time >= float(_chord_index + 1) * chord_seconds:
		_advance_chord()
	if _time >= _next_bell:
		_trigger_bell()

	if _mix_l.size() != frames:
		_mix_l.resize(frames)
		_mix_r.resize(frames)
	_mix_l.fill(0.0)
	_mix_r.fill(0.0)

	var table := _sine
	var to_index := float(TABLE_SIZE) / TAU_F
	# ~4 second attack / release on the pad voices
	var env_coef := 1.0 - exp(-1.0 / (mix_rate * 4.0))

	for v in _v_phase.size():
		var amp := float(_v_amp[v])
		var target := float(_v_target[v])
		if amp < 0.00005 and target <= 0.0:
			continue
		var phase := float(_v_phase[v])
		var step := float(_v_step[v])
		var pan := float(_v_pan[v])
		var gl := 1.0 - pan
		var gr := pan
		for i in frames:
			amp += (target - amp) * env_coef
			phase += step
			if phase >= TAU_F:
				phase -= TAU_F
			var s := table[int(phase * to_index) & TABLE_MASK] * amp
			_mix_l[i] += s * gl
			_mix_r[i] += s * gr
		_v_phase[v] = phase
		_v_amp[v] = amp

	if _bell_amp > 0.00005:
		var bamp := _bell_amp
		var bphase := _bell_phase
		for i in frames:
			bphase += _bell_step
			if bphase >= TAU_F:
				bphase -= TAU_F
			bamp *= _bell_decay
			var bs := table[int(bphase * to_index) & TABLE_MASK] * bamp * 0.6
			_mix_l[i] += bs
			_mix_r[i] += bs
		_bell_phase = bphase
		_bell_amp = bamp

	# The master fade and the slow "breath" swell move only a hair per block,
	# so they are ramped linearly across it instead of recomputed per sample.
	var gain := _master * (0.86 + 0.14 * sin(_time * 0.19))
	_master = move_toward(_master, 1.0 if _enabled else 0.0, block / maxf(fade_in_seconds, 0.001))
	var gain_end := _master * (0.86 + 0.14 * sin((_time + block) * 0.19))
	var gain_step := (gain_end - gain) / float(frames)

	# gentle one pole low pass to take the edge off
	var lp_coef := 1.0 - exp(-TAU_F * 1800.0 / mix_rate)
	var lp_l := _lp_l
	var lp_r := _lp_r
	var buf := PackedVector2Array()
	buf.resize(frames)
	for i in frames:
		lp_l += (_mix_l[i] * gain - lp_l) * lp_coef
		lp_r += (_mix_r[i] * gain - lp_r) * lp_coef
		gain += gain_step
		buf[i] = Vector2(clampf(lp_l, -1.0, 1.0), clampf(lp_r, -1.0, 1.0))
	_lp_l = lp_l
	_lp_r = lp_r

	_time += block
	_retire_voices()
	return buf


func _retire_voices() -> void:
	var write := 0
	for i in _v_phase.size():
		if _v_target[i] > 0.0 or _v_amp[i] > 0.0005:
			if write != i:
				_v_phase[write] = _v_phase[i]
				_v_step[write] = _v_step[i]
				_v_amp[write] = _v_amp[i]
				_v_target[write] = _v_target[i]
				_v_pan[write] = _v_pan[i]
			write += 1
	if write != _v_phase.size():
		_v_phase.resize(write)
		_v_step.resize(write)
		_v_amp.resize(write)
		_v_target.resize(write)
		_v_pan.resize(write)
