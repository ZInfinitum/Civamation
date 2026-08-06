class_name CivWorld
extends RefCounted
## The generated map plus the living stocks that sit on top of it.
##
## Tiles are flat arrays indexed `y * w + x`. Every renewable stock (game,
## forage, forest) has a matching capacity array; the ecology in Sim.gd pushes
## the stock toward that capacity and the workers pull it back down.

var w: int = Balance.WORLD_W
var h: int = Balance.WORLD_H
var world_seed: int = 0

var biome := PackedInt32Array()
var elevation := PackedFloat32Array()
var fertility := PackedFloat32Array()
var stone := PackedFloat32Array()
## 0..1, how easy it is to draw water here (distance-falloff from water tiles).
var water_access := PackedFloat32Array()

var game := PackedFloat32Array()
var game_cap := PackedFloat32Array()
var forage := PackedFloat32Array()
var forage_cap := PackedFloat32Array()
var forest := PackedFloat32Array()
var forest_cap := PackedFloat32Array()

## Mineral richness per tile. Unlike the living stocks these are not depleted -
## a seam outlasts the civilisation that works it, and the people's ability to
## use what comes up is what improves instead.
var ore := PackedFloat32Array()
var gold := PackedFloat32Array()

var origin := Vector2i.ZERO
var territory_radius: float = Balance.BASE_TERRITORY_RADIUS
var territory := PackedInt32Array()

var _cached_radius: float = -1.0


func idx(x: int, y: int) -> int:
	return y * w + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < w and y < h


func generate(p_seed: int) -> void:
	world_seed = p_seed
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed

	var n_elev := FastNoiseLite.new()
	n_elev.seed = p_seed
	n_elev.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_elev.frequency = 0.055
	n_elev.fractal_octaves = 4

	var n_moist := FastNoiseLite.new()
	n_moist.seed = p_seed + 7919
	n_moist.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_moist.frequency = 0.045
	n_moist.fractal_octaves = 3

	var n_temp := FastNoiseLite.new()
	n_temp.seed = p_seed + 104729
	n_temp.frequency = 0.03

	var count := w * h
	biome.resize(count)
	elevation.resize(count)
	fertility.resize(count)
	stone.resize(count)
	water_access.resize(count)
	game.resize(count)
	game_cap.resize(count)
	forage.resize(count)
	forage_cap.resize(count)
	forest.resize(count)
	forest_cap.resize(count)
	ore.resize(count)
	gold.resize(count)

	# Radial falloff keeps the landmass off the edges so the map reads as an
	# island/continent rather than a noise field cut by the viewport.
	var cx := w * 0.5
	var cy := h * 0.5
	var max_d := sqrt(cx * cx + cy * cy)

	for y in h:
		for x in w:
			var i := idx(x, y)
			var dx := (x - cx) / max_d
			var dy := (y - cy) / max_d
			var d := sqrt(dx * dx + dy * dy) * 1.35
			var e: float = (n_elev.get_noise_2d(x, y) * 0.5 + 0.5) - d * d * 0.85
			elevation[i] = e

			var moist: float = n_moist.get_noise_2d(x, y) * 0.5 + 0.5
			var temp: float = (n_temp.get_noise_2d(x, y) * 0.5 + 0.5) * 0.5 + (1.0 - float(y) / float(h)) * 0.5
			biome[i] = _classify(e, moist, temp)

	_carve_river(rng)
	_compute_water_access()
	_seed_stocks(rng)
	_place_settlement(rng)
	refresh_territory(true)


func _classify(e: float, moist: float, temp: float) -> int:
	if e < 0.16:
		return Balance.Biome.OCEAN
	if e < 0.20:
		return Balance.Biome.BEACH
	if e > 0.68:
		return Balance.Biome.MOUNTAIN
	if e > 0.55:
		return Balance.Biome.HILLS
	if moist > 0.72 and e < 0.30:
		return Balance.Biome.WETLAND
	if moist < 0.30 and temp > 0.60:
		return Balance.Biome.DESERT
	if moist > 0.50:
		return Balance.Biome.FOREST
	return Balance.Biome.GRASSLAND


## Walk downhill from a high point, cutting a river until we hit water or the
## map edge. Rivers matter a lot: they are the only reliable water source.
func _carve_river(rng: RandomNumberGenerator) -> void:
	for attempt in 6:
		var best := -1
		var best_e := -INF
		for probe in 200:
			var x := rng.randi_range(2, w - 3)
			var y := rng.randi_range(2, h - 3)
			var i := idx(x, y)
			if elevation[i] > best_e:
				best_e = elevation[i]
				best = i
		if best < 0 or best_e < 0.5:
			continue

		var cur := Vector2i(best % w, best / w)
		var steps := 0
		while steps < w * 2:
			steps += 1
			var ci := idx(cur.x, cur.y)
			if Balance.is_water_biome(biome[ci]):
				break
			biome[ci] = Balance.Biome.RIVER

			var next := cur
			var lowest: float = elevation[ci]
			for oy in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					if ox == 0 and oy == 0:
						continue
					var nx: int = cur.x + ox
					var ny: int = cur.y + oy
					if not in_bounds(nx, ny):
						continue
					var ni := idx(nx, ny)
					if elevation[ni] < lowest:
						lowest = elevation[ni]
						next = Vector2i(nx, ny)
			if next == cur:
				# Local minimum: pool into a lake and stop.
				biome[ci] = Balance.Biome.LAKE
				for oy in [-1, 0, 1]:
					for ox in [-1, 0, 1]:
						var lx: int = cur.x + ox
						var ly: int = cur.y + oy
						if in_bounds(lx, ly) and elevation[idx(lx, ly)] < 0.34:
							biome[idx(lx, ly)] = Balance.Biome.LAKE
				break
			cur = next
		return


## Cheap two-pass chamfer distance transform from water tiles, converted to a
## 0..1 accessibility score.
func _compute_water_access() -> void:
	var count := w * h
	var dist := PackedFloat32Array()
	dist.resize(count)
	for i in count:
		dist[i] = 0.0 if Balance.is_water_biome(biome[i]) else 1e9

	for y in h:
		for x in w:
			var i := idx(x, y)
			if x > 0:
				dist[i] = minf(dist[i], dist[i - 1] + 1.0)
			if y > 0:
				dist[i] = minf(dist[i], dist[i - w] + 1.0)
			if x > 0 and y > 0:
				dist[i] = minf(dist[i], dist[i - w - 1] + 1.4)
	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := idx(x, y)
			if x < w - 1:
				dist[i] = minf(dist[i], dist[i + 1] + 1.0)
			if y < h - 1:
				dist[i] = minf(dist[i], dist[i + w] + 1.0)
			if x < w - 1 and y < h - 1:
				dist[i] = minf(dist[i], dist[i + w + 1] + 1.4)

	for i in count:
		water_access[i] = clampf(1.0 - dist[i] / 6.0, 0.0, 1.0)


func _seed_stocks(rng: RandomNumberGenerator) -> void:
	# Minerals clump into seams rather than spreading evenly, so a separate
	# low-frequency noise field decides where the good ground is.
	var n_ore := FastNoiseLite.new()
	n_ore.seed = world_seed + 31337
	n_ore.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_ore.frequency = 0.09

	var n_gold := FastNoiseLite.new()
	n_gold.seed = world_seed + 61879
	n_gold.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_gold.frequency = 0.14

	for y in h:
		for x in w:
			var i := idx(x, y)
			var info: Dictionary = Balance.BIOME_INFO[biome[i]]
			var jitter := rng.randf_range(0.8, 1.2)
			game_cap[i] = float(info["game"]) * jitter
			forage_cap[i] = float(info["forage"]) * jitter
			forest_cap[i] = float(info["forest"]) * jitter
			fertility[i] = float(info["fertility"]) * jitter
			stone[i] = float(info["stone"]) * jitter
			# Start every living stock at capacity: an untouched world.
			game[i] = game_cap[i]
			forage[i] = forage_cap[i]
			forest[i] = forest_cap[i]

			# Seams: biome sets the ceiling, noise decides where it is realised.
			var ore_seam: float = maxf(0.0, n_ore.get_noise_2d(x, y) * 0.5 + 0.5 - 0.35) / 0.65
			var gold_seam: float = maxf(0.0, n_gold.get_noise_2d(x, y) * 0.5 + 0.5 - 0.62) / 0.38
			ore[i] = float(info["ore"]) * ore_seam * rng.randf_range(0.85, 1.15)
			gold[i] = float(info["gold"]) * gold_seam * rng.randf_range(0.85, 1.15)


## Pick the best starting site: dry land, close to water, surrounded by things
## worth eating.
func _place_settlement(rng: RandomNumberGenerator) -> void:
	# Water is not one factor among many - a band that has to walk for water
	# spends every pair of hands carrying it and never gets started. So the
	# first pass will only consider genuinely well-watered ground, and only
	# falls back to the open field if the map has nowhere better.
	if _try_place(rng, 0.45):
		return
	_try_place(rng, 0.0)


func _try_place(rng: RandomNumberGenerator, min_water: float) -> bool:
	var best_score := -INF
	var best := Vector2i(w / 2, h / 2)
	for y in range(3, h - 3):
		for x in range(3, w - 3):
			var i := idx(x, y)
			if Balance.is_water_biome(biome[i]):
				continue
			if biome[i] == Balance.Biome.MOUNTAIN:
				continue
			if water_access[i] < min_water:
				continue
			var score := water_access[i] * 260.0
			for oy in range(-3, 4):
				for ox in range(-3, 4):
					if not in_bounds(x + ox, y + oy):
						continue
					var ni := idx(x + ox, y + oy)
					score += game_cap[ni] * 0.35 + forage_cap[ni] * 0.5 \
							+ forest_cap[ni] * 0.2 + ore[ni] * 8.0 + gold[ni] * 6.0
			score += rng.randf_range(0.0, 12.0)
			if score > best_score:
				best_score = score
				best = Vector2i(x, y)
	if best_score == -INF:
		return false
	origin = best
	return true


func refresh_territory(force: bool = false) -> void:
	if not force and absf(territory_radius - _cached_radius) < 0.25:
		return
	_cached_radius = territory_radius
	var list := PackedInt32Array()
	var r := int(ceil(territory_radius))
	var r2 := territory_radius * territory_radius
	for oy in range(-r, r + 1):
		for ox in range(-r, r + 1):
			if float(ox * ox + oy * oy) > r2:
				continue
			var x := origin.x + ox
			var y := origin.y + oy
			if in_bounds(x, y):
				list.append(idx(x, y))
	territory = list


## Sum a stock array over the current territory.
func total_of(arr: PackedFloat32Array) -> float:
	var t := 0.0
	for i in territory:
		t += arr[i]
	return t


## Fraction of a stock's territory capacity that is currently standing.
## 1.0 is pristine, 0.0 is stripped bare.
func stock_health(arr: PackedFloat32Array, cap_arr: PackedFloat32Array) -> float:
	var have := 0.0
	var cap := 0.0
	for i in territory:
		have += arr[i]
		cap += cap_arr[i]
	if cap <= 0.01:
		return 1.0
	return clampf(have / cap, 0.0, 1.0)


func total_water_access() -> float:
	var t := 0.0
	for i in territory:
		t += water_access[i]
	return t


func total_stone() -> float:
	var t := 0.0
	for i in territory:
		t += stone[i]
	return t


func total_ore() -> float:
	var t := 0.0
	for i in territory:
		t += ore[i]
	return t


func total_gold() -> float:
	var t := 0.0
	for i in territory:
		t += gold[i]
	return t


func total_fertility() -> float:
	var t := 0.0
	for i in territory:
		t += fertility[i]
	return t


## Remove `amount` from a stock array, spread across the territory in
## proportion to what each tile holds above its refuge floor. Returns the amount
## actually taken.
##
## The refuge floor is the reason nothing in this world can be wiped out: a
## slice of every herd and every stand of timber lives somewhere the work
## parties do not reach, and that remnant is what regrows.
func drain(arr: PackedFloat32Array, cap_arr: PackedFloat32Array, amount: float, total: float) -> float:
	if amount <= 0.0 or total <= 0.0:
		return 0.0
	var refuge := 0.0
	for i in territory:
		refuge += cap_arr[i] * Balance.STOCK_REFUGE
	var available := total - refuge
	if available <= 0.0:
		return 0.0
	var take := minf(amount, available)
	var frac := take / available
	for i in territory:
		var floor_i: float = cap_arr[i] * Balance.STOCK_REFUGE
		var surplus: float = maxf(0.0, arr[i] - floor_i)
		arr[i] -= surplus * frac
	return take


func to_dict() -> Dictionary:
	return {
		"w": w,
		"h": h,
		"seed": world_seed,
		"origin_x": origin.x,
		"origin_y": origin.y,
		"radius": territory_radius,
		# refresh_territory() only rebuilds when the radius has moved enough to
		# matter, so the live territory can lag the live radius. Persist the
		# radius the territory was actually built from, or loading would quietly
		# enlarge the worked land by up to a quarter tile.
		"built_radius": _cached_radius,
		"game": Array(game),
		"forage": Array(forage),
		"forest": Array(forest),
	}


## Rebuild from a save. The map itself is regenerated from the seed - only the
## mutable stocks are stored, which keeps saves small.
func from_dict(d: Dictionary) -> void:
	generate(int(d.get("seed", 0)))
	origin = Vector2i(int(d.get("origin_x", origin.x)), int(d.get("origin_y", origin.y)))
	territory_radius = float(d.get("radius", Balance.BASE_TERRITORY_RADIUS))
	# Rebuild the tile list from the radius it was built from, then restore the
	# live radius without refreshing, exactly reproducing the saved state.
	var built := float(d.get("built_radius", territory_radius))
	var live := territory_radius
	territory_radius = built
	refresh_territory(true)
	territory_radius = live
	_restore(game, d.get("game", []))
	_restore(forage, d.get("forage", []))
	_restore(forest, d.get("forest", []))


func _restore(target: PackedFloat32Array, src: Variant) -> void:
	if src is Array and (src as Array).size() == target.size():
		var a: Array = src
		for i in a.size():
			target[i] = float(a[i])
