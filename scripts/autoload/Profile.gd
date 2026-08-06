extends Node
## What belongs to the *player* rather than to any one civilisation.
##
## Legacy used to live in the save file, which meant "New World" quietly threw
## it away - the one thing in the game that is explicitly supposed to outlast a
## run. Achievements had the same problem. Both live here now, in their own
## file, so starting over never costs you anything you earned by playing.

signal changed

const PATH := "user://profile.cfg"

## Banked across every run. Each point is a flat percentage on every trade.
var legacy_points: float = 0.0
## Permanent unlocks bought with Legacy - see Balance.LEGACY_PERKS.
var perks: Array[String] = []
var achievements: Array[String] = []
## Which world shapes have ever been settled, for the four-worlds achievement.
var shapes_played: Array[int] = []
## Purely for the player's own interest.
var runs_completed: int = 0
var best_population: float = 0.0


func _ready() -> void:
	load_profile()


func load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	legacy_points = float(cfg.get_value("legacy", "points", 0.0))
	perks = _to_string_array(cfg.get_value("legacy", "perks", []))
	achievements = _to_string_array(cfg.get_value("player", "achievements", []))
	shapes_played = _to_int_array(cfg.get_value("player", "shapes", []))
	runs_completed = int(cfg.get_value("player", "runs", 0))
	best_population = float(cfg.get_value("player", "best_population", 0.0))


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("legacy", "points", legacy_points)
	cfg.set_value("legacy", "perks", perks)
	cfg.set_value("player", "achievements", achievements)
	cfg.set_value("player", "shapes", shapes_played)
	cfg.set_value("player", "runs", runs_completed)
	cfg.set_value("player", "best_population", best_population)
	cfg.save(PATH)
	changed.emit()


func has_perk(id: String) -> bool:
	return perks.has(id)


func perk_cost(id: String) -> float:
	return float(Balance.LEGACY_PERKS[id]["cost"])


func can_buy_perk(id: String) -> bool:
	return Balance.LEGACY_PERKS.has(id) and not has_perk(id) \
			and legacy_points >= perk_cost(id)


func buy_perk(id: String) -> bool:
	if not can_buy_perk(id):
		return false
	legacy_points -= perk_cost(id)
	perks.append(id)
	save_profile()
	return true


func award(id: String) -> bool:
	if achievements.has(id) or not Balance.ACHIEVEMENTS.has(id):
		return false
	achievements.append(id)
	save_profile()
	return true


func note_shape(shape: int) -> void:
	if not shapes_played.has(shape):
		shapes_played.append(shape)
		save_profile()


func note_population(pop: float) -> void:
	if pop > best_population:
		best_population = pop
		# Only written on the ordinary save cadence; this is not worth a
		# file write every time somebody is born.


func wipe() -> void:
	legacy_points = 0.0
	perks.clear()
	achievements.clear()
	shapes_played.clear()
	runs_completed = 0
	best_population = 0.0
	save_profile()


func _to_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for x in v:
			out.append(String(x))
	return out


func _to_int_array(v: Variant) -> Array[int]:
	var out: Array[int] = []
	if v is Array:
		for x in v:
			out.append(int(x))
	return out
