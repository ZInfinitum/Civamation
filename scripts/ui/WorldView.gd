class_name WorldView
extends Control
## The map: terrain, fog of war, wildlife, work parties and the settlement.
##
## Performance shape, because this is the only thing in the game that could
## plausibly cost anything:
##
## * The terrain is a 96x64 `ImageTexture` drawn as **one** scaled rect with
##   nearest-neighbour filtering. Drawing it as tiles would be 6,144 draw calls
##   per frame; this is one. The texture is rebuilt from a packed byte buffer
##   only when something actually changed, at most a few times a second.
## * Everything else - animals, workers, buildings - is drawn only when zoomed
##   in far enough to read, only for tiles actually on screen, and capped to a
##   fixed budget of primitives regardless of how big the civilisation gets.
## * `_draw` never runs on a timer. It runs when the world changed.
##
## Everything is drawn with primitives *by default*, so the project has no art
## dependencies and runs the moment it is cloned. Every one of those shapes is
## also a fallback: if `Art` has a texture for a biome, building, animal or
## worker, that is drawn instead, with no other change anywhere. See
## `assets/README.md`.

const FOG := Color("0a0d11")
const FOG_EDGE := Color("161c23")
const TERRITORY_LINE := Color(1, 1, 1, 0.32)
const DEPLETED := Color("6b5a3c")

## Pixels per tile. Below this, overlays are unreadable and are skipped.
const DETAIL_ZOOM := 9.0
const ANIMAL_ZOOM := 7.0
## Terrain sprites are one draw call per visible tile, so they only appear once
## tiles are big enough to be worth it - which also bounds how many there are.
const TERRAIN_SPRITE_ZOOM := 8.0
const MAX_TERRAIN_SPRITES := 1400
const MIN_ZOOM := 3.0
const MAX_ZOOM := 26.0
## Hard ceiling on overlay primitives per frame, whatever the population.
const MAX_ANIMAL_MARKS := 90
const MAX_WORKER_MARKS := 44

var zoom: float = 13.0
var camera := Vector2.ZERO  ## in tile coordinates

var _img: Image
var _tex: ImageTexture
var _buf := PackedByteArray()
var _terrain_dirty := true
var _dirty := true
var _rebuild_accum := 0.0
var _place_accum := 0.0
var _dragging := false
## Set by the Rule tab: the next map click founds an outpost.
var placing_outpost := false

## Where each job's markers get drawn. Recomputed on a slow timer because it
## sorts, and sorting every frame for cosmetics would be absurd.
var _worker_spots := {}
## Deterministic scatter so buildings and animals do not shimmer between frames.
var _scatter: Array[Vector2] = []

var _last_explored := -1
var _last_territory := -1


func _ready() -> void:
	custom_minimum_size = Vector2(420, 300)
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_make_scatter()
	Sim.game_reset.connect(_on_reset)
	Art.reloaded.connect(func() -> void:
		_terrain_dirty = true
		_dirty = true)
	Sim.state_changed.connect(func() -> void: _dirty = true)
	resized.connect(func() -> void: _dirty = true)
	_on_reset()


func _on_reset() -> void:
	_terrain_dirty = true
	_dirty = true
	_worker_spots.clear()
	_last_explored = -1
	_last_territory = -1
	if Sim.world != null:
		camera = Vector2(Sim.world.origin)
	zoom = 13.0


func _make_scatter() -> void:
	_scatter.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240817
	for i in 256:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf())
		_scatter.append(Vector2(cos(a) * r, sin(a) * r))


func _process(delta: float) -> void:
	var world := Sim.world
	if world == null:
		return

	# The terrain image only changes when the fog or the tree cover does.
	_rebuild_accum += delta
	if _rebuild_accum >= (1.0 if Settings.reduce_motion else 0.4):
		_rebuild_accum = 0.0
		if world.explored_count != _last_explored:
			_last_explored = world.explored_count
			_terrain_dirty = true
		elif _dirty:
			# Tree cover and who-is-watching both tint the terrain.
			# Tree cover tints the terrain, so refresh it with the slow tick too.
			_terrain_dirty = true

	_place_accum += delta
	if _place_accum >= 1.0:
		_place_accum = 0.0
		if world.territory.size() != _last_territory:
			_last_territory = world.territory.size()
			_worker_spots.clear()
		_dirty = true

	if _terrain_dirty or _dirty:
		queue_redraw()


# --- Input ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			# A boon is a thing you go and collect, so it is clickable where it
			# stands rather than only on the button in the top bar.
			if mb.pressed and _boon_hit(mb.position):
				Sim.collect_boon()
				accept_event()
				return
			if mb.pressed and placing_outpost:
				var t := _screen_to_tile(mb.position).floor()
				if Sim.world.in_bounds(int(t.x), int(t.y)):
					if Sim.found_outpost(Sim.world.idx(int(t.x), int(t.y))):
						placing_outpost = false
				accept_event()
				return
			_dragging = mb.pressed
			if mb.pressed:
				grab_focus()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		camera -= (event as InputEventMouseMotion).relative / zoom
		_clamp_camera()
		_dirty = true
		accept_event()


## True when this screen point is on the boon marker.
func _boon_hit(p: Vector2) -> bool:
	var world := Sim.world
	if world == null or Sim.boon_id == "" or Sim.boon_tile < 0:
		return false
	var t := world.tile_pos(Sim.boon_tile)
	var centre := _tile_to_screen(Vector2(t) + Vector2(0.5, 0.5))
	return p.distance_to(centre) <= maxf(14.0, zoom * 0.8)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := _screen_to_tile(screen_pos)
	zoom = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)
	var after := _screen_to_tile(screen_pos)
	camera += before - after
	_clamp_camera()
	_dirty = true


func _clamp_camera() -> void:
	var world := Sim.world
	if world == null:
		return
	var half := size / zoom * 0.5
	camera.x = clampf(camera.x, -half.x * 0.5, float(world.w) + half.x * 0.5)
	camera.y = clampf(camera.y, -half.y * 0.5, float(world.h) + half.y * 0.5)


func _screen_to_tile(p: Vector2) -> Vector2:
	return camera + (p - size * 0.5) / zoom


func _tile_to_screen(t: Vector2) -> Vector2:
	return (t - camera) * zoom + size * 0.5


## Frame the whole world.
func view_world() -> void:
	var world := Sim.world
	if world == null:
		return
	zoom = clampf(minf(size.x / float(world.w), size.y / float(world.h)), MIN_ZOOM, MAX_ZOOM)
	camera = Vector2(world.w, world.h) * 0.5
	_dirty = true


## Frame the settlement.
func view_home() -> void:
	var world := Sim.world
	if world == null:
		return
	zoom = 13.0
	camera = Vector2(world.origin)
	_dirty = true


# --- Terrain texture --------------------------------------------------------

## One packed RGBA8 buffer uploaded as a single texture. Rebuilt only when the
## world changed, never per frame.
func _rebuild_terrain() -> void:
	var world := Sim.world
	if world == null:
		return
	_terrain_dirty = false

	var n := world.w * world.h
	if _buf.size() != n * 4:
		_buf.resize(n * 4)

	var faded := Settings.high_contrast
	for i in n:
		var o := i * 4
		var c: Color
		if world.explored[i] == 0:
			# Never walked. Blank - not even the shape of the land.
			c = FOG
		elif world.observed[i] == 0:
			# Walked once, nobody there now. You remember the country but not
			# what is happening on it, so this is the *remembered* biome, faded,
			# with no live tree-cover tint.
			c = Balance.BIOME_INFO[world.base_biome[i]]["color"]
			c = c.lerp(FOG_EDGE, 0.55 if faded else 0.62)
			c.s *= 0.5
		else:
			# Somebody is standing there: full colour, live state.
			c = Balance.BIOME_INFO[world.biome[i]]["color"]
			var fc: float = world.forest_cap[i]
			if fc > 0.5:
				var loss := 1.0 - clampf(world.forest[i] / fc, 0.0, 1.0)
				if loss > 0.02:
					c = c.lerp(DEPLETED, loss * 0.55)
		_buf[o] = int(c.r * 255.0)
		_buf[o + 1] = int(c.g * 255.0)
		_buf[o + 2] = int(c.b * 255.0)
		_buf[o + 3] = 255

	if _img == null:
		_img = Image.create_from_data(world.w, world.h, false, Image.FORMAT_RGBA8, _buf)
		_tex = ImageTexture.create_from_image(_img)
	else:
		_img.set_data(world.w, world.h, false, Image.FORMAT_RGBA8, _buf)
		_tex.update(_img)


# --- Drawing ----------------------------------------------------------------

func _draw() -> void:
	var world := Sim.world
	if world == null:
		return
	_dirty = false
	if _terrain_dirty or _tex == null:
		_rebuild_terrain()

	draw_rect(Rect2(Vector2.ZERO, size), Color("0a0c0f"))

	# The entire map: one draw call.
	var top_left := _tile_to_screen(Vector2.ZERO)
	draw_texture_rect(_tex, Rect2(top_left, Vector2(world.w, world.h) * zoom), false)

	# Which tiles are actually on screen. Everything below iterates this, not
	# the map, so cost is bounded by the window rather than the world.
	var lo := _screen_to_tile(Vector2.ZERO).floor()
	var hi := _screen_to_tile(size).ceil()
	var x0 := maxi(0, int(lo.x))
	var y0 := maxi(0, int(lo.y))
	var x1 := mini(world.w - 1, int(hi.x))
	var y1 := mini(world.h - 1, int(hi.y))

	# Terrain sprites, if any have been dropped in. The colour texture underneath
	# stays - it carries the fog states - and these go on top, only for tiles
	# actually on screen and only when they would be big enough to see.
	if zoom >= TERRAIN_SPRITE_ZOOM and Art.has_any("terrain"):
		_draw_terrain_sprites(world, x0, y0, x1, y1)

	if zoom >= ANIMAL_ZOOM:
		_draw_wildlife(world, x0, y0, x1, y1)
	if zoom >= DETAIL_ZOOM:
		_draw_seams(world, x0, y0, x1, y1)

	# Territory ring.
	var home := _tile_to_screen(Vector2(world.origin) + Vector2(0.5, 0.5))
	draw_arc(home, world.territory_radius * zoom, 0.0, TAU, 64, TERRITORY_LINE,
			maxf(1.0, zoom * 0.06), true)

	_draw_settlement(home)
	if zoom >= DETAIL_ZOOM:
		_draw_workers(world)
	_draw_outposts(world)
	if placing_outpost:
		_draw_placement(world)
	_draw_boon(world)
	_draw_legend()


## Real creatures on real tiles - deer, wolves, rabbits, birds - drawn only
## where somebody can currently see them. Bounded by the world's animal budget,
## so this costs the same for a city as for a camp.
func _draw_wildlife(world: CivWorld, x0: int, y0: int, x1: int, y1: int) -> void:
	var drawn := 0
	for a in world.animal_kind.size():
		if drawn >= MAX_ANIMAL_MARKS:
			break
		var i: int = world.animal_tile[a]
		# You cannot watch wildlife on ground nobody is standing on.
		if world.observed[i] == 0:
			continue
		var t := world.tile_pos(i)
		if t.x < x0 or t.x > x1 or t.y < y0 or t.y > y1:
			continue
		var kind: int = world.animal_kind[a]
		var info: Dictionary = Balance.ANIMALS[kind]
		var jitter := _scatter[(i + a) % _scatter.size()] * 0.26
		var p := _tile_to_screen(Vector2(t) + Vector2(0.5, 0.55) + jitter)
		_draw_fauna(p, zoom * 0.40, kind, info["color"])
		drawn += 1


## Ore and gold, once the tribe knows how to recognise them.
func _draw_seams(world: CivWorld, x0: int, y0: int, x1: int, y1: int) -> void:
	if not Sim.job_unlocked("miner"):
		return
	var ore_col: Color = Balance.ORE_TIERS[Sim.ore_tier()]["color"]
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := world.idx(x, y)
			if world.observed[i] == 0:
				continue
			var p := _tile_to_screen(Vector2(x, y) + Vector2(0.5, 0.5))
			if world.ore[i] > 0.35:
				var s := zoom * 0.13
				draw_rect(Rect2(p - Vector2(s, s) - Vector2(zoom * 0.22, 0), Vector2(s, s) * 2.0), ore_col, true)
			if world.gold[i] > 0.16:
				draw_circle(p + Vector2(zoom * 0.22, -zoom * 0.18), zoom * 0.10, Color("e3c14f"))


# --- Animal silhouettes -----------------------------------------------------
## Four creatures, four unmistakable outlines: deer carry antlers, wolves are
## long and low with a raised tail, rabbits are a ball with ears, birds are a
## wing stroke. Readable at ten pixels, which is the whole requirement.

func _draw_fauna(p: Vector2, s: float, kind: int, col: Color) -> void:
	match kind:
		Balance.Animal.DEER:
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(-s * 0.7, -s * 0.05), p + Vector2(s * 0.45, -s * 0.2),
				p + Vector2(s * 0.45, s * 0.4), p + Vector2(-s * 0.65, s * 0.4),
			]), col)
			var head := p + Vector2(s * 0.6, -s * 0.4)
			draw_line(p + Vector2(s * 0.45, -s * 0.15), head, col, maxf(1.0, s * 0.22))
			# Antlers - the tell.
			draw_line(head, head + Vector2(-s * 0.3, -s * 0.6), col, maxf(1.0, s * 0.15))
			draw_line(head, head + Vector2(s * 0.35, -s * 0.55), col, maxf(1.0, s * 0.15))
		Balance.Animal.WOLF:
			# Long, low, level back; brush tail up; muzzle out front.
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(-s * 0.75, -s * 0.05), p + Vector2(s * 0.5, -s * 0.1),
				p + Vector2(s * 0.5, s * 0.3), p + Vector2(-s * 0.7, s * 0.32),
			]), col)
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(s * 0.45, -s * 0.2), p + Vector2(s * 1.0, s * 0.05),
				p + Vector2(s * 0.45, s * 0.18),
			]), col)
			# Ears and tail.
			draw_line(p + Vector2(s * 0.5, -s * 0.15), p + Vector2(s * 0.42, -s * 0.5), col, maxf(1.0, s * 0.16))
			draw_line(p + Vector2(-s * 0.72, 0.0), p + Vector2(-s * 1.15, -s * 0.45), col, maxf(1.0, s * 0.26))
		Balance.Animal.RABBIT:
			draw_circle(p + Vector2(0, s * 0.12), s * 0.38, col)
			draw_circle(p + Vector2(s * 0.3, -s * 0.15), s * 0.2, col)
			# Ears.
			draw_line(p + Vector2(s * 0.26, -s * 0.28), p + Vector2(s * 0.18, -s * 0.85), col, maxf(1.0, s * 0.15))
			draw_line(p + Vector2(s * 0.38, -s * 0.28), p + Vector2(s * 0.5, -s * 0.8), col, maxf(1.0, s * 0.15))
		Balance.Animal.BIRD:
			draw_line(p + Vector2(-s * 0.8, s * 0.12), p, col, maxf(1.0, s * 0.22))
			draw_line(p, p + Vector2(s * 0.8, s * 0.12), col, maxf(1.0, s * 0.22))


# --- Workers ----------------------------------------------------------------

## Work parties stand where their work is: hunters out among the herds, miners
## at the seams, farmers on the fields. One marker per handful of people, capped,
## so a city of ten thousand costs exactly as much to draw as a camp of twenty.
func _draw_workers(world: CivWorld) -> void:
	if _worker_spots.is_empty():
		_compute_worker_spots(world)

	var budget := MAX_WORKER_MARKS
	for job_id in Balance.JOB_ORDER:
		if budget <= 0:
			break
		var n: int = Sim.jobs.get(job_id, 0)
		if n <= 0:
			continue
		var spots: PackedInt32Array = _worker_spots.get(job_id, PackedInt32Array())
		if spots.is_empty():
			continue
		var job: Dictionary = Balance.JOBS[job_id]
		var marks := clampi(int(ceil(float(n) / 8.0)), 1, 4)
		marks = mini(marks, mini(spots.size(), budget))
		for k in marks:
			var i := spots[k % spots.size()]
			var t := world.tile_pos(i)
			var jitter := _scatter[(i + k * 7) % _scatter.size()] * 0.28
			var p := _tile_to_screen(Vector2(t) + Vector2(0.5, 0.5) + jitter)
			if p.x < -20.0 or p.y < -20.0 or p.x > size.x + 20.0 or p.y > size.y + 20.0:
				continue
			var tex := Art.worker(job_id)
			if tex != null:
				Art.draw_centred(self, tex, p, zoom * 0.9)
			else:
				_draw_worker(p, zoom * 0.40, String(job["glyph"]), job["color"])
			budget -= 1


func _compute_worker_spots(world: CivWorld) -> void:
	var home := PackedInt32Array([world.idx(world.origin.x, world.origin.y)])
	for job_id in Balance.JOB_ORDER:
		var field: String = Balance.JOBS[job_id]["field"]
		match field:
			"game": _worker_spots[job_id] = world.best_tiles(world.game, 5)
			"forage": _worker_spots[job_id] = world.best_tiles(world.forage, 5)
			"forest": _worker_spots[job_id] = world.best_tiles(world.forest, 5)
			"water": _worker_spots[job_id] = world.best_tiles(world.water_access, 5)
			"stone": _worker_spots[job_id] = world.best_tiles(world.stone, 5)
			"ore": _worker_spots[job_id] = world.best_tiles(world.ore, 5)
			"farm": _worker_spots[job_id] = world.best_tiles(world.fertility, 5)
			"frontier": _worker_spots[job_id] = _frontier_spots(world)
			_: _worker_spots[job_id] = home


## Explorers belong at the edge of the known world, not in the village.
func _frontier_spots(world: CivWorld) -> PackedInt32Array:
	var out := PackedInt32Array()
	var step := maxi(1, world.frontier.size() / 5)
	var k := world._frontier_head
	while k < world.frontier.size() and out.size() < 5:
		out.append(world.frontier[k])
		k += step
	if out.is_empty():
		out.append(world.idx(world.origin.x, world.origin.y))
	return out


## A figure plus the tool of its trade. Colour separates them at a distance,
## silhouette separates them up close.
func _draw_worker(p: Vector2, s: float, glyph: String, col: Color) -> void:
	var dark := col.darkened(0.45)
	# Body: everyone has one, so the eye reads "person" before "which person".
	draw_circle(p + Vector2(0, -s * 0.55), s * 0.26, col)
	draw_line(p + Vector2(0, -s * 0.32), p + Vector2(0, s * 0.35), col, maxf(1.0, s * 0.24))

	var tool_w := maxf(1.0, s * 0.20)
	var right := p + Vector2(s * 0.30, -s * 0.10)
	match glyph:
		"bow":
			draw_arc(right, s * 0.45, -1.2, 1.2, 8, dark, tool_w, true)
			draw_line(right + Vector2(-s * 0.05, -s * 0.42), right + Vector2(-s * 0.05, s * 0.42), dark, tool_w * 0.7)
		"basket":
			draw_rect(Rect2(right - Vector2(s * 0.30, 0.0), Vector2(s * 0.6, s * 0.42)), dark, true)
			draw_arc(right, s * 0.30, PI, TAU, 6, dark, tool_w * 0.7)
		"axe":
			draw_line(right + Vector2(0, s * 0.45), right + Vector2(0, -s * 0.5), dark, tool_w)
			draw_colored_polygon(PackedVector2Array([
				right + Vector2(0, -s * 0.5), right + Vector2(s * 0.45, -s * 0.35),
				right + Vector2(0, -s * 0.1),
			]), dark)
		"jug":
			draw_circle(right + Vector2(0, s * 0.05), s * 0.32, dark)
			draw_rect(Rect2(right - Vector2(s * 0.12, s * 0.45), Vector2(s * 0.24, s * 0.25)), dark, true)
		"staff":
			# Explorer: a long walking staff, canted forward.
			draw_line(right + Vector2(-s * 0.15, s * 0.5), right + Vector2(s * 0.25, -s * 0.7), dark, tool_w)
			draw_circle(right + Vector2(s * 0.25, -s * 0.7), s * 0.16, dark)
		"hoe":
			draw_line(right + Vector2(0, s * 0.45), right + Vector2(s * 0.1, -s * 0.5), dark, tool_w)
			draw_line(right + Vector2(s * 0.1, -s * 0.5), right + Vector2(s * 0.5, -s * 0.42), dark, tool_w)
		"chisel":
			draw_rect(Rect2(right - Vector2(s * 0.08, s * 0.5), Vector2(s * 0.16, s * 0.8)), dark, true)
			draw_colored_polygon(PackedVector2Array([
				right + Vector2(-s * 0.08, s * 0.3), right + Vector2(s * 0.08, s * 0.3),
				right + Vector2(0, s * 0.55),
			]), dark)
		"pick":
			draw_line(right + Vector2(0, s * 0.45), right + Vector2(0, -s * 0.45), dark, tool_w)
			draw_arc(right + Vector2(0, -s * 0.45), s * 0.42, PI, TAU, 8, dark, tool_w * 0.8)
		"hammer":
			draw_line(right + Vector2(0, s * 0.45), right + Vector2(0, -s * 0.35), dark, tool_w)
			draw_rect(Rect2(right - Vector2(s * 0.32, s * 0.62), Vector2(s * 0.64, s * 0.30)), dark, true)
		"scroll":
			draw_rect(Rect2(right - Vector2(s * 0.34, s * 0.28), Vector2(s * 0.68, s * 0.56)), dark, true)
			draw_line(right + Vector2(-s * 0.2, -s * 0.08), right + Vector2(s * 0.2, -s * 0.08), col, tool_w * 0.5)
			draw_line(right + Vector2(-s * 0.2, s * 0.10), right + Vector2(s * 0.2, s * 0.10), col, tool_w * 0.5)


# --- Settlement -------------------------------------------------------------

func _draw_settlement(center: Vector2) -> void:
	var s := maxf(zoom, 4.0)

	if Sim.buildings.get("firepit", 0) > 0:
		draw_circle(center, s * 0.40, Color("d96a2b"))
		draw_circle(center, s * 0.20, Color("f2c15a"))
	else:
		draw_circle(center, s * 0.26, Color("3b332a"))

	# One mark per building up to a budget, then the settlement just reads as
	# dense - which is the right visual answer for a city of two hundred huts.
	var slot := 0
	slot = _draw_group(center, s, "windbreak", slot, Color("7d6a4e"), "tent")
	slot = _draw_group(center, s, "scout_camp", slot, Color("cbbf6a"), "tent")
	slot = _draw_group(center, s, "hut", slot, Color("9c7b4f"), "hut")
	slot = _draw_group(center, s, "longhouse", slot, Color("b09068"), "long")
	slot = _draw_group(center, s, "stone_house", slot, Color("a8a49b"), "hut")
	slot = _draw_group(center, s, "great_hall", slot, Color("d8cfa8"), "long")
	slot = _draw_group(center, s, "farm_plot", slot, Color("b8a24a"), "field")
	slot = _draw_group(center, s, "granary", slot, Color("cbb27a"), "hut")
	slot = _draw_group(center, s, "woodshed", slot, Color("7a6242"), "hut")
	slot = _draw_group(center, s, "well", slot, Color("6fa3c4"), "well")
	slot = _draw_group(center, s, "quarry", slot, Color("8e9298"), "field")
	slot = _draw_group(center, s, "mine", slot, Color("6b5a4a"), "mine")
	slot = _draw_group(center, s, "smelter", slot, Color("c2603a"), "hut")
	slot = _draw_group(center, s, "drying_rack", slot, Color("8a7355"), "tent")
	slot = _draw_group(center, s, "shrine", slot, Color("b08ad4"), "shrine")
	_draw_group(center, s, "treasury", slot, Color("e3c14f"), "long")


func _draw_group(center: Vector2, s: float, id: String, slot: int, color: Color, shape: String) -> int:
	var count: int = Sim.buildings.get(id, 0)
	# The settlement footprint widens as it fills, so a big town spreads instead
	# of stacking everything on one spot.
	var spread := s * (2.2 + sqrt(float(slot)) * 0.55)
	for n in count:
		if slot >= _scatter.size():
			break
		var p := center + _scatter[slot] * spread
		slot += 1
		match shape:
			"tent":
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.24, s * 0.20), p + Vector2(s * 0.24, s * 0.20),
					p + Vector2(0, -s * 0.24),
				]), color)
			"hut":
				draw_rect(Rect2(p - Vector2(s * 0.22, s * 0.16), Vector2(s * 0.44, s * 0.36)), color, true)
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.28, -s * 0.14), p + Vector2(s * 0.28, -s * 0.14),
					p + Vector2(0, -s * 0.42),
				]), color.darkened(0.25))
			"long":
				draw_rect(Rect2(p - Vector2(s * 0.48, s * 0.18), Vector2(s * 0.96, s * 0.36)), color, true)
			"field":
				var r := Rect2(p - Vector2(s * 0.36, s * 0.24), Vector2(s * 0.72, s * 0.48))
				draw_rect(r, color, true)
				draw_rect(r, color.darkened(0.4), false, maxf(1.0, s * 0.04))
			"well":
				draw_circle(p, s * 0.20, color)
				draw_circle(p, s * 0.10, Color("24404f"))
			"mine":
				draw_rect(Rect2(p - Vector2(s * 0.22, s * 0.08), Vector2(s * 0.44, s * 0.28)), color, true)
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.22, -s * 0.08), p + Vector2(s * 0.22, -s * 0.08),
					p + Vector2(0, -s * 0.32),
				]), Color("2a2320"))
			"shrine":
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.18, s * 0.24), p + Vector2(s * 0.18, s * 0.24),
					p + Vector2(0, -s * 0.36),
				]), color)
	return slot


# --- Outposts ---------------------------------------------------------------

func _draw_outposts(world: CivWorld) -> void:
	for o in Sim.outposts:
		var t := world.tile_pos(int(o["tile"]))
		var p := _tile_to_screen(Vector2(t) + Vector2(0.5, 0.5))
		if p.x < -20.0 or p.y < -20.0 or p.x > size.x + 20.0 or p.y > size.y + 20.0:
			continue
		var s := maxf(zoom, 6.0)
		var tex := Art.ui("outpost")
		if tex != null:
			Art.draw_centred(self, tex, p, s)
			draw_arc(p, s * 0.8, 0.0, TAU, 20, Color(0.8, 0.7, 0.4, 0.35), 1.5, true)
			continue
		draw_rect(Rect2(p - Vector2(s * 0.3, s * 0.22), Vector2(s * 0.6, s * 0.44)),
				Color("c9b06a"), true)
		draw_colored_polygon(PackedVector2Array([
			p + Vector2(-s * 0.36, -s * 0.2), p + Vector2(s * 0.36, -s * 0.2),
			p + Vector2(0, -s * 0.55),
		]), Color("8a7448"))
		draw_arc(p, s * 0.8, 0.0, TAU, 20, Color(0.8, 0.7, 0.4, 0.35), 1.5, true)


## While placing, shade every tile that would actually take an outpost. The
## decision is about *where*, so the map has to say where is allowed.
func _draw_placement(world: CivWorld) -> void:
	var lo := _screen_to_tile(Vector2.ZERO).floor()
	var hi := _screen_to_tile(size).ceil()
	var shown := 0
	for y in range(maxi(0, int(lo.y)), mini(world.h, int(hi.y) + 1)):
		for x in range(maxi(0, int(lo.x)), mini(world.w, int(hi.x) + 1)):
			if shown > 900:
				return
			var i := world.idx(x, y)
			if world.explored[i] == 0 or not Sim.can_found_outpost(i):
				continue
			shown += 1
			draw_rect(Rect2(_tile_to_screen(Vector2(x, y)), Vector2(zoom, zoom)),
					Color(0.85, 0.75, 0.4, 0.22), true)


# --- Terrain sprites --------------------------------------------------------

func _draw_terrain_sprites(world: CivWorld, x0: int, y0: int, x1: int, y1: int) -> void:
	var drawn := 0
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if drawn >= MAX_TERRAIN_SPRITES:
				return
			var i := world.idx(x, y)
			if world.explored[i] == 0:
				continue
			var tex := Art.terrain(world.biome[i])
			if tex == null:
				continue
			# Unwatched ground is dimmed the same way the colour layer is, so the
			# fog reads identically whether or not there is artwork.
			var tint := Color.WHITE if world.observed[i] != 0 else Color(0.5, 0.55, 0.6, 0.85)
			draw_texture_rect(tex, Rect2(_tile_to_screen(Vector2(x, y)),
					Vector2(zoom, zoom) + Vector2.ONE), false, tint)
			drawn += 1


# --- Boon -------------------------------------------------------------------

## The rare, brief, visible thing. Drawn as a ring that reads as "come here"
## without needing an explanation, and it fades as its time runs out so you can
## see you are about to miss it.
func _draw_boon(world: CivWorld) -> void:
	if Sim.boon_id == "" or Sim.boon_tile < 0:
		return
	var t := world.tile_pos(Sim.boon_tile)
	var centre := _tile_to_screen(Vector2(t) + Vector2(0.5, 0.5))
	if centre.x < -40.0 or centre.y < -40.0 or centre.x > size.x + 40.0 or centre.y > size.y + 40.0:
		return
	var col: Color = Balance.BOONS[Sim.boon_id]["color"]
	var left := clampf((Sim.boon_expires - Sim.day) / Balance.BOON_LIFETIME_DAYS, 0.0, 1.0)
	var r := maxf(12.0, zoom * 0.75)
	var tex := Art.ui("boon_" + Sim.boon_id)
	if tex != null:
		Art.draw_centred(self, tex, centre, r * 1.6)
		draw_arc(centre, r, -PI * 0.5, -PI * 0.5 + TAU * left, 28, col, 3.0, true)
		return
	draw_arc(centre, r, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.35), 3.0, true)
	# The inner arc empties as the moment passes.
	draw_arc(centre, r * 0.62, -PI * 0.5, -PI * 0.5 + TAU * left, 28, col, 3.0, true)
	draw_circle(centre, r * 0.22, col)


# --- Legend -----------------------------------------------------------------

## Only the trades currently being worked, so it stays short and doubles as an
## at-a-glance answer to "who is out there right now".
func _draw_legend() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var fs := 11
	var x := 8.0
	var y := size.y - 8.0
	var shown := 0
	for job_id in Balance.JOB_ORDER:
		if shown >= 5:
			break
		var n: int = Sim.jobs.get(job_id, 0)
		if n <= 0:
			continue
		var job: Dictionary = Balance.JOBS[job_id]
		var ltex := Art.worker(job_id)
		if ltex != null:
			Art.draw_centred(self, ltex, Vector2(x + 7.0, y - 9.0), 16.0)
		else:
			_draw_worker(Vector2(x + 7.0, y - 9.0), 15.0, String(job["glyph"]), job["color"])
		var label := "%s %d" % [job["name"], n]
		draw_string(font, Vector2(x + 17.0, y - 3.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, job["color"])
		x += 17.0 + font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 10.0
		shown += 1
