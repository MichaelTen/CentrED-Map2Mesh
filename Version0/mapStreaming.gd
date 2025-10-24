# mapSreaming.gd — keep only needed 16×16 blocks visible based on Camera2D + viewport size
extends Node
class_name MapSreaming

@export var ground_parent_path: NodePath = ^"../GroundBlocks"
@export var camera_path: NodePath = ^"../Camera2D"
@export var tiles_per_block: int = 16
@export var tile_px: Vector2 = Vector2(88, 44)
@export var preload_margin_blocks: int = 2
@export var map_tiles: Vector2i = Vector2i(256, 256)

var _ground: Node2D
var _cam: Camera2D
var _active: Dictionary = {}   # Vector2i -> Node2D

func _ready() -> void:
	_ground = get_node_or_null(ground_parent_path) as Node2D
	_cam = get_node_or_null(camera_path) as Camera2D
	if not _ground or not _cam:
		push_error("mapSreaming.gd: set ground_parent_path and camera_path.")
		set_process(false)
		return
	set_process(true)

func _process(_dt: float) -> void:
	_update_visible_blocks()

func _update_visible_blocks() -> void:
	var root_rect := get_viewport().get_visible_rect()
	var view_px := root_rect.size
	var world_size := Vector2(view_px.x * _cam.zoom.x, view_px.y * _cam.zoom.y)
	var half := world_size * 0.5
	var view_rect := Rect2(_cam.global_position - half, world_size)

	var corners := [
		view_rect.position,
		view_rect.position + Vector2(view_rect.size.x, 0),
		view_rect.position + Vector2(0, view_rect.size.y),
		view_rect.position + view_rect.size
	]

	var min_b := Vector2i( 2147483647,  2147483647)
	var max_b := Vector2i(-2147483648, -2147483648)

	for p in corners:
		var t := _world_px_to_tile(p)
		var b := Vector2i(t.x / tiles_per_block, t.y / tiles_per_block)
		min_b = Vector2i(min(min_b.x, b.x), min(min_b.y, b.y))
		max_b = Vector2i(max(max_b.x, b.x), max(max_b.y, b.y))

	min_b -= Vector2i(preload_margin_blocks, preload_margin_blocks)
	max_b += Vector2i(preload_margin_blocks, preload_margin_blocks)

	var blocks_total := Vector2i(
		int(ceil(float(map_tiles.x) / float(tiles_per_block))),
		int(ceil(float(map_tiles.y) / float(tiles_per_block)))
	)
	min_b = Vector2i(clamp(min_b.x, 0, blocks_total.x - 1), clamp(min_b.y, 0, blocks_total.y - 1))
	max_b = Vector2i(clamp(max_b.x, 0, blocks_total.x - 1), clamp(max_b.y, 0, blocks_total.y - 1))

	var want: Dictionary = {}
	for by in range(min_b.y, max_b.y + 1):
		for bx in range(min_b.x, max_b.x + 1):
			want[Vector2i(bx, by)] = true

	# Activate blocks already present under GroundBlocks (built by baker)
	for key in want.keys():
		if not _active.has(key):
			var node := _ground.get_node_or_null("Block_%d_%d" % [key.x, key.y]) as Node2D
			if node:
				_active[key] = node

	# Deactivate (hide) blocks not wanted
	for key in _active.keys():
		var node := _active[key] as Node2D
		if node:
			node.visible = want.has(key)

# Dimetric 2:1 inverse (world px → tile)
func _world_px_to_tile(p: Vector2) -> Vector2i:
	var a := tile_px.x * 0.5
	var b := tile_px.y * 0.5
	var ix_f := 0.5 * ((p.x / a) + (p.y / b))
	var iy_f := 0.5 * ((p.y / b) - (p.x / a))
	return Vector2i(floor(ix_f), floor(iy_f))
