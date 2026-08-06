# Where to take this next

Two parts: how much more detail the game can afford, and what is actually worth
building. Numbers here are measured on this build, not estimated.

## How much granularity you can afford

### What it costs today

Measured headless on one core, a 2,400-person Iron Age city on a 96x64 world:

| | measured |
| --- | --- |
| Simulation throughput | **~45 sim-days/sec** (incl. world gen, save/load, prestige and baseline tests) |
| Needed at 1x speed | 0.5 days/sec |
| Needed at 4x speed | 2.0 days/sec |
| **Headroom at 4x** | **~25x** |
| Terrain draw calls | **1** per frame |
| Overlay primitives | capped at ~140 regardless of population |
| Tile memory | ~340 KB (14 arrays x 6,144 tiles x 4 bytes) |

The simulation is the expensive half and the map is nearly free. That is the
opposite of what people assume, and it is what should drive the decisions below.

### Where the cost actually is

Per simulation substep (ten per in-game day) the only work proportional to
anything is:

- **one ecology sweep** over the territory — regrow three stocks, check tree cover
- **three drains** over the territory — hunting, foraging, woodcutting

That is `4 x territory` tile-operations per substep. Territory is capped at
`MAX_TERRITORY_RADIUS = 18`, so ~1,017 tiles: about **160,000 tile-ops/sec at 4x
speed**. Everything else in a step — jobs, production, population, building,
research, upgrades — is O(number of job types), which is ten.

Three deliberate choices keep it there, and they are the ones to preserve:

1. **Terrain aggregates are cached.** Water access, fertility, stone, ore, gold
   and the refuge floors are summed once when the territory changes, never per
   step. Living-stock totals are produced as a by-product of the sweep that was
   happening anyway.
2. **Housekeeping runs once a game-day, not per substep.** Auto-build, upgrade
   buying, animal movement and visibility all share one daily tick.
3. **The map is a texture, not tiles.** 6,144 rects per frame became one
   `draw_texture_rect`, rebuilt from a packed byte buffer at most 2.5 times a
   second and only when something changed.

### What you can add, and what it costs

Roughly in order of value per unit of risk:

| Change | Cost | Verdict |
| --- | --- | --- |
| **World 4x larger** (192x128 = 24k tiles) | Generation is one-off O(W·H), ~0.2 s. Texture rebuild 24k pixel writes at 2.5 Hz = 60k/s. Memory ~1.4 MB. Territory is capped separately, so the *simulation* cost does not move at all. | **Free. Do it if the map should feel bigger.** |
| **World 16x larger** (384x256 = 98k tiles) | Memory ~5.6 MB, texture rebuild 245k writes/sec. Still fine, but generation approaches a second — worth moving off the main thread or showing a progress bar. | Affordable |
| **Territory 4x larger** (radius 36, ~4,000 tiles) | Directly multiplies the hot loop: ~640k tile-ops/sec at 4x. Roughly 4x the simulation cost, leaving ~6x headroom. | **Affordable, and the most impactful.** Bigger worked land makes exploration matter more. |
| **10x more animals** (~700) | They move on a daily tick and draw under a cap. Movement becomes ~700 ops/day, nothing. Drawing is already capped. | Free |
| **Per-tile buildings** (each structure on a real tile, not scattered near home) | Pure data: an array of (tile, type). Drawing is already budgeted. No simulation cost. | **Free, and a big visual upgrade.** |
| **Per-tile stock display** (see which specific wood is depleted) | Already in the data — it is the same arrays the ecology uses. Only a rendering decision. | Free |
| **Visible individual people** (100-200 figures with simple steering) | 200 agents x 60 fps of position updates is trivial; the draw budget already handles it. Do *not* give them pathfinding. | Affordable if they stay decorative |
| **Every person simulated individually** (2,400+ agents with needs, homes, jobs) | 2,400 agents x 10 substeps/sec x 4x = 96k agent-updates/sec *plus* whatever each does. Population is unbounded by design, so this scales with the thing that is supposed to grow forever. | **No.** This is the one thing that breaks the game. |
| **Per-tile weather / seasons** | One more array and one more sweep term: +25% on the hot loop. | Affordable |
| **Pathfinding for anything** | A* over 6k tiles is ~1 ms per query. Fine occasionally, ruinous per-agent-per-tick. | Only for one-off queries |

**The rule to hold on to:** cost may scale with the *map*, which is fixed at
generation, and must never scale with the *population*, which grows without
bound. Every current system obeys that. The moment something is per-person
per-tick, the idle game has a ceiling again.

If you want one number to watch: keep the harness above **~10 sim-days/sec**.
That is 5x the 4x-speed requirement, which leaves room for the slowest machine
you care about.

## What has been built

Everything the previous pass recommended is now in. Kept here as a record of
what each one actually cost and what it changed.

**Legacy (prestige).** Set a civilisation down and the next one starts knowing
what it learned. Earned from lifetime output with a 0.55 exponent, so a better
run is clearly better and no single run ends the game. A first ascension around
day 700 is worth roughly +75% to every trade. An earlier tuning gave +900%,
which made the second run a formality - the divisor is the dial.

**Boons.** A caravan, a good omen, a migrating herd, a wandering scholar. Rare,
brief, visible on the map, clickable where they stand. Every one is a bonus and
none is a penalty, so noticing is rewarded and not noticing costs nothing.

**Twelve more techs and three more eras**, through Classical, Sail and
Industrial Dawn, plus tenements, workshop rows and universities to live in them.
The first attempt priced them so the whole tree finished by day 500 - late tech
costs now run to ~950k and spread across the arc.

**Ruins on the frontier**, which occasionally hand over a whole idea at once.

**Disaster frequency** is Off / Rare / Normal / Harsh rather than one switch.

**Sparklines** for population, food, herd health and lifetime output - the
shape of the last 360 days, one `draw_polyline` each, redrawn only when the
data moves.

**A summary line and a plan line.** One sentence on how it is going, and one on
why the workforce looks the way it does. The second matters more than it
sounds: an automation you cannot interrogate is one you will not leave running.

**Attributable rates.** Hovering a store says where the number comes from -
"612 foresters, 142 woodcutters" - and what is being consumed against it.

**Build orders state their case.** Every card says what one more does and how
many days it takes to pay for itself, computed by valuing cost and gain in one
currency.

**A CSV recorder** behind a setting: one row per in-game day, every resource,
rate and job. Balance arguments get settled with a spreadsheet.

**A +100 days button** while the verbose log is on, so a designer does not wait
an hour to see an hour of consequences.

**A baseline regression test** in CI, plus a prestige test. A silent balance
change now breaks the build.

**Smarter autopilot.** It looks ahead at what it actually intends to build
rather than the priciest thing in the catalogue; it ranks trades by marginal
value in one currency instead of a fixed order; and spare hands go to the
slot-based trades - farms, woodlots, mines, quarries - rather than piling onto
a wild stock that cannot give up any more.

## Still worth doing

**Art and audio** remain the biggest visible gap. Everything is primitives.

**More boon types**, and a reason to be watching at a particular moment.

**Something the autopilot cannot decide.** The automation is now good enough
that a player who never touches it does fine. That is the right default and a
standing design risk: if the optimum is "leave it alone", the management layer
is decoration. The answer is not to make the autopilot worse - it is to give
the player choices it cannot make. Where to found a second settlement. Which
era to rush. What to spend a windfall on. None of those exist yet.

**A second settlement** is the obvious next system, and the one the map is
already carrying the data for.

**Trade with other peoples** the explorers find, which would give gold a
purpose beyond the Treasury.
