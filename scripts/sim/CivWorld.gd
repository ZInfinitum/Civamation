class_name CivWorld
extends RefCounted
## The generated map, the living stocks on it, and how much of it anybody has
## actually seen.
##
## Tiles are flat arrays indexed `y * w + x`. Every renewable stock (game,
## forage, forest) has a matching capacity array; the ecology in Sim.gd pushes
## the stock toward that capacity and the work parties pull it back down.
##
## Three separate ideas about land, easy to confuse:
##   explored  - somebody has walked here. Fog of war. Grows only with explorers.
##   territory - explored land inside the working radius. What gets harvested.
##   passable  - can be walked through at all, which depends on your techs.

var w: int = Balance.WORLD_W
var h: int = Balance.WORLD_H
var world_seed: int = 0
var world_type: int = Balance.WorldType.EARTH

## Current biome. Tiles change: fell or burn a wood and it becomes a clearing
## until it grows back.
var biome := PackedInt32Array()
## The biome the land tends back toward - what generation decided it should be.
## A clearing remembers the forest it was.
var base_biome := PackedInt32Array()
var elevation := PackedFloat32Array()
var fertility := PackedFloat32Array()
var stone := PackedFloat32Array()
## 0..1, how easy it is to draw water here (distance falloff from water tiles).
var water_access := PackedFloat32Array()

var game := PackedFloat32Array()
var game_cap := PackedFloat32Array()
var forage := PackedFloat32Array()
var forage_cap := PackedFloat32Array()
var forest := PackedFloat32Array()
var forest_cap := PackedFloat32Array()

## Mineral richness. Unlike the living stocks these are never depleted - a seam
## outlasts the civilisation that works it, and what improves instead is the
## people's ability to use what comes up.
var ore := PackedFloat32Array()
var gold := PackedFloat32Array()

## Fog of war, in three states rather than two:
##   explored[i] == 0   nobody has ever been here. Blank.
##   explored[i] == 1   walked, but nobody is there now. Terrain remembered,
##                      drawn faded; you cannot see what is happening on it.
##   observed[i] == 1   somebody is there right now. Live: animals, work
##                      parties, current tree cover.
var explored := PackedByteArray()
var observed := PackedByteArray()
var explored_count: int = 0
## How far from home the furthest footstep has reached. The settlement will not
## claim ground beyond this, which is what makes explorers matter.
var explored_radius: float = 0.0
## Tiles adjacent to explored ground that could be walked into next, held as a
## FIFO queue. Breadth-first means reveal order is geodesic distance from home -
## a widening ring that walks around mountains rather than through them - and it
## makes taking the next tile O(1) instead of a scan for the nearest.
var frontier: PackedInt32Array = PackedInt32Array()
var _frontier_head: int = 0
## 1 once a tile is explored or already queued, so nothing is enqueued twice.
var _queued := PackedByteArray()

## Set by Sim from the tech list. The world does not know what a tech is.
var can_cross_water := false
var can_cross_mountains := false

var origin := Vector2i.ZERO
var territory_radius: float = Balance.BASE_TERRITORY_RADIUS
var territory := PackedInt32Array()
## Scratch for the territory union: a stamp per tile, so overlapping claims do
## not add the same tile twice without allocating a set every rebuild.
var _claim_seen := PackedByteArray()
var _claim_stamp := 0

## Territory aggregates that only change when the territory does. Recomputing
## these every substep was most of the simulation's cost once the map got big.
var terr_water_access: float = 0.0
var terr_fertility: float = 0.0
var terr_stone: float = 0.0
var terr_ore: float = 0.0
var terr_gold: float = 0.0
## Untouchable remnant of each living stock across the territory.
var terr_game_refuge: float = 0.0
var terr_forage_refuge: float = 0.0
var terr_forest_refuge: float = 0.0

var _cached_radius: float = -1.0
var _cached_explored: int = -1
var _rng := RandomNumberGenerator.new()


func idx(x: int, y: int) -> int:
	return y * w + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < w and y < h


func tile_pos(i: int) -> Vector2i:
	return Vector2i(i % w, i / w)


# --- Generation -------------------------------------------------------------

func generate(p_seed: int, p_type: int = Balance.WorldType.EARTH) -> void:
	world_seed = p_seed
	world_type = p_type
	var info := Balance.world_type_info(p_type)
	_rng.seed = p_seed

	var count := w * h
	for arr in [elevation, fertility, stone, water_access, game, game_cap,
			forage, forage_cap, forest, forest_cap, ore, gold]:
		arr.resize(count)
	biome.resize(count)
	base_biome.resize(count)
	explored.resize(count)
	observed.resize(count)
	_queued.resize(count)
	for i in count:
		explored[i] = 0
		observed[i] = 0
		_queued[i] = 0
	animal_kind = PackedInt32Array()
	animal_tile = PackedInt32Array()
	_animal_cursor = 0
	explored_count = 0
	explored_radius = 0.0
	frontier = PackedInt32Array()
	_frontier_head = 0

	var n_elev := FastNoiseLite.new()
	n_elev.seed = p_seed
	n_elev.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_elev.frequency = float(info["scale"])
	n_elev.fractal_octaves = 5

	var n_detail := FastNoiseLite.new()
	n_detail.seed = p_seed + 4021
	n_detail.frequency = float(info["scale"]) * 3.0

	var n_moist := FastNoiseLite.new()
	n_moist.seed = p_seed + 7919
	n_moist.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_moist.frequency = 0.035
	n_moist.fractal_octaves = 3

	var n_temp := FastNoiseLite.new()
	n_temp.seed = p_seed + 104729
	n_temp.frequency = 0.022

	# Edge falloff so land never runs off the side of the map. A whole-world map
	# gets a gentle one; scattered-island maps get almost none, because their
	# edge is just where the region stops.
	var edge_bite: float = 0.85 if bool(info["caps"]) else 0.35
	var cx := w * 0.5
	var cy := h * 0.5
	var max_d := sqrt(cx * cx + cy * cy)

	for y in h:
		for x in w:
			var i := idx(x, y)
			var dx := (x - cx) / max_d
			var dy := (y - cy) / max_d
			var d := sqrt(dx * dx + dy * dy) * 1.30
			var e: float = n_elev.get_noise_2d(x, y) * 0.5 + 0.5
			e += (n_detail.get_noise_2d(x, y) * 0.5 + 0.5) * 0.18
			e /= 1.18
			elevation[i] = e - d * d * edge_bite

	# Pick the waterline that actually produces the land fraction this world
	# shape promises, rather than trusting a fixed threshold against noise whose
	# distribution changes with frequency.
	var sea := _quantile(elevation, 1.0 - float(info["land"]))
	var span := maxf(0.0001, _quantile(elevation, 0.999) - sea)

	var climate := bool(info["climate"])
	for y in h:
		for x in w:
			var i := idx(x, y)
			var e: float = elevation[i]
			if e < sea:
				biome[i] = Balance.Biome.OCEAN
				continue
			# Height above the waterline, normalised, is what decides landform.
			var alt: float = (e - sea) / span
			var moist: float = n_moist.get_noise_2d(x, y) * 0.5 + 0.5
			# Rain shadows: high ground is drier.
			moist = clampf(moist - alt * 0.25, 0.0, 1.0)
			var temp := 0.75
			if climate:
				# Latitude drives climate on a whole-world map: hot at the
				# equator, cold at the poles, cooler the higher you stand.
				var lat: float = absf(float(y) / float(h) * 2.0 - 1.0)
				temp = 1.0 - lat * 1.15
			temp += n_temp.get_noise_2d(x, y) * 0.16
			temp -= alt * 0.35
			biome[i] = _classify(alt, moist, clampf(temp, 0.0, 1.0))

	if climate:
		_apply_ice_caps()
	_carve_rivers(int(info["rivers"]), sea)
	_mark_coast()
	_compute_water_access()
	_seed_stocks()
	base_biome = biome.duplicate()
	_place_settlement()
	_seed_animals()
	_initial_reveal()
	refresh_territory(true)


## Value below which `frac` of the array falls. Sampled rather than fully
## sorted; at this map size the difference is invisible and it is much faster.
func _quantile(arr: PackedFloat32Array, frac: float) -> float:
	var sample := PackedFloat32Array()
	var stride := maxi(1, arr.size() / 4000)
	for i in range(0, arr.size(), stride):
		sample.append(arr[i])
	sample.sort()
	if sample.is_empty():
		return 0.0
	return sample[clampi(int(sample.size() * frac), 0, sample.size() - 1)]


func _classify(alt: float, moist: float, temp: float) -> int:
	if alt > 0.62:
		return Balance.Biome.MOUNTAIN
	if alt > 0.42:
		return Balance.Biome.HILLS
	if temp < 0.16:
		return Balance.Biome.ICE
	if temp < 0.30:
		return Balance.Biome.TUNDRA
	if moist < 0.34 and temp > 0.52:
		return Balance.Biome.DESERT
	if moist > 0.70:
		if temp > 0.68:
			return Balance.Biome.RAINFOREST
		return Balance.Biome.FOREST
	if moist > 0.56:
		return Balance.Biome.FOREST
	if moist > 0.44:
		return Balance.Biome.GRASSLAND
	return Balance.Biome.PLAINS


## Solid ice at the top and bottom of the map. Only whole-world shapes get
## these - an island chain is a close-up of one warm region, not a globe.
func _apply_ice_caps() -> void:
	var cap := maxi(1, int(h * 0.055))
	for x in w:
		for k in cap:
			for y in [k, h - 1 - k]:
				var i := idx(x, y)
				# Ice sheets sit on the sea as well as the land at the poles.
				biome[i] = Balance.Biome.ICE
		# A ragged edge below the solid cap, so the boundary is not a ruler line.
		var extra := int((sin(float(x) * 0.31) * 0.5 + 0.5) * float(cap))
		for k in range(cap, cap + extra):
			for y in [k, h - 1 - k]:
				if y >= 0 and y < h:
					var i2 := idx(x, y)
					if biome[i2] != Balance.Biome.OCEAN:
						biome[i2] = Balance.Biome.ICE


func _carve_rivers(count: int, sea: float) -> void:
	for attempt in count:
		var best := -1
		var best_e := -INF
		for probe in 300:
			var x := _rng.randi_range(2, w - 3)
			var y := _rng.randi_range(2, h - 3)
			var i := idx(x, y)
			if biome[i] == Balance.Biome.ICE:
				continue
			if elevation[i] > best_e:
				best_e = elevation[i]
				best = i
		if best < 0 or best_e < sea + 0.05:
			continue

		var cur := tile_pos(best)
		var steps := 0
		while steps < w * 2:
			steps += 1
			var ci := idx(cur.x, cur.y)
			if Balance.is_water_biome(biome[ci]) or biome[ci] == Balance.Biome.ICE:
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
				# A local low: the water pools here instead of running on.
				for oy in [-1, 0, 1]:
					for ox in [-1, 0, 1]:
						var lx: int = cur.x + ox
						var ly: int = cur.y + oy
						if in_bounds(lx, ly) and elevation[idx(lx, ly)] < sea + 0.06:
							biome[idx(lx, ly)] = Balance.Biome.LAKE
				biome[ci] = Balance.Biome.LAKE
				break
			cur = next


## Land that touches open water becomes shore.
func _mark_coast() -> void:
	var changes := PackedInt32Array()
	for y in h:
		for x in w:
			var i := idx(x, y)
			var b := biome[i]
			if b != Balance.Biome.PLAINS and b != Balance.Biome.GRASSLAND \
					and b != Balance.Biome.DESERT:
				continue
			for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if in_bounds(x + o.x, y + o.y) and biome[idx(x + o.x, y + o.y)] == Balance.Biome.OCEAN:
					changes.append(i)
					break
	for i in changes:
		biome[i] = Balance.Biome.COAST


## Cheap two-pass chamfer distance transform from water, as a 0..1 score.
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


func _seed_stocks() -> void:
	# Minerals clump into seams rather than spreading evenly, so a separate
	# low-frequency field decides where the good ground is.
	var n_ore := FastNoiseLite.new()
	n_ore.seed = world_seed + 31337
	n_ore.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_ore.frequency = 0.06

	var n_gold := FastNoiseLite.new()
	n_gold.seed = world_seed + 61879
	n_gold.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_gold.frequency = 0.10

	for y in h:
		for x in w:
			var i := idx(x, y)
			var info: Dictionary = Balance.BIOME_INFO[biome[i]]
			var jitter := _rng.randf_range(0.82, 1.18)
			game_cap[i] = float(info["game"]) * jitter
			forage_cap[i] = float(info["forage"]) * jitter
			forest_cap[i] = float(info["forest"]) * jitter
			fertility[i] = float(info["fertility"]) * jitter
			stone[i] = float(info["stone"]) * jitter
			game[i] = game_cap[i]
			forage[i] = forage_cap[i]
			forest[i] = forest_cap[i]

			var ore_seam: float = maxf(0.0, n_ore.get_noise_2d(x, y) * 0.5 + 0.5 - 0.32) / 0.68
			var gold_seam: float = maxf(0.0, n_gold.get_noise_2d(x, y) * 0.5 + 0.5 - 0.60) / 0.40
			ore[i] = float(info["ore"]) * ore_seam * _rng.randf_range(0.85, 1.15)
			gold[i] = float(info["gold"]) * gold_seam * _rng.randf_range(0.85, 1.15)


## Pick the best starting site. Water first and by a wide margin - a band that
## has to walk for water spends every pair of hands carrying it and never gets
## started - then food, then whatever else is nearby.
func _place_settlement() -> void:
	if _try_place(0.45):
		return
	if _try_place(0.20):
		return
	_try_place(0.0)


func _try_place(min_water: float) -> bool:
	var best_score := -INF
	var best := Vector2i(w / 2, h / 2)
	var margin := 4
	for y in range(margin, h - margin):
		for x in range(margin, w - margin):
			var i := idx(x, y)
			var b := biome[i]
			if Balance.is_water_biome(b) or b == Balance.Biome.MOUNTAIN or b == Balance.Biome.ICE:
				continue
			if water_access[i] < min_water:
				continue
			var score := water_access[i] * 300.0
			var land := 0
			for oy in range(-3, 4):
				for ox in range(-3, 4):
					if not in_bounds(x + ox, y + oy):
						continue
					var ni := idx(x + ox, y + oy)
					if not Balance.is_water_biome(biome[ni]) and biome[ni] != Balance.Biome.ICE:
						land += 1
					score += game_cap[ni] * 0.35 + forage_cap[ni] * 0.5 \
							+ forest_cap[ni] * 0.2 + ore[ni] * 10.0 + gold[ni] * 8.0
			# Somewhere with room to grow into, not a three-tile rock.
			score += float(land) * 6.0
			score += _rng.randf_range(0.0, 20.0)
			if score > best_score:
				best_score = score
				best = Vector2i(x, y)
	if best_score == -INF:
		return false
	origin = best
	return true


# --- Fog of war -------------------------------------------------------------

func passable(i: int) -> bool:
	var b := biome[i]
	if b == Balance.Biome.ICE:
		return false
	if b == Balance.Biome.MOUNTAIN:
		return can_cross_mountains
	if Balance.is_deep_water(b):
		return can_cross_water
	return true


## Can the settlement actually get anything out of this tile?
func workable(i: int) -> bool:
	var b := biome[i]
	if b == Balance.Biome.ICE:
		return false
	if b == Balance.Biome.MOUNTAIN:
		return can_cross_mountains
	return true


func _initial_reveal() -> void:
	# The band knows the country it walked in through.
	for oy in range(-4, 5):
		for ox in range(-4, 5):
			if ox * ox + oy * oy > 18:
				continue
			var x := origin.x + ox
			var y := origin.y + oy
			if in_bounds(x, y):
				_set_explored(idx(x, y))
	rebuild_frontier()


func _set_explored(i: int) -> void:
	if explored[i] != 0:
		return
	explored[i] = 1
	_queued[i] = 1
	explored_count += 1
	var p := tile_pos(i)
	var d := Vector2(p - origin).length()
	if d > explored_radius:
		explored_radius = d


## Recollect the walkable edge of known country. Called on load and whenever a
## tech changes what counts as passable - the far side of a mountain range
## becomes reachable the moment you learn to cross it.
func rebuild_frontier() -> void:
	var list := PackedInt32Array()
	for i in _queued.size():
		_queued[i] = explored[i]
	for y in h:
		for x in w:
			var i := idx(x, y)
			if explored[i] == 0 or not passable(i):
				continue
			for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + o.x
				var ny: int = y + o.y
				if not in_bounds(nx, ny):
					continue
				var ni := idx(nx, ny)
				if _queued[ni] != 0:
					continue
				_queued[ni] = 1
				list.append(ni)
	frontier = list
	_frontier_head = 0


## Walk one tile further out. Returns the revealed tile index, or -1 when there
## is nothing left within reach.
func reveal_one() -> int:
	while _frontier_head < frontier.size():
		var i := frontier[_frontier_head]
		_frontier_head += 1
		if explored[i] != 0:
			continue

		_set_explored(i)
		# Impassable ground can be seen from next door but never entered, so it
		# is revealed and simply never becomes a route onward.
		if passable(i):
			var p := tile_pos(i)
			for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = p.x + o.x
				var ny: int = p.y + o.y
				if not in_bounds(nx, ny):
					continue
				var ni := idx(nx, ny)
				if _queued[ni] == 0:
					_queued[ni] = 1
					frontier.append(ni)
		_compact_frontier()
		return i
	frontier = PackedInt32Array()
	_frontier_head = 0
	return -1


## Drop the consumed prefix once it is worth the copy, so the queue does not
## grow without bound over a long game.
func _compact_frontier() -> void:
	if _frontier_head < 512 or _frontier_head < frontier.size() / 2:
		return
	frontier = frontier.slice(_frontier_head)
	_frontier_head = 0


func frontier_open() -> bool:
	return _frontier_head < frontier.size()


func explored_fraction() -> float:
	return float(explored_count) / float(maxi(1, w * h))


# --- Tile change ------------------------------------------------------------

## Wooded ground that has been worked flat reads as a clearing, and grows back
## into forest when the trees do. Called from the ecology sweep, so it costs one
## comparison per worked tile and nothing at all anywhere else.
##
## Only the *display* biome changes - the capacity arrays still describe the
## forest the land can support, which is what lets it recover.
func update_cover(i: int) -> bool:
	var base: int = base_biome[i]
	if base != Balance.Biome.FOREST and base != Balance.Biome.RAINFOREST:
		return false
	var cap: float = forest_cap[i]
	if cap <= 0.5:
		return false
	var frac: float = forest[i] / cap
	var now: int = biome[i]
	if now != Balance.Biome.CLEARING and frac < Balance.CLEARED_BELOW:
		biome[i] = Balance.Biome.CLEARING
		return true
	if now == Balance.Biome.CLEARING and frac > Balance.REGROWN_ABOVE:
		biome[i] = base
		return true
	return false


# --- Animals ----------------------------------------------------------------
## Cosmetic wildlife: real creatures standing on real tiles, wandering between
## them, as distinct from the abstract "game" stock the economy runs on. The
## count is a fixed budget, so this costs the same for a city as for a camp.

var animal_kind := PackedInt32Array()
var animal_tile := PackedInt32Array()
var _animal_cursor: int = 0


func _suits(kind: int, i: int) -> bool:
	var b: int = biome[i]
	return (Balance.ANIMALS[kind]["biomes"] as Array).has(b)


func _seed_animals() -> void:
	animal_kind = PackedInt32Array()
	animal_tile = PackedInt32Array()
	for n in Balance.MAX_ANIMALS:
		_spawn_animal()


func _spawn_animal() -> void:
	if animal_kind.size() >= Balance.MAX_ANIMALS:
		return
	# Weighted pick of what kind, then a handful of tries at somewhere it lives.
	var total := 0.0
	for k in Balance.ANIMAL_ORDER:
		total += float(Balance.ANIMALS[k]["weight"])
	var roll := _rng.randf() * total
	var kind: int = Balance.ANIMAL_ORDER[0]
	for k in Balance.ANIMAL_ORDER:
		roll -= float(Balance.ANIMALS[k]["weight"])
		if roll <= 0.0:
			kind = k
			break
	for tries in 12:
		var x := _rng.randi_range(0, w - 1)
		var y := _rng.randi_range(0, h - 1)
		var i := idx(x, y)
		if not _suits(kind, i):
			continue
		# Predators need something to hunt; grazers need the tile to support them.
		var need := float(Balance.ANIMALS[kind]["needs_game"])
		if need > 0.0 and game_cap[i] > 0.5 and game[i] / game_cap[i] < need:
			continue
		animal_kind.append(kind)
		animal_tile.append(i)
		return


## Move a few animals to a neighbouring tile they would plausibly be on, and
## top the population back up. Called on a slow tick, and only ever touches a
## couple of entries per call.
func step_animals(moves: int) -> void:
	if animal_kind.is_empty():
		_seed_animals()
		return
	for m in moves:
		if animal_kind.is_empty():
			return
		_animal_cursor = (_animal_cursor + 1) % animal_kind.size()
		var a := _animal_cursor
		var kind: int = animal_kind[a]
		var from := tile_pos(animal_tile[a])
		var nx: int = from.x + _rng.randi_range(-1, 1)
		var ny: int = from.y + _rng.randi_range(-1, 1)
		if not in_bounds(nx, ny):
			continue
		var ni := idx(nx, ny)
		if not _suits(kind, ni):
			continue
		var need := float(Balance.ANIMALS[kind]["needs_game"])
		if need > 0.0 and game_cap[ni] > 0.5 and game[ni] / game_cap[ni] < need:
			continue
		animal_tile[a] = ni
	if animal_kind.size() < Balance.MAX_ANIMALS:
		_spawn_animal()


# --- Visibility -------------------------------------------------------------

## Recompute who can actually see what. Somebody is *at* the tiles the
## settlement works, and explorers can see a little way around wherever they
## have got to. Everything else the tribe has walked is remembered, not watched.
##
## O(territory) on a one-per-second tick, which is nothing.
func refresh_visibility(scout_tiles: PackedInt32Array, scout_sight: int) -> void:
	for i in observed.size():
		observed[i] = 0
	for i in territory:
		observed[i] = 1
	if scout_tiles.is_empty():
		return
	for t in scout_tiles:
		var p := tile_pos(t)
		for oy in range(-scout_sight, scout_sight + 1):
			for ox in range(-scout_sight, scout_sight + 1):
				if ox * ox + oy * oy > scout_sight * scout_sight:
					continue
				var x: int = p.x + ox
				var y: int = p.y + oy
				if in_bounds(x, y):
					observed[idx(x, y)] = 1


# --- Territory --------------------------------------------------------------

## Every place the civilisation claims land from, as {"pos": Vector2i, "r": float}.
##
## Territory used to be a single circle around the first settlement, so founding
## a town sixteen tiles east also claimed the ground sixteen tiles *west*. It is
## a union of circles now - one per settlement - which is what a second town
## actually is. Set by Sim; the home circle is always element zero.
var claims: Array[Dictionary] = []


func refresh_territory(force: bool = false) -> void:
	# Rebuild on either input: the claim radii, or newly walked ground inside
	# them. Watching only the radius left the worked land lagging the fog.
	var signature := territory_radius
	for c in claims:
		signature += float(c["r"]) * 7.31 + float(int(c["pos"].x) * 31 + int(c["pos"].y))
	if not force and absf(signature - _cached_radius) < 0.25 \
			and explored_count == _cached_explored:
		return
	_cached_radius = signature
	_cached_explored = explored_count

	# The home circle is implicit when nobody has told us otherwise.
	var centres := claims
	if centres.is_empty():
		centres = [{"pos": origin, "r": territory_radius}]

	# Union, so overlapping settlements do not claim the same tile twice. The
	# seen-set is a byte array rather than a Dictionary: this runs whenever the
	# fog moves, and it is the only allocation in the path.
	if _claim_seen.size() != w * h:
		_claim_seen.resize(w * h)
	_claim_stamp += 1
	if _claim_stamp > 250:
		# Wrapped: clear rather than let a stale stamp read as claimed.
		for k in _claim_seen.size():
			_claim_seen[k] = 0
		_claim_stamp = 1

	var list := PackedInt32Array()
	for c in centres:
		var pos: Vector2i = c["pos"]
		var rad := float(c["r"])
		var r := int(ceil(rad))
		var r2 := rad * rad
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if float(ox * ox + oy * oy) > r2:
					continue
				var x := pos.x + ox
				var y := pos.y + oy
				if not in_bounds(x, y):
					continue
				var i := idx(x, y)
				if _claim_seen[i] == _claim_stamp:
					continue
				# You cannot work land nobody has walked.
				if explored[i] == 0 or not workable(i):
					continue
				_claim_seen[i] = _claim_stamp
				list.append(i)
	territory = list
	_recompute_static_totals()


## The terrain-derived sums, which change only when the territory does.
func _recompute_static_totals() -> void:
	terr_water_access = 0.0
	terr_fertility = 0.0
	terr_stone = 0.0
	terr_ore = 0.0
	terr_gold = 0.0
	var g := 0.0
	var f := 0.0
	var t := 0.0
	for i in territory:
		terr_water_access += water_access[i]
		terr_fertility += fertility[i]
		terr_stone += stone[i]
		terr_ore += ore[i]
		terr_gold += gold[i]
		g += game_cap[i]
		f += forage_cap[i]
		t += forest_cap[i]
	terr_game_refuge = g * Balance.STOCK_REFUGE
	terr_forage_refuge = f * Balance.STOCK_REFUGE
	terr_forest_refuge = t * Balance.STOCK_REFUGE


func territory_size() -> int:
	return territory.size()


func total_of(arr: PackedFloat32Array) -> float:
	var t := 0.0
	for i in territory:
		t += arr[i]
	return t


## Fraction of a stock's territory capacity currently standing. 1.0 is
## pristine, and it can never fall below the refuge floor.
func stock_health(arr: PackedFloat32Array, cap_arr: PackedFloat32Array) -> float:
	var have := 0.0
	var cap := 0.0
	for i in territory:
		have += arr[i]
		cap += cap_arr[i]
	if cap <= 0.01:
		return 1.0
	return clampf(have / cap, 0.0, 1.0)


## Remove `amount` from a stock, spread across the territory in proportion to
## what each tile holds above its refuge floor. Returns what was actually taken.
##
## The refuge floor is why nothing here can be wiped out: a slice of every herd
## and every stand of timber lives where the work parties do not reach, and that
## remnant is what regrows.
func drain(arr: PackedFloat32Array, cap_arr: PackedFloat32Array, amount: float,
		total: float, refuge: float) -> float:
	if amount <= 0.0 or total <= 0.0:
		return 0.0
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


## Tiles in the territory ranked by some per-tile array, best first. The map
## uses this to stand workers where their work actually is.
func best_tiles(arr: PackedFloat32Array, count: int) -> PackedInt32Array:
	var pairs: Array = []
	for i in territory:
		if arr[i] > 0.01:
			pairs.append([arr[i], i])
	pairs.sort_custom(func(a, b): return a[0] > b[0])
	var out := PackedInt32Array()
	for n in mini(count, pairs.size()):
		out.append(pairs[n][1])
	return out


# --- Persistence ------------------------------------------------------------
## The map itself is regenerated from the seed, so only the mutable parts are
## stored. Explored ground is run-length encoded because at 96x64 a raw array
## is most of the save file.

func to_dict() -> Dictionary:
	return {
		"w": w, "h": h,
		"seed": world_seed,
		"type": world_type,
		"origin_x": origin.x, "origin_y": origin.y,
		"radius": territory_radius,
		# refresh_territory() only rebuilds when the radius has moved enough to
		# matter, so the live territory can lag the live radius. Persist the
		# radius the territory was actually built from, or loading would quietly
		# enlarge the worked land.
		"built_radius": _cached_radius,
		"built_explored": _cached_explored,
		"explored": _rle_encode(explored),
		"cleared": _rle_encode(_cleared_mask()),
		"game": Array(game),
		"forage": Array(forage),
		"forest": Array(forest),
	}


func from_dict(d: Dictionary) -> void:
	generate(int(d.get("seed", 0)), int(d.get("type", Balance.WorldType.EARTH)))
	origin = Vector2i(int(d.get("origin_x", origin.x)), int(d.get("origin_y", origin.y)))

	var enc: Variant = d.get("explored", [])
	if enc is Array and not (enc as Array).is_empty():
		_rle_decode(enc, explored)
		explored_count = 0
		explored_radius = 0.0
		for i in explored.size():
			if explored[i] != 0:
				explored_count += 1
				var dd := Vector2(tile_pos(i) - origin).length()
				if dd > explored_radius:
					explored_radius = dd
	rebuild_frontier()

	var cleared: Variant = d.get("cleared", [])
	if cleared is Array and not (cleared as Array).is_empty():
		var mask := PackedByteArray()
		mask.resize(w * h)
		_rle_decode(cleared, mask)
		for i in mask.size():
			if mask[i] != 0:
				biome[i] = Balance.Biome.CLEARING

	_restore(game, d.get("game", []))
	_restore(forage, d.get("forage", []))
	_restore(forest, d.get("forest", []))

	territory_radius = float(d.get("radius", Balance.BASE_TERRITORY_RADIUS))
	var built := float(d.get("built_radius", territory_radius))
	var live := territory_radius
	territory_radius = built
	refresh_territory(true)
	_cached_explored = int(d.get("built_explored", explored_count))
	territory_radius = live


## Which tiles are currently cleared woodland. Everything else about the map is
## reproducible from the seed, so this one byte-per-tile layer is all the
## terrain a save has to carry.
func _cleared_mask() -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(w * h)
	for i in mask.size():
		mask[i] = 1 if biome[i] == Balance.Biome.CLEARING else 0
	return mask


func _rle_encode(bytes: PackedByteArray) -> Array:
	var out: Array = []
	if bytes.is_empty():
		return out
	var cur := bytes[0]
	var run := 1
	for i in range(1, bytes.size()):
		if bytes[i] == cur and run < 65535:
			run += 1
		else:
			out.append(int(cur))
			out.append(run)
			cur = bytes[i]
			run = 1
	out.append(int(cur))
	out.append(run)
	return out


func _rle_decode(enc: Array, target: PackedByteArray) -> void:
	var pos := 0
	var n := target.size()
	var k := 0
	while k + 1 < enc.size() and pos < n:
		var value := int(enc[k])
		var run := int(enc[k + 1])
		k += 2
		for r in run:
			if pos >= n:
				break
			target[pos] = value
			pos += 1


func _restore(target: PackedFloat32Array, src: Variant) -> void:
	if src is Array and (src as Array).size() == target.size():
		var a: Array = src
		for i in a.size():
			target[i] = float(a[i])
