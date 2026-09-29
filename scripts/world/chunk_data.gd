class_name ChunkData
extends RefCounted
## Pure data for one chunk: everything the generators decided, no scene nodes.
## Arrays cover the chunk plus a margin on every side so neighbour-dependent rules
## (shorelines, slopes, tree spacing, visible cliff faces) are seamless across chunk borders.

enum Surface { GRASS, DIRT, STONE, SAND }
enum Biome { GRASSLAND, FOREST, ROCKY_HIGHLANDS, SHORE, WATER }
## Slope direction: the neighbour the ramp rises toward.
enum SlopeDir { NONE, NORTH, EAST, SOUTH, WEST }

const NEIGHBOURS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

var coord: Vector2i
var gen_seed: int
var size: int
var margin: int
var span: int
## Global cell coordinate of array index (0, 0).
var origin_cell: Vector2i
var water_level: int

# Per-cell arrays, index = z * span + x (local to the padded region).
var level := PackedInt32Array()       # top level T: blocks 0..T-1
var height_f := PackedFloat32Array()  # unquantised height (levels)
var moisture := PackedFloat32Array()
var forest := PackedFloat32Array()    # 0..1 forest weight
var rocky := PackedFloat32Array()     # 0..1 rocky-highland weight
var meadow := PackedFloat32Array()    # 0..1 designed open-meadow weight
var river := PackedFloat32Array()     # 0..1 river channel strength
var water_dist := PackedInt32Array()  # cells to nearest water (capped)
var surface := PackedByteArray()      # Surface
var biome := PackedByteArray()        # Biome
var slope := PackedByteArray()        # SlopeDir

## Spawned decoration. key (asset id) -> Array of {id:int, xform:Transform3D}
var props: Dictionary = {}
## Counts for debug / tooling.
var stats: Dictionary = {}


func setup(p_coord: Vector2i, p_size: int, p_margin: int, p_seed: int, p_water: int) -> void:
	coord = p_coord
	size = p_size
	margin = p_margin
	span = size + margin * 2
	gen_seed = p_seed
	water_level = p_water
	origin_cell = coord * size - Vector2i(margin, margin)
	var n := span * span
	level.resize(n)
	water_dist.resize(n)
	height_f.resize(n)
	moisture.resize(n)
	forest.resize(n)
	rocky.resize(n)
	meadow.resize(n)
	river.resize(n)
	surface.resize(n)
	biome.resize(n)
	slope.resize(n)


func idx(x: int, z: int) -> int:
	return z * span + x


func in_span(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < span and z < span


func is_interior(x: int, z: int) -> bool:
	return x >= margin and z >= margin and x < margin + size and z < margin + size


func local_to_cell(x: int, z: int) -> Vector2i:
	return origin_cell + Vector2i(x, z)


func level_at(x: int, z: int) -> int:
	return level[idx(clampi(x, 0, span - 1), clampi(z, 0, span - 1))]


func is_water(x: int, z: int) -> bool:
	return level_at(x, z) < water_level


## Top level of the terrain in world cell coordinates, or -1 if outside this chunk's data.
func get_level_global(cell: Vector2i) -> int:
	var l := cell - origin_cell
	if not in_span(l.x, l.y):
		return -1
	return level[idx(l.x, l.y)]


func add_prop(key: String, id: int, xform: Transform3D) -> void:
	if not props.has(key):
		props[key] = []
	props[key].append({"id": id, "xform": xform})
