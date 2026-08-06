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


func _ready() -> void:
	var days := DEFAULT_DAYS
	var seeds := DEFAULT_SEEDS
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--days" and i + 1 < args.size():
			days = int(args[i + 1])
		elif args[i] == "--seeds" and i + 1 < args.size():
			seeds = int(args[i + 1])

	for s in range(1, seeds + 1):
		_run_seed(s * 1337, days)

	_test_save_load()

	print("")
	if _failures.is_empty():
		print("PASS - all %d worlds survived %d days." % [seeds, days])
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - " + f)
		get_tree().quit(1)


func _run_seed(seed_value: int, days: int) -> void:
	Sim.new_game(seed_value)
	Sim.speed_index = 0 # nothing should advance behind our back

	print("")
	print("=== seed %d ===" % seed_value)
	print("day    pop    K     food   wood   ore    gold   herd  plants forest  techs era  metal    jobs")

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
	Sim.new_game(90210)
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
	Sim.new_game(11111)
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


func _report() -> void:
	var w := Sim.world
	print("%-6d %-6.0f %-5.0f %-6.0f %-6.0f %-6.0f %-6.0f %-5.0f %-6.0f %-7.0f %-5d %-4d %-8s %s" % [
		int(Sim.day), Sim.population, Sim.carrying_capacity,
		Sim.resources["food"], Sim.resources["wood"],
		Sim.resources["ore"], Sim.resources["gold"],
		w.stock_health(w.game, w.game_cap) * 100.0,
		w.stock_health(w.forage, w.forage_cap) * 100.0,
		w.stock_health(w.forest, w.forest_cap) * 100.0,
		Sim.techs.size(), Sim.era,
		Sim.ore_name() if Sim.job_unlocked("miner") else "-",
		_job_summary(),
	])


func _job_summary() -> String:
	var parts: Array[String] = []
	for id in Balance.JOB_ORDER:
		var n: int = Sim.jobs.get(id, 0)
		if n > 0:
			parts.append("%s%d" % [id.substr(0, 2), n])
	return " ".join(parts)
