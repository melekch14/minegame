class_name PlayerInput
extends RefCounted
## Default bindings for the player actions. They are added at startup only when the project's
## Input Map doesn't already define the action, so anything set in Project Settings > Input Map wins.
## Keys are physical (keyboard position), so WASD is ZQSD on an AZERTY keyboard.

const KEYS := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"sprint": [KEY_SHIFT],
	"emote": [KEY_E],
}

## action -> [axis, direction]
const AXES := {
	"move_forward": [JOY_AXIS_LEFT_Y, -1.0],
	"move_back": [JOY_AXIS_LEFT_Y, 1.0],
	"move_left": [JOY_AXIS_LEFT_X, -1.0],
	"move_right": [JOY_AXIS_LEFT_X, 1.0],
	"look_up": [JOY_AXIS_RIGHT_Y, -1.0],
	"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	"look_left": [JOY_AXIS_RIGHT_X, -1.0],
	"look_right": [JOY_AXIS_RIGHT_X, 1.0],
}

const BUTTONS := {
	"jump": [JOY_BUTTON_A],
	"sprint": [JOY_BUTTON_LEFT_STICK],
	"emote": [JOY_BUTTON_Y],
}

const DEADZONE := 0.2


static func ensure_actions() -> void:
	var actions := {}
	for a in KEYS.keys() + AXES.keys() + BUTTONS.keys():
		actions[a] = true
	for action: String in actions:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, DEADZONE)
		for key: Key in KEYS.get(action, []):
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
		if AXES.has(action):
			var ev := InputEventJoypadMotion.new()
			ev.axis = AXES[action][0]
			ev.axis_value = AXES[action][1]
			InputMap.action_add_event(action, ev)
		for button: JoyButton in BUTTONS.get(action, []):
			var ev := InputEventJoypadButton.new()
			ev.button_index = button
			InputMap.action_add_event(action, ev)
