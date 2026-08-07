extends Node
## Long-run soak test.
##
##   godot --headless --path . res://tools/Soak.tscn -- --seeds 30 --days 8000
##
## The balance harness answers "does a run survive". This answers "what does a
## run *look like* over its whole life, across many worlds" - which is a
## different question and the only way to find the flat patches, the runaway
## seeds and the things that only break after an hour.
##
## Everything is deterministic (see Sim.deterministic), so a finding here can be
## reproduced exactly by re-running with the same arguments.
##
## Output is two things: a per-seed trace to stdout, and a CSV of every sample
## to user://soak.csv for anything that wants a spreadsheet.

const DEFAULT_SEEDS := 24
const DEFAULT_DAYS := 8000
const SAMPLE_EVERY := 250.0
## A run that has not grown by this fraction over a whole stall window is stuck.
const STALL_WINDOW_DAYS := 1000.0
const STALL_GROWTH := 0.02

var _rows: Array[Dictionary] = []
var _seeds: Array[Dictionary] = []
var _notes: Array[String] = []


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
	var seeds := DEFAULT_SEEDS
	var days := DEFAULT_DAYS
	var out := "user://soak.csv"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--seeds" and i + 1 < args.size():
			seeds = int(args[i + 1])
		elif args[i] == "--days" and i + 1 < args.size():
			days = int(args[i + 1])
		elif args[i] == "--out" and i + 1 < args.size():
			out = args[i + 1]

	var saved := _snapshot_profile()
	Profile.wipe()
	# Legacy must not carry between soak runs or every seed after the first is
	# measuring a different game from the one before it.
	Sim.deterministic = true

	print("SOAK: %d seeds x %d days, sampling every %d"
			% [seeds, days, int(SAMPLE_EVERY)])
	print("")

	var started := Time.get_ticks_msec()
	for s in range(seeds):
		# Every seed keeps its own wiped profile, so seed 20 is not quietly
		# richer than seed 1.
		Profile.wipe()
		_run_one(s, (s * 7919) % 999983 + 1, days, (s % Balance.WORLD_TYPES.size()))
		print("  ... %d/%d done, %.1f min elapsed"
				% [s + 1, seeds, float(Time.get_ticks_msec() - started) / 60000.0])

	_restore_profile(saved)
	_write_csv(out)
	_report(days)
	get_tree().quit(0 if _notes.is_empty() else 0)


func _run_one(index: int, world_seed: int, days: int, world_type: int) -> void:
	Sim.new_game(world_seed, world_type)
	Sim.speed_index = 0

	var peak := Sim.population
	var trough_after_peak := Sim.population
	var worst_drawdown := 0.0
	var hungry_days := 0.0
	var era_days := {}
	var techs_done_day := -1.0
	var last_stall_pop := Sim.population
	var last_stall_day := 0.0
	var stalled_from := -1.0
	var samples := 0
	var dependency_peak := 0.0
	var seams_at_end := 0
	var herd_min := 1.0
	var herd_sum := 0.0
	var herd_n := 0

	var elapsed := 0.0
	var next_sample := 0.0
	var chunk := 10.0
	while elapsed < float(days):
		Sim.simulate_days(chunk, true)
		elapsed += chunk

		if Sim.food_satisfaction < Balance.FAMINE_THRESHOLD:
			hungry_days += chunk

		peak = maxf(peak, Sim.population)
		if Sim.population > peak * 0.999:
			trough_after_peak = Sim.population
		else:
			trough_after_peak = minf(trough_after_peak, Sim.population)
		worst_drawdown = maxf(worst_drawdown, 1.0 - trough_after_peak / maxf(peak, 1.0))

		if not era_days.has(Sim.era):
			era_days[Sim.era] = elapsed
		if techs_done_day < 0.0 and Sim.techs.size() >= Balance.TECHS.size():
			techs_done_day = elapsed

		# Stall detection: a whole window with essentially no growth.
		if elapsed - last_stall_day >= STALL_WINDOW_DAYS:
			var grew := Sim.population / maxf(last_stall_pop, 1.0) - 1.0
			if grew < STALL_GROWTH and stalled_from < 0.0:
				stalled_from = last_stall_day
			last_stall_pop = Sim.population
			last_stall_day = elapsed

		# Sampled every chunk rather than every report, so a brief collapse
		# between samples cannot hide.
		var hh := Sim.world.stock_health(Sim.world.game, Sim.world.game_cap)
		herd_min = minf(herd_min, hh)
		herd_sum += hh
		herd_n += 1
		var dep := (Sim.children() + Sim.retired()) / maxf(Sim.population, 1.0)
		dependency_peak = maxf(dependency_peak, dep)

		if elapsed >= next_sample:
			next_sample += SAMPLE_EVERY
			samples += 1
			_rows.append({
				"seed": world_seed, "shape": world_type, "day": elapsed,
				"pop": Sim.population, "k": Sim.carrying_capacity,
				"era": Sim.era, "techs": Sim.techs.size(), "upgrades": Sim.upgrades.size(),
				"output": Sim.lifetime_output,
				"food": Sim.resources["food"], "wood": Sim.resources["wood"],
				"ore": Sim.resources["ore"], "knowledge": Sim.resources["knowledge"],
				"thinkers": int(Sim.jobs.get("thinker", 0)),
				"workforce": Sim.workforce(),
				"herd": Sim.world.stock_health(Sim.world.game, Sim.world.game_cap),
				"forest": Sim.world.stock_health(Sim.world.forest, Sim.world.forest_cap),
				"settlements": Sim.settlements.size(),
				"snow": Sim.snow_depth,
				"temp": Sim.temperature(),
				# Demographics - the whole reason the age bands exist is that
				# these can differ while population looks identical.
				"children": Sim.children(),
				"retired": Sim.retired(),
				"mean_age": Sim.mean_age(),
				"eaters": Sim.eaters(),
				"deaths_age": Sim.deaths_age,
				"deaths_hunger": Sim.deaths_hunger,
				# Is the map still producing news?
				"seams": Sim.deposits_found(),
				"seams_total": Sim.deposits_total(),
				# Is the economy actually in balance, or held up by a floor?
				"food_sat": Sim.food_satisfaction,
				"housing": Sim.housing,
				"forage": Sim.world.stock_health(Sim.world.forage, Sim.world.forage_cap),
			})

	var bad := ""
	if is_nan(Sim.population) or is_inf(Sim.population):
		bad = "population went non-finite"
	for id in Balance.RESOURCE_ORDER:
		var v: float = Sim.resources[id]
		if is_nan(v) or is_inf(v) or v < -0.001:
			bad = "resource %s is %f" % [id, v]

	_seeds.append({
		"seed": world_seed, "shape": world_type, "pop": Sim.population, "peak": peak,
		"era": Sim.era, "techs": Sim.techs.size(), "upgrades": Sim.upgrades.size(),
		"output": Sim.lifetime_output, "drawdown": worst_drawdown,
		"hungry": hungry_days, "hungry_pct": hungry_days / maxf(float(days), 1.0),
		"era_days": era_days, "techs_done": techs_done_day,
		"stalled_from": stalled_from, "bad": bad,
		"thinker_share": float(Sim.jobs.get("thinker", 0)) / maxf(float(Sim.workforce()), 1.0),
		"herd": Sim.world.stock_health(Sim.world.game, Sim.world.game_cap),
		"herd_min": herd_min,
		"herd_mean": herd_sum / maxf(float(herd_n), 1.0),
		"dependency": (Sim.children() + Sim.retired()) / maxf(Sim.population, 1.0),
		"dependency_peak": dependency_peak,
		"mean_age": Sim.mean_age(),
		"deaths_age": Sim.deaths_age,
		"deaths_hunger": Sim.deaths_hunger,
		"seams": Sim.deposits_found(),
		"seams_total": Sim.deposits_total(),
		"settlements": Sim.settlements.size(),
	})

	print("seed %-7d %-12s pop %-10s era %d  techs %2d  up %2d  out %-9s "
			% [world_seed, String(Balance.world_type_info(world_type)["name"]),
			Balance.fmt_count(Sim.population), Sim.era, Sim.techs.size(),
			Sim.upgrades.size(), Balance.fmt(Sim.lifetime_output)]
			+ "drawdown %2.0f%%  hungry %2.0f%%%s"
			% [worst_drawdown * 100.0, hungry_days / maxf(float(days), 1.0) * 100.0,
			("  STALLED from day %d" % int(stalled_from)) if stalled_from >= 0.0 else ""])
	if bad != "":
		print("     !! " + bad)


# --- Reporting --------------------------------------------------------------

func _pct(values: Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var v := values.duplicate()
	v.sort()
	var i := clampi(int(round(q * float(v.size() - 1))), 0, v.size() - 1)
	return float(v[i])


func _report(days: int) -> void:
	print("")
	print("=" .repeat(78))
	print("AGGREGATE - %d worlds, %d days each" % [_seeds.size(), days])
	print("=" .repeat(78))

	# How the population spreads over time. This is the shape of the game.
	print("")
	print("population across all worlds")
	print("day      min        p25        median     p75        max        spread")
	var by_day := {}
	for r in _rows:
		var d := int(r["day"])
		if not by_day.has(d):
			by_day[d] = []
		(by_day[d] as Array).append(float(r["pop"]))
	var day_keys := by_day.keys()
	day_keys.sort()
	for d in day_keys:
		if d % 1000 != 0 and d != 250 and d != 500:
			continue
		var vals: Array = by_day[d]
		var lo := _pct(vals, 0.0)
		var hi := _pct(vals, 1.0)
		print("%-8d %-10s %-10s %-10s %-10s %-10s %.1fx"
				% [d, Balance.fmt_count(lo), Balance.fmt_count(_pct(vals, 0.25)),
				Balance.fmt_count(_pct(vals, 0.5)), Balance.fmt_count(_pct(vals, 0.75)),
				Balance.fmt_count(hi), hi / maxf(lo, 1.0)])

	# Growth rate late on: is the line still going up?
	print("")
	print("late-game growth - median population, and the multiple over the previous sample")
	var prev := 0.0
	for d in day_keys:
		if d < int(float(days) * 0.5) or d % 1000 != 0:
			continue
		var med := _pct(by_day[d], 0.5)
		print("  day %-6d median %-10s %s" % [d, Balance.fmt_count(med),
				("x%.2f" % (med / prev)) if prev > 0.0 else ""])
		prev = med

	# When each era arrives.
	print("")
	print("era arrival, median day (worlds that got there)")
	for e in Balance.ERAS.size():
		var arrivals: Array = []
		for s in _seeds:
			var ed: Dictionary = s["era_days"]
			if ed.has(e):
				arrivals.append(float(ed[e]))
		if arrivals.is_empty():
			print("  %-24s never" % String(Balance.ERAS[e]["name"]))
		else:
			print("  %-24s day %-7d (%d/%d worlds)"
					% [String(Balance.ERAS[e]["name"]), int(_pct(arrivals, 0.5)),
					arrivals.size(), _seeds.size()])

	# Tech tree exhaustion - the clearest "nothing new is happening" signal.
	var done: Array = []
	for s in _seeds:
		if float(s["techs_done"]) >= 0.0:
			done.append(float(s["techs_done"]))
	print("")
	if done.is_empty():
		print("tech tree: no world finished all %d techs" % Balance.TECHS.size())
	else:
		print("tech tree finished: %d/%d worlds, median day %d, earliest day %d"
				% [done.size(), _seeds.size(), int(_pct(done, 0.5)), int(_pct(done, 0.0))])
		print("  -> %d%% of the run has no new technology in it"
				% int((1.0 - _pct(done, 0.5) / float(days)) * 100.0))

	# Health checks across the fleet.
	print("")
	print("health")
	var draw: Array = []
	var hungry: Array = []
	var thinkers: Array = []
	var herds: Array = []
	var stalls := 0
	var broken := 0
	for s in _seeds:
		draw.append(float(s["drawdown"]))
		hungry.append(float(s["hungry_pct"]))
		thinkers.append(float(s["thinker_share"]))
		herds.append(float(s["herd"]))
		if float(s["stalled_from"]) >= 0.0:
			stalls += 1
		if String(s["bad"]) != "":
			broken += 1
	print("  deepest drawdown   median %2.0f%%   worst %2.0f%%   (floor allows 25%%)"
			% [_pct(draw, 0.5) * 100.0, _pct(draw, 1.0) * 100.0])
	print("  time spent hungry  median %2.0f%%   worst %2.0f%%"
			% [_pct(hungry, 0.5) * 100.0, _pct(hungry, 1.0) * 100.0])
	print("  elders as a share  median %2.0f%%   worst %2.0f%%"
			% [_pct(thinkers, 0.5) * 100.0, _pct(thinkers, 1.0) * 100.0])
	print("  herd health        median %2.0f%%   worst %2.0f%%   (refuge is %2.0f%%)"
			% [_pct(herds, 0.5) * 100.0, _pct(herds, 0.0) * 100.0,
			Balance.STOCK_REFUGE * 100.0])
	print("  worlds that stalled for %d days: %d/%d"
			% [int(STALL_WINDOW_DAYS), stalls, _seeds.size()])
	print("  worlds with non-finite or negative state: %d/%d" % [broken, _seeds.size()])

	# The refuge floor was doing load-bearing work last time. Watch it directly:
	# a *mean* herd health barely above the floor means the stock is not living
	# at a level, it is being held at one.
	var hmean: Array = []
	var hmin: Array = []
	for s2 in _seeds:
		hmean.append(float(s2["herd_mean"]))
		hmin.append(float(s2["herd_min"]))
	print("  herd health, mean over the whole run: median %2.0f%%  worst %2.0f%%"
			% [_pct(hmean, 0.5) * 100.0, _pct(hmean, 0.0) * 100.0])
	print("  herd health, lowest ever touched:     median %2.0f%%  worst %2.0f%%   (floor %2.0f%%)"
			% [_pct(hmin, 0.5) * 100.0, _pct(hmin, 0.0) * 100.0,
			Balance.STOCK_REFUGE * 100.0])

	# Demographics. A civilisation of children cannot work, and one of
	# pensioners cannot grow - both look identical in a headcount.
	var dep: Array = []
	var deppk: Array = []
	var ages: Array = []
	var d_age := 0.0
	var d_hunger := 0.0
	for s3 in _seeds:
		dep.append(float(s3["dependency"]))
		deppk.append(float(s3["dependency_peak"]))
		ages.append(float(s3["mean_age"]))
		d_age += float(s3["deaths_age"])
		d_hunger += float(s3["deaths_hunger"])
	print("")
	print("demographics")
	print("  dependants (children + retired)  median %2.0f%%   peak seen %2.0f%%"
			% [_pct(dep, 0.5) * 100.0, _pct(deppk, 1.0) * 100.0])
	print("  mean age                         median %.1f   range %.1f - %.1f"
			% [_pct(ages, 0.5), _pct(ages, 0.0), _pct(ages, 1.0)])
	print("  deaths: %s of old age, %s of hunger (%.0f%% of deaths were hunger)"
			% [Balance.fmt(d_age), Balance.fmt(d_hunger),
			d_hunger / maxf(d_age + d_hunger, 1.0) * 100.0])

	# Is the map still producing news after it has been walked?
	var seams: Array = []
	var seams_total := 0
	for s4 in _seeds:
		seams.append(float(s4["seams"]))
		seams_total = maxi(seams_total, int(s4["seams_total"]))
	print("")
	print("ore seams struck: median %d of about %d placed  (range %d - %d)"
			% [int(_pct(seams, 0.5)), seams_total, int(_pct(seams, 0.0)),
			int(_pct(seams, 1.0))])

	# Per-shape, because the shapes are supposed to differ - but by how much?
	print("")
	print("by world shape, final population")
	for t in Balance.WORLD_TYPES.size():
		var vals: Array = []
		for s in _seeds:
			if int(s["shape"]) == t:
				vals.append(float(s["pop"]))
		if vals.is_empty():
			continue
		print("  %-14s median %-10s  min %-10s  max %-10s  (%d worlds)"
				% [String(Balance.WORLD_TYPES[t]["name"]), Balance.fmt_count(_pct(vals, 0.5)),
				Balance.fmt_count(_pct(vals, 0.0)), Balance.fmt_count(_pct(vals, 1.0)),
				vals.size()])


func _write_csv(path: String) -> void:
	if _rows.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("could not write %s" % path)
		return
	# Columns come from the rows themselves. They used to be a hand-written list
	# that had to be kept in step with what _run_one records, and of course it
	# was not: eight metrics were added and silently never reached the file, so
	# the CSV looked complete and was missing exactly the new things it had been
	# extended for. Deriving them cannot drift.
	var cols: Array[String] = []
	for k in (_rows[0] as Dictionary).keys():
		cols.append(String(k))
	f.store_line(",".join(cols))
	for r in _rows:
		var parts: Array[String] = []
		for c in cols:
			parts.append(String.num(float(r[c]), 4) if r[c] is float else str(r[c]))
		f.store_line(",".join(parts))
	f.close()
	print("")
	print("%d samples written to %s" % [_rows.size(), path])
