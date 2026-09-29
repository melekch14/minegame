extends Node
## Game root: the procedural World plus the player. Hooks them together — the world streams
## around the player, and the player queries the world for ground, water and spawn height.

@onready var world: World = $World
@onready var player: PlayerController = $Player


func _ready() -> void:
	player.world = world
	world.streaming_target = player
