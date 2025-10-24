@tool
# mapBake2D.gd — Bake MAP0.MUL → tile_heights.res + tiletex_info.res, then build MeshInstance2D blocks (editor-visible)
extends Node
class_name MapBake2DEditor

# ---------- Exports ----------
@export_file("*") var mul_path: String = "" : set = set_mul_path
@export var map_tiles: Vector2i = Vector2i(256, 256) : set = set_map_tiles
@export var tiles_per_block: int = 16 : set = set_tiles_per_block
@export var tile_px: Vector2 = Vector2(88, 44) : set = set_tile_px
@export var heights_scale_px: float = 4.0 : set = set_heights_scale_px
@export var ground_parent_path: NodePath = ^"GroundBlocks" : set = set_ground_parent_path
@export var placeholder_texture_path: String = "res://assets/terrain/desertv0.png" : set = set_placeholder_texture_path
@export var show_tile_outlines: bool = true : set = set_show_tile_outlines
@export var outline_color: Color = Color(1, 1, 0, 0.85) : set = set_outline_color
@export var flip_y: bool = false : set = set_flip_y
@export var swap_xy: bool = false : set = set_swap_xy
@export var map_center_offset: Vector2 = Vector2.ZERO : set = set_map_center_offset
@export var debug_log: bool = true

# Resource paths
const PATH_TILE_HEIGHTS := "res://assets/data/tile_heights.res"
const PATH_TEX_INFO := "res://assets/data/tiletex_info.res"
const PATH_TILE_REG := "res://assets/data/tile_registry.res"

# ---------- Internals ----------
var _ground_parent: Node2D
var _mat: ShaderMaterial

# ---------- Ready ----------
func _ready() -> void:
	_log("--- MapBake2D READY (editor:%s) ---" % [Engine.is_editor_hint()])
	_ensure_ground_parent()
	_center_parent()
	_setup_material()
	_ensure_tile_registry()
	_editor_build()

# ---------- Editor setters (live rebuild) ----------
func set_mul_path(v: String) -> void:
	mul_path = v
	_log("set mul_path → %s" % v)
	if Engine.is_editor_hint():
		_editor_build()

func set_map_tiles(v: Vector2i) -> void:
	map_tiles = v
	_log("set map_tiles → %s" % [v])
	if Engine.is_editor_hint():
		_center_parent()
		_editor_build()

func set_tiles_per_block(v: int) -> void:
	tiles_per_block = max(1, v)
	_log("set tiles_per_block → %d" % tiles_per_block)
	if Engine.is_editor_hint():
		_editor_build()

func set_tile_px(v: Vector2) -> void:
	tile_px = v
	_log("set tile_px → %s" % [v])
	if Engine.is_editor_hint():
		_center_parent()
		_editor_build()

func set_heights_scale_px(v: float) -> void:
	heights_scale_px = v
	_log("set heights_scale_px → %.3f" % v)
	if Engine.is_editor_hint():
		_editor_build()

func set_ground_parent_path(v: NodePath) -> void:
	ground_parent_path = v
	_log("set ground_parent_path → %s" % [v])
	_ensure_ground_parent()
	if Engine.is_editor_hint():
		_editor_build()

func set_placeholder_texture_path(v: String) -> void:
	placeholder_texture_path = v
	_log("set placeholder_texture_path → %s" % v)
	if _mat:
		var tex: Resource = load(placeholder_texture_path)
		if tex is Texture2D:
			_mat.set_shader_parameter("u_tex", tex)
		else:
			_mat.set_shader_parameter("u_tex", null)
			push_warning("Texture not found at %s" % placeholder_texture_path)
	if Engine.is_editor_hint():
		_editor_build()

func set_show_tile_outlines(v: bool) -> void:
	show_tile_outlines = v
	_log("set show_tile_outlines → %s" % [v])
	if Engine.is_editor_hint():
		_editor_build()

func set_outline_color(v: Color) -> void:
	outline_color = v
	_log("set outline_color")
	if Engine.is_editor_hint():
		_editor_build()

func set_flip_y(v: bool) -> void:
	flip_y = v
	_log("set flip_y → %s" % [v])
	if Engine.is_editor_hint():
		_editor_build()

func set_swap_xy(v: bool) -> void:
	swap_xy = v
	_log("set_swap_xy → %s" % [v])
	if Engine.is_editor_hint():
		_editor_build()

func set_map_center_offset(v: Vector2) -> void:
	map_center_offset = v
	_log("set map_center_offset → %s" % [v])
	if Engine.is_editor_hint():
		_center_parent()

# ---------- Build orchestration ----------
func _editor_build() -> void:
	_log("• editor_build() start")
	if mul_path.is_empty():
		_log("  mul_path empty → draw flat preview")
		_build_flat_preview()
		return
	if bake_from_mul():
		_log("  bake_from_mul: OK → build_all_blocks")
		build_all_blocks()
	else:
		_log("  bake_from_mul: FAILED → draw flat preview")
		_build_flat_preview()

# ---------- Setup helpers ----------
func _ensure_ground_parent() -> void:
	_ground_parent = get_node_or_null(ground_parent_path) as Node2D
	if _ground_parent == null:
		var gb: Node2D = Node2D.new()
		gb.name = "GroundBlocks"
		add_child(gb)
		_ground_parent = gb
		ground_parent_path = ^"GroundBlocks"
	_log("  Ground parent path: %s (node: %s)" % [ground_parent_path, _ground_parent])

func _center_parent() -> void:
	if _ground_parent:
		_ground_parent.position = map_center_offset
		_log("  GroundBlocks.position = %s" % [_ground_parent.position])

func _setup_material() -> void:
	# ShaderMaterial (CanvasItem) so MeshInstance2D can sample a texture via UV.
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	# NOTE: no ': hint_albedo' here so the GDScript lexer never misinterprets a colon.
	sh.code = """
shader_type canvas_item;
uniform sampler2D u_tex;
void fragment() {
	COLOR = texture(u_tex, UV);
}
"""
	_mat.shader = sh

	var tex: Resource = load(placeholder_texture_path)
	if tex is Texture2D:
		_mat.set_shader_parameter("u_tex", tex)
	else:
		_mat.set_shader_parameter("u_tex", null)
	_log("  Material ready (shader set, texture ok: %s)" % [tex is Texture2D])

func _ensure_tile_registry() -> void:
	if not ResourceLoader.exists(PATH_TILE_REG):
		var reg: Resource = Resource.new()
		reg.set_meta("schema", "tile_registry_v1")
		var err: int = ResourceSaver.save(reg, PATH_TILE_REG)
		if err != OK:
			push_error("Failed saving tile_registry.res: %s" % err)
		else:
			_log("  Created tile_registry.res")

# -------------------------
# BAKING
# -------------------------
func bake_from_mul() -> bool:
	_log("• bake_from_mul(%s) ..." % mul_path)
	var result: Dictionary = _read_map_mul(mul_path, map_tiles)
	if not result.get("ok", false):
		_log("  read_map_mul → FAILED")
		return false

	var tile_ids: PackedInt32Array = result["tile_ids"]
	var corner_heights: PackedInt32Array = result["corner_heights"]
	_log("  read_map_mul OK → tile_ids:%d, corner_heights:%d" % [tile_ids.size(), corner_heights.size()])

	var tex_info: PackedInt32Array = tile_ids.duplicate()

	var heights_res: Resource = Resource.new()
	heights_res.set_meta("w", map_tiles.x + 1)
	heights_res.set_meta("h", map_tiles.y + 1)
	heights_res.set_meta("data", corner_heights)
	var err_h: int = ResourceSaver.save(heights_res, PATH_TILE_HEIGHTS)
	if err_h != OK:
		push_error("Failed saving tile_heights.res: %s" % err_h)
		return false

	var tex_res: Resource = Resource.new()
	tex_res.set_meta("w", map_tiles.x)
	tex_res.set_meta("h", map_tiles.y)
	tex_res.set_meta("data", tex_info)
	var err_t: int = ResourceSaver.save(tex_res, PATH_TEX_INFO)
	if err_t != OK:
		push_error("Failed saving tiletex_info.res: %s" % err_t)
		return false

	_log("  Baked: %s, %s" % [PATH_TILE_HEIGHTS, PATH_TEX_INFO])
	return true

# signed int8 helper
func _get_i8(f: FileAccess) -> int:
	var b: int = f.get_8()
	return b - 256 if b >= 128 else b

# Returns { ok: bool, tile_ids: PackedInt32Array, corner_heights: PackedInt32Array }
func _read_map_mul(path: String, size_tiles: Vector2i) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open MAP0.MUL: %s" % path)
		return { "ok": false }
	f.big_endian = false

	var W: int = size_tiles.x
	var H: int = size_tiles.y
	if W <= 0 or H <= 0:
		push_error("Invalid map_tiles")
		f.close()
		return { "ok": false }

	var bx_count: int = int(ceil(W / 8.0))
	var by_count: int = int(ceil(H / 8.0))
	var BLOCK_SIZE: int = 196

	var tile_id_per_tile: PackedInt32Array = PackedInt32Array(); tile_id_per_tile.resize(W * H)
	var z_per_tile: PackedInt32Array = PackedInt32Array(); z_per_tile.resize(W * H)
	var min_z: int = 9999
	var max_z: int = -9999

	for bx in range(bx_count):
		for by in range(by_count):
			var block_index: int = bx * by_count + by
			var seek_pos: int = block_index * BLOCK_SIZE
			if seek_pos + BLOCK_SIZE > f.get_length():
				continue
			f.seek(seek_pos)
			f.get_32() # header
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
						if z < min_z: min_z = z
						if z > max_z: max_z = z

	f.close()
	_log("  MAP read: %dx%d tiles, blocks %dx%d, z range %d..%d" % [W, H, bx_count, by_count, min_z, max_z])

	# Optional axis fixes on per-tile arrays
	if swap_xy:
		var swapped_ids: PackedInt32Array = PackedInt32Array(); swapped_ids.resize(W * H)
		var swapped_z: PackedInt32Array = PackedInt32Array(); swapped_z.resize(W * H)
		for y in range(H):
			for x in range(W):
				var sx: int = y; var sy: int = x
				if sx < W and sy < H:
					swapped_ids[sy * W + sx] = tile_id_per_tile[y * W + x]
					swapped_z[sy * W + sx] = z_per_tile[y * W + x]
		tile_id_per_tile = swapped_ids; z_per_tile = swapped_z
		_log("  swap_xy applied")

	if flip_y:
		var half_h: int = H / 2
		for y in range(half_h):
			var y2: int = H - 1 - y
			for x in range(W):
				var a: int = y * W + x; var b: int = y2 * W + x
				var tmp_id: int = tile_id_per_tile[a]; tile_id_per_tile[a] = tile_id_per_tile[b]; tile_id_per_tile[b] = tmp_id
				var tmp_z: int = z_per_tile[a]; z_per_tile[a] = z_per_tile[b]; z_per_tile[b] = tmp_z
		_log("  flip_y applied")

	# Per-tile Z -> per-corner Z (W+1 x H+1)
	var corner_heights: PackedInt32Array = PackedInt32Array(); corner_heights.resize((W + 1) * (H + 1))
	for cy in range(H + 1):
		for cx in range(W + 1):
			var sum: int = 0; var count: int = 0
			if cx > 0 and cy > 0: sum += z_per_tile[(cy - 1) * W + (cx - 1)]; count += 1
			if cx < W and cy > 0: sum += z_per_tile[(cy - 1) * W + cx]; count += 1
			if cx > 0 and cy < H: sum += z_per_tile[cy * W + (cx - 1)]; count += 1
			if cx < W and cy < H: sum += z_per_tile[cy * W + cx]; count += 1
			var h: int = int(round(float(sum) / max(count, 1)))
			corner_heights[cy * (W + 1) + cx] = h

	return { "ok": true, "tile_ids": tile_id_per_tile, "corner_heights": corner_heights }

# -------------------------
# BUILDING (uses baked data if present; otherwise a flat grid)
# -------------------------
func build_all_blocks() -> void:
	_log("• build_all_blocks()")
	_clear_blocks()

	var heights_res: Resource = ResourceLoader.load(PATH_TILE_HEIGHTS)
	var tex_res: Resource = ResourceLoader.load(PATH_TEX_INFO)

	if heights_res == null or tex_res == null:
		_log("  Missing baked resources → preview instead")
		_build_flat_preview()
		return

	var H_w: int = int(heights_res.get_meta("w"))
	var H_corners: PackedInt32Array = heights_res.get_meta("data")
	var T_w: int = int(tex_res.get_meta("w"))
	var T_h: int = int(tex_res.get_meta("h"))
	_log("  Build from baked → tex:%dx%d, corners_w:%d, corners_size:%d" % [T_w, T_h, H_w, H_corners.size()])

	var blocks_x: int = int(ceil(float(T_w) / float(tiles_per_block)))
	var blocks_y: int = int(ceil(float(T_h) / float(tiles_per_block)))
	_log("  Blocks: %dx%d (tiles_per_block=%d)" % [blocks_x, blocks_y, tiles_per_block])

	var total_meshes: int = 0
	for by in range(blocks_y):
		for bx in range(blocks_x):
			var x0: int = bx * tiles_per_block
			var y0: int = by * tiles_per_block

			var block_node: Node2D = Node2D.new()
			block_node.name = "Block_%d_%d" % [bx, by]
			block_node.position = _iso_pos(x0, y0) # lay out blocks in world
			_ground_parent.add_child(block_node)

			var mesh_instance: MeshInstance2D = MeshInstance2D.new()
			mesh_instance.name = "Mesh"
			mesh_instance.material = _mat
			mesh_instance.mesh = _build_block_mesh(bx, by, T_w, T_h, H_corners, H_w)
			block_node.add_child(mesh_instance)
			total_meshes += 1

			if show_tile_outlines:
				var outline: Line2D = Line2D.new()
				outline.name = "Outline"
				outline.default_color = outline_color
				outline.width = 1.0
				outline.antialiased = true
				outline.z_index = 1000  # ensure on top in game
				_add_tile_outlines(outline, bx, by, T_w, T_h, H_corners, H_w)
				block_node.add_child(outline)
	_log("  Created %d MeshInstance2D blocks under %s" % [total_meshes, _ground_parent.get_path()])

# Flat preview (no baked data): zero heights over map_tiles
func _build_flat_preview() -> void:
	_log("• _build_flat_preview() map_tiles=%s" % [map_tiles])
	_clear_blocks()

	var W: int = map_tiles.x
	var Ht: int = map_tiles.y
	var H_corners: PackedInt32Array = PackedInt32Array(); H_corners.resize((W + 1) * (Ht + 1))

	var blocks_x: int = int(ceil(float(W) / float(tiles_per_block)))
	var blocks_y: int = int(ceil(float(Ht) / float(tiles_per_block)))
	_log("  Preview blocks: %dx%d" % [blocks_x, blocks_y])

	var total_meshes: int = 0
	for by in range(blocks_y):
		for bx in range(blocks_x):
			var x0: int = bx * tiles_per_block
			var y0: int = by * tiles_per_block

			var block_node: Node2D = Node2D.new()
			block_node.name = "Block_%d_%d" % [bx, by]
			block_node.position = _iso_pos(x0, y0)
			_ground_parent.add_child(block_node)

			var mesh_instance: MeshInstance2D = MeshInstance2D.new()
			mesh_instance.name = "Mesh"
			mesh_instance.material = _mat
			mesh_instance.mesh = _build_block_mesh(bx, by, W, Ht, H_corners, W + 1)
			block_node.add_child(mesh_instance)
			total_meshes += 1

			if show_tile_outlines:
				var outline: Line2D = Line2D.new()
				outline.name = "Outline"
				outline.default_color = outline_color
				outline.width = 1.0
				outline.antialiased = true
				outline.z_index = 1000
				_add_tile_outlines(outline, bx, by, W, Ht, H_corners, W + 1)
				block_node.add_child(outline)

	_log("  Preview created %d MeshInstance2D blocks" % total_meshes)

func _clear_blocks() -> void:
	if _ground_parent == null:
		return
	var count: int = _ground_parent.get_child_count()
	for c in _ground_parent.get_children():
		c.queue_free()
	_log("  Cleared %d existing children under %s" % [count, _ground_parent.get_path()])

# -------------------------
# MESH/OUTLINE BUILD HELPERS
# -------------------------
func _build_block_mesh(bx: int, by: int, tw: int, th: int, H: PackedInt32Array, Hw: int) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var x0: int = bx * tiles_per_block
	var y0: int = by * tiles_per_block
	var x1: int = min(x0 + tiles_per_block, tw)
	var y1: int = min(y0 + tiles_per_block, th)

	for ty in range(y0, y1):
		for tx in range(x0, x1):
			var lx: int = tx - x0
			var ly: int = ty - y0

			var p0: Vector2 = _iso_pos(lx, ly) + Vector2(0, -_corner_h(tx, ty, H, Hw) * heights_scale_px)
			var p1: Vector2 = _iso_pos(lx + 1, ly) + Vector2(0, -_corner_h(tx + 1, ty, H, Hw) * heights_scale_px)
			var p2: Vector2 = _iso_pos(lx + 1, ly + 1) + Vector2(0, -_corner_h(tx + 1, ty + 1, H, Hw) * heights_scale_px)
			var p3: Vector2 = _iso_pos(lx, ly + 1) + Vector2(0, -_corner_h(tx, ty + 1, H, Hw) * heights_scale_px)

			var uv0: Vector2 = Vector2(float(lx) / tiles_per_block, float(ly) / tiles_per_block)
			var uv1: Vector2 = Vector2(float(lx + 1) / tiles_per_block, float(ly) / tiles_per_block)
			var uv2: Vector2 = Vector2(float(lx + 1) / tiles_per_block, float(ly + 1) / tiles_per_block)
			var uv3: Vector2 = Vector2(float(lx) / tiles_per_block, float(ly + 1) / tiles_per_block)

			st.set_uv(uv0); st.add_vertex(Vector3(p0.x, p0.y, 0))
			st.set_uv(uv1); st.add_vertex(Vector3(p1.x, p1.y, 0))
			st.set_uv(uv2); st.add_vertex(Vector3(p2.x, p2.y, 0))
			st.set_uv(uv0); st.add_vertex(Vector3(p0.x, p0.y, 0))
			st.set_uv(uv2); st.add_vertex(Vector3(p2.x, p2.y, 0))
			st.set_uv(uv3); st.add_vertex(Vector3(p3.x, p3.y, 0))

	return st.commit()

func _add_tile_outlines(line: Line2D, bx: int, by: int, tw: int, th: int, H: PackedInt32Array, Hw: int) -> void:
	line.clear_points()

	var Hh: int = int(float(H.size()) / float(Hw)) if Hw > 0 else 0

	var x0: int = bx * tiles_per_block
	var y0: int = by * tiles_per_block
	var x1: int = min(x0 + tiles_per_block + 1, tw + 1)
	var y1: int = min(y0 + tiles_per_block + 1, th + 1)

	for ty in range(y0, y1):
		for tx in range(x0, x1):
			var lx: int = tx - x0
			var ly: int = ty - y0
			if Hw <= 0 or Hh <= 0 or tx >= Hw or ty >= Hh:
				continue
			var p: Vector2 = _iso_pos(lx, ly) + Vector2(0, -_corner_h(tx, ty, H, Hw) * heights_scale_px)
			line.add_point(p)

	var pts: PackedVector2Array = line.points
	if pts.size() < 2:
		return
	for i in range(pts.size() - 1):
		if (i + 1) % (tiles_per_block + 1) != 0:
			line.add_point(pts[i + 1])
			line.add_point(pts[i])

# -------------------------
# MATH HELPERS
# -------------------------
func _iso_pos(ix: float, iy: float) -> Vector2:
	return Vector2((ix - iy) * tile_px.x * 0.5, (ix + iy) * tile_px.y * 0.5)

func _corner_h(ix: int, iy: int, H: PackedInt32Array, Hw: int) -> int:
	if ix < 0 or iy < 0 or iy * Hw + ix >= H.size():
		return 0
	return H[iy * Hw + ix]

# -------------------------
# Logging
# -------------------------
func _log(msg: String) -> void:
	if debug_log:
		print("[MapBake2D] %s" % msg)
