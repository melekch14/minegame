class_name BiomeGenerator
extends RefCounted
## Climate sampling and biome classification.
##
## Noise A = moisture, Noise B = temperature/environment, Noise C = elevation (from the
## terrain). All are very low frequency, so biomes form large continuous regions. Biome
## weights are continuous (0..1); densities read the weights directly, which is what makes
## forest -> sparse forest -> meadow transitions gradual instead of bordered.

var config: WorldGenerationConfig
var layout: WorldLayout

var _moisture := FastNoiseLite.new()
var _temperature := FastNoiseLite.new()
var _highland := FastNoiseLite.new()
var _patch := FastNoiseLite.new()       # forest edge breakup
var _clearing := FastNoiseLite.new()    # forest clearings
var _grove := FastNoiseLite.new()       # tree groves inside meadows
var _stone := FastNoiseLite.new()       # exposed-stone breakup
var _shore := FastNoiseLite.new()       # shoreline width variation
var _cluster := FastNoiseLite.new()     # rock clustering


func _init(p_config: WorldGenerationConfig, p_layout: WorldLayout) -> void:
	config = p_config
	layout = p_layout
	var s := config.world_seed
	var f := config.terrain_noise_scale
	_setup(_moisture, s + 101, 1.0 / 210.0 * f, 3)
	_setup(_temperature, s + 102, 1.0 / 320.0 * f, 2)
	_setup(_highland, s + 103, 1.0 / 340.0 * f, 3)
	_setup(_patch, s + 104, 1.0 / 30.0, 2)
	_setup(_clearing, s + 105, 1.0 / 38.0, 2)
	_setup(_grove, s + 106, 1.0 / 22.0, 2)
	_setup(_stone, s + 107, 1.0 / 11.0, 2)
	_setup(_shore, s + 108, 1.0 / 13.0, 1)
	_setup(_cluster, s + 109, 1.0 / 9.0, 1)


static func _setup(n: FastNoiseLite, s: int, freq: float, octaves: int) -> void:
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	n.frequency = freq


static func n01(n: FastNoiseLite, x: float, z: float) -> float:
	return clampf(n.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)


## Climate at a cell. Returns Vector4(moisture, temperature, forest_bias_weight, highland 0..1)
## plus the layout sample (shared with the terrain generator to avoid sampling it twice).
func climate(x: float, z: float, lay: Dictionary) -> Vector4:
	var moist := n01(_moisture, x, z)
	var temp := n01(_temperature, x, z)
	# Highlands: rare, broad; drier + cooler environment pushes toward rock.
	var hl := n01(_highland, x, z)
	hl = pow(hl, 1.0 + config.highland_rarity * 2.2)
	hl = hl * 1.3 + (0.5 - moist) * 0.18 + (0.45 - temp) * 0.14
	hl += lay.rocky
	var highland := smoothstep(0.48, 0.85, hl)
	# Forest: wet + temperate regions, broken up at the edges.
	var fr := moist * 0.85 + (0.5 - absf(temp - 0.55)) * 0.3 + (n01(_patch, x, z) - 0.5) * 0.28
	fr += lay.forest * 0.55
	var forest := smoothstep(0.5, 0.72, fr)
	return Vector4(moist, temp, forest, highland)


# ---------------------------------------------------------------------------
# Classification passes (run after terrain heights are known)
# ---------------------------------------------------------------------------

func classify(d: ChunkData) -> void:
	_compute_water_distance(d)
	var w := d.water_level
	var max_shore := config.max_shore_width
	for z in d.span:
		for x in d.span:
			var i := d.idx(x, z)
			var cell := d.local_to_cell(x, z)
			var t := d.level[i]
			var r := d.rocky[i]
			var f := d.forest[i]
			# Elevation itself exposes stone high up.
			var elev_rock := smoothstep(10.5, 14.5, float(t))
			var rock := maxf(r, elev_rock)
			var drop := _max_drop(d, x, z)
			var stone_n := n01(_stone, cell.x, cell.y)
			var surf := ChunkData.Surface.GRASS
			var bio := ChunkData.Biome.GRASSLAND
			if t < w:
				# Lake / river bed.
				bio = ChunkData.Biome.WATER
				if rock > 0.55:
					surf = ChunkData.Surface.STONE
				elif t >= w - 1 and stone_n > 0.3:
					surf = ChunkData.Surface.SAND
				elif stone_n > 0.72:
					surf = ChunkData.Surface.STONE
				else:
					surf = ChunkData.Surface.DIRT
			else:
				var shore_w := int(floor(n01(_shore, cell.x, cell.y) * (max_shore + 0.85)))
				var wd := d.water_dist[i]
				# Exposed stone: rocky regions, high ground and steep edges; flatter
				# highland tops keep patches of grass so the highlands read as terrain.
				var steep := 1.0 if drop >= 2 else (0.35 if drop == 1 else 0.0)
				var stone_score := r * 0.26 + elev_rock * 0.42 + steep * 0.45 * (0.3 + r) + (stone_n - 0.5) * 0.7
				if stone_score > 0.5:
					surf = ChunkData.Surface.STONE
					bio = ChunkData.Biome.ROCKY_HIGHLANDS
				elif wd <= shore_w and t <= w + 1 and rock < 0.5:
					surf = ChunkData.Surface.SAND
					bio = ChunkData.Biome.SHORE
				elif f > 0.55 and n01(_patch, cell.x * 3.1, cell.y * 3.1) > 0.8:
					surf = ChunkData.Surface.DIRT  # rare forest-floor patches
					bio = ChunkData.Biome.FOREST
				else:
					surf = ChunkData.Surface.GRASS
					if rock > 0.5:
						bio = ChunkData.Biome.ROCKY_HIGHLANDS
					elif f > 0.5:
						bio = ChunkData.Biome.FOREST
					elif wd <= 2:
						bio = ChunkData.Biome.SHORE
			d.surface[i] = surf
			d.biome[i] = bio
	_assign_slopes(d)


func _compute_water_distance(d: ChunkData) -> void:
	var cap := 8
	var queue: Array[int] = []
	for i in d.level.size():
		if d.level[i] < d.water_level:
			d.water_dist[i] = 0
			queue.append(i)
		else:
			d.water_dist[i] = cap
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % d.span
		var z := i / d.span
		var nd := d.water_dist[i] + 1
		if nd >= cap:
			continue
		for o in ChunkData.NEIGHBOURS:
			var nx := x + o.x
			var nz := z + o.y
			if not d.in_span(nx, nz):
				continue
			var ni := d.idx(nx, nz)
			if d.water_dist[ni] > nd:
				d.water_dist[ni] = nd
				queue.append(ni)


func _max_drop(d: ChunkData, x: int, z: int) -> int:
	var t := d.level_at(x, z)
	var m := 0
	for o in ChunkData.NEIGHBOURS:
		m = maxi(m, t - d.level_at(x + o.x, z + o.y))
	return m


## Grass slopes go where the terrain steps up by exactly one level, turning small
## ledges into walkable, natural-looking ramps. Two-level (or more) steps stay cliffs.
func _assign_slopes(d: ChunkData) -> void:
	var w := d.water_level
	for z in d.span:
		for x in d.span:
			var i := d.idx(x, z)
			d.slope[i] = ChunkData.SlopeDir.NONE
			var t := d.level[i]
			if t < w or d.surface[i] == ChunkData.Surface.STONE:
				continue
			var higher: Array[int] = []
			var cliff := false
			for k in 4:
				var o: Vector2i = ChunkData.NEIGHBOURS[k]
				var nt := d.level_at(x + o.x, z + o.y)
				if nt == t + 1:
					higher.append(k)
				elif nt > t + 1:
					cliff = true
			if cliff or higher.is_empty() or higher.size() > 2:
				continue
			if higher.size() == 2 and (higher[1] - higher[0]) == 2:
				continue  # opposite sides: a 1-wide trench, leave flat
			var cell := d.local_to_cell(x, z)
			if WorldHash.rand01(d.gen_seed, cell.x, cell.y, 31) > config.slope_probability:
				continue
			var k_pick: int = higher[0]
			if higher.size() == 2:
				if WorldHash.rand01(d.gen_seed, cell.x, cell.y, 32) < 0.35:
					continue  # inner corner: sometimes leave a small ledge
				k_pick = higher[int(WorldHash.rand01(d.gen_seed, cell.x, cell.y, 33) * 2.0)]
			# The upper neighbour must be solid land (not stone cliff rock).
			var o2: Vector2i = ChunkData.NEIGHBOURS[k_pick]
			var ui := d.idx(clampi(x + o2.x, 0, d.span - 1), clampi(z + o2.y, 0, d.span - 1))
			if d.surface[ui] == ChunkData.Surface.STONE and d.rocky[ui] > 0.7:
				continue
			d.slope[i] = k_pick + 1
			d.surface[i] = ChunkData.Surface.GRASS


# ---------------------------------------------------------------------------
# Densities used by the vegetation / rock placer
# ---------------------------------------------------------------------------

func tree_density(d: ChunkData, i: int, cell: Vector2i) -> float:
	var f := d.forest[i]
	var r := d.rocky[i]
	var clearing := smoothstep(0.62, 0.74, n01(_clearing, cell.x, cell.y)) * config.clearing_amount * 2.0
	clearing = clampf(clearing, 0.0, 1.0)
	var forest_part := f * config.forest_density * (1.0 - clearing)
	var grove := smoothstep(0.58, 0.82, n01(_grove, cell.x, cell.y)) * 0.8 + 0.12
	var grass_part := (1.0 - f) * config.grassland_density * grove
	grass_part *= (1.0 - d.meadow[i] * 0.55)
	var dens := (forest_part + grass_part) * config.tree_density
	dens *= 1.0 - 0.93 * r
	var wd := d.water_dist[i]
	if wd <= 3:
		dens *= 0.25 + 0.2 * wd
	return dens


func large_tree_share(d: ChunkData, i: int) -> float:
	var f := d.forest[i]
	var l := config.large_tree_probability * (0.35 + 0.65 * f)
	var s := config.small_tree_probability * (1.25 - 0.55 * f)
	return l / maxf(l + s, 0.0001)


func large_rock_density(d: ChunkData, i: int, cell: Vector2i) -> float:
	var r := maxf(d.rocky[i], smoothstep(9.0, 12.0, float(d.level[i])))
	var f := d.forest[i]
	var edge := 1.0 - absf(f - 0.45) / 0.45  # forest edges
	edge = clampf(edge, 0.0, 1.0)
	var cl := n01(_cluster, cell.x * 0.6, cell.y * 0.6)
	var dens := r * 0.075 + edge * 0.018 + 0.004
	dens *= 0.4 + 1.3 * cl
	dens *= 1.0 - d.meadow[i] * 0.6
	return dens * config.rock_density


func small_rock_density(d: ChunkData, i: int, cell: Vector2i) -> float:
	var r := d.rocky[i]
	var f := d.forest[i]
	var cl := smoothstep(0.45, 0.8, n01(_cluster, cell.x, cell.y))
	var base := 0.008 + f * 0.012 + r * 0.045
	if d.water_dist[i] <= 2 and d.level[i] >= d.water_level:
		base += 0.035
	return base * (0.25 + 2.0 * cl) * config.rock_density
