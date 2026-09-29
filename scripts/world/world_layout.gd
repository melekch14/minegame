class_name WorldLayout
extends RefCounted
## Authored macro geography around the world origin, expressed as soft, noise-warped
## "anchors". Anchors only *bias* the procedural noise — they never draw hard borders —
## so every region blends naturally into its neighbours and into the purely procedural
## world beyond the layout radius.
##
## Directions: +X = east, -Z = north. Units: terrain cells (2 m).

# Anchor fields:
#   pos      centre (cells)          radius  influence radius (cells)
#   height   added elevation (levels)
#   forest   forest bias             rocky   rocky-highland bias
#   meadow   0..1 flatten + clear    hills   extra hill amplitude
#   lake     0..1 lake basin strength
const ANCHORS: Array[Dictionary] = [
	{"name": "start_meadow",  "pos": Vector2(0, 2),     "radius": 36.0, "meadow": 1.0, "forest": -1.2, "rocky": -1.0},
	{"name": "start_grove",   "pos": Vector2(27, -27),  "radius": 13.0, "forest": 1.5, "meadow": -0.9, "height": 0.3},
	{"name": "start_pond",    "pos": Vector2(-24, 18),  "radius": 11.0, "lake": 0.9},
	{"name": "north_forest",  "pos": Vector2(-4, -108), "radius": 84.0, "forest": 0.95, "hills": 0.4, "height": 0.8, "rocky": -0.7},
	{"name": "ne_highlands",  "pos": Vector2(104, -104),"radius": 70.0, "rocky": 1.1, "height": 1.2, "hills": 1.0, "forest": -0.4},
	{"name": "east_lake",     "pos": Vector2(96, 6),    "radius": 44.0, "lake": 1.0, "forest": 0.1, "rocky": -0.8},
	{"name": "east_woods",    "pos": Vector2(128, -30), "radius": 34.0, "forest": 0.8},
	{"name": "east_meadow",   "pos": Vector2(88, 52),   "radius": 30.0, "forest": -0.6, "meadow": 0.25},
	{"name": "south_rolling", "pos": Vector2(0, 118),   "radius": 86.0, "forest": -0.75, "hills": 1.0, "rocky": -0.6},
	{"name": "sw_mixed",      "pos": Vector2(-104, 98), "radius": 62.0, "forest": 0.3, "hills": 0.4, "rocky": -0.5},
	{"name": "west_rocky",    "pos": Vector2(-120, -6), "radius": 58.0, "rocky": 0.7, "height": 0.8, "hills": 0.7, "forest": -0.35},
	{"name": "nw_forest_hills","pos": Vector2(-104, -104),"radius": 72.0, "forest": 0.75, "hills": 1.5, "height": 1.6, "rocky": -0.45},
]

## River flowing out of the east lake toward the south-east (cells).
const SE_RIVER: Array[Vector2] = [
	Vector2(104, 16), Vector2(116, 40), Vector2(124, 72), Vector2(146, 108),
	Vector2(182, 146), Vector2(228, 200), Vector2(290, 268), Vector2(360, 350),
]
const SE_RIVER_START_WIDTH := 1.5   # half width, cells
const SE_RIVER_END_WIDTH := 3.6

var enabled: bool
var _anchors: Array[Dictionary] = []
var _river: PackedVector2Array
var _river_len: PackedFloat32Array
var _river_total := 0.0
var _warp_a := FastNoiseLite.new()
var _warp_b := FastNoiseLite.new()
var _meander := FastNoiseLite.new()


func _init(config: WorldGenerationConfig) -> void:
	enabled = config.use_designed_layout
	var s := config.world_seed
	for n in [_warp_a, _warp_b, _meander]:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = 2
	_warp_a.seed = s + 9001
	_warp_b.seed = s + 9002
	_meander.seed = s + 9003
	_warp_a.frequency = 1.0 / 26.0
	_warp_b.frequency = 1.0 / 26.0
	_meander.frequency = 1.0 / 40.0

	# Seed-driven drift so different seeds still differ inside the designed area.
	for i in ANCHORS.size():
		var a: Dictionary = ANCHORS[i].duplicate()
		var r: float = a.radius
		var jitter := config.layout_seed_jitter * r
		if a.name.begins_with("start"):
			jitter *= 0.3
		var off := Vector2(
			(WorldHash.rand01(s, i, 0, 777) - 0.5) * 2.0 * jitter,
			(WorldHash.rand01(s, i, 1, 777) - 0.5) * 2.0 * jitter)
		a.pos = (a.pos as Vector2) + off
		_anchors.append(a)

	_river = PackedVector2Array(SE_RIVER)
	for k in range(1, _river.size() - 1):
		_river[k] += Vector2(
			(WorldHash.rand01(s, k, 0, 778) - 0.5) * 16.0,
			(WorldHash.rand01(s, k, 1, 778) - 0.5) * 16.0)
	_river_len.resize(_river.size())
	_river_len[0] = 0.0
	for k in range(1, _river.size()):
		_river_total += _river[k].distance_to(_river[k - 1])
		_river_len[k] = _river_total


## Returns the combined anchor influence at a cell position.
## Keys: height, forest, rocky, meadow (0..1), hills, lake (0..1).
func sample(x: float, z: float) -> Dictionary:
	var out := {"height": 0.0, "forest": 0.0, "rocky": 0.0, "meadow": 0.0, "hills": 0.0, "lake": 0.0}
	if not enabled:
		return out
	# Warp the lookup position so anchor borders are organic, never circular.
	var wx := x + _warp_a.get_noise_2d(x, z) * 9.0
	var wz := z + _warp_b.get_noise_2d(x, z) * 9.0
	var meadow_pos := 0.0
	var meadow_neg := 0.0
	for a in _anchors:
		var r: float = a.radius
		var p: Vector2 = a.pos
		var dx := wx - p.x
		var dz := wz - p.y
		var d2 := dx * dx + dz * dz
		if d2 > r * r * 1.44:
			continue
		# Larger anchors get a larger, lower-frequency warp.
		var d := sqrt(d2) + _warp_a.get_noise_2d(x * 0.37 + p.x, z * 0.37 + p.y) * r * 0.22
		var w := 1.0 - smoothstep(r * 0.42, r, d)
		if w <= 0.0:
			continue
		out.height += a.get("height", 0.0) * w
		out.forest += a.get("forest", 0.0) * w
		out.rocky += a.get("rocky", 0.0) * w
		out.hills += a.get("hills", 0.0) * w
		var m: float = a.get("meadow", 0.0)
		if m > 0.0:
			meadow_pos = maxf(meadow_pos, m * w)
		elif m < 0.0:
			meadow_neg = maxf(meadow_neg, -m * w)
		var l: float = a.get("lake", 0.0)
		if l > 0.0:
			out.lake = maxf(out.lake, l * (1.0 - smoothstep(r * 0.25, r, d)))
	out.meadow = clampf(meadow_pos - meadow_neg, 0.0, 1.0)
	return out


## Designed river channel. Returns Vector3(channel 0..1, valley 0..1, progress 0..1).
func river(x: float, z: float) -> Vector3:
	if not enabled:
		return Vector3.ZERO
	var p := Vector2(x, z)
	var best := INF
	var best_t := 0.0
	for k in range(1, _river.size()):
		var a := _river[k - 1]
		var b := _river[k]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d := p.distance_to(a + ab * t)
		if d < best:
			best = d
			best_t = (_river_len[k - 1] + ab.length() * t) / _river_total
	if best > 40.0:
		return Vector3.ZERO
	# Meander: shift the perceived distance so banks wobble.
	best += _meander.get_noise_2d(x, z) * 2.2
	var half := lerpf(SE_RIVER_START_WIDTH, SE_RIVER_END_WIDTH, best_t)
	half += _meander.get_noise_2d(x * 2.3 + 50.0, z * 2.3) * 0.7
	var channel := 1.0 - smoothstep(half, half + 1.4, best)
	var valley := 1.0 - smoothstep(half + 1.0, half + 16.0, best)
	return Vector3(channel, valley, best_t)
