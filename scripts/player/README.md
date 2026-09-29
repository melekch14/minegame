# Third-person player

`scenes/game/Game.tscn` (the main scene) = `World` + `Player`. `scripts/game/game.gd` connects the two:
the world streams around the player, and the player asks the world for ground, water and spawn height.

## Scene structure

```
Player (CharacterBody3D, player_controller.gd)   # collision layer 2, mask 1 (terrain)
├── CollisionShape3D                             # capsule r 0.35, h 1.8
├── Model (player_model.gd)                      # turned to face the movement direction
│   └── Character (playerlv0.glb)                # Skeleton3D + AnimationPlayer: Idle, Walk, Wave, Air
└── CameraRig (third_person_camera.gd)           # top_level; yaw + pitch
    └── SpringArm3D                              # collides with layer 1, pulls the camera in
        └── Camera3D
```

## Scripts (`scripts/player/`)

| File | Role |
|---|---|
| `player_controller.gd` | Camera-relative movement, sprint, jump (coyote time, input buffer, variable height), swimming, spawn and streaming guards. All tunables are exported. |
| `third_person_camera.gd` | Orbit camera: mouse / right stick, wheel zoom, smooth follow (reads the interpolated transform), hides the character if a wall pushes the camera into it |
| `player_model.gd` | Rebuilds the Blender materials with `shaders/character_voxel.gdshader` and picks and scales the animation |
| `player_input.gd` | Default bindings, added at runtime only for actions missing from the project Input Map |
| `debug/player_preview_capture.gd` | Dev tool: `scenes/player/debug/PlayerPreview.tscn` drives the player with fake input and saves `_preview/player_*.png` plus a log |

## Controls

| Action | Keyboard / mouse | Gamepad |
|---|---|---|
| Move | WASD (physical keys, so ZQSD on AZERTY) / arrows | Left stick |
| Look | Mouse (captured; Esc releases, click recaptures) | Right stick |
| Zoom | Wheel | – |
| Jump | Space | A |
| Sprint | Shift | L3 |
| Wave | E | Y |

## Behaviour with the procedural world

- **Spawn**: the player is hidden until the chunk at `spawn_position` has collision. It is then
  raycast onto the ground.
- **Streaming guard**: if the chunk under the player has no collision yet, the player holds still
  instead of falling through.
- **Fall-out recovery**: if the player drops below `respawn_below_y`, it is put back on the surface.
- **Terrain**: 45° grass slopes are walkable (`floor_max_angle` 50°). 2 m cliff steps are not walkable
  but can be jumped (`jump_height` 2.3 m). Trees and rocks have no collision yet, because the world only
  builds terrain collision.
- **Water**: one global plane (`World.get_water_height()`). Deeper than `float_depth` the player
  floats and swims, and Jump hops out onto a shore.

## Character asset

`assets/characters/player/playerlv0.glb` is generated from `../assets/playerlv0.blend` (the .blend is
never modified):

```
blender -b ../assets/playerlv0.blend --python tools/blender/export_player.py
```

The exporter applies the modifiers and bakes the rest positions into the UVs (for the snapped-noise
materials). It also generates the `Idle` (the average of the Walk poses plus breathing) and `Air` poses
next to `Walk` and `Wave`. The import scales the model by 0.22 (`nodes/root_scale`), making it about
1.8 m tall. Mesh compression is disabled so the baked UVs stay exact.
