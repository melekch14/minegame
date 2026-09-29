extends Node
## Developer tool (not gameplay): runs Game.tscn, drives the player with simulated input and
## saves screenshots + a movement log to res://_preview/player_*. Quits when done.
## Run scenes/player/debug/PlayerPreview.tscn.

const GAME := preload("res://scenes/game/Game.tscn")

var game: Node
var player: PlayerController


func _ready() -> void:
	game = GAME.instantiate()
	add_child(game)
	player = game.get_node("Player")
	var t0 := Time.get_ticks_msec()
	while not player.is_spawned:
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > 60000:
			push_error("PlayerPreview: player never spawned")
			get_tree().quit(1)
			return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # the real mouse must not steer the camera
	print("PLAYER spawned at %s after %d ms" % [player.global_position, Time.get_ticks_msec() - t0])
	await _wait(1.0)
	_log("idle")
	await _shot("player_01_idle")

	# Front close-up of the character.
	var rig := player.camera_rig
	rig.yaw = player.model.rotation.y + PI
	rig.pitch = deg_to_rad(-8.0)
	rig.distance = 2.6
	await _wait(1.0)
	await _shot("player_02_front")
	player.model.play_emote()
	await _wait(0.9)
	await _shot("player_03_wave")

	rig.yaw = 0.0
	rig.pitch = deg_to_rad(-15.0)
	rig.distance = 4.5
	Input.action_press("move_forward")
	await _wait(0.35)
	await _shot("player_04_walk")
	await _wait(1.5)
	_log("walked 1.85 s")
	Input.action_press("sprint")
	await _wait(1.5)
	_log("sprinted 1.5 s")
	Input.action_press("jump")
	await _wait(0.25)
	_log("jump +0.25 s")
	await _shot("player_05_jump")
	Input.action_release("jump")
	await _wait(1.0)
	_log("landed?")
	Input.action_release("sprint")
	Input.action_release("move_forward")

	# Walk into the start pond (southwest of the start in the world preview) to test swimming.
	rig.yaw = deg_to_rad(135.0)
	var start := player.global_position
	Input.action_press("move_forward")
	var swam := false
	for i in 400:
		await get_tree().physics_frame
		if player.is_swimming and not swam:
			swam = true
			_log("entered water")
	await _wait(0.5)
	Input.action_release("move_forward")
	_log("after water walk (%.1f m from start)" % player.global_position.distance_to(start))
	await _wait(0.8)
	await _shot("player_06_last")
	get_tree().quit()


func _log(label: String) -> void:
	var a := player.model.anim
	print("PLAYER %-22s pos=%s vel=%s floor=%s swim=%s anim=%s x%.2f ground_ready=%s" % [
		label, player.global_position.snapped(Vector3.ONE * 0.01), player.velocity.snapped(Vector3.ONE * 0.01),
		player.is_on_floor(), player.is_swimming, a.current_animation, a.speed_scale,
		player.world.is_ground_ready(player.global_position)])


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _shot(n: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://_preview/%s.png" % n)
