class_name ChunkManager
extends Node3D
## Streams chunks around a center point.
##   distance <= detail radius  -> NEAR chunk (real Blender assets, collision)
##   distance <= active radius  -> FAR chunk  (lightweight LOD mesh + tree silhouettes)
##   beyond active + hysteresis -> unloaded (node freed; regenerates identically later)
## Data generation runs on WorkerThreadPool; node creation is budgeted per frame.

signal chunk_loaded(coord: Vector2i, lod: int)
signal chunk_unloaded(coord: Vector2i)
## Emitted once every desired chunk is built at its desired LOD.
signal streaming_idle

const WORLD_CHUNK_SCENE := preload("res://scenes/world/WorldChunk.tscn")

var config: WorldGenerationConfig
var generator: WorldGenerator
var assets: WorldAssetLibrary
var chunks_root: Node3D

var center := Vector3.ZERO
var _center_chunk := Vector2i(2147483647, 0)
var _chunks: Dictionary = {}      # Vector2i -> WorldChunk
var _desired: Dictionary = {}     # Vector2i -> lod
var _jobs: Dictionary = {}        # Vector2i -> {task:int, lod:int}
var _results: Array = []          # finished payloads waiting for the main thread
var _mutex := Mutex.new()
var _was_idle := false
var _stats := {"generated": 0, "gen_ms": 0.0, "mesh_ms": 0.0}


func setup(p_config: WorldGenerationConfig, p_gen: WorldGenerator, p_assets: WorldAssetLibrary, p_root: Node3D) -> void:
	config = p_config
	generator = p_gen
	assets = p_assets
	chunks_root = p_root


## Call every frame (or whenever the tracked position moves). Later: the player position.
func set_center(p: Vector3) -> void:
	center = p
	var c := generator.coords.world_to_chunk(p)
	if c != _center_chunk:
		_center_chunk = c
		_refresh_desired()


func _refresh_desired() -> void:
	_desired.clear()
	var r := config.active_chunk_radius
	var rd := config.detail_chunk_radius
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var dist := sqrt(float(dx * dx + dz * dz))
			if dist > r + 0.5:
				continue
			var lod := ChunkMesher.Lod.NEAR if dist <= rd + 0.5 else ChunkMesher.Lod.FAR
			_desired[_center_chunk + Vector2i(dx, dz)] = lod
	# Unload chunks well outside the active radius. Detailed chunks that drifted out of
	# the detail radius are dropped too, so they rebuild as cheap LOD chunks.
	var limit := r + 0.5 + config.unload_hysteresis
	var near_limit := rd + 0.5 + config.unload_hysteresis
	for c in _chunks.keys():
		var dd := Vector2(c - _center_chunk).length()
		var ch: WorldChunk = _chunks[c]
		if dd > limit or (ch.lod == ChunkMesher.Lod.NEAR and dd > near_limit and _desired.get(c, -1) != ChunkMesher.Lod.NEAR):
			_chunks[c].queue_free()
			_chunks.erase(c)
			chunk_unloaded.emit(c)
	_was_idle = false


func _process(_delta: float) -> void:
	if generator == null:
		return
	_collect_finished()
	_apply_results()
	_schedule_jobs()
	var idle := _jobs.is_empty() and _results.is_empty() and _pending_count() == 0
	if idle and not _was_idle:
		_was_idle = true
		streaming_idle.emit()


func _pending_count() -> int:
	var n := 0
	for c in _desired:
		var ch: WorldChunk = _chunks.get(c)
		if ch == null or ch.lod != _desired[c]:
			n += 1
	return n


func _schedule_jobs() -> void:
	if _jobs.size() >= config.max_concurrent_jobs:
		return
	# Nearest first.
	var todo: Array = []
	for c in _desired:
		if _jobs.has(c):
			continue
		var ch: WorldChunk = _chunks.get(c)
		if ch != null and ch.lod == _desired[c]:
			continue
		todo.append(c)
	if todo.is_empty():
		return
	var cc := _center_chunk
	todo.sort_custom(func(a, b): return (a - cc).length_squared() < (b - cc).length_squared())
	for c in todo:
		if _jobs.size() >= config.max_concurrent_jobs:
			break
		var lod: int = _desired[c]
		var task := WorkerThreadPool.add_task(_job.bind(c, lod), false, "chunk %s" % [c])
		_jobs[c] = {"task": task, "lod": lod}


func _job(c: Vector2i, lod: int) -> void:
	var res := generator.generate_chunk(c, lod)
	_mutex.lock()
	_results.append(res)
	_mutex.unlock()


func _collect_finished() -> void:
	for c in _jobs.keys():
		var j: Dictionary = _jobs[c]
		if WorkerThreadPool.is_task_completed(j.task):
			WorkerThreadPool.wait_for_task_completion(j.task)
			_jobs.erase(c)


func _apply_results() -> void:
	_mutex.lock()
	var batch := _results
	_results = []
	_mutex.unlock()
	var built := 0
	var leftover: Array = []
	for res in batch:
		if built >= config.max_chunk_builds_per_frame:
			leftover.append(res)
			continue
		var c: Vector2i = res.coord
		if not _desired.has(c) or _desired[c] != res.lod:
			continue  # became obsolete while generating
		var ch: WorldChunk = _chunks.get(c)
		if ch == null:
			ch = WORLD_CHUNK_SCENE.instantiate()
			ch.name = "Chunk_%d_%d" % [c.x, c.y]
			ch.position = generator.coords.chunk_to_world(c)
			chunks_root.add_child(ch)
			_chunks[c] = ch
		ch.apply(res, assets, config)
		built += 1
		_stats.generated += 1
		_stats.gen_ms += res.timing_ms.x
		_stats.mesh_ms += res.timing_ms.y
		if config.log_chunk_timings:
			print("chunk %s lod %d: data %.1f ms, mesh %.1f ms" % [c, res.lod, res.timing_ms.x, res.timing_ms.y])
		chunk_loaded.emit(c, res.lod)
	if not leftover.is_empty():
		_mutex.lock()
		_results = leftover + _results
		_mutex.unlock()


func is_idle() -> bool:
	return _was_idle


func get_chunk(c: Vector2i) -> WorldChunk:
	return _chunks.get(c)


func loaded_chunk_count() -> int:
	return _chunks.size()


func get_stats() -> Dictionary:
	var s := _stats.duplicate()
	s["loaded"] = _chunks.size()
	s["jobs"] = _jobs.size()
	return s


## Rebuild one chunk (e.g. after WorldModifications changed it).
func invalidate_chunk(c: Vector2i) -> void:
	var ch: WorldChunk = _chunks.get(c)
	if ch:
		ch.lod = -1
	_was_idle = false


func _exit_tree() -> void:
	for c in _jobs:
		WorkerThreadPool.wait_for_task_completion(_jobs[c].task)
	_jobs.clear()
