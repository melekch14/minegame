# Procedural open world

Press F5 to play `scenes/game/Game.tscn`: the world plus the third-person player
(see `scripts/player/README.md`), with streaming following the player.
Open `scenes/world/World.tscn` and press F6 for the world alone; it then streams in around
`World.world_center` (default `Vector3.ZERO`).

## Scene structure

```
World (world.gd)                 # wires everything; exposes world_center / streaming_target
├── WorldEnvironment             # sky, soft AO, aerial-perspective fog, tonemapping
├── Sun (DirectionalLight3D)     # soft shadows
├── WorldGenerator               # stateless generators, thread-safe
├── ChunkManager                 # streaming, worker threads, per-frame build budget
└── Chunks
    └── Chunk_X_Z (WorldChunk)
        ├── Section_i            # N x N sections per detailed chunk (HLOD)
        │   ├── TerrainLOD       # merged voxel mesh (distance / far chunks)
        │   ├── WaterLOD
        │   ├── Backing          # fills bevel pin-holes between Blender blocks; terrain shadow caster
        │   ├── grass/dirt/stone/sand/slope/water   # MultiMesh of the real Blender blocks (no shadows)
        │   ├── tree_* / tree_*_lod / tree_*_far    # MultiMesh trees (full / decimated / voxel stand-in)
        │   └── rock_*                              # MultiMesh rocks
        └── Collision            # StaticBody3D (detailed chunks only)
```

## Scripts (`scripts/world/`)

| File | Role |
|---|---|
| `world_generation_config.gd` + `resources/world/world_generation_config.tres` | **All tunables** (seed, chunk size, radii, water level, height/noise scale, densities, LOD distances) |
| `world_coords.gd` | The only place coordinate conversion happens: world ↔ cell ↔ chunk |
| `world_hash.gd` | Stateless deterministic hashing (no global RNG anywhere) |
| `world_layout.gd` | The authored macro-geography around the origin (start meadow, N forest, NE highlands, E lake + SE river…) as soft, noise-warped anchors |
| `terrain_generator.gd` | Layered noise: continental + hills + detail + ridged highlands, lakes, rivers, valleys |
| `biome_generator.gd` | Moisture/temperature/elevation → biome weights; surface materials; shorelines; slope placement; densities |
| `vegetation_generator.gd` | Deterministic blue-noise placement of trees and rocks (seamless across chunks) |
| `chunk_data.gd` | Pure per-chunk data (heights, biomes, surfaces, slopes, spawned objects with stable ids) |
| `chunk_mesher.gd` | ChunkData → MultiMesh buffers, merged LOD meshes, collision (worker thread) |
| `world_chunk.gd` | Builds the nodes for a chunk on the main thread |
| `chunk_manager.gd` | Streaming: load / upgrade / unload around the center |
| `world_asset_library.gd` | Loads the Blender GLBs and recreates their node materials in Godot |
| `world_modifications.gd` | Save-friendly record of changes (destroyed objects, terrain edits, structures) |

## Determinism

Every decision is a pure function of `(world_seed, global cell coordinate, layer)`. Chunks are
generated with an 8-cell margin, so neighbour-dependent rules (shores, slopes, tree spacing, cliff
faces) come out identical on both sides of a border. A chunk that is unloaded and reloaded
regenerates bit-for-bit. Same seed = same world; a different seed = a different world, and the
designed layout drifts slightly too.

## Player / streaming

`scripts/game/game.gd` sets `World.streaming_target` to the player. `ChunkManager.set_center()` is
called every frame. Chunks within `detail_chunk_radius` get full assets and collision. Chunks out to
`active_chunk_radius` get the lightweight LOD, and anything further out is freed.
`World.is_ground_ready(pos)` says whether the chunk under a position has collision yet, and
`World.get_water_height()` gives the (global) water surface.

## Persistence hook

Destroying a tree: `world.modifications.remove_object(id, chunk)`. Ids come from
`WorldChunk.get_spawned_objects()`. The chunk rebuilds without that tree and stays that way
after it reloads. Terrain edits use `set_terrain_level()`. `WorldModifications` is a Resource,
so you can save it with `ResourceSaver.save()`.

## Assets

The original `.blend` files in `../assets/terrain` are untouched. They are exported to
`assets/models/*.glb` (1 surface each, with the Blender material index in UV.x, plus
`material_ids.json`). Also exported: decimated `*_lod.glb` trees for distance, and bottom faces
removed from blocks (they are never visible). The terrain blocks (grass, dirt, stone, sand, slope) are drawn from `assets/models/baked/`: 10-triangle
boxes made by `tools/blender/bake_blocks.py`
(`blender -b --python tools/blender/bake_blocks.py`), which bakes each detailed block's normals,
material index and AO into two small textures. `voxel_ramp.gdshader` still generates the colours per
instance. Re-run the script whenever a detailed block GLB changes. The `tree_*_far` stand-ins are not exported: at
load time `WorldAssetLibrary.build_voxel_proxy()` voxelises each `*_lod` tree (~150–280 triangles
at the default `far_tree_voxel_size`), shown beyond `tree_far_distance`. Block pivots are bottom-centre, 2×2×2 m, which
matches the 2 m terrain grid. The shaders in `shaders/` rebuild the Blender voxel-noise ramps.

## Developer tools

- `scripts/world/debug/world_map_preview.gd`: headless top-down map + biome statistics:
  `godot --headless --path . --script res://scripts/world/debug/world_map_preview.gd -- <seed> <radius>`
- `scenes/world/debug/WorldPreview.tscn`: flies through fixed viewpoints and saves screenshots
  plus fps/draw-call stats to `_preview/`.
