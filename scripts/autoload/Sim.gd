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
signal boon_appeared(id: String)
signal ascended(points: float)
signal council_opened(id: String)
signal council_closed(id: String, choice: String, by_elders: bool)

## The simulation's own random source, seeded from the world seed.
##
## Everything used to draw on the global RNG, which Godot seeds from the system
## at startup. World *generation* was always seeded properly, so two players
## entering the same seed got the same map - and then a completely different
## game on top of it, because every event, boon, council question, disaster and
## notable name came from somewhere else entirely. That makes a shared seed
## almost meaningless, and it made the balance harness unable to reproduce its
## own results: the numbers it printed changed every run.
##
## Its state is saved, so reloading continues the same sequence rather than
## forking into a new one.
var rng := RandomNumberGenerator.new()

## What a seed promises, and what it does not.
##
## A seed fixes the *world*: the same land, the same rivers and ore, the same
## starting location, the same six people with the same things in front of them.
## Two players who type the same seed begin in exactly the same place.
##
## It does not fix the *run*. Each new game rolls a salt, so the weather, the
## events, the council questions and the boons differ between two games on the
## same seed - and they diverge further with every decision either player makes.
## A seed is a starting position, not a script.
##
## The salt is saved, so reloading continues the run you were in rather than
## forking a new one, and the headless harness pins it to zero because a
## regression test that cannot reproduce its own numbers measures nothing.
var run_salt: int = 0
## Set by the harness. Makes new_game reproducible salt and all.
var deterministic := false

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

# --- Legacy (prestige) ---
## Everything this civilisation has ever produced, which is what Legacy is
## earned from. Summed across trades - it is a score, not a quantity.
## The banked points themselves live in Profile, because they are the player's
## and must survive "New World".
var lifetime_output: float = 0.0

# --- Season, chronicle, notables ---
var season: int = 0
## Index into Balance.WEATHER, and the day it runs until. Weather is the fast
## rhythm under the season's slow one - a few days at a time, unannounced.
var weather: int = 0
var weather_until: float = 0.0
## Significant entries kept as the civilisation's own history.
var chronicle: Array[Dictionary] = []
## Named individuals attached to things that actually happened.
var notables: Array[Dictionary] = []
## Index of the next opening prompt, and the current one's text.
var beat: int = 0
var beat_text := ""
## Standing exchange: what goes out, what comes back. Player-set only.
var trade_sell := ""
var trade_buy := ""
## Filled in when a save is loaded after time away, for the digest.
var offline_digest := {}
## Consecutive days the people have gone hungry, for the hungry-decade mark.
var hunger_days: float = 0.0

# --- Boons ---
var boon_id := ""
var boon_tile: int = -1
var boon_expires: float = 0.0

## One sample a day of the things worth seeing the shape of.
var history := {}
## Gross output per job last step, for attributing a rate to its sources.
var gross_by_job := {}
## One line explaining the labour planner's last decision. An automation you
## cannot interrogate is one you cannot trust.
var plan_reason := ""

# --- Player-only levers. The elders never touch any of these. ---
## Active decree, or "". A commitment: big bonus, real penalty, cooldown.
var decree := ""
var decree_cooldown: float = 0.0
## Open council question, if any, and how long is left to answer it.
var council_id := ""
var council_deadline: float = 0.0
var council_answered := 0
var council_by_elders := 0
## Boons collected close together stack. This is the reward for watching.
var momentum: int = 0
var momentum_until: float = -1.0
var festival_until: float = -1.0
var festival_cooldown: float = 0.0
## Founded by hand on walked ground. tile -> richness contribution.
var outposts: Array[Dictionary] = []
## Second (and third, and fourth) places people live. Bought with points earned
## by growing, not with resources alone - see Balance.SETTLEMENT_POP_THRESHOLDS.
var settlements: Array[Dictionary] = []
var settlement_points: int = 0
## How many population thresholds have already paid out, so each pays once.
var _settlements_earned: int = 0
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
## Scratch pool used while rebuilding, so a category can be summed before it multiplies.
var _effect_pool := {}
var _storage := {}
var _spoilage_mult := 1.0
var _knowledge_mult := 1.0
var _farm_plots := 0.0
var _mine_slots := 0.0
var _quarry_slots := 0.0
var _woodlot_slots := 0.0
var _birth_mult := 1.0
var _housing_mult := 1.0
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
var _legacy_mult := 1.0
var _omen_until: float = -1.0
var _boon_cooldown: float = Balance.BOON_INTERVAL_DAYS
var _council_cooldown: float = Balance.COUNCIL_INTERVAL_DAYS
## Two council outcomes leave a lasting mark rather than a one-off payout.
var _mine_bonus_days: float = -1.0
var _endowed := false
var _csv: FileAccess = null
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
		# The one deliberate use of the global RNG: choosing a seed is the act of
		# not having one. Everything after this line is reproducible from it.
		p_seed = randi() % 1_000_000 + 1

	world = CivWorld.new()
	world.generate(p_seed, p_type)
	run_salt = 0 if deterministic else randi()
	# Offset so the simulation's stream is not the terrain generator's stream.
	rng.seed = hash("civamation-sim:%d:%d:%d" % [p_seed, p_type, run_salt])

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
	lifetime_output = 0.0
	season = 0
	weather = 0
	weather_until = 0.0
	chronicle.clear()
	notables.clear()
	beat = 0
	beat_text = ""
	trade_sell = ""
	trade_buy = ""
	offline_digest = {}
	hunger_days = 0.0
	boon_id = ""
	boon_tile = -1
	_omen_until = -1.0
	_boon_cooldown = Balance.BOON_INTERVAL_DAYS
	plan_reason = ""
	decree = ""
	decree_cooldown = 0.0
	council_id = ""
	council_deadline = 0.0
	council_answered = 0
	council_by_elders = 0
	momentum = 0
	momentum_until = -1.0
	festival_until = -1.0
	festival_cooldown = 0.0
	outposts.clear()
	settlements.clear()
	settlement_points = 0
	_settlements_earned = 0
	_mine_bonus_days = -1.0
	_endowed = false
	_council_cooldown = Balance.COUNCIL_INTERVAL_DAYS * 0.6
	history = {}
	for series in Balance.HISTORY_SERIES:
		history[series] = PackedFloat32Array()

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

	_apply_perks()
	Profile.note_shape(p_type)

	var here: String = Balance.BIOME_INFO[world.biome[world.idx(world.origin.x, world.origin.y)]]["name"]
	_seen_biomes.append(world.biome[world.idx(world.origin.x, world.origin.y)])
	add_log("Six of you stop walking. This place has water, and the grass is thick. It will do for now.", "era")
	add_log("The band makes camp on %s. Nobody here knows what is over the next ridge." % String(here).to_lower(), "info")
	game_reset.emit()
	state_changed.emit()


## Permanent unlocks bought with Legacy. Applied once, at the start of a run,
## before anyone has done anything - which is the point of them.
func _apply_perks() -> void:
	if Profile.has_perk("remembered_fire"):
		for t in ["fire_mastery", "stone_tools"]:
			if not techs.has(t):
				techs.append(t)
	if Profile.has_perk("seed_stock"):
		# The whole prerequisite chain, or the tech tree stops making sense.
		for t in ["fire_mastery", "stone_tools", "shared_stories", "preservation",
				"settlement", "basketry", "pottery", "agriculture"]:
			if not techs.has(t):
				techs.append(t)
		buildings["farm_plot"] = 5
	if Profile.has_perk("full_granary"):
		resources["food"] += 400.0
		resources["wood"] += 300.0
		resources["stone"] += 150.0
		resources["hides"] += 60.0
	if Profile.has_perk("old_maps"):
		for k in 220:
			if world.reveal_one() < 0:
				break
	_mods_dirty = true
	_rebuild_mods()
	_update_territory()


## How far the speed control goes. Four is far too slow once a decision takes a
## hundred days to pay off, so the later ones unlock with the eras.
func max_speed_index() -> int:
	var top := 0
	for i in Balance.SPEEDS.size():
		if era >= int(Balance.SPEED_UNLOCK_ERA[i]):
			top = i
	return top


func _process(delta: float) -> void:
	var speed: float = Balance.SPEEDS[speed_index]
	if speed <= 0.0:
		return
	advance(delta * speed / Balance.SECONDS_PER_DAY)


## Advance the simulation by `days`, in fixed substeps.
func advance(days: float) -> void:
	_accum += days
	# Thirty days a second at ten substeps each is three hundred steps a second
	# of precision nobody can see. The ecology is stable at the coarser rate.
	var dt := Balance.FAST_STEP_DAYS if days_per_second() >= Balance.FAST_STEP_THRESHOLD \
			else Balance.STEP_DAYS
	var steps := 0
	while _accum >= dt and steps < Balance.MAX_STEPS_PER_FRAME:
		_accum -= dt
		_step(dt)
		steps += 1
	if steps > 0:
		state_changed.emit()


## How many in-game days pass per real second at the current speed.
func days_per_second() -> float:
	return Balance.SPEEDS[speed_index] / Balance.SECONDS_PER_DAY


## Credit offline time. Runs the real simulation rather than approximating it.
func run_offline(days: float) -> void:
	var capped := minf(days, Balance.MAX_OFFLINE_HOURS * 3600.0 / Balance.SECONDS_PER_DAY)
	if capped <= 0.5:
		return
	var before := {
		"pop": population, "era": era, "techs": techs.size(),
		"upgrades": upgrades.size(), "output": lifetime_output,
		"explored": world.explored_fraction(), "council": council_by_elders,
	}
	simulate_days(capped, true)
	# The data was always there; only the telling was missing.
	offline_digest = {
		"days": int(capped),
		"pop_before": before["pop"], "pop_after": population,
		"techs": techs.size() - int(before["techs"]),
		"upgrades": upgrades.size() - int(before["upgrades"]),
		"eras": era - int(before["era"]),
		"explored": (world.explored_fraction() - float(before["explored"])) * 100.0,
		"elders_decided": council_by_elders - int(before["council"]),
		"output": lifetime_output - float(before["output"]),
	}
	add_log("While you were away: %d days passed, and the people went from %s to %s."
			% [int(capped), Balance.fmt_count(before["pop"]), Balance.fmt_count(population)], "info")
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
	decree_cooldown = maxf(0.0, decree_cooldown - dt)
	festival_cooldown = maxf(0.0, festival_cooldown - dt)
	_maybe_council(dt, offline)
	if not offline:
		_maybe_boon(dt)
	if Settings.disaster_frequency > 0:
		_maybe_disaster(dt, offline)
	_check_era()
	_check_milestones(offline)
	_check_settlement_points()


## The worked land grows with the population and with technology, but never
## past where somebody has actually walked. That gate is the entire reason
## explorers exist.
func _update_territory() -> void:
	var bonus := _territory_bonus + float(outposts.size()) * Balance.OUTPOST_TERRITORY \
			+ float(settlements.size()) * Balance.SETTLEMENT_TERRITORY
	if decree != "":
		bonus += float(Balance.DECREES[decree].get("territory", 0.0))
	var want := Balance.BASE_TERRITORY_RADIUS + population * Balance.TERRITORY_PER_POP + bonus
	var walked := world.explored_radius - Balance.CLAIM_MARGIN
	world.territory_radius = clampf(minf(want, walked),
			Balance.BASE_TERRITORY_RADIUS, max_territory_radius())
	world.refresh_territory()


## True when the settlement wants more land than it has been shown - the signal
## that explorers are the bottleneck right now.
func expansion_blocked_by_exploration() -> bool:
	if world.territory_radius >= max_territory_radius():
		return false
	if not world.frontier_open():
		return false
	var bonus := _territory_bonus + float(outposts.size()) * Balance.OUTPOST_TERRITORY \
			+ float(settlements.size()) * Balance.SETTLEMENT_TERRITORY
	if decree != "":
		bonus += float(Balance.DECREES[decree].get("territory", 0.0))
	var want := Balance.BASE_TERRITORY_RADIUS + population * Balance.TERRITORY_PER_POP + bonus
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
	# Somebody was here first. The rarest thing the frontier turns up, and the
	# only one that can hand you a whole idea at once.
	if rng.randf() < 0.004 and _seen_biomes.size() > 2:
		var target := researching if researching != "" else _cheapest_available()
		if target != "" and rng.randf() < 0.35:
			resources["knowledge"] += float(Balance.TECHS[target]["cost"])
			add_log("Ruins. Someone was here long before you, and left enough behind "
					+ "to finish a thought your elders had started.", "tech")
			_add_notable("ruins", "They brought the marks back from the ruins.")
		else:
			resources["knowledge"] += 40.0 + population * 0.8
			add_log("Ruins on the frontier - old walls, and marks nobody can read.", "tech")
		return
	if world.gold[i] > 0.30:
		resources["gold"] += 6.0 + population * 0.05
		add_log("Bright grains in a streambed out past the frontier.", "good")
	elif world.ore[i] > 1.10:
		resources["ore"] += 12.0 + population * 0.08
		add_log("A seam breaks the surface on a hillside the scouts just mapped.", "good")


## Once-a-day upkeep of the things the map shows but the economy does not run
## on: where the animals are, and who can currently see what.
## Legacy on offer if you set this civilisation down now.
func legacy_on_offer() -> float:
	if lifetime_output <= 0.0:
		return 0.0
	return floorf(pow(lifetime_output / Balance.LEGACY_DIVISOR, Balance.LEGACY_EXPONENT))


func can_ascend() -> bool:
	return legacy_on_offer() >= Balance.LEGACY_MIN_POINTS


## End this civilisation and begin another, keeping what was learned. The only
## action in the game that throws work away on purpose, and the only one that
## makes the next run permanently better.
func ascend(world_type: int = -1) -> bool:
	if not can_ascend():
		return false
	var gained := legacy_on_offer()
	if day < 400.0:
		_award("early_ascent")
	Profile.runs_completed += 1
	var keep := Profile.legacy_points + gained
	var shape := world.world_type if world_type < 0 else world_type
	# Setting a civilisation down should hand you a genuinely new country, so the
	# next world is normally unseeded. Under the harness it has to be repeatable
	# like everything else - this was the last thing making the balance numbers
	# wander between runs.
	new_game(hash("ascend:%d" % shape) % 1_000_000 + 1 if deterministic else 0, shape)
	Profile.legacy_points = keep
	Profile.save_profile()
	_mods_dirty = true
	_rebuild_mods()
	add_log("The old country is behind you. %s Legacy carried forward - every trade "
			% Balance.fmt(gained) + "begins %d%% better than it did before."
			% int(round(Profile.legacy_points * Balance.LEGACY_BONUS_PER_POINT * 100.0)), "era")
	ascended.emit(gained)
	state_changed.emit()
	return true


# --- Boons ------------------------------------------------------------------
## Rare, brief, and visible on the map. Every one is a bonus and none is a
## penalty, so noticing is rewarded and not noticing costs nothing.

func _maybe_boon(dt: float) -> void:
	if boon_id != "":
		if day > boon_expires:
			boon_id = ""
			boon_tile = -1
			state_changed.emit()
		return
	_boon_cooldown -= dt
	if _boon_cooldown > 0.0:
		return
	_boon_cooldown = Balance.BOON_INTERVAL_DAYS * rng.randf_range(0.65, 1.45)
	if world.territory.is_empty():
		return
	boon_id = Balance.BOON_ORDER[rng.randi() % Balance.BOON_ORDER.size()]
	boon_tile = world.territory[rng.randi() % world.territory.size()]
	boon_expires = day + Balance.BOON_LIFETIME_DAYS
	add_log("%s. %s" % [Balance.BOONS[boon_id]["name"], Balance.BOONS[boon_id]["text"]], "good")
	boon_appeared.emit(boon_id)
	state_changed.emit()


func collect_boon() -> bool:
	if boon_id == "":
		return false
	# Caught one while the last was still counting: they compound.
	if day < momentum_until:
		momentum = mini(momentum + 1, Balance.MOMENTUM_MAX)
	else:
		momentum = 1
	momentum_until = day + Balance.MOMENTUM_WINDOW_DAYS + Balance.MOMENTUM_DECAY_DAYS
	var id := boon_id
	boon_id = ""
	boon_tile = -1
	match id:
		"caravan":
			# Paid in proportion to what the settlement makes, so it stays
			# meaningful at six people and at sixty thousand.
			for res in ["food", "wood", "stone", "ore"]:
				resources[res] += maxf(40.0, production[res] * 60.0)
			resources["gold"] += maxf(10.0, production["gold"] * 90.0 + population * 0.2)
			add_log("The caravan is met and traded with.", "good")
		"good_omen":
			_omen_until = day + Balance.OMEN_DAYS
			add_log("The omen is read as a good one. For a month everyone works like it matters.", "good")
		"migrating_herd":
			for i in world.territory:
				world.game[i] = world.game_cap[i]
			add_log("The herd passes through. The valley is full of animals again.", "good")
		"wandering_scholar":
			resources["knowledge"] += maxf(60.0, production["knowledge"] * 120.0)
			for k in 20:
				world.reveal_one()
			add_log("The scholar draws what they remember of the country beyond, and moves on.", "good")
		"master_mason":
			for res in ["stone", "wood"]:
				resources[res] += maxf(60.0, production[res] * 80.0)
			add_log("The mason shows them a better way to lay a course, and moves on.", "good")
		"seam_strike":
			resources["ore"] += maxf(80.0, production["ore"] * 150.0)
			resources["gold"] += maxf(5.0, production["gold"] * 100.0)
			add_log("The seam runs richer than anyone dared hope.", "good")
		"fair_season":
			resources["food"] += maxf(120.0, production["food"] * 100.0)
			for i in world.territory:
				world.forage[i] = world.forage_cap[i]
			add_log("A fair season. Everything ripens at once.", "good")
	if momentum > 1:
		add_log("That is %d in a row. Everything is running at %d%%." % [momentum,
				int(round((1.0 + momentum * Balance.MOMENTUM_PER_BOON) * 100.0))], "good")
	state_changed.emit()
	return true


func momentum_active() -> bool:
	return momentum > 0 and day < momentum_until


func omen_active() -> bool:
	return day < _omen_until


func _sample_history() -> void:
	var vals := {
		"pop": population,
		"food": resources["food"],
		"herd": world.stock_health(world.game, world.game_cap) * 100.0,
		"output": lifetime_output,
	}
	for series in Balance.HISTORY_SERIES:
		var arr: PackedFloat32Array = history.get(series, PackedFloat32Array())
		arr.append(float(vals[series]))
		if arr.size() > Balance.HISTORY_SAMPLES:
			arr = arr.slice(arr.size() - Balance.HISTORY_SAMPLES)
		history[series] = arr


## One row per in-game day. Balance arguments should be settled with a
## spreadsheet, not with opinions.
func _write_csv_row() -> void:
	if not Settings.csv_logging:
		if _csv != null:
			_csv.close()
			_csv = null
		return
	if _csv == null:
		_csv = FileAccess.open(Settings.CSV_PATH, FileAccess.WRITE)
		if _csv == null:
			return
		var head := PackedStringArray(["day", "population", "carrying_capacity", "housing"])
		for res in Balance.RESOURCE_ORDER:
			head.append(res)
			head.append(res + "_rate")
		for job in Balance.JOB_ORDER:
			head.append("job_" + job)
		head.append_array(["techs", "upgrades", "era", "explored_pct", "territory", "legacy"])
		_csv.store_line(",".join(head))
	var row := PackedStringArray([str(int(day)), "%.2f" % population,
			"%.2f" % carrying_capacity, "%.2f" % housing])
	for res in Balance.RESOURCE_ORDER:
		row.append("%.3f" % resources[res])
		row.append("%.3f" % float(rates.get(res, 0.0)))
	for job in Balance.JOB_ORDER:
		row.append(str(int(jobs.get(job, 0))))
	row.append_array([str(techs.size()), str(upgrades.size()), str(era),
			"%.1f" % (world.explored_fraction() * 100.0), str(world.territory.size()),
			"%.1f" % Profile.legacy_points])
	_csv.store_line(",".join(row))


## Run days immediately, for a designer who does not want to wait an hour to
## see an hour of consequences.
func surge(days: float) -> void:
	simulate_days(days, false)
	state_changed.emit()


func _daily_world_tick() -> void:
	season = int(fmod(day, Balance.DAYS_PER_YEAR) / (Balance.DAYS_PER_YEAR * 0.25)) % 4
	_roll_weather()
	_run_trade()
	_check_beats()
	_check_achievements()
	Profile.note_population(population)
	_sample_history()
	_write_csv_row()
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
	var freq: Dictionary = Balance.DISASTER_FREQUENCY[clampi(Settings.disaster_frequency, 0,
			Balance.DISASTER_FREQUENCY.size() - 1)]
	_disaster_cooldown = Balance.DISASTER_INTERVAL_DAYS * float(freq["scale"]) * rng.randf_range(0.6, 1.5)

	var choices: Array[String] = []
	for id in Balance.DISASTERS:
		if _disaster_possible(String(Balance.DISASTERS[id]["needs"])):
			choices.append(id)
	if choices.is_empty():
		return
	var pick: String = choices[rng.randi() % choices.size()]
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


# --- Seasons, opening, chronicle, trade -------------------------------------

func season_name() -> String:
	return String(Balance.SEASONS[season]["name"])


## The next thing worth telling a new player, or "" once they are past it. The
## settlement gets there on its own either way - these only teach the order the
## systems matter in.
func _check_beats() -> void:
	if beat >= Balance.OPENING_BEATS.size():
		beat_text = ""
		return
	var id: String = Balance.OPENING_BEATS[beat]["id"]
	var done := false
	match id:
		"fire": done = int(buildings.get("firepit", 0)) > 0
		"scout": done = int(job_peak.get("explorer", 0)) > 0
		"shelter": done = int(buildings.get("windbreak", 0)) + int(buildings.get("hut", 0)) > 0
		"decree": done = decree != ""
		"winter": done = day > Balance.DAYS_PER_YEAR
	if done:
		beat += 1
		beat_text = ""
		_check_beats()
		return
	beat_text = String(Balance.OPENING_BEATS[beat]["text"])


## A standing exchange. Sends out a slice of one good's production and brings
## back another, minus the caravan's cut, for a little gold a day.
func can_trade() -> bool:
	return techs.has(Balance.TRADE_UNLOCK_TECH)


func set_trade(sell: String, buy: String) -> void:
	if sell == buy:
		sell = ""
		buy = ""
	trade_sell = sell
	trade_buy = buy
	if sell == "":
		add_log("The trade route is closed.", "info")
	else:
		add_log("A standing exchange: %s out, %s back." % [
				String(Balance.RESOURCES[sell]["name"]).to_lower(),
				String(Balance.RESOURCES[buy]["name"]).to_lower()], "era")
	state_changed.emit()


func _run_trade() -> void:
	if trade_sell == "" or trade_buy == "" or not can_trade():
		return
	var upkeep := population * 0.01 * Balance.TRADE_GOLD_UPKEEP
	if resources["gold"] < upkeep:
		trade_sell = ""
		trade_buy = ""
		add_log("There is no gold left to keep the caravans coming. The route lapses.", "bad")
		return
	resources["gold"] -= upkeep
	var out: float = production.get(trade_sell, 0.0) * Balance.TRADE_EXPORT_FRACTION
	if out <= 0.0:
		return
	out = minf(out, resources[trade_sell])
	resources[trade_sell] -= out
	var sell_value := float(Balance.RESOURCE_VALUE.get(trade_sell, 1.0))
	var buy_value := maxf(0.01, float(Balance.RESOURCE_VALUE.get(trade_buy, 1.0)))
	resources[trade_buy] += out * sell_value / buy_value * Balance.TRADE_EFFICIENCY


## A name attached to something that actually happened.
func _add_notable(kind: String, what: String) -> void:
	var names: Array = Balance.GIVEN_NAMES
	var roles: Array = Balance.NOTABLE_ROLES.get(kind, ["who was there"])
	var entry := {
		"name": String(names[rng.randi() % names.size()]),
		"role": String(roles[rng.randi() % roles.size()]),
		"what": what,
		"day": int(day),
		"era": era,
	}
	notables.append(entry)
	if notables.size() > 60:
		notables.remove_at(0)
	add_log("%s, %s. %s" % [entry["name"], entry["role"], what], "era")


func _chronicle(text: String, kind: String) -> void:
	chronicle.append({"day": int(day), "era": era, "text": text, "kind": kind})
	if chronicle.size() > 200:
		chronicle.remove_at(0)


# --- Achievements -----------------------------------------------------------

func _check_achievements() -> void:
	if era >= 2 and float(job_lifetime.get("hunter", 0.0)) <= 0.0:
		_award("vegetarian")
	if era >= 5 and world.world_type == Balance.WorldType.ARCHIPELAGO:
		_award("island_steel")
	if world.explored_fraction() > 0.995 or (not world.frontier_open() and world.explored_fraction() > 0.6):
		_award("cartographer")
	if Profile.shapes_played.size() >= Balance.WORLD_TYPES.size():
		_award("all_shapes")
	if population >= 10000.0:
		_award("myriad")
	if era >= 3 and world.stock_health(world.game, world.game_cap) > 0.8 \
			and world.stock_health(world.forest, world.forest_cap) > 0.8:
		_award("untouched")
	if momentum >= 5:
		_award("chain")
	if hunger_days > 100.0 and food_satisfaction > 0.99 and population > peak_population * 0.9:
		_award("deep_winter")
	# Every tier of one trade, which needs both the output and the knowledge.
	for job_id in Balance.JOB_ORDER:
		var kind := String(Balance.JOBS[job_id]["kind"])
		var all := true
		for tier in Balance.UPGRADE_TIERS.size():
			if not _tier_owned(kind, tier):
				all = false
				break
		if all:
			_award("mastery")
			break


func _tier_owned(kind: String, tier: int) -> bool:
	if Balance.BRANCH_TIERS.has(tier):
		return upgrades.has("%s_%d_deep" % [kind, tier]) or upgrades.has("%s_%d_broad" % [kind, tier])
	return upgrades.has(upgrade_id(kind, tier))


func _award(id: String) -> void:
	if Profile.award(id):
		add_log("%s - %s" % [Balance.ACHIEVEMENTS[id]["name"], Balance.ACHIEVEMENTS[id]["desc"]], "good")


# --- Player-only levers -----------------------------------------------------
## Everything below is deliberately outside the autopilot's reach. Not because
## the code could not do it, but because none of it has a computable right
## answer - each one is a commitment, a gamble, or a moment. That is the whole
## reason a managed civilisation beats an unmanaged one.

func can_set_decree() -> bool:
	return decree_cooldown <= 0.0


func set_decree(id: String) -> bool:
	if not can_set_decree():
		return false
	if id != "" and not Balance.DECREES.has(id):
		return false
	if id == decree:
		return true
	decree = id
	decree_cooldown = Balance.DECREE_SWITCH_COOLDOWN_DAYS
	if Profile.has_perk("restless"):
		decree_cooldown *= 0.5
	_mods_dirty = true
	if id == "":
		add_log("The decree is lifted. Everyone goes back to their own business.", "info")
	else:
		add_log("Decree: %s. %s" % [Balance.DECREES[id]["name"], Balance.DECREES[id]["desc"]], "era")
	if auto_assign:
		_auto_assign_jobs()
	state_changed.emit()
	return true


## Spend a third of the granary on a party. No optimiser would; every
## civilisation does; and the births and the ideas that come out of it are
## worth more than the food.
func can_hold_festival() -> bool:
	return festival_cooldown <= 0.0 and resources["food"] > population * 4.0


func hold_festival() -> bool:
	if not can_hold_festival():
		return false
	resources["food"] *= (1.0 - Balance.FESTIVAL_FOOD_FRACTION)
	festival_until = day + Balance.FESTIVAL_DAYS
	festival_cooldown = Balance.FESTIVAL_COOLDOWN_DAYS
	# A festival is also where boons get talked about, so it feeds momentum.
	momentum = mini(momentum + 1, Balance.MOMENTUM_MAX)
	momentum_until = maxf(momentum_until, day + Balance.MOMENTUM_WINDOW_DAYS)
	add_log("A festival. The granary takes a beating and everyone remembers it for years.", "era")
	state_changed.emit()
	return true


func festival_active() -> bool:
	return day < festival_until


# --- Outposts ---------------------------------------------------------------

## The ceiling on worked land. Settlements raise it, which is the only way the
## reach grows once the home circle is at its limit.
##
## Territory is modelled as one circle centred on the first settlement, so a new
## settlement widens that circle rather than claiming its own ground where it
## actually stands. That is a real simplification and it shows: found one
## sixteen tiles east and the land sixteen tiles *west* is claimed too. Proper
## multi-centre territory is the honest fix and it touches the whole
## territory/worker-spot path, so it is not done here.
func max_territory_radius() -> float:
	return Balance.MAX_TERRITORY_RADIUS \
			+ float(settlements.size()) * Balance.SETTLEMENT_TERRITORY


# --- Weather ----------------------------------------------------------------

## Roll a new spell of weather when the last one runs out. Weighted by season,
## so snow belongs to winter and long clear spells to summer without any of that
## being special-cased anywhere.
func _roll_weather() -> void:
	if day < weather_until:
		return
	var total := 0.0
	for w in Balance.WEATHER:
		total += float((w["weight"] as Array)[season])
	if total <= 0.0:
		return
	var roll := rng.randf() * total
	for i in Balance.WEATHER.size():
		roll -= float((Balance.WEATHER[i]["weight"] as Array)[season])
		if roll <= 0.0:
			var changed := i != weather
			weather = i
			weather_until = day + rng.randf_range(
					Balance.WEATHER_MIN_DAYS, Balance.WEATHER_MAX_DAYS)
			if changed and Settings.verbose_log:
				add_log(String(Balance.WEATHER[i]["note"]), "info")
			return


func weather_info() -> Dictionary:
	return Balance.WEATHER[clampi(weather, 0, Balance.WEATHER.size() - 1)]


func weather_name() -> String:
	return String(weather_info()["name"])


# --- Settlements ------------------------------------------------------------

## Points are earned by growing, one per population threshold crossed. Called
## from the milestone check, so it is on the same cadence as everything else
## that reacts to the settlement getting bigger.
func _check_settlement_points() -> void:
	while _settlements_earned < Balance.SETTLEMENT_POP_THRESHOLDS.size() \
			and population >= Balance.SETTLEMENT_POP_THRESHOLDS[_settlements_earned]:
		_settlements_earned += 1
		settlement_points += 1
		add_log("There are enough of you to settle somewhere else. "
				+ "Found a new settlement from the Rule tab.", "era")
		_chronicle("Enough people to found a second place to live.", "era")


## The cheat. Deliberately a plain function rather than something hidden - it is
## for trying the system out before the thresholds are tuned.
func grant_settlement_point() -> void:
	settlement_points += 1
	add_log("A settlement point is granted.", "good")
	state_changed.emit()


## A share of what is in store, rising with each settlement already founded.
func settlement_cost() -> Dictionary:
	var scale := pow(Balance.SETTLEMENT_COST_GROWTH, float(settlements.size()))
	var out := {}
	for res in Balance.SETTLEMENT_COST_FRACTION:
		var frac := minf(float(Balance.SETTLEMENT_COST_FRACTION[res]) * scale,
				Balance.SETTLEMENT_MAX_FRACTION)
		out[res] = float(resources.get(res, 0.0)) * frac
	return out


## Can a settlement go here? A point in hand, walked ground, well clear of home
## and of every other settlement.
func can_found_settlement(tile: int) -> bool:
	if settlement_points <= 0 or world == null:
		return false
	if tile < 0 or tile >= world.explored.size() or world.explored[tile] == 0:
		return false
	if not world.workable(tile) or Balance.is_water_biome(world.biome[tile]):
		return false
	if Vector2(world.tile_pos(tile) - world.origin).length() < Balance.SETTLEMENT_MIN_DISTANCE:
		return false
	for s in settlements:
		if Vector2(world.tile_pos(int(s["tile"])) - world.tile_pos(tile)).length() \
				< Balance.SETTLEMENT_SPACING:
			return false
	# The floors are eligibility, not price: you must have a real store before
	# you can spend a share of it.
	for res in Balance.SETTLEMENT_BASE_COST:
		if resources.get(res, 0.0) < float(Balance.SETTLEMENT_BASE_COST[res]):
			return false
	return true


func found_settlement(tile: int) -> bool:
	if not can_found_settlement(tile):
		return false
	var cost := settlement_cost()
	for res in cost:
		resources[res] -= float(cost[res])
	settlement_points -= 1
	settlements.append({"tile": tile, "value": outpost_value(tile)})
	_mods_dirty = true
	var far := int(Vector2(world.tile_pos(tile) - world.origin).length())
	add_log("A new settlement is founded %d tiles out. People live there now, "
			% far + "and the land around it is yours.", "era")
	_chronicle("A second settlement founded %d tiles out." % far, "era")
	_add_notable("settlement", "They led the party that built the new town.")
	state_changed.emit()
	return true


## Everything the settlements add to the home economy. Same shape as an
## outpost's contribution, scaled up - a settlement works its ground properly.
func settlement_production(res: String) -> float:
	var total := 0.0
	for s in settlements:
		var v: Dictionary = s.get("value", {})
		total += float(v.get(res, 0.0)) * Balance.SETTLEMENT_YIELD_SCALE
	return total


func outpost_cost() -> Dictionary:
	var scale := pow(Balance.OUTPOST_COST_GROWTH, float(outposts.size()))
	var out := {}
	for res in Balance.OUTPOST_BASE_COST:
		out[res] = float(Balance.OUTPOST_BASE_COST[res]) * scale
	return out


## Can an outpost go here? Walked ground, far enough out, not already taken.
func can_found_outpost(tile: int) -> bool:
	if outposts.size() >= Balance.OUTPOST_MAX or world == null:
		return false
	if tile < 0 or tile >= world.explored.size() or world.explored[tile] == 0:
		return false
	if not world.workable(tile):
		return false
	if Balance.is_water_biome(world.biome[tile]):
		return false
	if Vector2(world.tile_pos(tile) - world.origin).length() < Balance.OUTPOST_MIN_DISTANCE:
		return false
	for o in outposts:
		if int(o["tile"]) == tile:
			return false
		if Vector2(world.tile_pos(int(o["tile"])) - world.tile_pos(tile)).length() < 5.0:
			return false
	var cost := outpost_cost()
	for res in cost:
		if resources.get(res, 0.0) < float(cost[res]):
			return false
	return true


## What this particular ground would be worth to hold. The judgement the elders
## will not make: it is about a place, not a sum.
func outpost_value(tile: int) -> Dictionary:
	if world == null or tile < 0:
		return {}
	var r := 3
	var food := 0.0
	var wood := 0.0
	var ore := 0.0
	var stone := 0.0
	var p := world.tile_pos(tile)
	for oy in range(-r, r + 1):
		for ox in range(-r, r + 1):
			var x: int = p.x + ox
			var y: int = p.y + oy
			if not world.in_bounds(x, y):
				continue
			var i := world.idx(x, y)
			food += world.game_cap[i] * 0.02 + world.forage_cap[i] * 0.03 + world.fertility[i] * 0.6
			wood += world.forest_cap[i] * 0.03
			ore += world.ore[i] * 0.9
			stone += world.stone[i] * 0.5
	return {"food": food, "wood": wood, "ore": ore, "stone": stone}


func found_outpost(tile: int) -> bool:
	if not can_found_outpost(tile):
		return false
	var cost := outpost_cost()
	for res in cost:
		resources[res] -= float(cost[res])
	outposts.append({"tile": tile, "value": outpost_value(tile)})
	_mods_dirty = true
	# An outpost is somewhere people are, so it sees its own country.
	add_log("An outpost is founded %d tiles out. It sends back what the ground there gives."
			% int(Vector2(world.tile_pos(tile) - world.origin).length()), "era")
	_chronicle("An outpost founded %d tiles out."
			% int(Vector2(world.tile_pos(tile) - world.origin).length()), "era")
	_add_notable("outpost", "They walked out to the new ground and did not come back.")
	state_changed.emit()
	return true


## Flat daily production from every outpost, added on top of the home economy.
func outpost_production(res: String) -> float:
	var total := 0.0
	for o in outposts:
		total += float((o["value"] as Dictionary).get(res, 0.0))
	return total * _legacy_mult


# --- Council ----------------------------------------------------------------
## A question with no computable right answer, a clock, and a safe default the
## elders take if nobody says otherwise. Safe is never a disaster and never the
## best - and that gap is exactly what paying attention is worth.

func _maybe_council(dt: float, offline: bool) -> void:
	if council_id != "":
		if day > council_deadline:
			var safe := _council_safe_option(council_id)
			_resolve_council(council_id, safe, true, offline)
		return
	_council_cooldown -= dt
	if _council_cooldown > 0.0:
		return
	_council_cooldown = Balance.COUNCIL_INTERVAL_DAYS * rng.randf_range(0.7, 1.4)
	if population < 20.0:
		return
	council_id = Balance.COUNCIL_ORDER[rng.randi() % Balance.COUNCIL_ORDER.size()]
	council_deadline = day + Balance.COUNCIL_PATIENCE_DAYS
	if not offline:
		add_log("%s %s" % [Balance.COUNCIL[council_id]["title"],
				Balance.COUNCIL[council_id]["text"]], "era")
	council_opened.emit(council_id)
	state_changed.emit()


func _council_safe_option(id: String) -> String:
	for opt in Balance.COUNCIL[id]["options"]:
		if bool(opt.get("safe", false)):
			return String(opt["id"])
	return String(Balance.COUNCIL[id]["options"][0]["id"])


## The player's answer.
func answer_council(choice: String) -> bool:
	if council_id == "":
		return false
	_resolve_council(council_id, choice, false, false)
	return true


func _resolve_council(id: String, choice: String, by_elders: bool, offline: bool) -> void:
	council_id = ""
	council_answered += 1
	if by_elders:
		council_by_elders += 1

	match choice:
		"slaughter":
			resources["food"] += population * 30.0
			_scale_stock(world.game, world.game_cap, 0.45)
			_note("The herds are taken. The granary has never been so full, and the "
					+ "hunting will be poor for a long time.", offline)
		"ration":
			resources["food"] = maxf(resources["food"], population * 6.0)
			_note("Rations are set. Nobody starves and nobody grows.", offline)
		"trust":
			if rng.randf() < 0.55:
				_note("The winter is mild. Nothing was needed after all.", offline)
			else:
				resources["food"] *= 0.55
				_note("The winter is not mild. The stores take a beating.", offline)
		"take_in":
			population += Balance.migrant_count(population)
			resources["knowledge"] += 60.0 + population * 1.5
			_note("They stay. Within a month nobody can remember which of them arrived.", offline)
		"trade":
			resources["gold"] += 40.0 + population * 0.6
			resources["knowledge"] += 30.0 + population * 0.8
			for k in 25:
				world.reveal_one()
			_note("They trade well, and draw the country they came through in the dirt.", offline)
		"refuse":
			_note("They are given a day's food and pointed at the road.", offline)
		"deeper":
			resources["ore"] += maxf(150.0, production["ore"] * 200.0)
			population = maxf(Balance.MIN_POPULATION, population * 0.97)
			_note("The seam is everything they hoped. Three of them do not come back up.", offline)
		"shore_up":
			resources["stone"] = maxf(0.0, resources["stone"] - population * 2.0)
			_mine_bonus_days = day + 400.0
			_note("The shaft is timbered properly. It will still be there in thirty years.", offline)
		"leave_it":
			_note("The deep seam is left alone.", offline)
		"dig":
			resources["wood"] = maxf(0.0, resources["wood"] - population * 3.0)
			for i in world.territory:
				world.fertility[i] = minf(world.fertility[i] * 1.25, 2.2)
			world.refresh_territory(true)
			_note("The channel is cut. The fields drink again, and better than before.", offline)
		"move_fields":
			resources["food"] *= 0.6
			for i in world.territory:
				world.fertility[i] = minf(world.fertility[i] * 1.45, 2.4)
			world.refresh_territory(true)
			_note("A season is lost moving everything. The new ground is the best they have had.", offline)
		"carry":
			_note("They carry the water, as they always have.", offline)
		"endow":
			resources["food"] = maxf(0.0, resources["food"] - population * 8.0)
			resources["wood"] = maxf(0.0, resources["wood"] - population * 4.0)
			_endowed = true
			_mods_dirty = true
			_note("She gets a building and a stipend, and forty years of pupils.", offline)
		"allow":
			resources["knowledge"] += 40.0 + population * 1.0
			_note("She gets on with it in the afternoons.", offline)

	_chronicle("%s - %s." % [Balance.COUNCIL[id]["title"], choice.replace("_", " ")], "council")
	if by_elders:
		add_log("(The elders decided this one themselves.)", "info")
	elif rng.randf() < 0.4:
		_add_notable("council", "It was their argument that carried the day.")
	council_closed.emit(id, choice, by_elders)
	state_changed.emit()


func _note(text: String, offline: bool) -> void:
	if not offline:
		add_log(text, "good")


# --- Ecology ----------------------------------------------------------------

## Logistic regrowth toward capacity plus immigration from beyond the territory,
## so a hard-worked stock always recovers. Also the one pass that recomputes the
## living-stock totals the rest of the step reads.
func _ecology(dt: float) -> void:
	var regrow := 1.0
	if decree != "":
		regrow = float(Balance.DECREES[decree].get("regrowth", 1.0))
	var tg := 0.0
	var tf := 0.0
	var tw := 0.0
	for i in world.territory:
		# Felling forest costs wildlife some habitat, but never all of it.
		var cover := 1.0
		if world.forest_cap[i] > 0.01:
			cover = world.forest[i] / world.forest_cap[i]
		var cap: float = world.game_cap[i] * (1.0 - Balance.HABITAT_WEIGHT + Balance.HABITAT_WEIGHT * cover)
		tg += _grow(world.game, i, cap, Balance.GAME_REGROWTH * regrow, Balance.GAME_IMMIGRATION * regrow, dt)
		tf += _grow(world.forage, i, world.forage_cap[i], Balance.FORAGE_REGROWTH * regrow, Balance.FORAGE_IMMIGRATION * regrow, dt)
		tw += _grow(world.forest, i, world.forest_cap[i], Balance.FOREST_REGROWTH * regrow, Balance.FOREST_IMMIGRATION * regrow, dt)
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


## Every yield passes through here, and the shape of this function is the
## single biggest lever on how far the numbers run.
##
## Things combine in three ways, deliberately:
##
## * **Techs add up, buildings add up, upgrades multiply.** Five techs at +30%
##   each is +150%, not x3.7. Only the upgrade ladder - a bounded, purchased,
##   deliberately exponential thing - is allowed to compound.
## * **Temporary and global effects add to each other.** Legacy, an omen,
##   momentum, a festival and a decree's boost pool into one bonus rather than
##   stacking multiplicatively. Catching a boon during a festival under a decree
##   is a very good moment; it is not a four-hundred-fold spike.
## * **Penalties and the season still multiply.** A cost has to bite whatever
##   else is going on, and the year's rhythm should scale what you have rather
##   than be diluted by it.
##
## Independent multiplicative systems are what made two runs of the same length
## differ by three orders of magnitude. This is the fix.
func _mult(kind: String) -> float:
	var m := float(_yield_mult.get(kind, 1.0))

	var bonus := _legacy_mult - 1.0
	if day < _omen_until:
		bonus += Balance.OMEN_MULTIPLIER - 1.0
	if day < momentum_until and momentum > 0:
		bonus += float(momentum) * Balance.MOMENTUM_PER_BOON
	if decree != "":
		bonus += float((Balance.DECREES[decree]["boost"] as Dictionary).get(kind, 1.0)) - 1.0
	if kind == "knowledge" and day < festival_until:
		bonus += Balance.FESTIVAL_KNOWLEDGE_MULT - 1.0
	m *= 1.0 + maxf(bonus, -0.9)

	if decree != "":
		m *= float((Balance.DECREES[decree]["penalty"] as Dictionary).get(kind, 1.0))
	m *= float((Balance.SEASONS[season]["mult"] as Dictionary).get(kind, 1.0))
	# Weather sits under the season: a small, fast-changing term on top of a
	# large, slow, predictable one.
	m *= float((weather_info()["mult"] as Dictionary).get(kind, 1.0))
	return m


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

	# Outposts and settlements: flat daily production from ground held out past
	# the frontier. An outpost sends things home; a settlement works its own
	# country properly and sends home a good deal more.
	if not outposts.is_empty() or not settlements.is_empty():
		for res in ["food", "wood", "ore", "stone"]:
			var op := outpost_production(res) + settlement_production(res)
			if op > 0.0:
				production[res] += op
				resources[res] += op * dt

	# Knowledge: ambient learning plus dedicated elders.
	var k_rate := Balance.AMBIENT_KNOWLEDGE * sqrt(maxf(population, 1.0))
	# Sub-linear in headcount, and this is the single most important damping in
	# the game. Linear elders closed a loop - more people, more elders, more
	# knowledge, more upgrades, more food, more people - that took a run from
	# three hundred to eighteen thousand in two hundred and fifty days and
	# exhausted the whole tech tree in seventeen minutes. Research has
	# diminishing returns to headcount in reality too.
	k_rate += pow(float(jobs.get("thinker", 0)), Balance.THINKER_EXPONENT) \
			* Balance.KNOWLEDGE_PER_THINKER * _mult("knowledge")
	k_rate *= _knowledge_mult
	_last_gross["thinker"] = pow(float(jobs.get("thinker", 0)), Balance.THINKER_EXPONENT) \
			* Balance.KNOWLEDGE_PER_THINKER * _mult("knowledge") * _knowledge_mult
	production["knowledge"] += k_rate
	resources["knowledge"] += k_rate * dt

	for id in ["hunter", "forager", "woodcutter", "water_carrier", "farmer",
			"forester", "quarrier", "miner", "thinker"]:
		_track_yield(id, float(_last_gross.get(id, 0.0)), dt)
	gross_by_job = _last_gross.duplicate()
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

	var birth_mult := _birth_mult
	if decree != "":
		birth_mult *= float(Balance.DECREES[decree].get("birth_mult", 1.0))
	if day < festival_until:
		birth_mult *= Balance.FESTIVAL_BIRTH_MULT
	births_per_day = Balance.BIRTH_RATE_MAX * population * fertility * crowd * birth_mult
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
	# The high-water mark only rises while the people are actually fed. Without
	# that condition a summer spike set a permanent floor, winter could not
	# correct it, and the safety net ended up holding nine thousand people on
	# land that supported fourteen hundred - the net doing the work the ecology
	# is supposed to do. A peak has to be a level the settlement sustained.
	if food_satisfaction > 0.95 and water_satisfaction > 0.95:
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

	if need_score < Balance.FAMINE_THRESHOLD:
		hunger_days += dt
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
	var total := Balance.BASE_HOUSING + float(settlements.size()) * Balance.SETTLEMENT_HOUSING
	for id in buildings:
		var count: int = buildings[id]
		if count <= 0:
			continue
		var eff: Dictionary = Balance.BUILDINGS[id]["effects"]
		total += float(eff.get("housing", 0.0)) * count
	# Density. Drains, clean water and mortared walls mean a given building
	# holds far more people than it used to - which is how population responds
	# to how well the place is run, rather than only to how much stone it has.
	var density := _housing_mult
	if decree != "":
		density *= float(Balance.DECREES[decree].get("housing_mult", 1.0))
	return Balance.BASE_HOUSING + (total - Balance.BASE_HOUSING) * density


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
		"knowledge":
			# Marginal, not average: what the *next* elder adds, which is what
			# the planner should be sizing against.
			var n := float(jobs.get("thinker", 0))
			var marginal := pow(n + 1.0, Balance.THINKER_EXPONENT) - pow(n, Balance.THINKER_EXPONENT)
			return maxf(marginal, 0.05) * Balance.KNOWLEDGE_PER_THINKER \
					* _mult("knowledge") * _knowledge_mult
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
		lifetime_output += gross * dt
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
	# Look ahead at what the settlement actually intends to build next, rather
	# than at the priciest thing in the catalogue. Saving up for a Great Hall
	# nobody wants yet keeps every pair of hands gathering for no reason.
	var seen := {}
	var considered := 0
	for id in _build_priority():
		if considered >= 6:
			break
		if seen.has(id) or not building_unlocked(id):
			continue
		var cap := building_max(id)
		if cap > 0 and built_and_queued(id) >= cap:
			continue
		seen[id] = true
		considered += 1
		var cost := cost_of(id)
		for res in cost:
			var want := float(cost[res]) * Balance.STOCK_TARGET_MULTIPLE
			if want > float(_stock_targets.get(res, 0.0)):
				_stock_targets[res] = want


## What one more worker in this job is worth, in one currency across all trades.
##
## Yield alone is not comparable - a miner and a forester produce different
## things in different quantities. Multiplying by what the material is worth and
## by how short of it the settlement currently is puts every trade on the same
## scale, which is the only way to answer "who should the next person be?"
func marginal_value(id: String) -> float:
	var res := _job_resource(id)
	var y := job_yield_planned(id)
	if y <= 0.0:
		return 0.0
	var target: float = maxf(1.0, float(_stock_targets.get(res, Balance.STOCK_TARGET_FLOOR)))
	var have: float = resources.get(res, 0.0)
	# Scarcity: worth a great deal when the store is empty, little when it is
	# nearly full, never quite nothing.
	var scarcity := clampf(1.0 - have / target, 0.05, 1.0)
	return y * float(Balance.RESOURCE_VALUE.get(res, 1.0)) * scarcity


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
	# Lay in stores before the fields stop giving. Without this the settlement
	# walked into every winter with a fortnight of food and was caught by the
	# never-lose floor annually - the safety net doing work the planner should
	# have done.
	if season == 2: # autumn
		food_target *= 1.9
	elif season == 3: # winter
		food_target *= 1.35

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
		# Best value first, so the scarcest useful thing gets the people.
		var trades: Array[String] = ["forester", "woodcutter", "quarrier", "miner"]
		trades.sort_custom(func(a: String, c: String) -> bool:
			return marginal_value(a) > marginal_value(c))
		for id in trades:
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

		# Anyone still spare goes on production anyway, even where the stores are
		# comfortable: upgrades unlock on lifetime output, so idle hands are the
		# next doubling not happening. Only the slot-based trades though - farms,
		# woodlots, mines and quarries all have somewhere to put another person,
		# whereas the wild stocks are already worked as hard as they can bear.
		if left > 0:
			var spare: Array[String] = []
			for id in ["farmer", "forester", "miner", "quarrier"]:
				if job_unlocked(id) and job_capacity(id) > int(jobs.get(id, 0)):
					spare.append(id)
			spare.sort_custom(func(a: String, c: String) -> bool:
				return marginal_value(a) > marginal_value(c))
			for id in spare:
				if left <= 0:
					break
				var room := job_capacity(id) - int(jobs.get(id, 0))
				room = mini(room, maxi(0, _saturation_cap(id) - int(jobs.get(id, 0))))
				# An even-ish share so one trade does not swallow everybody.
				var take := clampi(int(ceil(float(left) / float(spare.size()))), 0, room)
				take = mini(take, left)
				jobs[id] = int(jobs.get(id, 0)) + take
				left -= take

		# And whatever is left over thinks. Knowledge is never full, and because
		# upgrades unlock on output rather than headcount there is always another
		# one coming, so this never becomes busy-work.
		if left > 0 and job_unlocked("thinker"):
			# Capped. Everyone spare becoming an elder turned knowledge into a
			# second runaway - and a settlement where four in five people are
			# thinking is not a settlement.
			var think_cap := maxi(1, int(float(total) * 0.35))
			var take := clampi(think_cap - int(jobs.get("thinker", 0)), 0, left)
			jobs["thinker"] = int(jobs.get("thinker", 0)) + take
			left -= take

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

	_explain_plan(food_days, water_days)


## One readable sentence about why the workforce looks the way it does. An
## automation you cannot interrogate is one you cannot trust, and a player who
## does not trust it will not leave it running - which is the whole game.
func _explain_plan(food_days: float, water_days: float) -> void:
	var parts: Array[String] = []
	var n_food: int = int(jobs["hunter"]) + int(jobs["forager"]) + int(jobs["farmer"])
	if n_food > 0:
		var why := "keeping pace"
		if food_days < 3.0:
			why = "the larder is thin"
		elif food_days > 12.0:
			why = "well stocked, so fewer"
		parts.append("%d on food (%s)" % [n_food, why])
	if int(jobs["water_carrier"]) > 0:
		parts.append("%d on water%s" % [int(jobs["water_carrier"]),
				" (running low)" if water_days < 1.5 else ""])
	if int(jobs["explorer"]) > 0:
		parts.append("%d scouting%s" % [int(jobs["explorer"]),
				" (land waiting to be claimed)" if expansion_blocked_by_exploration() else ""])
	if int(jobs["builder"]) > 0 and not build_queue.is_empty():
		parts.append("%d building the %s" % [int(jobs["builder"]),
				Balance.BUILDINGS[build_queue[0]["id"]]["name"]])
	for id in ["forester", "woodcutter", "quarrier", "miner"]:
		if int(jobs[id]) > 0:
			parts.append("%d on %s" % [int(jobs[id]), String(Balance.JOBS[id]["name"]).to_lower()])
	if int(jobs["thinker"]) > 0:
		parts.append("%d thinking" % int(jobs["thinker"]))
	var idle := idle_workers()
	if idle > 0:
		parts.append("%d idle (nothing worth doing)" % idle)
	plan_reason = ", ".join(parts) if not parts.is_empty() else "nobody assigned"


## Which store a job actually fills, for display.
func job_resource(id: String) -> String:
	match String(Balance.JOBS[id]["kind"]):
		"game", "forage", "farm": return "food"
		"forest", "timber": return "wood"
		"water": return "water"
		"stone": return "stone"
		"ore": return "ore"
		"knowledge": return "knowledge"
	return ""


## Where a resource is coming from right now. "+754 wood/day" is fine; "612
## from woodlots, 142 from the wild" is what a player needs to decide what to
## build next.
func rate_breakdown(res: String) -> String:
	var parts: Array[String] = []
	for job_id in Balance.JOB_ORDER:
		if job_resource(job_id) != res:
			continue
		var g := float(gross_by_job.get(job_id, 0.0))
		if g > 0.005:
			parts.append("%s %s" % [Balance.fmt(g), String(Balance.JOBS[job_id]["name"]).to_lower()])
	if res == "knowledge":
		var ambient := Balance.AMBIENT_KNOWLEDGE * sqrt(maxf(population, 1.0)) * _knowledge_mult
		if ambient > 0.005:
			parts.append("%s ambient" % Balance.fmt(ambient))
	if res == "hides":
		var hide_rate := float(gross_by_job.get("hunter", 0.0)) * 0.22
		if hide_rate > 0.005:
			parts.append("%s from the hunt" % Balance.fmt(hide_rate))
	return ", ".join(parts)


# --- Building ---------------------------------------------------------------

## Plain English for what one more of something does. The build list used to
## say what a Woodlot costs and never what it was for.
func building_effect_text(id: String) -> String:
	var eff: Dictionary = Balance.BUILDINGS[id]["effects"]
	var parts: Array[String] = []
	for key in eff:
		match key:
			"housing":
				parts.append("shelters %d more" % int(eff[key]))
			"farm_plots":
				parts.append("+%d farm plot%s (about %s food/day)" % [int(eff[key]),
						"" if int(eff[key]) == 1 else "s",
						Balance.fmt(float(eff[key]) * _farm_per_worker(), 2)])
			"woodlot_slots":
				parts.append("+%d woodlot%s (about %s wood/day)" % [int(eff[key]),
						"" if int(eff[key]) == 1 else "s",
						Balance.fmt(float(eff[key]) * _timber_per_worker(), 2)])
			"mine_slots":
				parts.append("+%d mine shaft%s (about %s ore/day)" % [int(eff[key]),
						"" if int(eff[key]) == 1 else "s",
						Balance.fmt(float(eff[key]) * _ore_per_worker(), 2)])
			"quarry_slots":
				parts.append("+%d quarry face%s (about %s stone/day)" % [int(eff[key]),
						"" if int(eff[key]) == 1 else "s",
						Balance.fmt(float(eff[key]) * _stone_per_worker(), 2)])
			"yield_mult":
				for kind in eff[key]:
					parts.append("+%d%% %s" % [int(round((float(eff[key][kind]) - 1.0) * 100.0)),
							_kind_label(kind)])
			"knowledge_mult":
				parts.append("+%d%% knowledge" % int(round((float(eff[key]) - 1.0) * 100.0)))
			"spoilage_mult":
				parts.append("-%d%% spoilage" % int(round((1.0 - float(eff[key])) * 100.0)))
			"territory":
				parts.append("+%s tiles of range" % Balance.fmt(float(eff[key]), 1))
	return ", ".join(parts)


func _kind_label(kind: String) -> String:
	for job_id in Balance.JOB_ORDER:
		if String(Balance.JOBS[job_id]["kind"]) == kind:
			return String(Balance.JOBS[job_id]["name"]).to_lower()
	return kind


## Days for one more of these to pay for itself, comparing what it costs and
## what it adds in the same currency. Returns -1 when the value is real but not
## measurable this way - housing and range, mostly.
func building_payback_days(id: String) -> float:
	var cost := cost_of(id)
	var spend := 0.0
	for res in cost:
		spend += float(cost[res]) * float(Balance.RESOURCE_VALUE.get(res, 1.0))
	if spend <= 0.0:
		return -1.0

	var eff: Dictionary = Balance.BUILDINGS[id]["effects"]
	var gain := 0.0
	for key in eff:
		match key:
			"farm_plots":
				gain += float(eff[key]) * _farm_per_worker() * float(Balance.RESOURCE_VALUE["food"])
			"woodlot_slots":
				gain += float(eff[key]) * _timber_per_worker() * float(Balance.RESOURCE_VALUE["wood"])
			"mine_slots":
				gain += float(eff[key]) * _ore_per_worker() * float(Balance.RESOURCE_VALUE["ore"])
			"quarry_slots":
				gain += float(eff[key]) * _stone_per_worker() * float(Balance.RESOURCE_VALUE["stone"])
			"yield_mult":
				for kind in eff[key]:
					var res := _kind_resource(kind)
					if res == "":
						continue
					gain += production.get(res, 0.0) * (float(eff[key][kind]) - 1.0) \
							* float(Balance.RESOURCE_VALUE.get(res, 1.0))
			"knowledge_mult":
				gain += production.get("knowledge", 0.0) * (float(eff[key]) - 1.0) \
						* float(Balance.RESOURCE_VALUE["knowledge"])
	if gain <= 0.0001:
		return -1.0
	return spend / gain


func _kind_resource(kind: String) -> String:
	for job_id in Balance.JOB_ORDER:
		if String(Balance.JOBS[job_id]["kind"]) == kind:
			return job_resource(job_id)
	return ""



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
	# Surplus effort rolls on to the next order instead of being thrown away,
	# so a large workforce finishes several things in a step rather than one.
	var guard := 0
	while work > 0.0 and not build_queue.is_empty() and guard < MAX_QUEUED_ORDERS + 2:
		guard += 1
		var order: Dictionary = build_queue[0]
		var needed: float = float(order["total"]) - float(order["work"])
		if work < needed:
			order["work"] = float(order["work"]) + work
			return
		work -= needed
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
## Queue as much as the settlement can actually pay for, up to a few orders.
##
## This used to place one order a day, which quietly capped how fast anything
## could be built no matter how rich the place got - a civilisation producing
## five times as much housed barely more people, because the pipeline, not the
## purse, was the limit.
const MAX_QUEUED_ORDERS := 4


func _auto_build() -> void:
	var guard := 0
	while build_queue.size() < MAX_QUEUED_ORDERS and guard < MAX_QUEUED_ORDERS * 2:
		guard += 1
		var placed := false
		for id in _build_priority():
			if can_build(id):
				queue_building(id)
				placed = true
				break
		if not placed:
			return


func _build_priority() -> Array[String]:
	var list: Array[String] = []
	list.append("firepit")

	# Somewhere for explorers to work out of, early, because exploration gates
	# every other kind of expansion.
	if expansion_blocked_by_exploration():
		list.append("scout_camp")

	# Shelter is built toward what the land can *feed*, not toward how full the
	# huts are right now. Building only at 75% occupancy meant a surplus of food
	# never turned into people - it just sat in the granary, and a well-managed
	# settlement grew no faster than a neglected one. Housing chases the food
	# supply; the food supply is what the player can actually influence.
	var shelter: Array[String] = ["stone_house", "longhouse", "hut", "windbreak"]
	var food_supports: float = production["food"] / Balance.FOOD_PER_PERSON_PER_DAY
	var larder_supports: float = resources["food"] / (Balance.FOOD_PER_PERSON_PER_DAY * 30.0)
	var room_wanted: float = maxf(food_supports, larder_supports)
	# Still never past what the land can carry - housing that outruns food parks
	# everyone at subsistence on the never-lose floor, which looks like growth.
	if housing < room_wanted or population > housing * 0.75:
		if carrying_capacity >= population * 0.95 or housing < room_wanted:
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
	_chronicle("%s." % t["name"], "tech")
	if rng.randf() < 0.22:
		_add_notable("tech", "It was %s that finally settled it." % t["name"])
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


## Branch tiers come as a pair and buying one closes the other for the run.
func is_branch_tier(tier: int) -> bool:
	return Balance.BRANCH_TIERS.has(tier)


func branch_id(kind: String, tier: int, side: String) -> String:
	return "%s_%d_%s" % [kind, tier, side]


## Split an id back into (kind, tier, side). Side is "" for ordinary upgrades.
func upgrade_parts(id: String) -> Array:
	var bits := id.split("_")
	if bits.size() < 2:
		return ["", -1, ""]
	var side := ""
	var tier_at := bits.size() - 1
	if bits[tier_at] == "deep" or bits[tier_at] == "broad":
		side = bits[tier_at]
		tier_at -= 1
	var tier := int(bits[tier_at])
	var kind := "_".join(Array(bits).slice(0, tier_at))
	return [kind, tier, side]


func upgrade_name(id: String) -> String:
	var parts := upgrade_parts(id)
	var kind: String = parts[0]
	var tier: int = parts[1]
	var side: String = parts[2]
	var names: Array = Balance.UPGRADE_NAMES.get(kind, [])
	var base := String(names[tier]) if tier >= 0 and tier < names.size() \
			else "%s improvement %d" % [kind.capitalize(), tier + 1]
	if side == "deep":
		return base + " (Deep)"
	if side == "broad":
		return base + " (Broad)"
	return base


func upgrade_cost(id: String) -> float:
	var tier: int = upgrade_parts(id)[1]
	if tier < 0 or tier >= Balance.UPGRADE_TIERS.size():
		return INF
	return float(Balance.UPGRADE_TIERS[tier]["cost"])


## What buying this would do, in words - the two sides of a branch have to be
## legible or the choice is a coin flip.
func upgrade_effect_text(id: String) -> String:
	var parts := upgrade_parts(id)
	var kind: String = parts[0]
	var side: String = parts[2]
	var partner: String = Balance.BRANCH_PARTNER.get(kind, "")
	if side == "":
		return "%s produce twice as much." % _kind_job_name(kind)
	var spec: Dictionary = Balance.BRANCH_DEEP if side == "deep" else Balance.BRANCH_BROAD
	var self_pct := int(round((float(spec["self"]) - 1.0) * 100.0))
	var other_pct := int(round((float(spec["other"]) - 1.0) * 100.0))
	if partner == "":
		return "%s %+d%%." % [_kind_job_name(kind), self_pct]
	return "%s %+d%%, %s %+d%%." % [_kind_job_name(kind), self_pct,
			_kind_job_name(partner), other_pct]


func _kind_job_name(kind: String) -> String:
	for job_id in Balance.JOB_ORDER:
		if String(Balance.JOBS[job_id]["kind"]) == kind:
			return String(Balance.JOBS[job_id]["name"])
	return kind


## Which job an upgrade improves.
func upgrade_job(id: String) -> String:
	var kind: String = upgrade_parts(id)[0]
	for job_id in Balance.JOB_ORDER:
		if String(Balance.JOBS[job_id]["kind"]) == kind:
			return job_id
	return ""


## Unlocked by lifetime output, not yet bought, and - on a branch tier - not
## closed off by having taken the other side.
func upgrade_offered(id: String) -> bool:
	if upgrades.has(id):
		return false
	var parts := upgrade_parts(id)
	var kind: String = parts[0]
	var tier: int = parts[1]
	var side: String = parts[2]
	if tier < 0 or tier >= Balance.UPGRADE_TIERS.size():
		return false
	if is_branch_tier(tier) != (side != ""):
		return false
	if side != "":
		var other := branch_id(kind, tier, "broad" if side == "deep" else "deep")
		if upgrades.has(other):
			return false
	var job_id := upgrade_job(id)
	if job_id == "" or not job_unlocked(job_id):
		return false
	return float(job_lifetime.get(job_id, 0.0)) >= float(Balance.UPGRADE_TIERS[tier]["output"])


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
			if is_branch_tier(tier):
				for side in ["deep", "broad"]:
					var bid := branch_id(kind, tier, side)
					if upgrade_offered(bid):
						out.append(bid)
			else:
				var uid := upgrade_id(kind, tier)
				if not upgrades.has(uid):
					out.append(uid)
	return out


## Cheapest offered upgrade, without allocating the full list - this runs on the
## housekeeping tick and in the job planner.
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
				break
			var c := float(Balance.UPGRADE_TIERS[tier]["cost"])
			if c >= best_cost:
				continue
			if is_branch_tier(tier):
				# A branch is a decision, so the autopilot leaves it alone - and
				# it is not "the next upgrade" for the purposes of buying either.
				continue
			var uid := upgrade_id(kind, tier)
			if not upgrades.has(uid):
				best_cost = c
				best = uid
	return best


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
	add_log("%s. %s" % [upgrade_name(id), upgrade_effect_text(id)], "tech")
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
	if resources["knowledge"] >= cost and cost <= resources["knowledge"] * 0.5:
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
	_housing_mult = 1.0
	_territory_bonus = 0.0
	# Techs pool together, buildings pool together, and the two pools multiply.
	# Upgrades are the only thing that compounds freely.
	_effect_pool = {}
	for id in techs:
		_apply_effects(Balance.TECHS[id]["effects"], 1)
	var tech_pool := _effect_pool.duplicate()

	_effect_pool = {}
	for id in buildings:
		var bcount: int = buildings[id]
		if bcount > 0:
			_apply_effects(Balance.BUILDINGS[id]["effects"], bcount)
	for kind in tech_pool:
		_yield_mult[kind] = (1.0 + float(tech_pool[kind])) \
				* (1.0 + float(_effect_pool.get(kind, 0.0)))
	for kind in _effect_pool:
		if not tech_pool.has(kind):
			_yield_mult[kind] = 1.0 + float(_effect_pool[kind])

	_legacy_mult = 1.0 + Profile.legacy_points * Balance.LEGACY_BONUS_PER_POINT
	# Permanent unlocks bought with Legacy, applied before anything else.
	if Profile.has_perk("long_memory"):
		_knowledge_mult *= 1.6
	if Profile.has_perk("deep_roots"):
		_birth_mult *= 1.4
		_housing_mult *= 1.25
	if Profile.has_perk("prospectors"):
		_yield_mult["ore"] = float(_yield_mult.get("ore", 1.0)) * 1.5
	if _endowed:
		_knowledge_mult *= 1.30
	if day < _mine_bonus_days:
		_yield_mult["ore"] = float(_yield_mult.get("ore", 1.0)) * 1.35

	for id in upgrades:
		var parts := upgrade_parts(id)
		var kind: String = parts[0]
		var side: String = parts[2]
		if side == "":
			_yield_mult[kind] = float(_yield_mult.get(kind, 1.0)) * Balance.UPGRADE_MULT
			continue
		var spec: Dictionary = Balance.BRANCH_DEEP if side == "deep" else Balance.BRANCH_BROAD
		_yield_mult[kind] = float(_yield_mult.get(kind, 1.0)) * float(spec["self"])
		var partner: String = Balance.BRANCH_PARTNER.get(kind, "")
		if partner != "":
			_yield_mult[partner] = float(_yield_mult.get(partner, 1.0)) * float(spec["other"])

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
				# Additive within the category - see the note on _mult(). The
				# caller decides which pool this lands in.
				for kind in eff[key]:
					var add := (float(eff[key][kind]) - 1.0) * float(count)
					_effect_pool[kind] = float(_effect_pool.get(kind, 0.0)) + add
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
			"housing_mult":
				_housing_mult *= pow(float(eff[key]), count)
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
		_chronicle("The settlement becomes a %s." % e["name"], "era")
		_add_notable("era", "They were there when it became a %s." % e["name"])
		era_advanced.emit(era)


## The current world's seed, as something a player can write down and share.
func world_seed() -> int:
	return world.world_seed if world != null else 0


func world_shape_name() -> String:
	return "" if world == null else String(Balance.world_type_info(world.world_type)["name"])


## Seed and shape in one line, which is the thing worth copying.
func seed_string() -> String:
	return "%d / %s" % [world_seed(), world_shape_name()]


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
	if rng.randf() > Balance.EVENT_CHANCE_PER_DAY * dt:
		return
	_event_cooldown = Balance.EVENT_COOLDOWN_DAYS
	var e: Dictionary = EVENTS[rng.randi() % EVENTS.size()]
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
			var joiners := Balance.migrant_count(population)
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

func _history_to_save() -> Dictionary:
	var out := {}
	for series in Balance.HISTORY_SERIES:
		out[series] = Array(history.get(series, PackedFloat32Array()))
	return out


func _history_from_save(d: Variant) -> void:
	history = {}
	for series in Balance.HISTORY_SERIES:
		var arr := PackedFloat32Array()
		if d is Dictionary and (d as Dictionary).has(series):
			for v in (d as Dictionary)[series]:
				arr.append(float(v))
		history[series] = arr


func to_dict() -> Dictionary:
	return {
		"version": Balance.SAVE_VERSION,
		"day": day,
		"population": population,
		"peak_population": peak_population,
		# Saved so a reloaded game continues the same sequence of events
		# rather than forking into a different one at every load.
		"rng_state": str(rng.state),
		"run_salt": run_salt,
		"Profile.legacy_points": Profile.legacy_points,
		"lifetime_output": lifetime_output,
		"boon_id": boon_id,
		"boon_tile": boon_tile,
		"boon_expires": boon_expires,
		"omen_until": _omen_until,
		"history": _history_to_save(),
		"decree": decree,
		"decree_cooldown": decree_cooldown,
		"council_id": council_id,
		"council_deadline": council_deadline,
		"council_answered": council_answered,
		"council_by_elders": council_by_elders,
		"momentum": momentum,
		"momentum_until": momentum_until,
		"festival_until": festival_until,
		"festival_cooldown": festival_cooldown,
		"outposts": outposts.duplicate(true),
		"settlements": settlements.duplicate(true),
		"settlement_points": settlement_points,
		"settlements_earned": _settlements_earned,
		"season": season,
		"weather": weather,
		"weather_until": weather_until,
		"beat": beat,
		"trade_sell": trade_sell,
		"trade_buy": trade_buy,
		"hunger_days": hunger_days,
		"chronicle": chronicle.duplicate(true),
		"notables": notables.duplicate(true),
		"mine_bonus_days": _mine_bonus_days,
		"endowed": _endowed,
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
	run_salt = int(d.get("run_salt", 0))
	var rs := String(d.get("rng_state", ""))
	if rs.is_valid_int():
		rng.state = int(rs)
	Profile.legacy_points = float(d.get("Profile.legacy_points", 0.0))
	lifetime_output = float(d.get("lifetime_output", 0.0))
	boon_id = String(d.get("boon_id", ""))
	boon_tile = int(d.get("boon_tile", -1))
	boon_expires = float(d.get("boon_expires", 0.0))
	_omen_until = float(d.get("omen_until", -1.0))
	_history_from_save(d.get("history", {}))
	decree = String(d.get("decree", ""))
	decree_cooldown = float(d.get("decree_cooldown", 0.0))
	council_id = String(d.get("council_id", ""))
	council_deadline = float(d.get("council_deadline", 0.0))
	council_answered = int(d.get("council_answered", 0))
	council_by_elders = int(d.get("council_by_elders", 0))
	momentum = int(d.get("momentum", 0))
	momentum_until = float(d.get("momentum_until", -1.0))
	festival_until = float(d.get("festival_until", -1.0))
	festival_cooldown = float(d.get("festival_cooldown", 0.0))
	season = int(d.get("season", 0))
	weather = clampi(int(d.get("weather", 0)), 0, Balance.WEATHER.size() - 1)
	weather_until = float(d.get("weather_until", 0.0))
	beat = int(d.get("beat", 0))
	trade_sell = String(d.get("trade_sell", ""))
	trade_buy = String(d.get("trade_buy", ""))
	hunger_days = float(d.get("hunger_days", 0.0))
	chronicle.clear()
	for c in d.get("chronicle", []):
		if c is Dictionary:
			chronicle.append(c)
	notables.clear()
	for n in d.get("notables", []):
		if n is Dictionary:
			notables.append(n)
	_mine_bonus_days = float(d.get("mine_bonus_days", -1.0))
	_endowed = bool(d.get("endowed", false))
	settlement_points = int(d.get("settlement_points", 0))
	_settlements_earned = int(d.get("settlements_earned", 0))
	settlements.clear()
	for sv in d.get("settlements", []):
		if sv is Dictionary:
			settlements.append({"tile": int(sv.get("tile", 0)), "value": sv.get("value", {})})
	outposts.clear()
	for o in d.get("outposts", []):
		if o is Dictionary:
			outposts.append({"tile": int(o.get("tile", 0)), "value": o.get("value", {})})
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
