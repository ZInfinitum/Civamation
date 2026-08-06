extends Node
## The simulation. Owns all game state and advances it in fixed steps.
##
## The ecology is a real model: wild stocks regrow logistically (Verhulst),
## workers harvest them through a Holling type II functional response, and the
## population is the consumer in a Rosenzweig-MacArthur consumer-resource
## system. Lean too hard on the herds and per-worker yield sags, growth stalls,
## and the herds get their breathing room back.
##
## What the model deliberately does *not* do is punish. Refugia keep every stock
## from bottoming out, hunger throttles births far more than it costs lives, and
## the population can never fall below three quarters of its high-water mark.
## The curve wobbles; it always climbs.
##
## Layered on top is an idler economy: geometric building costs against linear
## output, with upgrades that double a whole trade outright. There is always a
## next purchase and nothing ever hard-caps.

signal state_changed
signal logged(entry: Dictionary)
signal tech_researched(id: String)
signal upgrade_bought(id: String)
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

var jobs := {}           ## job id -> assigned worker count (int)
var job_weights := {}    ## job id -> player priority 0..5
## Most workers a job has ever held. Upgrade unlocks read this rather than the
## live count, so a momentary reshuffle cannot un-offer an upgrade.
var job_peak := {}
## Everything a trade has ever produced. Drives upgrade unlocks - see
## Balance.UPGRADE_TIERS for why it is this and not headcount.
var job_lifetime := {}
var auto_assign := true
var auto_build := true
var auto_research := true
var auto_upgrade := true

var buildings := {}      ## building id -> completed count
var build_queue: Array[Dictionary] = []

var techs: Array[String] = []
var upgrades: Array[String] = []
var researching: String = ""

var era: int = 0
var log_entries: Array[Dictionary] = []

# Cached readouts the UI wants but should not recompute.
var food_satisfaction: float = 1.0
var water_satisfaction: float = 1.0
var carrying_capacity: float = 0.0
var housing: float = 0.0
var births_per_day: float = 0.0
var deaths_per_day: float = 0.0
var tiles_explored_per_day: float = 0.0

# --- derived modifiers, rebuilt when techs/buildings/upgrades change ---
var _mods_dirty := true
var _yield_mult := {}
var _storage := {}
var _spoilage_mult := 1.0
var _knowledge_mult := 1.0
var _farm_plots := 0.0
var _mine_slots := 0.0
var _quarry_slots := 0.0
var _woodlot_slots := 0.0
var _birth_mult := 1.0
var _territory_bonus := 0.0

## Smoothed per-worker output each job is actually delivering. Potential yield
## over-promises whenever a stock is being worked down to its refuge floor, so
## planning on it would hire far more hunters than the herd can ever feed.
var _yield_ema := {}
var _last_gross := {}

# Living-stock territory totals, recomputed once per step by _ecology and
# adjusted by drain. Recomputing these per use was most of the cost on a big map.
var _total_game := 0.0
var _total_forage := 0.0
var _total_forest := 0.0

## How much of each material the settlement wants in hand before it stops
## gathering, recomputed on the housekeeping tick from what it could build.
var _stock_targets := {}
## Last pass's assignment, so saturation can be judged against a real crew.
var _prev_jobs := {}
var _explore_progress := 0.0
var _seen_biomes: Array[int] = []
var _milestone := 0

var _accum := 0.0
var _assign_timer := 0.0
var _build_timer := 0.0
var _event_cooldown := 0.0
var _last_pop_int := 0
var _famine_latch := false


func _ready() -> void:
	if world == null:
		new_game(0)


func new_game(p_seed: int = 0, p_type: int = Balance.WorldType.EARTH) -> void:
	if p_seed == 0:
		p_seed = randi() % 1_000_000 + 1

	world = CivWorld.new()
	world.generate(p_seed, p_type)

	day = 0.0
	population = 6.0
	peak_population = 6.0
	speed_index = 1
	era = 0
	techs.clear()
	upgrades.clear()
	researching = ""
	build_queue.clear()
	log_entries.clear()
	_famine_latch = false
	_event_cooldown = Balance.EVENT_COOLDOWN_DAYS * 0.5
	_explore_progress = 0.0
	_seen_biomes.clear()
	_milestone = 0

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
	job_peak = {}
	job_lifetime = {}
	_yield_ema = {}
	for id in Balance.JOB_ORDER:
		jobs[id] = 0
		job_weights[id] = 1.0
		job_peak[id] = 0
		job_lifetime[id] = 0.0
	job_weights["hunter"] = 2.0
	job_weights["forager"] = 2.0
	job_weights["water_carrier"] = 2.0
	job_weights["explorer"] = 2.0

	_mods_dirty = true
	_rebuild_mods()
	_auto_assign_jobs()
	_last_pop_int = int(population)

	var here: String = Balance.BIOME_INFO[world.biome[world.idx(world.origin.x, world.origin.y)]]["name"]
	_seen_biomes.append(world.biome[world.idx(world.origin.x, world.origin.y)])
	add_log("Six of you stop walking. This place has water, and the grass is thick. It will do for now.", "era")
	add_log("The band makes camp on %s. Nobody here knows what is over the next ridge." % String(here).to_lower(), "info")
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


## Credit offline time. Runs the real simulation rather than approximating it.
func run_offline(days: float) -> void:
	var capped := minf(days, Balance.MAX_OFFLINE_HOURS * 3600.0 / Balance.SECONDS_PER_DAY)
	if capped <= 0.5:
		return
	var pop_before := population
	simulate_days(capped, true)
	add_log("While you were away: %d days passed, and the people went from %s to %s."
			% [int(capped), Balance.fmt_count(pop_before), Balance.fmt_count(population)], "info")
	state_changed.emit()


## Run `days` right now, ignoring the per-frame step cap. Long spans use longer
## steps rather than more of them, bounded so the integration stays stable.
func simulate_days(days: float, quiet: bool = false) -> void:
	var dt := Balance.STEP_DAYS
	var steps := int(days / dt)
	if steps > Balance.MAX_OFFLINE_STEPS:
		dt = minf(days / float(Balance.MAX_OFFLINE_STEPS), Balance.MAX_OFFLINE_STEP_DAYS)
		steps = mini(int(days / dt), Balance.MAX_OFFLINE_STEPS)
	for i in steps:
		_step(dt, quiet)


func _step(dt: float, offline: bool = false) -> void:
	if _mods_dirty:
		_rebuild_mods()

	day += dt
	_update_territory()

	_assign_timer -= dt
	if auto_assign and (_assign_timer <= 0.0 or int(population) != _last_pop_int):
		_assign_timer = 0.5
		_last_pop_int = int(population)
		_auto_assign_jobs()

	# One shared once-a-day tick for the two housekeeping autopilots. Neither
	# needs substep resolution and both allocate, so this keeps them off the
	# hot path entirely.
	_build_timer -= dt
	var housekeep := _build_timer <= 0.0
	if housekeep:
		_build_timer = 1.0
		_recompute_stock_targets()
		if auto_build:
			_auto_build()
		_daily_world_tick()

	_explore(dt, offline)
	_ecology(dt)
	_produce(dt)
	_consume_and_grow(dt)
	_progress_builds(dt)
	_progress_research(dt)
	if auto_upgrade and housekeep:
		_auto_buy_upgrade()
	_apply_storage(dt)
	if not offline:
		_maybe_event(dt)
	if Settings.disasters:
		_maybe_disaster(dt, offline)
	_check_era()
	_check_milestones(offline)


## The worked land grows with the population and with technology, but never
## past where somebody has actually walked. That gate is the entire reason
## explorers exist.
func _update_territory() -> void:
	var want := Balance.BASE_TERRITORY_RADIUS + population * Balance.TERRITORY_PER_POP + _territory_bonus
	var walked := world.explored_radius - Balance.CLAIM_MARGIN
	world.territory_radius = clampf(minf(want, walked),
			Balance.BASE_TERRITORY_RADIUS, Balance.MAX_TERRITORY_RADIUS)
	world.refresh_territory()


## True when the settlement wants more land than it has been shown - the signal
## that explorers are the bottleneck right now.
func expansion_blocked_by_exploration() -> bool:
	if world.territory_radius >= Balance.MAX_TERRITORY_RADIUS:
		return false
	if not world.frontier_open():
		return false
	var want := Balance.BASE_TERRITORY_RADIUS + population * Balance.TERRITORY_PER_POP + _territory_bonus
	return want > world.explored_radius - Balance.CLAIM_MARGIN


# --- Exploration ------------------------------------------------------------

func _explore(dt: float, offline: bool) -> void:
	var n: int = jobs.get("explorer", 0)
	tiles_explored_per_day = float(n) * Balance.EXPLORE_PER_SCOUT * _mult("explore")
	if n <= 0:
		return

	resources["knowledge"] += float(n) * Balance.KNOWLEDGE_PER_SCOUT * _knowledge_mult * dt
	_explore_progress += tiles_explored_per_day * dt

	var revealed := 0
	while _explore_progress >= 1.0 and revealed < Balance.MAX_REVEALS_PER_STEP:
		_explore_progress -= 1.0
		var i := world.reveal_one()
		if i < 0:
			_explore_progress = 0.0
			break
		revealed += 1
		_on_revealed(i, offline)
	if revealed > 0:
		# Newly walked ground can widen the claim immediately.
		_update_territory()


## Something worth mentioning happens when explorers see a kind of country
## nobody has seen before, or walk into unusually rich ground.
func _on_revealed(i: int, offline: bool) -> void:
	var b: int = world.biome[i]
	if not _seen_biomes.has(b):
		_seen_biomes.append(b)
		var info: Dictionary = Balance.BIOME_INFO[b]
		var reward := 10.0 + float(_seen_biomes.size()) * 8.0
		resources["knowledge"] += reward
		if not offline:
			add_log("The scouts come back talking about %s. Nobody here had seen it before."
					% String(info["name"]).to_lower(), "tech")
		return

	if offline:
		return
	if world.gold[i] > 0.30:
		resources["gold"] += 6.0 + population * 0.05
		add_log("Bright grains in a streambed out past the frontier.", "good")
	elif world.ore[i] > 1.10:
		resources["ore"] += 12.0 + population * 0.08
		add_log("A seam breaks the surface on a hillside the scouts just mapped.", "good")


## Once-a-day upkeep of the things the map shows but the economy does not run
## on: where the animals are, and who can currently see what.
func _daily_world_tick() -> void:
	if not Settings.reduce_motion:
		world.step_animals(int(float(Balance.MAX_ANIMALS) / Balance.ANIMAL_MOVE_DAYS))
	world.refresh_visibility(_scout_tiles(), 2)


## Roughly where the explorers have got to - the head of the frontier queue.
func _scout_tiles() -> PackedInt32Array:
	var out := PackedInt32Array()
	if int(jobs.get("explorer", 0)) <= 0:
		return out
	var k: int = world._frontier_head
	var step := maxi(1, (world.frontier.size() - k) / 5)
	while k < world.frontier.size() and out.size() < 5:
		out.append(world.frontier[k])
		k += step
	return out


# --- Disasters --------------------------------------------------------------
## Opt-in, and bounded: the never-lose floor sits underneath all of these, so
## the worst one costs a season of momentum rather than the settlement.

var _disaster_cooldown := Balance.DISASTER_INTERVAL_DAYS


func _maybe_disaster(dt: float, offline: bool) -> void:
	_disaster_cooldown -= dt
	if _disaster_cooldown > 0.0:
		return
	_disaster_cooldown = Balance.DISASTER_INTERVAL_DAYS * randf_range(0.6, 1.5)

	var choices: Array[String] = []
	for id in Balance.DISASTERS:
		if _disaster_possible(String(Balance.DISASTERS[id]["needs"])):
			choices.append(id)
	if choices.is_empty():
		return
	var pick: String = choices[randi() % choices.size()]
	var d: Dictionary = Balance.DISASTERS[pick]

	match pick:
		"forest_fire":
			# Burns standing timber, which turns wooded tiles into clearings via
			# the ordinary cover rule - no special case needed.
			_scale_stock(world.forest, world.forest_cap, 0.45)
			_scale_stock(world.game, world.game_cap, 0.75)
			resources["wood"] *= 0.7
		"flood":
			resources["food"] *= 0.55
			_scale_stock(world.forage, world.forage_cap, 0.7)
			# Silt: the one disaster the land is better for afterwards.
			for i in world.territory:
				world.fertility[i] = minf(world.fertility[i] * 1.06, 2.0)
			world.refresh_territory(true)
		"hurricane":
			resources["food"] *= 0.7
			resources["wood"] *= 0.55
			_wreck_buildings(2)
		"tornado":
			_wreck_buildings(3)
			population = maxf(Balance.MIN_POPULATION, population * 0.97)

	if not offline:
		add_log("%s. %s" % [d["name"], d["text"]], "bad")


func _disaster_possible(needs: String) -> bool:
	match needs:
		"forest":
			return world.stock_health(world.forest, world.forest_cap) > 0.35
		"water":
			return world.terr_water_access > float(world.territory.size()) * 0.15
		"coast":
			for i in world.territory:
				if world.biome[i] == Balance.Biome.COAST or world.biome[i] == Balance.Biome.OCEAN:
					return true
			return false
		"open":
			return population > 20.0
	return true


## Flatten a few of the flimsiest things standing. Never the last of anything,
## and never something the settlement cannot rebuild.
func _wreck_buildings(count: int) -> void:
	var order: Array[String] = ["windbreak", "drying_rack", "scout_camp", "hut",
			"woodshed", "farm_plot", "longhouse"]
	var wrecked := 0
	for id in order:
		if wrecked >= count:
			break
		if int(buildings.get(id, 0)) > 0:
			buildings[id] = int(buildings[id]) - 1
			wrecked += 1
	if wrecked > 0:
		_mods_dirty = true


# --- Ecology ----------------------------------------------------------------

## Logistic regrowth toward capacity plus immigration from beyond the territory,
## so a hard-worked stock always recovers. Also the one pass that recomputes the
## living-stock totals the rest of the step reads.
func _ecology(dt: float) -> void:
	var tg := 0.0
	var tf := 0.0
	var tw := 0.0
	for i in world.territory:
		# Felling forest costs wildlife some habitat, but never all of it.
		var cover := 1.0
		if world.forest_cap[i] > 0.01:
			cover = world.forest[i] / world.forest_cap[i]
		var cap: float = world.game_cap[i] * (1.0 - Balance.HABITAT_WEIGHT + Balance.HABITAT_WEIGHT * cover)
		tg += _grow(world.game, i, cap, Balance.GAME_REGROWTH, Balance.GAME_IMMIGRATION, dt)
		tf += _grow(world.forage, i, world.forage_cap[i], Balance.FORAGE_REGROWTH, Balance.FORAGE_IMMIGRATION, dt)
		tw += _grow(world.forest, i, world.forest_cap[i], Balance.FOREST_REGROWTH, Balance.FOREST_IMMIGRATION, dt)
		# One comparison per worked tile: woodland that has been cut flat turns
		# into a clearing, and turns back once the trees are up again.
		world.update_cover(i)
	_total_game = tg
	_total_forage = tf
	_total_forest = tw


func _grow(arr: PackedFloat32Array, i: int, cap: float, rate: float, immigration: float, dt: float) -> float:
	if cap <= 0.01:
		arr[i] = 0.0
		return 0.0
	var n: float = arr[i]
	var d: float = rate * n * (1.0 - n / cap) + immigration * (1.0 - n / cap)
	var v := clampf(n + d * dt, 0.0, cap)
	arr[i] = v
	return v


# --- Production -------------------------------------------------------------

## Holling type II: per-worker yield saturates with abundance and falls away
## with scarcity.
func _functional_response(stock: float, attack: float, handling: float) -> float:
	if stock <= 0.0:
		return 0.0
	return attack * stock / (1.0 + attack * handling * stock)


func _mult(kind: String) -> float:
	return float(_yield_mult.get(kind, 1.0))


func _tile_avg(total: float) -> float:
	return total / maxf(float(world.territory.size()), 1.0)


func _produce(dt: float) -> void:
	for id in Balance.RESOURCE_ORDER:
		production[id] = 0.0

	# Hunting
	var n_hunt: int = jobs.get("hunter", 0)
	if n_hunt > 0 and _total_game > 0.0:
		var rate := _functional_response(_total_game, Balance.HUNT_ATTACK_RATE,
				Balance.HUNT_HANDLING_TIME) * n_hunt * _mult("game")
		var taken := world.drain(world.game, world.game_cap, rate * dt, _total_game, world.terr_game_refuge)
		_total_game -= taken
		_last_gross["hunter"] = taken / dt
		production["food"] += taken / dt
		production["hides"] += taken * 0.22 / dt
		resources["food"] += taken
		resources["hides"] += taken * 0.22

	# Foraging
	var n_forage: int = jobs.get("forager", 0)
	if n_forage > 0 and _total_forage > 0.0:
		var rate2 := _functional_response(_total_forage, Balance.FORAGE_ATTACK_RATE,
				Balance.FORAGE_HANDLING_TIME) * n_forage * _mult("forage")
		var taken2 := world.drain(world.forage, world.forage_cap, rate2 * dt, _total_forage, world.terr_forage_refuge)
		_total_forage -= taken2
		_last_gross["forager"] = taken2 / dt
		production["food"] += taken2 / dt
		resources["food"] += taken2

	# Woodcutting
	var n_wood: int = jobs.get("woodcutter", 0)
	if n_wood > 0 and _total_forest > 0.0:
		var rate3 := _functional_response(_total_forest, Balance.CHOP_ATTACK_RATE,
				Balance.CHOP_HANDLING_TIME) * n_wood * _mult("forest")
		var taken3 := world.drain(world.forest, world.forest_cap, rate3 * dt, _total_forest, world.terr_forest_refuge)
		_total_forest -= taken3
		_last_gross["woodcutter"] = taken3 / dt
		production["wood"] += taken3 / dt
		resources["wood"] += taken3

	# Water. Not a depletable stock, but limited by how close water is.
	var n_water: int = jobs.get("water_carrier", 0)
	if n_water > 0:
		var w_rate := n_water * _water_per_worker()
		_last_gross["water_carrier"] = w_rate
		production["water"] += w_rate
		resources["water"] += w_rate * dt

	# Farming. The whole point of the tech tree: no wild stock involved.
	var n_farm: int = mini(jobs.get("farmer", 0), int(_farm_plots))
	if n_farm > 0:
		var f_rate := n_farm * _farm_per_worker()
		_last_gross["farmer"] = f_rate
		production["food"] += f_rate
		resources["food"] += f_rate * dt

	# Managed timber. Like farming, this ignores the wild stock entirely - which
	# is how the late game stops being permanently short of wood.
	var n_timber: int = mini(jobs.get("forester", 0), int(_woodlot_slots))
	if n_timber > 0:
		var t_rate := n_timber * _timber_per_worker()
		_last_gross["forester"] = t_rate
		production["wood"] += t_rate
		resources["wood"] += t_rate * dt

	# Stone
	var n_stone: int = mini(jobs.get("quarrier", 0), int(_quarry_slots))
	if n_stone > 0:
		var s_rate := n_stone * _stone_per_worker()
		_last_gross["quarrier"] = s_rate
		production["stone"] += s_rate
		resources["stone"] += s_rate * dt

	# Ore and gold. Seams never run dry, so this is the reliable industrial
	# floor the whole late game rests on.
	var n_mine: int = mini(jobs.get("miner", 0), int(_mine_slots))
	if n_mine > 0:
		var o_rate := n_mine * _ore_per_worker()
		var g_rate := n_mine * Balance.GOLD_PER_MINER \
				* clampf(_tile_avg(world.terr_gold), 0.0, 0.8) * _mult("ore")
		_last_gross["miner"] = o_rate
		production["ore"] += o_rate
		production["gold"] += g_rate
		resources["ore"] += o_rate * dt
		resources["gold"] += g_rate * dt

	# Knowledge: ambient learning plus dedicated elders.
	var k_rate := Balance.AMBIENT_KNOWLEDGE * sqrt(maxf(population, 1.0))
	k_rate += float(jobs.get("thinker", 0)) * Balance.KNOWLEDGE_PER_THINKER * _mult("knowledge")
	k_rate *= _knowledge_mult
	_last_gross["thinker"] = float(jobs.get("thinker", 0)) * Balance.KNOWLEDGE_PER_THINKER \
			* _mult("knowledge") * _knowledge_mult
	production["knowledge"] += k_rate
	resources["knowledge"] += k_rate * dt

	for id in ["hunter", "forager", "woodcutter", "water_carrier", "farmer",
			"forester", "quarrier", "miner", "thinker"]:
		_track_yield(id, float(_last_gross.get(id, 0.0)), dt)
	_last_gross.clear()


func _water_per_worker() -> float:
	# The floor matters more than it looks. A settlement that draws a dry site
	# was putting half its people on water and still coming up short, which
	# cripples a run through no decision the player made. Even a bad site has a
	# soak or a spring: carrying is slow, never futile.
	var access := _tile_avg(world.terr_water_access)
	return Balance.WATER_PER_CARRIER * clampf(access * 2.2, 0.45, 1.6) * _mult("water")


func _farm_per_worker() -> float:
	var fert := clampf(_tile_avg(world.terr_fertility), 0.2, 1.4)
	return Balance.FARM_YIELD_PER_PLOT * fert * _mult("farm")


func _stone_per_worker() -> float:
	var rock := clampf(_tile_avg(world.terr_stone), 0.05, 1.8)
	return Balance.STONE_PER_QUARRIER * rock * _mult("stone")


func _ore_per_worker() -> float:
	var rich := clampf(_tile_avg(world.terr_ore), 0.02, 1.5)
	return Balance.ORE_PER_MINER * rich * float(Balance.ORE_TIERS[ore_tier()]["value"]) * _mult("ore")


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
	# holds and the line turns back up. Hunger costs the player time and
	# momentum, never their civilisation.
	var floor_pop := maxf(Balance.MIN_POPULATION, peak_population * Balance.PEAK_FLOOR_FRACTION)
	population = maxf(floor_pop, population + (births_per_day - deaths_per_day) * dt)
	peak_population = maxf(peak_population, population)

	rates["food"] = production["food"] - population * Balance.FOOD_PER_PERSON_PER_DAY
	rates["water"] = production["water"] - population * Balance.WATER_PER_PERSON_PER_DAY
	for id in ["wood", "stone", "hides", "ore", "gold", "knowledge"]:
		rates[id] = production[id]

	# What this land can currently support - the K in dN/dt = rN(1 - N/K). A
	# well-stocked store means the land is covering the need whatever today's
	# work assignment happens to look like, so do not read a misleading zero.
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
			add_log("There is not enough to eat. The work parties come back with less every day.", "bad")
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


func _check_milestones(offline: bool) -> void:
	while _milestone < Balance.MILESTONES.size():
		var m: Dictionary = Balance.MILESTONES[_milestone]
		if population < float(m["pop"]):
			return
		_milestone += 1
		if not offline:
			add_log(String(m["text"]), "era")


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


func job_unlocked(id: String) -> bool:
	var req: String = Balance.JOBS[id]["requires"]
	return req == "" or techs.has(req)


## How many people this job can usefully take. Farms, mines and quarries need
## somewhere to stand; the rest are limited only by the population.
func job_capacity(id: String) -> int:
	match String(Balance.JOBS[id]["kind"]):
		"farm": return int(_farm_plots)
		"ore": return int(_mine_slots)
		"stone": return int(_quarry_slots)
		"timber": return int(_woodlot_slots)
	return workforce()


func set_job(id: String, count: int) -> void:
	var current: int = jobs.get(id, 0)
	var free := idle_workers() + current
	jobs[id] = clampi(count, 0, free)
	job_peak[id] = maxi(int(job_peak.get(id, 0)), int(jobs[id]))
	state_changed.emit()


## Gross output one worker in this job would produce per day, in that job's own
## units. Theoretical - see job_yield_planned for what to actually plan on.
func job_output_per_worker(id: String) -> float:
	if world == null:
		return 0.0
	match String(Balance.JOBS[id]["kind"]):
		"game":
			return _functional_response(_total_game, Balance.HUNT_ATTACK_RATE,
					Balance.HUNT_HANDLING_TIME) * _mult("game")
		"forage":
			return _functional_response(_total_forage, Balance.FORAGE_ATTACK_RATE,
					Balance.FORAGE_HANDLING_TIME) * _mult("forage")
		"forest":
			return _functional_response(_total_forest, Balance.CHOP_ATTACK_RATE,
					Balance.CHOP_HANDLING_TIME) * _mult("forest")
		"water": return _water_per_worker()
		"farm": return _farm_per_worker()
		"stone": return _stone_per_worker()
		"timber": return _timber_per_worker()
		"ore": return _ore_per_worker()
		"explore": return Balance.EXPLORE_PER_SCOUT * _mult("explore")
		"knowledge": return Balance.KNOWLEDGE_PER_THINKER * _mult("knowledge") * _knowledge_mult
		"build": return Balance.BUILDER_WORK_PER_DAY * _mult("build")
	return 0.0


## Total current output of everyone assigned to a job, per day.
func job_output(id: String) -> float:
	var n: float = float(mini(int(jobs.get(id, 0)), job_capacity(id)))
	return job_yield_planned(id) * n


## Per-worker yield to plan around: what the job has actually been delivering,
## smoothed. Falls back to the theoretical figure for jobs nobody is doing yet.
func job_yield_planned(id: String) -> float:
	if _yield_ema.has(id):
		return maxf(0.0, float(_yield_ema[id]))
	return job_output_per_worker(id)


func _track_yield(id: String, gross: float, dt: float = 0.0) -> void:
	if gross > 0.0 and dt > 0.0:
		job_lifetime[id] = float(job_lifetime.get(id, 0.0)) + gross * dt
	var n: int = mini(int(jobs.get(id, 0)), job_capacity(id))
	# With nobody assigned there is no evidence to learn from, so drift back
	# toward the theoretical figure - otherwise a job once abandoned would look
	# worthless forever and never be picked up again.
	var per: float = gross / float(n) if n > 0 else job_output_per_worker(id)
	_yield_ema[id] = lerpf(float(_yield_ema.get(id, per)), per, 0.08)


## How much of a material is "enough". With no storage ceilings this cannot be
## "the barn is full" any more, so it is: hold a couple of the priciest thing
## you could currently build with it. That scales itself as costs climb, and it
## is what still lets the forest grow back - once there is more timber than any
## project needs, the axes stop.
func _recompute_stock_targets() -> void:
	for res in Balance.RESOURCE_ORDER:
		_stock_targets[res] = Balance.STOCK_TARGET_FLOOR
	for id in Balance.BUILDING_ORDER:
		if not building_unlocked(id):
			continue
		var cap := building_max(id)
		if cap > 0 and built_and_queued(id) >= cap:
			continue
		var cost := cost_of(id)
		for res in cost:
			var want := float(cost[res]) * Balance.STOCK_TARGET_MULTIPLE
			if want > float(_stock_targets.get(res, 0.0)):
				_stock_targets[res] = want


## True when there is plainly enough of something, so nobody is sent to fetch
## more. Perishables are measured in days of supply; materials against what
## there is to spend them on.
func _well_stocked(id: String) -> bool:
	match id:
		"knowledge":
			return false
		"food":
			return resources["food"] >= population * Balance.FOOD_PER_PERSON_PER_DAY * 25.0
		"water":
			return resources["water"] >= population * Balance.WATER_PER_PERSON_PER_DAY * 12.0
	if _stock_targets.is_empty():
		_recompute_stock_targets()
	return resources[id] >= float(_stock_targets.get(id, Balance.STOCK_TARGET_FLOOR))


## Which store a gathering job fills.
func _job_resource(id: String) -> String:
	match String(Balance.JOBS[id]["kind"]):
		"forest": return "wood"
		"timber": return "wood"
		"stone": return "stone"
		"ore": return "ore"
	return "wood"


## Workers past this point are standing in each other's way. A wild stock can
## only give up so much a day however many hands you send at it, and the
## realised yield per worker is what tells you that has happened - so ratchet
## the crew down until each of them is earning their place again.
func _saturation_cap(id: String) -> int:
	var theory := job_output_per_worker(id)
	var real := job_yield_planned(id)
	# The crew as it was before this pass cleared the board - reading the live
	# figure here always saw zero, so the cap never once applied.
	var n := int(_prev_jobs.get(id, 0))
	if n <= 1 or theory <= 0.0:
		return 1000000
	if real >= theory * 0.6:
		return 1000000
	return maxi(1, int(float(n) * 0.9))


## Need-driven allocation. Water first, then a food mix chosen by each job's
## *current* per-worker yield - which is what makes the tribe drift off hunting
## as the herds thin out, and abandon it outright once they are gone.
func _auto_assign_jobs() -> void:
	var total := workforce()
	_prev_jobs = jobs.duplicate()
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
	if _well_stocked("water"):
		water_target = 0.0
	var n_water := 0
	if y_water > 0.0 and water_target > 0.0:
		n_water = clampi(int(ceil(water_target / y_water)), 1, maxi(1, total / 2))
	n_water = mini(n_water, left)
	jobs["water_carrier"] = n_water
	left -= n_water

	# --- 2. Food.
	var y_hunt := job_yield_planned("hunter")
	var y_forage := job_yield_planned("forager")
	var y_farm := 0.0
	if job_unlocked("farmer") and _farm_plots >= 1.0:
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
	if _well_stocked("food"):
		food_target = eat * 0.75

	# Hold a few hands back from the food quest. A tribe that puts every last
	# pair of hands on hunting can never build the thing that would end the
	# hunger - which is precisely how a subsistence trap closes, and precisely
	# the trap an idle game must never leave the player sitting in.
	var reserve := 0
	if total >= 6:
		reserve = clampi(int(round(total * 0.12)), 1, 40)
	var food_pool := maxi(1, left - reserve)

	# Farms are limited by how many plots exist, so fill them before sizing
	# anything else. Planning as if farmers were unlimited makes the estimate of
	# what one more worker yields far too rosy and under-hires everyone else.
	var n_farm := 0
	if y_farm > 0.0:
		n_farm = clampi(int(ceil(food_target / y_farm)), 0, mini(int(_farm_plots), food_pool))
		jobs["farmer"] = n_farm
		left -= n_farm
	var remaining := maxf(0.0, food_target - float(n_farm) * y_farm)

	if wsum > 0.0 and remaining > 0.0 and left > 0:
		var blended := (wh * y_hunt + wf * y_forage) / wsum
		if blended > 0.0:
			var n_wild := clampi(int(ceil(remaining / blended)), 1,
					mini(left, maxi(1, food_pool - n_farm)))
			var n_hunt := clampi(int(round(n_wild * wh / maxf(wh + wf, 0.0001))), 0, n_wild)
			jobs["hunter"] = n_hunt
			jobs["forager"] = n_wild - n_hunt
			left -= n_wild

	# --- 3. Explorers, whenever the settlement wants land it has not been shown.
	# This is a hard bottleneck rather than a nice-to-have, so it gets staffed
	# before the ordinary support trades.
	if left > 0 and world.frontier_open():
		var n_scout := 0
		if expansion_blocked_by_exploration():
			n_scout = clampi(int(round(float(total) * 0.10)), 1, left)
		elif world.explored_fraction() < 0.9:
			# Not urgent, but a couple of people out mapping is never wasted.
			n_scout = mini(maxi(1, int(float(total) * 0.02)), left)
		jobs["explorer"] = n_scout
		left -= n_scout

	# --- 4. Builders while there is anything queued.
	if not build_queue.is_empty() and left > 0:
		var n_build := clampi(int(round(left * 0.5)), 1, left)
		jobs["builder"] = n_build
		left -= n_build

	# --- 5. Everyone else: sized by what is actually needed, and by whether
	# another pair of hands would achieve anything. Dividing the leftovers
	# evenly put nine hundred people on a forest that could not give up another
	# stick - busy, and completely pointless.
	if left > 0:
		for id in ["forester", "woodcutter", "quarrier", "miner"]:
			if left <= 0:
				break
			if not job_unlocked(id) or _well_stocked(_job_resource(id)):
				continue
			var slots := job_capacity(id)
			if slots <= 0:
				continue
			var y := job_yield_planned(id)
			if y <= 0.0001:
				continue
			var short: float = maxf(0.0, float(_stock_targets.get(_job_resource(id),
					Balance.STOCK_TARGET_FLOOR)) - resources[_job_resource(id)])
			# Fill the shortfall over about ten days rather than all at once.
			var want := int(ceil(short / (y * 10.0)))
			want = mini(mini(want, slots), _saturation_cap(id))
			# No single gathering trade takes more than a quarter of everybody.
			want = mini(want, maxi(1, int(float(total) * 0.25)))
			want = clampi(want, 0, left)
			jobs[id] = int(jobs.get(id, 0)) + want
			left -= want

		# Knowledge is never full and never wasted while there is anything left
		# to learn or buy, so it soaks up whoever is spare.
		if left > 0 and job_unlocked("thinker") and (researching != ""
				or _cheapest_available() != "" or _next_upgrade() != ""):
			jobs["thinker"] = int(jobs.get("thinker", 0)) + left
			left = 0

	# --- 6. Never let a small band get wood-locked. The fire pit and the first
	# windbreaks are the bottom rung of the ladder, and if every pair of hands is
	# on food forever the band sits at subsistence and never climbs it.
	if int(jobs["woodcutter"]) == 0 and resources["wood"] < 20.0 and total >= 4 and food_days > 3.0:
		for donor in ["forager", "hunter"]:
			if int(jobs[donor]) > 1:
				jobs[donor] = int(jobs[donor]) - 1
				jobs["woodcutter"] = 1
				break

	for id in Balance.JOB_ORDER:
		job_peak[id] = maxi(int(job_peak.get(id, 0)), int(jobs[id]))


# --- Building ---------------------------------------------------------------

## The nth of anything costs `base x growth^n`. Geometric costs against linear
## output is the engine of the whole economy: the next one is always a little
## further away, which is what makes an upgrade that doubles a trade feel like
## an event rather than a rounding error.
func cost_of(id: String, extra: int = 0) -> Dictionary:
	var b: Dictionary = Balance.BUILDINGS[id]
	var owned := built_and_queued(id) + extra
	var growth := float(b.get("growth", Balance.DEFAULT_COST_GROWTH))
	var scale := pow(growth, float(owned))
	var out := {}
	for res in b["cost"]:
		out[res] = float(b["cost"][res]) * scale
	return out


func building_max(id: String) -> int:
	# Absent means uncapped, which is most of them.
	return int(Balance.BUILDINGS[id].get("max", 0))


func can_build(id: String) -> bool:
	if not building_unlocked(id):
		return false
	var cap := building_max(id)
	if cap > 0 and built_and_queued(id) >= cap:
		return false
	var cost := cost_of(id)
	for res in cost:
		if resources.get(res, 0.0) < float(cost[res]):
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
	var cost := cost_of(id)
	for res in cost:
		resources[res] -= float(cost[res])
	build_queue.append({"id": id, "work": 0.0, "total": float(Balance.BUILDINGS[id]["work"])})
	if auto_assign:
		_auto_assign_jobs()
	state_changed.emit()
	return true


func cancel_order(index: int) -> void:
	if index < 0 or index >= build_queue.size():
		return
	var order: Dictionary = build_queue[index]
	var id: String = order["id"]
	# Refund against what this one actually cost, less whatever has already been
	# worked into the ground.
	var owned := built_and_queued(id) - 1
	var b: Dictionary = Balance.BUILDINGS[id]
	var growth := float(b.get("growth", Balance.DEFAULT_COST_GROWTH))
	var scale := pow(growth, float(maxi(0, owned)))
	var progress := clampf(float(order["work"]) / maxf(float(order["total"]), 0.01), 0.0, 1.0)
	for res in b["cost"]:
		resources[res] += float(b["cost"][res]) * scale * (1.0 - progress * 0.5)
	build_queue.remove_at(index)
	state_changed.emit()


func _progress_builds(dt: float) -> void:
	if build_queue.is_empty():
		return
	var work: float = float(jobs.get("builder", 0)) * Balance.BUILDER_WORK_PER_DAY * _mult("build") * dt
	if work <= 0.0:
		return
	var order: Dictionary = build_queue[0]
	order["work"] = float(order["work"]) + work
	if float(order["work"]) >= float(order["total"]):
		var id: String = order["id"]
		build_queue.pop_front()
		buildings[id] = int(buildings.get(id, 0)) + 1
		_mods_dirty = true
		add_log("%s finished (%d)." % [Balance.BUILDINGS[id]["name"], buildings[id]], "good")
		building_completed.emit(id)


## What the settlement builds when left to its own devices.
##
## This is not a convenience - it is the game. Nobody is watching an idle game
## most of the time, and a civilisation that only grows while somebody is
## clicking the Build tab is not a civilisation that grows.
func _auto_build() -> void:
	if build_queue.size() >= 2:
		return
	for id in _build_priority():
		if can_build(id):
			queue_building(id)
			return


func _build_priority() -> Array[String]:
	var list: Array[String] = []
	list.append("firepit")

	# Somewhere for explorers to work out of, early, because exploration gates
	# every other kind of expansion.
	if expansion_blocked_by_exploration():
		list.append("scout_camp")

	# Best shelter the age can manage when the place is filling up - but only
	# while the land can feed the people already in it. Housing that outruns
	# food parks everyone at subsistence on the never-lose floor, which looks
	# like growth and is not.
	var shelter: Array[String] = ["stone_house", "longhouse", "hut", "windbreak"]
	var fed := carrying_capacity >= population * 0.95
	if population > housing * 0.75 and fed:
		list.append_array(shelter)

	# Work slots for the trades that need somewhere to stand.
	if job_unlocked("farmer") and _farm_plots < population * 0.30:
		list.append("farm_plot")
	if job_unlocked("forester") and _woodlot_slots < population * 0.12:
		list.append("woodlot")
	if job_unlocked("miner") and _mine_slots < population * 0.10:
		list.append("mine")
	if job_unlocked("quarrier") and _quarry_slots < population * 0.08:
		list.append("quarry")

	# Storage, but only for what is actually overflowing right now.
	if _well_stocked("food"):
		list.append_array(["granary", "drying_rack"])
	if _well_stocked("wood"):
		list.append("woodshed")

	list.append_array(["great_hall", "smelter", "shrine", "treasury", "well",
			"scout_camp", "mine", "quarry", "farm_plot", "woodlot"])
	list.append_array(shelter)
	return list


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


func research_cost() -> float:
	if researching == "":
		return 0.0
	return float(Balance.TECHS[researching]["cost"])


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
	var tier_before := ore_tier()
	techs.append(id)
	_mods_dirty = true
	_rebuild_mods()
	var t: Dictionary = Balance.TECHS[id]
	add_log("%s: %s" % [t["name"], t["desc"]], "tech")
	if ore_tier() != tier_before:
		var tier: Dictionary = Balance.ORE_TIERS[ore_tier()]
		add_log("The seams give up %s now. %s" % [String(tier["name"]).to_lower(), tier["note"]], "good")
	tech_researched.emit(id)
	if auto_assign:
		_auto_assign_jobs()


# --- Upgrades ---------------------------------------------------------------

## Upgrade ids are "<job kind>_<tier>". Each doubles that trade's output, and
## unlocks once enough people have ever worked it. Buildings creep; upgrades
## jump - which is what keeps a geometric cost curve from grinding to a halt.
func upgrade_id(kind: String, tier: int) -> String:
	return "%s_%d" % [kind, tier]


func upgrade_name(id: String) -> String:
	var parts := id.rsplit("_", true, 1)
	if parts.size() != 2:
		return id
	var names: Array = Balance.UPGRADE_NAMES.get(parts[0], [])
	var tier := int(parts[1])
	if tier < names.size():
		return String(names[tier])
	return "%s improvement %d" % [parts[0].capitalize(), tier + 1]


func upgrade_cost(id: String) -> float:
	var parts := id.rsplit("_", true, 1)
	if parts.size() != 2:
		return INF
	var tier := int(parts[1])
	if tier >= Balance.UPGRADE_TIERS.size():
		return INF
	return float(Balance.UPGRADE_TIERS[tier]["cost"])


## Which job kind an upgrade improves, and the job that shows it.
func upgrade_job(id: String) -> String:
	var kind := id.rsplit("_", true, 1)[0]
	for job_id in Balance.JOB_ORDER:
		if String(Balance.JOBS[job_id]["kind"]) == kind:
			return job_id
	return ""


## Every upgrade currently offered: unlocked by headcount, not yet bought.
func available_upgrades() -> Array[String]:
	var out: Array[String] = []
	for job_id in Balance.JOB_ORDER:
		if not job_unlocked(job_id):
			continue
		var kind := String(Balance.JOBS[job_id]["kind"])
		var made := float(job_lifetime.get(job_id, 0.0))
		for tier in Balance.UPGRADE_TIERS.size():
			if made < float(Balance.UPGRADE_TIERS[tier]["output"]):
				break # tiers are ordered, so nothing further is unlocked either
			var id := upgrade_id(kind, tier)
			if upgrades.has(id):
				continue
			out.append(id)
	return out


## Cheapest offered upgrade, without allocating the full offered list - this
## runs on the housekeeping tick and in the job planner.
func _next_upgrade() -> String:
	var best := ""
	var best_cost := INF
	for job_id in Balance.JOB_ORDER:
		if not job_unlocked(job_id):
			continue
		var kind := String(Balance.JOBS[job_id]["kind"])
		var made := float(job_lifetime.get(job_id, 0.0))
		for tier in Balance.UPGRADE_TIERS.size():
			if made < float(Balance.UPGRADE_TIERS[tier]["output"]):
				break # tiers are ordered, so nothing beyond this is unlocked
			var id := upgrade_id(kind, tier)
			if upgrades.has(id):
				continue
			var c := float(Balance.UPGRADE_TIERS[tier]["cost"])
			if c < best_cost:
				best_cost = c
				best = id
	return best


## Unlocked by headcount and not yet bought.
func upgrade_offered(id: String) -> bool:
	if upgrades.has(id):
		return false
	var parts := id.rsplit("_", true, 1)
	if parts.size() != 2:
		return false
	var tier := int(parts[1])
	if tier < 0 or tier >= Balance.UPGRADE_TIERS.size():
		return false
	var job_id := upgrade_job(id)
	if job_id == "" or not job_unlocked(job_id):
		return false
	return float(job_lifetime.get(job_id, 0.0)) >= float(Balance.UPGRADE_TIERS[tier]["output"])


func buy_upgrade(id: String) -> bool:
	if upgrades.has(id) or not upgrade_offered(id):
		return false
	var cost := upgrade_cost(id)
	if resources["knowledge"] < cost:
		return false
	resources["knowledge"] -= cost
	upgrades.append(id)
	_mods_dirty = true
	_rebuild_mods()
	add_log("%s. %s work twice as well now." % [upgrade_name(id),
			Balance.JOBS[upgrade_job(id)]["name"]], "tech")
	upgrade_bought.emit(id)
	state_changed.emit()
	return true


## Buy the cheapest offered upgrade, but never at the cost of stalling the
## current research - techs open new systems and upgrades only scale old ones.
func _auto_buy_upgrade() -> void:
	var id := _next_upgrade()
	if id == "":
		return
	var cost := upgrade_cost(id)
	var reserved := research_cost() if researching != "" else 0.0
	if resources["knowledge"] >= cost + reserved:
		buy_upgrade(id)


# --- Storage & modifiers ----------------------------------------------------

func capacity_of(id: String) -> float:
	var base := float(Balance.RESOURCES[id]["base_cap"])
	if base <= 0.0:
		return 0.0 # uncapped
	return base + float(_storage.get(id, 0.0))


## Spoilage only - nothing has a ceiling. Decay is what keeps perishables
## honest, and it bounds them all by itself: a store settles where daily
## production equals daily loss, which scales with the economy for free.
func _apply_storage(dt: float) -> void:
	for id in Balance.RESOURCE_ORDER:
		var spoil := float(Balance.RESOURCES[id]["spoilage"])
		if spoil <= 0.0:
			continue
		var m: float = _spoilage_mult if id == "food" else 1.0
		resources[id] = maxf(0.0, resources[id] * (1.0 - spoil * m * dt))


func _rebuild_mods() -> void:
	_mods_dirty = false
	_yield_mult = {}
	_storage = {}
	_spoilage_mult = 1.0
	_knowledge_mult = 1.0
	_farm_plots = 0.0
	_mine_slots = 0.0
	_quarry_slots = 0.0
	_woodlot_slots = 0.0
	_birth_mult = 1.0
	_territory_bonus = 0.0

	for id in techs:
		_apply_effects(Balance.TECHS[id]["effects"], 1)
	for id in buildings:
		var count: int = buildings[id]
		if count > 0:
			_apply_effects(Balance.BUILDINGS[id]["effects"], count)
	for id in upgrades:
		var kind := id.rsplit("_", true, 1)[0]
		_yield_mult[kind] = float(_yield_mult.get(kind, 1.0)) * Balance.UPGRADE_MULT

	# Spoilage is a product of fractions and would otherwise reach zero with
	# enough granaries. Food should always be perishable, just less so.
	_spoilage_mult = maxf(_spoilage_mult, 0.12)

	if world != null:
		var water_before := world.can_cross_water
		var mtn_before := world.can_cross_mountains
		world.can_cross_water = techs.has("seafaring")
		world.can_cross_mountains = techs.has("mountain_paths")
		if world.can_cross_water != water_before or world.can_cross_mountains != mtn_before:
			# Ground that was a wall a moment ago is now a route.
			world.rebuild_frontier()
			world.refresh_territory(true)


func _apply_effects(eff: Dictionary, count: int) -> void:
	for key in eff:
		match key:
			"yield_mult":
				for kind in eff[key]:
					_yield_mult[kind] = float(_yield_mult.get(kind, 1.0)) * pow(float(eff[key][kind]), count)
			"storage":
				for res in eff[key]:
					_storage[res] = float(_storage.get(res, 0.0)) + float(eff[key][res]) * count
			"spoilage_mult":
				_spoilage_mult *= pow(float(eff[key]), count)
			"knowledge_mult":
				_knowledge_mult *= pow(float(eff[key]), count)
			"farm_plots":
				_farm_plots += float(eff[key]) * count
			"mine_slots":
				_mine_slots += float(eff[key]) * count
			"quarry_slots":
				_quarry_slots += float(eff[key]) * count
			"woodlot_slots":
				_woodlot_slots += float(eff[key]) * count
			"birth_mult":
				_birth_mult *= pow(float(eff[key]), count)
			"territory":
				_territory_bonus += float(eff[key]) * count


func farm_plots() -> float:
	return _farm_plots


func mine_slots() -> float:
	return _mine_slots


func quarry_slots() -> float:
	return _quarry_slots


func woodlot_slots() -> float:
	return _woodlot_slots


func _timber_per_worker() -> float:
	return Balance.TIMBER_YIELD_PER_LOT * _mult("timber") * _mult("forest")


func yield_mult(kind: String) -> float:
	return _mult(kind)


## Index of the best ore the civilisation knows how to work. The rock does not
## change - the people do.
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
	{"id": "migrants", "text": "Strangers walk in from the hills and ask to stay."},
	{"id": "windfall", "text": "A storm brings down a stand of old timber."},
	{"id": "rich_seam", "text": "A rockfall opens a seam nobody knew was there."},
	{"id": "placer_gold", "text": "A child finds bright grains in the shallows of the river."},
	{"id": "wanderer", "text": "A wanderer stops for a night and talks until dawn about places nobody here has been."},
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
			_scale_stock(world.forage, world.forage_cap, 0.75)
			add_log(e["text"], "bad")
		"harsh_winter":
			resources["food"] *= 0.7
			_scale_stock(world.game, world.game_cap, 0.7)
			add_log(e["text"], "bad")
		"good_year":
			_scale_stock(world.game, world.game_cap, 1.3)
			_scale_stock(world.forage, world.forage_cap, 1.4)
			add_log(e["text"], "good")
		"wolves":
			_scale_stock(world.game, world.game_cap, 0.72)
			add_log(e["text"], "bad")
		"sickness":
			population = maxf(Balance.MIN_POPULATION, population * 0.94)
			add_log(e["text"], "bad")
		"migrants":
			var joiners := maxf(2.0, population * 0.12)
			population += joiners
			add_log("%s %s of them join the band." % [e["text"], Balance.fmt_count(joiners)], "good")
		"windfall":
			resources["wood"] += 25.0 + population
			add_log(e["text"], "good")
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
		"wanderer":
			resources["knowledge"] += 12.0 + population * 0.4
			# And a corner of the map nobody had walked.
			for k in 6:
				world.reveal_one()
			add_log(e["text"], "good")


func _scale_stock(arr: PackedFloat32Array, cap_arr: PackedFloat32Array, factor: float) -> void:
	for i in world.territory:
		arr[i] = clampf(arr[i] * factor, 0.0, cap_arr[i])


# --- Log --------------------------------------------------------------------

func add_log(text: String, kind: String = "info") -> void:
	var entry := {"day": int(day), "text": text, "kind": kind}
	log_entries.append(entry)
	if log_entries.size() > 120:
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
		"milestone": _milestone,
		"resources": resources.duplicate(),
		"jobs": jobs.duplicate(),
		"job_weights": job_weights.duplicate(),
		"job_peak": job_peak.duplicate(),
		"job_lifetime": job_lifetime.duplicate(),
		"auto_assign": auto_assign,
		"auto_build": auto_build,
		"auto_research": auto_research,
		"auto_upgrade": auto_upgrade,
		"buildings": buildings.duplicate(),
		"build_queue": build_queue.duplicate(true),
		"techs": techs.duplicate(),
		"upgrades": upgrades.duplicate(),
		"researching": researching,
		"seen_biomes": _seen_biomes.duplicate(),
		"world": world.to_dict(),
		"log": log_entries.slice(maxi(0, log_entries.size() - 30)),
	}


func from_dict(d: Dictionary) -> void:
	var wd: Dictionary = d.get("world", {})
	new_game(int(wd.get("seed", 1)), int(wd.get("type", Balance.WorldType.EARTH)))

	day = float(d.get("day", 0.0))
	population = float(d.get("population", 6.0))
	peak_population = maxf(population, float(d.get("peak_population", population)))
	era = int(d.get("era", 0))
	_milestone = int(d.get("milestone", 0))
	auto_assign = bool(d.get("auto_assign", true))
	auto_build = bool(d.get("auto_build", true))
	auto_research = bool(d.get("auto_research", true))
	auto_upgrade = bool(d.get("auto_upgrade", true))
	researching = String(d.get("researching", ""))

	for id in Balance.RESOURCE_ORDER:
		resources[id] = float((d.get("resources", {}) as Dictionary).get(id, 0.0))
	for id in Balance.JOB_ORDER:
		jobs[id] = int((d.get("jobs", {}) as Dictionary).get(id, 0))
		job_weights[id] = float((d.get("job_weights", {}) as Dictionary).get(id, 1.0))
		job_peak[id] = int((d.get("job_peak", {}) as Dictionary).get(id, 0))
		job_lifetime[id] = float((d.get("job_lifetime", {}) as Dictionary).get(id, 0.0))
	for id in Balance.BUILDING_ORDER:
		buildings[id] = int((d.get("buildings", {}) as Dictionary).get(id, 0))

	techs.clear()
	for t in d.get("techs", []):
		if Balance.TECHS.has(t):
			techs.append(String(t))
	upgrades.clear()
	for u in d.get("upgrades", []):
		upgrades.append(String(u))
	_seen_biomes.clear()
	for b in d.get("seen_biomes", []):
		_seen_biomes.append(int(b))

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

	_mods_dirty = true
	_rebuild_mods()
	world.from_dict(wd)
	game_reset.emit()
	state_changed.emit()
