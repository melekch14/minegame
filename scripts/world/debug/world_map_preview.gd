extends SceneTree
## Developer tool: renders a top-down map of the generated world without opening a window.
##   godot --headless --path <project> --script res://scripts/world/debug/world_map_preview.gd -- [seed] [radius_chunks]
## Writes res://_preview/map_seed_<seed>.png plus elevation / biome statistics to stdout.
## Useful for tuning WorldGenerationConfig: every pixel is one terrain cell.

const SURFACE_COLORS := [Color(0.3, 0.62, 0.16), Color(0.45, 0.3, 0.17), Color(0.5, 0.49, 0.47), Color(0.86, 0.74, 0.47)]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var config: WorldGenerationConfig = load("res://resources/world/world_generation_config.tres").duplicate()
	if args.size() > 0:
		config.world_seed = int(args[0])
	var radius := 5
	if args.size() > 1:
		radius = int(args[1])
	var gen := WorldGenerator.new()
	gen.setup(config, WorldModifications.new())
	var cs := config.chunk_size
	var n := (radius * 2 + 1) * cs
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var hist := {}
	var biome_count := [0, 0, 0, 0, 0]
	var trees := 0
	var rocks := 0
	var t0 := Time.get_ticks_msec()
	for cz in range(-radius, radius + 1):
		for cx in range(-radius, radius + 1):
			var d := gen.generate_chunk_data(Vector2i(cx, cz))
			for z in cs:
				for x in cs:
					var lx := x + d.margin
					var lz := z + d.margin
					var i := d.idx(lx, lz)
					var t := d.level[i]
					hist[t] = hist.get(t, 0) + 1
					biome_count[d.biome[i]] += 1
					var col: Color
					if t < config.water_level:
						col = Color(0.12, 0.35, 0.62).lerp(Color(0.05, 0.14, 0.36), clampf((config.water_level - t - 1) / 2.0, 0.0, 1.0))
					else:
						col = SURFACE_COLORS[d.surface[i]]
						var shade := 0.72 + (t - config.water_level) * 0.035
						# Hillshade from the west neighbour.
						var tw := d.level_at(lx - 1, lz - 1)
						shade += (t - tw) * 0.12
						col = col * clampf(shade, 0.4, 1.4)
						if d.biome[i] == ChunkData.Biome.FOREST:
							col = col.lerp(Color(0.1, 0.3, 0.08), 0.45)
						if d.slope[i] != 0:
							col = col.lerp(Color(0.55, 0.8, 0.3), 0.35)
					img.set_pixel((cx + radius) * cs + x, (cz + radius) * cs + z, col)
			for key in d.props:
				for p in d.props[key]:
					var wp: Vector3 = p.xform.origin
					var px := int(floor(wp.x / config.cell_size)) + radius * cs
					var pz := int(floor(wp.z / config.cell_size)) + radius * cs
					if px < 0 or pz < 0 or px >= n or pz >= n:
						continue
					if key.begins_with("tree"):
						trees += 1
						img.set_pixel(px, pz, Color(0.05, 0.25, 0.05) if key.begins_with("tree_large") else Color(0.12, 0.38, 0.08))
					else:
						rocks += 1
						img.set_pixel(px, pz, Color(0.2, 0.2, 0.22) if key == "rock_large" else Color(0.62, 0.62, 0.64))
	# Mark the world centre.
	for k in range(-3, 4):
		if radius == 0:
			break
		img.set_pixel(radius * cs + k, radius * cs, Color.RED)
		img.set_pixel(radius * cs, radius * cs + k, Color.RED)
	var dt := Time.get_ticks_msec() - t0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_preview"))
	var path := "res://_preview/map_seed_%d.png" % config.world_seed
	img.save_png(path)
	var total := n * n
	print("map saved: ", ProjectSettings.globalize_path(path))
	print("chunks: %d  time: %d ms (%.1f ms/chunk)" % [(radius * 2 + 1) * (radius * 2 + 1), dt, dt / float((radius * 2 + 1) * (radius * 2 + 1))])
	var keys := hist.keys()
	keys.sort()
	var line := "levels: "
	for k in keys:
		line += "%d:%.1f%% " % [k, 100.0 * hist[k] / total]
	print(line)
	print("biomes: grass %.1f%% forest %.1f%% rocky %.1f%% shore %.1f%% water %.1f%%" % [
		100.0 * biome_count[0] / total, 100.0 * biome_count[1] / total, 100.0 * biome_count[2] / total,
		100.0 * biome_count[3] / total, 100.0 * biome_count[4] / total])
	print("trees: %d  rocks: %d" % [trees, rocks])
	gen.free()
	quit()
