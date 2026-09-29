extends Node3D
## Developer tool (not gameplay): flies a static camera through fixed viewpoints, lets the
## world stream in around each one, and saves screenshots to res://_preview/.
## Run scenes/world/debug/WorldPreview.tscn. Quits automatically when done.

const VIEWS := [
	# name, streaming focus (m), camera position (m, y = height above ground), look-at (m, y above ground)
	{"name": "01_overview", "focus": Vector3(40, 0, -40), "cam": Vector3(-150, 150, 250), "abs": true, "look": Vector3(60, 0, -80)},
	{"name": "02_start_meadow", "focus": Vector3(0, 0, 0), "cam": Vector3(-26, 2.4, 44), "look": Vector3(70, 3, -90)},
	{"name": "03_start_pond", "focus": Vector3(0, 0, 0), "cam": Vector3(18, 5, -14), "look": Vector3(-48, 0, 36)},
	{"name": "04_east_lake", "focus": Vector3(180, 0, 20), "cam": Vector3(128, 7, 78), "look": Vector3(200, 0, 0)},
	{"name": "05_north_forest", "focus": Vector3(0, 0, -170), "cam": Vector3(14, 4, -120), "look": Vector3(-10, 6, -230)},
	{"name": "06_ne_highlands", "focus": Vector3(170, 0, -160), "cam": Vector3(110, 22, -90), "look": Vector3(215, 10, -215)},
	{"name": "07_west_rocky", "focus": Vector3(-190, 0, 0), "cam": Vector3(-140, 14, 46), "look": Vector3(-250, 8, -20)},
	{"name": "08_se_river", "focus": Vector3(250, 0, 170), "cam": Vector3(212, 20, 104), "look": Vector3(300, 0, 232)},
	{"name": "09_top_down", "focus": Vector3(40, 0, 0), "top": true, "env": {"fog_enabled": false}},
]

@export var world_path: NodePath = ^"World"
@export var camera_path: NodePath = ^"Camera3D"
## Only capture these view names (empty = all). Handy when iterating on one area.
@export var only_views: PackedStringArray = []
## Extra diagnostic views appended to VIEWS, same format plus optional
## "env": {property: value} overrides and "lod_threshold": float.
@export var extra_views: Array[Dictionary] = []
@export var settle_frames := 20
@export var timeout_s := 90.0


func _ready() -> void:
	var world: World = get_node(world_path)
	var cam: Camera3D = get_node(camera_path)
	cam.current = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_preview"))
	await get_tree().process_frame
	var env: Environment = world.get_node("WorldEnvironment").environment
	for v in VIEWS + extra_views:
		if not only_views.is_empty() and not only_views.has(v.name):
			continue
		var env_backup := {}
		for k in v.get("env", {}):
			env_backup[k] = env.get(k)
			env.set(k, v.env[k])
		get_viewport().mesh_lod_threshold = v.get("lod_threshold", 1.0)
		get_viewport().debug_draw = v.get("debug_draw", Viewport.DEBUG_DRAW_DISABLED)
		world.world_center = v.focus
		await _wait_idle(world)
		if v.get("top", false):
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = 700.0
			cam.far = 1200.0
			cam.look_at_from_position(v.focus + Vector3(0, 500, 0.01), v.focus, Vector3.FORWARD)
		else:
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = 70.0
			cam.far = 2000.0
			var p: Vector3 = v.cam
			var l: Vector3 = v.look
			if not v.get("abs", false):
				p = _clear_spot(world, p)
				p.y += world.get_surface_height(p)
				l.y += world.get_surface_height(l)
			cam.look_at_from_position(p, l, Vector3.UP)
		for i in settle_frames:
			await get_tree().process_frame
		# Steady-state frame time over ~1.5 s once streaming is idle.
		var t0 := Time.get_ticks_usec()
		var frames := 0
		while Time.get_ticks_usec() - t0 < 1500000:
			await get_tree().process_frame
			frames += 1
		var avg_fps := frames / ((Time.get_ticks_usec() - t0) / 1000000.0)
		var img := get_viewport().get_texture().get_image()
		var path := "res://_preview/%s.png" % v.name
		img.save_png(path)
		for k in env_backup:
			env.set(k, env_backup[k])
		var st := world.chunk_manager.get_stats()
		print("PREVIEW saved %s  avg_fps=%.0f  chunks=%d  draw_calls=%d  prims=%d" % [
			path, avg_fps, st.loaded,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	print("PREVIEW done. gen stats: ", world.chunk_manager.get_stats())
	get_tree().quit()


## Nudge an eye-level camera away from trees/rocks so it never starts inside one.
func _clear_spot(world: World, p: Vector3) -> Vector3:
	for attempt in 24:
		var blocked := false
		var ch := world.chunk_manager.get_chunk(world.generator.coords.world_to_chunk(p))
		if ch and ch.data:
			for key in ch.data.props:
				for o in ch.data.props[key]:
					var op: Vector3 = o.xform.origin
					if Vector2(op.x - p.x, op.z - p.z).length() < (4.0 if key.begins_with("tree") else 2.0):
						blocked = true
						break
				if blocked:
					break
		if not blocked:
			return p
		p += Vector3(3.0, 0, 0).rotated(Vector3.UP, attempt * 0.9)
	return p


func _wait_idle(world: World) -> void:
	var t := 0.0
	await get_tree().process_frame
	await get_tree().process_frame
	while not world.chunk_manager.is_idle() and t < timeout_s:
		await get_tree().process_frame
		t += get_process_delta_time()
