class_name TerrainGenerator
extends RefCounted
## Elevation and water. Height is layered noise:
##   continental (very low freq)  -> large regions, natural low basins (lakes)
##   hills       (medium freq)    -> hills and valleys, amplitude varies by region
##   detail      (high freq)      -> small surface variation
##   highlands   (ridged)         -> rocky elevated areas, masked so they stay rare
## then the designed layout flattens the start meadow / digs lakes, and rivers carve
## channels and valleys. All inputs are pure functions of (seed, cell).

var config: WorldGenerationConfig
var layout: WorldLayout
var biomes: BiomeGenerator

var _continent := FastNoiseLite.new()
var _hills := FastNoiseLite.new()
var _hilliness := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _ridge := FastNoiseLite.new()
var _warp_x := FastNoiseLite.new()
var _warp_z := FastNoiseLite.new()
var _river := FastNoiseLite.new()
var _river_mask := FastNoiseLite.new()


func _init(p_config: WorldGenerationConfig, p_layout: WorldLayout, p_biomes: BiomeGenerator) -> void:
	config = p_config
	layout = p_layout
	biomes = p_biomes
	var s := config.world_seed
	var f := config.terrain_noise_scale
	BiomeGenerator._setup(_continent, s + 1, 1.0 / 420.0 * f, 3)
	BiomeGenerator._setup(_hills, s + 2, 1.0 / 58.0 * f, 3)
	BiomeGenerator._setup(_hilliness, s + 3, 1.0 / 240.0 * f, 2)
	BiomeGenerator._setup(_detail, s + 4, 1.0 / 13.0 * f, 2)
	BiomeGenerator._setup(_ridge, s + 5, 1.0 / 85.0 * f, 4)
	_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	BiomeGenerator._setup(_warp_x, s + 6, 1.0 / 160.0 * f, 2)
	BiomeGenerator._setup(_warp_z, s + 7, 1.0 / 160.0 * f, 2)
	BiomeGenerator._setup(_river, s + 8, 1.0 / 300.0 * f, 2)
	BiomeGenerator._setup(_river_mask, s + 9, 1.0 / 520.0 * f, 1)


## Fills heights and climate channels for the whole padded region of the chunk.
func fill(d: ChunkData) -> void:
	for z in d.span:
		for x in d.span:
			var cell := d.local_to_cell(x, z)
			var i := d.idx(x, z)
			_sample_into(d, i, float(cell.x), float(cell.y))


func _sample_into(d: ChunkData, i: int, x: float, z: float) -> void:
	var w := float(config.water_level)
	var hs := config.terrain_height_scale
	var lay := layout.sample(x, z)
	# Domain warp breaks up the grid-aligned look of layered noise.
	var wx := x + _warp_x.get_noise_2d(x, z) * 22.0
	var wz := z + _warp_z.get_noise_2d(x, z) * 22.0

	var clim := biomes.climate(wx, wz, lay)
	var highland := clim.w

	var cont := _continent.get_noise_2d(wx, wz)
	var hilliness := BiomeGenerator.n01(_hilliness, wx, wz)
	hilliness = clampf(hilliness + lay.hills * 0.45, 0.0, 1.0)
	var hill_amp := lerpf(config.hill_amplitude_min, config.hill_amplitude_max, hilliness)
	var hills := _hills.get_noise_2d(wx, wz)
	var detail := _detail.get_noise_2d(x, z)
	var ridge := _ridge.get_noise_2d(wx, wz) * 0.5 + 0.5
	# Sharpen: broad lower flanks and valleys, narrow crests.
	ridge = pow(clampf(ridge, 0.0, 1.0), 1.8)

	var h := config.base_height
	h += cont * config.continental_amplitude
	h += hills * hill_amp * hs
	h += detail * config.detail_amplitude
	h += highland * (config.highland_base_height + ridge * config.highland_ridge_height) * hs
	h += lay.height * hs

	# Designed open meadow: gentle, mostly flat, buildable.
	var meadow: float = lay.meadow
	if meadow > 0.0:
		var flat := config.base_height + 0.35 + hills * 0.45 + detail * 0.18
		h = lerpf(h, flat, smoothstep(0.0, 0.85, meadow))
		highland *= 1.0 - meadow

	# Lakes occupy designed basins; the continental layer adds natural ones elsewhere.
	var lake: float = lay.lake
	if lake > 0.0:
		var bottom := w - 0.6 - 2.4 * smoothstep(0.3, 1.0, lake) + detail * 0.3
		h = lerpf(h, minf(h, bottom), smoothstep(0.0, 0.42, lake))

	# Rivers.
	var channel := 0.0
	var valley := 0.0
	var dr := layout.river(x, z)
	if dr.x > 0.0 or dr.y > 0.0:
		channel = dr.x
		valley = dr.y
	if config.procedural_rivers:
		var mask := smoothstep(0.52, 0.66, BiomeGenerator.n01(_river_mask, x, z))
		mask *= (1.0 - meadow) * (1.0 - highland * 0.8)
		if mask > 0.0:
			var rn := absf(_river.get_noise_2d(wx, wz))
			var above := clampf((h - w) / 7.0, 0.0, 1.0)
			var rw := lerpf(0.026, 0.011, above)  # wider in the lowlands
			channel = maxf(channel, (1.0 - smoothstep(rw, rw * 1.9, rn)) * mask)
			valley = maxf(valley, (1.0 - smoothstep(rw * 1.5, rw * 7.0, rn)) * mask)
	if valley > 0.0:
		var valley_floor := w + 0.9 + maxf(h - w - 0.9, 0.0) * 0.35
		h = lerpf(h, minf(h, valley_floor), valley * 0.85)
	if channel > 0.0:
		h = lerpf(h, minf(h, w - 1.2 + detail * 0.2), channel)

	h = clampf(h, 1.0, float(config.max_height))
	d.height_f[i] = h
	d.level[i] = clampi(int(round(h)), 1, config.max_height)
	d.moisture[i] = clim.x
	d.forest[i] = clampf(clim.z * (1.0 - highland * 0.85) * (1.0 - meadow), 0.0, 1.0)
	d.rocky[i] = clampf(highland, 0.0, 1.0)
	d.meadow[i] = meadow
	d.river[i] = channel


## Convenience for tools: top level at an arbitrary world cell.
func level_at_cell(cell: Vector2i) -> int:
	var d := ChunkData.new()
	d.setup(Vector2i.ZERO, 1, 0, config.world_seed, config.water_level)
	d.origin_cell = cell
	_sample_into(d, 0, float(cell.x), float(cell.y))
	return d.level[0]
