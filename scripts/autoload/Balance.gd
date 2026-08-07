extends Node
## Central tuning constants and static data tables.
##
## Everything designers will want to twiddle lives here so the sim code stays
## about *mechanism* and this file stays about *numbers*.
##
## Design stance, in two halves:
##
## 1. It is hopeful. The ecology underneath is a real consumer-resource model
##    and the population genuinely rises and falls with what the land gives -
##    but the land always comes back, the people always come back, and the long
##    trend is always upward. Bad stretches are pauses, never losses.
##
## 2. It is an idler. Costs grow geometrically while output grows linearly with
##    what you own, so the next thing is always a little further away - and
##    upgrades periodically double a trade outright and reset that curve. That
##    is the Cookie Clicker engine: there is always a next purchase, the numbers
##    never stop climbing, and nothing ever hard-caps.

const SAVE_VERSION := 7

# --- Time -------------------------------------------------------------------
## Real seconds per in-game day at the slowest speed. A day is the unit the
## player thinks in, so it is the unit the clock counts - not years.
const SECONDS_PER_DAY := 30.0
## Fixed sim substeps per in-game day at ordinary speeds.
const STEPS_PER_DAY := 10.0
const STEP_DAYS := 1.0 / STEPS_PER_DAY
## At the fast-forward speeds a day passes in a thirtieth of a second, and ten
## substeps of it would be wasted precision. The ecology is stable at coarser
## steps, so the substep count drops instead of the frame rate.
const FAST_STEPS_PER_DAY := 3.0
const FAST_STEP_DAYS := 1.0 / FAST_STEPS_PER_DAY
## Above this many days per second, use the coarse step.
const FAST_STEP_THRESHOLD := 4.0

## Hard cap on how much offline time is credited on load.
const MAX_OFFLINE_HOURS := 12.0
## Ceiling on catch-up steps executed in a single frame.
const MAX_STEPS_PER_FRAME := 40
## Offline catch-up runs the real simulation rather than approximating it, so
## it has to be bounded or a twelve-hour absence would take minutes to load.
const MAX_OFFLINE_STEPS := 6000
const MAX_OFFLINE_STEP_DAYS := 2.0

## Speeds, as multiples of the base thirty-seconds-a-day. The player picks how
## long a day should take, not an abstract multiplier, so the labels say that.
##   1x   -> 30 seconds a day
##   2x   -> 15 seconds a day
##   30x  -> 1 second a day
##   900x -> 1 second a month
const SPEEDS: Array[float] = [0.0, 1.0, 2.0, 30.0, 900.0]
const SPEED_LABELS: Array[String] = ["II", "30s", "15s", "1s", "1mo"]
const SPEED_TIPS: Array[String] = [
	"Paused",
	"Thirty seconds a day",
	"Fifteen seconds a day",
	"One second a day",
	"One second a month - thirty days a second",
]
## Era needed for each speed. The two fast-forwards arrive once there is enough
## going on that watching every day would be tedious.
const SPEED_UNLOCK_ERA: Array[int] = [0, 0, 0, 1, 3]

# --- Population -------------------------------------------------------------
const FOOD_PER_PERSON_PER_DAY := 1.0
const WATER_PER_PERSON_PER_DAY := 0.5
## Max births per person per day when fed, watered and housed.
## Deliberately below what the land could support. A population that grows
## right up against its carrying capacity eats everything it produces and lives
## hand to mouth for ever - technically correct Malthusian behaviour, and not
## the game this is. Slack means the granary fills, winter is survived out of
## store rather than out of the safety net, and growth feels like abundance.
const BIRTH_RATE_MAX := 0.021
## Baseline mortality, always present.
const DEATH_RATE_BASE := 0.010
## Extra mortality when the tribe goes short. Deliberately gentle: hunger
## should stop the tribe growing, not kill it off.
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

## How many people a wandering band is worth when it joins you.
##
## This used to be a flat percentage of the settlement, which is wrong twice
## over. It is wrong in the fiction - a band walking out of the hills is fifty
## people whether it finds a village or a city - and it was badly wrong in the
## simulation: at ten thousand people a single event added twelve hundred mouths
## in one day, far past anything the land was feeding. The never-lose floor then
## locked the new number in, and the settlement spent the rest of the run at a
## population its fields could not support with the granary pinned at zero.
##
## Sub-linear instead: a band is a band. It still feels generous early, when a
## dozen arrivals doubles you, and it stays a pleasant event later without being
## the largest single source of population in the game.
const MIGRANT_BASE := 2.0
const MIGRANT_SCALE := 1.5
const MIGRANT_EXPONENT := 0.5
## Never more than this fraction of the settlement in one arrival, whatever the
## curve says. Only binds in the first few dozen people.
const MIGRANT_MAX_FRACTION := 0.35


## The size of a band of newcomers, given how big the settlement already is.
static func migrant_count(population: float) -> float:
	var band := MIGRANT_BASE + pow(maxf(population, 0.0), MIGRANT_EXPONENT) * MIGRANT_SCALE
	return minf(band, maxf(2.0, population * MIGRANT_MAX_FRACTION))

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
const STONE_PER_QUARRIER := 1.10
const ORE_PER_MINER := 0.95
## Gold comes up alongside the ore, in far smaller quantities.
const GOLD_PER_MINER := 0.045
const KNOWLEDGE_PER_THINKER := 0.22
## Elders have diminishing returns to headcount. See the note in Sim._produce -
## this exponent is what stops population and knowledge feeding each other into
## a run that finishes the tech tree in a quarter of an hour.
const THINKER_EXPONENT := 0.58
## Ambient learning: even with nobody assigned, a bigger tribe accumulates
## know-how. Scales with sqrt(pop) so it never outruns dedicated thinkers.
const AMBIENT_KNOWLEDGE := 0.060

const FARM_YIELD_PER_PLOT := 2.6
## Managed timber, per worked woodlot row. Independent of the wild forest,
## which is the whole point of it.
const TIMBER_YIELD_PER_LOT := 2.0
const BUILDER_WORK_PER_DAY := 1.0

# --- Exploration ------------------------------------------------------------
## Tiles one explorer reveals per day, before any tech multipliers.
const EXPLORE_PER_SCOUT := 0.85
## Explorers map as they go, and a map is knowledge.
const KNOWLEDGE_PER_SCOUT := 0.05
## How far past the worked territory the frontier must reach before the
## settlement will claim more land. You cannot work what nobody has walked.
const CLAIM_MARGIN := 1.5
## Tiles revealed per simulation step, at most - keeps the reveal smooth and
## the per-step cost bounded no matter how many explorers are out.
const MAX_REVEALS_PER_STEP := 24

# --- Comparable value -------------------------------------------------------
## What a unit of each material is worth to the settlement, in one currency, so
## the labour planner can weigh "one more miner" against "one more forester"
## instead of handling every trade by its own private rule.
const RESOURCE_VALUE := {
	"food": 1.0, "water": 1.4, "wood": 0.45, "stone": 0.8,
	"hides": 0.4, "ore": 1.6, "gold": 6.0, "knowledge": 2.2,
}

# --- Stock targets ----------------------------------------------------------
## With no ceilings, "enough" has to mean something else: the settlement
## gathers a material until it holds this multiple of the priciest thing it
## could currently build with it, then stops. That scales itself, and it is what
## lets the forest grow back once there is more timber than anyone needs.
const STOCK_TARGET_MULTIPLE := 2.5
const STOCK_TARGET_FLOOR := 120.0

# --- Storage ----------------------------------------------------------------
## Fraction of stored food lost per day before any preservation tech.
const FOOD_SPOILAGE := 0.030

## Nothing has a storage ceiling, and that is deliberate. A hard cap cannot
## coexist with geometric costs: prices grow exponentially in what you own while
## any cap grows at best linearly, so sooner or later there is a building nobody
## can ever save up for and the game quietly stops. Perishables are held in
## check by spoilage instead, which scales with the economy on its own - stock
## settles where production equals decay. The rest simply accumulate.
const RESOURCES := {
	"food": {"name": "Food", "color": Color("d9a441"), "base_cap": 0.0, "spoilage": FOOD_SPOILAGE},
	"water": {"name": "Water", "color": Color("4fa3d1"), "base_cap": 0.0, "spoilage": 0.02},
	"wood": {"name": "Wood", "color": Color("8a6642"), "base_cap": 0.0, "spoilage": 0.0},
	"stone": {"name": "Stone", "color": Color("9aa0a6"), "base_cap": 0.0, "spoilage": 0.0},
	"hides": {"name": "Hides", "color": Color("b3714e"), "base_cap": 0.0, "spoilage": 0.008},
	"ore": {"name": "Ore", "color": Color("c0724a"), "base_cap": 0.0, "spoilage": 0.0},
	"gold": {"name": "Gold", "color": Color("e3c14f"), "base_cap": 0.0, "spoilage": 0.0},
	"knowledge": {"name": "Knowledge", "color": Color("b08ad4"), "base_cap": 0.0, "spoilage": 0.0}
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
		"name": "Copper", "requires": "prospecting", "value": 1.0, "color": Color("c0724a"),
		"note": "Green-stained rock in the hillside, soft enough to beat into shape."
	},
	{
		"name": "Bronze", "requires": "bronze_working", "value": 2.0, "color": Color("b08d57"),
		"note": "Copper and tin together. Harder than either, and it holds an edge."
	},
	{
		"name": "Iron", "requires": "iron_working", "value": 3.4, "color": Color("9aa4ad"),
		"note": "Stubborn, plentiful, and better than bronze once you can get it hot enough."
	},
	{
		"name": "Steel", "requires": "steelmaking", "value": 6.0, "color": Color("cfd6dd"),
		"note": "Iron with the temper beaten into it. Nothing your neighbours have compares."
	},
]

# --- Jobs -------------------------------------------------------------------
## `kind` selects which production routine in Sim handles the job.
## `glyph` and `color` are what the map draws, so a glance tells you who is
## doing what and where they are doing it.
const JOBS := {
	"hunter": {
		"name": "Hunters", "kind": "game", "requires": "",
		"desc": "Track and kill wild game. Big yields, and the herds always come back.",
		"glyph": "bow", "color": Color("d98555"), "field": "game"
	},
	"forager": {
		"name": "Foragers", "kind": "forage", "requires": "",
		"desc": "Gather berries, roots and nuts. Modest but dependable.",
		"glyph": "basket", "color": Color("9ecb6a"), "field": "forage"
	},
	"woodcutter": {
		"name": "Woodcutters", "kind": "forest", "requires": "",
		"desc": "Fell trees for fuel and building. The forest regrows, given room.",
		"glyph": "axe", "color": Color("b98d5a"), "field": "forest"
	},
	"water_carrier": {
		"name": "Water Carriers", "kind": "water", "requires": "",
		"desc": "Haul water from the river and lakes. Yield depends on nearby water.",
		"glyph": "jug", "color": Color("5fb3e0"), "field": "water"
	},
	"explorer": {
		"name": "Explorers", "kind": "explore", "requires": "",
		"desc": "Walk out past the last known ridge. Reveals the map, and the settlement can only claim ground somebody has walked.",
		"glyph": "staff", "color": Color("e0d05a"), "field": "frontier"
	},
	"farmer": {
		"name": "Farmers", "kind": "farm", "requires": "agriculture",
		"desc": "Work the plots. Steady food that does not depend on the herds at all.",
		"glyph": "hoe", "color": Color("d4c14e"), "field": "farm"
	},
	"forester": {
		"name": "Foresters", "kind": "timber", "requires": "agriculture",
		"desc": "Work the woodlots: planted rows, cut on rotation. Timber that does not depend on the wild forest at all.",
		"glyph": "axe", "color": Color("6fa85e"), "field": "farm",
	},
	"quarrier": {
		"name": "Quarriers", "kind": "stone", "requires": "masonry",
		"desc": "Cut stone from the hills. Needs a worked quarry face to stand at.",
		"glyph": "chisel", "color": Color("b9bec4"), "field": "stone"
	},
	"miner": {
		"name": "Miners", "kind": "ore", "requires": "prospecting",
		"desc": "Work the seams for metal, and whatever gold comes up with it. Needs a mine shaft.",
		"glyph": "pick", "color": Color("c9803f"), "field": "ore"
	},
	"builder": {
		"name": "Builders", "kind": "build", "requires": "",
		"desc": "Raise whatever is queued in the build orders.",
		"glyph": "hammer", "color": Color("d8a0d0"), "field": "home"
	},
	"thinker": {
		"name": "Elders", "kind": "knowledge", "requires": "shared_stories",
		"desc": "Remember, teach and puzzle things out. Generates Knowledge.",
		"glyph": "scroll", "color": Color("b08ad4"), "field": "home"
	}
}

const JOB_ORDER: Array[String] = [
	"hunter", "forager", "woodcutter", "water_carrier", "explorer",
	"farmer", "forester", "quarrier", "miner", "builder", "thinker",
]

# --- Buildings --------------------------------------------------------------
## Costs are geometric: the nth of anything costs `cost x growth^n`. Output is
## linear in how many you own. That gap is the whole idler engine - the next one
## is always a little further off, and an upgrade that doubles a trade is
## always worth more than the building it paid for.
##
## `max` is only set for things that are genuinely singular. Everything that
## produces or houses is uncapped, so the numbers never stop.
##
## effects:
##   housing / storage / yield_mult / spoilage_mult / knowledge_mult / territory
##   farm_plots  - farmer work slots
##   mine_slots  - miner work slots
##   quarry_slots- quarrier work slots
##   woodlot_slots- forester work slots
const DEFAULT_COST_GROWTH := 1.15
## Shelter costs the same every time, and this is a design decision rather than
## a missing number.
##
## With any geometric growth at all, the count you can afford rises with the
## *logarithm* of your income - that is arithmetic, not tuning. A settlement
## producing nine times as much housed eleven per cent more people, so no amount
## of good management moved the number the player actually watches. Flat shelter
## costs hand the limit back to food, which is what the ecology model was always
## supposed to decide: population settles at what the land can feed, and what
## the land can feed is precisely what a player can influence.
##
## Flat is a step too far: with no cost pressure at all, population feeds food
## feeds population and the whole economy runs away - a test run reached two
## hundred thousand people by day 900 and lifetime output in the 1e27s. A small
## growth keeps the population genuinely responsive to how well the place is run
## while still damping the loop.
##
## The idler curve proper lives on production, multipliers and upgrades, where a
## steep geometric cost belongs.
const HOUSING_COST_GROWTH := 1.04

## Places to stand and work - farm plots, woodlots, mines, quarries.
##
## These had the default steep growth, and it produced exactly the failure the
## housing note above describes, one level further down. A farm plot is a work
## *slot*, so food production is proportional to the number of plots; at 1.15 the
## seventy-sixth plot cost a million timber and the count could only ever rise
## with the logarithm of income. Plots therefore crawled up by one per month
## while population needed them proportionally, and the late game stalled dead:
## a settlement holding eleven thousand people on seventy-five plots, food
## satisfaction between 0.3 and 0.8 all year, permanently short and permanently
## held up by the never-lose floor rather than fed by its own fields.
##
## A stalled idler is a broken idler, and a game whose promise is that the line
## always goes up cannot have its late game be a chronic famine held level by the
## safety net. Work slots track the settlement instead of lagging it. The steep
## geometric curve stays where it belongs - on multipliers and upgrades, which is
## where the idler's real progression lives and where a wall is the point.
const WORKSITE_COST_GROWTH := 1.045

const BUILDINGS := {
	"firepit": {
		"name": "Fire Pit",
		"desc": "A hearth to cook at. Cooked food goes further and keeps longer.",
		"cost": {"wood": 12.0}, "work": 4.0, "requires": "", "max": 1,
		"effects": {"spoilage_mult": 0.75, "yield_mult": {"game": 1.10}}
	},
	"windbreak": {
		"name": "Windbreak",
		"desc": "Hide and brush lean-tos. Barely shelter, but it is a start.",
		"cost": {"wood": 10.0, "hides": 4.0}, "work": 4.0, "requires": "",
		"growth": HOUSING_COST_GROWTH,
		"effects": {"housing": 3.0}
	},
	"drying_rack": {
		"name": "Drying Rack",
		"desc": "Smoke and dry the kill. Food keeps through a bad month.",
		"cost": {"wood": 20.0, "hides": 6.0}, "work": 6.0, "requires": "preservation",
		"max": 8,
		"effects": {"spoilage_mult": 0.72}
	},
	"hut": {
		"name": "Hut",
		"desc": "A round timber hut. The moment the tribe stops moving.",
		"cost": {"wood": 34.0, "hides": 8.0}, "work": 12.0, "requires": "settlement",
		"growth": HOUSING_COST_GROWTH,
		"effects": {"housing": 6.0}
	},
	"woodshed": {
		"name": "Woodshed",
		"desc": "Seasoned timber, stacked dry and ready. Everything gets built faster.",
		"cost": {"wood": 25.0}, "work": 7.0, "requires": "settlement",
		"effects": {"yield_mult": {"build": 1.12}}
	},
	"scout_camp": {
		"name": "Scout Camp",
		"desc": "A forward camp with dried meat and spare boots. Explorers range further from one.",
		"cost": {"wood": 28.0, "hides": 10.0}, "work": 9.0, "requires": "",
		"max": 10,
		"effects": {"yield_mult": {"explore": 1.25}}
	},
	"farm_plot": {
		"name": "Farm Plot",
		"desc": "Broken ground, sown with saved grain. Food that does not run away.",
		"cost": {"wood": 22.0, "stone": 6.0}, "work": 10.0, "requires": "agriculture",
		"growth": WORKSITE_COST_GROWTH,
		"effects": {"farm_plots": 1.0}
	},
	"woodlot": {
		"name": "Woodlot",
		"desc": "Planted rows cut on a rotation. Timber you grow instead of timber you find.",
		"cost": {"wood": 30.0, "stone": 8.0}, "work": 11.0, "requires": "agriculture",
		"growth": WORKSITE_COST_GROWTH,
		"effects": {"woodlot_slots": 1.0}
	},
	"well": {
		"name": "Well",
		"desc": "Dig for water instead of walking to it.",
		"cost": {"wood": 20.0, "stone": 25.0}, "work": 14.0, "requires": "masonry",
		"max": 10,
		"effects": {"yield_mult": {"water": 1.35}}
	},
	"longhouse": {
		"name": "Longhouse",
		"desc": "Many families under one roof, and somewhere to store the harvest.",
		"cost": {"wood": 90.0, "stone": 30.0}, "work": 30.0, "requires": "masonry",
		"growth": HOUSING_COST_GROWTH,
		"effects": {"housing": 18.0}
	},
	"granary": {
		"name": "Granary",
		"desc": "Raised stone store. A year of grain against a year of drought.",
		"cost": {"wood": 60.0, "stone": 70.0}, "work": 28.0, "requires": "pottery",
		"effects": {"spoilage_mult": 0.80}
	},
	"quarry": {
		"name": "Quarry",
		"desc": "A worked stone face in the hills. Somewhere for quarriers to stand.",
		"cost": {"wood": 45.0}, "work": 18.0, "requires": "masonry",
		"growth": WORKSITE_COST_GROWTH,
		"effects": {"quarry_slots": 2.0}
	},
	"mine": {
		"name": "Mine",
		"desc": "A shaft following the seam down. Whatever this age can work, this brings up.",
		"cost": {"wood": 55.0, "stone": 40.0}, "work": 24.0, "requires": "prospecting",
		"growth": WORKSITE_COST_GROWTH,
		"effects": {"mine_slots": 2.0}
	},
	"smelter": {
		"name": "Smelter",
		"desc": "Charcoal, bellows and patience. Better metal means better everything.",
		"cost": {"stone": 80.0, "wood": 70.0, "ore": 40.0}, "work": 32.0,
		"requires": "bronze_working", "max": 12,
		"effects": {
			"yield_mult": {"game": 1.08, "forest": 1.10, "stone": 1.10, "farm": 1.10, "ore": 1.10}
			}
	},
	"stone_house": {
		"name": "Stone House",
		"desc": "Mortared walls and a tiled roof. These outlive the people who build them.",
		"cost": {"stone": 120.0, "wood": 60.0, "ore": 30.0}, "work": 40.0,
		"requires": "iron_working",
		"growth": HOUSING_COST_GROWTH,
		"effects": {"housing": 30.0}
	},
	"shrine": {
		"name": "Shrine",
		"desc": "Where the tribe keeps what it knows and what it fears.",
		"cost": {"wood": 30.0, "stone": 20.0, "hides": 10.0}, "work": 20.0,
		"requires": "shared_stories", "max": 12,
		"effects": {"knowledge_mult": 1.18}
	},
	"treasury": {
		"name": "Treasury",
		"desc": "Gold buys teachers, travellers, and news from far away.",
		"cost": {"stone": 140.0, "gold": 60.0, "ore": 50.0}, "work": 45.0,
		"requires": "coinage", "max": 10,
		"effects": {"knowledge_mult": 1.25, "territory": 0.5}
	},
	"tenement": {
		"name": "Tenement Block",
		"desc": "Four storeys of small rooms and a shared yard. Not beautiful. Houses a great many people.",
		"cost": {"stone": 900.0, "wood": 400.0, "ore": 600.0}, "work": 120.0,
		"requires": "sanitation",
		"growth": HOUSING_COST_GROWTH,
		"effects": {"housing": 260.0}
	},
	"workshop_row": {
		"name": "Workshop Row",
		"desc": "Water-driven saws, hammers and bellows under one long roof.",
		"cost": {"stone": 700.0, "wood": 500.0, "ore": 900.0}, "work": 130.0,
		"requires": "mechanisation",
		"effects": {"mine_slots": 6.0, "quarry_slots": 6.0, "woodlot_slots": 6.0}
	},
	"university": {
		"name": "University",
		"desc": "Somewhere for the arguments to happen on purpose.",
		"cost": {"stone": 1200.0, "gold": 400.0, "ore": 500.0}, "work": 160.0,
		"requires": "printing", "max": 12,
		"effects": {"knowledge_mult": 1.5}
	},
	"great_hall": {
		"name": "Great Hall",
		"desc": "The building that says this place intends to still be here in a hundred years.",
		"cost": {"stone": 400.0, "wood": 250.0, "ore": 180.0, "gold": 90.0}, "work": 90.0,
		"requires": "steelmaking",
		"growth": HOUSING_COST_GROWTH,
		"effects": {"housing": 70.0, "knowledge_mult": 1.10}
	}
}

const BUILDING_ORDER: Array[String] = [
	"firepit", "windbreak", "scout_camp", "drying_rack", "hut", "woodshed",
	"farm_plot", "woodlot", "well", "longhouse", "granary", "quarry", "mine", "smelter",
	"stone_house", "shrine", "treasury", "great_hall",
	"tenement", "workshop_row", "university",
]

# --- Upgrades ---------------------------------------------------------------
## The other half of the idler engine. Every trade has a ladder of upgrades that
## unlock once enough people work it, and each one *doubles* that trade's
## output. Buildings creep; upgrades jump. Paid for in Knowledge, which is why
## Elders and Shrines matter long after the tech tree is finished.
const UPGRADE_MULT := 1.75
## At these tiers the upgrade comes as a pair and buying one closes the other
## for the run. The cheapest possible way to put a real commitment into a system
## the player already visits constantly - and something for Legacy to
## reconsider next time.
const BRANCH_TIERS: Array[int] = [3, 7]
const BRANCH_DEEP := {"self": 2.9, "other": 0.8}
const BRANCH_BROAD := {"self": 1.7, "other": 1.35}
## Which trade each one trades against.
const BRANCH_PARTNER := {
	"game": "forage", "forage": "game",
	"forest": "timber", "timber": "forest",
	"farm": "water", "water": "farm",
	"ore": "stone", "stone": "ore",
	"build": "knowledge", "knowledge": "build",
	"explore": "knowledge",
}
## Unlocked by lifetime output, not by headcount. Gating on how many people
## work a trade sounds natural and is a dead end: the labour planner only ever
## hires what is needed, so a tier wanting three thousand foresters would never
## unlock and the whole ladder would stall with the population standing idle.
## Total ever produced always climbs, so there is always a next upgrade - which
## is what keeps spare hands worth putting on Knowledge for ever.
const UPGRADE_TIERS := [
	{"output": 200.0, "cost": 60.0},
	{"output": 2.0e3, "cost": 400.0},
	{"output": 2.0e4, "cost": 2500.0},
	{"output": 2.0e5, "cost": 15000.0},
	{"output": 2.0e6, "cost": 90000.0},
	{"output": 2.0e7, "cost": 5.0e5},
	{"output": 2.0e8, "cost": 3.0e6},
	{"output": 2.0e9, "cost": 1.8e7},
	{"output": 2.0e10, "cost": 1.0e8},
	{"output": 2.0e11, "cost": 6.0e8},
]

## Flavour per trade, indexed by tier. Cosmetic, but it is most of what makes
## buying one feel like anything.
const UPGRADE_NAMES := {
	"game": ["Fire-Hardened Spears", "Drive Hunting", "The Atlatl", "Composite Bows", "Beaters and Nets", "Hunting Dogs", "Managed Herds", "Game Wardens", "Beast Trails", "The Hunting Reserve", "Selective Culling", "The Wild Register"],
	"forage": ["Digging Sticks", "Reading the Season", "Woven Panniers", "Seed Selection", "Orchard Grafting", "Kitchen Gardens", "Tended Groves", "The Herbal", "Botanic Survey", "Glasshouses", "Seed Vaults", "The Great Orchard"],
	"timber": ["Straight Rows", "Coppice Rotation", "The Nursery", "Grafted Stock",
		"Drying Sheds", "The Plantation", "Managed Rotation", "The Timber Estate",
		"Mechanical Saws", "The Great Woodlot", "Seed Orchards", "The Forestry Board"],
	"forest": ["Stone Axes", "Two-Handed Axes", "The Wedge", "Felling Teams", "River Driving", "The Pit Saw", "Coppice Rotation", "Managed Forestry", "Timber Rails", "The Sawmill", "Nursery Beds", "The Forest Office"],
	"water": ["Gourd Carriers", "Yoked Pails", "Lined Cisterns", "The Shaduf", "Clay Pipe", "The Aqueduct", "Reservoirs", "The Waterworks", "Sluice Gates", "The Great Cistern", "Pressure Mains", "The Water Board"],
	"explore": ["Cairns and Blazes", "The Stick Chart", "Scouting Parties", "Star Navigation", "Surveyed Roads", "The Great Survey", "Relay Riders", "The Atlas", "Survey Chains", "The Grand Expedition", "Ocean Charts", "The Cartographers"],
	"farm": ["Sowing in Rows", "The Hoe", "Crop Rotation", "The Seed Drill", "Manuring", "Terracing", "The Heavy Plough", "Selective Breeding", "Four-Field Rotation", "The Threshing Floor", "Drained Fen", "The Estate"],
	"stone": ["Wedge and Feather", "The Sledge", "Quarry Ramps", "The Crane", "Cut-Stone Standards", "Powder Charges", "Rail Trolleys", "The Stoneworks", "The Derrick", "Cut-to-Order", "Deep Quarries", "The Masons' Yard"],
	"ore": ["Fire-Setting", "Timbered Shafts", "The Windlass", "Adits and Drainage", "The Blast Furnace", "Deep Shafts", "Ore Sorting", "The Foundry", "Pumped Shafts", "The Bloomery Row", "Assay Offices", "The Great Works"],
	"build": ["Plumb and Line", "The Lever", "Scaffolding", "The Treadwheel", "Standard Timbers", "Master Masons", "The Guild", "The Works Office", "Drawn Plans", "The Crane Yard", "Prefabrication", "The Ministry of Works"],
	"knowledge": ["Counting Sticks", "The Storyhouse", "Clay Tablets", "The Archive", "The Academy", "Observatories", "The Great Library", "The University", "The Scriptorium", "Endowed Chairs", "The Census", "The Royal Society"]
}

# --- Technology -------------------------------------------------------------
const TECHS := {
	"fire_mastery": {
		"name": "Fire Mastery", "cost": 8.0, "requires": [], "era": 0,
		"desc": "Carry an ember, and the night is yours.",
		"effects": {"yield_mult": {"game": 1.15}}
	},
	"stone_tools": {
		"name": "Knapped Tools", "cost": 16.0, "requires": ["fire_mastery"], "era": 0,
		"desc": "Sharp edges for every trade.",
		"effects": {"yield_mult": {"game": 1.15, "forest": 1.30, "forage": 1.10}}
	},
	"wayfinding": {
		"name": "Wayfinding", "cost": 18.0, "requires": ["fire_mastery"], "era": 0,
		"desc": "Cairns, blazed trees and a memory for ridgelines. Your explorers cover far more ground.",
		"effects": {"yield_mult": {"explore": 1.6}}
	},
	"tracking": {
		"name": "Tracking", "cost": 28.0, "requires": ["stone_tools"], "era": 0,
		"desc": "Read the ground and the herd cannot hide.",
		"effects": {"yield_mult": {"game": 1.35}, "territory": 2.0}
	},
	"shared_stories": {
		"name": "Shared Stories", "cost": 20.0, "requires": ["fire_mastery"], "era": 0,
		"desc": "What one elder knows, everyone knows. Unlocks Elders and the Shrine.",
		"effects": {}
	},
	"preservation": {
		"name": "Smoking & Drying", "cost": 34.0, "requires": ["fire_mastery"], "era": 0,
		"desc": "Make the good months pay for the bad ones. Unlocks Drying Racks.",
		"effects": {"spoilage_mult": 0.85}
	},
	"settlement": {
		"name": "Settling Down", "cost": 55.0, "requires": ["shared_stories", "preservation"], "era": 1,
		"desc": "Stop following the herds. Unlocks Huts and Woodsheds.",
		"effects": {"territory": 2.0, "birth_mult": 1.15}
	},
	"trackways": {
		"name": "Trackways", "cost": 130.0, "requires": ["settlement"], "era": 2,
		"desc": "Split logs laid over the soft ground between one place and the next. "
				+ "A cart can get through, and towns stop being islands.",
		"effects": {"territory": 1.0, "yield_mult": {"explore": 1.15, "build": 1.08}}
	},
	"basketry": {
		"name": "Basketry", "cost": 48.0, "requires": ["settlement"], "era": 1,
		"desc": "Woven carriers for everything worth carrying.",
		"effects": {"yield_mult": {"forage": 1.30}}
	},
	"prospecting": {
		"name": "Prospecting", "cost": 70.0, "requires": ["stone_tools", "settlement"], "era": 1,
		"desc": "Learn which stones are worth breaking. Unlocks Miners and the Mine.",
		"effects": {"territory": 1.0}
	},
	"seafaring": {
		"name": "Seafaring", "cost": 95.0, "requires": ["wayfinding", "settlement"], "era": 1,
		"desc": "Hide boats and a nerve for open water. Explorers can finally cross to the far shore - which on a broken-up world is everything.",
		"effects": {"yield_mult": {"explore": 1.2}}
	},
	"pottery": {
		"name": "Pottery", "cost": 90.0, "requires": ["basketry"], "era": 1,
		"desc": "Fired clay holds water, grain and the idea of a surplus. Unlocks Granaries.",
		"effects": {"spoilage_mult": 0.8}
	},
	"husbandry": {
		"name": "Animal Husbandry", "cost": 115.0, "requires": ["settlement", "tracking"], "era": 1,
		"desc": "Keep the herd instead of chasing it.",
		"effects": {"yield_mult": {"game": 1.4}}
	},
	"agriculture": {
		"name": "Agriculture", "cost": 170.0, "requires": ["pottery"], "era": 2,
		"desc": "Sow, wait, reap. The most important thing your people will ever learn. Unlocks Farmers and Farm Plots.",
		"effects": {"birth_mult": 1.2}
	},
	"masonry": {
		"name": "Masonry", "cost": 200.0, "requires": ["agriculture"], "era": 2,
		"desc": "Cut stone, stacked true. Unlocks Quarriers, Wells and Longhouses.",
		"effects": {"yield_mult": {"stone": 1.15}}
	},
	"irrigation": {
		"name": "Irrigation", "cost": 220.0, "requires": ["agriculture"], "era": 2,
		"desc": "Lead the river to the field.",
		"effects": {"yield_mult": {"farm": 1.5}, "territory": 2.0}
	},
	"mountain_paths": {
		"name": "Mountain Paths", "cost": 240.0, "requires": ["masonry", "wayfinding"], "era": 2,
		"desc": "Cut steps, rope the bad pitches, cache food at the col. The high ground stops being a wall - explorers can cross it and quarriers can work it.",
		"effects": {"yield_mult": {"stone": 1.2, "explore": 1.15}, "territory": 1.0}
	},
	"bronze_working": {
		"name": "Bronze Working", "cost": 260.0, "requires": ["prospecting", "pottery"], "era": 2,
		"desc": "Alloy copper with tin. Your miners start bringing up bronze, and the Smelter makes every trade sharper.",
		"effects": {"yield_mult": {"ore": 1.2}}
	},
	"the_plough": {
		"name": "The Plough", "cost": 320.0, "requires": ["irrigation", "husbandry"], "era": 2,
		"desc": "One person, one ox, ten times the ground.",
		"effects": {"yield_mult": {"farm": 1.6}}
	},
	"writing": {
		"name": "Writing", "cost": 450.0, "requires": ["masonry", "the_plough"], "era": 3,
		"desc": "Knowledge that outlives the person who had it.",
		"effects": {"knowledge_mult": 1.6, "territory": 3.0}
	},
	"iron_working": {
		"name": "Iron Working", "cost": 600.0, "requires": ["bronze_working", "masonry"], "era": 3,
		"desc": "Hotter fires, and a stubborner metal than bronze ever was. Your seams start yielding iron, and Stone Houses become possible.",
		"effects": {"yield_mult": {"ore": 1.3, "stone": 1.25, "farm": 1.2}}
	},
	"cartography": {
		"name": "Cartography", "cost": 520.0, "requires": ["writing", "seafaring"], "era": 3,
		"desc": "Everything anyone has walked, drawn once and copied. Nobody ever has to find it twice.",
		"effects": {"yield_mult": {"explore": 2.0}, "territory": 3.0, "knowledge_mult": 1.15}
	},
	"coinage": {
		"name": "Coinage", "cost": 720.0, "requires": ["writing", "bronze_working"], "era": 4,
		"desc": "Stamped gold. Wealth you can carry, count, and spend on people who know things. Unlocks the Treasury.",
		"effects": {"knowledge_mult": 1.2}
	},
	"mathematics": {
		"name": "Mathematics", "cost": 16000.0, "requires": ["writing"], "era": 5,
		"desc": "Numbers that describe things nobody has counted yet.",
		"effects": {"knowledge_mult": 1.5, "yield_mult": {"build": 1.2}}
	},
	"roads": {
		"name": "Roads", "cost": 21000.0, "requires": ["steelmaking"], "era": 5,
		"desc": "Metalled and drained, and they do not wash out in spring. Everything moves further.",
		"effects": {"territory": 4.0, "yield_mult": {"explore": 1.5, "stone": 1.2, "housing_mult": 1.2}}
	},
	"macadam": {
		"name": "Macadam", "cost": 480000.0, "requires": ["mechanisation"], "era": 7,
		"desc": "Crushed stone, bound and rolled flat. Everything moves twice as far in a "
				+ "day as it did, and the towns start to behave like one place.",
		"effects": {"territory": 3.0, "yield_mult": {"explore": 1.6, "build": 1.3}}
	},
	"aqueducts": {
		"name": "Aqueducts", "cost": 28000.0, "requires": ["roads", "mathematics"], "era": 5,
		"desc": "Water arrives whether or not anyone carries it.",
		"effects": {"yield_mult": {"water": 3.0, "farm": 1.3, "housing_mult": 1.35}}
	},
	"astronomy": {
		"name": "Astronomy", "cost": 38000.0, "requires": ["mathematics"], "era": 5,
		"desc": "The year, measured. Sowing stops being a guess.",
		"effects": {"knowledge_mult": 1.4, "yield_mult": {"farm": 1.35, "explore": 1.4}}
	},
	"the_keel": {
		"name": "The Keel", "cost": 55000.0, "requires": ["astronomy", "cartography"], "era": 6,
		"desc": "Ships that go where they are pointed, into weather that used to end voyages.",
		"effects": {"yield_mult": {"explore": 2.5, "ore": 1.2}, "territory": 4.0}
	},
	"crop_science": {
		"name": "Crop Science", "cost": 75000.0, "requires": ["astronomy"], "era": 6,
		"desc": "Which seed, which soil, which year. Written down and argued over.",
		"effects": {"yield_mult": {"farm": 2.0, "timber": 1.5}, "birth_mult": 1.1}
	},
	"blast_furnace": {
		"name": "The Blast Furnace", "cost": 105000.0, "requires": ["the_keel"], "era": 6,
		"desc": "Iron by the ton instead of by the bar.",
		"effects": {"yield_mult": {"ore": 2.2, "stone": 1.5, "build": 1.4}}
	},
	"printing": {
		"name": "Printing", "cost": 150000.0, "requires": ["crop_science", "mathematics"], "era": 6,
		"desc": "A thought, copied a thousand times, cheaply. Nothing is ever forgotten again.",
		"effects": {"knowledge_mult": 2.2, "housing_mult": 1.25}
	},
	"sanitation": {
		"name": "Sanitation", "cost": 230000.0, "requires": ["printing", "aqueducts"], "era": 7,
		"desc": "Drains, clean water, and the plain observation that the two should not mix.",
		"effects": {"birth_mult": 1.35, "yield_mult": {"water": 1.5, "housing_mult": 1.8}}
	},
	"mechanisation": {
		"name": "Mechanisation", "cost": 360000.0, "requires": ["blast_furnace", "printing"], "era": 7,
		"desc": "Water and gearing doing what arms used to.",
		"effects": {"yield_mult": {"timber": 2.2, "ore": 1.8, "stone": 1.8, "build": 1.8}}
	},
	"the_steam_engine": {
		"name": "The Steam Engine", "cost": 600000.0, "requires": ["mechanisation"], "era": 7,
		"desc": "Fire turned into motion. Everything after this is a different world.",
		"effects": {"yield_mult": {"ore": 2.5, "stone": 2.0, "timber": 1.8, "build": 2.0}}
	},
	"public_health": {
		"name": "Public Health", "cost": 950000.0, "requires": ["sanitation", "the_steam_engine"], "era": 7,
		"desc": "The unglamorous work that lets a city hold a hundred thousand people.",
		"effects": {"birth_mult": 1.4, "knowledge_mult": 1.3, "housing_mult": 2.0}
	},
	"steelmaking": {
		"name": "Steelmaking", "cost": 1100.0, "requires": ["iron_working", "coinage"], "era": 4,
		"desc": "Iron with the temper beaten into it, and a Great Hall to prove it. Your seams start yielding steel.",
		"effects": {"yield_mult": {"ore": 1.4, "build": 1.5, "farm": 1.25}}
	}
}

const TECH_ORDER: Array[String] = [
	"fire_mastery", "stone_tools", "wayfinding", "tracking", "shared_stories",
	"preservation", "settlement", "basketry", "prospecting", "seafaring",
	"pottery", "husbandry", "agriculture", "masonry", "irrigation",
	"mountain_paths", "bronze_working", "the_plough", "writing", "iron_working",
	"cartography", "coinage", "steelmaking",
	"mathematics", "roads", "aqueducts", "astronomy",
	"the_keel", "crop_science", "blast_furnace", "printing",
	"sanitation", "mechanisation", "the_steam_engine", "public_health",
]

# --- Eras -------------------------------------------------------------------
const ERAS := [
	{"name": "Nomadic Band", "techs": 0, "pop": 0},
	{"name": "Semi-Settled Camp", "techs": 4, "pop": 18},
	{"name": "Neolithic Village", "techs": 9, "pop": 45},
	{"name": "Bronze Age Town", "techs": 15, "pop": 110},
	{"name": "Iron Age City", "techs": 20, "pop": 280},
	{"name": "Age of Steel", "techs": 23, "pop": 900},
	{"name": "Classical City-State", "techs": 27, "pop": 3000},
	{"name": "Age of Sail", "techs": 31, "pop": 12000},
	{"name": "Industrial Dawn", "techs": 35, "pop": 50000},
]

## Population milestones. Purely for the pleasure of watching a number pass a
## round mark, which in this genre is not a small thing.
const MILESTONES := [
	{"pop": 25, "text": "Twenty-five mouths. Somebody has started calling this place by a name."},
	{"pop": 100, "text": "A hundred people. There are faces here you do not recognise."},
	{"pop": 500, "text": "Five hundred. The smoke from the hearths is visible from the ridge."},
	{"pop": 2000, "text": "Two thousand. This is a town by any measure anyone here would use."},
	{"pop": 10000, "text": "Ten thousand. Ten thousand, from six people and a river."},
	{"pop": 50000, "text": "Fifty thousand. The road out of the valley runs both ways now."},
	{"pop": 250000, "text": "A quarter of a million souls under one set of walls."},
	{"pop": 1000000, "text": "A million people. Whatever this is, it is no longer a settlement."},
]

# --- Legacy (prestige) ------------------------------------------------------
## A civilisation ends; the next one begins knowing what this one learned.
##
## This is the genre's oldest trick and the honest version of it here: you set
## your people down, and the songs about them make the next lot faster. Legacy
## is earned from everything you ever produced, so a long patient run and a
## short explosive one both count.
##
## The exponent matters more than the divisor, and it has to survive an economy
## that reaches 1e18 - at 0.55 that produced millions of points and +590,000,000%.
## A cube-root curve keeps a good run clearly better without ending the game.
## At 0.33, doubling a run's output
## gives about 1.46x the Legacy - enough that a better run is clearly better,
## far from enough that one enormous run ends the game. The divisor is then set
## so a first ascension around day 700 is worth roughly +75% rather than the
## +900% an earlier pass produced, which made the second run a formality.
const LEGACY_DIVISOR := 5000000.0
const LEGACY_EXPONENT := 0.33
## Each point is a flat percentage on every trade, for ever.
const LEGACY_BONUS_PER_POINT := 0.03
## Below this there is nothing worth carrying and the option stays hidden.
const LEGACY_MIN_POINTS := 1.0

# --- Boons ------------------------------------------------------------------
## The idle genre's other engine: a rare, brief, visible thing that pays out if
## you happen to be looking. It has to reward attention without punishing
## absence, which is why every one of these is a bonus and none is a penalty.
const BOON_INTERVAL_DAYS := 110.0
## How long one stays on the map. At 1x this is about twenty-five seconds.
const BOON_LIFETIME_DAYS := 13.0

const BOONS := {
	"caravan": {
		"name": "A Caravan",
		"text": "Traders out of the east. They will not wait long.",
		"color": Color("e0b25a"),
	},
	"good_omen": {
		"name": "A Good Omen",
		"text": "Something in the sky that the elders like the look of. Everyone works the harder for it.",
		"color": Color("7fbf6a"),
	},
	"migrating_herd": {
		"name": "A Migrating Herd",
		"text": "The valley fills with animals moving south. It will not come again this year.",
		"color": Color("d98555"),
	},
	"wandering_scholar": {
		"name": "A Wandering Scholar",
		"text": "Someone who has seen other places, and will talk about them for a night.",
		"color": Color("b08ad4"),
	},
	"master_mason": {
		"name": "A Master Mason",
		"text": "Passing through, and willing to show anyone who turns up how it is properly done.",
		"color": Color("b9bec4"),
	},
	"seam_strike": {
		"name": "A Struck Seam",
		"text": "A shaft breaks into something far richer than anyone expected.",
		"color": Color("c9803f"),
	},
	"fair_season": {
		"name": "A Fair Season",
		"text": "Rain when it was wanted and sun when it was wanted. It happens perhaps twice in a life.",
		"color": Color("d4c14e"),
	},
}

const BOON_ORDER: Array[String] = ["caravan", "good_omen", "migrating_herd",
	"wandering_scholar", "master_mason", "seam_strike", "fair_season"]
## How long a "good omen" doubles everything, in days.
const OMEN_DAYS := 30.0
const OMEN_MULTIPLIER := 2.0

# --- Disasters, frequency ---------------------------------------------------
## Index into this from Settings.disaster_frequency. Off is the default.
const DISASTER_FREQUENCY := [
	{"name": "Off", "scale": 0.0},
	{"name": "Rare", "scale": 2.5},
	{"name": "Normal", "scale": 1.0},
	{"name": "Harsh", "scale": 0.45},
]

# --- History ----------------------------------------------------------------
## One sample a day. An idle game lives on the shape of the curve, and the
## curve is cheap: a few hundred floats is nothing next to the tile arrays.
const HISTORY_SAMPLES := 360
const HISTORY_SERIES: Array[String] = ["pop", "food", "herd", "output"]

# --- Decrees ----------------------------------------------------------------
## The answer to "why would anyone manage this themselves?"
##
## Every other decision in the game is locally optimisable - "how many
## woodcutters" has one right answer and the planner computes it perfectly. A
## decree is not that. It is a *commitment*: a large bonus to one thing paid for
## with a real penalty to another, held until you change your mind, with a
## cooldown so switching is not free.
##
## The elders never issue one. They will not gamble the settlement on a guess
## about what it needs next month, which is exactly the judgement a player has
## and an optimiser does not. A managed civilisation runs a decree that matches
## its bottleneck; an unmanaged one runs none.
const DECREE_SWITCH_COOLDOWN_DAYS := 60.0

const DECREES := {
	"expansion": {
		"name": "Go and See",
		"desc": "Everything that can be spared goes to the frontier. The fields suffer for it.",
		"boost": {"explore": 3.0, "stone": 1.25},
		"penalty": {"farm": 0.82, "timber": 0.9},
		"territory": 2.0,
		"color": Color("e0d05a"),
	},
	"industry": {
		"name": "Dig and Build",
		"desc": "Stone, metal and timber before anything else. There will be less on the table.",
		"boost": {"ore": 1.9, "stone": 1.8, "build": 1.5},
		"penalty": {"game": 0.85, "forage": 0.85},
		"color": Color("c9803f"),
	},
	"learning": {
		"name": "Sit and Think",
		"desc": "The best of them are taken off the work rota and told to work it out instead.",
		"boost": {"knowledge": 2.6},
		"penalty": {"build": 0.75, "ore": 0.85},
		"color": Color("b08ad4"),
	},
	"the_land": {
		"name": "Let It Rest",
		"desc": "Hunt lightly, cut sparingly. The country comes back, and comes back richer.",
		"boost": {"farm": 1.35, "forage": 1.3},
		"penalty": {"ore": 0.7, "stone": 0.7},
		"regrowth": 2.0,
		"color": Color("7fbf6a"),
	},
	"the_hearth": {
		"name": "Mind the Children",
		"desc": "Fewer hands in the field, more mouths next year. A bet on the far side of a decade.",
		"boost": {},
		"penalty": {"game": 0.9, "forage": 0.9, "ore": 0.9, "stone": 0.9, "timber": 0.9},
		"birth_mult": 1.9,
		"housing_mult": 1.3,
		"color": Color("d98555"),
	},
}

const DECREE_ORDER: Array[String] = ["expansion", "industry", "learning", "the_land", "the_hearth"]

# --- Council decisions ------------------------------------------------------
## Something happens, the elders want an answer, and there is a right answer
## only if you know what the settlement needs right now.
##
## Every one has a `safe` option, which is what the elders choose on their own
## if nobody says otherwise. Safe is deliberately the weakest - never a
## disaster, never the best. That gap *is* the value of paying attention, and it
## is measurable: see the managed-vs-autopilot test in the harness.
const COUNCIL_INTERVAL_DAYS := 150.0
## How long a question stays open before the elders answer it themselves.
const COUNCIL_PATIENCE_DAYS := 25.0

const COUNCIL := {
	"hard_winter": {
		"title": "A Hard Winter Is Coming",
		"text": "The birds went south early and the elders have seen this before.",
		"options": [
			{"id": "slaughter", "label": "Take the herds now",
				"detail": "A great deal of food at once, and thin hunting for a year."},
			{"id": "ration", "label": "Ration what there is", "safe": true,
				"detail": "Nobody starves. Nobody grows either."},
			{"id": "trust", "label": "Trust the hunt",
				"detail": "Nothing changes. If the winter is mild you lose nothing at all."},
		],
	},
	"strangers": {
		"title": "Strangers at the Edge of the Fields",
		"text": "Two dozen of them, thin, with tools you do not recognise.",
		"options": [
			{"id": "take_in", "label": "Take them in",
				"detail": "More hands, more mouths, and whatever they know."},
			{"id": "trade", "label": "Trade and send them on",
				"detail": "Gold and news of the country beyond."},
			{"id": "refuse", "label": "Send them on", "safe": true,
				"detail": "No risk, and no gain."},
		],
	},
	"the_seam": {
		"title": "An Argument About the Seam",
		"text": "The miners want to drive deeper. The elders think the props will not hold.",
		"options": [
			{"id": "deeper", "label": "Drive deeper",
				"detail": "A great deal of ore. Some of it will cost people."},
			{"id": "shore_up", "label": "Shore it up first",
				"detail": "Slower now, and the shaft lasts."},
			{"id": "leave_it", "label": "Leave it be", "safe": true,
				"detail": "Work the ground you already have."},
		],
	},
	"the_river": {
		"title": "The River Has Moved",
		"text": "A spring flood cut a new channel and the old fields are half a mile from water.",
		"options": [
			{"id": "dig", "label": "Dig a channel to the fields",
				"detail": "Hard work, and the fields are better than they ever were."},
			{"id": "move_fields", "label": "Move the fields to the river",
				"detail": "Lose a season, gain the best ground you have had."},
			{"id": "carry", "label": "Carry the water", "safe": true,
				"detail": "It is what everyone has always done."},
		],
	},
	"the_teacher": {
		"title": "Someone Who Wants to Teach",
		"text": "One of the elders has started gathering the children in the afternoons.",
		"options": [
			{"id": "endow", "label": "Give her a building and a stipend",
				"detail": "Costs real food and timber now. Compounds for ever."},
			{"id": "allow", "label": "Let her get on with it", "safe": true,
				"detail": "Costs nothing, and does a little."},
		],
	},
}

const COUNCIL_ORDER: Array[String] = ["hard_winter", "strangers", "the_seam", "the_river", "the_teacher"]

# --- Momentum ---------------------------------------------------------------
## Boons collected close together build on each other. This is the direct
## reward for actually watching: a player who catches three in a row is running
## at nearly double for a while, and one who never looks loses nothing they had.
const MOMENTUM_WINDOW_DAYS := 45.0
const MOMENTUM_PER_BOON := 0.30
const MOMENTUM_MAX := 5
const MOMENTUM_DECAY_DAYS := 60.0

# --- Festivals --------------------------------------------------------------
## A manual action with a real cost. The elders never call one - spending a
## third of the granary on a party is not a decision an optimiser makes, and it
## is exactly the sort of thing a civilisation does.
const FESTIVAL_COOLDOWN_DAYS := 120.0
const FESTIVAL_FOOD_FRACTION := 0.35
const FESTIVAL_DAYS := 40.0
const FESTIVAL_BIRTH_MULT := 2.2
const FESTIVAL_KNOWLEDGE_MULT := 1.6

# --- Outposts ---------------------------------------------------------------
## Founded by hand on ground the explorers have walked. The elders will not
## choose where - it is a judgement about a place, not a sum - so this is the
## one piece of the map the player alone decides.
const OUTPOST_BASE_COST := {"wood": 220.0, "stone": 140.0, "food": 300.0}
const OUTPOST_COST_GROWTH := 1.55
## Minimum distance from home, in tiles: an outpost has to actually be somewhere.
const OUTPOST_MIN_DISTANCE := 8.0
## Each outpost adds this much worked land, and its tile's richness on top.
const OUTPOST_TERRITORY := 1.2
const OUTPOST_MAX := 12

# --- Map filters ------------------------------------------------------------
## Different questions asked of the same picture. The default shows every
## person in the colour of the trade they work; the others answer "how many are
## there", "where is the land worn out", "where is anything worth having".
enum MapFilter { TRADES, PEOPLE, LAND, RESOURCES, TERRITORY }

const MAP_FILTERS := [
	{
		"id": MapFilter.TRADES, "name": "Trades",
		"desc": "Every person coloured by the work they do.",
	},
	{
		"id": MapFilter.PEOPLE, "name": "Population",
		"desc": "Everyone in one colour, so the crowd reads as a crowd.",
	},
	{
		"id": MapFilter.LAND, "name": "The Land",
		"desc": "How worn the ground is - herds, plants and tree cover, green to bare.",
	},
	{
		"id": MapFilter.RESOURCES, "name": "What Is Here",
		"desc": "Ore, gold, fertile ground and water, everything else dimmed.",
	},
	{
		"id": MapFilter.TERRITORY, "name": "Reach",
		"desc": "What is worked, what is walked, and what nobody has seen.",
	},
]

## One person on the map is this many people in the settlement. Crowds are drawn
## as individual figures up to a budget, then the count carries the meaning.
const PEOPLE_PER_FIGURE_STEPS: Array[float] = [1.0, 5.0, 25.0, 100.0, 500.0, 2500.0, 10000.0]
## Colour every figure the same in the Population filter.
const CROWD_COLOR := Color("e8dcc0")

## --- Weather ----------------------------------------------------------------
## Seasons are the slow rhythm; weather is the fast one. A season lasts a
## quarter of a year and is known in advance, so it is something to plan around.
## Weather turns over every few days and is not, so it is something to notice -
## the reason to glance at a game that is otherwise running itself.
##
## Effects are deliberately small. Weather is texture, not difficulty: the point
## is that the map is never the same twice, not that a wet fortnight ruins a
## civilisation. The season multipliers do the heavy lifting.
##
## `weight` is per season (spring, summer, autumn, winter), so a given climate
## produces the right weather at the right time of year without any extra state.
const WEATHER := [
	{
		"id": "clear", "name": "Clear", "color": Color("cfe3f2"), "clouds": 0.10,
		"note": "Nothing in the sky worth mentioning.",
		"mult": {"build": 1.10, "explore": 1.10},
		"weight": [1.0, 1.5, 1.1, 0.8],
	},
	{
		"id": "fair", "name": "Fair", "color": Color("bcd6ea"), "clouds": 0.35,
		"note": "High cloud, and a good day for anything.",
		"mult": {"farm": 1.05},
		"weight": [1.3, 1.2, 1.2, 0.9],
	},
	{
		"id": "overcast", "name": "Overcast", "color": Color("9aa9b8"), "clouds": 0.75,
		"note": "Grey from edge to edge. It will come to something.",
		"mult": {"explore": 0.95},
		"weight": [1.0, 0.7, 1.2, 1.3],
	},
	{
		"id": "rain", "name": "Rain", "color": Color("7f9ab0"), "clouds": 0.95,
		"note": "Steady rain. The fields drink and nobody else enjoys it.",
		"mult": {"farm": 1.20, "forage": 1.30, "build": 0.90, "explore": 0.85},
		"regrowth": {"forage": 1.40, "forest": 1.25},
		"weight": [1.4, 0.8, 1.1, 0.7],
	},
	{
		"id": "storm", "name": "Storm", "color": Color("5f7183"), "clouds": 1.0,
		"note": "Wind and water together. Everyone who can be indoors is.",
		"mult": {"build": 0.70, "explore": 0.60, "game": 0.85, "farm": 1.10},
		"regrowth": {"forage": 1.15},
		"weight": [0.5, 0.4, 0.7, 0.6],
	},
	{
		"id": "snow", "name": "Snow", "color": Color("dfe9f2"), "clouds": 0.85,
		"note": "Snow, and the country goes quiet.",
		"mult": {"farm": 0.80, "forage": 0.75, "explore": 0.70, "build": 0.85},
		"regrowth": {"game": 0.70, "forage": 0.50},
		"weight": [0.15, 0.0, 0.10, 1.6],
	},
]

## How long one spell of weather lasts, in days, before another is rolled.
const WEATHER_MIN_DAYS := 2.0
const WEATHER_MAX_DAYS := 7.0

## --- Climate ----------------------------------------------------------------
## The reference climate is **Seattle**: 47.6 degrees north, a mild maritime
## year with a small annual swing and a very large swing in daylight.
##
## Temperature is two cosines - one for the year, one for the day - which is
## the standard first approximation and is accurate to a degree or two against
## the real monthly means:
##
##   January mean about 5 C, July mean about 19 C, annual mean about 12 C
##   coldest around the start of January, warmest late July
##   about 8 degrees between the night low and the afternoon high
##
## The year here is 360 days rather than 365, so the phase constants are in
## fractions of a year and not in calendar dates.
const TEMP_ANNUAL_MEAN := 11.8
const TEMP_ANNUAL_SWING := 7.0
## Fraction of the year at which it is coldest. Day 5 of 360.
const TEMP_COLDEST_PHASE := 0.014
## Half the difference between the pre-dawn low and the afternoon high.
const TEMP_DAILY_SWING := 4.0
## The hour the daily peak lands on. Not noon - the ground keeps warming.
const TEMP_PEAK_HOUR := 15.0

## Seattle's latitude, which is what makes the winter days so short.
const LATITUDE_DEG := 47.6
## Daylight never quite collapses or saturates at this latitude, but clamp
## anyway so a pathological value cannot produce a day of negative length.
const DAYLIGHT_MIN_HOURS := 7.5
const DAYLIGHT_MAX_HOURS := 16.5

## Below this the ground freezes: precipitation falls as snow and lies.
const FREEZING_C := 0.0
## Centimetres of snow laid down per day of snowfall.
const SNOW_PER_DAY := 7.0
## And how fast it goes once the temperature climbs, per degree above freezing
## per day. A warm afternoon takes a real bite out of it.
const SNOW_MELT_PER_DEGREE_DAY := 1.9
## Snow deeper than this slows movement as much as it ever will.
const SNOW_DEEP_CM := 25.0
## What that costs at full depth: exploring and building are movement, and
## hunting means walking a long way in it.
const SNOW_MOVEMENT_PENALTY := {"explore": 0.45, "build": 0.75, "game": 0.80}


## Hours of daylight on a given day, from the standard sunrise equation.
static func daylight_hours(day: float) -> float:
	# Solar declination through the year. Phase is measured from the winter
	# solstice, which sits a fortnight before the coldest part of the year.
	var year_frac := fposmod(day, DAYS_PER_YEAR) / DAYS_PER_YEAR
	var decl := deg_to_rad(-23.44) * cos(TAU * year_frac)
	var lat := deg_to_rad(LATITUDE_DEG)
	var cos_h := -tan(lat) * tan(decl)
	if cos_h <= -1.0:
		return DAYLIGHT_MAX_HOURS
	if cos_h >= 1.0:
		return DAYLIGHT_MIN_HOURS
	return clampf(2.0 * rad_to_deg(acos(cos_h)) / 15.0,
			DAYLIGHT_MIN_HOURS, DAYLIGHT_MAX_HOURS)


## The hour the sun comes up, and the hour it goes down.
static func sunrise_hour(day: float) -> float:
	return 12.0 - daylight_hours(day) * 0.5


static func sunset_hour(day: float) -> float:
	return 12.0 + daylight_hours(day) * 0.5


## Where in the day we are, as an hour from 0 to 24.
static func hour_of_day(day: float) -> float:
	return fposmod(day, 1.0) * 24.0


## How high the sun is, from 0 at the horizon to 1 at midday. Zero all night.
## This is what the map darkens by, so it wants to be smooth rather than exact.
static func sun_elevation(day: float) -> float:
	var h := hour_of_day(day)
	var rise := sunrise_hour(day)
	var set_h := sunset_hour(day)
	if h <= rise or h >= set_h:
		return 0.0
	return sin(PI * (h - rise) / maxf(set_h - rise, 0.001))


static func is_night(day: float) -> bool:
	return sun_elevation(day) <= 0.001


## Temperature in Celsius: the year's cosine plus the day's.
static func temperature_c(day: float) -> float:
	var year_frac := fposmod(day, DAYS_PER_YEAR) / DAYS_PER_YEAR
	var annual := -cos(TAU * (year_frac - TEMP_COLDEST_PHASE)) * TEMP_ANNUAL_SWING
	var daily := cos(TAU * (hour_of_day(day) - TEMP_PEAK_HOUR) / 24.0) * TEMP_DAILY_SWING
	return TEMP_ANNUAL_MEAN + annual + daily


static func celsius_to_f(c: float) -> float:
	return c * 9.0 / 5.0 + 32.0

## --- Settlements ------------------------------------------------------------
## An outpost is a place that sends things home. A settlement is a second place
## people actually live: it carries its own housing, claims a wide ring of land
## around itself, and works the ground there.
##
## They are not bought with resources but with **settlement points**, earned by
## growing. That is deliberate - it makes founding one a milestone rather than a
## purchase, and it stops a rich civilisation from simply blanketing the map.
const SETTLEMENT_POP_THRESHOLDS: Array[float] = [
	400.0, 1500.0, 6000.0, 25000.0, 100000.0, 400000.0, 1500000.0,
]
## Founding one costs a *share of the stores*, not a fixed sum.
##
## A flat price cannot work here. The auto-builder spends materials as fast as
## they arrive, so the stores hover near whatever the next building costs rather
## than accumulating - which means any absolute number is either trivial in the
## late game or, as the first two attempts both were, permanently just out of
## reach. Six hundred stone: never payable. Eight hundred timber: the test sat
## at seven hundred and sixty-one, for ever.
##
## A fraction is always payable, always hurts the same amount, and needs no
## retuning at any scale - the same reasoning behind the festival costing a
## third of the granary rather than a number of loaves. The floors below are an
## eligibility check, not a price: you must have a real store before you can
## spend a share of it.
const SETTLEMENT_COST_FRACTION := {"wood": 0.55, "food": 0.40}
const SETTLEMENT_BASE_COST := {"wood": 250.0, "food": 400.0}
## No settlement may cost more than this share, however many you have founded.
const SETTLEMENT_MAX_FRACTION := 0.85
const SETTLEMENT_COST_GROWTH := 1.40
## Far enough out that a settlement is a genuinely separate place.
const SETTLEMENT_MIN_DISTANCE := 12.0
## And far enough from each other.
const SETTLEMENT_SPACING := 9.0
## How far a settlement works out from itself, before technology.
const SETTLEMENT_TERRITORY := 5.0
## And how much of the empire's territory technology a settlement enjoys. Roads
## and cartography widen the capital's reach; the towns get most of that too.
const SETTLEMENT_TECH_SHARE := 0.6
const SETTLEMENT_HOUSING := 140.0
## How much of the surrounding ground a settlement works, against an outpost's.
const SETTLEMENT_YIELD_SCALE := 2.6

## --- Roads ------------------------------------------------------------------
## Two settlements whose claimed ground touches are neighbours, and neighbours
## build a road. The road is not placed by the player - it is what happens when
## two towns are close enough to walk between, which is the reward for siting
## them thoughtfully rather than as far apart as the rules allow.
##
## What a road buys is time on the journey, which in a simulation with no
## individual travel is expressed as the share of a town's output that actually
## reaches the capital. A footpath loses a lot of it; a metalled road loses very
## little. Each tier is unlocked by a technology, so roads improve across the
## ages like everything else.
const ROAD_TIERS := [
	{
		"id": "footpath", "tech": "", "name": "Footpaths",
		"desc": "Trodden earth. Passable in summer, and a misery otherwise.",
		"reach": 1.00, "color": Color("8a7c5e"), "width": 0.06,
	},
	{
		"id": "trackway", "tech": "trackways", "name": "Trackways",
		"desc": "Split logs laid over the soft ground. A cart can get through.",
		"reach": 1.25, "color": Color("a8946c"), "width": 0.09,
	},
	{
		"id": "road", "tech": "roads", "name": "Metalled Roads",
		"desc": "Drained, cambered and stone-bedded. They do not wash out in spring.",
		"reach": 1.60, "color": Color("c2b48d"), "width": 0.13,
	},
	{
		"id": "macadam", "tech": "macadam", "name": "Macadam",
		"desc": "Crushed stone bound and rolled flat. Everything moves twice as far in a day.",
		"reach": 2.10, "color": Color("ddd3b4"), "width": 0.17,
	},
]

## An unconnected settlement keeps only this share of what it produces - the
## rest is eaten by the journey. Connecting one is a real gain, not a rounding.
const ROAD_ISOLATED_REACH := 0.55

## --- Wildlife density -------------------------------------------------------
## One animal marker used to mean "there is wildlife here", which told the player
## nothing about how much. A herd is a quantity, and the map is the only place
## that quantity is ever visible - so the number of animals drawn on a tile is
## the number of animals on it, at a stated scale, exactly like the people.
##
## One unit of the abstract `game` stock is this many head of actual animal. A
## rich forest tile carries about 34 units, so roughly thirteen thousand head.
const ANIMALS_PER_GAME_UNIT := 400.0
## And this many head get one icon on the map.
const ANIMALS_PER_ICON := 1000.0
## Ceiling per tile, so a very rich tile does not become a solid block of deer.
const MAX_ANIMAL_ICONS_PER_TILE := 12

# --- Seasons ----------------------------------------------------------------
## A four-phase year. One extra term in the multiplier chain and no new state,
## and it does three things at once: it gives the game a rhythm instead of a
## monotone climb, it makes storage and spoilage matter, and it makes *when* you
## issue a decree a real question.
##
## Winter is deliberately hard on farming and gentle on nothing. The never-lose
## floor sits underneath it, so a bad winter costs momentum rather than the
## settlement - which is exactly the shape the whole game is tuned to.
const DAYS_PER_YEAR := 360.0
const SEASONS := [
	{
		"name": "Spring", "color": Color("8fbf6a"),
		"note": "Everything green at once, and nothing ripe yet.",
		"mult": {"forage": 1.35, "farm": 0.85, "game": 1.05, "explore": 1.15},
		# Regrowth, not yield: the herds and the greenery genuinely multiply in
		# spring and genuinely do not in winter. This is what makes the animals
		# on the map thicken and thin with the year rather than only the numbers.
		"regrowth": {"game": 1.60, "forage": 1.70, "forest": 1.35},
	},
	{
		"name": "Summer", "color": Color("d9a441"),
		"note": "Long days. The fields do the work.",
		"mult": {"farm": 1.45, "forage": 1.15, "game": 0.85, "build": 1.15},
		"regrowth": {"game": 1.35, "forage": 1.30, "forest": 1.25},
	},
	{
		"name": "Autumn", "color": Color("c9803f"),
		"note": "The harvest and the hunt, both at once, and no time to waste.",
		"mult": {"farm": 1.30, "game": 1.45, "forage": 1.05, "timber": 1.15},
		"regrowth": {"game": 0.75, "forage": 0.55, "forest": 0.85},
	},
	{
		"name": "Winter", "color": Color("8fa8bf"),
		"note": "What is in the store is what there is.",
		"mult": {"farm": 0.52, "forage": 0.64, "game": 0.88, "build": 0.85, "explore": 0.7},
		"regrowth": {"game": 0.35, "forage": 0.20, "forest": 0.45},
	},
]

# --- Opening ----------------------------------------------------------------
## The first few minutes used to be six people, nothing affordable and nothing
## to decide. These are scripted beats: a prompt, and something visible that
## happens when you act on it. Advisory only - the settlement gets there on its
## own either way - but they teach the systems in the order they matter.
const OPENING_BEATS := [
	{
		"id": "fire", "text": "Somebody should get a fire going. Build a Fire Pit - it is the "
			+ "cheapest thing you will ever build and it improves everything after it.",
	},
	{
		"id": "scout", "text": "Nobody knows what is over the ridge, and the settlement cannot "
			+ "claim ground nobody has walked. Put someone on Explorers.",
	},
	{
		"id": "shelter", "text": "People are sleeping under hides. Windbreaks are rough, cheap, "
			+ "and the difference between a band and a camp.",
	},
	{
		"id": "decree", "text": "You can issue a decree - a real bonus paid for with a real cost. "
			+ "The elders never will. Look at the Rule tab.",
	},
	{
		"id": "winter", "text": "Winter is coming and the fields will give almost nothing. "
			+ "What is in the store is what there is.",
	},
]

# --- Notable people ---------------------------------------------------------
## One or two named individuals per era, attached to something that actually
## happened. A name table and an event hook; buys attachment nothing else can.
const GIVEN_NAMES := [
	"Aya", "Bern", "Cass", "Dela", "Eiric", "Fen", "Gita", "Hald", "Ines", "Joro",
	"Kesh", "Lira", "Mabon", "Nera", "Oskar", "Pell", "Quen", "Ruda", "Sten", "Tal",
	"Ulla", "Vig", "Wren", "Yara", "Zev", "Anwe", "Bodil", "Cyr", "Dag", "Elke",
	"Fyn", "Gero", "Hesta", "Ivar", "Juna", "Kilda", "Lem", "Mira", "Noll", "Ovid",
]

const NOTABLE_ROLES := {
	"tech": ["who would not let it go", "who kept asking", "who worked it out",
		"who tried it eleven times"],
	"era": ["who was born the year it changed", "who remembers when it was six of them",
		"who named the place"],
	"ruins": ["who went furthest", "who came back with it", "who read the marks"],
	"council": ["who argued for it", "who was overruled and was right",
		"who said nothing and was listened to"],
	"outpost": ["who walked out and stayed", "who chose the hillside"],
}

# --- Achievements -----------------------------------------------------------
## For odd play, not for playing. An achievement for merely continuing is
## wallpaper; one that describes a strategy teaches the game's depth to somebody
## who had not noticed it was there.
const ACHIEVEMENTS := {
	"vegetarian": {
		"name": "Not One Hunter",
		"desc": "Reach the Neolithic Village without a single day of hunting.",
	},
	"island_steel": {
		"name": "Steel on Scattered Rocks",
		"desc": "Reach the Age of Steel on an Archipelago world.",
	},
	"early_ascent": {
		"name": "A Short Bright Life",
		"desc": "Set a civilisation down before day 400.",
	},
	"cartographer": {
		"name": "The Whole Country",
		"desc": "Map every reachable tile of a world.",
	},
	"all_shapes": {
		"name": "Four Worlds",
		"desc": "Found a settlement on each of the four world shapes.",
	},
	"mastery": {
		"name": "Nothing Left to Learn",
		"desc": "Buy every upgrade available to a single trade.",
	},
	"deep_winter": {
		"name": "The Hungry Decade",
		"desc": "Come through a stretch where the people went hungry for a hundred days, and grow again.",
	},
	"myriad": {
		"name": "Ten Thousand",
		"desc": "Ten thousand people under one set of walls.",
	},
	"untouched": {
		"name": "Left the Land Alone",
		"desc": "Reach the Bronze Age with the herds and the forest both above 80%.",
	},
	"chain": {
		"name": "A Run of Luck",
		"desc": "Hold five boons at once.",
	},
}

const ACHIEVEMENT_ORDER: Array[String] = ["vegetarian", "island_steel", "early_ascent",
	"cartographer", "all_shapes", "mastery", "deep_winter", "myriad", "untouched", "chain"]

# --- Legacy perks -----------------------------------------------------------
## Legacy was a flat multiplier: earned, then forgotten. Spending it on
## permanent unlocks turns prestige into a build order, which is the largest
## addition to replay value available and costs nothing at runtime.
const LEGACY_PERKS := {
	"remembered_fire": {
		"name": "Remembered Fire", "cost": 3,
		"desc": "Every civilisation begins knowing Fire Mastery and Knapped Tools.",
	},
	"old_maps": {
		"name": "Old Maps", "cost": 5,
		"desc": "Begin with a wide stretch of the country already walked.",
	},
	"full_granary": {
		"name": "A Full Granary", "cost": 4,
		"desc": "Begin with food, timber and stone enough to build immediately.",
	},
	"seed_stock": {
		"name": "Seed Stock", "cost": 12,
		"desc": "Begin knowing Agriculture, and with the first plots already broken.",
	},
	"restless": {
		"name": "Restless", "cost": 8,
		"desc": "Decrees can be changed twice as often.",
	},
	"long_memory": {
		"name": "Long Memory", "cost": 10,
		"desc": "Knowledge accumulates 60% faster, in every run, for ever.",
	},
	"deep_roots": {
		"name": "Deep Roots", "cost": 15,
		"desc": "Births 40% more frequent and shelter holds a quarter more people.",
	},
	"prospectors": {
		"name": "Prospectors' Instinct", "cost": 20,
		"desc": "Seams give half again as much, in every run.",
	},
}

const LEGACY_PERK_ORDER: Array[String] = ["remembered_fire", "full_granary", "old_maps",
	"restless", "long_memory", "seed_stock", "deep_roots", "prospectors"]

# --- Trade ------------------------------------------------------------------
## Gold had one sink and no pressure. A standing exchange gives it a purpose,
## makes exploration pay in a second currency, and is a decision the planner
## cannot make because it depends on what you intend to build next.
const TRADE_UNLOCK_TECH := "coinage"
## Fraction of daily production of the exported good that goes out.
const TRADE_EXPORT_FRACTION := 0.30
## Value kept in the exchange. The rest is the caravan's cut.
const TRADE_EFFICIENCY := 0.72
## Gold per day per hundred people to keep a route open.
const TRADE_GOLD_UPKEEP := 0.04

# --- World ------------------------------------------------------------------
## Big enough that walking to the edge is a project, which is the point of
## having explorers at all.
const WORLD_W := 96
const WORLD_H := 64
const BASE_TERRITORY_RADIUS := 3.5
const TERRITORY_PER_POP := 0.028
const MAX_TERRITORY_RADIUS := 18.0

enum Biome {
	OCEAN, LAKE, RIVER, COAST,
	PLAINS, GRASSLAND, FOREST, RAINFOREST,
	HILLS, MOUNTAIN, DESERT, TUNDRA, ICE,
	## Woodland that has been felled or burned. Not a landform - a state. The
	## tile remembers the forest it was and grows back into it.
	CLEARING
}

## Below this fraction of its tree cover a wooded tile reads as cleared ground;
## above the upper mark it has grown back. The gap is hysteresis, so a tile
## being worked does not flicker between the two.
const CLEARED_BELOW := 0.22
const REGROWN_ABOVE := 0.55

## World shapes. The generator reads `land`, `scale` and `caps` from here, so
## adding a shape is a data edit.
##   land  - roughly what fraction of the map ends up above sea level
##   scale - noise frequency; low is few big masses, high is many small ones
##   caps  - polar ice, which only makes sense on a whole-world map
enum WorldType { EARTH, CONTINENTS, ISLANDS, ARCHIPELAGO }

const WORLD_TYPES := [
	{
		"id": WorldType.EARTH, "name": "Earth",
		"desc": "A whole world: several continents, real climate bands from the tropics to the poles, and ice at the top and bottom.",
		"land": 0.34, "scale": 0.030, "caps": true, "climate": true, "rivers": 8
	},
	{
		"id": WorldType.CONTINENTS, "name": "Continents",
		"desc": "Two or three big landmasses with room to spread out. Climate bands and polar ice.",
		"land": 0.46, "scale": 0.024, "caps": true, "climate": true, "rivers": 7
	},
	{
		"id": WorldType.ISLANDS, "name": "Islands",
		"desc": "A warm sea scattered with substantial islands. No poles - this is a close-up of one region, not a globe. You will want Seafaring.",
		"land": 0.30, "scale": 0.055, "caps": false, "climate": false, "rivers": 4
	},
	{
		"id": WorldType.ARCHIPELAGO, "name": "Archipelago",
		"desc": "Hundreds of small islands and shallow water between them. Land is precious and Seafaring is not optional.",
		"land": 0.22, "scale": 0.085, "caps": false, "climate": false, "rivers": 2
	},
]

## `ore` and `gold` are deposit richness, not depletable stocks - seams do not
## run dry at this timescale, which keeps the civilisation always able to grow.
const BIOME_INFO := {
	Biome.OCEAN: {
		"name": "Ocean", "color": Color("1b3652"), "water": 1.0,
		"game": 0.0, "forest": 0.0, "forage": 0.0, "fertility": 0.0, "stone": 0.0, "ore": 0.0, "gold": 0.0
	},
	Biome.LAKE: {
		"name": "Lake", "color": Color("2f6b93"), "water": 1.0,
		"game": 8.0, "forest": 0.0, "forage": 5.0, "fertility": 0.0, "stone": 0.0, "ore": 0.0, "gold": 0.0
	},
	Biome.RIVER: {
		"name": "River", "color": Color("3f83ab"), "water": 1.0,
		"game": 10.0, "forest": 0.0, "forage": 7.0, "fertility": 0.0, "stone": 0.0, "ore": 0.05, "gold": 0.35
	},
	Biome.COAST: {
		"name": "Coast", "color": Color("cbbd8f"), "water": 0.25,
		"game": 5.0, "forest": 2.0, "forage": 10.0, "fertility": 0.25, "stone": 0.1, "ore": 0.0, "gold": 0.05
	},
	Biome.PLAINS: {
		"name": "Plains", "color": Color("9aae62"), "water": 0.0,
		"game": 32.0, "forest": 4.0, "forage": 11.0, "fertility": 1.15, "stone": 0.1, "ore": 0.05, "gold": 0.0
	},
	Biome.GRASSLAND: {
		"name": "Grassland", "color": Color("7d9b57"), "water": 0.0,
		"game": 24.0, "forest": 7.0, "forage": 16.0, "fertility": 1.0, "stone": 0.1, "ore": 0.05, "gold": 0.0
	},
	Biome.FOREST: {
		"name": "Forest", "color": Color("3f6b3c"), "water": 0.0,
		"game": 34.0, "forest": 48.0, "forage": 26.0, "fertility": 0.6, "stone": 0.1, "ore": 0.05, "gold": 0.0
	},
	Biome.RAINFOREST: {
		"name": "Rainforest", "color": Color("245a35"), "water": 0.35,
		"game": 26.0, "forest": 62.0, "forage": 34.0, "fertility": 0.75, "stone": 0.05, "ore": 0.05, "gold": 0.10
	},
	Biome.HILLS: {
		"name": "Hills", "color": Color("8a8763"), "water": 0.0,
		"game": 16.0, "forest": 16.0, "forage": 9.0, "fertility": 0.4, "stone": 1.15, "ore": 1.05, "gold": 0.20
	},
	Biome.MOUNTAIN: {
		"name": "Mountain", "color": Color("6f6f74"), "water": 0.0,
		"game": 6.0, "forest": 4.0, "forage": 2.0, "fertility": 0.0, "stone": 1.9, "ore": 1.75, "gold": 0.50
	},
	Biome.DESERT: {
		"name": "Desert", "color": Color("c9ab6d"), "water": 0.0,
		"game": 5.0, "forest": 1.0, "forage": 3.0, "fertility": 0.1, "stone": 0.35, "ore": 0.50, "gold": 0.18
	},
	Biome.TUNDRA: {
		"name": "Tundra", "color": Color("8d9a95"), "water": 0.1,
		"game": 14.0, "forest": 3.0, "forage": 5.0, "fertility": 0.15, "stone": 0.4, "ore": 0.35, "gold": 0.08
	},
	Biome.ICE: {
		"name": "Ice", "color": Color("dfe8ee"), "water": 0.3,
		"game": 2.0, "forest": 0.0, "forage": 0.0, "fertility": 0.0, "stone": 0.0, "ore": 0.0, "gold": 0.0
	},
	Biome.CLEARING: {
		"name": "Clearing", "color": Color("8a8a52"), "water": 0.0,
		"game": 14.0, "forest": 6.0, "forage": 12.0, "fertility": 0.85, "stone": 0.1, "ore": 0.05, "gold": 0.0
	}
}

# --- Animals ----------------------------------------------------------------
## Wildlife you can actually see, as distinct from the abstract "game" stock the
## economy runs on. Each kind lives where it would really live, wanders between
## neighbouring tiles, and has a silhouette you can tell apart at a glance.
##
## `weight` biases how many of each the world holds; `needs_game` ties predators
## to the herds they eat, so wolves thin out when the deer do.
enum Animal { DEER, WOLF, RABBIT, BIRD }

const ANIMALS := {
	Animal.DEER: {
		"name": "Deer", "color": Color("a5764a"), "weight": 1.0, "needs_game": 0.25,
		"biomes": [Biome.FOREST, Biome.RAINFOREST, Biome.CLEARING, Biome.TUNDRA, Biome.HILLS]
	},
	Animal.WOLF: {
		"name": "Wolves", "color": Color("6f7681"), "weight": 0.30, "needs_game": 0.55,
		"biomes": [Biome.FOREST, Biome.HILLS, Biome.TUNDRA, Biome.MOUNTAIN, Biome.CLEARING]
	},
	Animal.RABBIT: {
		"name": "Rabbits", "color": Color("c9b79a"), "weight": 1.15, "needs_game": 0.0,
		"biomes": [Biome.PLAINS, Biome.GRASSLAND, Biome.CLEARING, Biome.DESERT, Biome.COAST]
	},
	Animal.BIRD: {
		"name": "Birds", "color": Color("e6eef4"), "weight": 0.95, "needs_game": 0.0,
		"biomes": [Biome.COAST, Biome.LAKE, Biome.RIVER, Biome.PLAINS, Biome.GRASSLAND,
			Biome.RAINFOREST, Biome.FOREST, Biome.TUNDRA]
	}
}

const ANIMAL_ORDER: Array[int] = [Animal.DEER, Animal.WOLF, Animal.RABBIT, Animal.BIRD]

## How many creatures the map tracks at once. Purely cosmetic, so this is a
## drawing budget rather than a simulation parameter - a fixed cost no matter
## how large the civilisation grows.
const MAX_ANIMALS := 72
## Roughly how often a given animal wanders to a neighbouring tile, in days.
const ANIMAL_MOVE_DAYS := 3.0
## Animals repopulate and reshuffle on this cadence, in days.
const ANIMAL_RESTOCK_DAYS := 6.0

# --- Disasters --------------------------------------------------------------
## Off by default, and deliberately so: the default game is a calm one you leave
## running. Switched on in Settings they are setbacks, never defeats - the
## never-lose floor still holds underneath them.
const DISASTERS := {
	"forest_fire": {
		"name": "Forest Fire",
		"text": "Fire runs through the timber on the ridge. It burns for three days.",
		"weight": 1.0, "needs": "forest"
	},
	"flood": {
		"name": "Flood",
		"text": "The river comes up over its banks and takes the low ground with it.",
		"weight": 1.0, "needs": "water"
	},
	"hurricane": {
		"name": "Hurricane",
		"text": "A storm comes in off the water and does not let up for two days.",
		"weight": 0.7, "needs": "coast"
	},
	"tornado": {
		"name": "Tornado",
		"text": "A funnel drops out of a green sky and walks across the open ground.",
		"weight": 0.8, "needs": "open"
	}
}

## Mean days between disasters when they are switched on.
const DISASTER_INTERVAL_DAYS := 140.0

# --- Events -----------------------------------------------------------------
const EVENT_COOLDOWN_DAYS := 24.0
const EVENT_CHANCE_PER_DAY := 0.06


## Stable lowercase id for a biome, which is also its artwork filename.
static func biome_id(b: int) -> String:
	if not BIOME_INFO.has(b):
		return "unknown"
	return String(BIOME_INFO[b]["name"]).to_lower().replace(" ", "_")


## Same for an animal.
static func animal_id(kind: int) -> String:
	match kind:
		Animal.DEER: return "deer"
		Animal.WOLF: return "wolf"
		Animal.RABBIT: return "rabbit"
		Animal.BIRD: return "bird"
	return "unknown"


static func is_water_biome(b: int) -> bool:
	return b == Biome.OCEAN or b == Biome.LAKE or b == Biome.RIVER


## Open water needs boats; lakes and rivers can be forded.
static func is_deep_water(b: int) -> bool:
	return b == Biome.OCEAN


static func world_type_info(id: int) -> Dictionary:
	for w in WORLD_TYPES:
		if int(w["id"]) == id:
			return w
	return WORLD_TYPES[0]


## Format a number compactly. Idle games live in this function - it has to stay
## readable from six people all the way to nine figures.
static func fmt(value: float, decimals: int = 1) -> String:
	var a := absf(value)
	if a >= 1e18:
		# Past quintillions the suffixes stop being worth learning. GDScript's
		# String % has no %e, so this is assembled rather than formatted.
		var e := int(floor(log(a) / log(10.0)))
		return "%.2fe%d" % [value / pow(10.0, float(e)), e]
	if a >= 1e15:
		return "%.2fQ" % (value / 1e15)
	if a >= 1e12:
		return "%.2fT" % (value / 1e12)
	if a >= 1e9:
		return "%.2fB" % (value / 1e9)
	if a >= 1e6:
		return "%.2fM" % (value / 1e6)
	if a >= 1000.0:
		return "%.2fk" % (value / 1000.0)
	if a < 10.0:
		return String.num(value, decimals)
	return String.num(value, 0)


## Whole counts of people, which want separators rather than suffixes until
## they get genuinely large.
static func fmt_count(value: float) -> String:
	if absf(value) >= 1e6:
		return fmt(value)
	var s := String.num(floorf(value), 0)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


## The date, as a running clock: "412 days, 14:23:07".
##
## `day` is a float and always has been - the fractional part is the time of
## day, it just was never shown. A settlement that ticks a bare day counter
## looks stopped between days; one with a second hand is visibly alive even
## paused, and at thirty seconds to the day the clock moves at roughly fifty
## times real time, which reads as a place going about its business.
static func fmt_clock(day: float) -> String:
	var whole := floorf(maxf(day, 0.0))
	var secs := int((maxf(day, 0.0) - whole) * 86400.0)
	return "%s days, %02d:%02d:%02d" % [fmt_count(whole + 1.0),
			secs / 3600, (secs / 60) % 60, secs % 60]


## Format a per-day rate with an explicit sign.
static func fmt_rate(value: float) -> String:
	var s := "+" if value >= 0.0 else "-"
	return s + fmt(absf(value), 2)


## An hour of the day as a clock time - "06:42".
static func fmt_hour(h: float) -> String:
	var total := int(round(fposmod(h, 24.0) * 60.0))
	return "%02d:%02d" % [(total / 60) % 24, total % 60]
