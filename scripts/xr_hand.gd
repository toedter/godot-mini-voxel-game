class_name XRHand
extends Node3D

## The hand the player sees on a controller in XR, built the way the Godot XR
## Development Kit builds one: the kit's humanoid hand mesh rides the tracked
## pose at the grip, and a skeleton modifier on the hand's skeleton folds the
## fingers as the inputs come in. The index finger answers to the trigger, the
## other four to the grip, so a full fist needs both, which is how a real
## grab feels.
##
## Must be a child of an XRController3D tracking "left_hand" or "right_hand";
## the modifier walks up the tree to that node to find its tracker and which
## side of the head it is on, and picks the matching hand mesh here. Nothing
## about the pose is authored: the controller's pose is set to the grip in the
## rig, so the palm sits where the hand closes around a held object.

## The pose the fingers fold into as the inputs reach full.
@export var closed_finger_poses: GXDKFingerPoses
## The pose the fingers rest in while the inputs are out.
@export var open_finger_poses: GXDKFingerPoses
## The input that folds the index finger, and the one that folds the rest.
@export var trigger_action: StringName = &"trigger"
@export var grip_action: StringName = &"grab"


func _ready() -> void:
	var controller := get_parent() as XRController3D
	if controller == null:
		push_warning("XRHand needs an XRController3D parent")
		return
	var scene := _hand_scene(controller.tracker)
	if scene == null:
		return
	var hand := scene.instantiate()
	hand.name = "HandMesh"
	add_child(hand)
	var skeleton := _find_skeleton(hand)
	if skeleton == null:
		push_warning("No Skeleton3D found in the hand mesh")
		return
	var poses := GXDKFingerPosesModifier3D.new()
	poses.finger_poses = closed_finger_poses
	poses.open_finger_poses = open_finger_poses
	poses.trigger_action = String(trigger_action)
	poses.grip_action = String(grip_action)
	skeleton.add_child(poses)


func _hand_scene(tracker: StringName) -> PackedScene:
	if tracker == &"left_hand":
		return preload("res://addons/godot-xr-development-kit/hands/gltf/LeftHandHumanoid.gltf")
	elif tracker == &"right_hand":
		return preload("res://addons/godot-xr-development-kit/hands/gltf/RightHandHumanoid.gltf")
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null
