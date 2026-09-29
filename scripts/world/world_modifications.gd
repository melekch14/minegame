class_name WorldModifications
extends Resource
## Save-friendly record of everything that differs from the pure procedural result.
## The generator stays deterministic; at build time it consults this resource so a chunk
## that is unloaded and reloaded keeps the player's changes. Not a full save system yet —
## it is the data shape a future save system serialises (it is a Resource, so
## ResourceSaver can already write it to .tres/.res).

## World seed this record belongs to.
@export var world_seed: int = 0
## Stable object ids (WorldHash.object_id) of destroyed trees / rocks.
@export var removed_objects: Dictionary = {}
## Terrain edits: "i_j" cell key -> new top level.
@export var terrain_overrides: Dictionary = {}
## Player-built structures per chunk: chunk key -> Array of serialised structures.
@export var structures: Dictionary = {}
## Chunk keys touched by any modification (lets a loader skip untouched chunks fast).
@export var modified_chunks: Dictionary = {}

signal chunk_modified(chunk: Vector2i)


func is_object_removed(id: int) -> bool:
	return removed_objects.has(id)


func remove_object(id: int, chunk: Vector2i) -> void:
	removed_objects[id] = true
	_touch(chunk)


func set_terrain_level(cell: Vector2i, level: int, chunk: Vector2i) -> void:
	terrain_overrides["%d_%d" % [cell.x, cell.y]] = level
	_touch(chunk)


func get_terrain_override(cell: Vector2i) -> int:
	return terrain_overrides.get("%d_%d" % [cell.x, cell.y], -1)


func has_terrain_overrides() -> bool:
	return not terrain_overrides.is_empty()


func _touch(chunk: Vector2i) -> void:
	modified_chunks[WorldCoords.chunk_key(chunk)] = true
	chunk_modified.emit(chunk)
