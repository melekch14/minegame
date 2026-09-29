@tool
class_name WorldGenerationConfig
extends Resource
## Central, designer-facing configuration for the procedural world.
## Every tunable generation value lives here; no generator script hardcodes these.
## Edit res://resources/world/world_generation_config.tres in the inspector.

@export_group("Seed")
## Same seed + same config => identical world, chunk for chunk.
@export var world_seed: int = 12345

@export_group("Chunks & Streaming")
## Terrain cells per chunk edge.
@export_range(8, 64, 1) var chunk_size: int = 32
## Chunks (radius) kept loaded around the world center. Outer ring uses the lightweight LOD.
@export_range(1, 12, 1) var active_chunk_radius: int = 7
## Chunks (radius) around the world center built with the full Blender assets.
@export_range(0, 8, 1) var detail_chunk_radius: int = 2
## Extra chunks beyond the active radius before a chunk is unloaded (prevents load/unload thrash).
@export_range(0, 3, 1) var unload_hysteresis: int = 1
## Chunk data jobs allowed to run on worker threads at once.
@export_range(1, 16, 1) var max_concurrent_jobs: int = 6
## Finished chunks turned into scene nodes per frame (main-thread budget).
@export_range(1, 16, 1) var max_chunk_builds_per_frame: int = 3
## Build StaticBody3D collision for detailed chunks (for the future player).
@export var generate_collision: bool = true

@export_group("Level of Detail")
## Detailed chunks are split into N x N sections; each swaps between the real Blender assets
## and the merged LOD mesh on its own, based on camera distance.
@export_range(1, 4, 1) var detail_sections_per_axis: int = 2
## Camera distance (m) up to which sections show the real Blender blocks, slopes and water tiles.
@export var detail_view_distance: float = 90.0
## Camera distance (m) up to which full-detail trees are shown (decimated trees beyond).
@export var tree_detail_distance: float = 75.0
## Camera distance (m) up to which small rocks are drawn.
@export var small_rock_view_distance: float = 70.0
## Hysteresis around the switch distances (m).
@export var lod_switch_margin: float = 6.0

@export_group("Terrain Grid")
## World size of one terrain cell. Matches the 2 m Blender blocks.
@export var cell_size: float = 2.0
## World height of one terrain level. Matches the 2 m Blender blocks.
@export var level_height: float = 2.0
## Highest terrain level that can be generated.
@export_range(4, 32, 1) var max_height: int = 16

@export_group("Terrain Shape")
## Water surface level (in terrain levels). Terrain below this is flooded.
@export_range(1, 10, 1) var water_level: int = 3
## Base elevation of ordinary lowland, in levels.
@export var base_height: float = 5.2
## Multiplies all hill / highland height contributions.
@export_range(0.1, 3.0, 0.01) var terrain_height_scale: float = 1.0
## Multiplies all terrain noise frequencies. >1 = smaller, busier features; <1 = broader features.
@export_range(0.25, 4.0, 0.01) var terrain_noise_scale: float = 1.0
## Strength of the continental (very low frequency) layer, in levels.
@export var continental_amplitude: float = 1.9
## Minimum / maximum amplitude of the medium hill layer, in levels.
@export var hill_amplitude_min: float = 0.7
@export var hill_amplitude_max: float = 2.7
## Amplitude of the small surface detail layer, in levels.
@export var detail_amplitude: float = 0.38
## Extra height of rocky highlands (base + ridged peaks), in levels.
@export var highland_base_height: float = 1.6
@export var highland_ridge_height: float = 8.5
## 0..1: how rare highlands are away from the designed layout (higher = rarer).
@export_range(0.0, 1.0, 0.01) var highland_rarity: float = 0.62

@export_group("Water")
## Enables noise-driven river networks outside the designed layout.
@export var procedural_rivers: bool = true
## Maximum sand shoreline width in cells (actual width varies procedurally 0..this).
@export_range(0, 6, 1) var max_shore_width: int = 3

@export_group("Biomes & Density")
## Probability that a forest cell spawns a tree candidate.
@export_range(0.0, 1.0, 0.01) var forest_density: float = 0.9
## Probability that a grassland cell spawns a tree candidate (inside meadow groves).
@export_range(0.0, 1.0, 0.01) var grassland_density: float = 0.1
## Global tree density multiplier.
@export_range(0.0, 2.0, 0.01) var tree_density: float = 1.0
## Global rock density multiplier.
@export_range(0.0, 3.0, 0.01) var rock_density: float = 1.0
## Relative weights of large vs small trees.
@export_range(0.0, 1.0, 0.01) var large_tree_probability: float = 0.55
@export_range(0.0, 1.0, 0.01) var small_tree_probability: float = 0.45
## Uniform scale variation applied to trees (0.1 => 0.9..1.1).
@export_range(0.0, 0.3, 0.01) var tree_scale_variation: float = 0.1
## How often a single-level terrain step becomes a grass slope instead of a small cliff.
@export_range(0.0, 1.0, 0.01) var slope_probability: float = 0.9
## How strongly forests are broken up by open clearings.
@export_range(0.0, 1.0, 0.01) var clearing_amount: float = 0.5

@export_group("Designed Layout")
## Applies the authored macro layout (start meadow, north forest, east lake...) around the origin.
@export var use_designed_layout: bool = true
## How far (in cells) anchor positions may drift with the seed.
@export_range(0.0, 1.0, 0.01) var layout_seed_jitter: float = 0.12

@export_group("Debug")
## Print per-chunk generation timings.
@export var log_chunk_timings: bool = false


func chunk_world_size() -> float:
	return chunk_size * cell_size
