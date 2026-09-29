extends SceneTree
## Developer tool: checks the rendered world geometry for wrongly facing faces and for
## overlapping coplanar faces (z-fighting, i.e. flickering blocks). Headless, no window:
##   godot --headless --path <project> --script res://scripts/world/debug/geometry_check.gd -- [radius_chunks] [center_chunk_x] [center_chunk_z]
## Chunks are generated at NEAR detail exactly as ChunkManager / WorldChunk build them.
## Exit code 0 = clean, 1 = issues found.
##
## Checks
##   1. Asset meshes (WorldAssetLibrary): winding vs stored normal, degenerate triangles, and
##      for the box-like terrain blocks, faces pointing into the block.
##   2. Terrain meshes (merged LOD mesh, Backing, water quads): winding vs stored normal, and
##      faces that point the wrong way (front side in the ground, back side in the air).
##      Faces with both sides in the ground are hidden (wasted, not visible): reported, not
##      counted as issues.
##   3. Z-fighting: two triangles that can be drawn at the same time, lie in the same plane,
##      face the same way and overlap with positive area. Backing is shadow-only and never
##      drawn on screen, so it is left out. "Detail" geometry (blocks) of a section and "LOD" geometry (merged mesh + water quads) are never shown together in
##      one section, but can be across a section boundary.

const DEPTH_EPS := 0.01      # m: planes closer than this fight in the depth buffer
const NORMAL_EPS := 0.999    # cos of the max angle between "parallel" normals
const SHRINK := 0.002        # m: triangles are shrunk so shared edges don't count as overlap
const PROBE := 0.3           # m: distance of the solid/air probes along a terrain face normal
const GRID := 2.0            # m: spatial hash cell for the overlap search
const MAX_EXAMPLES := 8
const BOX_KEYS := ["grass", "dirt", "stone", "sand", "slope", "water"]

var config: WorldGenerationConfig
var gen: WorldGenerator
var lib: WorldAssetLibrary
var issues := 0

# Triangle soup for the z-fighting pass (world space).
var tri_a := PackedVector3Array()
var tri_b := PackedVector3Array()
var tri_c := PackedVector3Array()
var tri_src: Array[String] = []         # "grass", "Backing", "TerrainLOD"...
var tri_section := PackedInt32Array()   # global section index
var tri_detail := PackedByteArray()     # 1 = near-detail geometry, 0 = LOD geometry


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var radius := int(args[0]) if args.size() > 0 else 1
	var center := Vector2i(int(args[1]), int(args[2])) if args.size() > 2 else Vector2i.ZERO
	config = load("res://resources/world/world_generation_config.tres")
	gen = WorldGenerator.new()
	gen.setup(config, WorldModifications.new())
	lib = WorldAssetLibrary.new()
	lib.load_all(config)
	var t0 := Time.get_ticks_msec()
	_check_assets()
	var section := 0
	for cz in range(center.y - radius, center.y + radius + 1):
		for cx in range(center.x - radius, center.x + radius + 1):
			section = _collect_chunk(Vector2i(cx, cz), section)
	print("\n== Terrain faces: %d chunks, %d sections, %d triangles" % [(radius * 2 + 1) * (radius * 2 + 1), section, tri_a.size()])
	_check_zfighting()
	print("\n%s in %.1f s" % ["OK: no issues" if issues == 0 else "FOUND %d issue(s)" % issues,
		(Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if issues == 0 else 1)


# --- 1. asset meshes ----------------------------------------------------------

func _check_assets() -> void:
	print("== Asset meshes")
	var keys := lib.meshes.keys()
	keys.sort()
	for key in keys:
		var mesh: Mesh = lib.meshes[key]
		var flipped := 0
		var degenerate := 0
		var inward := 0
		var tris := 0
		var center := mesh.get_aabb().get_center()
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var ids := _indices(arr)
			for t in range(0, ids.size(), 3):
				tris += 1
				var a := v[ids[t]]
				var b := v[ids[t + 1]]
				var c := v[ids[t + 2]]
				var fn := _front_normal(a, b, c)
				if fn == Vector3.ZERO:
					degenerate += 1
					continue
				var sn := (n[ids[t]] + n[ids[t + 1]] + n[ids[t + 2]]).normalized()
				if fn.dot(sn) < -0.1:
					flipped += 1
				if key in BOX_KEYS and fn.dot((a + b + c) / 3.0 - center) < -1e-4:
					inward += 1
		var bad := flipped + inward
		issues += bad
		var line := "  %-20s %6d tris" % [key, tris]
		if flipped:
			line += "  %d winding/normal mismatch" % flipped
		if inward:
			line += "  %d facing into the block" % inward
		if degenerate:
			line += "  (%d degenerate, harmless)" % degenerate
		print(line + ("" if bad else "  ok"))


# --- 2. terrain meshes --------------------------------------------------------

func _collect_chunk(c: Vector2i, section: int) -> int:
	var res := gen.generate_chunk(c, ChunkMesher.Lod.NEAR)
	var d: ChunkData = res.data
	var origin := gen.coords.chunk_to_world(c)
	var stats := {"flipped": [], "inverted": [], "floating": [], "hidden": []}
	for sec in res.sections:
		var base: Vector3 = origin + sec.center
		var terrain: Array = sec.terrain
		_add_terrain(terrain[0], terrain[1], base, "TerrainLOD", section, 0, d, stats)
		_add_terrain(terrain[0], terrain[1], base + Vector3(0, WorldChunk.BACKING_OFFSET, 0), "Backing", section, -1, d, stats)
		_add_terrain(sec.water_lod, PackedVector3Array(), base, "WaterLOD", section, 0, null, stats)
		var inst: Dictionary = sec.instances
		for key in inst:
			if key in BOX_KEYS:
				_add_instances(key, inst[key], base, section)
		section += 1
	const WHAT := {"flipped": "winding/normal mismatch", "inverted": "facing into the ground",
		"floating": "air on both sides", "hidden": "hidden inside the ground (harmless)"}
	for kind in stats:
		var list: Array = stats[kind]
		if list.is_empty():
			continue
		if kind != "hidden":
			issues += list.size()
		print("  chunk %s: %d %s, e.g. %s" % [c, list.size(), WHAT[kind], list.slice(0, 3)])
	return section


func _add_terrain(v: PackedVector3Array, n: PackedVector3Array, base: Vector3, src: String,
		section: int, detail: int, d: ChunkData, stats: Dictionary) -> void:
	for t in range(0, v.size(), 3):
		var a := v[t] + base
		var b := v[t + 1] + base
		var c := v[t + 2] + base
		var fn := _front_normal(a, b, c)
		if fn == Vector3.ZERO:
			continue
		var mid := (a + b + c) / 3.0
		if not n.is_empty() and fn.dot((n[t] + n[t + 1] + n[t + 2]).normalized()) < -0.1:
			stats.flipped.append("%s @ %s" % [src, _fmt(mid)])
		elif d != null:
			var front := _solid(d, mid + fn * PROBE)
			var back := _solid(d, mid - fn * PROBE)
			if front or not back:  # correct: air in front, ground behind
				var kind := ("hidden" if back else "inverted") if front else "floating"
				stats[kind].append("%s @ %s n=%s" % [src, _fmt(mid), _fmt(fn)])
		if detail >= 0:  # -1: shadow-only, never drawn on screen
			_push(a, b, c, src, section, detail)


func _add_instances(key: String, buf: PackedFloat32Array, base: Vector3, section: int) -> void:
	var arr := (lib.meshes[key] as Mesh).surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var ids := _indices(arr)
	for i in range(0, buf.size(), 12):
		var xf := Transform3D(Basis(Vector3(buf[i], buf[i + 4], buf[i + 8]), Vector3(buf[i + 1], buf[i + 5], buf[i + 9]),
			Vector3(buf[i + 2], buf[i + 6], buf[i + 10])), Vector3(buf[i + 3], buf[i + 7], buf[i + 11]) + base)
		for t in range(0, ids.size(), 3):
			_push(xf * v[ids[t]], xf * v[ids[t + 1]], xf * v[ids[t + 2]], key, section, 1)


## True if world point p is inside the terrain of chunk data d (slopes included).
func _solid(d: ChunkData, p: Vector3) -> bool:
	var cell := gen.coords.world_to_cell(p)
	var l := cell - d.origin_cell
	if not d.in_span(l.x, l.y):
		return false
	var i := d.idx(l.x, l.y)
	var h := d.level[i] * config.level_height
	var sd := d.slope[i]
	if sd != ChunkData.SlopeDir.NONE:
		var fx := p.x / config.cell_size - cell.x
		var fz := p.z / config.cell_size - cell.y
		var s: float = [0.0, 1.0 - fz, fx, fz, 1.0 - fx][sd]
		h += config.level_height * s
	return p.y < h


# --- 3. z-fighting ------------------------------------------------------------

func _push(a: Vector3, b: Vector3, c: Vector3, src: String, section: int, detail: int) -> void:
	tri_a.append(a)
	tri_b.append(b)
	tri_c.append(c)
	tri_src.append(src)
	tri_section.append(section)
	tri_detail.append(detail)


func _check_zfighting() -> void:
	# Bucket by (quantised normal, plane distance slab), then a 2D grid inside each bucket.
	var grid := {}   # [nkey, dslab, gx, gy] -> PackedInt32Array of triangle ids
	var pairs := {}  # "srcA × srcB" -> count
	var examples := {}
	for i in tri_a.size():
		var fn := _front_normal(tri_a[i], tri_b[i], tri_c[i])
		if fn == Vector3.ZERO:
			continue
		var nkey := Vector3i((fn * 50.0).round())
		var dist := fn.dot(tri_a[i])
		var slab := floori(dist / DEPTH_EPS)
		var ax := _drop_axis(fn)
		var p := [_proj(tri_a[i], ax), _proj(tri_b[i], ax), _proj(tri_c[i], ax)]
		var lo := Vector2(minf(p[0].x, minf(p[1].x, p[2].x)), minf(p[0].y, minf(p[1].y, p[2].y)))
		var hi := Vector2(maxf(p[0].x, maxf(p[1].x, p[2].x)), maxf(p[0].y, maxf(p[1].y, p[2].y)))
		var g0 := Vector2i((lo / GRID).floor())
		var g1 := Vector2i((hi / GRID).floor())
		var tested := {}
		for gy in range(g0.y, g1.y + 1):
			for gx in range(g0.x, g1.x + 1):
				for ds in [-1, 0, 1]:
					for j in grid.get([nkey, slab + ds, gx, gy], PackedInt32Array()):
						if tested.has(j):
							continue
						tested[j] = true
						if not _drawn_together(i, j):
							continue
						var fj := _front_normal(tri_a[j], tri_b[j], tri_c[j])
						if fj.dot(fn) < NORMAL_EPS or absf(fj.dot(tri_a[j]) - dist) > DEPTH_EPS:
							continue
						var q := [_proj(tri_a[j], ax), _proj(tri_b[j], ax), _proj(tri_c[j], ax)]
						if _overlap_2d(p, q):
							var names := [tri_src[i], tri_src[j]]
							names.sort()
							var k := "%s × %s" % names
							pairs[k] = pairs.get(k, 0) + 1
							var ex: Array = examples.get_or_add(k, [])
							if ex.size() < MAX_EXAMPLES:
								ex.append(_fmt((tri_a[i] + tri_b[i] + tri_c[i]) / 3.0))
				var key := [nkey, slab, gx, gy]
				var cell: PackedInt32Array = grid.get(key, PackedInt32Array())
				cell.append(i)
				grid[key] = cell
	print("\n== Z-fighting (coplanar, same-facing, overlapping, drawn together)")
	if pairs.is_empty():
		print("  none")
		return
	for k in pairs:
		issues += pairs[k]
		print("  %-26s %6d triangle pairs, e.g. at %s" % [k, pairs[k], ", ".join(examples[k].slice(0, 4))])


func _drawn_together(i: int, j: int) -> bool:
	if tri_detail[i] == tri_detail[j]:
		return true
	return tri_section[i] != tri_section[j]  # detail vs LOD only across a section boundary


## Strict 2D triangle overlap (separating axis), after shrinking both triangles slightly.
func _overlap_2d(p: Array, q: Array) -> bool:
	p = _shrink(p)
	q = _shrink(q)
	for tri in [p, q]:
		for e in 3:
			var edge: Vector2 = tri[(e + 1) % 3] - tri[e]
			var axis := Vector2(-edge.y, edge.x)
			var pa := _extent(p, axis)
			var qa := _extent(q, axis)
			if pa.y <= qa.x or qa.y <= pa.x:
				return false
	return true


func _shrink(t: Array) -> Array:
	var c: Vector2 = (t[0] + t[1] + t[2]) / 3.0
	var out := []
	for v: Vector2 in t:
		var dv := c - v
		out.append(v + dv.normalized() * minf(SHRINK, dv.length() * 0.5))
	return out


func _extent(t: Array, axis: Vector2) -> Vector2:
	var a: float = t[0].dot(axis)
	var b: float = t[1].dot(axis)
	var c: float = t[2].dot(axis)
	return Vector2(minf(a, minf(b, c)), maxf(a, maxf(b, c)))


# --- helpers ------------------------------------------------------------------

## Godot front faces are clockwise seen from the front, so the front normal is (c-a)x(b-a).
static func _front_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (c - a).cross(b - a)
	return n.normalized() if n.length_squared() > 1e-12 else Vector3.ZERO


static func _indices(arr: Array) -> PackedInt32Array:
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx != null and not (idx as PackedInt32Array).is_empty():
		return idx
	return PackedInt32Array(range((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()))


static func _drop_axis(n: Vector3) -> int:
	var m := n.abs()
	return 0 if m.x >= m.y and m.x >= m.z else (1 if m.y >= m.z else 2)


static func _proj(v: Vector3, drop: int) -> Vector2:
	match drop:
		0: return Vector2(v.y, v.z)
		1: return Vector2(v.x, v.z)
		_: return Vector2(v.x, v.y)


static func _fmt(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]
