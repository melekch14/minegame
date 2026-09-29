class_name VegetationGenerator
extends RefCounted
## Places trees and rocks with a deterministic blue-noise rule:
##   1. every cell gets an *eligibility* test (hash < biome density) and a *priority* hash;
##   2. a candidate is accepted only if no eligible neighbour within its exclusion radius
##      has a higher priority.
## Both steps are pure functions of (seed, cell), so the result is identical no matter
## which chunk evaluates it -> no duplicates or gaps along chunk borders, and a chunk
## regenerates exactly after being unloaded.

const LAYER_ROCK_L_ELIG := 11
const LAYER_ROCK_L_PRIO := 12
const LAYER_ROCK_S_ELIG := 13
const LAYER_ROCK_S_PRIO := 14
const LAYER_TREE_ELIG := 21
const LAYER_TREE_PRIO := 22
const LAYER_TREE_KIND := 23
const LAYER_JITTER := 40

const ID_TREE := 1
const ID_ROCK_LARGE := 2
const ID_ROCK_SMALL := 3

const TREE_R_LARGE := 2.25  # exclusion radius in cells
const TREE_R_SMALL := 1.55
const ROCK_R_LARGE := 2.3
const ROCK_R_SMALL := 1.1

var config: WorldGenerationConfig
var biomes: BiomeGenerator
var coords: WorldCoords


func _init(p_config: WorldGenerationConfig, p_biomes: BiomeGenerator, p_coords: WorldCoords) -> void:
	config = p_config
	biomes = p_biomes
	coords = p_coords


func populate(d: ChunkData, mods: WorldModifications) -> void:
	var n := d.span * d.span
	var s := d.gen_seed
	# --- per-cell ground suitability -------------------------------------
	var flat := PackedByteArray()
	flat.resize(n)
	for z in d.span:
		for x in d.span:
			var i := d.idx(x, z)
			var t := d.level[i]
			var ok := t >= d.water_level and d.slope[i] == ChunkData.SlopeDir.NONE
			if ok:
				for o in ChunkData.NEIGHBOURS:
					var nt := d.level_at(x + o.x, z + o.y)
					# Roots/rocks must not hang over a ledge or sit under a wall.
					if nt < t or nt > t + 1:
						ok = false
						break
			flat[i] = 1 if ok else 0

	# --- rocks first (trees keep their distance from rocks) --------------
	var large_elig := PackedFloat32Array()
	large_elig.resize(n)
	var small_elig := PackedFloat32Array()
	small_elig.resize(n)
	for z in d.span:
		for x in d.span:
			var i := d.idx(x, z)
			large_elig[i] = -1.0
			small_elig[i] = -1.0
			if flat[i] == 0:
				continue
			var c := d.local_to_cell(x, z)
			if WorldHash.rand01(s, c.x, c.y, LAYER_ROCK_L_ELIG) < biomes.large_rock_density(d, i, c):
				large_elig[i] = WorldHash.rand01(s, c.x, c.y, LAYER_ROCK_L_PRIO)
			if WorldHash.rand01(s, c.x, c.y, LAYER_ROCK_S_ELIG) < biomes.small_rock_density(d, i, c):
				small_elig[i] = WorldHash.rand01(s, c.x, c.y, LAYER_ROCK_S_PRIO)
	var large_acc := _accept(d, large_elig, ROCK_R_LARGE)
	# Small rocks never share a cell with (or sit right beside) a large rock.
	for z in d.span:
		for x in d.span:
			if large_acc[d.idx(x, z)] == 1:
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						if d.in_span(x + dx, z + dz):
							small_elig[d.idx(x + dx, z + dz)] = -1.0
	var small_acc := _accept(d, small_elig, ROCK_R_SMALL)

	# --- trees -----------------------------------------------------------
	var tree_elig := PackedFloat32Array()
	tree_elig.resize(n)
	var tree_large := PackedByteArray()
	tree_large.resize(n)
	for z in d.span:
		for x in d.span:
			var i := d.idx(x, z)
			tree_elig[i] = -1.0
			if flat[i] == 0:
				continue
			var surf := d.surface[i]
			if surf == ChunkData.Surface.STONE:
				continue
			if d.water_dist[i] < 2:
				continue
			if small_acc[i] == 1 or _near(d, large_acc, x, z, 1):
				continue
			var c := d.local_to_cell(x, z)
			var dens := biomes.tree_density(d, i, c)
			if surf == ChunkData.Surface.SAND:
				dens *= 0.2
			if WorldHash.rand01(s, c.x, c.y, LAYER_TREE_ELIG) < dens:
				tree_elig[i] = WorldHash.rand01(s, c.x, c.y, LAYER_TREE_PRIO)
				tree_large[i] = 1 if WorldHash.rand01(s, c.x, c.y, LAYER_TREE_KIND) < biomes.large_tree_share(d, i) else 0
	var tree_acc := _accept_trees(d, tree_elig, tree_large)

	# --- emit interior props --------------------------------------------
	var counts := {"trees": 0, "rocks_large": 0, "rocks_small": 0}
	for z in range(d.margin, d.margin + d.size):
		for x in range(d.margin, d.margin + d.size):
			var i := d.idx(x, z)
			var c := d.local_to_cell(x, z)
			var ground := coords.surface_y(d.level[i])
			if large_acc[i] == 1:
				var id := WorldHash.object_id(ID_ROCK_LARGE, c)
				if mods == null or not mods.is_object_removed(id):
					var sc := 0.85 + WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 5) * 0.55
					d.add_prop("rock_large", id, _xform(d, c, ground - 0.08 * sc, sc, 0.45))
					counts.rocks_large += 1
			if small_acc[i] == 1:
				var id2 := WorldHash.object_id(ID_ROCK_SMALL, c)
				if mods == null or not mods.is_object_removed(id2):
					var sc2 := 0.8 + WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 6) * 0.7
					var v := int(WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 7) * 3.0)
					d.add_prop(["rock_small_a", "rock_small_b", "rock_small_c"][v], id2, _xform(d, c, ground - 0.04, sc2, 0.62))
					counts.rocks_small += 1
			if tree_acc[i] == 1:
				var id3 := WorldHash.object_id(ID_TREE, c)
				if mods == null or not mods.is_object_removed(id3):
					var var_ := int(WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 8) * 3.0)
					var key: String = ("tree_large_" if tree_large[i] == 1 else "tree_small_") + ["a", "b", "c"][var_]
					var tv := config.tree_scale_variation
					var sc3 := 1.0 - tv + WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 9) * tv * 2.0
					d.add_prop(key, id3, _xform(d, c, ground - 0.06, sc3, 0.3))
					counts.trees += 1
	d.stats.merge(counts, true)


## Accept candidates that are the local priority maximum within radius (cells).
## Only cells whose whole neighbourhood lies inside the padded region are decided, which
## is what keeps the result identical across chunk borders (ChunkData margin >= 8).
func _accept(d: ChunkData, elig: PackedFloat32Array, radius: float) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(elig.size())
	var r := int(ceil(radius))
	var r2 := radius * radius
	var lo := r
	var hi := d.span - r
	for z in range(lo, hi):
		for x in range(lo, hi):
			var i := d.idx(x, z)
			var p := elig[i]
			if p < 0.0:
				continue
			var best := true
			for dz in range(-r, r + 1):
				if not best:
					break
				for dx in range(-r, r + 1):
					if dx == 0 and dz == 0:
						continue
					if dx * dx + dz * dz > r2:
						continue
					if not d.in_span(x + dx, z + dz):
						continue
					var q := elig[d.idx(x + dx, z + dz)]
					if q > p:
						best = false
						break
			out[i] = 1 if best else 0
	return out


func _accept_trees(d: ChunkData, elig: PackedFloat32Array, large: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(elig.size())
	var rmax := int(ceil(TREE_R_LARGE))
	for z in range(d.margin, d.margin + d.size):
		for x in range(d.margin, d.margin + d.size):
			var i := d.idx(x, z)
			var p := elig[i]
			if p < 0.0:
				continue
			var ri := TREE_R_LARGE if large[i] == 1 else TREE_R_SMALL
			var best := true
			for dz in range(-rmax, rmax + 1):
				if not best:
					break
				for dx in range(-rmax, rmax + 1):
					if dx == 0 and dz == 0:
						continue
					if not d.in_span(x + dx, z + dz):
						continue
					var j := d.idx(x + dx, z + dz)
					var q := elig[j]
					if q <= p:
						continue
					var rj := TREE_R_LARGE if large[j] == 1 else TREE_R_SMALL
					var rr := maxf(ri, rj)
					if dx * dx + dz * dz <= rr * rr:
						best = false
						break
			out[i] = 1 if best else 0
	return out


func _near(d: ChunkData, acc: PackedByteArray, x: int, z: int, r: int) -> bool:
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if d.in_span(x + dx, z + dz) and acc[d.idx(x + dx, z + dz)] == 1:
				return true
	return false


## Transform on a cell with deterministic jitter, yaw and uniform scale.
func _xform(d: ChunkData, c: Vector2i, y: float, sc: float, jitter_m: float) -> Transform3D:
	var s := d.gen_seed
	var jx := (WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 1) - 0.5) * 2.0 * jitter_m
	var jz := (WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 2) - 0.5) * 2.0 * jitter_m
	var yaw := WorldHash.rand01(s, c.x, c.y, LAYER_JITTER + 3) * TAU
	var b := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc)
	var p := coords.cell_to_world(c, 0)
	p.x += jx
	p.z += jz
	p.y = y
	return Transform3D(b, p)
