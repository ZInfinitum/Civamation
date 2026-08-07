extends Node
## Headless balance harness.
##
##   godot --headless --path . res://tools/HeadlessSim.tscn -- --days 4000 --seeds 5
##
## Runs the simulation with nobody at the controls (pure auto-assign,
## auto-research, and a simple build AI) and prints a trajectory. If the game is
## unplayable on autopilot it is unplayable, full stop - so this doubles as the
## smoke test CI runs on every push.

const DEFAULT_DAYS := 4000
const DEFAULT_SEEDS := 3
const REPORT_EVERY := 250

var _failures: Array[String] = []
## The harness's own sampling, kept off the global RNG for the same reason the
## simulation is: a regression test that cannot reproduce its own numbers is
## not measuring anything.
var _rng := RandomNumberGenerator.new()


func _snapshot_profile() -> Dictionary:
	return {
		"points": Profile.legacy_points, "perks": Profile.perks.duplicate(),
		"achievements": Profile.achievements.duplicate(),
		"shapes": Profile.shapes_played.duplicate(), "runs": Profile.runs_completed,
		"best": Profile.best_population,
	}


func _restore_profile(d: Dictionary) -> void:
	Profile.legacy_points = float(d["points"])
	Profile.perks.assign(d["perks"])
	Profile.achievements.assign(d["achievements"])
	Profile.shapes_played.assign(d["shapes"])
	Profile.runs_completed = int(d["runs"])
	Profile.best_population = float(d["best"])
	Profile.save_profile()


func _ready() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--days" and i + 1 < args.size():
			days = int(args[i + 1])
		elif args[i] == "--seeds" and i + 1 < args.size():
			seeds = int(args[i + 1])

	# Run against an empty profile, and put the real one back afterwards.
	#
	# Legacy lives in user://profile.cfg and is deliberately *not* reset between
	# runs - which meant the harness banked points into it every time it ran, and
	# legacy is a flat percentage on every trade. So each run started richer than
	# the last and no two runs produced the same numbers. Every balance figure
	# this tool printed was quietly a function of how many times it had been run
	# before, which is the exact opposite of what a regression test is for. It
	# also silently spent the developer's own profile.
	var saved := _snapshot_profile()
	Profile.wipe()
	# Pin the per-run salt, so every new_game below reproduces exactly. The real
	# game deliberately rolls it, so two players on one seed get the same world
	# and different weather.
	Sim.deterministic = true

	for s in range(1, seeds + 1):
		# Cycle the world shapes so every generator path is covered.
		_run_seed(s * 1337, days, (s - 1) % Balance.WORLD_TYPES.size())

	_test_save_load()
	_test_legacy()
	_test_baseline()
	_test_engagement()
	_test_settlements()

	_restore_profile(saved)

	print("")
	if _failures.is_empty():
		print("PASS - all %d worlds survived %d days." % [seeds, days])
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - " + f)
		get_tree().quit(1)


func _run_seed(seed_value: int, days: int, world_type: int = 0) -> void:
	Sim.new_game(seed_value, world_type)
	Sim.speed_index = 0 # nothing should advance behind our back

	print("")
	print("=== seed %d, %s ===" % [seed_value, Balance.world_type_info(world_type)["name"]])
	print("day    pop     K      food   wood   ore    gold   herd forest expl%  techs up era metal    jobs")

	var peak_pop := Sim.population
	var min_pop_after_peak := Sim.population
	var chunk := 10.0

	var elapsed := 0.0
	var next_report := 0.0
	while elapsed < float(days):
		Sim.simulate_days(chunk, true)
		elapsed += chunk

		peak_pop = maxf(peak_pop, Sim.population)
		if Sim.population > peak_pop * 0.999:
			min_pop_after_peak = Sim.population
		else:
			min_pop_after_peak = minf(min_pop_after_peak, Sim.population)

		if elapsed >= next_report:
			next_report += REPORT_EVERY
			_report()

	_report()
	var drawdown := 1.0 - min_pop_after_peak / maxf(peak_pop, 1.0)
	print("peak pop %.0f, deepest crash after peak %.0f%%, techs %d/%d, era %d"
			% [peak_pop, drawdown * 100.0, Sim.techs.size(), Balance.TECHS.size(), Sim.era])

	# Assertions: the run has to actually go somewhere.
	var w := Sim.world
	if Sim.population < 12.0:
		_failures.append("seed %d: population stalled at %.1f" % [seed_value, Sim.population])
	if w.explored_fraction() < 0.05:
		_failures.append("seed %d: explorers mapped only %.1f%% of the world"
				% [seed_value, w.explored_fraction() * 100.0])
	if Sim.techs.size() < 6:
		_failures.append("seed %d: only %d techs after %d days" % [seed_value, Sim.techs.size(), days])
	# The promise: no run ever loses more than a quarter of its high-water mark.
	if drawdown > 0.26:
		_failures.append("seed %d: drawdown of %.0f%% breaks the never-lose floor"
				% [seed_value, drawdown * 100.0])
	# Every living stock must still be alive and recovering, never stripped bare.
	var floor_pct := Balance.STOCK_REFUGE * 100.0 - 1.0
	for pair in [["herds", w.stock_health(w.game, w.game_cap)],
			["plants", w.stock_health(w.forage, w.forage_cap)],
			["forest", w.stock_health(w.forest, w.forest_cap)]]:
		if float(pair[1]) * 100.0 < floor_pct:
			_failures.append("seed %d: %s stripped to %.0f%%, below the refuge floor"
					% [seed_value, pair[0], float(pair[1]) * 100.0])
	if is_nan(Sim.population) or is_inf(Sim.population):
		_failures.append("seed %d: population went non-finite" % seed_value)
	for id in Balance.RESOURCE_ORDER:
		var v: float = Sim.resources[id]
		if is_nan(v) or is_inf(v) or v < -0.001:
			_failures.append("seed %d: resource %s is %f" % [seed_value, id, v])


## Round-trip the whole game state through the save file and make sure what
## comes back is what went in. A background idle game is only as good as its
## persistence: the player closes the tab, and everything must survive.
func _test_save_load() -> void:
	print("")
	print("=== save / load round trip ===")
	Sim.new_game(90210, Balance.WorldType.CONTINENTS)
	Sim.speed_index = 0
	Sim.simulate_days(400.0, true)
	for id in ["firepit", "windbreak", "windbreak"]:
		if Sim.can_build(id):
			Sim.queue_building(id)
	Sim.simulate_days(60.0, true)

	var before := {
		"day": Sim.day,
		"population": Sim.population,
		"peak": Sim.peak_population,
		"era": Sim.era,
		"techs": Sim.techs.size(),
		"seed": Sim.world.world_seed,
		"origin": Sim.world.origin,
		"game": Sim.world.total_of(Sim.world.game),
		"forest": Sim.world.total_of(Sim.world.forest),
		"radius": Sim.world.territory_radius,
		"terr": Sim.world.territory.size(),
		"game0": float(Sim.world.game[Sim.world.territory[0]]),
		"explored": Sim.world.explored_count,
		"world_type": Sim.world.world_type,
		"upgrades": Sim.upgrades.size(),
	}
	for id in Balance.RESOURCE_ORDER:
		before["res_" + id] = float(Sim.resources[id])
	for id in Balance.BUILDING_ORDER:
		before["b_" + id] = int(Sim.buildings[id])

	SaveSystem.save_game()
	if not SaveSystem.has_save():
		_failures.append("save/load: no save file was written")
		return
	# Wipe the state completely so a silent no-op load cannot pass this test.
	Sim.new_game(11111, Balance.WorldType.ARCHIPELAGO)
	Sim.speed_index = 0
	if not SaveSystem.load_game():
		_failures.append("save/load: load_game() reported failure")
		return

	var after := {
		"day": Sim.day,
		"population": Sim.population,
		"peak": Sim.peak_population,
		"era": Sim.era,
		"techs": Sim.techs.size(),
		"seed": Sim.world.world_seed,
		"origin": Sim.world.origin,
		"game": Sim.world.total_of(Sim.world.game),
		"forest": Sim.world.total_of(Sim.world.forest),
		"radius": Sim.world.territory_radius,
		"terr": Sim.world.territory.size(),
		"game0": float(Sim.world.game[Sim.world.territory[0]]),
		"explored": Sim.world.explored_count,
		"world_type": Sim.world.world_type,
		"upgrades": Sim.upgrades.size(),
	}
	for id in Balance.RESOURCE_ORDER:
		after["res_" + id] = float(Sim.resources[id])
	for id in Balance.BUILDING_ORDER:
		after["b_" + id] = int(Sim.buildings[id])

	var mismatches := 0
	for key in before:
		var a: Variant = before[key]
		var b: Variant = after[key]
		var same := false
		if a is float:
			same = absf(float(a) - float(b)) <= maxf(0.01, absf(float(a)) * 0.001)
		else:
			same = a == b
		if not same:
			mismatches += 1
			_failures.append("save/load: %s was %s, came back %s" % [key, a, b])
	print("day %.0f, pop %.0f, %d techs, %d fields compared, %d mismatched"
			% [Sim.day, Sim.population, Sim.techs.size(), before.size(), mismatches])
	SaveSystem.delete_save()


## Prestige has to actually carry forward, and the next run has to start
## measurably better - otherwise the whole layer is decoration.
func _test_legacy() -> void:
	print("")
	print("=== legacy ===")
	Sim.new_game(4242, Balance.WorldType.CONTINENTS)
	Sim.speed_index = 0
	# Run until the civilisation has done enough to be worth remembering. How
	# long that takes varies enormously between seeds - an exponential economy
	# compounds small early differences - so this waits rather than assuming a
	# fixed number of days is always sufficient.
	var waited := 0.0
	while waited < 2000.0 and not Sim.can_ascend():
		Sim.simulate_days(100.0, true)
		waited += 100.0
	var offer := Sim.legacy_on_offer()
	var pop_before := Sim.population
	# Legacy lives in the profile, which is deliberately *not* reset between
	# runs - so the assertion is on what this ascension added, not on the total.
	# Comparing against the total made the test pass or fail depending on
	# whatever happened to be in user://profile.cfg.
	var banked_before := Profile.legacy_points
	if not Sim.can_ascend():
		_failures.append("legacy: %d days earned only %.1f points - nothing is worth "
				% [int(waited), offer] + "setting down")
		return
	if not Sim.ascend(Balance.WorldType.EARTH):
		_failures.append("legacy: ascend refused with %.1f points on offer" % offer)
		return
	var gained := Profile.legacy_points - banked_before
	if not is_equal_approx(gained, offer):
		_failures.append("legacy: carried %.2f forward, expected %.2f" % [gained, offer])
	if Sim.day > 1.0 or Sim.population > 10.0:
		_failures.append("legacy: the new world did not actually start over")
	Sim.simulate_days(300.0, true)
	print("worth setting down after %d days; earned %.0f points; %.0f people before, "
			% [int(waited), gained, pop_before]
			+ "%.0f in the next run's first 300 days" % Sim.population)
	if Sim.population < 20.0:
		_failures.append("legacy: the run after ascending stalled at %.0f" % Sim.population)


## A silent balance regression should break the build, not be discovered in
## play three weeks later. Wide tolerances - this catches things falling over,
## not honest tuning.
const BASELINE := {"day": 500.0, "pop_min": 300.0, "pop_max": 40000.0,
	"techs_min": 18, "explored_min": 0.25}


func _test_baseline() -> void:
	print("")
	print("=== baseline (seed 1337, Earth, day %d) ===" % int(BASELINE["day"]))
	Sim.new_game(1337, Balance.WorldType.EARTH)
	Sim.speed_index = 0
	Sim.simulate_days(float(BASELINE["day"]), true)
	print("pop %s, %d techs, %d upgrades, %.0f%% mapped, era %d"
			% [Balance.fmt_count(Sim.population), Sim.techs.size(), Sim.upgrades.size(),
			Sim.world.explored_fraction() * 100.0, Sim.era])
	if Sim.population < float(BASELINE["pop_min"]) or Sim.population > float(BASELINE["pop_max"]):
		_failures.append("baseline: population %.0f outside %.0f-%.0f"
				% [Sim.population, float(BASELINE["pop_min"]), float(BASELINE["pop_max"])])
	if Sim.techs.size() < int(BASELINE["techs_min"]):
		_failures.append("baseline: only %d techs by day %d"
				% [Sim.techs.size(), int(BASELINE["day"])])
	if Sim.world.explored_fraction() < float(BASELINE["explored_min"]):
		_failures.append("baseline: only %.0f%% mapped"
				% (Sim.world.explored_fraction() * 100.0))


## The design's central claim, measured rather than asserted: a player who
## actually manages the settlement should beat one who leaves it running.
##
## Same seed, same length, same autopilots. The only difference is that one run
## uses the levers the elders will not touch - decrees, council answers,
## festivals, boons, outposts. If the gap is not there, the management layer is
## decoration and the design has failed.
const ENGAGEMENT_DAYS := 900.0
## The margin the managed run has to win by to count as a real difference.
const ENGAGEMENT_MIN_EDGE := 1.25


func _test_engagement() -> void:
	print("")
	print("=== managed vs left alone (seed 777, %d days) ===" % int(ENGAGEMENT_DAYS))

	_rng.seed = 90210
	Sim.new_game(777, Balance.WorldType.CONTINENTS)
	Sim.speed_index = 0
	Sim.simulate_days(ENGAGEMENT_DAYS, true)
	var idle_pop := Sim.population
	var idle_out := Sim.lifetime_output
	var idle_legacy := Sim.legacy_on_offer()
	print("left alone: %s people, %s lifetime output, %s Legacy on offer"
			% [Balance.fmt_count(idle_pop), Balance.fmt(idle_out), Balance.fmt(idle_legacy)])

	_rng.seed = 90210
	Sim.new_game(777, Balance.WorldType.CONTINENTS)
	Sim.speed_index = 0
	var elapsed := 0.0
	while elapsed < ENGAGEMENT_DAYS:
		Sim.simulate_days(8.0, true)
		elapsed += 8.0
		_play_actively()
	var play_pop := Sim.population
	var play_out := Sim.lifetime_output
	print("managed:    %s people, %s lifetime output, %s Legacy on offer"
			% [Balance.fmt_count(play_pop), Balance.fmt(play_out), Balance.fmt(Sim.legacy_on_offer())])
	print("            %d council questions answered, %d left to the elders, %d outposts"
			% [Sim.council_answered - Sim.council_by_elders, Sim.council_by_elders,
			Sim.outposts.size()])

	var pop_edge := play_pop / maxf(idle_pop, 1.0)
	var out_edge := play_out / maxf(idle_out, 1.0)
	print("edge: %.2fx population, %.2fx lifetime output" % [pop_edge, out_edge])
	if out_edge < ENGAGEMENT_MIN_EDGE:
		_failures.append("engagement: managing gains only %.2fx lifetime output - "
				% out_edge + "the management layer is not worth using")
	# The headline number has to move too. A five-fold economy that houses the
	# same number of people does not *look* like better play, whatever the
	# spreadsheet says.
	if pop_edge < 1.15:
		_failures.append("engagement: managing gains only %.2fx population - the number "
				% pop_edge + "the player actually watches barely responds")


## A reasonably attentive player: catches boons, answers the council, keeps a
## decree matched to the bottleneck, throws a festival when it can, and plants
## outposts on good ground.
func _play_actively() -> void:
	if Sim.boon_id != "":
		Sim.collect_boon()
	if Sim.council_id != "":
		Sim.answer_council(_best_council_option(Sim.council_id))
	if Sim.can_hold_festival() and Sim.population > 40.0:
		Sim.hold_festival()
	if Sim.can_set_decree():
		var want := _pick_decree()
		if want != Sim.decree:
			Sim.set_decree(want)
	_maybe_outpost()


## Deliberately not optimal - just sensible. A real player would do better.
func _pick_decree() -> String:
	if Sim.expansion_blocked_by_exploration():
		return "expansion"
	if Sim.researching != "" and Sim.resources["knowledge"] < Sim.research_cost():
		return "learning"
	if Sim.mine_slots() < Sim.population * 0.08 or Sim.resources["stone"] < Sim.population * 2.0:
		return "industry"
	if Sim.carrying_capacity > Sim.population * 1.2:
		return "the_hearth"
	return "the_land"


func _best_council_option(id: String) -> String:
	match id:
		"hard_winter":
			return "slaughter" if Sim.food_satisfaction < 0.98 else "trust"
		"strangers":
			return "take_in" if Sim.carrying_capacity > Sim.population * 1.1 else "trade"
		"the_seam":
			return "shore_up"
		"the_river":
			return "dig"
		"the_teacher":
			return "endow" if Sim.resources["food"] > Sim.population * 20.0 else "allow"
	return ""


func _maybe_outpost() -> void:
	if Sim.outposts.size() >= 3 or Sim.world == null:
		return
	var best := -1
	var best_score := 0.0
	# Sample rather than sweep - a player eyeballs the map, they do not solve it.
	for probe in 220:
		var i := _rng.randi() % Sim.world.explored.size()
		if not Sim.can_found_outpost(i):
			continue
		var v := Sim.outpost_value(i)
		var score := float(v.get("food", 0.0)) + float(v.get("ore", 0.0)) * 2.0 \
				+ float(v.get("wood", 0.0)) + float(v.get("stone", 0.0))
		if score > best_score:
			best_score = score
			best = i
	if best >= 0:
		Sim.found_outpost(best)


func _report() -> void:
	var w := Sim.world
	print("%-6d %-7s %-6s %-6s %-6s %-6s %-6s %-4.0f %-6.0f %-6.0f %-5d %-2d %-3d %-8s %s" % [
		int(Sim.day), Balance.fmt_count(Sim.population), Balance.fmt(Sim.carrying_capacity),
		Balance.fmt(Sim.resources["food"]), Balance.fmt(Sim.resources["wood"]),
		Balance.fmt(Sim.resources["ore"]), Balance.fmt(Sim.resources["gold"]),
		w.stock_health(w.game, w.game_cap) * 100.0,
		w.stock_health(w.forest, w.forest_cap) * 100.0,
		w.explored_fraction() * 100.0,
		Sim.techs.size(), Sim.upgrades.size(), Sim.era,
		Sim.ore_name() if Sim.job_unlocked("miner") else "-",
		_job_summary(),
	])


## Two letters collided - forager and forester both came out "fo", which made
## every job line in the trace ambiguous exactly where the wood economy needed
## reading. Spelled out where the prefix is not unique.
const JOB_ABBREV := {
	"hunter": "hunt", "forager": "forage", "woodcutter": "wood",
	"water_carrier": "water", "explorer": "scout", "builder": "build",
	"farmer": "farm", "forester": "wood+", "quarrier": "quarry",
	"miner": "mine", "thinker": "think",
}


## Settlements are earned, placed by hand, and then have to actually do
## something - otherwise the whole layer is a button that spends a number.
func _test_settlements() -> void:
	print("")
	print("=== settlements ===")
	Sim.new_game(31415, Balance.WorldType.CONTINENTS)
	Sim.speed_index = 0
	Sim.simulate_days(600.0, true)

	if Sim.settlement_points <= 0:
		_failures.append("settlements: %.0f people and not one point earned"
				% Sim.population)
		return

	# The cheat has to work too - it is the only way to try this early.
	var before_points := Sim.settlement_points
	Sim.grant_settlement_point()
	if Sim.settlement_points != before_points + 1:
		_failures.append("settlements: the cheat did not grant a point")

	var site := -1
	for i in Sim.world.explored.size():
		if Sim.can_found_settlement(i):
			site = i
			break
	if site < 0:
		# Say *why*, or this failure is a guessing game.
		var walked := 0
		var far_enough := 0
		var buildable := 0
		for i in Sim.world.explored.size():
			if Sim.world.explored[i] == 0:
				continue
			walked += 1
			if Vector2(Sim.world.tile_pos(i) - Sim.world.origin).length() \
					< Balance.SETTLEMENT_MIN_DISTANCE:
				continue
			far_enough += 1
			if Sim.world.workable(i) and not Balance.is_water_biome(Sim.world.biome[i]):
				buildable += 1
		var cost := Sim.settlement_cost()
		var afford := "yes"
		for res in cost:
			if Sim.resources.get(res, 0.0) < float(cost[res]):
				afford = "no - %s %s of %s" % [res,
						Balance.fmt(Sim.resources.get(res, 0.0)), Balance.fmt(float(cost[res]))]
		_failures.append(("settlements: %d points and nowhere legal. "
				% Sim.settlement_points)
				+ "%d walked, %d far enough out, %d of those buildable, affordable: %s"
				% [walked, far_enough, buildable, afford])
		return

	var radius_before := Sim.world.territory_radius
	var housing_before := Sim.housing
	var points_before := Sim.settlement_points
	if not Sim.found_settlement(site):
		_failures.append("settlements: founding refused on a tile that said it was legal")
		return
	Sim.simulate_days(20.0, true)

	print("earned %d points by day 600; founded one %d tiles out"
			% [before_points, int(Vector2(Sim.world.tile_pos(site) - Sim.world.origin).length())])
	print("territory %.1f -> %.1f, housing %s -> %s"
			% [radius_before, Sim.world.territory_radius,
			Balance.fmt_count(housing_before), Balance.fmt_count(Sim.housing)])

	if Sim.settlement_points != points_before - 1:
		_failures.append("settlements: founding did not spend a point")
	if Sim.settlements.size() != 1:
		_failures.append("settlements: founded one and there are %d" % Sim.settlements.size())
	if Sim.housing <= housing_before:
		_failures.append("settlements: housing did not rise - a settlement is somewhere people live")
	if Sim.world.territory_radius <= radius_before:
		_failures.append("settlements: territory did not grow around the new settlement")
	# And it must survive a save.
	SaveSystem.save_game()
	Sim.new_game(11111, Balance.WorldType.ISLANDS)
	Sim.speed_index = 0
	SaveSystem.load_game()
	if Sim.settlements.size() != 1:
		_failures.append("settlements: did not survive a save round trip")


func _job_summary() -> String:
	var parts: Array[String] = []
	for id in Balance.JOB_ORDER:
		var n: int = Sim.jobs.get(id, 0)
		if n > 0:
			parts.append("%s%d" % [String(JOB_ABBREV.get(id, id.substr(0, 4))), n])
	return " ".join(parts)
