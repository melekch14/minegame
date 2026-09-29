class_name World
extends Node3D
## Root of the open world. Wires the config, generator and chunk streaming together.
## The streaming center is `world_center`, or `streaming_target`'s position when set —
## scenes/game/Game.tscn puts the player in `streaming_target` so the world follows it.

@export var config: WorldGenerationConfig
## Where streaming is centred while there is no player.
@export var world_center := Vector3.ZERO
## Optional node to follow (the player). Overrides world_center.
@export var streaming_target: Node3D
## Optional persistent changes (destroyed trees, terrain edits...).
@export var modifications: WorldModifications

@onready var generator: WorldGenerator = $WorldGenerator
@onready var chunk_manager: ChunkManager = $ChunkManager
@onready var chunks_root: Node3D = $Chunks

var assets := WorldAssetLibrary.new()


func _ready() -> void:
	if config == null:
		config = load("res://resources/world/world_generation_config.tres")
	if modifications == null:
		modifications = WorldModifications.new()
		modifications.world_seed = config.world_seed
	modifications.chunk_modified.connect(_on_chunk_modified)
	if not assets.load_all(config):
		push_error("World: some Blender assets failed to load; see errors above.")
	generator.setup(config, modifications)
	chunk_manager.setup(config, generator, assets, chunks_root)
	chunk_manager.set_center(_current_center())
	print("World: seed %d, chunk %d cells (%.0f m), radius %d (detail %d)" % [
		config.world_seed, config.chunk_size, config.chunk_world_size(),
		config.active_chunk_radius, config.detail_chunk_radius])


func _process(_delta: float) -> void:
	chunk_manager.set_center(_current_center())


func _current_center() -> Vector3:
	if is_instance_valid(streaming_target):
		return streaming_target.global_position
	return world_center


func _on_chunk_modified(c: Vector2i) -> void:
	chunk_manager.invalidate_chunk(c)


## Walkable ground height at a world XZ position (for spawning / building).
func get_surface_height(p: Vector3) -> float:
	return generator.get_surface_height(p)


## Height of the water surface. The whole world shares one water level.
func get_water_height() -> float:
	return config.water_level * config.level_height


## True when the chunk under p is built with collision, i.e. it is safe to stand or spawn there.
func is_ground_ready(p: Vector3) -> bool:
	var ch := chunk_manager.get_chunk(generator.coords.world_to_chunk(p))
	return ch != null and (ch.has_collision() or not config.generate_collision)
