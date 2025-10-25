@tool
# mapBake2D.gd — Bake MAP0.MUL → tile_heights.res + tiletex_info.res, then build MeshInstance2D blocks
# version 0.0.15 (texture-only rotation + seam-free UV crop)
extends Node
class_name MapBake2DEditor

# ---------- Exports ----------
@export_file("*") var mul_path: String = "" : set = set_mul_path
@export var map_tiles: Vector2i = Vector2i(256, 256) : set = set_map_tiles
@export var tiles_per_block: int = 16 : set = set_tiles_per_block

# Step size in screen pixels between tile corners.
@export var tile_px: Vector2 = Vector2(88, 88) : set = set_tile_px

@export var heights_scale_px: float = 4.0 : set = set_heights_scale_px
@export var ground_parent_path: NodePath = ^"GroundBlocks" : set = set_ground_parent_path
@export var placeholder_texture_path: String = "res://assets/terrain/desertv0.png" : set = set_placeholder_texture_path

@export var show_tile_outlines: bool = true : set = set_show_tile_outlines
@export var outline_color: Color = Color(1, 1, 0, 0.85) : set = set_outline_color

# CentrED# overlay
@export var square_outline_color: Color = Color(1, 1, 0, 0.9)
@export var square_diag_color: Color   = Color(1, 1, 1, 0.65)
@export var draw_square_diagonals: bool = true

@export var flip_y: bool = false : set = set_flip_y
@export var swap_xy: bool = false : set = set_swap_xy
@export var map_center_offset: Vector2 = Vector2.ZERO : set = set_map_center_offset
@export var debug_log: bool = true

# --- PNG-only controls ---
# Rotate ONLY the texture sampling (not the grid). Use 45 or -45 to align the flat edge "north".
@export var tex_rot_deg: float = 45.0 : set = set_tex_rot_deg
# Crop away N texture pixels from each edge AFTER rotation to remove transparent-border seams.
@export var uv_inset_px: float = -20.0 : set = set_uv_inset_px

# ---------- Constants ----------
const PATH_TILE_HEIGHTS := "res://assets/data/tile_heights.res"
const PATH_TEX_INFO     := "res://assets/data/tiletex_info.res"
const PATH_TILE_REG     := "res://assets/data/tile_registry.res"

# ---------- Internals ----------
var _ground_parent: Node2D
var _mat: ShaderMaterial
var _square_outlines_visible: bool = false
var _tex_size: Vector2 = Vector2.ONE   # in pixels

# ---------- Ready ----------
func _ready() -> void:
	_log("--- MapBake2D READY (editor:%s) ---" % [Engine.is_editor_hint()])
	_ensure_ground_parent()
	_center_parent()
	_setup_material()
	_ensure_tile_registry()
	_ensure_input_actions()
	_editor_build()

# Hotkey: Ctrl + O toggles CentrED#-style tile outlines
func _ensure_input_actions() -> void:
	if not InputMap.has_action("toggle_square_outlines"):
		InputMap.add_action("toggle_square_outlines")
		var ev := InputEventKey.new()
		ev.keycode = KEY_O
		ev.ctrl_pressed = true
		InputMap.action_add_event("toggle_square_outlines", ev)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("toggle_square_outlines"):
		_square_outlines_visible = not _square_outlines_visible
		get_tree().call_group("square_outlines", "set", "visible", _square_outlines_visible)

# ---------- Editor setters ----------
func set_mul_path(v: String) -> void:
	mul_path = v
	if Engine.is_editor_hint(): _editor_build()

func set_map_tiles(v: Vector2i) -> void:
	map_tiles = v
	if Engine.is_editor_hint():
		_center_parent()
		_editor_build()

func set_tiles_per_block(v: int) -> void:
	tiles_per_block = max(1, v)
	if Engine.is_editor_hint(): _editor_build()

func set_tile_px(v: Vector2) -> void:
	tile_px = v
	if Engine.is_editor_hint():
		_center_parent()
		_editor_build()

func set_heights_scale_px(v: float) -> void:
	heights_scale_px = v
	if Engine.is_editor_hint(): _editor_build()

func set_ground_parent_path(v: NodePath) -> void:
	ground_parent_path = v
	_ensure_ground_parent()
	if Engine.is_editor_hint(): _editor_build()

func set_placeholder_texture_path(v: String) -> void:
	placeholder_texture_path = v
	_update_shader_texture()
	if Engine.is_editor_hint(): _editor_build()

func set_show_tile_outlines(v: bool) -> void:
	show_tile_outlines = v
	if Engine.is_editor_hint(): _editor_build()

func set_outline_color(v: Color) -> void:
	outline_color = v
	if Engine.is_editor_hint(): _editor_build()

func set_flip_y(v: bool) -> void:
	flip_y = v
	if Engine.is_editor_hint(): _editor_build()

func set_swap_xy(v: bool) -> void:
	swap_xy = v
	if Engine.is_editor_hint(): _editor_build()

func set_map_center_offset(v: Vector2) -> void:
	map_center_offset = v
	if Engine.is_editor_hint(): _center_parent()

func set_tex_rot_deg(v: float) -> void:
	tex_rot_deg = v
	if _mat: _mat.set_shader_parameter("u_uv_rot_deg", tex_rot_deg)

func set_uv_inset_px(v: float) -> void:
	uv_inset_px = max(v, 0.0)
	_update_uv_inset_uniform()

# ---------- Build orchestration ----------
func _editor_build() -> void:
	if mul_path.is_empty():
		_build_flat_preview()
		return
	if bake_from_mul():
		build_all_blocks()
	else:
		_build_flat_preview()

# ---------- Setup ----------
func _ensure_ground_parent() -> void:
	_ground_parent = get_node_or_null(ground_parent_path) as Node2D
	if _ground_parent == null:
		var gb := Node2D.new()
		gb.name = "GroundBlocks"
		add_child(gb)
		_ground_parent = gb
		ground_parent_path = ^"GroundBlocks"

func _center_parent() -> void:
	if _ground_parent:
		_ground_parent.position = map_center_offset

func _setup_material() -> void:
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;

uniform sampler2D u_tex;
uniform float u_uv_rot_deg = 0.0;   // degrees
uniform vec2  u_uv_inset   = vec2(0.0); // in UV space (0..1), per-edge crop

vec2 rotate_uv(vec2 uv, float deg){
	float a = radians(deg);
	float c = cos(a);
	float s = sin(a);
	vec2 p = uv - vec2(0.5);
	vec2 r = vec2(p.x * c - p.y * s, p.x * s + p.y * c);
	return r + vec2(0.5);
}

void fragment(){
	vec2 uv = rotate_uv(UV, u_uv_rot_deg);

	// Crop away a tiny border (after rotation) to avoid sampling transparent edge texels.
	// Equivalent to uv = mix(inset, 1.0-inset, uv) on both axes.
	vec2 lo = u_uv_inset;
	vec2 hi = vec2(1.0) - u_uv_inset;
	uv = clamp(uv, lo, hi);
	uv = (uv - lo) / max(hi - lo, vec2(1e-6));

	COLOR = texture(u_tex, uv);
}
"""
	_mat.shader = sh
	_update_shader_texture()
	_mat.set_shader_parameter("u_uv_rot_deg", tex_rot_deg)
	_update_uv_inset_uniform()

func _update_shader_texture() -> void:
	if not _mat: return
	var tex := load(placeholder_texture_path)
	if tex is Texture2D:
		_mat.set_shader_parameter("u_tex", tex)
		_tex_size = Vector2(tex.get_width(), tex.get_height())
	else:
		_mat.set_shader_parameter("u_tex", null)
		_tex_size = Vector2.ONE
		push_warning("Texture not found at %s" % placeholder_texture_path)
	_update_uv_inset_uniform()

func _update_uv_inset_uniform() -> void:
	if not _mat: return
	# Convert pixel inset to UV inset per axis.
	var inset_uv := Vector2(uv_inset_px / max(_tex_size.x, 1.0), uv_inset_px / max(_tex_size.y, 1.0))
	_mat.set_shader_parameter("u_uv_inset", inset_uv)

func _ensure_tile_registry() -> void:
	if not ResourceLoader.exists(PATH_TILE_REG):
		var reg := Resource.new()
		reg.set_meta("schema", "tile_registry_v1")
		ResourceSaver.save(reg, PATH_TILE_REG)

# ---------- MUL reading ----------
func _get_i8(f: FileAccess) -> int:
	var b: int = f.get_8()
	return b - 256 if b >= 128 else b

func bake_from_mul() -> bool:
	var result := _read_map_mul(mul_path, map_tiles)
	if not result.get("ok", false): return false

	var tile_ids: PackedInt32Array = result["tile_ids"]
	var corner_heights: PackedInt32Array = result["corner_heights"]

	var heights_res := Resource.new()
	heights_res.set_meta("w", map_tiles.x + 1)
	heights_res.set_meta("h", map_tiles.y + 1)
	heights_res.set_meta("data", corner_heights)
	ResourceSaver.save(heights_res, PATH_TILE_HEIGHTS)

	var tex_res := Resource.new()
	tex_res.set_meta("w", map_tiles.x)
	tex_res.set_meta("h", map_tiles.y)
	tex_res.set_meta("data", tile_ids)
	ResourceSaver.save(tex_res, PATH_TEX_INFO)
	return true

func _read_map_mul(path: String, size_tiles: Vector2i) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open MAP0.MUL: %s" % path)
		return { "ok": false }

	var W: int = size_tiles.x
	var H: int = size_tiles.y
	var bx_count: int = int(ceil(W / 8.0))
	var by_count: int = int(ceil(H / 8.0))
	const BLOCK_SIZE := 196

	var tile_id_per_tile := PackedInt32Array(); tile_id_per_tile.resize(W * H)
	var z_per_tile := PackedInt32Array(); z_per_tile.resize(W * H)

	for bx in range(bx_count):
		for by in range(by_count):
			var block_index: int = bx * by_count + by
			var seek_pos: int = block_index * BLOCK_SIZE
			if seek_pos + BLOCK_SIZE > f.get_length():
				continue
			f.seek(seek_pos)
			f.get_32()
			for cy in range(8):
				for cx in range(8):
					if f.get_position() + 3 > f.get_length():
						break
					var tid: int = int(f.get_16() & 0xFFFF)
					var z: int = _get_i8(f)
					var x: int = bx * 8 + cx
					var y: int = by * 8 + cy
					if x < W and y < H:
						var idx: int = y * W + x
						tile_id_per_tile[idx] = tid
						z_per_tile[idx] = z
	f.close()

	# Optional axis fixes
	if swap_xy:
		var tmp_ids := PackedInt32Array(); tmp_ids.resize(W * H)
		var tmp_z := PackedInt32Array(); tmp_z.resize(W * H)
		for y in range(H):
			for x in range(W):
				if y < W and x < H:
					tmp_ids[x * W + y] = tile_id_per_tile[y * W + x]
					tmp_z[x * W + y] = z_per_tile[y * W + x]
		tile_id_per_tile = tmp_ids
		z_per_tile = tmp_z

	if flip_y:
		for y in range(H / 2):
			var y2: int = H - 1 - y
			for x in range(W):
				var a: int = y * W + x
				var b: int = y2 * W + x
				var tmp_id: int = tile_id_per_tile[a]
				tile_id_per_tile[a] = tile_id_per_tile[b]
				tile_id_per_tile[b] = tmp_id
				var tmp_z: int = z_per_tile[a]
				z_per_tile[a] = z_per_tile[b]
				z_per_tile[b] = tmp_z

	# Per-tile Z → per-corner average
	var corner_heights := PackedInt32Array(); corner_heights.resize((W + 1) * (H + 1))
	for cy in range(H + 1):
		for cx in range(W + 1):
			var sum := 0
			var count := 0
			if cx > 0 and cy > 0: sum += z_per_tile[(cy - 1) * W + (cx - 1)]; count += 1
			if cx < W and cy > 0: sum += z_per_tile[(cy - 1) * W + cx];         count += 1
			if cx > 0 and cy < H: sum += z_per_tile[ cy      * W + (cx - 1)];  count += 1
			if cx < W and cy < H: sum += z_per_tile[ cy      * W +  cx     ];  count += 1
			corner_heights[cy * (W + 1) + cx] = int(round(float(sum) / max(count, 1)))

	return { "ok": true, "tile_ids": tile_id_per_tile, "corner_heights": corner_heights }

# ---------- Mesh builders ----------
func build_all_blocks() -> void:
	_clear_blocks()
	var heights_res := ResourceLoader.load(PATH_TILE_HEIGHTS)
	var tex_res := ResourceLoader.load(PATH_TEX_INFO)
	if heights_res == null or tex_res == null:
		_build_flat_preview()
		return

	var H_w: int = int(heights_res.get_meta("w"))
	var H_corners: PackedInt32Array = heights_res.get_meta("data")
	var T_w: int = int(tex_res.get_meta("w"))
	var T_h: int = int(tex_res.get_meta("h"))

	var blocks_x: int = int(ceil(float(T_w) / float(tiles_per_block)))
	var blocks_y: int = int(ceil(float(T_h) / float(tiles_per_block)))

	for by in range(blocks_y):
		for bx in range(blocks_x):
			var block_node := Node2D.new()
			block_node.name = "Block_%d_%d" % [bx, by]
			_ground_parent.add_child(block_node)

			var mesh_instance := MeshInstance2D.new()
			mesh_instance.name = "Mesh"
			mesh_instance.material = _mat
			# predictable tiling (avoid alpha fringes)
			mesh_instance.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			mesh_instance.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED

			mesh_instance.mesh = _build_block_mesh(bx, by, T_w, T_h, H_corners, H_w)
			block_node.add_child(mesh_instance)

			if show_tile_outlines:
				var outline := Line2D.new()
				outline.name = "Outline_Corners"
				outline.default_color = outline_color
				outline.width = 1.0
				outline.antialiased = true
				outline.visible = show_tile_outlines
				_add_tile_outlines(outline, bx, by, T_w, T_h, H_corners, H_w)
				outline.add_to_group("tile_outlines")
				block_node.add_child(outline)

			_add_square_outlines(block_node, bx, by, T_w, T_h, H_corners, H_w)

# ---------- Helpers ----------
func _build_flat_preview() -> void:
	_clear_blocks()
	var W: int = map_tiles.x
	var Ht: int = map_tiles.y
	var H_corners := PackedInt32Array(); H_corners.resize((W + 1) * (Ht + 1))
	var blocks_x: int = int(ceil(float(W) / float(tiles_per_block)))
	var blocks_y: int = int(ceil(float(Ht) / float(tiles_per_block)))
	for by in range(blocks_y):
		for bx in range(blocks_x):
			var block_node := Node2D.new()
			block_node.name = "Block_%d_%d" % [bx, by]
			_ground_parent.add_child(block_node)

			var mesh_instance := MeshInstance2D.new()
			mesh_instance.name = "Mesh"
			mesh_instance.material = _mat
			mesh_instance.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			mesh_instance.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED

			mesh_instance.mesh = _build_block_mesh(bx, by, W, Ht, H_corners, W + 1)
			block_node.add_child(mesh_instance)

			if show_tile_outlines:
				var outline := Line2D.new()
				outline.name = "Outline_Corners"
				outline.default_color = outline_color
				outline.width = 1.0
				outline.antialiased = true
				outline.visible = show_tile_outlines
				_add_tile_outlines(outline, bx, by, W, Ht, H_corners, W + 1)
				outline.add_to_group("tile_outlines")
				block_node.add_child(outline)

			_add_square_outlines(block_node, bx, by, W, Ht, H_corners, W + 1)

func _build_block_mesh(bx: int, by: int, tw: int, th: int, H: PackedInt32Array, Hw: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var x0: int = bx * tiles_per_block
	var y0: int = by * tiles_per_block
	var x1: int = min(x0 + tiles_per_block, tw)
	var y1: int = min(y0 + tiles_per_block, th)

	# Diagonal order (tx+ty) for height overlap safety.
	var tiles := []
	for ty in range(y0, y1):
		for tx in range(x0, x1):
			tiles.append(Vector2i(tx, ty))
	tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a.x + a.y) < (b.x + b.y)
	)

	for t in tiles:
		var tx: int = t.x
		var ty: int = t.y
		var p0 := _iso_pos(tx,     ty,     H, Hw)
		var p1 := _iso_pos(tx + 1, ty,     H, Hw)
		var p2 := _iso_pos(tx + 1, ty + 1, H, Hw)
		var p3 := _iso_pos(tx,     ty + 1, H, Hw)

		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(p0.x, p0.y, 0))
		st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(p1.x, p1.y, 0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(p2.x, p2.y, 0))

		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(p0.x, p0.y, 0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(p2.x, p2.y, 0))
		st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(p3.x, p3.y, 0))

	return st.commit()

func _add_tile_outlines(line: Line2D, bx: int, by: int, tw: int, th: int, H: PackedInt32Array, Hw: int) -> void:
	line.clear_points()
	var x0: int = bx * tiles_per_block
	var y0: int = by * tiles_per_block
	var x1: int = min(x0 + tiles_per_block, tw)
	var y1: int = min(y0 + tiles_per_block, th)
	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			line.add_point(_iso_pos(tx, ty, H, Hw))

# CentrED#-style per-tile diamond outlines (+ diagonals)
func _add_square_outlines(block_node: Node2D, bx: int, by: int, tw: int, th: int, H: PackedInt32Array, Hw: int) -> void:
	var x0: int = bx * tiles_per_block
	var y0: int = by * tiles_per_block
	var x1: int = min(x0 + tiles_per_block, tw)
	var y1: int = min(y0 + tiles_per_block, th)

	var tiles := []
	for ty in range(y0, y1):
		for tx in range(x0, x1):
			tiles.append(Vector2i(tx, ty))
	tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a.x + a.y) < (b.x + b.y)
	)

	for t in tiles:
		var tx: int = t.x
		var ty: int = t.y

		var p0 := _iso_pos(tx,     ty,     H, Hw)
		var p1 := _iso_pos(tx + 1, ty,     H, Hw)
		var p2 := _iso_pos(tx + 1, ty + 1, H, Hw)
		var p3 := _iso_pos(tx,     ty + 1, H, Hw)

		var edge := Line2D.new()
		edge.name = "Sq_%d_%d_Edge" % [tx, ty]
		edge.default_color = square_outline_color
		edge.width = 1.0
		edge.antialiased = true
		edge.closed = true
		edge.add_point(p0); edge.add_point(p1); edge.add_point(p2); edge.add_point(p3)
		edge.visible = _square_outlines_visible
		edge.add_to_group("square_outlines")
		block_node.add_child(edge)

		if draw_square_diagonals:
			var d1 := Line2D.new()
			d1.name = "Sq_%d_%d_DiagA" % [tx, ty]
			d1.default_color = square_diag_color
			d1.width = 1.0
			d1.antialiased = true
			d1.add_point(p0); d1.add_point(p2)
			d1.visible = _square_outlines_visible
			d1.add_to_group("square_outlines")
			block_node.add_child(d1)

			var d2 := Line2D.new()
			d2.name = "Sq_%d_%d_DiagB" % [tx, ty]
			d2.default_color = square_diag_color
			d2.width = 1.0
			d2.antialiased = true
			d2.add_point(p1); d2.add_point(p3)
			d2.visible = _square_outlines_visible
			d2.add_to_group("square_outlines")
			block_node.add_child(d2)

# ---------- Geometry ----------
func _derived_tile_dims() -> Vector2:
	var w: float = max(float(tile_px.x), 1.0)
	var h: float = max(float(tile_px.y), 1.0) # usually equal to w
	return Vector2(w, h)

# 45° diamond placement (grid unchanged)
func _iso_pos(ix: int, iy: int, H: PackedInt32Array, Hw: int) -> Vector2:
	var dims := _derived_tile_dims()
	var w: float = dims.x
	var h: float = dims.y
	var z: float = -float(_corner_h(ix, iy, H, Hw)) * heights_scale_px
	return Vector2(
		(ix - iy) * (w * 0.5),
		(ix + iy) * (h * 0.5) + z
	)

func _corner_h(ix: int, iy: int, H: PackedInt32Array, Hw: int) -> int:
	if ix < 0 or iy < 0 or iy * Hw + ix >= H.size(): return 0
	return H[iy * Hw + ix]

func _clear_blocks() -> void:
	if _ground_parent == null: return
	for c in _ground_parent.get_children(): c.queue_free()

func _log(msg: String) -> void:
	if debug_log: print("[MapBake2D] %s" % msg)
