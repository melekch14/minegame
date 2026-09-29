class_name WorldChunk
extends Node3D
## Scene-side representation of one chunk. Holds the generated ChunkData (terrain data,
## biome info, spawned objects) and the nodes built from it:
##
##   Section_i (Node3D at the section centre)
##     Terrain LOD mesh          -> visible beyond detail_view_distance (always, for FAR chunks)
##     Water LOD quads           -> same
##     Blocks / slope / water    -> MultiMesh of the real Blender assets, visible up close (NEAR)
##     Trees                     -> full trees up close, decimated trees beyond, voxel
##                                  stand-ins beyond tree_far_distance
##     Rocks
##   Collision (StaticBody3D, NEAR only)

var coord: Vector2i
var lod: int = -1
var data: ChunkData
var generation_seed: int
var _collision: StaticBody3D


func apply(res: Dictionary, lib: WorldAssetLibrary, cfg: WorldGenerationConfig) -> void:
	for c in get_children():
		c.queue_free()
	_collision = null
	data = res.data
	lod = res.lod
	coord = res.coord
	generation_seed = data.gen_seed
	var near: bool = lod == ChunkMesher.Lod.NEAR
	var dd := cfg.detail_view_distance
	var td := cfg.tree_detail_distance
	var fd := cfg.tree_far_distance
	var m := cfg.lod_switch_margin

	var idx := 0
	for sec in res.sections:
		var s := Node3D.new()
		s.name = "Section_%d" % idx
		s.position = sec.center
		add_child(s)
		idx += 1
		var terrain: Array = sec.terrain
		# Merged voxel mesh: the only terrain in FAR chunks; the distant stand-in in NEAR ones.
		var lod_mesh := _add_array_mesh(s, "TerrainLOD", terrain[0], terrain[1], terrain[2], lib.lod_material, true)
		var water_lod := _add_array_mesh(s, "WaterLOD", sec.water_lod, PackedVector3Array(), PackedVector2Array(), lib.water_material, false)
		if near and lod_mesh:
			# HLOD: the merged mesh is the parent. Detailed geometry below uses it as its
			# visibility_parent, so it appears exactly when the parent hides (camera closer
			# than dd). One distance test per section => the two can never both be hidden.
			_set_range(lod_mesh, dd, 0.0, m)
			_set_range(water_lod, dd, 0.0, m)
			# Backing: the bevelled Blender blocks leave pin-holes where four corners meet.
			# A copy of the merged mesh slightly below the block tops fills them with ground.
			# It is also the terrain's shadow caster up close: the blocks themselves (hundreds
			# to thousands of triangles each) don't cast shadows.
			var backing := MeshInstance3D.new()
			backing.name = "Backing"
			backing.mesh = lod_mesh.mesh
			backing.position = Vector3(0.0, -0.18, 0.0)
			backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			s.add_child(backing)
			backing.visibility_parent = backing.get_path_to(lod_mesh)
		var inst: Dictionary = sec.instances
		for key in inst:
			var buf: PackedFloat32Array = inst[key]
			if buf.is_empty():
				continue
			var is_block: bool = key in ["grass", "dirt", "stone", "sand", "slope", "water"]
			var is_far_tree: bool = key.begins_with("tree") and key.ends_with("_far")
			var shadows: bool = (near and not is_block and not is_far_tree) or key == "rock_large"
			var mmi := _add_multimesh(s, key, buf, lib, shadows)
			if mmi == null:
				continue
			if is_far_tree:
				_set_range(mmi, fd, 0.0, m)
			elif key.begins_with("tree") and key.ends_with("_lod"):
				_set_range(mmi, td if near else 0.0, fd, m)
			elif not near:
				continue
			elif is_block:
				if lod_mesh:
					mmi.visibility_parent = mmi.get_path_to(lod_mesh)
			elif key.begins_with("tree"):
				_set_range(mmi, 0.0, td, m)
			elif key.begins_with("rock_small"):
				_set_range(mmi, 0.0, cfg.small_rock_view_distance, m)

	if res.has("collision") and res.collision.size() > 0:
		_collision = StaticBody3D.new()
		_collision.name = "Collision"
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(res.collision)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		_collision.add_child(cs)
		add_child(_collision)


## True once this chunk's StaticBody3D exists (NEAR chunks with collision enabled).
func has_collision() -> bool:
	return _collision != null


## begin/end in metres from the camera; 0 disables that side.
static func _set_range(g: GeometryInstance3D, begin: float, end: float, margin: float) -> void:
	if g == null:
		return
	g.visibility_range_begin = begin
	g.visibility_range_end = end
	g.visibility_range_begin_margin = margin if begin > 0.0 else 0.0
	g.visibility_range_end_margin = margin if end > 0.0 else 0.0
	g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


func _add_multimesh(parent: Node3D, key: String, buf: PackedFloat32Array, lib: WorldAssetLibrary, shadows: bool) -> MultiMeshInstance3D:
	if not lib.meshes.has(key):
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = lib.meshes[key]
	mm.instance_count = buf.size() / 12
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.name = key
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)
	return mmi


func _add_array_mesh(parent: Node3D, n: String, verts: PackedVector3Array, norms: PackedVector3Array,
		uvs: PackedVector2Array, mat: Material, shadows: bool) -> MeshInstance3D:
	if verts.is_empty():
		return null
	if norms.is_empty():
		norms.resize(verts.size())
		norms.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	if not uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## Future gameplay hook: destroyed tree ids etc. go through WorldModifications and the
## chunk is simply rebuilt from the deterministic generator + modifications.
func get_spawned_objects() -> Dictionary:
	return data.props if data else {}
