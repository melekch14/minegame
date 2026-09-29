class_name ChunkMesher
extends RefCounted
## Turns ChunkData into render/collision payloads. Runs on worker threads — it only produces
## packed arrays; scene nodes are created later on the main thread.
##
## Rendering is hierarchical (HLOD):
##   * Every chunk is split into square "sections". Each section has a merged voxel mesh
##     (only exposed faces, same Blender ramp colours) used at distance.
##   * NEAR chunks additionally carry, per section, MultiMesh buffers of the real Blender
##     assets (blocks, slopes, water tiles, rocks, full trees). WorldChunk swaps between the
##     two with visibility ranges, so detail follows the camera without regenerating chunks.
##   * FAR chunks are one section: merged mesh, decimated / voxel trees, large rocks.
## Collision (NEAR only): triangle soup of block tops, cliff faces and ramps.

enum Lod { FAR, NEAR }

# LOD mesh material ids, stored in UV.x (vertex colours get colour-space converted, UVs don't).
const MAT_GRASS := 0
const MAT_DIRT := 1
const MAT_STONE := 2
const MAT_SAND := 3
## UV.y = 1 marks the side of a grass-topped block so the shader can draw the grass lip.
const LIP := 1.0

const SLOPE_YAW := [0.0, 0.0, -PI * 0.5, PI, PI * 0.5]  # index = SlopeDir; mesh rises toward -Z

var config: WorldGenerationConfig
var coords: WorldCoords
var water_offset := -0.14  # water sits slightly below the block top => visible bank lip


func _init(p_config: WorldGenerationConfig, p_coords: WorldCoords) -> void:
	config = p_config
	coords = p_coords


## Material key of the block `depth` levels below a column's top (depth 0 = top block).
static func layer_key(surface: int, depth: int, rocky: float) -> String:
	match surface:
		ChunkData.Surface.STONE:
			return "stone"
		ChunkData.Surface.SAND:
			if depth <= 1:
				return "sand"
			return "dirt" if depth <= 2 else "stone"
		ChunkData.Surface.DIRT:
			if depth == 0:
				return "dirt"
			return "dirt" if depth <= (1 if rocky > 0.35 else 2) else "stone"
		_:
			if depth == 0:
				return "grass"
			return "dirt" if depth <= (1 if rocky > 0.35 else 2) else "stone"


static func _mat_id(key: String) -> int:
	match key:
		"grass": return MAT_GRASS
		"stone": return MAT_STONE
		"sand": return MAT_SAND
		_: return MAT_DIRT


func build(d: ChunkData, lod: int) -> Dictionary:
	var res := {"coord": d.coord, "lod": lod, "data": d, "sections": []}
	var chunk_origin := coords.chunk_to_world(d.coord)
	var per_axis := config.detail_sections_per_axis if lod == Lod.NEAR else 1
	var sec_cells := d.size / per_axis
	for sz in per_axis:
		for sx in per_axis:
			var rect := Rect2i(d.margin + sx * sec_cells, d.margin + sz * sec_cells, sec_cells, sec_cells)
			var center := Vector3((sx + 0.5) * sec_cells * config.cell_size, 0.0, (sz + 0.5) * sec_cells * config.cell_size)
			# Put the section pivot at mid terrain height so visibility-range distances are honest.
			var mid_level := d.level[d.idx(rect.position.x + sec_cells / 2, rect.position.y + sec_cells / 2)]
			center.y = maxf(mid_level, d.water_level) * config.level_height
			var sec := {"rect": rect, "center": center}
			var offset := chunk_origin + center
			sec["terrain"] = _build_merged(d, rect, offset)
			sec["water_lod"] = _build_water_quads(d, rect, offset)
			var inst := {}
			if lod == Lod.NEAR:
				_build_block_instances(d, rect, inst, offset)
			_add_props(d, rect, inst, offset, lod)
			sec["instances"] = inst
			res.sections.append(sec)
	if lod == Lod.NEAR and config.generate_collision:
		var all := Rect2i(d.margin, d.margin, d.size, d.size)
		res["collision"] = _build_merged(d, all, chunk_origin)[0]
	return res


# ---------------------------------------------------------------------------

static func _push(buf: PackedFloat32Array, xf: Transform3D) -> void:
	var b := xf.basis
	buf.append_array([b.x.x, b.y.x, b.z.x, xf.origin.x,
		b.x.y, b.y.y, b.z.y, xf.origin.y,
		b.x.z, b.y.z, b.z.z, xf.origin.z])


static func _buf(inst: Dictionary, key: String) -> PackedFloat32Array:
	if not inst.has(key):
		inst[key] = PackedFloat32Array()
	return inst[key]


func _lowest_visible(d: ChunkData, x: int, z: int, t: int) -> int:
	var lo := t
	for o in ChunkData.NEIGHBOURS:
		lo = mini(lo, d.level_at(x + o.x, z + o.y))
	return maxi(lo, 0)


func _in_rect(rect: Rect2i, x: int, z: int) -> bool:
	return x >= rect.position.x and z >= rect.position.y and x < rect.end.x and z < rect.end.y


func _build_block_instances(d: ChunkData, rect: Rect2i, inst: Dictionary, offset: Vector3) -> void:
	var lh := config.level_height
	var w := d.water_level
	# Packed arrays are values in GDScript: collect locally, then store.
	var bufs := {"grass": PackedFloat32Array(), "dirt": PackedFloat32Array(), "stone": PackedFloat32Array(),
		"sand": PackedFloat32Array(), "slope": PackedFloat32Array(), "water": PackedFloat32Array()}
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var i := d.idx(x, z)
			var t := d.level[i]
			var surf := d.surface[i]
			var base := coords.cell_to_world(d.local_to_cell(x, z), 0) - offset
			var lo := _lowest_visible(d, x, z, t)
			if lo == t:
				lo = t - 1  # always draw the top block
			for lvl in range(lo, t):
				var key := layer_key(surf, t - 1 - lvl, d.rocky[i])
				var b: PackedFloat32Array = bufs[key]
				_push(b, Transform3D(Basis.IDENTITY, base + Vector3(0, lvl * lh, 0)))
				bufs[key] = b
			var sd := d.slope[i]
			if sd != ChunkData.SlopeDir.NONE:
				var sb: PackedFloat32Array = bufs.slope
				_push(sb, Transform3D(Basis(Vector3.UP, SLOPE_YAW[sd]), base + Vector3(0, t * lh, 0)))
				bufs.slope = sb
			if t < w:
				var wb: PackedFloat32Array = bufs.water
				_push(wb, Transform3D(Basis.IDENTITY, base + Vector3(0, (w - 1) * lh + water_offset, 0)))
				bufs.water = wb
	for k in bufs:
		if not bufs[k].is_empty():
			inst[k] = bufs[k]


func _add_props(d: ChunkData, rect: Rect2i, inst: Dictionary, offset: Vector3, lod: int) -> void:
	var cs := config.cell_size
	for key in d.props:
		var is_tree: bool = key.begins_with("tree")
		if lod == Lod.FAR and key.begins_with("rock_small"):
			continue  # small clutter is invisible at LOD distances
		for p in d.props[key]:
			var xf: Transform3D = p.xform
			var lx := int(floor(xf.origin.x / cs)) - d.origin_cell.x
			var lz := int(floor(xf.origin.z / cs)) - d.origin_cell.y
			if not _in_rect(rect, lx, lz):
				continue
			xf.origin -= offset
			if is_tree:
				# NEAR sections get the full tree too; every section gets the decimated tree and
				# the voxel stand-in (all swapped by distance).
				if lod == Lod.NEAR:
					var fb := _buf(inst, key)
					_push(fb, xf)
					inst[key] = fb
				for suffix in ["_lod", "_far"]:
					var lb := _buf(inst, key + suffix)
					_push(lb, xf)
					inst[key + suffix] = lb
			else:
				var rb := _buf(inst, key)
				_push(rb, xf)
				inst[key] = rb


# --- merged voxel mesh (LOD + collision) --------------------------------------

func _build_water_quads(d: ChunkData, rect: Rect2i, offset: Vector3) -> PackedVector3Array:
	var verts := PackedVector3Array()
	var cs := config.cell_size
	var y := d.water_level * config.level_height + water_offset - offset.y
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if d.level[d.idx(x, z)] < d.water_level:
				var c := d.local_to_cell(x, z)
				var p := Vector3(c.x * cs - offset.x, y, c.y * cs - offset.z)
				verts.append_array([p, p + Vector3(cs, 0, 0), p + Vector3(cs, 0, cs),
					p, p + Vector3(cs, 0, cs), p + Vector3(0, 0, cs)])
	return verts


## Returns [vertices, normals, uvs] for the exposed faces of the cells in `rect`.
func _build_merged(d: ChunkData, rect: Rect2i, offset: Vector3) -> Array:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cs := config.cell_size
	var lh := config.level_height
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var i := d.idx(x, z)
			var t := d.level[i]
			var surf := d.surface[i]
			var c := d.local_to_cell(x, z)
			var x0 := c.x * cs - offset.x
			var z0 := c.y * cs - offset.z
			var top := t * lh - offset.y
			var top_key := layer_key(surf, 0, d.rocky[i])
			var sd := d.slope[i]
			if sd == ChunkData.SlopeDir.NONE:
				_add_quad(verts, norms, uvs,
					Vector3(x0, top, z0), Vector3(x0 + cs, top, z0),
					Vector3(x0 + cs, top, z0 + cs), Vector3(x0, top, z0 + cs), Vector3.UP, _mat_id(top_key), 0.0)
			else:
				_add_ramp(verts, norms, uvs, x0, z0, top, cs, lh, sd)
				_add_ramp_sides(d, x, z, t, verts, norms, uvs, x0, z0, top, cs, lh, sd)
			# Cliff faces toward lower neighbours.
			for k in 4:
				var o: Vector2i = ChunkData.NEIGHBOURS[k]
				var nt := d.level_at(x + o.x, z + o.y)
				if nt >= t:
					continue
				for lvl in range(nt, t):
					var key := layer_key(surf, t - 1 - lvl, d.rocky[i])
					var lip := 0.0
					if key == "grass":
						key = "dirt"
						lip = LIP  # grass block: dirt sides with a grass rim
					_add_side(verts, norms, uvs, x0, z0, cs, lvl * lh - offset.y, (lvl + 1) * lh - offset.y, o, _mat_id(key), lip)
	return [verts, norms, uvs]


func _add_quad(v: PackedVector3Array, n: PackedVector3Array, u: PackedVector2Array,
		a: Vector3, b: Vector3, cc: Vector3, dd: Vector3, nrm: Vector3, mat: int, flag: float) -> void:
	_add_tri(v, n, u, a, b, cc, nrm, mat, flag)
	_add_tri(v, n, u, a, cc, dd, nrm, mat, flag)


static func _add_tri(v: PackedVector3Array, n: PackedVector3Array, u: PackedVector2Array,
		a: Vector3, b: Vector3, cc: Vector3, nrm: Vector3, mat: int, flag: float) -> void:
	# Godot front faces are clockwise as seen from the normal side.
	if (b - a).cross(cc - a).dot(nrm) > 0.0:
		var tmp := b
		b = cc
		cc = tmp
	v.append_array([a, b, cc])
	n.append_array([nrm, nrm, nrm])
	var uv := Vector2(mat + 0.5, flag)
	u.append_array([uv, uv, uv])


func _add_side(v: PackedVector3Array, n: PackedVector3Array, u: PackedVector2Array,
		x0: float, z0: float, cs: float, y0: float, y1: float, o: Vector2i, mat: int, flag: float) -> void:
	var nrm := Vector3(o.x, 0, o.y)
	var a: Vector3
	var b: Vector3
	if o.x == 1:
		a = Vector3(x0 + cs, 0, z0); b = Vector3(x0 + cs, 0, z0 + cs)
	elif o.x == -1:
		a = Vector3(x0, 0, z0); b = Vector3(x0, 0, z0 + cs)
	elif o.y == 1:
		a = Vector3(x0, 0, z0 + cs); b = Vector3(x0 + cs, 0, z0 + cs)
	else:
		a = Vector3(x0, 0, z0); b = Vector3(x0 + cs, 0, z0)
	_add_quad(v, n, u, a + Vector3(0, y0, 0), b + Vector3(0, y0, 0), b + Vector3(0, y1, 0), a + Vector3(0, y1, 0), nrm, mat, flag)


## Triangular side walls of a ramp, where the lateral neighbour doesn't hide them.
func _add_ramp_sides(d: ChunkData, x: int, z: int, t: int, v: PackedVector3Array, n: PackedVector3Array,
		u: PackedVector2Array, x0: float, z0: float, y: float, cs: float, lh: float, sd: int) -> void:
	var dir: Vector2i = ChunkData.NEIGHBOURS[sd - 1]
	for k in 4:
		var o: Vector2i = ChunkData.NEIGHBOURS[k]
		if o == dir or o == -dir:
			continue
		if d.level_at(x + o.x, z + o.y) > t:
			continue
		# Edge on side o, from the low end (-dir) to the high end (+dir).
		var mid := Vector3(x0 + cs * 0.5, y, z0 + cs * 0.5)
		var side := Vector3(o.x, 0, o.y) * cs * 0.5
		var along := Vector3(dir.x, 0, dir.y) * cs * 0.5
		var low := mid + side - along
		var high := mid + side + along
		_add_tri(v, n, u, low, high, high + Vector3(0, lh, 0), Vector3(o.x, 0, o.y), MAT_DIRT, LIP)


func _add_ramp(v: PackedVector3Array, n: PackedVector3Array, u: PackedVector2Array,
		x0: float, z0: float, y: float, cs: float, lh: float, sd: int) -> void:
	var p00 := Vector3(x0, y, z0)
	var p10 := Vector3(x0 + cs, y, z0)
	var p11 := Vector3(x0 + cs, y, z0 + cs)
	var p01 := Vector3(x0, y, z0 + cs)
	match sd:
		ChunkData.SlopeDir.NORTH:
			p00.y += lh; p10.y += lh
		ChunkData.SlopeDir.SOUTH:
			p01.y += lh; p11.y += lh
		ChunkData.SlopeDir.EAST:
			p10.y += lh; p11.y += lh
		ChunkData.SlopeDir.WEST:
			p00.y += lh; p01.y += lh
	var nrm := (p10 - p00).cross(p01 - p00).normalized()
	if nrm.y < 0.0:
		nrm = -nrm
	_add_quad(v, n, u, p00, p10, p11, p01, nrm, MAT_GRASS, 0.0)
