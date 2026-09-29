class_name WorldHash
extends RefCounted
## Deterministic, stateless integer hashing. Never uses global random state, so any
## decision can be re-derived from (seed, coordinates, layer) on any thread, in any order.

const MASK := 0xFFFFFFFF


static func hash4(a: int, b: int, c: int, d: int = 0) -> int:
	var h: int = (a * 374761393 + b * 668265263 + c * 1103515245 + d * 1274126177 + 0x9E3779B9) & MASK
	h = ((h ^ (h >> 15)) * 2246822519) & MASK
	h = ((h ^ (h >> 13)) * 3266489917) & MASK
	h = h ^ (h >> 16)
	return h


## Uniform float in [0, 1).
static func rand01(seed: int, x: int, z: int, layer: int) -> float:
	return float(hash4(seed, x, z, layer)) / 4294967296.0


## Stable id for a spawned object — used by persistence to remember destroyed trees etc.
static func object_id(layer: int, cell: Vector2i) -> int:
	return (layer << 48) ^ ((cell.x & 0xFFFFFF) << 24) ^ (cell.y & 0xFFFFFF)


## Seed for a chunk-scoped RandomNumberGenerator stream.
static func chunk_seed(world_seed: int, chunk: Vector2i, layer: int) -> int:
	return hash4(world_seed, chunk.x, chunk.y, layer)
