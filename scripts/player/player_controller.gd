class_name PlayerController
extends CharacterBody3D
## Third-person player: camera-relative movement, sprint, jump (coyote time + input buffer),
## swimming at the world's water level, plus the guards a streamed world needs:
##   * waits for the chunk under the spawn point to have collision before dropping in,
##   * freezes in place if the ground under it isn't streamed in yet,
##   * puts itself back on the surface if it ever falls out of the world.
## The World is assigned by the owning scene (see scripts/game/game.gd).

signal spawned

@export_group("Movement")
@export var walk_speed := 4.0
@export var sprint_speed := 7.5
## m/s² while speeding up / slowing down on the ground.
@export var acceleration := 30.0
@export var deceleration := 40.0
## Fraction of ground acceleration available in the air.
@export_range(0.0, 1.0) var air_control := 0.35
## How quickly the model turns to face the movement direction.
@export var turn_sharpness := 12.0

@export_group("Jump")
## Apex height (m). Terrain levels are 2 m, so the default clears a single cliff step.
@export var jump_height := 2.3
## Seconds from take-off to apex; together with jump_height this defines gravity.
@export var time_to_apex := 0.42
## Extra gravity while falling or after releasing jump early (shorter hops).
@export var fall_gravity_multiplier := 1.7
@export var max_fall_speed := 40.0
## Jump still allowed this long after walking off a ledge.
@export var coyote_time := 0.12
## A jump pressed this long before landing still fires on touchdown.
@export var jump_buffer_time := 0.12

@export_group("Swimming")
@export var swim_speed := 3.0
## How far below the water surface the feet float.
@export var float_depth := 1.3
@export var buoyancy := 14.0
@export var water_drag := 4.0
## Jump strength out of the water, relative to a normal jump.
@export_range(0.0, 1.0) var water_jump_factor := 0.9

@export_group("World")
## Only X/Z are used: the height comes from the terrain.
@export var spawn_position := Vector3.ZERO
## Below this height the player is put back on the surface.
@export var respawn_below_y := -30.0

@onready var model: PlayerModel = $Model
@onready var camera_rig: ThirdPersonCamera = $CameraRig

var world: World
var is_swimming := false
var is_spawned := false

var _gravity: float
var _jump_velocity: float
var _coyote := 0.0
var _jump_buffer := 0.0


func _ready() -> void:
	PlayerInput.ensure_actions()
	_gravity = 2.0 * jump_height / (time_to_apex * time_to_apex)
	_jump_velocity = 2.0 * jump_height / time_to_apex
	global_position = Vector3(spawn_position.x, 0.0, spawn_position.z)
	model.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if is_spawned and event.is_action_pressed("emote") and is_on_floor() and _horizontal_speed() < 0.3:
		model.play_emote()


func _physics_process(delta: float) -> void:
	if world == null:
		return
	if not is_spawned:
		_try_spawn()
		return
	if not world.is_ground_ready(global_position):
		# Collision under us isn't streamed in yet: hold still rather than fall through.
		velocity = Vector3.ZERO
		return

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := camera_rig.get_yaw_basis() * Vector3(input.x, 0.0, input.y)

	_update_water_state()
	if is_swimming:
		_swim(delta, dir)
	else:
		_walk(delta, dir)
	move_and_slide()

	if global_position.y < respawn_below_y:
		push_warning("Player fell out of the world at %s; respawning on the surface." % global_position)
		if not _place_on_surface(global_position):
			global_position.y = world.get_surface_height(global_position) + 1.0
			velocity = Vector3.ZERO

	if dir.length_squared() > 0.01:
		var target_yaw := atan2(-dir.x, -dir.z)
		model.rotation.y = lerp_angle(model.rotation.y, target_yaw, 1.0 - exp(-turn_sharpness * delta))
	model.update_locomotion(_horizontal_speed(), is_on_floor(), is_swimming)


# --- ground / air ---------------------------------------------------------

func _walk(delta: float, dir: Vector3) -> void:
	var on_floor := is_on_floor()
	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	var h := Vector3(velocity.x, 0.0, velocity.z)
	var rate := acceleration if dir != Vector3.ZERO else deceleration
	if not on_floor:
		rate *= air_control
	h = h.move_toward(dir * speed, rate * delta)

	_coyote = coyote_time if on_floor else _coyote - delta
	_jump_buffer = jump_buffer_time if Input.is_action_just_pressed("jump") else _jump_buffer - delta

	var vy := velocity.y
	if _jump_buffer > 0.0 and _coyote > 0.0:
		vy = _jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0
	elif not on_floor:
		var g := _gravity
		if vy < 0.0 or not Input.is_action_pressed("jump"):
			g *= fall_gravity_multiplier
		vy = maxf(vy - g * delta, -max_fall_speed)
	velocity = Vector3(h.x, vy, h.z)


# --- water ----------------------------------------------------------------

## The world has a single water plane; any spot deeper than float_depth is swimmable.
func _update_water_state() -> void:
	var depth := world.get_water_height() - global_position.y
	# Only sink back into swimming when not rising, so a jump out of the water isn't cancelled.
	if not is_swimming and depth > float_depth + 0.1 and velocity.y <= 0.0:
		is_swimming = true
		_coyote = 0.0
	elif is_swimming and depth < float_depth - 0.35:
		is_swimming = false


func _swim(delta: float, dir: Vector3) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z).move_toward(dir * swim_speed, acceleration * 0.5 * delta)
	var depth := world.get_water_height() - global_position.y
	# Damped spring towards floating height.
	var vy := velocity.y + (depth - float_depth) * buoyancy * delta
	vy *= exp(-water_drag * delta)
	if Input.is_action_just_pressed("jump") and absf(depth - float_depth) < 0.4:
		vy = _jump_velocity * water_jump_factor
		is_swimming = false
	velocity = Vector3(h.x, vy, h.z)


# --- spawning -------------------------------------------------------------

func _try_spawn() -> void:
	var p := Vector3(spawn_position.x, 0.0, spawn_position.z)
	if not world.is_ground_ready(p) or not _place_on_surface(p):
		return  # retried next physics frame while the world streams in
	is_spawned = true
	model.visible = true
	camera_rig.snap_to_target()
	spawned.emit()


## Raycasts down onto the terrain collision at p.xz. False if nothing was hit (yet).
func _place_on_surface(p: Vector3) -> bool:
	var top := world.get_surface_height(p) + 40.0
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, top, p.z), Vector3(p.x, -10.0, p.z), collision_mask)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	global_position = hit.position + Vector3.UP * 0.05
	velocity = Vector3.ZERO
	reset_physics_interpolation()
	return true


func _horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()
