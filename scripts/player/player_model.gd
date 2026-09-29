class_name PlayerModel
extends Node3D
## Visual side of the player (res://assets/characters/player/playerlv0.glb):
## rebuilds the Blender materials in Godot and picks the animation for the current movement.
## The controller rotates this node to face the movement direction; the model faces -Z.

const SHADER := preload("res://shaders/character_voxel.gdshader")

## Blender material -> the two linear colours its white-noise mix picks between, snap size
## (Blender units), roughness and metallic. Copied from playerlv0.blend.
const MATERIALS := {
	"MAT_Skin": {"a": Color(0.8, 0.36, 0.2), "b": Color(0.72, 0.31, 0.17), "snap": 0.12, "rough": 0.6, "metal": 0.0},
	"MAT_Hair": {"a": Color(0.055, 0.02, 0.008), "b": Color(0.03, 0.011, 0.005), "snap": 0.1, "rough": 0.85, "metal": 0.0},
	"MAT_Eye": {"a": Color(0.85, 0.85, 0.82), "b": Color(0.8, 0.8, 0.77), "snap": 0.1, "rough": 0.4, "metal": 0.0},
	"MAT_Mouth": {"a": Color(0.3, 0.07, 0.04), "b": Color(0.26, 0.06, 0.035), "snap": 0.1, "rough": 0.6, "metal": 0.0},
	"MAT_Shirt": {"a": Color(0.56, 0.55, 0.51), "b": Color(0.42, 0.41, 0.38), "snap": 0.12, "rough": 0.9, "metal": 0.0},
	"MAT_Pants": {"a": Color(0.15, 0.058, 0.024), "b": Color(0.095, 0.037, 0.016), "snap": 0.12, "rough": 0.9, "metal": 0.0},
	"MAT_Boots": {"a": Color(0.085, 0.032, 0.013), "b": Color(0.055, 0.021, 0.009), "snap": 0.1, "rough": 0.75, "metal": 0.0},
	"MAT_Leather": {"a": Color(0.12, 0.045, 0.016), "b": Color(0.08, 0.03, 0.011), "snap": 0.1, "rough": 0.7, "metal": 0.0},
	"MAT_Backpack": {"a": Color(0.22, 0.085, 0.028), "b": Color(0.15, 0.058, 0.02), "snap": 0.12, "rough": 0.75, "metal": 0.0},
	"MAT_Metal": {"a": Color(0.13, 0.13, 0.13), "b": Color(0.1, 0.1, 0.1), "snap": 0.1, "rough": 0.35, "metal": 1.0},
}

## Render layer (1-based) the character meshes are drawn on, so the camera can hide them
## when it gets pushed inside the character.
const RENDER_LAYER := 2

## Animations that repeat. Wave plays once.
const LOOPING := ["Idle", "Walk", "Air"]

## Ground speed (m/s) at which Walk plays at normal speed (feet roughly match the ground).
@export var walk_anim_speed := 2.2
@export var max_anim_speed_scale := 2.4
@export var blend_time := 0.18

var anim: AnimationPlayer
var _materials := {}
var _emoting := false


func _ready() -> void:
	_apply_materials(self)
	anim = find_child("AnimationPlayer", true, false)
	if anim == null:
		push_error("PlayerModel: no AnimationPlayer in the character scene")
		return
	for n in LOOPING:
		if anim.has_animation(n):
			anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	anim.play("Idle")


## Called every physics frame by the controller.
func update_locomotion(ground_speed: float, grounded: bool, swimming: bool) -> void:
	if anim == null:
		return
	var want := "Idle"
	var speed_scale := 1.0
	if swimming:
		want = "Walk"
		speed_scale = 0.6
	elif not grounded:
		want = "Air"
	elif ground_speed > 0.3:
		want = "Walk"
		speed_scale = clampf(ground_speed / walk_anim_speed, 0.6, max_anim_speed_scale)
	if want == "Idle" and _emoting and anim.current_animation == "Wave":
		return
	_emoting = false
	if anim.current_animation != want:
		anim.play(want, blend_time)
	anim.speed_scale = speed_scale


## One-shot emote; interrupted as soon as the player moves.
func play_emote() -> void:
	if anim == null or not anim.has_animation("Wave"):
		return
	_emoting = true
	anim.speed_scale = 1.0
	anim.play("Wave", blend_time)


func _apply_materials(n: Node) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		mi.layers = 1 << (RENDER_LAYER - 1)
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i)
			var mname := WorldAssetLibrary.base_material_name(src.resource_name) if src else ""
			if MATERIALS.has(mname):
				mi.set_surface_override_material(i, _material(mname))
			else:
				push_warning("PlayerModel: no material definition for '%s' on %s" % [mname, mi.name])
	for c in n.get_children():
		_apply_materials(c)


func _material(mname: String) -> ShaderMaterial:
	if not _materials.has(mname):
		var def: Dictionary = MATERIALS[mname]
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.resource_name = mname
		# Vector3, not Color: a Color would be treated as sRGB and linearised a second time.
		var a: Color = def.a
		var b: Color = def.b
		m.set_shader_parameter("color_a", Vector3(a.r, a.g, a.b))
		m.set_shader_parameter("color_b", Vector3(b.r, b.g, b.b))
		m.set_shader_parameter("snap_size", def.snap)
		m.set_shader_parameter("roughness_value", def.rough)
		m.set_shader_parameter("metallic_value", def.metal)
		_materials[mname] = m
	return _materials[mname]
