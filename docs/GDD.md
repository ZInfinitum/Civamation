# Civamation — Game Design Document

*Working title. Version 0.1.0. This document describes the game as it is
actually built, not as it is hoped for; anything not yet implemented is in
[§18 Not Built Yet](#18-not-built-yet) and nowhere else.*

Every number in here is read from `scripts/autoload/Balance.gd`. When the two
disagree, Balance.gd is right and this document is stale.

---

## Contents

1. [The pitch](#1-the-pitch)
2. [Design pillars](#2-design-pillars)
3. [The player's experience](#3-the-players-experience)
4. [Time](#4-time)
5. [The world](#5-the-world)
6. [The land](#6-the-land)
7. [Animals](#7-animals)
8. [Resources](#8-resources)
9. [People and trades](#9-people-and-trades)
10. [Population — the simulation underneath](#10-population--the-simulation-underneath)
11. [The ecology](#11-the-ecology)
12. [Building](#12-building)
13. [Knowledge, techs and upgrades](#13-knowledge-techs-and-upgrades)
14. [Eras and progression](#14-eras-and-progression)
15. [Player agency — what the elders will never do](#15-player-agency--what-the-elders-will-never-do) *(includes settlements)*
16. [Legacy, profile and the meta-game](#16-legacy-profile-and-the-meta-game)
17. [Interface, art and performance](#17-interface-art-and-performance)
18. [Not built yet](#18-not-built-yet)
19. [Known design problems](#19-known-design-problems)
20. [Balance reference](#20-balance-reference)

---

## 1. The pitch

Six people stop walking somewhere with water and good grass. Over the next few
hours they become a city.

Civamation is an **idle civilisation builder**: something you leave running on
a second monitor and glance at, in the Cookie Clicker mould — costs grow
geometrically, output grows with what you own, upgrades periodically double a
whole trade outright, nothing caps, the numbers keep going up. What sits under
it is not a cookie but a **real population and ecology model**: Verhulst
logistic growth, a Holling type II functional response on every wild stock,
Liebig's law of the minimum on consumption.

It is a **hopeful** game. The herds always come back, the forest always grows
back, and the settlement never falls below three quarters of the largest it has
ever been. A hard stretch costs the player time and momentum. It never costs
them their civilisation. There is no lose state and there is no fail screen.

There is also no ending. There are nine eras, thirty-five technologies, one
hundred and thirty-two upgrades and a prestige layer, and after all of that the
line keeps going up.

**Platform intent.** PC via Steam, Xbox Game Pass, console, and web. Everything
is built on the GL Compatibility renderer, the whole UI is focus-navigable with
a gamepad, and the simulation is deterministic and fixed-step so a save moves
between platforms unchanged. See `docs/PLATFORMS.md`.

---

## 2. Design pillars

**One: it plays itself competently.** Left completely alone the settlement
assigns its own labour, builds its own buildings and pursues its own research,
and keeps growing. That is not a concession — it is the product. Every one of
those three autopilots has an off switch.

**Two: managing it must beat leaving it.** If the optimal play is to close the
window, there is no game. The gap is not asserted, it is measured: the headless
harness runs the same seed twice, once left alone and once managed, and **fails
the build** if managing does not win. It currently comes out at roughly **1.6×
population and 100×+ lifetime output**.

**Three: nothing is ever lost.** No famine wipes a settlement, no fire ends a
run, no wild stock is hunted to extinction. Thirty per cent of every living
stock is permanently out of reach (`STOCK_REFUGE`), and population has a hard
floor at 75% of its own high-water mark.

**Four: the numbers must always go up.** A stalled idler is a broken idler.
Every ceiling in the game is soft, every wall has a door, and if the trace ever
shows a plateau that is a bug with a cause, not a difficulty setting.

**Five: performance is a feature.** The map is 6,144 tiles and draws in one
call. The simulation is fixed-step and allocation-free in its hot loop. This is
a game people leave running for hours next to something else they are doing; it
has no right to their CPU.

**Six: every asset is replaceable.** Drop a PNG in a folder with the right name
and it appears. No registration, no import step, no code change.

---

## 3. The player's experience

### The first five minutes

Six people, a river, and about eleven tiles of visible ground. Food and water
tick up. Nothing is affordable yet.

Five **opening beats** fire in order, each a prompt with a visible consequence.
They are advisory — the settlement gets there on its own either way — but they
teach the systems in the order those systems matter:

| Beat | Prompt |
| --- | --- |
| `fire` | Build a Fire Pit. Cheapest thing you will ever build, improves everything after it. |
| `scout` | Put someone on Explorers. The settlement cannot claim ground nobody has walked. |
| `shelter` | Windbreaks. Rough, cheap, the difference between a band and a camp. |
| `decree` | You can issue a decree. The elders never will. |
| `winter` | Winter is coming and the fields will give almost nothing. |

### The shape of a session

- **Minutes 0–10** — nomadic band. Hunting and foraging. Everything is scarce.
- **Minutes 10–40** — the settling. Agriculture arrives, farms replace the hunt
  as the food base, the wild stocks stop being the constraint.
- **Hour 1–2** — the industrial middle. Mines, quarries, woodlots. Population in
  the thousands. Upgrades start doubling trades.
- **Hour 2+** — the long tail. Knowledge in the millions, population in the tens
  of thousands, upgrade tiers stepping by 10× each.

### The loop

```
       ┌─────────────────────────────────────────────────┐
       │                                                 │
   assign work ──► production ──► stores ──► population ─┤
       ▲                │                        │       │
       │                ▼                        ▼       │
       │            build slots            more workers  │
       │                │                        │       │
       └──── knowledge ◄┴─── techs & upgrades ◄──┘       │
                                                         │
                        explore ──► territory ──────────►┘
```

Population is both the output the player watches *and* the workforce that
produces it. That closed loop is the single most dangerous thing in the design
and most of §10 is about damping it.

---

## 4. Time

Time runs **day by day**, never by year. A day is the atomic unit of everything:
the log stamps days, the chronicle records days, birth and death rates are
per-day, spoilage is per-day.

| Speed | Label | Real seconds per in-game day | Unlocks |
| --- | --- | --- | --- |
| 0 | `II` | paused | — |
| 1 | `30s` | 30 | from the start |
| 2 | `15s` | 15 | from the start |
| 3 | `1s` | 1 | era 1 (Semi-Settled Camp) |
| 4 | `1mo` | 1/30 — a second is a month | era 3 (Bronze Age Town) |

Under the hood the simulation runs **ten fixed substeps per day** (`STEP_DAYS =
0.1`). Above four days a second it drops to **three substeps per day** — fast
forwarding costs frames of fidelity rather than frames per second. At most 40
substeps run per rendered frame, so a stall in the host never turns into a
spiral.

**Seasons.** A four-phase year, each season one quarter of it, multiplying what
every trade brings in.

| Season | Effect |
| --- | --- |
| **Spring** | forage ×1.35, explore ×1.15, game ×1.05, farm ×0.85 |
| **Summer** | farm ×1.45, build ×1.15, forage ×1.15, game ×0.85 |
| **Autumn** | game ×1.45, farm ×1.30, timber ×1.15 |
| **Winter** | farm ×0.52, forage ×0.64, explore ×0.70, build ×0.85 |

Seasons cost no extra state — they are one more term in the multiplier chain —
and they do three things at once: they give the game a rhythm instead of a
monotone climb, they make storage and spoilage matter, and they make *when* you
issue a decree a real question.

**Weather.** Under the seasons sits a faster rhythm. A season is slow, known in
advance and something to plan around; weather turns over every **2–7 days**,
unannounced, and is something to *notice* — the reason to glance at a game that
is otherwise running itself.

| Weather | Effect | Sky |
| --- | --- | --- |
| **Clear** | build ×1.10, explore ×1.10 | almost empty |
| **Fair** | farm ×1.05 | light |
| **Overcast** | explore ×0.95 | heavy |
| **Rain** | farm ×1.20, forage ×1.10, build ×0.90, explore ×0.85 | full |
| **Storm** | build ×0.70, explore ×0.60, game ×0.85, farm ×1.10 | total |
| **Snow** | farm ×0.80, forage ×0.75, explore ×0.70, build ×0.85 | heavy |

Each is weighted per season, so snow belongs to winter without being
special-cased anywhere. Effects are deliberately small — weather is texture, not
difficulty; the season multipliers do the heavy lifting.

**Clouds** are the visible half of it. How much of the sky is covered *is* the
current weather, so it reads off the map without looking at a label. Their
positions are a pure function of the in-game day, so they cost no state, never
drift out of step with the simulation, and come back identical after a reload;
they drift in world space rather than screen space, so they do not slide around
when you pan. Reduced motion turns them off.

**Offline.** The game credits up to **12 hours** of absence by running the real
simulation rather than approximating it (capped at 6,000 substeps of up to 2
days each), and reports what happened as a **digest** — population, era, techs,
upgrades, ground mapped — rather than as one line in the log. It autosaves every
20 seconds by default and on focus loss.

---

## 5. The world

A **96 × 64 grid — 6,144 tiles**. Not isometric: a flat top-down grid, drawn as
one texture.

The player picks a **shape** when starting, and the shape is not cosmetic — it
changes which technologies are urgent.

| Shape | Land | Feature scale | Ice caps | Climate bands | Rivers |
| --- | --- | --- | --- | --- | --- |
| **Earth** | 34% | 0.030 | yes | yes | 8 |
| **Continents** | 46% | 0.024 | yes | yes | 7 |
| **Islands** | 30% | 0.055 | no | no | 4 |
| **Archipelago** | 22% | 0.085 | no | no | 2 |

Earth and Continents are whole worlds, so they get polar ice and a real climate
gradient from equator to pole. Islands and Archipelago are a close-up of one
warm region, not a globe, so they have neither. On Archipelago, **Seafaring is
not optional** — without it the settlement is trapped on its starting rock.

Generation is elevation × latitude × rainfall, from value noise at the shape's
feature scale, with rivers traced downhill from high ground to the sea.

**Seeds.** A seed fixes the **world**: the same land, rivers and ore, the same
starting location, the same six people with the same things in front of them.
Two players who type the same seed begin in exactly the same place.

It does not fix the **run**. Each new game rolls a salt, so the weather, the
events, the council questions and the boons differ between two games on one
seed — and they diverge further with every decision either player makes. A seed
is a starting position, not a script. (The salt is saved, so reloading
continues the run you were in; the headless harness pins it to zero.)

The pause menu shows the seed and shape as one copyable line — `482913 /
Archipelago` — and New World accepts that whole line back, a bare number, or
**any words at all**, which are hashed. `midsummer` is a perfectly good seed and
always the same world.

### Fog of war — three states

| State | Looks like | Means |
| --- | --- | --- |
| **Unexplored** | black | nobody has ever walked here |
| **Explored** | faded | you have been here, nobody is here now — you remember the country but not what is happening on it |
| **Observed** | full colour | somebody is standing here right now |

The middle state is the interesting one. It is the difference between a map and
a view, and it is why explorers are a real job rather than a fog-clearing chore.

Reveal is a **BFS frontier queue** — an O(1) pop per tile revealed, in geodesic
order, so exploration spreads outward like walking rather than like a paint
bucket. `EXPLORE_PER_SCOUT = 0.85` tiles per explorer per day, before
multipliers.

### Territory

What the settlement can actually work, as distinct from what it has seen.

```
radius = 3.5 + 0.028 × population + tech bonuses + outposts,  capped at 18
```

Territory is a real constraint: a tile outside it contributes nothing however
rich it is. Nine technologies grant territory (`tracking` +2, `settlement` +2,
`writing` +3, `cartography` +3, `roads` +4, `the_keel` +4, and others), and
outposts add 1.2 each. When the settlement wants land it has not been shown,
`expansion_blocked_by_exploration()` returns true and the labour planner
promotes explorers above every other support trade.

---

## 6. The land

Fourteen biomes. Each carries a stock of game, forage, forest, fertility, stone,
ore and gold, and each has a 32×32 pixel-art tile.

| Biome | Game | Forage | Forest | Fertility | Stone | Ore | Gold | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Ocean | — | — | — | — | — | — | — | impassable, water source |
| Lake | 8 | 5 | — | — | — | — | — | water |
| River | 10 | 7 | — | — | — | 0.05 | 0.35 | water; placer gold |
| Coast | 5 | 10 | 2 | 0.25 | 0.1 | — | 0.05 | best foraging outside forest |
| **Plains** | **32** | 11 | 4 | **1.15** | 0.1 | 0.05 | — | the best all-round ground |
| Grassland | 24 | 16 | 7 | 1.0 | 0.1 | 0.05 | — | |
| **Forest** | 34 | 26 | **48** | 0.6 | 0.1 | 0.05 | — | timber and game together |
| Rainforest | 26 | 34 | **62** | 0.75 | 0.05 | 0.05 | 0.10 | most timber in the game |
| Hills | 16 | 9 | 16 | 0.4 | **1.15** | **1.05** | 0.20 | the mining ground |
| **Mountain** | 6 | 2 | 4 | — | **1.90** | **1.75** | 0.50 | **impassable until Mountain Paths** |
| Desert | 5 | 3 | 1 | 0.1 | 0.35 | 0.50 | 0.18 | |
| Tundra | 14 | 5 | 3 | 0.15 | 0.4 | 0.35 | 0.08 | |
| Ice | 2 | — | — | — | — | — | — | poles only |
| **Clearing** | 14 | 12 | 6 | 0.85 | 0.1 | 0.05 | — | **what a felled forest becomes** |

**Tiles change.** This is a core mechanic, not decoration. Fell a forest hard
enough and the tile becomes a **Clearing** — a different biome, with a different
tile sprite (stumps), different yields and better fertility than the wood it
replaced. Leave it and the forest grows back and the tile reverts. Every tile
therefore has both a `biome` (what it is now) and a `base_biome` (what it wants
to be), and the map the player is looking at is a record of what they have done
to it.

**Mountains** are impassable — explorers cannot cross them and quarriers cannot
work them — until **Mountain Paths**. On some world layouts that single
technology is what opens the second half of the map.

**Ore tiers.** What a seam yields depends on what the civilisation knows, not on
where it is:

| Tier | Unlocked by | Relative value |
| --- | --- | --- |
| Copper | Prospecting | 1.0 |
| Bronze | Bronze Working | 2.0 |
| Iron | Iron Working | 3.4 |
| Steel | Steelmaking | 6.0 |

The same mine on the same hill gives six times as much once you know how to make
steel. Progression changes the world rather than sending you to a new part of
it.

---

## 7. Animals

Distinct from the abstract `game` stock the hunters draw on — these are visible
individuals that live where they would actually live and wander between tiles.
They are the map's evidence that the ecology is real.

| Animal | Colour | Density | Needs game stock | Lives in |
| --- | --- | --- | --- | --- |
| **Deer** | brown | 1.00 | ≥ 25% | forest, rainforest, clearing, desert*, hills |
| **Wolves** | grey | 0.30 | ≥ 55% | forest, hills, tundra, mountain, clearing |
| **Rabbits** | pale buff | 1.15 | — | plains, grassland, clearing, desert, coast |
| **Birds** | white | 0.95 | — | coast, lake, river, plains, grassland, rainforest, forest, tundra |

The `needs_game` column is the mechanic: **wolves only appear on tiles where the
game stock is above 55%**, and deer above 25%. Over-hunt a valley and the deer
thin out and then the wolves leave, and you can see it happen. Let it recover
and they come back in that order. It is Lotka–Volterra told as sprites.

Animals move between adjacent valid tiles on a slow tick. **Reduced motion** in
Settings stops the wandering — it is also the lightest setting on a weak
machine, which is not a coincidence.

---

## 8. Resources

Eight. **None of them has a storage cap.**

| Resource | Spoilage / day | Notes |
| --- | --- | --- |
| **Food** | 3.0% | the binding constraint on population |
| **Water** | 2.0% | second half of Liebig's minimum |
| **Wood** | — | the universal building input |
| **Stone** | — | |
| **Hides** | 0.8% | by-product of hunting; early building input |
| **Ore** | — | displayed as Copper / Bronze / Iron / Steel |
| **Gold** | — | trade and the Treasury |
| **Knowledge** | — | buys techs and upgrades |

**Why nothing caps.** Storage ceilings and geometric costs cannot coexist. With
both, every world in testing froze at exactly the same population — 198 — because
the cheapest useful building cost more than the barn could hold. Caps are gone.
Perishables are bounded by **spoilage** instead, which is a rate rather than a
wall: it punishes hoarding without ever forbidding it, and it makes Drying
Racks, Granaries and the Fire Pit meaningful (each multiplies spoilage down).

"Enough" is therefore not "the barn is full" but **"hold a couple of the priciest
thing you could currently build with it"** (`_well_stocked`). That scales itself
as costs climb, and it is what lets the forest grow back — once there is more
timber than any use for it, the woodcutters stand down and the wood recovers.

---

## 9. People and trades

Everybody is a worker. There are eleven trades.

| Trade | Kind | Unlocked by | Bounded by |
| --- | --- | --- | --- |
| **Hunters** | game | — | wild game stock |
| **Foragers** | forage | — | wild forage stock |
| **Woodcutters** | forest | — | wild forest stock |
| **Water Carriers** | water | — | water tiles in territory |
| **Explorers** | explore | — | unexplored frontier |
| **Farmers** | farm | Agriculture | **farm plots built** |
| **Foresters** | timber | Agriculture | **woodlot slots built** |
| **Quarriers** | stone | Masonry | **quarry slots built** |
| **Miners** | ore | Prospecting | **mine slots built** |
| **Builders** | build | — | the build queue |
| **Elders** | knowledge | Shared Stories | 35% of the workforce |

The five wild trades are bounded by **ecology**. The four slot trades are
bounded by **construction**. That split is the spine of the whole progression:
each wild trade has a managed successor that removes its ceiling.

- hunting and foraging → **farming**
- felling wild forest → **forestry** (woodlots on rotation)

Wood having no managed successor was a real bug — 937 of 1,280 people once
worked a forest that could not give up another stick — and Foresters exist to
close exactly that gap, mirroring what Agriculture does for food.

### How a worker's yield is computed

For a wild trade, a **Holling type II functional response**:

```
per-worker yield = a·S / (1 + a·h·S)   ×  multipliers
```

where `S` is the stock available in territory, `a` the attack rate and `h` the
handling time. Diminishing, saturating, and — importantly — *low when the stock
is low*, which is what makes a hunted-out valley empty its own hunting camp
rather than keep it staffed out of habit.

For a slot trade, yield is per-slot and flat, times multipliers.

### The multiplier chain, and why it is shaped the way it is

```
yield = base
      × tech/building pool          (multiplicative, fixed set)
      × upgrade tier                (×1.75 per tier owned)
      × (1 + Σ situational bonuses) (ADDITIVE — see below)
      × season
      × decree penalty
```

The fourth term is the important one. Legacy, omens, momentum, decree boosts and
festivals used to *multiply* together. Catching four boons under a decree during
a festival in the right season produced a 40× swing, which is how seed variance
became the largest force in the game. They now **pool additively** inside one
`(1 + Σ)` bracket, floored at ×0.1. Four things worth +30% each give +120%, not
×2.86. Stacking still rewards play; it no longer detonates.

### The labour planner

When **Assign work automatically** is on, the planner re-runs on every material
change, in this order:

1. **Water** — sized to actual draw, pushed harder below one day of stock, eased
   off above four.
2. **Food** — target is `population × 1.25`, ×1.9 in autumn (lay in stores
   before the fields stop giving) and ×1.35 in winter. Farms are filled first
   because they are plot-limited; the wild trades split the remainder weighted by
   yield², and any food job yielding under a tenth of the best is dropped
   entirely.
3. **A 12% reserve** is held back from the food quest, capped at 40 people. A
   tribe that puts every last pair of hands on hunting can never build the thing
   that would end the hunger — that is how a subsistence trap closes, and it is
   precisely the trap an idle game must never leave the player sitting in.
4. **Explorers** — 10% of everybody when expansion is blocked by unexplored
   ground, otherwise a token 2% while the map is under 90% known.
5. **Builders** — half of what remains while anything is queued.
6. **Everyone else**, ranked by marginal value, sized by the *shortfall against
   target over ten days*, never more than 25% of the settlement in one trade.
7. **Spare hands go to slot trades anyway** even when stores are comfortable,
   because upgrades unlock on lifetime output — idle hands are the next doubling
   not happening.
8. **Whatever is left thinks**, capped at 35% of the workforce.

The planner explains itself in one sentence in the HUD. An automation you cannot
interrogate is one you cannot trust, and a player who does not trust it will not
leave it running — which is the whole game.

---

## 10. Population — the simulation underneath

Per substep:

```
food_satisfaction  = min(1, food_available / food_needed)      # 1.0 food/person/day
water_satisfaction = min(1, water_available / water_needed)
need   = min(food_satisfaction, water_satisfaction)            # Liebig's minimum
larder = clamp(food_stored / (population × 5), 0, 1)
crowd  = clamp((housing − population) / (housing × 0.35), 0, 1)

fertility = need × (0.35 + 0.65 × larder)
births    = 0.021 × population × fertility × crowd × birth_mult
deaths    = (0.010 + 0.028 × (1 − need)² + crowding) × population
```

The **larder** term is what makes the granary matter. A settlement eating
hand-to-mouth breeds at 35% of its potential even when nobody is technically
hungry. Filling the store is a real, visible, controllable lever on growth.

### The floor

```
population = max(peak_population × 0.75, population + (births − deaths) × dt)
```

The promise of the game, in one line. But `peak_population` **only rises while
the people are actually fed** (both satisfactions above 0.95). Without that
condition a summer spike set a permanent floor, winter could not correct it, and
the safety net ended up holding nine thousand people on land that supported
fourteen hundred — the net doing the work the ecology is supposed to do. A peak
has to be a level the settlement actually sustained.

### The three damping mechanisms

Population feeds knowledge feeds techs feeds production feeds population. Left
alone that loop goes to infinity, and it did — a test build reached 200,000
people and lifetime output in the 1e27s by day 900. Three things hold it:

**1. The sub-linear knowledge term.** This is the single most important number
in the game.

```
knowledge_rate = thinkers^0.58 × 0.22 × multipliers
```

If ten elders gave ten knowledge, that would be linear, and the loop would close
with a gain above one. At an exponent of **0.58**, ten elders give about four.
Doubling your thinkers gives 1.5× the knowledge, not 2×. That single number
converts the loop's runaway into a converging series. See §19 for the full
explanation.

**2. Cost growth, applied at three different rates.**

| What | Growth per unit | Why |
| --- | --- | --- |
| Housing | **1.04** | with steep growth, population is logarithmic in income — a settlement producing 9× as much housed 11% more people, and no amount of good management moved the number the player watches |
| Work slots | **1.045** | same argument one level down; at 1.15 the 76th farm plot cost a million timber and the late game stalled dead |
| Everything else | **1.15** | the idler curve proper, where a steep wall is the point |

Flat (1.0) is a step too far — with no cost pressure at all the loop runs away
again. The steep geometric curve belongs on **multipliers and upgrades**, not on
the things the player's population count is directly proportional to.

**3. Refugia.** Thirty per cent of every living stock is permanently unreachable,
so no stock ever hits zero and no trade ever becomes permanently worthless.

### Discrete population events

Everything that moves population by a *fraction* is a loss (sickness ×0.97,
a collapsed shaft ×0.97) — proportional losses are self-limiting. Everything
that *adds* people is **sub-linear**:

```
band = 2 + √population × 1.5,  capped at 35% of the settlement
```

A band walking out of the hills is fifty people whether it finds a village or a
city. This was a flat 12% and it was the second-largest bug in the balance: at
ten thousand people one event added twelve hundred mouths in a day, far past
what the land was feeding, and the never-lose floor then locked the number in.

---

## 11. The ecology

Each tile carries four living stocks — **game, forage, forest, water** — each
with a per-tile capacity set by its biome, each regrowing on a **Verhulst
logistic** curve:

```
dS/dt = r · S · (1 − S/K)
```

Harvest is the Holling type II response from §9, and the whole thing together is
**Rosenzweig–MacArthur** consumer–resource dynamics: the settlement is the
consumer, the tile is the resource, and the characteristic behaviour is
overshoot followed by recovery rather than a smooth approach.

Three deliberate departures from a faithful model, all in the same direction:

1. **Refugia** (30%). A faithful model permits local extinction. This one does
   not.
2. **Regrowth never stops.** `r` is constant; there is no depensation, no Allee
   effect, no collapse threshold.
3. **Drawdown is spread.** `drain()` takes proportionally from every tile in
   territory rather than emptying the nearest, so pressure shows up as the whole
   country thinning slightly rather than a ring of dead ground.

A faithful model was built first and it was bleak. This is the hopeful version
of the same mathematics, and the difference is three constants.

### Disasters

**Off by default.** Settings offers Rare / Normal / Harsh.

| Disaster | Needs | Effect |
| --- | --- | --- |
| Forest Fire | forest on the map | burns tree cover on a patch |
| Flood | water nearby | takes the low ground, hits stores |
| Hurricane | coast | two days of damage across a wide area |
| Tornado | open ground | a narrow track of destruction |

Disasters are **setbacks only**. The never-lose floor holds underneath all of
them. They cost time and momentum and they never cost the settlement.

---

## 12. Building

Twenty-one buildings. Cost scales as `base × growth^(count already built)` at
the rates in §10.

**Housing** — Windbreak (3), Hut (6), Longhouse (18), Stone House (30), Great
Hall (70), Tenement Block (260). Effective capacity is multiplied by a
**density** factor from Roads, Aqueducts, Printing, Sanitation and Public Health
— which is how population responds to *how well the place is run*, not only to
how much stone it has.

**Work slots** — Farm Plot (+1 farmer), Woodlot (+1 forester), Quarry (+2
quarriers), Mine (+2 miners), Workshop Row (+6 of each).

**Preservation** — Fire Pit (spoilage ×0.75), Drying Rack (×0.72), Granary
(×0.80). These stack, and against 3%/day food spoilage they are what makes a
winter store survive to spring.

**Multipliers** — Woodshed (build ×1.12), Scout Camp (explore ×1.25), Well
(water ×1.35), Smelter (five trades ×1.08–1.10), Shrine (knowledge ×1.18),
Treasury (knowledge ×1.25, territory +0.5), University (knowledge ×1.50).

The **auto-builder** keeps up to **four orders queued** at once and rolls surplus
work forward between them. A serial one-order-a-day queue capped the entire
economy regardless of how many builders existed — the build pipeline, not the
labour, was the bottleneck.

The Quarry costs **wood only**, deliberately: it originally cost stone and was
the only source of stone, which is an unbreakable deadlock on a stone-poor start.

---

## 13. Knowledge, techs and upgrades

Two ladders, paid for out of the same pool.

### Techs — 35 of them

A prerequisite DAG rooted at Fire Mastery, costing from **8** knowledge to
**950,000**. Techs grant yield multipliers, territory, birth multipliers, housing
density, spoilage reduction — and, critically, **unlocks**: Shared Stories opens
Elders, Agriculture opens Farmers and Farm Plots, Prospecting opens Miners,
Masonry opens Quarriers, Mountain Paths opens the high ground, Seafaring opens
the water, Coinage opens trade.

The spine runs: Fire Mastery → Knapped Tools → Shared Stories → Settling Down →
Pottery → **Agriculture** → Masonry → Writing → Iron Working → Steelmaking →
Mathematics → Printing → Mechanisation → The Steam Engine → Public Health.

### Upgrades — 132 of them

The other half of the idler engine, and the part that makes the numbers move.
Eleven trades × twelve named tiers. Each owned tier multiplies that trade's
output by **×1.75**, and they compound.

A tier unlocks on **lifetime output of that trade**, not on headcount — 200,
2,000, 20,000, and so on by 10× — and costs 60, 400, 2,500, 15,000, 90,000, …
knowledge. Gating on headcount was a dead end: the labour planner only hires
what is needed, so an upgrade that wanted 40 hunters simply never unlocked in a
world that never needed 40 hunters.

Every tier is named. *Fire-Hardened Spears* → *Drive Hunting* → *The Atlatl* →
*Composite Bows* → *Beaters and Nets* → *Hunting Dogs* → *Managed Herds* → *Game
Wardens* → *Beast Trails* → *The Hunting Reserve* → *Selective Culling* → *The
Wild Register*. Watching those names arrive is a large part of the pleasure and
they cost nothing to ship.

At tiers 3 and 7 the ladder **branches** and the player picks one of two.

---

## 14. Eras and progression

Era advances when **both** a population and a tech threshold are met, so neither
can be rushed alone.

| # | Era | Population | Techs |
| --- | --- | --- | --- |
| 0 | Nomadic Band | — | — |
| 1 | Semi-Settled Camp | 18 | 4 |
| 2 | Neolithic Village | 45 | 9 |
| 3 | Bronze Age Town | 110 | 15 |
| 4 | Iron Age City | 280 | 20 |
| 5 | Age of Steel | 900 | 23 |
| 6 | Classical City-State | 3,000 | 27 |
| 7 | Age of Sail | 12,000 | 31 |
| 8 | Industrial Dawn | 50,000 | 35 |

**Milestones** fire independently at 25, 100, 500, 2,000, 10,000, 50,000,
250,000 and 1,000,000 people — a line of prose each, no mechanical effect. *"Ten
thousand. Ten thousand, from six people and a river."*

---

## 15. Player agency — what the elders will never do

Pillar two, made concrete. Five systems, chosen because none of them has an
answer a planner could compute.

### Decrees

A standing order: a large bonus to one thing paid for with a real penalty to
another, held until changed. **60-day cooldown** between changes, so the choice
has weight.

| Decree | Gains | Costs |
| --- | --- | --- |
| **Go and See** | explore ×3.0, stone ×1.25, territory +2 | farm ×0.82, timber ×0.90 |
| **Dig and Build** | ore ×1.9, stone ×1.8, build ×1.5 | game ×0.85, forage ×0.85 |
| **Sit and Think** | knowledge ×2.6 | build ×0.75, ore ×0.85 |
| **Let It Rest** | farm ×1.35, forage ×1.3, regrowth ×2 | ore ×0.70, stone ×0.70 |
| **Mind the Children** | births ×1.9, housing density ×1.3 | every gathering trade ×0.90 |

Because seasons multiply the same terms, *when* you issue one matters as much as
which. Dig and Build in winter costs almost nothing; Let It Rest through spring
and summer is worth far more than through autumn.

### Council decisions

Every **150 days** a question arrives with a **25-day clock**. Ignore it and the
elders take the option marked `safe` — never a disaster, never the best.

Five exist: **A Hard Winter Is Coming** (take the herds now / ration / trust the
hunt), **Strangers at the Edge of the Fields** (take them in / trade and send
them on / send them on), **An Argument About the Seam** (drive deeper / shore it
up / leave it), **The River Has Moved** (dig a channel / move the fields / carry
the water), **Someone Who Wants to Teach** (endow her / let her get on with it).

The teacher is the one that matters most and looks smallest: endowing her costs
real food and timber now and compounds for ever.

### Festivals

Spend **35% of the granary** on a party. For 40 days: births ×2.2, knowledge
×1.6. **120-day cooldown.** Timing it against the harvest is the entire skill —
a festival on a full autumn store is transformative, the same festival in
February is a famine you chose.

### Boons

Roughly every **110 days**, something lands on the map for **13 days** and has to
be collected by hand. Seven kinds: **A Caravan**, **A Good Omen** (everything
×2.0 for 30 days), **A Migrating Herd**, **A Wandering Scholar**, **A Master
Mason**, **A Struck Seam**, **A Fair Season**.

Catching several inside a **45-day window** builds **momentum**: +30% per boon,
up to five, decaying over 60 days. This is the closest thing the game has to a
combo, and it is pure attention — a player who is watching gets it and a player
who is not, does not.

### Outposts

Founded by hand on ground your explorers have walked, at least **8 tiles** from
anything else, up to **12** of them. Each adds **1.2** territory radius around
itself. Cost starts at 220 wood / 140 stone / 300 food and grows **×1.55** each.

Where you put one is the whole decision, and it is a genuinely spatial one: an
outpost on a mountain range you have just learned to cross opens ore the
settlement could not otherwise reach.

### Settlements

A second place people actually live, as distinct from an outpost, which is a
place that sends things home. A settlement houses **140** people, widens the
reach, and works its own country properly — about **2.6×** what an outpost sends
back.

They are bought with **settlement points**, *earned by growing* rather than
purchased: the first at **400** people, then 1,500, 6,000, 25,000, 100,000. That
makes founding one a milestone rather than a transaction, and stops a rich
civilisation from blanketing the map. Settings carries an openly-labelled cheat
that grants a point.

The material price is a **share of the stores** — 55% of the timber, 40% of the
granary — not a fixed sum. A flat price cannot work: the auto-builder spends
materials as fast as they arrive, so stores hover around whatever the next
building costs rather than accumulating, and any absolute number is either
trivial late or permanently just out of reach. Same reasoning as the festival
costing a third of the granary rather than a number of loaves.

**Known limitation.** Territory is one circle centred on the first settlement,
so a new settlement widens that circle rather than claiming the ground where it
stands — found one sixteen tiles east and the land sixteen west is claimed too.
Proper multi-centre territory touches the whole territory and worker-spot path
and is not built. Settlements raise the radius *ceiling* in the meantime, which
is what makes them worth founding once the home circle is capped.

### Trade

Unlocked by **Coinage**. Export up to 30% of one resource's production at 72%
efficiency for another, with a 4% gold upkeep. The lever for converting a
resource you are drowning in into the one you are short of.

---

## 16. Legacy, profile and the meta-game

When a civilisation has done enough it can be **set down**. Everything standing
is lost — the buildings, the fields, the people, the map — and what survives is
what they worked out.

Legacy is banked in the **profile** (`user://profile.cfg`), not in the save file.
Starting a new world never costs anything earned by playing. It buys a flat
percentage on every trade, and it buys **perks**:

| Perk | Cost | Effect |
| --- | --- | --- |
| Remembered Fire | 3 | begin knowing Fire Mastery and Knapped Tools |
| A Full Granary | 4 | begin with food, timber and stone enough to build immediately |
| Old Maps | 5 | begin with a wide stretch of country already walked |
| Restless | 8 | decrees can be changed twice as often |
| Long Memory | 10 | knowledge accumulates 60% faster, for ever |
| Seed Stock | 12 | begin knowing Agriculture, with the first plots broken |
| Deep Roots | 15 | births +40%, shelter holds 25% more |
| Prospectors' Instinct | 20 | seams give half again as much, for ever |

### The Chronicle

The event log was always a history; it was simply thrown away. It is kept now,
grouped by era, readable as a document, with the **notable people** who turned up
in it.

### Achievements

Ten, and they are for **odd play** rather than for playing:

*Not One Hunter* (reach the Neolithic without a single day of hunting) · *Steel
on Scattered Rocks* (Age of Steel on an Archipelago) · *A Short Bright Life* (set
a civilisation down before day 400) · *The Whole Country* (map every reachable
tile) · *Four Worlds* · *Nothing Left to Learn* (buy every upgrade in one trade)
· *The Hungry Decade* (come through a hundred hungry days and grow again) · *Ten
Thousand* · *Left the Land Alone* (Bronze Age with herds and forest both above
80%) · *A Run of Luck* (hold five boons at once).

---

## 17. Interface, art and performance

### Layout

A single screen, no modes. Top bar (era, day, population, season, five speed
buttons, Chronicle / Legacy / Settings / New World) — laid out in a **flow
container** so it wraps rather than forcing the window wider than it is. Left
column: stores with per-day rates, and four sparkline histories. Centre: the
map, with a filter dropdown under it. Right: five tabs — **Work**, **Build**,
**Upgrades**, **Rule**, **Knowledge**. Bottom: the event log.

Every control is focus-navigable with a gamepad, which console certification
will require later and which costs nothing now.

### Map filters

The same picture asked five different questions:

| Filter | Shows |
| --- | --- |
| **Trades** | every person coloured by the work they do *(default)* |
| **Population** | everyone in one colour, so the crowd reads as a crowd |
| **The Land** | how worn the ground is — herds, plants and tree cover, green to bare |
| **What Is Here** | ore, gold, fertile ground and water; everything else dimmed |
| **Reach** | what is worked, what is walked, and what nobody has seen |

The legend answers whatever question the current filter is asking rather than
always listing trades.

### People

People are drawn as **five-pixel figures** — head, body, legs — scattered inside
their tile and coloured by trade, so a glance tells you what is happening
without reading a panel. Above a headcount the map cannot draw individually, one
figure stands for many: 1 → 5 → 25 → 100 → 500 → 2,500 → 10,000, with the legend
stating the current ratio.

### Rendering, and what it costs

The whole map is **one draw call**. The 96×64 grid is written into a packed
RGBA8 byte buffer, pushed through `Image.set_data` into an `ImageTexture`, and
drawn as a single scaled rect. The naive version was 6,144 `draw_rect` calls per
frame. The texture is only rebuilt when the fog or the tree cover actually
changes, not every frame.

Sprites — terrain tiles, animals, workers, buildings — only draw past a **zoom
threshold**. Zoomed out you are looking at the one-call texture and nothing
else; zoomed in you are looking at a few hundred sprites in a few hundred tiles.
The cost of detail is therefore bounded by the *screen*, not by the world.

The simulation is fixed-step, allocation-free in its hot loop, and caches its
per-tile aggregates (`terr_game`, `terr_forest`, …) rather than re-summing 6,144
tiles per substep.

### Drop-in artwork

Every drawn thing asks `Art` for a texture first and falls back to its
hand-drawn primitive if there is not one. Put a PNG in a folder with the right
name and it appears — nothing to register, nothing to import, no code to change.

```
assets/terrain/forest.png      one per biome
assets/buildings/hut.png       one per building
assets/animals/deer.png        one per animal
assets/workers/hunter.png      one per job
assets/resources/food.png      one per resource
assets/ui/boon_caravan.png     odds and ends
```

The names are the ids in `Balance.gd`, which is what the code already uses
everywhere, so there is exactly one thing to get right. Two roots are searched
and **`user://` wins**, so artwork can be swapped on a machine that already has
the game, with no editor and no re-export. Settings has a **Reload artwork**
button.

Anything without a file keeps its built-in drawn shape, so art can be replaced
one piece at a time and the game always runs.

**Shipped art.** Fourteen 32×32 pixel-art terrain tiles, one per biome, generated
by `tools/make_terrain_art.py` — checked in beside them so they can be
regenerated and argued with rather than only replaced. Each biome has a small
palette and a motif that means something: firs for forest against round canopies
for rainforest, stumps for a clearing, ridge lines lit from one consistent
direction for mountains and hills, wind crests for dunes. They wrap on both axes
so a field of grassland does not show a grid.

### Settings

Audio (master / music / sfx / mute). Display (fullscreen, vsync, interface
scale, frame rate, reduce motion, high contrast map). Game (disaster frequency,
CSV logging, autosave interval, confirm-before-abandoning, verbose log).
Controls reference. This world (seed + copy). Artwork (reload, count). Danger
(restore defaults, delete save).

---

## 18. Not built yet

Honestly, and in rough priority order:

- **Audio.** No music, no sound effects. The mixer exists and is wired to
  Settings; nothing plays through it.
- **Art beyond terrain.** Buildings, animals, workers and resource icons are
  still drawn primitives. The pipeline is proven end to end; the art is not made.
- **Tutorial.** The five opening beats are all there is.
- **Localisation.** All strings are inline English.
- **Console certification work.** See `docs/PLATFORMS.md`.
- **Export presets.** Note that non-imported `res://` assets need an explicit
  export filter to make it into a PCK.
- **Cloud saves, achievements backends, store integration.**

---

## 19. Known design problems

Written down rather than discovered later.

### Territory is a single circle

Settlements claim ground by widening one circle centred on the original
settlement, rather than claiming the land where they actually stand. See §15.

### The ore-tier dead zone

All four ore tiers are consumed by roughly **day 500**, because Steelmaking costs
1,100 knowledge while the very next tech on the ladder, Mathematics, costs
16,000. Steel — the top tier, notionally an Age-of-Steel achievement — arrives in
era 4. Then nothing new comes out of the ground for another 1,500 days. Either
Steelmaking should cost far more, or there should be tiers above Steel, or both.

### Seed variance

Much reduced by additive pooling, but a broken-up Archipelago start and a fat
Continents start still diverge by roughly 3× in population by day 2,000. Some of
this is legitimate — the shapes are meant to play differently — and some is an
exponential economy compounding a small early difference for two thousand days.

### Elders are 35% of everyone

The planner fills the thinker cap and it is a lot of people to have doing
nothing visible. Either the cap should be lower, or knowledge should have a
second source that is not headcount.

### Winter is still sharp

Farm output ×0.52 against a population that cannot fall (the floor) means
satisfaction dips every winter even in a healthy settlement. The granary now
absorbs most of it, but the dip is visible in the trace.

---

## 20. Balance reference

The constants that matter most, all from `Balance.gd`.

### Vital rates

| Constant | Value | Meaning |
| --- | --- | --- |
| `FOOD_PER_PERSON_PER_DAY` | 1.0 | the unit everything is measured against |
| `BIRTH_RATE_MAX` | 0.021 | 0.030 left the settlement hand-to-mouth |
| `DEATH_RATE_BASE` | 0.010 | always present |
| `DEATH_RATE_STARVATION` | 0.028 | gentle: hunger stops growth, it does not kill |
| `CROWDING_SOFTNESS` | 0.35 | how hard housing throttles births |
| `BASE_HOUSING` | 10.0 | tents the band carries |
| `MIN_POPULATION` | 4.0 | absolute floor |
| `PEAK_FLOOR_FRACTION` | 0.75 | **the promise the game makes** |
| `FAMINE_THRESHOLD` | 0.85 | below this the log mentions hunger |

### The damping constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `THINKER_EXPONENT` | **0.58** | the most important number in the file |
| `KNOWLEDGE_PER_THINKER` | 0.22 | |
| `HOUSING_COST_GROWTH` | 1.04 | not 1.0 (runaway), not 1.15 (logarithmic population) |
| `WORKSITE_COST_GROWTH` | 1.045 | same argument, one level down |
| `DEFAULT_COST_GROWTH` | 1.15 | where a steep wall belongs |
| `UPGRADE_MULT` | 1.75 | per owned tier, compounding |
| `STOCK_REFUGE` | 0.30 | nothing is ever wiped out |
| `MIGRANT_EXPONENT` | 0.5 | a band is a band |

### Ecology

| Constant | Value |
| --- | --- |
| `GAME_REGROWTH` | 0.100 / day |
| `EXPLORE_PER_SCOUT` | 0.85 tiles / day |
| `FOOD_SPOILAGE` | 3.0% / day |
| `BASE_TERRITORY_RADIUS` | 3.5 |
| `TERRITORY_PER_POP` | 0.028 |
| `MAX_TERRITORY_RADIUS` | 18.0 |

### Agency timing

| Constant | Value |
| --- | --- |
| `BOON_INTERVAL_DAYS` | 110 |
| `BOON_LIFETIME_DAYS` | 13 |
| `MOMENTUM_WINDOW_DAYS` | 45 |
| `MOMENTUM_PER_BOON` | +0.30, max 5 |
| `DECREE_SWITCH_COOLDOWN_DAYS` | 60 |
| `COUNCIL_INTERVAL_DAYS` | 150 |
| `COUNCIL_PATIENCE_DAYS` | 25 |
| `FESTIVAL_COOLDOWN_DAYS` | 120 |
| `FESTIVAL_FOOD_FRACTION` | 0.35 |
| `OUTPOST_MAX` | 12 |
| `OUTPOST_COST_GROWTH` | 1.55 |

### World

| Constant | Value |
| --- | --- |
| `WORLD_W` × `WORLD_H` | 96 × 64 = 6,144 tiles |
| `SECONDS_PER_DAY` | 30.0 |
| `STEPS_PER_DAY` | 10 (3 when fast-forwarding) |
| `MAX_OFFLINE_HOURS` | 12 |
| `SAVE_VERSION` | 7 |

---

## How this is verified

`tools/headless_sim.gd` plays the game on autopilot and prints the trajectory.
CI runs it on every push. It asserts:

- all four world shapes survive 2,000 days
- a save round-trips through 44 compared fields with zero mismatches
- legacy carries forward exactly what was offered, and the next run is not stalled
- a baseline seed lands inside a wide tolerance at day 500
- **managing beats leaving it alone on the same seed**

```
godot --headless --path . res://tools/HeadlessSim.tscn -- --days 2000 --seeds 4
```

Render a real frame — including at a zoom that shows the terrain art and the
individual figures, neither of which draws when zoomed out:

```
godot --path . --resolution 1280x720 res://tools/Screenshot.tscn -- \
    --days 900 --zoom 14 --filter 1 --out shot.png
```
