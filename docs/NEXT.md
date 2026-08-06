# Where to take this next

Two parts: how much more detail the game can afford, and what is actually worth
building. Numbers here are measured on this build, not estimated.

## How much granularity you can afford

### What it costs today

Measured headless on one core, a 2,400-person Iron Age city on a 96x64 world:

| | measured |
| --- | --- |
| Simulation throughput | **49 sim-days/sec** (incl. world gen and a save/load test) |
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

## Gameplay

**A prestige layer is the biggest missing piece.** Cookie Clicker's ascension is
what turns "I hit a wall" into "I start again faster", and this game has the
perfect fiction for it: your civilisation ends, and the next one begins knowing
what this one learned. Carry over a fraction of lifetime output as a permanent
multiplier — call it Legacy, or the songs they still sing about you. It is
maybe 150 lines on top of what already exists, because `job_lifetime` is already
tracked and `_rebuild_mods` is already the one place multipliers are applied.

**Golden-cookie equivalents.** Cookie Clicker's biggest retention trick is the
rare click-for-a-big-bonus. The honest version here is a caravan, a good omen, a
migrating herd — something that appears on the map for twenty seconds and pays
out if you notice. It rewards watching without punishing not watching, which is
exactly the contract an idle game makes.

**The eras want more to do at the top.** Five eras is enough to prove the arc.
The economy now scales forever but the *content* stops at Steel. More eras are
pure data in `Balance.gd` — no simulation work.

**Exploration should pay off more.** Right now it gates territory and turns up
the occasional cache. Ruins that grant a tech, other peoples to trade with, or a
second settlement site would make explorers the interesting choice they deserve
to be.

**Disasters need a difficulty dial** rather than one switch. "Rare / Normal /
Harsh" costs nothing and makes the toggle a real setting.

## Interface

**The left column is doing too much.** Stores, people, land and workshops are
four different questions in one scrolling strip. Consider a single "state of the
settlement" summary line at the top and put the detail behind a tab.

**Nothing shows history.** An idle game lives on the shape of the curve, and
the game currently only shows the current value. A sparkline of population,
food and the herd over the last few hundred days would be the single highest
value-per-pixel addition — and the data is cheap to keep (one sample a day in a
ring buffer is 1,440 floats an hour).

**Rates should be attributable.** "+754 wood/day" is good; "+754 (612 woodlots,
142 wild)" is much better, and it is the information a player needs to decide
what to build next.

**The build tab does not say what a thing is worth.** It says what a Woodlot
costs but not that it will add ~2 wood/day. Show the marginal effect and the
payback time — that is the core decision of the genre.

**Number formatting will need scientific notation** past about 1e15.
`Balance.fmt` currently stops at trillions.

## Playtest logging

The event log is prose for the player, not data for you. Worth adding:

- **A CSV recorder** behind the verbose-log setting: one row per in-game day
  with population, every resource, every job count and the derived rates. Then
  balance arguments get settled with a spreadsheet instead of opinions.
- **A "why" probe** on the labour planner. It makes a non-obvious decision every
  half-day and there is currently no way to ask it why. Logging the target,
  the realised yields and the resulting split — behind a flag — would have found
  the 937-woodcutter bug in a minute rather than a run.
- **Deterministic seeded runs in CI with a recorded baseline**, failing when
  population at day 500 moves more than ~15%. That turns silent balance
  regressions into build failures.
- **A fast-forward button in-game** (100x for ten seconds) so a designer can see
  an hour of consequences without waiting an hour.

## Smarter autopilot

The labour planner is need-driven and reactive. Three upgrades, in order:

1. **Look ahead instead of at the current shortfall.** It currently fills a gap
   over ten days. It should notice that a Granary is queued and start
   stockpiling stone *before* the order is placed.
2. **Compare marginal value across trades in one currency.** Right now food is
   sized against need, materials against stock targets, and knowledge gets the
   leftovers. A single "what does one more worker here get me" score, in
   comparable units, would let it make genuinely optimal calls — and it would
   have avoided both saturation bugs by construction.
3. **Make the autopilot legible.** Show its current reasoning in one line — "37
   on food because the larder is thin, 12 on timber because a Longhouse is
   queued". A player who understands the automation trusts it, and a player who
   trusts it is happy to leave it running, which is the entire point.

One caution: the automation is now good enough that a player who never touches
it does fine. That is the right default and a design risk — if the optimum is
"leave it alone", the management layer is decoration. The fix is not to make the
autopilot worse. It is to give the player decisions the autopilot cannot make:
where to settle next, which era to rush, what to do with a windfall.
