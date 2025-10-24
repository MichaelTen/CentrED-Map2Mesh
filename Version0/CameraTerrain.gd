extends Camera2D

# --- Zoom & pan tuning ---
@export var zoom_step: float = 0.15         # % change per wheel notch when Ctrl is held
@export var zoom_min: float = 0.02          # farther zoom OUT
@export var zoom_max: float = 64.0          # farther zoom IN
@export var pan_sensitivity: float = 8.0    # mouse-drag responsiveness (higher = faster)
@export var key_pan_speed: float = 1400.0   # WASD/arrow panning (world units/sec)

# --- Dimetric -> square view compensation ---
# UO uses 2:1 tiles (e.g., 88x44). To make each diamond *appear* square,
# we need to stretch the screen vertically by ~2x.
# Set this to 2.0 for 2:1 tiles. Use 1.0 if you switch to 1:1 tiles.
@export var y_stretch: float = 2.0

# Internal scalar zoom we manipulate; we build the 2D zoom Vector2 from this.
var _zoom_scalar: float = 1.0

func _ready() -> void:
	make_current()
	enabled = true

	# Keep limits wide so the camera never clamps.
	limit_left   = -1000000
	limit_top    = -1000000
	limit_right  =  1000000
	limit_bottom =  1000000

	# Initialize the actual Camera2D zoom with our stretch on Y.
	_apply_zoom_vector()

func _unhandled_input(event: InputEvent) -> void:
	# Ctrl + Wheel = zoom in/out
	if event is InputEventMouseButton and event.pressed and Input.is_key_pressed(KEY_CTRL):
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				# Wheel forward -> ZOOM IN
				_set_zoom_ratio(1.0 + zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				# Wheel back -> ZOOM OUT
				_set_zoom_ratio(1.0 - zoom_step)

	# Middle- or Right-mouse drag to pan (faster when zoomed out)
	if event is InputEventMouseMotion:
		var dragging_mmb: bool = (event.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0
		var dragging_rmb: bool = (event.button_mask & MOUSE_BUTTON_MASK_RIGHT)  != 0
		if dragging_mmb or dragging_rmb:
			var speed_mult: float = 1.0
			if Input.is_key_pressed(KEY_SHIFT):
				speed_mult = 6.0   # turbo pan
			elif Input.is_key_pressed(KEY_ALT):
				speed_mult = 0.25  # precision pan
			# Scale panning by 1/_zoom_scalar so it covers more world space when zoomed out.
			var z: float = max(_zoom_scalar, 0.0001)
			position -= event.relative * (pan_sensitivity * speed_mult / z)

# Optional: double-click middle mouse to jump to the cursor
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.double_click and event.button_index == MOUSE_BUTTON_MIDDLE:
		position = get_global_mouse_position()

func _process(delta: float) -> void:
	# Keyboard panning (WASD / arrows). Also scales by 1/_zoom_scalar.
	var v: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("ui_left"):  v.x -= 1.0
	if Input.is_action_pressed("ui_right"): v.x += 1.0
	if Input.is_action_pressed("ui_up"):    v.y -= 1.0
	if Input.is_action_pressed("ui_down"):  v.y += 1.0
	if v != Vector2.ZERO:
		var speed_mult: float = 1.0
		if Input.is_key_pressed(KEY_SHIFT):
			speed_mult = 6.0
		elif Input.is_key_pressed(KEY_ALT):
			speed_mult = 0.25
		var z: float = max(_zoom_scalar, 0.0001)
		position += v.normalized() * (key_pan_speed * speed_mult * delta / z)

# --- Helpers -------------------------------------------------------------

# Applies the current scalar zoom with Y compensation to the Camera2D
func _apply_zoom_vector() -> void:
	zoom = Vector2(_zoom_scalar, _zoom_scalar * y_stretch)

# Sets zoom multiplicatively then clamps and applies y_stretch
func _set_zoom_ratio(factor: float) -> void:
	_zoom_scalar = clamp(_zoom_scalar * factor, zoom_min, zoom_max)
	_apply_zoom_vector()
