extends Node
## Central tuning constants and static data tables.
##
## Everything designers will want to twiddle lives here so the sim code stays
## about *mechanism* and this file stays about *numbers*.
##
## Design stance: this is a hopeful game. The ecology model underneath is a real
## one and the population genuinely rises and falls with what the land can give
## - but the land always comes back, the people always come back, and the long
## trend is always upward. Bad stretches are pauses, never losses.

const SAVE_VERSION := 2

# --- Time -------------------------------------------------------------------
## Real seconds per in-game day at 1x speed.
const SECONDS_PER_DAY := 2.0
## Fixed sim substeps per in-game day. Smaller dt keeps the ecology integration
## stable when growth rates are high.
const STEPS_PER_DAY := 10.0
## Days simulated per fixed step.
const STEP_DAYS := 1.0 / STEPS_PER_DAY
## Hard cap on how much offline time is credited on load.
const MAX_OFFLINE_HOURS := 12.0
## Ceiling on catch-up steps executed in a single frame, so a long offline
## credit or a stalled tab never freezes the game.
const MAX_STEPS_PER_FRAME := 12
const SPEEDS: Array[float] = [0.0, 1.0, 2.0, 4.0]

# --- Population -------------------------------------------------------------
const FOOD_PER_PERSON_PER_DAY := 1.0
const WATER_PER_PERSON_PER_DAY := 0.5
## Max births per person per day when fed, watered and housed.
const BIRTH_RATE_MAX := 0.030
## Baseline mortality, always present.
const DEATH_RATE_BASE := 0.010
## Extra mortality when the tribe goes short. Deliberately gentle: hunger
## should stop the tribe growing, not kill it off. Scarcity throttles births
## hard and takes lives only slowly.
const DEATH_RATE_STARVATION := 0.028
## Births are throttled as the tribe fills its housing.
const CROWDING_SOFTNESS := 0.35
## Shelter the band carries with it - tents and lean-tos, before any building.
const BASE_HOUSING := 10.0
const MIN_POPULATION := 4.0
## The tribe never falls below this fraction of its high-water mark. Whatever
## happens, the settlement holds and the line goes back up. This is the promise
## the whole game makes to the player.
const PEAK_FLOOR_FRACTION := 0.75
## Below this fraction of need, the log starts mentioning hunger.
const FAMINE_THRESHOLD := 0.85

# --- Ecology (Rosenzweig-MacArthur / Holling type II) -----------------------
## Intrinsic regrowth rate of wild game, per day.
const GAME_REGROWTH := 0.100
## Attack rate: how effectively one hunter finds game.
const HUNT_ATTACK_RATE := 0.030
## Handling time: the saturation term that caps yield when game is abundant.
const HUNT_HANDLING_TIME := 0.42
## Wild game wanders in from beyond the territory, so the herds always recover.
const GAME_IMMIGRATION := 0.300

const FORAGE_REGROWTH := 0.300
const FORAGE_ATTACK_RATE := 0.100
const FORAGE_HANDLING_TIME := 0.62
const FORAGE_IMMIGRATION := 0.600

## Trees regrow slower than anything else, but they do regrow.
const FOREST_REGROWTH := 0.050
const CHOP_ATTACK_RATE := 0.030
const CHOP_HANDLING_TIME := 0.40
const FOREST_IMMIGRATION := 0.100

## Refugia: this fraction of every stock is simply out of reach - deep
## thickets, high ground, the far bank. Nothing is ever hunted or felled to
## nothing, so every stock always keeps a seed to grow back from.
const STOCK_REFUGE := 0.30

## Felling forest costs wildlife some habitat, but never all of it.
const HABITAT_WEIGHT := 0.30

const WATER_PER_CARRIER := 2.50
const STONE_PER_QUARRIER := 0.55
const ORE_PER_MINER := 0.42
## Gold comes up alongside the ore, in far smaller quantities.
const GOLD_PER_MINER := 0.045
const KNOWLEDGE_PER_THINKER := 0.18
## Ambient learning: even with nobody assigned, a bigger tribe accumulates
## know-how. Scales with sqrt(pop) so it never outruns dedicated thinkers.
const AMBIENT_KNOWLEDGE := 0.060

const FARM_YIELD_PER_PLOT := 2.6
const BUILDER_WORK_PER_DAY := 1.0

# --- Storage ----------------------------------------------------------------
## Fraction of stored food lost per day before any preservation tech.
const FOOD_SPOILAGE := 0.030

const RESOURCES := {
	"food": {
		"name": "Food",
		"color": Color("d9a441"),
		"base_cap": 150.0,
		"spoilage": FOOD_SPOILAGE,
	},
	"water": {
		"name": "Water",
		"color": Color("4fa3d1"),
		"base_cap": 100.0,
		"spoilage": 0.02,
	},
	"wood": {
		"name": "Wood",
		"color": Color("8a6642"),
		"base_cap": 150.0,
		"spoilage": 0.0,
	},
	"stone": {
		"name": "Stone",
		"color": Color("9aa0a6"),
		"base_cap": 120.0,
		"spoilage": 0.0,
	},
	"hides": {
		"name": "Hides",
		"color": Color("b3714e"),
		"base_cap": 80.0,
		"spoilage": 0.008,
	},
	"ore": {
		"name": "Ore",
		"color": Color("c0724a"),
		"base_cap": 100.0,
		"spoilage": 0.0,
	},
	"gold": {
		"name": "Gold",
		"color": Color("e3c14f"),
		"base_cap": 60.0,
		"spoilage": 0.0,
	},
	"knowledge": {
		"name": "Knowledge",
		"color": Color("b08ad4"),
		"base_cap": 0.0, # 0 means uncapped
		"spoilage": 0.0,
	},
}

const RESOURCE_ORDER: Array[String] = [
	"food", "water", "wood", "stone", "hides", "ore", "gold", "knowledge",
]

# --- Ore tiers --------------------------------------------------------------
## What comes out of the ground improves as the civilisation does. The deposits
## in the rock never change; the people's ability to recognise and work them
## does. Highest tier whose tech is researched wins.
const ORE_TIERS := [
	{
		"name": "Copper",
		"requires": "prospecting",
		"value": 1.0,
		"color": Color("c0724a"),
		"note": "Green-stained rock in the hillside, soft enough to beat into shape.",
	},
	{
		"name": "Bronze",
		"requires": "bronze_working",
		"value": 2.0,
		"color": Color("b08d57"),
		"note": "Copper and tin together. Harder than either, and it holds an edge.",
	},
	{
		"name": "Iron",
		"requires": "iron_working",
		"value": 3.4,
		"color": Color("9aa4ad"),
		"note": "Stubborn, plentiful, and better than bronze once you can get it hot enough.",
	},
]

# --- Jobs -------------------------------------------------------------------
## `kind` selects which production routine in Sim handles the job.
const JOBS := {
	"hunter": {
		"name": "Hunters",
		"kind": "game",
		"desc": "Track and kill wild game. Big yields, and the herds always come back.",
		"requires": "",
	},
	"forager": {
		"name": "Foragers",
		"kind": "forage",
		"desc": "Gather berries, roots and nuts. Modest but dependable.",
		"requires": "",
	},
	"woodcutter": {
		"name": "Woodcutters",
		"kind": "forest",
		"desc": "Fell trees for fuel and building. The forest regrows, given room.",
		"requires": "",
	},
	"water_carrier": {
		"name": "Water Carriers",
		"kind": "water",
		"desc": "Haul water from the river and lakes. Yield depends on nearby water.",
		"requires": "",
	},
	"farmer": {
		"name": "Farmers",
		"kind": "farm",
		"desc": "Work the plots. Steady food that does not depend on the herds at all.",
		"requires": "agriculture",
	},
	"quarrier": {
		"name": "Quarriers",
		"kind": "stone",
		"desc": "Cut stone from the hills for permanent building.",
		"requires": "masonry",
	},
	"miner": {
		"name": "Miners",
		"kind": "ore",
		"desc": "Work the seams for metal, and whatever gold comes up with it.",
		"requires": "prospecting",
	},
	"builder": {
		"name": "Builders",
		"kind": "build",
		"desc": "Raise whatever is queued in the build orders.",
		"requires": "",
	},
	"thinker": {
		"name": "Elders",
		"kind": "knowledge",
		"desc": "Remember, teach and puzzle things out. Generates Knowledge.",
		"requires": "shared_stories",
	},
}

const JOB_ORDER: Array[String] = [
	"hunter", "forager", "woodcutter", "water_carrier",
	"farmer", "quarrier", "miner", "builder", "thinker",
]

# --- Buildings --------------------------------------------------------------
## effects:
##   housing         - people supported
##   storage         - {resource: added cap}
##   yield_mult      - {job kind: multiplicative bonus}
##   farm_plots      - farm capacity
##   spoilage_mult   - multiplies food spoilage
##   knowledge_mult  - multiplies knowledge output
##   territory       - extra territory radius in tiles
const BUILDINGS := {
	"firepit": {
		"name": "Fire Pit",
		"desc": "A hearth to cook at. Cooked food goes further and keeps longer.",
		"cost": {"wood": 12.0},
		"work": 4.0,
		"requires": "",
		"max": 1,
		"effects": {"spoilage_mult": 0.75, "yield_mult": {"game": 1.10}},
	},
	"windbreak": {
		"name": "Windbreak",
		"desc": "Hide and brush lean-tos. Barely shelter, but it is a start.",
		"cost": {"wood": 10.0, "hides": 4.0},
		"work": 4.0,
		"requires": "",
		"max": 10,
		"effects": {"housing": 3.0},
	},
	"drying_rack": {
		"name": "Drying Rack",
		"desc": "Smoke and dry the kill. Food keeps through a bad month.",
		"cost": {"wood": 20.0, "hides": 6.0},
		"work": 6.0,
		"requires": "preservation",
		"max": 8,
		"effects": {"storage": {"food": 90.0}, "spoilage_mult": 0.72},
	},
	"hut": {
		"name": "Hut",
		"desc": "A round timber hut. The moment the tribe stops moving.",
		"cost": {"wood": 34.0, "hides": 8.0},
		"work": 12.0,
		"requires": "settlement",
		"max": 40,
		"effects": {"housing": 6.0},
	},
	"woodshed": {
		"name": "Woodshed",
		"desc": "Somewhere to stack timber out of the rain.",
		"cost": {"wood": 25.0},
		"work": 7.0,
		"requires": "settlement",
		"max": 8,
		"effects": {"storage": {"wood": 160.0}},
	},
	"farm_plot": {
		"name": "Farm Plot",
		"desc": "Broken ground, sown with saved grain. Food that does not run away.",
		"cost": {"wood": 22.0, "stone": 6.0},
		"work": 10.0,
		"requires": "agriculture",
		"max": 80,
		"effects": {"farm_plots": 1.0},
	},
	"well": {
		"name": "Well",
		"desc": "Dig for water instead of walking to it.",
		"cost": {"wood": 20.0, "stone": 25.0},
		"work": 14.0,
		"requires": "masonry",
		"max": 8,
		"effects": {"yield_mult": {"water": 1.7}, "storage": {"water": 70.0}},
	},
	"longhouse": {
		"name": "Longhouse",
		"desc": "Many families under one roof, and somewhere to store the harvest.",
		"cost": {"wood": 90.0, "stone": 30.0},
		"work": 30.0,
		"requires": "masonry",
		"max": 24,
		"effects": {"housing": 18.0, "storage": {"food": 60.0}},
	},
	"granary": {
		"name": "Granary",
		"desc": "Raised stone store. A year of grain against a year of drought.",
		"cost": {"wood": 60.0, "stone": 70.0},
		"work": 28.0,
		"requires": "pottery",
		"max": 10,
		"effects": {"storage": {"food": 320.0}, "spoilage_mult": 0.55},
	},
	"quarry": {
		"name": "Quarry",
		"desc": "A worked stone face in the hills.",
		"cost": {"wood": 40.0},
		"work": 18.0,
		"requires": "masonry",
		"max": 6,
		"effects": {"yield_mult": {"stone": 1.5}, "storage": {"stone": 140.0}},
	},
	"mine": {
		"name": "Mine",
		"desc": "A shaft following the seam down. Whatever this age can work, this brings up.",
		"cost": {"wood": 55.0, "stone": 40.0},
		"work": 24.0,
		"requires": "prospecting",
		"max": 8,
		"effects": {"yield_mult": {"ore": 1.55}, "storage": {"ore": 120.0, "gold": 40.0}},
	},
	"smelter": {
		"name": "Smelter",
		"desc": "Charcoal, bellows and patience. Better metal means better everything.",
		"cost": {"stone": 80.0, "wood": 70.0, "ore": 40.0},
		"work": 32.0,
		"requires": "bronze_working",
		"max": 6,
		"effects": {
			"yield_mult": {"game": 1.10, "forest": 1.12, "stone": 1.12, "farm": 1.12, "ore": 1.10},
			"storage": {"ore": 80.0},
		},
	},
	"stone_house": {
		"name": "Stone House",
		"desc": "Mortared walls and a tiled roof. These outlive the people who build them.",
		"cost": {"stone": 120.0, "wood": 60.0, "ore": 30.0},
		"work": 40.0,
		"requires": "iron_working",
		"max": 30,
		"effects": {"housing": 30.0, "storage": {"food": 40.0}},
	},
	"shrine": {
		"name": "Shrine",
		"desc": "Where the tribe keeps what it knows and what it fears.",
		"cost": {"wood": 30.0, "stone": 20.0, "hides": 10.0},
		"work": 20.0,
		"requires": "shared_stories",
		"max": 6,
		"effects": {"knowledge_mult": 1.30},
	},
	"treasury": {
		"name": "Treasury",
		"desc": "Gold buys teachers, travellers, and news from far away.",
		"cost": {"stone": 140.0, "gold": 60.0, "ore": 50.0},
		"work": 45.0,
		"requires": "coinage",
		"max": 6,
		"effects": {
			"knowledge_mult": 1.45,
			"storage": {"gold": 160.0},
			"territory": 1.0,
		},
	},
}

const BUILDING_ORDER: Array[String] = [
	"firepit", "windbreak", "drying_rack", "hut", "woodshed", "farm_plot",
	"well", "longhouse", "granary", "quarry", "mine", "smelter",
	"stone_house", "shrine", "treasury",
]

# --- Technology -------------------------------------------------------------
## effects mirror building effects, plus `birth_mult`.
const TECHS := {
	"fire_mastery": {
		"name": "Fire Mastery",
		"desc": "Carry an ember, and the night is yours.",
		"cost": 8.0,
		"requires": [],
		"era": 0,
		"effects": {"yield_mult": {"game": 1.15}},
	},
	"stone_tools": {
		"name": "Knapped Tools",
		"desc": "Sharp edges for every trade.",
		"cost": 16.0,
		"requires": ["fire_mastery"],
		"era": 0,
		"effects": {"yield_mult": {"game": 1.15, "forest": 1.30, "forage": 1.10}},
	},
	"tracking": {
		"name": "Tracking",
		"desc": "Read the ground and the herd cannot hide.",
		"cost": 28.0,
		"requires": ["stone_tools"],
		"era": 0,
		"effects": {"yield_mult": {"game": 1.35}, "territory": 2.0},
	},
	"shared_stories": {
		"name": "Shared Stories",
		"desc": "What one elder knows, everyone knows. Unlocks Elders and the Shrine.",
		"cost": 20.0,
		"requires": ["fire_mastery"],
		"era": 0,
		"effects": {},
	},
	"preservation": {
		"name": "Smoking & Drying",
		"desc": "Make the good months pay for the bad ones. Unlocks Drying Racks.",
		"cost": 34.0,
		"requires": ["fire_mastery"],
		"era": 0,
		"effects": {"storage": {"food": 40.0}},
	},
	"settlement": {
		"name": "Settling Down",
		"desc": "Stop following the herds. Unlocks Huts and Woodsheds.",
		"cost": 55.0,
		"requires": ["shared_stories", "preservation"],
		"era": 1,
		"effects": {"territory": 2.0, "birth_mult": 1.15},
	},
	"basketry": {
		"name": "Basketry",
		"desc": "Woven carriers for everything worth carrying.",
		"cost": 48.0,
		"requires": ["settlement"],
		"era": 1,
		"effects": {"storage": {"food": 60.0, "water": 40.0}, "yield_mult": {"forage": 1.30}},
	},
	"prospecting": {
		"name": "Prospecting",
		"desc": "Learn which stones are worth breaking. Unlocks Miners and the Mine.",
		"cost": 70.0,
		"requires": ["stone_tools", "settlement"],
		"era": 1,
		"effects": {"territory": 1.0},
	},
	"pottery": {
		"name": "Pottery",
		"desc": "Fired clay holds water, grain and the idea of a surplus. Unlocks Granaries.",
		"cost": 90.0,
		"requires": ["basketry"],
		"era": 1,
		"effects": {"storage": {"water": 60.0, "food": 60.0}, "spoilage_mult": 0.8},
	},
	"husbandry": {
		"name": "Animal Husbandry",
		"desc": "Keep the herd instead of chasing it.",
		"cost": 115.0,
		"requires": ["settlement", "tracking"],
		"era": 1,
		"effects": {"yield_mult": {"game": 1.4}, "storage": {"hides": 50.0}},
	},
	"agriculture": {
		"name": "Agriculture",
		"desc": "Sow, wait, reap. The most important thing your people will ever learn. Unlocks Farmers and Farm Plots.",
		"cost": 170.0,
		"requires": ["pottery"],
		"era": 2,
		"effects": {"birth_mult": 1.2},
	},
	"masonry": {
		"name": "Masonry",
		"desc": "Cut stone, stacked true. Unlocks Quarriers, Wells and Longhouses.",
		"cost": 200.0,
		"requires": ["agriculture"],
		"era": 2,
		"effects": {"storage": {"stone": 60.0}},
	},
	"irrigation": {
		"name": "Irrigation",
		"desc": "Lead the river to the field.",
		"cost": 220.0,
		"requires": ["agriculture"],
		"era": 2,
		"effects": {"yield_mult": {"farm": 1.5}, "territory": 2.0},
	},
	"bronze_working": {
		"name": "Bronze Working",
		"desc": "Alloy copper with tin. Your miners start bringing up bronze, and the Smelter makes every trade sharper.",
		"cost": 260.0,
		"requires": ["prospecting", "pottery"],
		"era": 2,
		"effects": {"yield_mult": {"ore": 1.2}},
	},
	"the_plough": {
		"name": "The Plough",
		"desc": "One person, one ox, ten times the ground.",
		"cost": 320.0,
		"requires": ["irrigation", "husbandry"],
		"era": 2,
		"effects": {"yield_mult": {"farm": 1.6}},
	},
	"writing": {
		"name": "Writing",
		"desc": "Knowledge that outlives the person who had it.",
		"cost": 450.0,
		"requires": ["masonry", "the_plough"],
		"era": 3,
		"effects": {"knowledge_mult": 1.6, "territory": 3.0},
	},
	"iron_working": {
		"name": "Iron Working",
		"desc": "Hotter fires, and a stubborner metal than bronze ever was. Your seams start yielding iron, and Stone Houses become possible.",
		"cost": 600.0,
		"requires": ["bronze_working", "masonry"],
		"era": 3,
		"effects": {"yield_mult": {"ore": 1.3, "stone": 1.25, "farm": 1.2}},
	},
	"coinage": {
		"name": "Coinage",
		"desc": "Stamped gold. Wealth you can carry, count, and spend on people who know things. Unlocks the Treasury.",
		"cost": 720.0,
		"requires": ["writing", "bronze_working"],
		"era": 4,
		"effects": {"storage": {"gold": 80.0}, "knowledge_mult": 1.2},
	},
}

const TECH_ORDER: Array[String] = [
	"fire_mastery", "stone_tools", "tracking", "shared_stories", "preservation",
	"settlement", "basketry", "prospecting", "pottery", "husbandry",
	"agriculture", "masonry", "irrigation", "bronze_working", "the_plough",
	"writing", "iron_working", "coinage",
]

# --- Eras -------------------------------------------------------------------
## Advancing an era is purely a recognition of what you have already done.
const ERAS := [
	{"name": "Nomadic Band", "techs": 0, "pop": 0},
	{"name": "Semi-Settled Camp", "techs": 4, "pop": 18},
	{"name": "Neolithic Village", "techs": 8, "pop": 45},
	{"name": "Bronze Age Town", "techs": 13, "pop": 110},
	{"name": "Iron Age City", "techs": 17, "pop": 280},
]

# --- World ------------------------------------------------------------------
const WORLD_W := 48
const WORLD_H := 32
const BASE_TERRITORY_RADIUS := 3.5
## Territory also creeps outward as the population grows.
const TERRITORY_PER_POP := 0.045
const MAX_TERRITORY_RADIUS := 16.0

enum Biome { OCEAN, LAKE, RIVER, BEACH, GRASSLAND, FOREST, WETLAND, HILLS, MOUNTAIN, DESERT }

## `ore` and `gold` are deposit richness, not depletable stocks - seams do not
## run dry at this timescale, which keeps the civilisation always able to grow.
const BIOME_INFO := {
	Biome.OCEAN: {"name": "Ocean", "color": Color("1d3c5c"), "water": 1.0, "game": 0.0, "forest": 0.0, "forage": 0.0, "fertility": 0.0, "stone": 0.0, "ore": 0.0, "gold": 0.0},
	Biome.LAKE: {"name": "Lake", "color": Color("2f6b93"), "water": 1.0, "game": 6.0, "forest": 0.0, "forage": 4.0, "fertility": 0.0, "stone": 0.0, "ore": 0.0, "gold": 0.0},
	Biome.RIVER: {"name": "River", "color": Color("3f83ab"), "water": 1.0, "game": 8.0, "forest": 0.0, "forage": 6.0, "fertility": 0.0, "stone": 0.0, "ore": 0.05, "gold": 0.35},
	Biome.BEACH: {"name": "Shore", "color": Color("cbbd8f"), "water": 0.2, "game": 4.0, "forest": 2.0, "forage": 8.0, "fertility": 0.2, "stone": 0.1, "ore": 0.0, "gold": 0.05},
	Biome.GRASSLAND: {"name": "Grassland", "color": Color("7d9b57"), "water": 0.0, "game": 26.0, "forest": 6.0, "forage": 14.0, "fertility": 1.0, "stone": 0.1, "ore": 0.05, "gold": 0.0},
	Biome.FOREST: {"name": "Forest", "color": Color("3f6b3c"), "water": 0.0, "game": 34.0, "forest": 46.0, "forage": 26.0, "fertility": 0.6, "stone": 0.1, "ore": 0.05, "gold": 0.0},
	Biome.WETLAND: {"name": "Wetland", "color": Color("55806a"), "water": 0.8, "game": 20.0, "forest": 14.0, "forage": 24.0, "fertility": 0.9, "stone": 0.0, "ore": 0.0, "gold": 0.05},
	Biome.HILLS: {"name": "Hills", "color": Color("8a8763"), "water": 0.0, "game": 16.0, "forest": 16.0, "forage": 9.0, "fertility": 0.4, "stone": 1.0, "ore": 1.00, "gold": 0.20},
	Biome.MOUNTAIN: {"name": "Mountain", "color": Color("6f6f74"), "water": 0.0, "game": 5.0, "forest": 4.0, "forage": 2.0, "fertility": 0.0, "stone": 1.6, "ore": 1.60, "gold": 0.45},
	Biome.DESERT: {"name": "Desert", "color": Color("c2a267"), "water": 0.0, "game": 4.0, "forest": 1.0, "forage": 3.0, "fertility": 0.1, "stone": 0.3, "ore": 0.45, "gold": 0.15},
}

# --- Events -----------------------------------------------------------------
## Minimum in-game days between random events.
const EVENT_COOLDOWN_DAYS := 24.0
## Chance per day of an event once off cooldown.
const EVENT_CHANCE_PER_DAY := 0.06

static func is_water_biome(b: int) -> bool:
	return b == Biome.OCEAN or b == Biome.LAKE or b == Biome.RIVER


## Format a number compactly for UI: 12.4, 1.2k, 3.4M.
static func fmt(value: float, decimals: int = 1) -> String:
	var a := absf(value)
	if a >= 1_000_000.0:
		return "%.2fM" % (value / 1_000_000.0)
	if a >= 1_000.0:
		return "%.2fk" % (value / 1_000.0)
	if a < 10.0:
		return String.num(value, decimals)
	return String.num(value, 0)


## Format a per-day rate with an explicit sign.
static func fmt_rate(value: float) -> String:
	var s := "+" if value >= 0.0 else "-"
	return s + fmt(absf(value), 2)
