# CameraTerrain.gd — Godot 4.5.1
extends Camera2D

@export var zoom_step: float = 0.15
@export var zoom_min: float = 0.02
@export var zoom_max: float = 64.0
@export var pan_sensitivity: float = 8.0
@export var key_pan_speed: float = 1400.0
# Dimetric → square compensation (keep 0.5 to make diamonds look square)
@export var y_stretch: float = 1.0

var _zoom_scalar: float = 1.0
var _grid_visible: bool = true

func _ready() -> void:
	make_current()
	enabled = true
	limit_left = -1000000
	limit_top = -1000000
	limit_right = 1000000
	limit_bottom = 1000000
	_apply_zoom_vector()

	# Ensure an InputMap action exists for Ctrl+G at runtime.
	# This way you don't need to set anything in Project Settings.
	if not InputMap.has_action("toggle_grid"):
		InputMap.add_action("toggle_grid")
		var ev := InputEventKey.new()
		ev.keycode = KEY_G
		ev.ctrl_pressed = true
		InputMap.action_add_event("toggle_grid", ev)

func _input(event: InputEvent) -> void:
	# Optional: double-click middle mouse to jump to the cursor
	if event is InputEventMouseButton and event.double_click and event.button_index == MOUSE_BUTTON_MIDDLE:
		position = get_global_mouse_position()

func _unhandled_input(event: InputEvent) -> void:
	# Ctrl+G via InputMap (robust)
	if Input.is_action_just_pressed("toggle_grid"):
		_grid_visible = !_grid_visible
		get_tree().call_group("tile_outlines", "set", "visible", _grid_visible)

	# Ctrl + Wheel → zoom
	if event is InputEventMouseButton and event.pressed and Input.is_key_pressed(KEY_CTRL):
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:   _set_zoom_ratio(1.0 + zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN: _set_zoom_ratio(1.0 - zoom_step)

	# Middle/Right drag → pan
	if event is InputEventMouseMotion:
		var dragging: bool = (event.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0
		if dragging:
			var speed_mult: float = 1.0
			if Input.is_key_pressed(KEY_SHIFT): speed_mult = 6.0
			elif Input.is_key_pressed(KEY_ALT):  speed_mult = 0.25
			var z: float = max(_zoom_scalar, 0.0001)
			position -= event.relative * (pan_sensitivity * speed_mult / z)

func _process(delta: float) -> void:
	var v: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("ui_left"):  v.x -= 1.0
	if Input.is_action_pressed("ui_right"): v.x += 1.0
	if Input.is_action_pressed("ui_up"):    v.y -= 1.0
	if Input.is_action_pressed("ui_down"):  v.y += 1.0
	if v != Vector2.ZERO:
		var speed_mult: float = 1.0
		if Input.is_key_pressed(KEY_SHIFT): speed_mult = 6.0
		elif Input.is_key_pressed(KEY_ALT):  speed_mult = 0.25
		var z: float = max(_zoom_scalar, 0.0001)
		position += v.normalized() * (key_pan_speed * speed_mult * delta / z)

# Applies the current scalar zoom with Y compensation to the Camera2D
func _apply_zoom_vector() -> void:
	zoom = Vector2(_zoom_scalar, _zoom_scalar * y_stretch)

# Sets zoom multiplicatively then clamps and applies y_stretch
func _set_zoom_ratio(factor: float) -> void:
	_zoom_scalar = clamp(_zoom_scalar * factor, zoom_min, zoom_max)
	_apply_zoom_vector()
