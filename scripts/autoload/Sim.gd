extends Node
## The simulation. Owns all game state and advances it in fixed steps.
##
## The core model is a real one: wild stocks regrow logistically (Verhulst),
## workers harvest them through a Holling type II functional response, and the
## population is the consumer in a Rosenzweig-MacArthur consumer-resource
## system. Lean too hard on the herds and per-worker yield sags, growth stalls,
## and the herds get their breathing room back - the classic boom-and-slack
## cycle, which farming and then mining lift you out of.
##
## What the model deliberately does *not* do is punish. Refugia keep every
## stock from ever bottoming out, hunger throttles births far more than it
## costs lives, and the population can never fall below three quarters of its
## high-water mark. The curve wobbles; it always climbs.

signal state_changed
signal logged(entry: Dictionary)
signal tech_researched(id: String)
signal building_completed(id: String)
signal era_advanced(era: int)
signal game_reset

var world: CivWorld

var day: float = 0.0
var population: float = 6.0
## High-water mark, and the anchor for the never-lose floor.
var peak_population: float = 6.0
var speed_index: int = 1

var resources := {}
var rates := {}          ## Net per-day change, for the UI.
var production := {}     ## Gross per-day production, for the UI.
## Smoothed per-worker output each job is *actually* delivering. Potential
## yield over-promises whenever a stock is being worked down to its refuge
## floor, so planning on it would hire far more hunters than the herd can ever
## feed. This is what the allocator and the UI both read.
var _yield_ema := {}

var jobs := {}           ## job id -> assigned worker count (int)
var job_weights := {}    ## job id -> player priority 0..5
var auto_assign := true
## Whether the settlement builds for itself. On by default - see _auto_build().
var auto_build := true

var buildings := {}      ## building id -> completed count
var build_queue: Array[Dictionary] = []

var techs: Array[String] = []
var researching: String = ""
var auto_research := true

var era: int = 0
var log_entries: Array[Dictionary] = []

# Cached readouts the UI wants but should not recompute.
var food_satisfaction: float = 1.0
var water_satisfaction: float = 1.0
var carrying_capacity: float = 0.0
var housing: float = 0.0
var births_per_day: float = 0.0
var deaths_per_day: float = 0.0

# --- derived modifiers, rebuilt when techs/buildings change ---
var _mods_dirty := true
var _yield_mult := {}
var _storage := {}
var _spoilage_mult := 1.0
var _knowledge_mult := 1.0
var _farm_plots := 0.0
var _birth_mult := 1.0
var _territory_bonus := 0.0

var _last_gross := {}
var _accum := 0.0
var _assign_timer := 0.0
var _build_timer := 0.0
var _event_cooldown := 0.0
var _last_pop_int := 0
var _famine_latch := false


func _ready() -> void:
	if world == null:
		new_game(0)


func new_game(p_seed: int = 0) -> void:
	if p_seed == 0:
		p_seed = randi() % 1_000_000 + 1

	world = CivWorld.new()
	world.generate(p_seed)

	day = 0.0
	population = 6.0
	peak_population = 6.0
	speed_index = 1
	era = 0
	techs.clear()
	researching = ""
	build_queue.clear()
	log_entries.clear()
	_famine_latch = false
	_event_cooldown = Balance.EVENT_COOLDOWN_DAYS * 0.5

	resources = {}
	rates = {}
	production = {}
	for id in Balance.RESOURCE_ORDER:
		resources[id] = 0.0
		rates[id] = 0.0
		production[id] = 0.0
	resources["food"] = 20.0
	resources["water"] = 15.0
	resources["wood"] = 5.0

	buildings = {}
	for id in Balance.BUILDING_ORDER:
		buildings[id] = 0

	jobs = {}
	job_weights = {}
	_yield_ema = {}
	for id in Balance.JOB_ORDER:
		jobs[id] = 0
		job_weights[id] = 1.0
	job_weights["hunter"] = 2.0
	job_weights["forager"] = 2.0
	job_weights["water_carrier"] = 2.0

	_mods_dirty = true
	_rebuild_mods()
	_auto_assign_jobs()
	_last_pop_int = int(population)

	var biome_name: String = Balance.BIOME_INFO[world.biome[world.idx(world.origin.x, world.origin.y)]]["name"]
	add_log("Six of you stop walking. This place has water, and the grass is thick. It will do for now.", "era")
	add_log("The band makes camp on %s." % String(biome_name).to_lower(), "info")
	game_reset.emit()
	state_changed.emit()


func _process(delta: float) -> void:
	var speed: float = Balance.SPEEDS[speed_index]
	if speed <= 0.0:
		return
	advance(delta * speed / Balance.SECONDS_PER_DAY)


## Advance the simulation by `days`, in fixed substeps.
func advance(days: float) -> void:
	_accum += days
	var steps := 0
	while _accum >= Balance.STEP_DAYS and steps < Balance.MAX_STEPS_PER_FRAME:
		_accum -= Balance.STEP_DAYS
		_step(Balance.STEP_DAYS)
		steps += 1
	if steps > 0:
		state_changed.emit()


## Credit offline time. Runs uncapped substeps because it must actually finish.
func run_offline(days: float) -> void:
	var capped := minf(days, Balance.MAX_OFFLINE_HOURS * 3600.0 / Balance.SECONDS_PER_DAY)
	if capped <= 0.5:
		return
	var pop_before := population
	simulate_days(capped, true)
	add_log("While you were away: %d days passed, and the people went from %d to %d."
			% [int(capped), int(pop_before), int(population)], "info")
	state_changed.emit()


## Run `days` of simulation right now, ignoring the per-frame step cap. Used by
## offline catch-up and by the headless balance harness.
func simulate_days(days: float, quiet: bool = false) -> void:
	var steps := int(days / Balance.STEP_DAYS)
	var dt := Balance.STEP_DAYS
	# Coarser steps for very long spans so loading stays instant.
	if steps > 20000:
		dt = days / 20000.0
		steps = 20000
	for i in steps:
		_step(dt, quiet)


func _step(dt: float, offline: bool = false) -> void:
	if _mods_dirty:
		_rebuild_mods()

	day += dt

	world.territory_radius = clampf(
		Balance.BASE_TERRITORY_RADIUS + population * Balance.TERRITORY_PER_POP + _territory_bonus,
		Balance.BASE_TERRITORY_RADIUS, Balance.MAX_TERRITORY_RADIUS)
	world.refresh_territory()

	_assign_timer -= dt
	if auto_assign and (_assign_timer <= 0.0 or int(population) != _last_pop_int):
		_assign_timer = 0.5
		_last_pop_int = int(population)
		_auto_assign_jobs()

	_build_timer -= dt
	if auto_build and _build_timer <= 0.0:
		_build_timer = 1.0
		_auto_build()

	_ecology(dt)
	_produce(dt)
	_consume_and_grow(dt)
	_progress_builds(dt)
	_progress_research(dt)
	_apply_storage(dt)
	if not offline:
		_maybe_event(dt)
	_check_era()


# --- Ecology ----------------------------------------------------------------

## Logistic regrowth toward capacity, plus immigration from outside the
## territory so a collapsed stock can always recover.
func _ecology(dt: float) -> void:
	for i in world.territory:
		# Felling forest shrinks the game capacity that depends on it.
		var base_cap: float = world.game_cap[i]
		var cover := 1.0
		if world.forest_cap[i] > 0.01:
			cover = world.forest[i] / world.forest_cap[i]
		var cap: float = base_cap * (1.0 - Balance.HABITAT_WEIGHT + Balance.HABITAT_WEIGHT * cover)
		_grow(world.game, i, cap, Balance.GAME_REGROWTH, Balance.GAME_IMMIGRATION, dt)
		_grow(world.forage, i, world.forage_cap[i], Balance.FORAGE_REGROWTH, Balance.FORAGE_IMMIGRATION, dt)
		_grow(world.forest, i, world.forest_cap[i], Balance.FOREST_REGROWTH, Balance.FOREST_IMMIGRATION, dt)


func _grow(arr: PackedFloat32Array, i: int, cap: float, rate: float, immigration: float, dt: float) -> void:
	if cap <= 0.01:
		arr[i] = 0.0
		return
	var n: float = arr[i]
	var d: float = rate * n * (1.0 - n / cap) + immigration * (1.0 - n / cap)
	arr[i] = clampf(n + d * dt, 0.0, cap)


# --- Production -------------------------------------------------------------

## Holling type II: per-worker yield saturates with abundance and collapses
## with scarcity.
func _functional_response(stock: float, attack: float, handling: float) -> float:
	if stock <= 0.0:
		return 0.0
	return attack * stock / (1.0 + attack * handling * stock)


func _mult(kind: String) -> float:
	return float(_yield_mult.get(kind, 1.0))


func _produce(dt: float) -> void:
	for id in Balance.RESOURCE_ORDER:
		production[id] = 0.0

	var game_total := world.total_of(world.game)
	var forage_total := world.total_of(world.forage)
	var forest_total := world.total_of(world.forest)

	# Hunting
	var n_hunt: int = jobs.get("hunter", 0)
	if n_hunt > 0 and game_total > 0.0:
		var rate := _functional_response(game_total, Balance.HUNT_ATTACK_RATE, Balance.HUNT_HANDLING_TIME) \
				* n_hunt * _mult("game")
		var taken := world.drain(world.game, world.game_cap, rate * dt, game_total)
		_last_gross["hunter"] = taken / dt
		production["food"] += taken / dt
		production["hides"] += taken * 0.22 / dt
		resources["food"] += taken
		resources["hides"] += taken * 0.22

	# Foraging
	var n_forage: int = jobs.get("forager", 0)
	if n_forage > 0 and forage_total > 0.0:
		var rate2 := _functional_response(forage_total, Balance.FORAGE_ATTACK_RATE, Balance.FORAGE_HANDLING_TIME) \
				* n_forage * _mult("forage")
		var taken2 := world.drain(world.forage, world.forage_cap, rate2 * dt, forage_total)
		_last_gross["forager"] = taken2 / dt
		production["food"] += taken2 / dt
		resources["food"] += taken2

	# Woodcutting
	var n_wood: int = jobs.get("woodcutter", 0)
	if n_wood > 0 and forest_total > 0.0:
		var rate3 := _functional_response(forest_total, Balance.CHOP_ATTACK_RATE, Balance.CHOP_HANDLING_TIME) \
				* n_wood * _mult("forest")
		var taken3 := world.drain(world.forest, world.forest_cap, rate3 * dt, forest_total)
		_last_gross["woodcutter"] = taken3 / dt
		production["wood"] += taken3 / dt
		resources["wood"] += taken3

	# Water - not a depletable stock, but limited by how close water is.
	var n_water: int = jobs.get("water_carrier", 0)
	if n_water > 0:
		var access := world.total_water_access() / maxf(float(world.territory.size()), 1.0)
		var factor := clampf(access * 2.2, 0.15, 1.6)
		var w_rate := n_water * Balance.WATER_PER_CARRIER * factor * _mult("water")
		_last_gross["water_carrier"] = w_rate
		production["water"] += w_rate
		resources["water"] += w_rate * dt

	# Farming - the whole point of the tech tree. No wild stock involved.
	var n_farm: int = jobs.get("farmer", 0)
	if n_farm > 0 and _farm_plots > 0.0:
		var worked: float = minf(float(n_farm), _farm_plots)
		var fert := clampf(world.total_fertility() / maxf(float(world.territory.size()), 1.0), 0.2, 1.4)
		var f_rate := worked * Balance.FARM_YIELD_PER_PLOT * fert * _mult("farm")
		_last_gross["farmer"] = f_rate
		production["food"] += f_rate
		resources["food"] += f_rate * dt

	# Stone
	var n_stone: int = jobs.get("quarrier", 0)
	if n_stone > 0:
		var rock := clampf(world.total_stone() / maxf(float(world.territory.size()), 1.0), 0.05, 1.6)
		var s_rate := n_stone * Balance.STONE_PER_QUARRIER * rock * _mult("stone")
		_last_gross["quarrier"] = s_rate
		production["stone"] += s_rate
		resources["stone"] += s_rate * dt

	# Ore and gold. Seams are not depleted, so this is pure richness x labour -
	# the reliable industrial floor the whole late game is built on. What the
	# ore actually *is* depends on how far the civilisation has come.
	var n_mine: int = jobs.get("miner", 0)
	if n_mine > 0 and job_unlocked("miner"):
		var tiles := maxf(float(world.territory.size()), 1.0)
		var ore_rich := clampf(world.total_ore() / tiles, 0.02, 1.4)
		var gold_rich := clampf(world.total_gold() / tiles, 0.0, 0.8)
		var tier_value := float(Balance.ORE_TIERS[ore_tier()]["value"])
		var o_rate := n_mine * Balance.ORE_PER_MINER * ore_rich * tier_value * _mult("ore")
		var g_rate := n_mine * Balance.GOLD_PER_MINER * gold_rich * _mult("ore")
		_last_gross["miner"] = o_rate
		production["ore"] += o_rate
		production["gold"] += g_rate
		resources["ore"] += o_rate * dt
		resources["gold"] += g_rate * dt

	# Knowledge - ambient learning plus dedicated elders.
	var k_rate := Balance.AMBIENT_KNOWLEDGE * sqrt(maxf(population, 1.0))
	k_rate += float(jobs.get("thinker", 0)) * Balance.KNOWLEDGE_PER_THINKER
	k_rate *= _knowledge_mult
	production["knowledge"] += k_rate
	resources["knowledge"] += k_rate * dt

	# Feed the planner what actually happened, not what was hoped for.
	_track_yield("hunter", _last_gross.get("hunter", 0.0))
	_track_yield("forager", _last_gross.get("forager", 0.0))
	_track_yield("woodcutter", _last_gross.get("woodcutter", 0.0))
	_track_yield("water_carrier", _last_gross.get("water_carrier", 0.0))
	_track_yield("farmer", _last_gross.get("farmer", 0.0))
	_track_yield("quarrier", _last_gross.get("quarrier", 0.0))
	_track_yield("miner", _last_gross.get("miner", 0.0))
	_last_gross.clear()


# --- Population -------------------------------------------------------------

func _consume_and_grow(dt: float) -> void:
	var food_need := population * Balance.FOOD_PER_PERSON_PER_DAY * dt
	var water_need := population * Balance.WATER_PER_PERSON_PER_DAY * dt

	var food_got := minf(resources["food"], food_need)
	var water_got := minf(resources["water"], water_need)
	resources["food"] -= food_got
	resources["water"] -= water_got

	food_satisfaction = 1.0 if food_need <= 0.0 else food_got / food_need
	water_satisfaction = 1.0 if water_need <= 0.0 else water_got / water_need

	# Liebig's law of the minimum: the scarcest necessity sets the outcome.
	var need_score := minf(food_satisfaction, water_satisfaction)

	housing = _housing_total()
	var crowd := clampf((housing - population) / maxf(housing * Balance.CROWDING_SOFTNESS, 1.0), 0.0, 1.0)
	var larder := clampf(resources["food"] / maxf(population * 5.0, 1.0), 0.0, 1.0)
	var fertility := need_score * (0.35 + 0.65 * larder)

	births_per_day = Balance.BIRTH_RATE_MAX * population * fertility * crowd * _birth_mult
	var crowd_death := 0.0
	if population > housing and housing > 0.0:
		crowd_death = 0.012 * (population / housing - 1.0)
	deaths_per_day = (Balance.DEATH_RATE_BASE
			+ Balance.DEATH_RATE_STARVATION * pow(1.0 - need_score, 2.0)
			+ crowd_death) * population

	# The floor under everything. However bad a stretch gets, the settlement
	# holds and the line turns back up - the tribe never falls below three
	# quarters of the largest it has ever been. Hunger costs the player time and
	# momentum, never their civilisation.
	var floor_pop := maxf(Balance.MIN_POPULATION, peak_population * Balance.PEAK_FLOOR_FRACTION)
	population = maxf(floor_pop, population + (births_per_day - deaths_per_day) * dt)
	peak_population = maxf(peak_population, population)

	rates["food"] = production["food"] - population * Balance.FOOD_PER_PERSON_PER_DAY
	rates["water"] = production["water"] - population * Balance.WATER_PER_PERSON_PER_DAY
	for id in ["wood", "stone", "hides", "knowledge"]:
		rates[id] = production[id]

	# What this land can currently support - the K in dN/dt = rN(1 - N/K).
	# A full store means nobody is working that resource, which is not the same
	# as the land being unable to provide it: count it as covering the current
	# population rather than reading a misleading zero.
	var k_food: float = production["food"] / Balance.FOOD_PER_PERSON_PER_DAY
	var k_water: float = production["water"] / Balance.WATER_PER_PERSON_PER_DAY
	if resources["food"] > population * Balance.FOOD_PER_PERSON_PER_DAY * 2.0:
		k_food = maxf(k_food, population)
	if resources["water"] > population * Balance.WATER_PER_PERSON_PER_DAY * 2.0:
		k_water = maxf(k_water, population)
	carrying_capacity = minf(minf(k_food, k_water), housing)

	if need_score < Balance.FAMINE_THRESHOLD and not _famine_latch:
		_famine_latch = true
		if food_satisfaction <= water_satisfaction:
			add_log("There is not enough to eat. The hunting parties come back with less every day.", "bad")
		else:
			add_log("The water runs short. People are drinking from puddles.", "bad")
	elif need_score > 0.98 and _famine_latch:
		_famine_latch = false
		add_log("The hungry season passes. There is food again.", "good")


func _housing_total() -> float:
	var total := Balance.BASE_HOUSING
	for id in buildings:
		var count: int = buildings[id]
		if count <= 0:
			continue
		var eff: Dictionary = Balance.BUILDINGS[id]["effects"]
		total += float(eff.get("housing", 0.0)) * count
	return total


# --- Jobs -------------------------------------------------------------------

func workforce() -> int:
	return int(floor(population))


func assigned_total() -> int:
	var t := 0
	for id in jobs:
		t += int(jobs[id])
	return t


func idle_workers() -> int:
	return maxi(0, workforce() - assigned_total())


## Gross output one more worker in this job would produce per day, in that
## job's own units. Drives the "x each" readout, and makes the collapse of a
## hunted-out herd legible before the food bar starts falling.
func job_output_per_worker(id: String) -> float:
	if world == null:
		return 0.0
	match String(Balance.JOBS[id]["kind"]):
		"game":
			return _functional_response(world.total_of(world.game),
					Balance.HUNT_ATTACK_RATE, Balance.HUNT_HANDLING_TIME) * _mult("game")
		"forage":
			return _functional_response(world.total_of(world.forage),
					Balance.FORAGE_ATTACK_RATE, Balance.FORAGE_HANDLING_TIME) * _mult("forage")
		"forest":
			return _functional_response(world.total_of(world.forest),
					Balance.CHOP_ATTACK_RATE, Balance.CHOP_HANDLING_TIME) * _mult("forest")
		"water":
			var access := world.total_water_access() / maxf(float(world.territory.size()), 1.0)
			return Balance.WATER_PER_CARRIER * clampf(access * 2.2, 0.15, 1.6) * _mult("water")
		"farm":
			var fert := clampf(world.total_fertility() / maxf(float(world.territory.size()), 1.0), 0.2, 1.4)
			return Balance.FARM_YIELD_PER_PLOT * fert * _mult("farm")
		"stone":
			var rock := clampf(world.total_stone() / maxf(float(world.territory.size()), 1.0), 0.05, 1.6)
			return Balance.STONE_PER_QUARRIER * rock * _mult("stone")
		"ore":
			var tiles := maxf(float(world.territory.size()), 1.0)
			var ore_rich := clampf(world.total_ore() / tiles, 0.02, 1.4)
			return Balance.ORE_PER_MINER * ore_rich \
					* float(Balance.ORE_TIERS[ore_tier()]["value"]) * _mult("ore")
		"knowledge":
			return Balance.KNOWLEDGE_PER_THINKER * _knowledge_mult
		"build":
			return Balance.BUILDER_WORK_PER_DAY
	return 0.0


## Index of the best ore the civilisation currently knows how to work. The rock
## does not change - the people do.
func ore_tier() -> int:
	var best := 0
	for i in Balance.ORE_TIERS.size():
		var req: String = Balance.ORE_TIERS[i]["requires"]
		if req == "" or techs.has(req):
			best = i
	return best


func ore_name() -> String:
	if not job_unlocked("miner"):
		return "Ore"
	return String(Balance.ORE_TIERS[ore_tier()]["name"])


## Total current output of everyone assigned to a job, per day.
func job_output(id: String) -> float:
	var n: float = float(jobs.get(id, 0))
	if String(Balance.JOBS[id]["kind"]) == "farm":
		n = minf(n, _farm_plots)
	return job_yield_planned(id) * n


## Per-worker yield to plan around: what the job has actually been delivering,
## smoothed. Falls back to the theoretical figure for jobs nobody is doing yet.
func job_yield_planned(id: String) -> float:
	if _yield_ema.has(id):
		return maxf(0.0, float(_yield_ema[id]))
	return job_output_per_worker(id)


func _track_yield(id: String, gross: float) -> void:
	var n: int = jobs.get(id, 0)
	# With nobody assigned there is no evidence to learn from, so drift back
	# toward the theoretical figure - otherwise a job once abandoned would look
	# worthless forever and never be picked up again.
	var per: float = gross / float(n) if n > 0 else job_output_per_worker(id)
	_yield_ema[id] = lerpf(float(_yield_ema.get(id, per)), per, 0.08)


func job_unlocked(id: String) -> bool:
	var req: String = Balance.JOBS[id]["requires"]
	return req == "" or techs.has(req)


func set_job(id: String, count: int) -> void:
	var current: int = jobs.get(id, 0)
	var free := idle_workers() + current
	jobs[id] = clampi(count, 0, free)
	state_changed.emit()


## True when a store is effectively full, so nobody is sent to top it up.
## This is what lets the forest grow back: once the woodsheds are full the
## woodcutters stop, and 0.012/day regrowth finally gets ahead of the axes.
func _at_cap(id: String) -> bool:
	var cap := capacity_of(id)
	return cap > 0.0 and resources[id] >= cap * 0.98


## Need-driven allocation. Water first, then a food mix chosen by each job's
## *current* per-worker yield - which is what makes the tribe drift off hunting
## as the herds thin out, and abandon it outright once they are gone.
func _auto_assign_jobs() -> void:
	var total := workforce()
	for id in Balance.JOB_ORDER:
		jobs[id] = 0
	if total <= 0:
		return
	var left := total

	# --- 1. Water. Push harder when the jars are nearly dry, ease off when full.
	var y_water := job_yield_planned("water_carrier")
	var draw := population * Balance.WATER_PER_PERSON_PER_DAY
	var water_days: float = resources["water"] / maxf(draw, 0.01)
	var water_target := draw
	if water_days > 4.0:
		water_target = draw * 0.5
	elif water_days < 1.0:
		water_target = draw * 1.35
	if _at_cap("water"):
		water_target = 0.0
	var n_water := 0
	if y_water > 0.0 and water_target > 0.0:
		n_water = clampi(int(ceil(water_target / y_water)), 1, maxi(1, total / 2))
	n_water = mini(n_water, left)
	jobs["water_carrier"] = n_water
	left -= n_water

	# --- 2. Food. Decide the mix, then hire enough people to actually hit the
	# target with that mix - sizing off the best single job under-hires.
	var y_hunt := job_yield_planned("hunter")
	var y_forage := job_yield_planned("forager")
	var y_farm := 0.0
	if job_unlocked("farmer") and _farm_plots > 0.0:
		y_farm = job_yield_planned("farmer")

	var best := maxf(maxf(y_hunt, y_forage), y_farm)
	# Ignore any food job yielding under a tenth of the best. A hunted-out herd
	# should empty the hunting camp, not keep it staffed out of habit.
	var floor_y := best * 0.10
	var wh := 0.0
	var wf := 0.0
	if y_hunt >= floor_y and y_hunt > 0.0:
		wh = y_hunt * y_hunt * float(job_weights.get("hunter", 1.0))
	if y_forage >= floor_y and y_forage > 0.0:
		wf = y_forage * y_forage * float(job_weights.get("forager", 1.0))
	var wsum := wh + wf

	var eat := population * Balance.FOOD_PER_PERSON_PER_DAY
	var food_days: float = resources["food"] / maxf(eat, 0.01)
	var food_target := eat * 1.25
	if food_days > 12.0:
		food_target = eat * 0.9
	elif food_days > 6.0:
		food_target = eat * 1.1
	if _at_cap("food"):
		food_target = eat * 0.75

	# Hold a few hands back from the food quest. A tribe that puts every last
	# pair of hands on hunting can never build the thing that would end the
	# hunger - which is precisely how a subsistence trap closes, and precisely
	# the trap an idle game must never leave the player sitting in. The cost is
	# a slightly smaller population; the payoff is that the tribe keeps
	# climbing.
	var reserve := 0
	if total >= 6:
		reserve = clampi(int(round(total * 0.12)), 1, 16)
	var food_pool := maxi(1, left - reserve)

	# Farms are limited by how many plots exist, so fill them before sizing
	# anything else. Planning as if farmers were unlimited makes the estimate of
	# what one more worker yields far too rosy and badly under-hires the hunting
	# and foraging that has to cover the gap.
	var n_farm := 0
	if y_farm > 0.0 and _farm_plots >= 1.0:
		n_farm = clampi(int(ceil(food_target / y_farm)), 0, mini(int(_farm_plots), food_pool))
		jobs["farmer"] = n_farm
		left -= n_farm
	var remaining := maxf(0.0, food_target - float(n_farm) * y_farm)

	if wsum > 0.0 and remaining > 0.0 and left > 0:
		# What one more wild-food worker yields on average in this mix.
		var blended := (wh * y_hunt + wf * y_forage) / wsum
		if blended > 0.0:
			var n_wild := clampi(int(ceil(remaining / blended)), 1,
					mini(left, maxi(1, food_pool - n_farm)))
			var n_hunt := clampi(int(round(n_wild * wh / maxf(wh + wf, 0.0001))), 0, n_wild)
			jobs["hunter"] = n_hunt
			jobs["forager"] = n_wild - n_hunt
			left -= n_wild

	# --- 3. Builders while there is anything queued.
	if not build_queue.is_empty() and left > 0:
		var n_build := clampi(int(round(left * 0.5)), 1, left)
		jobs["builder"] = n_build
		left -= n_build

	# --- 4. Everyone else, skipping anything whose store is already full.
	# If there is genuinely nothing worth doing, people stay idle rather than
	# strip-mining a landscape for resources that will only rot.
	if left > 0:
		var support: Array[String] = []
		if not _at_cap("wood"):
			support.append("woodcutter")
		if job_unlocked("quarrier") and not _at_cap("stone"):
			support.append("quarrier")
		if job_unlocked("miner") and not (_at_cap("ore") and _at_cap("gold")):
			support.append("miner")
		# Knowledge is never capped, but it is worthless once the tech tree is
		# finished - do not park hundreds of people on it out of habit.
		if job_unlocked("thinker") and (researching != "" or _cheapest_available() != ""):
			support.append("thinker")
		if not support.is_empty():
			var sw := 0.0
			for id in support:
				sw += float(job_weights.get(id, 1.0))
			var handed := 0
			for i in support.size():
				var id: String = support[i]
				var n := 0
				if i == support.size() - 1:
					n = left - handed
				else:
					n = int(floor(left * float(job_weights.get(id, 1.0)) / maxf(sw, 0.001)))
				n = maxi(0, n)
				jobs[id] = int(jobs.get(id, 0)) + n
				handed += n

	# --- 5. Never let a small band get wood-locked. The fire pit and the first
	# windbreaks are the bottom rung of the ladder, and if every pair of hands
	# is on food forever the band sits at subsistence and never climbs it.
	if int(jobs["woodcutter"]) == 0 and resources["wood"] < 20.0 and total >= 4 and food_days > 3.0:
		for donor in ["forager", "hunter"]:
			if int(jobs[donor]) > 1:
				jobs[donor] = int(jobs[donor]) - 1
				jobs["woodcutter"] = 1
				break


# --- Building ---------------------------------------------------------------

func can_build(id: String) -> bool:
	var b: Dictionary = Balance.BUILDINGS[id]
	if b["requires"] != "" and not techs.has(b["requires"]):
		return false
	if built_and_queued(id) >= int(b["max"]):
		return false
	for res in b["cost"]:
		if resources.get(res, 0.0) < float(b["cost"][res]):
			return false
	return true


func building_unlocked(id: String) -> bool:
	var req: String = Balance.BUILDINGS[id]["requires"]
	return req == "" or techs.has(req)


func built_and_queued(id: String) -> int:
	var n: int = buildings.get(id, 0)
	for o in build_queue:
		if o["id"] == id:
			n += 1
	return n


func queue_building(id: String) -> bool:
	if not can_build(id):
		return false
	var b: Dictionary = Balance.BUILDINGS[id]
	for res in b["cost"]:
		resources[res] -= float(b["cost"][res])
	build_queue.append({"id": id, "work": 0.0, "total": float(b["work"])})
	if auto_assign:
		_auto_assign_jobs()
	state_changed.emit()
	return true


func cancel_order(index: int) -> void:
	if index < 0 or index >= build_queue.size():
		return
	var order: Dictionary = build_queue[index]
	var b: Dictionary = Balance.BUILDINGS[order["id"]]
	# Refund what has not been worked into the ground yet.
	var refund := 1.0 - clampf(float(order["work"]) / maxf(float(order["total"]), 0.01), 0.0, 1.0) * 0.5
	for res in b["cost"]:
		resources[res] += float(b["cost"][res]) * refund
	build_queue.remove_at(index)
	state_changed.emit()


## What the settlement builds when left to its own devices.
##
## This is not a convenience - it is the game. Nobody is watching an idle game
## most of the time, and a civilisation that only grows while a player is
## clicking the Build tab is not a civilisation that grows. Turning this off in
## the Build tab hands every decision back.
func _auto_build() -> void:
	if build_queue.size() >= 2:
		return
	for id in _build_priority():
		if can_build(id):
			queue_building(id)
			return


func _build_priority() -> Array[String]:
	var list: Array[String] = []
	# A hearth first, always: cheap, and it improves everything that follows.
	list.append("firepit")

	# Best shelter the age can manage, whenever the place is filling up - but
	# only while the land can actually feed the people already in it. Housing
	# that outruns food just parks everyone at subsistence on the never-lose
	# floor, which looks like growth and is not.
	var shelter: Array[String] = ["stone_house", "longhouse", "hut", "windbreak"]
	var fed := carrying_capacity >= population * 0.95
	if population > housing * 0.75 and fed:
		list.append_array(shelter)

	# Fields, up to roughly one plot per four mouths.
	if job_unlocked("farmer") and _farm_plots < population * 0.25:
		list.append("farm_plot")

	# Storage, but only for whatever is actually overflowing right now.
	if _at_cap("food"):
		list.append_array(["granary", "drying_rack"])
	if _at_cap("wood"):
		list.append("woodshed")
	if _at_cap("stone"):
		list.append("quarry")
	if _at_cap("ore"):
		list.append("mine")

	# Production and the long-run multipliers.
	list.append_array(["mine", "well", "quarry", "smelter", "shrine", "treasury", "farm_plot"])

	# Nothing pressing? Then more room to grow.
	list.append_array(shelter)
	return list


func _progress_builds(dt: float) -> void:
	if build_queue.is_empty():
		return
	var work: float = float(jobs.get("builder", 0)) * Balance.BUILDER_WORK_PER_DAY * dt
	if work <= 0.0:
		return
	var order: Dictionary = build_queue[0]
	order["work"] = float(order["work"]) + work
	if float(order["work"]) >= float(order["total"]):
		var id: String = order["id"]
		build_queue.pop_front()
		buildings[id] = int(buildings.get(id, 0)) + 1
		_mods_dirty = true
		add_log("%s finished." % Balance.BUILDINGS[id]["name"], "good")
		building_completed.emit(id)


# --- Research ---------------------------------------------------------------

func tech_available(id: String) -> bool:
	if techs.has(id):
		return false
	for req in Balance.TECHS[id]["requires"]:
		if not techs.has(req):
			return false
	return true


func set_research(id: String) -> void:
	if id != "" and not tech_available(id):
		return
	researching = id
	auto_research = false
	state_changed.emit()


func _progress_research(_dt: float) -> void:
	if researching == "" or techs.has(researching):
		researching = ""
		if auto_research:
			researching = _cheapest_available()
		if researching == "":
			return
	var cost := float(Balance.TECHS[researching]["cost"])
	if resources["knowledge"] >= cost:
		resources["knowledge"] -= cost
		_complete_tech(researching)
		researching = _cheapest_available() if auto_research else ""


func _cheapest_available() -> String:
	var best := ""
	var best_cost := INF
	for id in Balance.TECH_ORDER:
		if tech_available(id) and float(Balance.TECHS[id]["cost"]) < best_cost:
			best_cost = float(Balance.TECHS[id]["cost"])
			best = id
	return best


func _complete_tech(id: String) -> void:
	var _ore_tier_before := ore_tier()
	techs.append(id)
	_mods_dirty = true
	var t: Dictionary = Balance.TECHS[id]
	add_log("%s: %s" % [t["name"], t["desc"]], "tech")
	if _ore_tier_before != ore_tier():
		var tier: Dictionary = Balance.ORE_TIERS[ore_tier()]
		add_log("The seams give up %s now. %s" % [String(tier["name"]).to_lower(), tier["note"]], "good")
	tech_researched.emit(id)
	if auto_assign:
		_auto_assign_jobs()


# --- Storage & modifiers ----------------------------------------------------

func capacity_of(id: String) -> float:
	var base := float(Balance.RESOURCES[id]["base_cap"])
	if base <= 0.0:
		return 0.0 # uncapped
	return base + float(_storage.get(id, 0.0))


func _apply_storage(dt: float) -> void:
	for id in Balance.RESOURCE_ORDER:
		var spoil := float(Balance.RESOURCES[id]["spoilage"])
		if spoil > 0.0:
			var m: float = _spoilage_mult if id == "food" else 1.0
			resources[id] = maxf(0.0, resources[id] * (1.0 - spoil * m * dt))
		var cap := capacity_of(id)
		if cap > 0.0 and resources[id] > cap:
			resources[id] = cap


func _rebuild_mods() -> void:
	_mods_dirty = false
	_yield_mult = {}
	_storage = {}
	_spoilage_mult = 1.0
	_knowledge_mult = 1.0
	_farm_plots = 0.0
	_birth_mult = 1.0
	_territory_bonus = 0.0

	for id in techs:
		_apply_effects(Balance.TECHS[id]["effects"], 1)
	for id in buildings:
		var count: int = buildings[id]
		if count > 0:
			_apply_effects(Balance.BUILDINGS[id]["effects"], count)


func _apply_effects(eff: Dictionary, count: int) -> void:
	for key in eff:
		match key:
			"yield_mult":
				for kind in eff[key]:
					var m := pow(float(eff[key][kind]), count)
					_yield_mult[kind] = float(_yield_mult.get(kind, 1.0)) * m
			"storage":
				for res in eff[key]:
					_storage[res] = float(_storage.get(res, 0.0)) + float(eff[key][res]) * count
			"spoilage_mult":
				_spoilage_mult *= pow(float(eff[key]), count)
			"knowledge_mult":
				_knowledge_mult *= pow(float(eff[key]), count)
			"farm_plots":
				_farm_plots += float(eff[key]) * count
			"birth_mult":
				_birth_mult *= pow(float(eff[key]), count)
			"territory":
				_territory_bonus += float(eff[key]) * count


func farm_plots() -> float:
	return _farm_plots


# --- Eras -------------------------------------------------------------------

func _check_era() -> void:
	var next := era + 1
	if next >= Balance.ERAS.size():
		return
	var e: Dictionary = Balance.ERAS[next]
	if techs.size() >= int(e["techs"]) and population >= float(e["pop"]):
		era = next
		add_log("Your people are now a %s." % e["name"], "era")
		era_advanced.emit(era)


func era_name() -> String:
	return Balance.ERAS[era]["name"]


# --- Events -----------------------------------------------------------------

const EVENTS := [
	{"id": "drought", "text": "A dry season. The river is low and the grass is brittle."},
	{"id": "harsh_winter", "text": "A hard winter. The herds go thin and so do you."},
	{"id": "good_year", "text": "A good year. Everything is fat and the berries hang heavy."},
	{"id": "wolves", "text": "Wolves work the same herds you do. There is less to find."},
	{"id": "sickness", "text": "A sickness moves through the camp. It passes."},
	{"id": "rich_seam", "text": "A rockfall opens a seam nobody knew was there."},
	{"id": "placer_gold", "text": "A child finds bright grains in the shallows of the river."},
	{"id": "migrants", "text": "Strangers walk in from the hills and ask to stay."},
	{"id": "windfall", "text": "A storm brings down a stand of old timber."},
]


func _maybe_event(dt: float) -> void:
	_event_cooldown -= dt
	if _event_cooldown > 0.0:
		return
	if randf() > Balance.EVENT_CHANCE_PER_DAY * dt:
		return
	_event_cooldown = Balance.EVENT_COOLDOWN_DAYS
	var e: Dictionary = EVENTS[randi() % EVENTS.size()]
	match e["id"]:
		"drought":
			resources["water"] *= 0.45
			_scale_stock(world.forage, 0.75)
			add_log(e["text"], "bad")
		"harsh_winter":
			resources["food"] *= 0.7
			_scale_stock(world.game, 0.7)
			add_log(e["text"], "bad")
		"good_year":
			_scale_stock(world.game, 1.3)
			_scale_stock(world.forage, 1.4)
			add_log(e["text"], "good")
		"wolves":
			_scale_stock(world.game, 0.72)
			add_log(e["text"], "bad")
		"sickness":
			population = maxf(Balance.MIN_POPULATION, population * 0.94)
			add_log(e["text"], "bad")
		"rich_seam":
			if job_unlocked("miner"):
				resources["ore"] += 30.0 + population * 0.5
				add_log(e["text"], "good")
			else:
				resources["stone"] += 20.0 + population * 0.3
				add_log("A rockfall leaves good building stone lying loose.", "good")
		"placer_gold":
			resources["gold"] += 8.0 + population * 0.12
			add_log(e["text"], "good")
		"migrants":
			var joiners := maxf(2.0, population * 0.12)
			population += joiners
			add_log("%s %d of them join the band." % [e["text"], int(joiners)], "good")
		"windfall":
			resources["wood"] += 25.0 + population
			add_log(e["text"], "good")


func _scale_stock(arr: PackedFloat32Array, factor: float) -> void:
	for i in world.territory:
		arr[i] *= factor


# --- Log --------------------------------------------------------------------

func add_log(text: String, kind: String = "info") -> void:
	var entry := {"day": int(day), "text": text, "kind": kind}
	log_entries.append(entry)
	if log_entries.size() > 80:
		log_entries.remove_at(0)
	logged.emit(entry)


# --- Save / load ------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"version": Balance.SAVE_VERSION,
		"day": day,
		"population": population,
		"peak_population": peak_population,
		"era": era,
		"resources": resources.duplicate(),
		"jobs": jobs.duplicate(),
		"job_weights": job_weights.duplicate(),
		"auto_assign": auto_assign,
		"auto_build": auto_build,
		"auto_research": auto_research,
		"buildings": buildings.duplicate(),
		"build_queue": build_queue.duplicate(true),
		"techs": techs.duplicate(),
		"researching": researching,
		"world": world.to_dict(),
		"log": log_entries.slice(maxi(0, log_entries.size() - 25)),
	}


func from_dict(d: Dictionary) -> void:
	new_game(int((d.get("world", {}) as Dictionary).get("seed", 1)))

	day = float(d.get("day", 0.0))
	population = float(d.get("population", 6.0))
	peak_population = maxf(population, float(d.get("peak_population", population)))
	era = int(d.get("era", 0))
	auto_assign = bool(d.get("auto_assign", true))
	auto_build = bool(d.get("auto_build", true))
	auto_research = bool(d.get("auto_research", true))
	researching = String(d.get("researching", ""))

	for id in Balance.RESOURCE_ORDER:
		resources[id] = float((d.get("resources", {}) as Dictionary).get(id, 0.0))
	for id in Balance.JOB_ORDER:
		jobs[id] = int((d.get("jobs", {}) as Dictionary).get(id, 0))
		job_weights[id] = float((d.get("job_weights", {}) as Dictionary).get(id, 1.0))
	for id in Balance.BUILDING_ORDER:
		buildings[id] = int((d.get("buildings", {}) as Dictionary).get(id, 0))

	techs.clear()
	for t in d.get("techs", []):
		if Balance.TECHS.has(t):
			techs.append(String(t))

	build_queue.clear()
	for o in d.get("build_queue", []):
		if o is Dictionary and Balance.BUILDINGS.has(o.get("id", "")):
			build_queue.append({
				"id": String(o["id"]),
				"work": float(o.get("work", 0.0)),
				"total": float(o.get("total", 1.0)),
			})

	log_entries.clear()
	for e in d.get("log", []):
		if e is Dictionary:
			log_entries.append(e)

	world.from_dict(d.get("world", {}))
	_mods_dirty = true
	_rebuild_mods()
	game_reset.emit()
	state_changed.emit()
