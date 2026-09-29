class_name WorldGenerator
extends Node
## Owns the stateless generators and produces chunk payloads. Thread-safe: every method
## used by generate_chunk() only reads immutable noise objects/config, so ChunkManager can
## call it from WorkerThreadPool tasks.

## Padding (cells) around each chunk so neighbour rules are identical across borders.
const CHUNK_MARGIN := 8

var config: WorldGenerationConfig
var coords: WorldCoords
var layout: WorldLayout
var biomes: BiomeGenerator
var terrain: TerrainGenerator
var vegetation: VegetationGenerator
var mesher: ChunkMesher
var modifications: WorldModifications


func setup(p_config: WorldGenerationConfig, p_mods: WorldModifications) -> void:
	config = p_config
	modifications = p_mods
	coords = WorldCoords.new(config)
	layout = WorldLayout.new(config)
	biomes = BiomeGenerator.new(config, layout)
	terrain = TerrainGenerator.new(config, layout, biomes)
	vegetation = VegetationGenerator.new(config, biomes, coords)
	mesher = ChunkMesher.new(config, coords)


## Pure data for a chunk (terrain, biomes, water, slopes, props).
func generate_chunk_data(chunk: Vector2i) -> ChunkData:
	var d := ChunkData.new()
	d.setup(chunk, config.chunk_size, CHUNK_MARGIN, config.world_seed, config.water_level)
	terrain.fill(d)
	_apply_terrain_overrides(d)
	biomes.classify(d)
	vegetation.populate(d, modifications)
	return d


## Full payload ready for WorldChunk.apply(). Safe to call from a worker thread.
func generate_chunk(chunk: Vector2i, lod: int) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var d := generate_chunk_data(chunk)
	var t1 := Time.get_ticks_usec()
	var res := mesher.build(d, lod)
	res["timing_ms"] = Vector2((t1 - t0) / 1000.0, (Time.get_ticks_usec() - t1) / 1000.0)
	return res


func _apply_terrain_overrides(d: ChunkData) -> void:
	if modifications == null or not modifications.has_terrain_overrides():
		return
	for z in d.span:
		for x in d.span:
			var o := modifications.get_terrain_override(d.local_to_cell(x, z))
			if o >= 0:
				d.level[d.idx(x, z)] = o


## Walkable surface height at a world position (useful for future spawn / placement code).
func get_surface_height(world_pos: Vector3) -> float:
	var cell := coords.world_to_cell(world_pos)
	return coords.surface_y(terrain.level_at_cell(cell))
