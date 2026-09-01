class_name Interactable
extends StaticBody3D

## Something the player can look at and use.
##
## The verb is deliberately narrow: point at it, press the button. That is the
## one thing a flat mouse and an XR controller can both do naturally, so every
## puzzle built out of Interactables works in both modes without a second
## design. Anything needing a gesture, a drag or two hands does not belong here.
##
## Interactables sit on their own collision layer as well as the world one, so
## the Interactor's ray can ask for them specifically while still being stopped
## by terrain: you cannot use a lock through a hill.

## Physics layer interactables answer on. Layer 1 is the world (terrain and
## bodies), layer 3 is reserved for things that can be used.
const LAYER_WORLD := 1
const LAYER_INTERACTABLE := 4

## Shown floating over the object while it is focused, and in the flat HUD.
## Phrased as the verb the player is about to perform.
@export var prompt: String = "Use"
## Whether the prompt label is drawn over the object. The label is what makes
## this readable in XR, where there is no screen to put a HUD line on.
@export var show_label: bool = true
## Height (m) above the object's origin the label floats at.
@export var label_height: float = 0.9

## Fires when the player uses this. `actor` is the Interactor that did it.
signal used(actor: Node3D)

var _label: Label3D
var _focused := false


func _ready() -> void:
	collision_layer = LAYER_WORLD | LAYER_INTERACTABLE
	add_to_group("interactable")
	if show_label:
		_label = Label3D.new()
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = true
		_label.pixel_size = 0.0012
		_label.modulate = Color(1.0, 0.96, 0.85)
		_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
		_label.outline_size = 10
		_label.position = Vector3.UP * label_height
		_label.visible = false
		add_child(_label)


## Called by the Interactor when the player looks at or away from this.
func set_focused(on: bool) -> void:
	if _focused == on:
		return
	_focused = on
	if _label != null:
		_label.text = prompt
		_label.visible = on
	_on_focus(on)


func is_focused() -> bool:
	return _focused


## Refreshes the floating label, for when the prompt changes while focused.
func refresh_prompt() -> void:
	if _label != null and _focused:
		_label.text = prompt


## Entry point for the Interactor. Subclasses override `_on_use`.
func use(actor: Node3D) -> void:
	_on_use(actor)
	used.emit(actor)
	refresh_prompt()


## Override: what this thing does when used.
func _on_use(_actor: Node3D) -> void:
	pass


## Override: react to being looked at, for a highlight or a sound.
func _on_focus(_on: bool) -> void:
	pass
