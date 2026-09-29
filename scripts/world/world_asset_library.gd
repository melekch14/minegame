class_name WorldAssetLibrary
extends RefCounted
## Loads the exported Blender assets (res://assets/models/*.glb), extracts their meshes and
## assigns Godot materials that reproduce the Blender node materials.
## One Mesh per asset key is shared by every MultiMesh in the world.

const MODEL_DIR := "res://assets/models/"
## Low-poly blocks with baked normal / material textures (tools/blender/bake_blocks.py).
## Used instead of the detailed block of the same name when present.
const BAKED_DIR := "res://assets/models/baked/"
const VOXEL_SHADER := preload("res://shaders/voxel_ramp.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")
const LOD_SHADER := preload("res://shaders/terrain_lod.gdshader")

## asset key -> glb basename. Keys are what the generators and ChunkData use.
const ASSETS := {
	"grass": "01_grass_block",
	"dirt": "02_dirt_block",
	"stone": "03_stone_block",
	"sand": "04_sand_block",
	"water": "05_water_tile",
	"slope": "06_grass_slope",
	"rock_large": "07_rock_large",
	"rock_small_a": "08_rock_small_a",
	"rock_small_b": "08_rock_small_b",
	"rock_small_c": "08_rock_small_c",
	"tree_large_a": "09_tree_large_a",
	"tree_large_b": "09_tree_large_b",
	"tree_large_c": "09_tree_large_c",
	"tree_small_a": "10_tree_small_a",
	"tree_small_b": "10_tree_small_b",
	"tree_small_c": "10_tree_small_c",
	# Decimated versions of the same trees, exported from the same .blend files, for distance.
	"tree_large_a_lod": "09_tree_large_a_lod",
	"tree_large_b_lod": "09_tree_large_b_lod",
	"tree_large_c_lod": "09_tree_large_c_lod",
	"tree_small_a_lod": "10_tree_small_a_lod",
	"tree_small_b_lod": "10_tree_small_b_lod",
	"tree_small_c_lod": "10_tree_small_c_lod",
}

## Blender material name -> ramp (linear colours) and noise settings, copied from the .blend files.
const MATERIALS := {
	"MAT_Terrain_Grass": {"ramp": [[0.0, Color(0.02, 0.105, 0.008)], [0.3, Color(0.04, 0.19, 0.012)], [0.55, Color(0.075, 0.28, 0.02)], [0.78, Color(0.12, 0.38, 0.03)], [0.93, Color(0.19, 0.47, 0.045)]], "scale": 1.6, "coarse": 0.25, "fine": 0.125, "white": 0.45, "rough": 0.92},
	"MAT_Terrain_Dirt": {"ramp": [[0.0, Color(0.05, 0.024, 0.011)], [0.3, Color(0.09, 0.045, 0.02)], [0.62, Color(0.135, 0.07, 0.032)], [0.86, Color(0.18, 0.1, 0.05)], [0.95, Color(0.15, 0.135, 0.115)]], "scale": 1.6, "coarse": 0.25, "fine": 0.125, "white": 0.3, "rough": 0.95},
	"MAT_Terrain_Dirt_Dark": {"ramp": [[0.0, Color(0.022, 0.011, 0.006)], [0.35, Color(0.04, 0.02, 0.01)], [0.7, Color(0.062, 0.032, 0.015)], [0.93, Color(0.085, 0.075, 0.065)]], "scale": 1.6, "coarse": 0.25, "fine": 0.125, "white": 0.3, "rough": 0.97},
	"MAT_Terrain_Soil_Detail": {"ramp": [[0.0, Color(0.056, 0.05, 0.044)], [0.3, Color(0.096, 0.086, 0.074)], [0.62, Color(0.144, 0.132, 0.112)], [0.86, Color(0.2, 0.186, 0.16)], [0.95, Color(0.088, 0.056, 0.036)]], "scale": 1.6, "coarse": 0.125, "fine": 0.0625, "white": 0.25, "rough": 0.9},
	"MAT_Terrain_Stone": {"ramp": [[0.0, Color(0.092, 0.092, 0.091)], [0.35, Color(0.112, 0.111, 0.109)], [0.7, Color(0.13, 0.128, 0.124)], [0.93, Color(0.15, 0.147, 0.14)]], "scale": 1.6, "coarse": 0.25, "fine": 0.125, "white": 0.35, "rough": 0.88},
	"MAT_Terrain_Stone_Dark": {"ramp": [[0.0, Color(0.03, 0.03, 0.031)], [0.4, Color(0.043, 0.043, 0.044)], [0.8, Color(0.058, 0.057, 0.056)]], "scale": 1.6, "coarse": 0.25, "fine": 0.125, "white": 0.3, "rough": 0.9},
	"MAT_Terrain_Stone_Light": {"ramp": [[0.0, Color(0.14, 0.134, 0.123)], [0.35, Color(0.16, 0.153, 0.14)], [0.7, Color(0.178, 0.17, 0.156)], [0.93, Color(0.198, 0.189, 0.173)]], "scale": 1.6, "coarse": 0.25, "fine": 0.125, "white": 0.35, "rough": 0.86},
	"MAT_Terrain_Sand": {"ramp": [[0.0, Color(0.47, 0.315, 0.14)], [0.22, Color(0.545, 0.38, 0.175)], [0.5, Color(0.62, 0.45, 0.215)], [0.8, Color(0.68, 0.515, 0.255)], [0.94, Color(0.72, 0.585, 0.27)]], "scale": 2.2, "coarse": 0.125, "fine": 0.0625, "white": 0.4, "rough": 0.93},
	"MAT_Terrain_Sand_Dark": {"ramp": [[0.0, Color(0.36, 0.235, 0.1)], [0.35, Color(0.42, 0.28, 0.125)], [0.7, Color(0.475, 0.325, 0.15)], [0.93, Color(0.53, 0.37, 0.175)]], "scale": 2.2, "coarse": 0.125, "fine": 0.0625, "white": 0.35, "rough": 0.95},
	"MAT_Environment_Rock": {"ramp": [[0.0, Color(0.055, 0.055, 0.057)], [0.25, Color(0.085, 0.084, 0.083)], [0.5, Color(0.112, 0.11, 0.106)], [0.75, Color(0.138, 0.133, 0.124)], [0.92, Color(0.165, 0.157, 0.143)]], "scale": 1.6, "coarse": 0.125, "fine": 0.0625, "white": 0.45, "rough": 0.9},
	"MAT_Tree_Bark": {"ramp": [[0.0, Color(0.06, 0.03, 0.014)], [0.3, Color(0.095, 0.05, 0.024)], [0.62, Color(0.13, 0.07, 0.034)], [0.86, Color(0.165, 0.092, 0.046)]], "scale": 1.6, "coarse": 0.1875, "fine": 0.0625, "white": 0.35, "rough": 0.9},
	"MAT_Tree_Bark_Dark": {"ramp": [[0.0, Color(0.022, 0.012, 0.006)], [0.4, Color(0.036, 0.019, 0.009)], [0.78, Color(0.052, 0.028, 0.013)]], "scale": 1.6, "coarse": 0.1875, "fine": 0.0625, "white": 0.35, "rough": 0.92},
	"MAT_Tree_Bark_Light": {"ramp": [[0.0, Color(0.14, 0.08, 0.04)], [0.4, Color(0.18, 0.105, 0.054)], [0.78, Color(0.215, 0.13, 0.068)]], "scale": 1.6, "coarse": 0.1875, "fine": 0.0625, "white": 0.35, "rough": 0.88},
	"MAT_Tree_Leaves": {"ramp": [[0.0, Color(0.03, 0.14, 0.012)], [0.3, Color(0.045, 0.19, 0.016)], [0.62, Color(0.065, 0.24, 0.022)], [0.88, Color(0.095, 0.3, 0.03)]], "scale": 1.6, "coarse": 0.375, "fine": 0.125, "white": 0.35, "rough": 0.85},
	"MAT_Tree_Leaves_Dark": {"ramp": [[0.0, Color(0.01, 0.06, 0.008)], [0.4, Color(0.016, 0.085, 0.01)], [0.78, Color(0.024, 0.11, 0.013)]], "scale": 1.6, "coarse": 0.375, "fine": 0.125, "white": 0.35, "rough": 0.88},
	"MAT_Tree_Leaves_Light": {"ramp": [[0.0, Color(0.09, 0.29, 0.028)], [0.4, Color(0.125, 0.35, 0.036)], [0.78, Color(0.17, 0.42, 0.045)]], "scale": 1.6, "coarse": 0.375, "fine": 0.125, "white": 0.35, "rough": 0.82},
}

var meshes: Dictionary = {}          # key -> Mesh
var mesh_offsets: Dictionary = {}    # key -> Transform3D (node transform inside the glb)
var water_material: ShaderMaterial
var lod_material: ShaderMaterial
var _material_cache: Dictionary = {}
var _material_ids: Dictionary = {}
var missing: PackedStringArray = []


## `cfg` supplies far_tree_voxel_size for the generated `tree_*_far` stand-ins.
func load_all(cfg: WorldGenerationConfig = null) -> bool:
	water_material = ShaderMaterial.new()
	water_material.shader = WATER_SHADER
	lod_material = ShaderMaterial.new()
	lod_material.shader = LOD_SHADER
	_setup_lod_material()
	var f := FileAccess.open(MODEL_DIR + "material_ids.json", FileAccess.READ)
	if f:
		_material_ids = JSON.parse_string(f.get_as_text())
	else:
		push_error("WorldAssetLibrary: missing %smaterial_ids.json (re-export the assets)" % MODEL_DIR)
	for key in ASSETS:
		var baked := ResourceLoader.exists(BAKED_DIR + ASSETS[key] + ".glb")
		var path: String = (BAKED_DIR if baked else MODEL_DIR) + ASSETS[key] + ".glb"
		if not ResourceLoader.exists(path):
			missing.append(path)
			continue
		var scene: PackedScene = load(path)
		var root := scene.instantiate()
		var found := _find_mesh(root, Transform3D.IDENTITY)
		root.free()
		if found.is_empty():
			missing.append(path)
			continue
		var mesh: Mesh = found.mesh
		_apply_materials(mesh, key, baked)
		meshes[key] = mesh
		mesh_offsets[key] = found.xform
	# Very distant trees: blocky voxel versions of the decimated trees (a few hundred triangles).
	var voxel := cfg.far_tree_voxel_size if cfg else 1.0
	for key in ASSETS:
		if key.begins_with("tree") and key.ends_with("_lod") and meshes.has(key):
			var far_key: String = key.trim_suffix("_lod") + "_far"
			meshes[far_key] = build_voxel_proxy(meshes[key], voxel)
			mesh_offsets[far_key] = mesh_offsets[key]
	if not missing.is_empty():
		push_error("WorldAssetLibrary: missing assets %s" % [missing])
	return missing.is_empty()


## The merged LOD terrain uses the same Blender ramps as the real blocks' top materials.
func _setup_lod_material() -> void:
	_fill_ramp_params(lod_material, ["MAT_Terrain_Grass", "MAT_Terrain_Dirt", "MAT_Terrain_Stone", "MAT_Terrain_Sand"])


## Writes the per-material ramp/noise arrays expected by voxel_ramp / terrain_lod shaders.
## Colours go in as Vector4: a Color would be treated as sRGB and linearised a second time.
func _fill_ramp_params(m: ShaderMaterial, names: Array) -> void:
	var cols := PackedVector4Array()
	var pos_a := PackedVector4Array()
	var pos_b := PackedFloat32Array()
	var counts := PackedInt32Array()
	var scale := PackedFloat32Array()
	var coarse := PackedFloat32Array()
	var fine := PackedFloat32Array()
	var white := PackedFloat32Array()
	var rough := PackedFloat32Array()
	for mname in names:
		var def: Dictionary = MATERIALS.get(mname, MATERIALS["MAT_Terrain_Dirt"])
		if not MATERIALS.has(mname):
			push_warning("WorldAssetLibrary: no ramp for material '%s', using dirt" % mname)
		var ramp: Array = def.ramp
		var pos := [1.0, 1.0, 1.0, 1.0, 1.0]
		for k in 5:
			var e: Array = ramp[mini(k, ramp.size() - 1)]
			var c: Color = e[1]
			cols.append(Vector4(c.r, c.g, c.b, 1.0))
			if k < ramp.size():
				pos[k] = e[0]
		pos_a.append(Vector4(pos[0], pos[1], pos[2], pos[3]))
		pos_b.append(pos[4])
		counts.append(ramp.size())
		scale.append(def.scale)
		coarse.append(def.coarse)
		fine.append(def.fine)
		white.append(def.white)
		rough.append(def.rough)
	m.set_shader_parameter("ramp_cols", cols)
	m.set_shader_parameter("ramp_pos_a", pos_a)
	m.set_shader_parameter("ramp_pos_b", pos_b)
	m.set_shader_parameter("ramp_count", counts)
	m.set_shader_parameter("noise_scale", scale)
	m.set_shader_parameter("snap_coarse", coarse)
	m.set_shader_parameter("snap_fine", fine)
	m.set_shader_parameter("white_mix", white)
	m.set_shader_parameter("roughness_mat", rough)


## Voxelises `src` on a `voxel`-metre grid: each voxel touched by the surface takes the
## material covering most of it (UV.x), enclosed voxels are filled, and only faces toward
## the outside are emitted. Same material and UV.x convention as `src`.
static func build_voxel_proxy(src: Mesh, voxel: float) -> ArrayMesh:
	var a := src.surface_get_arrays(0)
	var sv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var suv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var sidx = a[Mesh.ARRAY_INDEX]
	var ids := PackedInt32Array(sidx) if sidx != null else PackedInt32Array(range(sv.size()))
	var aabb := src.get_aabb()
	var org := aabb.position
	var dim := Vector3i((aabb.size / voxel).floor()) + Vector3i.ONE
	var cells := dim.x * dim.y * dim.z
	var cell := func(p: Vector3) -> int:
		var c := Vector3i(((p - org) / voxel).floor()).clamp(Vector3i.ZERO, dim - Vector3i.ONE)
		return (c.y * dim.z + c.z) * dim.x + c.x
	# Area-weighted material votes from points sampled at <= voxel / 2 spacing on each triangle.
	var votes := {}  # cell -> {mat: weight}
	for t in range(0, ids.size(), 3):
		var p0 := sv[ids[t]]
		var p1 := sv[ids[t + 1]]
		var p2 := sv[ids[t + 2]]
		var mat := int(suv[ids[t]].x)
		var n := maxi(1, ceili(maxf(p0.distance_to(p1), maxf(p1.distance_to(p2), p2.distance_to(p0))) / (voxel * 0.5)))
		var w := (p1 - p0).cross(p2 - p0).length() / float((n + 1) * (n + 2) / 2)
		for i in n + 1:
			for j in n + 1 - i:
				var c: int = cell.call(p0 + (p1 - p0) * (float(i) / n) + (p2 - p0) * (float(j) / n))
				var v: Dictionary = votes.get_or_add(c, {})
				v[mat] = v.get(mat, 0.0) + w
	var solid := PackedInt32Array()
	solid.resize(cells)
	solid.fill(-1)
	for c in votes:
		var best := -1
		for m in votes[c]:
			if best < 0 or votes[c][m] > votes[c][best]:
				best = m
		solid[c] = best
	# Flood the outside from the grid border; empty cells it can't reach are interior.
	var outside := PackedByteArray()
	outside.resize(cells)
	var stack: Array[Vector3i] = []
	for z in dim.z:
		for y in dim.y:
			for x in dim.x:
				if x == 0 or y == 0 or z == 0 or x == dim.x - 1 or y == dim.y - 1 or z == dim.z - 1:
					stack.append(Vector3i(x, y, z))
	const DIRS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		var i := (c.y * dim.z + c.z) * dim.x + c.x
		if outside[i] or solid[i] >= 0:
			continue
		outside[i] = 1
		for d: Vector3i in DIRS:
			var nc: Vector3i = c + d
			if nc.x >= 0 and nc.y >= 0 and nc.z >= 0 and nc.x < dim.x and nc.y < dim.y and nc.z < dim.z:
				stack.append(nc)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	for y in dim.y:
		for z in dim.z:
			for x in dim.x:
				var mat := solid[(y * dim.z + z) * dim.x + x]
				if mat < 0:
					continue
				var lo := org + Vector3(x, y, z) * voxel
				for d: Vector3i in DIRS:
					var nc := Vector3i(x, y, z) + d
					var inside := nc.x >= 0 and nc.y >= 0 and nc.z >= 0 and nc.x < dim.x and nc.y < dim.y and nc.z < dim.z
					if inside and not outside[(nc.y * dim.z + nc.z) * dim.x + nc.x]:
						continue
					_add_voxel_face(verts, norms, uvs, lo, voxel, Vector3(d), mat)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, src.surface_get_material(0))
	return mesh


static func _add_voxel_face(v: PackedVector3Array, n: PackedVector3Array, u: PackedVector2Array,
		lo: Vector3, s: float, nrm: Vector3, mat: int) -> void:
	# Face of the cube [lo, lo + s] on the `nrm` side, spanned by the two other axes.
	var c := lo + Vector3.ONE * s * 0.5 + nrm * s * 0.5
	var ax := Vector3(nrm.y, nrm.z, nrm.x) * s * 0.5
	var ay := nrm.cross(ax)
	var p := [c - ax - ay, c + ax - ay, c + ax + ay, c - ax + ay]
	ChunkMesher._add_tri(v, n, u, p[0], p[1], p[2], nrm, mat, 0.0)
	ChunkMesher._add_tri(v, n, u, p[0], p[2], p[3], nrm, mat, 0.0)


func _find_mesh(n: Node, parent_xf: Transform3D) -> Dictionary:
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return {"mesh": (n as MeshInstance3D).mesh, "xform": xf}
	for c in n.get_children():
		var r := _find_mesh(c, xf)
		if not r.is_empty():
			return r
	return {}


static func base_material_name(n: String) -> String:
	var rx := RegEx.create_from_string("\\.\\d+$")
	return rx.sub(n, "")


func _apply_materials(mesh: Mesh, key: String, baked := false) -> void:
	if key == "water":
		for si in mesh.get_surface_count():
			mesh.surface_set_material(si, water_material)
		return
	# Every exported asset is a single surface; material_ids.json lists, per asset, the
	# Blender materials whose index the exporter stored in UV.x.
	var order: Array = _material_ids.get(ASSETS[key], [])
	if order.is_empty():
		push_warning("WorldAssetLibrary: %s has no material id table" % key)
		order = ["MAT_Terrain_Dirt"]
	var sig := ",".join(PackedStringArray(order))
	if not _material_cache.has(sig):
		var m := ShaderMaterial.new()
		m.shader = VOXEL_SHADER
		m.resource_name = sig
		_fill_ramp_params(m, order)
		_material_cache[sig] = m
	var mat: ShaderMaterial = _material_cache[sig]
	if baked:
		# Same ramps; material index and normal read from this block's baked textures.
		mat = mat.duplicate()
		mat.resource_name = ASSETS[key] + " (baked)"
		mat.set_shader_parameter("baked", true)
		mat.set_shader_parameter("baked_normal", load(BAKED_DIR + ASSETS[key] + "_normal.png"))
		mat.set_shader_parameter("baked_mat_ao", load(BAKED_DIR + ASSETS[key] + "_matao.png"))
	for si in mesh.get_surface_count():
		mesh.surface_set_material(si, mat)
