class_name WorldView
extends Control
## Draws the generated map, the territory the tribe works, and the settlement
## itself. Everything is drawn with primitives - no art dependencies - so the
## project runs the moment it is cloned.

const DEPLETED := Color("6b5a3c")
const TERRITORY_LINE := Color(1, 1, 1, 0.30)

var _redraw_accum := 0.0

## Deterministic scatter positions for settlement structures, so buildings do
## not jump around between frames.
var _scatter: Array[Vector2] = []


func _ready() -> void:
	custom_minimum_size = Vector2(420, 280)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_make_scatter()
	Sim.game_reset.connect(_make_scatter)


func _make_scatter() -> void:
	_scatter.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240817
	for i in 128:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * 2.6
		_scatter.append(Vector2(cos(a) * r, sin(a) * r))


func _process(delta: float) -> void:
	_redraw_accum += delta
	if _redraw_accum >= 0.2:
		_redraw_accum = 0.0
		queue_redraw()


func _draw() -> void:
	var world := Sim.world
	if world == null:
		return

	var ts := minf(size.x / float(world.w), size.y / float(world.h))
	var ox := (size.x - ts * world.w) * 0.5
	var oy := (size.y - ts * world.h) * 0.5
	var origin_px := Vector2(ox + (world.origin.x + 0.5) * ts, oy + (world.origin.y + 0.5) * ts)

	draw_rect(Rect2(Vector2.ZERO, size), Color("0f1216"))

	# Terrain, tinted by how hard the tribe has worked it.
	for y in world.h:
		for x in world.w:
			var i := world.idx(x, y)
			var c: Color = Balance.BIOME_INFO[world.biome[i]]["color"]
			if world.forest_cap[i] > 0.5:
				var loss := 1.0 - clampf(world.forest[i] / world.forest_cap[i], 0.0, 1.0)
				c = c.lerp(DEPLETED, loss * 0.75)
			draw_rect(Rect2(ox + x * ts, oy + y * ts, ts + 0.5, ts + 0.5), c, true)

	# Game density: a dot per tile with a healthy herd.
	for i in world.territory:
		if world.game_cap[i] <= 0.5:
			continue
		var frac := clampf(world.game[i] / world.game_cap[i], 0.0, 1.0)
		if frac < 0.12:
			continue
		var tx := i % world.w
		var ty := i / world.w
		var p := Vector2(ox + (tx + 0.5) * ts, oy + (ty + 0.5) * ts)
		draw_circle(p, ts * 0.13 * frac, Color(0.95, 0.85, 0.55, 0.30 + 0.4 * frac))

	# Mineral seams. Only what the tribe has learned to recognise is marked, so
	# the map visibly gains detail as the civilisation advances.
	if Sim.job_unlocked("miner"):
		var ore_col: Color = Balance.ORE_TIERS[Sim.ore_tier()]["color"]
		for i in world.territory:
			var tx := i % world.w
			var ty := i / world.w
			var p := Vector2(ox + (tx + 0.5) * ts, oy + (ty + 0.5) * ts)
			if world.ore[i] > 0.18:
				draw_rect(Rect2(p - Vector2(ts * 0.14, ts * 0.14), Vector2(ts * 0.28, ts * 0.28)),
						ore_col, true)
			if world.gold[i] > 0.10:
				draw_circle(p + Vector2(ts * 0.22, -ts * 0.22), ts * 0.11, Color("e3c14f"))

	# Territory ring.
	draw_arc(origin_px, world.territory_radius * ts, 0.0, TAU, 72, TERRITORY_LINE, maxf(1.0, ts * 0.08), true)

	_draw_settlement(origin_px, ts)


func _draw_settlement(center: Vector2, ts: float) -> void:
	var scale := maxf(ts, 4.0)

	# Hearth at the middle, once it exists.
	if Sim.buildings.get("firepit", 0) > 0:
		draw_circle(center, scale * 0.42, Color("d96a2b"))
		draw_circle(center, scale * 0.22, Color("f2c15a"))
	else:
		draw_circle(center, scale * 0.28, Color("3b332a"))

	var slot := 0
	slot = _draw_group(center, scale, "windbreak", slot, Color("7d6a4e"), "tent")
	slot = _draw_group(center, scale, "hut", slot, Color("9c7b4f"), "hut")
	slot = _draw_group(center, scale, "longhouse", slot, Color("b09068"), "long")
	slot = _draw_group(center, scale, "farm_plot", slot, Color("b8a24a"), "field")
	slot = _draw_group(center, scale, "granary", slot, Color("cbb27a"), "hut")
	slot = _draw_group(center, scale, "woodshed", slot, Color("7a6242"), "hut")
	slot = _draw_group(center, scale, "well", slot, Color("6fa3c4"), "well")
	slot = _draw_group(center, scale, "quarry", slot, Color("8e9298"), "field")
	slot = _draw_group(center, scale, "mine", slot, Color("6b5a4a"), "mine")
	slot = _draw_group(center, scale, "smelter", slot, Color("c2603a"), "hut")
	slot = _draw_group(center, scale, "stone_house", slot, Color("a8a49b"), "hut")
	slot = _draw_group(center, scale, "treasury", slot, Color("e3c14f"), "long")
	slot = _draw_group(center, scale, "drying_rack", slot, Color("8a7355"), "tent")
	slot = _draw_group(center, scale, "shrine", slot, Color("b08ad4"), "shrine")


func _draw_group(center: Vector2, scale: float, id: String, slot: int, color: Color, shape: String) -> int:
	var count: int = Sim.buildings.get(id, 0)
	for n in count:
		if slot >= _scatter.size():
			break
		var p := center + _scatter[slot] * scale
		slot += 1
		match shape:
			"tent":
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-scale * 0.28, scale * 0.24),
					p + Vector2(scale * 0.28, scale * 0.24),
					p + Vector2(0, -scale * 0.28),
				]), color)
			"hut":
				draw_rect(Rect2(p - Vector2(scale * 0.26, scale * 0.20), Vector2(scale * 0.52, scale * 0.44)), color, true)
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-scale * 0.32, -scale * 0.18),
					p + Vector2(scale * 0.32, -scale * 0.18),
					p + Vector2(0, -scale * 0.48),
				]), color.darkened(0.25))
			"long":
				draw_rect(Rect2(p - Vector2(scale * 0.55, scale * 0.22), Vector2(scale * 1.1, scale * 0.44)), color, true)
			"field":
				draw_rect(Rect2(p - Vector2(scale * 0.42, scale * 0.28), Vector2(scale * 0.84, scale * 0.56)), color, true)
				draw_rect(Rect2(p - Vector2(scale * 0.42, scale * 0.28), Vector2(scale * 0.84, scale * 0.56)), color.darkened(0.4), false, maxf(1.0, scale * 0.05))
			"well":
				draw_circle(p, scale * 0.24, color)
				draw_circle(p, scale * 0.12, Color("24404f"))
			"mine":
				draw_rect(Rect2(p - Vector2(scale * 0.26, scale * 0.10), Vector2(scale * 0.52, scale * 0.34)), color, true)
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-scale * 0.26, -scale * 0.10),
					p + Vector2(scale * 0.26, -scale * 0.10),
					p + Vector2(0, -scale * 0.38),
				]), Color("2a2320"))
			"shrine":
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-scale * 0.22, scale * 0.28),
					p + Vector2(scale * 0.22, scale * 0.28),
					p + Vector2(0, -scale * 0.42),
				]), color)
	return slot
