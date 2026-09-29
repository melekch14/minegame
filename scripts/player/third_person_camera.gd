class_name ThirdPersonCamera
extends Node3D
## Orbit camera for the player. Lives inside Player.tscn but is top_level, so it follows the
## player's position smoothly without inheriting its rotation.
##
##   CameraRig (this: yaw + pitch)
##   └── SpringArm3D  (pulls the camera in when terrain / cliffs are in the way)
##       └── Camera3D
##
## Mouse (captured) or right stick to orbit, wheel to zoom, Esc releases the mouse,
## click recaptures it.

## The node to follow (the player body).
@export var target_path: NodePath = ^".."
## Orbit pivot height above the target's origin (the player's feet).
@export var pivot_height := 1.5

@export_group("Distance")
@export var distance := 4.5
@export var min_distance := 1.5
@export var max_distance := 10.0
@export var zoom_step := 0.6

@export_group("Look")
## Radians per pixel of mouse movement.
@export var mouse_sensitivity := 0.0025
## Radians per second at full right-stick deflection.
@export var stick_sensitivity := 3.0
@export var invert_y := false
@export_range(-89.0, 0.0) var pitch_min_deg := -70.0
@export_range(0.0, 89.0) var pitch_max_deg := 40.0

## Stop drawing the character (PlayerModel.RENDER_LAYER) when an obstacle pulls the camera
## closer than this to the pivot. Its shadow is still drawn.
@export var hide_target_distance := 0.9

@export_group("Smoothing")
## Higher = the pivot catches up with the player faster.
@export var follow_sharpness := 20.0
@export var zoom_sharpness := 10.0

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D

var yaw := 0.0
var pitch := deg_to_rad(-15.0)
var _target: Node3D


func _ready() -> void:
	top_level = true
	# Moved in _process from the target's interpolated transform; interpolating it again would lag.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_target = get_node_or_null(target_path)
	if _target is CollisionObject3D:
		spring_arm.add_excluded_object((_target as CollisionObject3D).get_rid())
	spring_arm.spring_length = distance
	yaw = rotation.y
	snap_to_target()
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(min_distance, distance - zoom_step)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(max_distance, distance + zoom_step)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var rel := (event as InputEventMouseMotion).relative
		yaw -= rel.x * mouse_sensitivity
		pitch -= rel.y * mouse_sensitivity * (-1.0 if invert_y else 1.0)


func _process(delta: float) -> void:
	var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	yaw -= stick.x * stick_sensitivity * delta
	pitch -= stick.y * stick_sensitivity * delta * (-1.0 if invert_y else 1.0)
	pitch = clampf(pitch, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
	rotation = Vector3(pitch, yaw, 0.0)
	if _target:
		global_position = global_position.lerp(_pivot(), 1.0 - exp(-follow_sharpness * delta))
	spring_arm.spring_length = lerpf(spring_arm.spring_length, distance, 1.0 - exp(-zoom_sharpness * delta))
	camera.set_cull_mask_value(PlayerModel.RENDER_LAYER, spring_arm.get_hit_length() > hide_target_distance)


## Horizontal camera orientation; the controller moves relative to it.
func get_yaw_basis() -> Basis:
	return Basis(Vector3.UP, yaw)


## Jump straight to the target (after spawning / teleporting).
func snap_to_target() -> void:
	if _target:
		global_position = _pivot()


func _pivot() -> Vector3:
	return _target.get_global_transform_interpolated().origin + Vector3.UP * pivot_height
