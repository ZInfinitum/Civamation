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

## --- Hex geometry ------------------------------------------------------------
## Tiles are pointy-top hexagons in "odd-r" offset coordinates: the map data is
## still a rectangular 96x64 array, and odd rows are drawn shifted half a hex to
## the right. Nothing in the simulation had to change to make the map hexagonal;
## it is entirely a question of where each cell is drawn.
##
## One hex is `zoom` pixels wide. A regular pointy-top hex is 2/sqrt(3) times as
## tall as it is wide; the isometric camera then foreshortens the vertical axis
## by ISO_SQUASH, which is what tilts the field away from a flat top-down grid.
const HEX_TALL := 1.1547005  # 2 / sqrt(3)
const ISO_SQUASH := 0.62
## Full corner-to-corner height of one hex, in units of its width.
const HEX_H := HEX_TALL * ISO_SQUASH
## Vertical distance between row centres. Hex rows interlock, so this is 3/4 of
## the height rather than all of it.
const HEX_ROW := HEX_H * 0.75

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
## A tile has to get big enough to hold a visible crowd. At the old ceiling of
## 26 a person was about one pixel and the map could never show the thing the
## people are drawn for; the terrain art is 32px native, so this also lets it
## reach 1:1 and past it.
const MAX_ZOOM := 84.0
## Hard ceiling on overlay primitives per frame, whatever the population.
const MAX_ANIMAL_MARKS := 400
## A figure is four small filled rects. Several hundred of them costs nothing
## next to the terrain pass, and a populated map is the whole point of drawing
## people at all - so this budget is set by what looks right, not by fear.
const MAX_WORKER_MARKS := 420
## Clouds at full overcast. Three circles each, so this is the whole sky budget.
const CLOUD_MAX := 26
## Tiles a cloud crosses per in-game day.
const CLOUD_DRIFT_PER_DAY := 1.4
## How dark the deepest part of the night gets. Not black - you still have to be
## able to read the map at three in the morning.
const NIGHT_MAX_DARKNESS := 0.62

var zoom: float = 13.0
var camera := Vector2.ZERO  ## in tile coordinates

var _img: Image
var _tex: ImageTexture
var _buf := PackedByteArray()
var _terrain_dirty := true
var _dirty := true
var _rebuild_accum := 0.0
var _place_accum := 0.0
var _cloud_accum := 0.0
var _dragging := false
## Set by the Rule tab: the next map click founds an outpost.
var placing_outpost := false
## Same, for a settlement - a second place people actually live.
var placing_settlement := false
## Which question the map is answering. See Balance.MAP_FILTERS.
var filter: int = Balance.MapFilter.TRADES

## Where each job's markers get drawn. Recomputed on a slow timer because it
## sorts, and sorting every frame for cosmetics would be absurd.
var _worker_spots := {}
## Deterministic scatter so buildings and animals do not shimmer between frames.
var _scatter: Array[Vector2] = []

var _last_explored := -1
var _last_territory := -1


## The terrain shader has to apply to the terrain and to nothing else, and a
## CanvasItem's material covers everything it draws - so the map is two layers.
## This one is the hex field, one draw call; the overlay above it is everything
## that stands on the ground and is drawn with ordinary primitives.
class OverlayLayer extends Control:
	var view: WorldView

	func _draw() -> void:
		if view != null:
			view.draw_overlay()


var _terrain_layer: ColorRect
var _overlay: OverlayLayer


func _ready() -> void:
	custom_minimum_size = Vector2(420, 300)
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	_terrain_layer = ColorRect.new()
	_terrain_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_terrain_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/hex_terrain.gdshader")
	_terrain_layer.material = mat
	add_child(_terrain_layer)

	_overlay = OverlayLayer.new()
	_overlay.view = self
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_overlay)

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

	# Clouds move with the in-game day, so they need a redraw cadence of their
	# own - the ordinary dirty flag fires on material changes and once a second,
	# which would make them judder across the sky.
	# Clouds drift and the light changes through the day, both continuously, so
	# they need a redraw cadence of their own - the ordinary dirty flag fires on
	# material changes and once a second, which would make both of them judder.
	if float(Sim.weather_info()["clouds"]) > 0.01 or Sim.sun_elevation() < 0.6:
		_cloud_accum += delta
		if _cloud_accum >= (0.25 if Settings.reduce_motion else 0.066):
			_cloud_accum = 0.0
			_dirty = true

	if _terrain_dirty or _dirty:
		_dirty = false
		_sync_terrain_shader()
		_overlay.queue_redraw()


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
			if mb.pressed and (placing_outpost or placing_settlement):
				var t := _screen_to_tile(mb.position)
				if Sim.world.in_bounds(int(t.x), int(t.y)):
					var i := Sim.world.idx(int(t.x), int(t.y))
					if placing_settlement:
						if Sim.found_settlement(i):
							placing_settlement = false
					elif Sim.found_outpost(i):
						placing_outpost = false
				accept_event()
				return
			_dragging = mb.pressed
			if mb.pressed:
				grab_focus()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_pan((event as InputEventMouseMotion).relative)
		_clamp_camera()
		_dirty = true
		accept_event()


## True when this screen point is on the boon marker.
func _boon_hit(p: Vector2) -> bool:
	var world := Sim.world
	if world == null or Sim.boon_id == "" or Sim.boon_tile < 0:
		return false
	var t := world.tile_pos(Sim.boon_tile)
	var centre := _tile_to_screen(Vector2(t))
	return p.distance_to(centre) <= maxf(14.0, zoom * 0.8)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := _screen_to_tile(screen_pos)
	zoom = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)
	var after := _screen_to_tile(screen_pos)
	camera += before - after
	_clamp_camera()
	_dirty = true


## Drag the map. The screen delta has to be converted back through the hex
## layout - a pixel down is not a row down, it is a row down over ISO_SQUASH.
func _pan(screen_delta: Vector2) -> void:
	camera -= Vector2(screen_delta.x, screen_delta.y / HEX_ROW) / zoom


func _clamp_camera() -> void:
	var world := Sim.world
	if world == null:
		return
	var half := Vector2(size.x, size.y / HEX_ROW) / zoom * 0.5
	camera.x = clampf(camera.x, -half.x * 0.5, float(world.w) + half.x * 0.5)
	camera.y = clampf(camera.y, -half.y * 0.5, float(world.h) + half.y * 0.5)


## Hex-space position of a grid coordinate. Integer (x, y) is the *centre* of
## hex (x, y); fractional parts move around within it. Odd rows step half a hex
## right, which is the whole of the offset layout.
func _hex_space(t: Vector2) -> Vector2:
	var row := int(round(t.y))
	return Vector2(t.x + 0.5 * float(row & 1), t.y * HEX_ROW)


## Hex space -> screen. One hex is `zoom` pixels wide.
func _tile_to_screen(t: Vector2) -> Vector2:
	return (_hex_space(t) - _hex_space(camera)) * zoom + size * 0.5


## Screen -> the hex under it. Un-squash, convert to axial, round in cube space
## - the same arithmetic the terrain shader does, so what you click is exactly
## what you see.
func _screen_to_tile(p: Vector2) -> Vector2:
	var d := (p - size * 0.5) / zoom + _hex_space(camera)
	d.y /= ISO_SQUASH
	var s := 1.0 / sqrt(3.0)
	var q := (sqrt(3.0) / 3.0 * d.x - d.y / 3.0) / s
	var r := (2.0 / 3.0 * d.y) / s
	var c := _cube_round(Vector3(q, -q - r, r))
	var row := c.z
	return Vector2(c.x + floorf((row - fposmod(row, 2.0)) * 0.5), row)


## The bounding box of one hex, for tile fills and terrain sprites. A hex is as
## wide as the zoom and HEX_H times that tall, centred on the hex.
func _hex_rect(x: int, y: int) -> Rect2:
	var box := Vector2(zoom, zoom * HEX_H)
	return Rect2(_tile_to_screen(Vector2(x, y)) - box * 0.5, box)


## The territory boundary. A circle in tile space, which the hex row spacing and
## the isometric squash together turn into an ellipse - so it is walked as
## points rather than handed to draw_arc, which only knows about circles.
func _draw_territory_ring(home: Vector2, radius: float) -> void:
	var pts := PackedVector2Array()
	for i in 65:
		var a := TAU * float(i) / 64.0
		pts.append(home + Vector2(cos(a) * radius * zoom,
				sin(a) * radius * zoom * HEX_ROW))
	_overlay.draw_polyline(pts, TERRITORY_LINE, maxf(1.0, zoom * 0.05), true)


func _cube_round(c: Vector3) -> Vector3:
	var r := c.round()
	var d := (r - c).abs()
	if d.x > d.y and d.x > d.z:
		r.x = -r.y - r.z
	elif d.y > d.z:
		r.y = -r.x - r.z
	else:
		r.z = -r.x - r.y
	return r


## Frame the whole world.
func view_world() -> void:
	var world := Sim.world
	if world == null:
		return
	# The hex field is (w + 0.5) hexes wide and h * HEX_ROW tall in hex space.
	zoom = clampf(minf(size.x / (float(world.w) + 0.5),
			size.y / (float(world.h) * HEX_ROW)), MIN_ZOOM, MAX_ZOOM)
	camera = Vector2(world.w, world.h) * 0.5
	_dirty = true


## Frame the settlement.
func view_home() -> void:
	var world := Sim.world
	if world == null:
		return
	zoom = 30.0
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
			c = _filter_tint(world, i, c)
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


## Recolour a tile according to whatever question the map is currently being
## asked. Terrain colour is the default answer; the others overwrite it.
func _filter_tint(world: CivWorld, i: int, base: Color) -> Color:
	match filter:
		Balance.MapFilter.LAND:
			# How worn the ground is: green where it is whole, bare where it is not.
			var wear := 1.0
			var parts := 0
			for pair in [[world.game, world.game_cap], [world.forage, world.forage_cap],
					[world.forest, world.forest_cap]]:
				var cap: float = (pair[1] as PackedFloat32Array)[i]
				if cap > 0.5:
					wear = minf(wear, (pair[0] as PackedFloat32Array)[i] / cap)
					parts += 1
			if parts == 0:
				return base.lerp(Color("2b2f33"), 0.6)
			return Color("6b4a2a").lerp(Color("5fbf5a"), clampf(wear, 0.0, 1.0))
		Balance.MapFilter.RESOURCES:
			# Only what is worth having; everything else out of the way.
			if world.gold[i] > 0.10:
				return Color("e3c14f")
			if world.ore[i] > 0.25:
				return Color("c0724a")
			if world.stone[i] > 0.8:
				return Color("9aa0a6")
			if world.fertility[i] > 0.9:
				return Color("94b85e")
			if world.water_access[i] > 0.7:
				return Color("4fa3d1")
			return base.lerp(Color("1a1d21"), 0.72)
		Balance.MapFilter.TERRITORY:
			return base
	return base


# --- Drawing ----------------------------------------------------------------

## Push the camera into the terrain shader. The hex field is drawn entirely from
## these two vectors, so panning and zooming cost nothing but this.
func _sync_terrain_shader() -> void:
	var world := Sim.world
	if world == null or _terrain_layer == null:
		return
	var mat: ShaderMaterial = _terrain_layer.material
	if mat == null:
		return
	if _terrain_dirty or _tex == null:
		_rebuild_terrain()
	var origin := _hex_space(camera) - size * 0.5 / zoom
	mat.set_shader_parameter("grid", _tex)
	mat.set_shader_parameter("grid_dims", Vector2(world.w, world.h))
	mat.set_shader_parameter("origin_hex", origin)
	mat.set_shader_parameter("span_hex", size / zoom)
	mat.set_shader_parameter("iso_squash", ISO_SQUASH)


func draw_overlay() -> void:
	var world := Sim.world
	if world == null:
		return

	# Which tiles are actually on screen. Everything below iterates this, not
	# the map, so cost is bounded by the window rather than the world. The four
	# screen corners bound the visible hexes; on a hex grid the box is a little
	# generous, which is fine and much cheaper than being exact.
	var c0 := _screen_to_tile(Vector2.ZERO)
	var c1 := _screen_to_tile(Vector2(size.x, 0.0))
	var c2 := _screen_to_tile(Vector2(0.0, size.y))
	var c3 := _screen_to_tile(size)
	var x0 := maxi(0, int(minf(minf(c0.x, c1.x), minf(c2.x, c3.x))) - 1)
	var y0 := maxi(0, int(minf(minf(c0.y, c1.y), minf(c2.y, c3.y))) - 1)
	var x1 := mini(world.w - 1, int(maxf(maxf(c0.x, c1.x), maxf(c2.x, c3.x))) + 1)
	var y1 := mini(world.h - 1, int(maxf(maxf(c0.y, c1.y), maxf(c2.y, c3.y))) + 1)

	# Terrain sprites, if any have been dropped in. The colour texture underneath
	# stays - it carries the fog states - and these go on top, only for tiles
	# actually on screen and only when they would be big enough to see.
	if zoom >= TERRAIN_SPRITE_ZOOM and Art.has_any("terrain"):
		_draw_terrain_sprites(world, x0, y0, x1, y1)

	if zoom >= ANIMAL_ZOOM:
		_draw_wildlife(world, x0, y0, x1, y1)
	if zoom >= DETAIL_ZOOM:
		_draw_seams(world, x0, y0, x1, y1)

	if filter == Balance.MapFilter.TERRITORY:
		_draw_territory_overlay(world, x0, y0, x1, y1)

	# Territory: one ring per claim, because territory is a union of circles now
	# rather than a single one around the capital.
	var home := _tile_to_screen(Vector2(world.origin))
	_draw_territory_ring(home, world.territory_radius)
	for s in Sim.settlements:
		_draw_territory_ring(_tile_to_screen(Vector2(world.tile_pos(int(s["tile"])))),
				Sim.settlement_radius())

	_draw_roads(world)
	_draw_settlement(home)
	if zoom >= DETAIL_ZOOM:
		_draw_workers(world)
	_draw_outposts(world)
	if placing_outpost or placing_settlement:
		_draw_placement(world)
	_draw_boon(world)
	_draw_clouds()
	_draw_night(world)
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
		# How many are actually here. A herd is a quantity, and this is the only
		# place in the game that quantity is visible - so draw it, at the stated
		# scale, the same way the population is drawn.
		var head: float = world.game[i] * Balance.ANIMALS_PER_GAME_UNIT * float(info["weight"])
		var icons := clampi(int(round(head / Balance.ANIMALS_PER_ICON)), 1,
				mini(Balance.MAX_ANIMAL_ICONS_PER_TILE, MAX_ANIMAL_MARKS - drawn))
		for k in icons:
			var jitter := _scatter[(i * 11 + a * 5 + k * 23) % _scatter.size()] * 0.40
			var p := _tile_to_screen(Vector2(t) + jitter)
			_draw_fauna(p, zoom * 0.26, kind, info["color"])
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
			var p := _tile_to_screen(Vector2(x, y))
			if world.ore[i] > 0.35:
				var s := zoom * 0.13
				_overlay.draw_rect(Rect2(p - Vector2(s, s) - Vector2(zoom * 0.22, 0), Vector2(s, s) * 2.0), ore_col, true)
			if world.gold[i] > 0.16:
				_overlay.draw_circle(p + Vector2(zoom * 0.22, -zoom * 0.18), zoom * 0.10, Color("e3c14f"))


# --- Animal silhouettes -----------------------------------------------------
## Four creatures, four unmistakable outlines: deer carry antlers, wolves are
## long and low with a raised tail, rabbits are a ball with ears, birds are a
## wing stroke. Readable at ten pixels, which is the whole requirement.

func _draw_fauna(p: Vector2, s: float, kind: int, col: Color) -> void:
	match kind:
		Balance.Animal.DEER:
			_overlay.draw_colored_polygon(PackedVector2Array([
				p + Vector2(-s * 0.7, -s * 0.05), p + Vector2(s * 0.45, -s * 0.2),
				p + Vector2(s * 0.45, s * 0.4), p + Vector2(-s * 0.65, s * 0.4),
			]), col)
			var head := p + Vector2(s * 0.6, -s * 0.4)
			_overlay.draw_line(p + Vector2(s * 0.45, -s * 0.15), head, col, maxf(1.0, s * 0.22))
			# Antlers - the tell.
			_overlay.draw_line(head, head + Vector2(-s * 0.3, -s * 0.6), col, maxf(1.0, s * 0.15))
			_overlay.draw_line(head, head + Vector2(s * 0.35, -s * 0.55), col, maxf(1.0, s * 0.15))
		Balance.Animal.WOLF:
			# Long, low, level back; brush tail up; muzzle out front.
			_overlay.draw_colored_polygon(PackedVector2Array([
				p + Vector2(-s * 0.75, -s * 0.05), p + Vector2(s * 0.5, -s * 0.1),
				p + Vector2(s * 0.5, s * 0.3), p + Vector2(-s * 0.7, s * 0.32),
			]), col)
			_overlay.draw_colored_polygon(PackedVector2Array([
				p + Vector2(s * 0.45, -s * 0.2), p + Vector2(s * 1.0, s * 0.05),
				p + Vector2(s * 0.45, s * 0.18),
			]), col)
			# Ears and tail.
			_overlay.draw_line(p + Vector2(s * 0.5, -s * 0.15), p + Vector2(s * 0.42, -s * 0.5), col, maxf(1.0, s * 0.16))
			_overlay.draw_line(p + Vector2(-s * 0.72, 0.0), p + Vector2(-s * 1.15, -s * 0.45), col, maxf(1.0, s * 0.26))
		Balance.Animal.RABBIT:
			_overlay.draw_circle(p + Vector2(0, s * 0.12), s * 0.38, col)
			_overlay.draw_circle(p + Vector2(s * 0.3, -s * 0.15), s * 0.2, col)
			# Ears.
			_overlay.draw_line(p + Vector2(s * 0.26, -s * 0.28), p + Vector2(s * 0.18, -s * 0.85), col, maxf(1.0, s * 0.15))
			_overlay.draw_line(p + Vector2(s * 0.38, -s * 0.28), p + Vector2(s * 0.5, -s * 0.8), col, maxf(1.0, s * 0.15))
		Balance.Animal.BIRD:
			_overlay.draw_line(p + Vector2(-s * 0.8, s * 0.12), p, col, maxf(1.0, s * 0.22))
			_overlay.draw_line(p, p + Vector2(s * 0.8, s * 0.12), col, maxf(1.0, s * 0.22))


# --- Workers ----------------------------------------------------------------

## Work parties stand where their work is: hunters out among the herds, miners
## at the seams, farmers on the fields. One marker per handful of people, capped,
## so a city of ten thousand costs exactly as much to draw as a camp of twenty.
func _draw_workers(world: CivWorld) -> void:
	if _worker_spots.is_empty():
		_compute_worker_spots(world)

	# One figure per N people, where N steps up as the settlement grows, so a
	# city of forty thousand costs exactly as much to draw as a camp of twenty
	# and still *looks* like forty thousand.
	var per := _people_per_figure()
	var budget := MAX_WORKER_MARKS
	var crowd_mode := filter == Balance.MapFilter.PEOPLE
	var workforce := maxi(1, Sim.workforce())

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
		var col: Color = Balance.CROWD_COLOR if crowd_mode else job["color"]
		# Figures for this trade, in proportion to its share of the workforce.
		# A flat per-trade cap of fourteen used to be the real limit, so a town of
		# two thousand and a city of forty thousand drew the same thin scattering
		# and the map never looked populated. A figure is four small rects; a few
		# hundred of them is nothing, and it is the difference between a map with
		# people on it and a map with markers on it.
		var share := float(n) / float(workforce)
		var figures := clampi(int(ceil(float(n) / per)), 1,
				maxi(1, mini(int(ceil(float(MAX_WORKER_MARKS) * share)), budget)))
		for k in figures:
			var i := spots[(k * 3) % spots.size()]
			var t := world.tile_pos(i)
			# Scatter across the whole tile, not a huddle in the middle of it -
			# the point is that one tile visibly holds a crowd.
			var jitter := _scatter[(i * 7 + k * 13) % _scatter.size()] * 0.46
			var p := _tile_to_screen(Vector2(t) + jitter)
			if p.x < -20.0 or p.y < -20.0 or p.x > size.x + 20.0 or p.y > size.y + 20.0:
				continue
			var tex := Art.worker(job_id)
			if tex != null and not crowd_mode:
				Art.draw_centred(_overlay, tex, p, zoom * 0.30)
			else:
				_draw_person(p, zoom, col)
			budget -= 1


## People are five pixels, and every one of them means something: head, body,
## and the colour of the trade. Legible at a glance, cheap to draw, and it
## scales down to a dot without becoming mush.
func _draw_person(p: Vector2, tile: float, col: Color) -> void:
	# A person is about five pixels tall at a comfortable zoom. Bigger than that
	# and a crowd reads as a row of icons rather than as a crowd.
	var px := maxf(1.0, tile * 0.05)
	# head
	_overlay.draw_rect(Rect2(p.x - px * 0.5, p.y - px * 2.5, px, px), col.lightened(0.25), true)
	# body, two pixels tall
	_overlay.draw_rect(Rect2(p.x - px * 0.5, p.y - px * 1.5, px, px * 2.0), col, true)
	# legs, split
	_overlay.draw_rect(Rect2(p.x - px, p.y + px * 0.5, px * 0.8, px), col.darkened(0.25), true)
	_overlay.draw_rect(Rect2(p.x + px * 0.2, p.y + px * 0.5, px * 0.8, px), col.darkened(0.25), true)


## Each figure stands for this many people. Steps rather than a smooth ratio, so
## the crowd does not shimmer as the population creeps.
func _people_per_figure() -> float:
	var pop := Sim.population
	var steps: Array = Balance.PEOPLE_PER_FIGURE_STEPS
	for i in range(steps.size() - 1, -1, -1):
		# One figure per person holds until there are genuinely too many to draw.
		# At a ratio of thirty this stepped up almost immediately and the map went
		# sparse just as the settlement got interesting.
		if pop >= float(steps[i]) * 240.0:
			return float(steps[i])
	return 1.0


func _compute_worker_spots(world: CivWorld) -> void:
	var home := _home_spots(world)
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
		# Every trade also shows some of its people at home. Work sites are the
		# best few tiles for that resource and they can be right across the map,
		# so zooming in on the settlement - the one place a player actually looks
		# - used to show an empty village with all its people out of frame.
		var spots: PackedInt32Array = _worker_spots[job_id]
		if String(Balance.JOBS[job_id]["field"]) != "frontier":
			spots.append_array(home)
			_worker_spots[job_id] = spots


## The settlement tile and the ring around it - where people are when they are
## not at a work face.
func _home_spots(world: CivWorld) -> PackedInt32Array:
	var out := PackedInt32Array()
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := world.origin.x + dx
			var y := world.origin.y + dy
			if world.in_bounds(x, y):
				out.append(world.idx(x, y))
	return out


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
	_overlay.draw_circle(p + Vector2(0, -s * 0.55), s * 0.26, col)
	_overlay.draw_line(p + Vector2(0, -s * 0.32), p + Vector2(0, s * 0.35), col, maxf(1.0, s * 0.24))

	var tool_w := maxf(1.0, s * 0.20)
	var right := p + Vector2(s * 0.30, -s * 0.10)
	match glyph:
		"bow":
			_overlay.draw_arc(right, s * 0.45, -1.2, 1.2, 8, dark, tool_w, true)
			_overlay.draw_line(right + Vector2(-s * 0.05, -s * 0.42), right + Vector2(-s * 0.05, s * 0.42), dark, tool_w * 0.7)
		"basket":
			_overlay.draw_rect(Rect2(right - Vector2(s * 0.30, 0.0), Vector2(s * 0.6, s * 0.42)), dark, true)
			_overlay.draw_arc(right, s * 0.30, PI, TAU, 6, dark, tool_w * 0.7)
		"axe":
			_overlay.draw_line(right + Vector2(0, s * 0.45), right + Vector2(0, -s * 0.5), dark, tool_w)
			_overlay.draw_colored_polygon(PackedVector2Array([
				right + Vector2(0, -s * 0.5), right + Vector2(s * 0.45, -s * 0.35),
				right + Vector2(0, -s * 0.1),
			]), dark)
		"jug":
			_overlay.draw_circle(right + Vector2(0, s * 0.05), s * 0.32, dark)
			_overlay.draw_rect(Rect2(right - Vector2(s * 0.12, s * 0.45), Vector2(s * 0.24, s * 0.25)), dark, true)
		"staff":
			# Explorer: a long walking staff, canted forward.
			_overlay.draw_line(right + Vector2(-s * 0.15, s * 0.5), right + Vector2(s * 0.25, -s * 0.7), dark, tool_w)
			_overlay.draw_circle(right + Vector2(s * 0.25, -s * 0.7), s * 0.16, dark)
		"hoe":
			_overlay.draw_line(right + Vector2(0, s * 0.45), right + Vector2(s * 0.1, -s * 0.5), dark, tool_w)
			_overlay.draw_line(right + Vector2(s * 0.1, -s * 0.5), right + Vector2(s * 0.5, -s * 0.42), dark, tool_w)
		"chisel":
			_overlay.draw_rect(Rect2(right - Vector2(s * 0.08, s * 0.5), Vector2(s * 0.16, s * 0.8)), dark, true)
			_overlay.draw_colored_polygon(PackedVector2Array([
				right + Vector2(-s * 0.08, s * 0.3), right + Vector2(s * 0.08, s * 0.3),
				right + Vector2(0, s * 0.55),
			]), dark)
		"pick":
			_overlay.draw_line(right + Vector2(0, s * 0.45), right + Vector2(0, -s * 0.45), dark, tool_w)
			_overlay.draw_arc(right + Vector2(0, -s * 0.45), s * 0.42, PI, TAU, 8, dark, tool_w * 0.8)
		"hammer":
			_overlay.draw_line(right + Vector2(0, s * 0.45), right + Vector2(0, -s * 0.35), dark, tool_w)
			_overlay.draw_rect(Rect2(right - Vector2(s * 0.32, s * 0.62), Vector2(s * 0.64, s * 0.30)), dark, true)
		"scroll":
			_overlay.draw_rect(Rect2(right - Vector2(s * 0.34, s * 0.28), Vector2(s * 0.68, s * 0.56)), dark, true)
			_overlay.draw_line(right + Vector2(-s * 0.2, -s * 0.08), right + Vector2(s * 0.2, -s * 0.08), col, tool_w * 0.5)
			_overlay.draw_line(right + Vector2(-s * 0.2, s * 0.10), right + Vector2(s * 0.2, s * 0.10), col, tool_w * 0.5)


# --- Settlement -------------------------------------------------------------

func _draw_settlement(center: Vector2) -> void:
	# Buildings used to scale straight off zoom, so at the close zooms that make
	# a crowd visible a single hut filled most of a tile and the map turned into
	# furniture. A building is a thing standing *on* ground, not the ground - so
	# it grows with zoom only up to the point where it reads, then stops.
	var s := clampf(zoom, 4.0, 26.0)

	if Sim.buildings.get("firepit", 0) > 0:
		_overlay.draw_circle(center, s * 0.40, Color("d96a2b"))
		_overlay.draw_circle(center, s * 0.20, Color("f2c15a"))
	else:
		_overlay.draw_circle(center, s * 0.26, Color("3b332a"))

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
				_overlay.draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.24, s * 0.20), p + Vector2(s * 0.24, s * 0.20),
					p + Vector2(0, -s * 0.24),
				]), color)
			"hut":
				_overlay.draw_rect(Rect2(p - Vector2(s * 0.22, s * 0.16), Vector2(s * 0.44, s * 0.36)), color, true)
				_overlay.draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.28, -s * 0.14), p + Vector2(s * 0.28, -s * 0.14),
					p + Vector2(0, -s * 0.42),
				]), color.darkened(0.25))
			"long":
				_overlay.draw_rect(Rect2(p - Vector2(s * 0.48, s * 0.18), Vector2(s * 0.96, s * 0.36)), color, true)
			"field":
				var r := Rect2(p - Vector2(s * 0.36, s * 0.24), Vector2(s * 0.72, s * 0.48))
				_overlay.draw_rect(r, color, true)
				_overlay.draw_rect(r, color.darkened(0.4), false, maxf(1.0, s * 0.04))
			"well":
				_overlay.draw_circle(p, s * 0.20, color)
				_overlay.draw_circle(p, s * 0.10, Color("24404f"))
			"mine":
				_overlay.draw_rect(Rect2(p - Vector2(s * 0.22, s * 0.08), Vector2(s * 0.44, s * 0.28)), color, true)
				_overlay.draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.22, -s * 0.08), p + Vector2(s * 0.22, -s * 0.08),
					p + Vector2(0, -s * 0.32),
				]), Color("2a2320"))
			"shrine":
				_overlay.draw_colored_polygon(PackedVector2Array([
					p + Vector2(-s * 0.18, s * 0.24), p + Vector2(s * 0.18, s * 0.24),
					p + Vector2(0, -s * 0.36),
				]), color)
	return slot


## Worked, walked, or unseen - the three states of ground, said plainly.
func _draw_territory_overlay(world: CivWorld, x0: int, y0: int, x1: int, y1: int) -> void:
	var worked := {}
	for i in world.territory:
		worked[i] = true
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i := world.idx(x, y)
			var col := Color(0, 0, 0, 0)
			if worked.has(i):
				col = Color(0.85, 0.72, 0.35, 0.22)
			elif world.explored[i] != 0:
				col = Color(0.4, 0.55, 0.7, 0.12)
			if col.a > 0.0:
				_overlay.draw_rect(_hex_rect(x, y),
						col, true)


# --- Outposts ---------------------------------------------------------------

func _draw_outposts(world: CivWorld) -> void:
	for o in Sim.outposts:
		var t := world.tile_pos(int(o["tile"]))
		var p := _tile_to_screen(Vector2(t))
		if p.x < -20.0 or p.y < -20.0 or p.x > size.x + 20.0 or p.y > size.y + 20.0:
			continue
		var s := maxf(zoom, 6.0)
		var tex := Art.ui("outpost")
		if tex != null:
			Art.draw_centred(_overlay, tex, p, s)
			_overlay.draw_arc(p, s * 0.8, 0.0, TAU, 20, Color(0.8, 0.7, 0.4, 0.35), 1.5, true)
			continue
		_overlay.draw_rect(Rect2(p - Vector2(s * 0.3, s * 0.22), Vector2(s * 0.6, s * 0.44)),
				Color("c9b06a"), true)
		_overlay.draw_colored_polygon(PackedVector2Array([
			p + Vector2(-s * 0.36, -s * 0.2), p + Vector2(s * 0.36, -s * 0.2),
			p + Vector2(0, -s * 0.55),
		]), Color("8a7448"))
		_overlay.draw_arc(p, s * 0.8, 0.0, TAU, 20, Color(0.8, 0.7, 0.4, 0.35), 1.5, true)

	# Settlements: bigger, cooler in colour, and with their own claimed ring, so
	# a glance at the map tells you which of the two you are looking at.
	for sv in Sim.settlements:
		var t := world.tile_pos(int(sv["tile"]))
		var p := _tile_to_screen(Vector2(t))
		if p.x < -40.0 or p.y < -40.0 or p.x > size.x + 40.0 or p.y > size.y + 40.0:
			continue
		var s := maxf(zoom, 8.0) * 1.35
		var tex := Art.ui("settlement")
		if tex != null:
			Art.draw_centred(_overlay, tex, p, s)
			continue
		# Three roofs on a base, which reads as a town rather than as a hut.
		_overlay.draw_rect(Rect2(p - Vector2(s * 0.42, s * 0.06), Vector2(s * 0.84, s * 0.30)),
				Color("9fb4c9"), true)
		for dx in [-0.28, 0.0, 0.28]:
			var c := p + Vector2(s * dx, 0.0)
			_overlay.draw_colored_polygon(PackedVector2Array([
				c + Vector2(-s * 0.17, -s * 0.06), c + Vector2(s * 0.17, -s * 0.06),
				c + Vector2(0.0, -s * 0.36),
			]), Color("d6e3ee"))


## While placing, shade every tile that would actually take an outpost. The
## decision is about *where*, so the map has to say where is allowed.
func _draw_placement(world: CivWorld) -> void:
	var c0 := _screen_to_tile(Vector2.ZERO)
	var c3 := _screen_to_tile(size)
	var tint := Color(0.55, 0.85, 0.95, 0.26) if placing_settlement \
			else Color(0.85, 0.75, 0.4, 0.22)
	var shown := 0
	for y in range(maxi(0, int(minf(c0.y, c3.y)) - 1), mini(world.h, int(maxf(c0.y, c3.y)) + 2)):
		for x in range(maxi(0, int(minf(c0.x, c3.x)) - 2), mini(world.w, int(maxf(c0.x, c3.x)) + 2)):
			if shown > 900:
				return
			var i := world.idx(x, y)
			if world.explored[i] == 0:
				continue
			if placing_settlement:
				if not Sim.can_found_settlement(i):
					continue
			elif not Sim.can_found_outpost(i):
				continue
			shown += 1
			_overlay.draw_rect(_hex_rect(x, y), tint, true)


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
			_overlay.draw_texture_rect(tex, _hex_rect(x, y).grow(1.0), false, tint)
			drawn += 1


# --- Boon -------------------------------------------------------------------

## The rare, brief, visible thing. Drawn as a ring that reads as "come here"
## without needing an explanation, and it fades as its time runs out so you can
## see you are about to miss it.
func _draw_boon(world: CivWorld) -> void:
	if Sim.boon_id == "" or Sim.boon_tile < 0:
		return
	var t := world.tile_pos(Sim.boon_tile)
	var centre := _tile_to_screen(Vector2(t))
	if centre.x < -40.0 or centre.y < -40.0 or centre.x > size.x + 40.0 or centre.y > size.y + 40.0:
		return
	var col: Color = Balance.BOONS[Sim.boon_id]["color"]
	var left := clampf((Sim.boon_expires - Sim.day) / Balance.BOON_LIFETIME_DAYS, 0.0, 1.0)
	var r := maxf(12.0, zoom * 0.75)
	var tex := Art.ui("boon_" + Sim.boon_id)
	if tex != null:
		Art.draw_centred(_overlay, tex, centre, r * 1.6)
		_overlay.draw_arc(centre, r, -PI * 0.5, -PI * 0.5 + TAU * left, 28, col, 3.0, true)
		return
	_overlay.draw_arc(centre, r, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.35), 3.0, true)
	# The inner arc empties as the moment passes.
	_overlay.draw_arc(centre, r * 0.62, -PI * 0.5, -PI * 0.5 + TAU * left, 28, col, 3.0, true)
	_overlay.draw_circle(centre, r * 0.22, col)


## Night, and the lights people keep against it.
##
## Drawn last, over everything, because night falls on the whole country at
## once. The darkness is one rect keyed to how high the sun is - dusk and dawn
## come on gradually, which is most of what sells it - and then every place
## people live burns a fire in it.
##
## The bloom is three concentric circles at low alpha rather than a real shader
## pass: additive blending on a handful of circles reads as glow at a fraction
## of the cost, and it is the same trick whether it is a campfire now or a
## street lamp once there is electricity to run one.
func _draw_night(world: CivWorld) -> void:
	var sun := Sim.sun_elevation()
	if sun >= 0.55:
		return
	# Deepest an hour after dusk, easing off through twilight.
	var dark := clampf(1.0 - sun / 0.55, 0.0, 1.0)
	var night := dark * dark * NIGHT_MAX_DARKNESS
	_overlay.draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.06, 0.13, night))
	if night < 0.06:
		return

	# Firelight. Brighter the darker it is, so the village emerges as dusk
	# deepens rather than snapping on.
	var glow := dark
	var lit: Array[Vector2] = [_tile_to_screen(Vector2(world.origin))]
	for s in Sim.settlements:
		lit.append(_tile_to_screen(Vector2(world.tile_pos(int(s["tile"])))))
	for o in Sim.outposts:
		lit.append(_tile_to_screen(Vector2(world.tile_pos(int(o["tile"])))))

	# A settlement with a fire pit burns a bigger one, and a bigger place burns
	# more of them - so the map at night is a readable picture of where people
	# actually are.
	var base := maxf(zoom * 1.6, 22.0)
	if Sim.buildings.get("firepit", 0) > 0:
		base *= 1.25
	var warm := Color(1.0, 0.62, 0.24)
	for i in lit.size():
		var p: Vector2 = lit[i]
		if p.x < -base * 3.0 or p.x > size.x + base * 3.0:
			continue
		if p.y < -base * 3.0 or p.y > size.y + base * 3.0:
			continue
		# The capital is the big fire; the others are smaller.
		var r := base if i == 0 else base * 0.62
		for ring in 3:
			var t := float(ring + 1) / 3.0
			_overlay.draw_circle(p, r * t * 1.5,
					Color(warm.r, warm.g, warm.b, glow * 0.16 * (1.0 - t) + 0.02))
		_overlay.draw_circle(p, maxf(2.0, r * 0.16),
				Color(1.0, 0.86, 0.55, minf(0.95, 0.35 + glow * 0.6)))


## Roads between places whose claimed ground touches. Nobody places these - they
## are what two towns within reach of each other do - so the map showing them is
## the only feedback that siting a settlement close to another was worth it.
func _draw_roads(world: CivWorld) -> void:
	var links := Sim.road_links()
	if links.is_empty():
		return
	var info := Sim.road_info()
	var col: Color = info["color"]
	var wide := maxf(1.5, zoom * float(info["width"]))

	for l in links:
		var a := _road_point(world, int(l[0]))
		var b := _road_point(world, int(l[1]))
		# A darker casing under the road, so it reads over any terrain.
		_overlay.draw_line(a, b, Color(0.12, 0.10, 0.08, 0.55), wide * 1.8, true)
		_overlay.draw_line(a, b, Color(col.r, col.g, col.b, 0.9), wide, true)


func _road_point(world: CivWorld, which: int) -> Vector2:
	if which < 0:
		return _tile_to_screen(Vector2(world.origin))
	return _tile_to_screen(Vector2(world.tile_pos(int(Sim.settlements[which]["tile"]))))


# --- Weather ----------------------------------------------------------------

## Cloud shadows crossing the map.
##
## Cheap on purpose: a fixed set of blobs whose positions are a pure function of
## the in-game day, so they cost no state, never desynchronise from the
## simulation, and are identical on a reload. They drift in *world* space rather
## than screen space, which is what stops them sliding around when you pan.
##
## How many appear is the current weather. Clear skies get one or two passing
## over; a storm covers the map. That means the sky is readable from the map
## itself without looking at a label, which is the point of having weather at
## all in a game you are half-watching.
func _draw_clouds() -> void:
	if Settings.reduce_motion:
		return
	var info := Sim.weather_info()
	var cover := float(info["clouds"])
	if cover <= 0.01:
		return
	var count := int(round(cover * float(CLOUD_MAX)))
	if count <= 0:
		return

	var col: Color = info["color"]
	# Heavier weather means darker, more opaque shadow.
	var alpha := 0.05 + cover * 0.16
	# Drift: slow, and westward, at a speed that reads at any zoom.
	var drift := Sim.day * CLOUD_DRIFT_PER_DAY

	for k in count:
		var seed_pt := _scatter[(k * 37) % _scatter.size()]
		# Wrap across a band wider than the world so clouds enter and leave.
		var span := float(Sim.world.w) + 24.0
		var wx := fposmod(seed_pt.x * span + drift * (0.6 + 0.5 * absf(seed_pt.y)), span) - 12.0
		var wy := (seed_pt.y * 0.5 + 0.5) * float(Sim.world.h)
		var p := _tile_to_screen(Vector2(wx, wy))
		var r := zoom * (2.2 + 2.6 * absf(seed_pt.x))
		if p.x < -r * 3.0 or p.x > size.x + r * 3.0:
			continue
		if p.y < -r * 3.0 or p.y > size.y + r * 3.0:
			continue
		# Three overlapping ellipses read as a cloud and cost three calls.
		for lobe in 3:
			var o := _scatter[(k * 11 + lobe * 53) % _scatter.size()]
			var c := p + Vector2(o.x * r * 1.1, o.y * r * 0.30)
			_overlay.draw_circle(c, r * (0.62 + 0.24 * absf(o.y)),
					Color(col.r, col.g, col.b, alpha))


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
	var per := _people_per_figure()
	# Backing strip. Terrain sprites brought the map up to full brightness and
	# the legend became unreadable over grassland and sand - white-ish text on a
	# pale tile. One flat rect is cheaper than outlining every glyph.
	var strip := 40.0
	_overlay.draw_rect(Rect2(0.0, size.y - strip, size.x, strip), Color(0.05, 0.06, 0.07, 0.72), true)
	var scale_note := ""
	if per > 1.0:
		scale_note = "one figure = %s people" % Balance.fmt_count(per)
	if zoom >= ANIMAL_ZOOM:
		if scale_note != "":
			scale_note += "   -   "
		scale_note += "one animal = %s head" % Balance.fmt_count(Balance.ANIMALS_PER_ICON)
	if scale_note != "":
		_overlay.draw_string(font, Vector2(x, y - 20.0), scale_note,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.72, 0.74, 0.72))
	# The legend has to answer the question the current filter is asking. Listing
	# five trades under a map that has deliberately stopped distinguishing trades
	# is worse than listing nothing.
	if filter == Balance.MapFilter.PEOPLE:
		_draw_person(Vector2(x + 7.0, y - 6.0), 60.0, Balance.CROWD_COLOR)
		_overlay.draw_string(font, Vector2(x + 17.0, y - 3.0),
				"%s people" % Balance.fmt_count(Sim.population),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Balance.CROWD_COLOR)
		return
	if filter != Balance.MapFilter.TRADES:
		var info: Dictionary = Balance.MAP_FILTERS[filter]
		_overlay.draw_string(font, Vector2(x, y - 3.0), String(info["desc"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.78, 0.80, 0.78))
		return

	for job_id in Balance.JOB_ORDER:
		if shown >= 5:
			break
		var n: int = Sim.jobs.get(job_id, 0)
		if n <= 0:
			continue
		var job: Dictionary = Balance.JOBS[job_id]
		var ltex := Art.worker(job_id)
		if ltex != null:
			Art.draw_centred(_overlay, ltex, Vector2(x + 7.0, y - 9.0), 16.0)
		else:
			_draw_worker(Vector2(x + 7.0, y - 9.0), 15.0, String(job["glyph"]), job["color"])
		var label := "%s %s" % [job["name"], Balance.fmt_count(float(n))]
		_overlay.draw_string(font, Vector2(x + 17.0, y - 3.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, job["color"])
		x += 17.0 + font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 10.0
		shown += 1
