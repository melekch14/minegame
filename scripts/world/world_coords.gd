class_name WorldCoords
extends RefCounted
## Single source of truth for coordinate conversion.
##
## Conventions (Godot): +X = east, -Z = north, +Y = up.
## Cell (i, j) covers x in [i*cell, (i+1)*cell), z in [j*cell, (j+1)*cell).
## Chunk (cx, cz) covers cells i in [cx*chunk_size, (cx+1)*chunk_size).
## Terrain level L is the block whose bottom is at y = L * level_height.
## A column of top level T has blocks 0..T-1, so its walkable surface is y = T * level_height.

var cell_size: float
var level_height: float
var chunk_size: int


func _init(config: WorldGenerationConfig) -> void:
	cell_size = config.cell_size
	level_height = config.level_height
	chunk_size = config.chunk_size


# --- world <-> cell -------------------------------------------------------

func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / cell_size), floori(p.z / cell_size))


## Bottom-centre of the block at (cell, level) — the pivot of every Blender block.
func cell_to_world(cell: Vector2i, level: int = 0) -> Vector3:
	return Vector3((cell.x + 0.5) * cell_size, level * level_height, (cell.y + 0.5) * cell_size)


func surface_y(top_level: int) -> float:
	return top_level * level_height


# --- cell <-> chunk -------------------------------------------------------

func cell_to_chunk(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / chunk_size), floori(float(cell.y) / chunk_size))


func world_to_chunk(p: Vector3) -> Vector2i:
	return cell_to_chunk(world_to_cell(p))


func chunk_origin_cell(chunk: Vector2i) -> Vector2i:
	return chunk * chunk_size


func chunk_to_world(chunk: Vector2i) -> Vector3:
	return Vector3(chunk.x * chunk_size * cell_size, 0.0, chunk.y * chunk_size * cell_size)


## Cell coordinate relative to its chunk origin (0..chunk_size-1).
func cell_to_local(cell: Vector2i) -> Vector2i:
	return Vector2i(posmod(cell.x, chunk_size), posmod(cell.y, chunk_size))


static func chunk_key(chunk: Vector2i) -> String:
	return "%d_%d" % [chunk.x, chunk.y]
