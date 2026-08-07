# Civamation — Next Steps

Everything worth building next, ordered by what it unblocks rather than by how
big it is. **Art and audio assets are deliberately excluded** — the drop-in
pipeline works and the art is a separate track.

Each item carries an honest **effort** (hours of focused work) and **impact**
(what the player actually notices).

Status key: 🔴 known broken · 🟠 known gap · 🟡 design decision needed · 🟢 pure addition

---

## 0. The short list

If only five things get done, these five:

1. **§1.1** — the ore-tier dead zone (1,500 days with nothing new out of the ground)
2. **§2.1** — night is a rendering effect only; nothing sleeps
3. **§3.1** — settlements have no population of their own
4. **§1.3** — elders are 35% of everyone and it looks absurd
5. **§6.1** — there is no tutorial beyond five log lines

---

## 1. Balance and pacing — things that are wrong now

### 1.1 🔴 The ore-tier dead zone
All four ore tiers are consumed by roughly **day 500**. Steelmaking costs 1,100
knowledge; the next tech up the ladder, Mathematics, costs 16,000. Steel — the
top tier, notionally an Age-of-Steel achievement — lands in era 4, and then
**nothing new comes out of the ground for 1,500 days**.

Three fixes, not exclusive:
- Raise Steelmaking to ~12,000 so it sits where its name implies.
- Add tiers above Steel: Crucible Steel, Alloy, and something industrial.
- Make ore *quality* per-seam rather than global, so prospecting keeps mattering.

**Effort** 3h · **Impact** high — this is the clearest dead patch in the curve.

### 1.2 🟠 Winter is now genuinely sharp
The regrowth work made seasons act on the stocks, which is right, but winter
forage regrowth at ×0.20 on top of yield ×0.64 is a hard bite. Traces show food
hitting zero in winter at 6,000+ population. The never-lose floor catches it, so
nothing is *lost* — but "and hungry" in the summary line every winter is not the
hopeful read the game is aiming for.

Fix: raise the winter floor on forage regrowth, or make Granaries/Drying Racks
scale their effect with era so preservation keeps pace with population.

**Effort** 2h · **Impact** medium-high — it is the most visible recurring dip.

### 1.3 🟠 Elders are 35% of the workforce
The planner fills the thinker cap because knowledge is never "full". A third of
the civilisation sitting and thinking looks wrong and reads as a bug.

Options: lower the cap to ~20%; give knowledge a second source that is not
headcount (buildings, trade, a Library that produces flat output); or make
elders consume something so there is a real trade-off.

**Effort** 2h · **Impact** medium — mostly a credibility problem.

### 1.4 🟡 Seed variance is still ~3×
Archipelago and Continents diverge by roughly 3× population by day 2,000. Some
of that is legitimate (the shapes *should* play differently) and some is an
exponential economy compounding a small early difference for two thousand days.

Now that the harness is deterministic this is finally measurable properly: run
20 seeds, plot the spread, decide how much is intended.

**Effort** 3h (mostly measurement) · **Impact** medium

### 1.5 🟢 An actual difficulty / pace setting
Everything is tuned to one curve. A "Leisurely / Standard / Brisk" setting
scaling `SECONDS_PER_DAY` and the cost-growth constants would cost almost
nothing and widen the audience a lot.

**Effort** 2h · **Impact** medium

---

## 2. Systems that are half-built

### 2.1 🔴 Night is a rendering effect only
The map darkens and the fires light, but **nothing in the simulation knows it is
night**. Everyone works at 3am exactly as hard as at noon.

This is the single biggest gap between what the game now *looks* like and what
it *is*. Minimum viable version:
- Outdoor trades (hunt, forage, explore, build, farm) scale with `sun_elevation()`.
- Indoor/abstract trades (thinking, quarrying under torchlight) do not.
- Fire Pit, and later lighting tech, recover some of the night penalty — which
  is what makes the campfires mean something rather than being decoration.
- Long winter nights then genuinely hurt at 47°N, which is the entire point of
  having picked a latitude.

Watch out: this multiplies the day/night cycle into every yield, so the balance
pass afterwards is not small. Consider applying it to a *daily average* rather
than instantaneously, so fast-forward does not alias.

**Effort** 5h + balance pass · **Impact** very high

### 2.2 🟠 Settlements have no population of their own
A settlement houses 140 people and produces from its ground, but the population
is a single global number and every worker is notionally at the capital. So a
settlement is really a production building with a map position.

Proper version: each settlement has its own population, its own housing, its own
labour split; roads move people between them; a settlement can starve
independently and be relieved by road. That is a substantial re-architecture of
`Sim` (population becomes a per-place array) and it changes the whole HUD.

**Effort** 20h+ · **Impact** very high, and it is the natural next chapter of the game

### 2.3 🟠 Roads are inferred, not built
Roads appear automatically when claims overlap. There is no cost, no
construction time, and no decision. Making them a build order — with a cost per
tile of distance — turns "where do I put the town" into "and can I afford to
connect it".

**Effort** 4h · **Impact** medium-high

### 2.4 🟠 Temperature does almost nothing
It is displayed, and it drives snow melt. It does not affect food spoilage
(cold should preserve), water demand (hot should raise it), heating fuel
consumption in winter, or mortality at extremes.

The cheapest meaningful hookup: winter wood consumption for heating, scaled by
how far below freezing it is. That makes timber a winter resource and gives the
temperature readout a reason to be on screen.

**Effort** 3h · **Impact** medium-high

### 2.5 🟡 Disasters are off by default and shallow
Four disasters exist, all "scale a stock down". No visible track on the map, no
rebuilding, no warning. They are a settings toggle rather than a system.

**Effort** 6h · **Impact** medium — but they are opt-in, so low priority

### 2.6 🟢 Rivers and coast do nothing mechanically
Water tiles set `water_access` and that is all. Fishing as a trade, river
transport as a road that already exists, coastal settlements getting cheaper
roads — all natural and none built.

**Effort** 6h · **Impact** medium-high — Archipelago especially needs this

---

## 3. The simulation's structural limits

### 3.1 🟠 Population is one number
Everything above about settlements traces back here. `population` is a float.
There are no individuals, no age structure, no families. Notables are cosmetic
strings.

An age structure (children / workers / elders) would make the birth rate
mean something, make Deep Roots and festivals legible, and give a real reason
that a young population grows and an old one does not. It is also the
foundation for §2.2.

**Effort** 12h · **Impact** high, mostly on depth rather than on the first hour

### 3.2 🟠 Territory is still a set of circles
Better than one circle, but a claim is a radius, not a shape. Real territory
would flood-fill from each settlement with a cost per tile (mountains
expensive, rivers cheap along their length) and stop at a budget.

**Effort** 6h · **Impact** medium — mostly makes the map read better

### 3.3 🟡 The job planner is a heuristic cascade
`_auto_assign_jobs` is ~150 lines of ordered special cases. It works, and every
line of it is a bug that was found and fixed. But it cannot explain a trade-off,
and adding a trade means finding the right place in the cascade.

A marginal-value optimiser (compute d(utility)/d(worker) for every trade, assign
greedily) would be shorter, more principled, and would automatically handle new
trades. Risk: it will find degenerate optima the cascade avoided by accident.

**Effort** 8h · **Impact** low visible, high maintainability

### 3.4 🟢 No demand/price model
Trade is a fixed-ratio swap. A price that moves with what you are dumping on
the market would make the Coinage branch far more interesting.

**Effort** 5h · **Impact** medium

---

## 4. Interface

### 4.1 🟠 The top bar is overflowing again
Era, day+clock, population, season, weather, temperature, five speed buttons and
five more buttons. It wraps to two lines at 1280×720 now. It needs grouping —
probably a compact "world state" cluster (season / weather / temp / clock) with
the detail in a tooltip or a popover.

**Effort** 2h · **Impact** medium

### 4.2 🟠 There is no way to see a settlement
Click a settlement on the map and nothing happens. It should open a panel: what
it holds, what it produces, what it is connected to, how far its claim reaches.

**Effort** 4h · **Impact** high once §2.2 lands, medium before

### 4.3 🟠 No graphs worth the name
Four sparklines with no axes, no scale, no hover. For a game whose whole appeal
is watching numbers go up, the historical view is thin. Wants: a real chart
panel, selectable series, log scale toggle.

**Effort** 5h · **Impact** high — this is the genre's core pleasure

### 4.4 🟢 Map filters could go much further
Five filters exist. Obvious additions: temperature, snow depth, road network,
travel time from the capital, what each tile contributes.

**Effort** 3h · **Impact** medium

### 4.5 🟢 No notification/event feed worth reading
The log is chronological and undifferentiated. A player returning after an hour
wants "here is what mattered", not 400 lines. The offline digest does this well —
extend the same treatment to the live log.

**Effort** 3h · **Impact** medium-high for an idler

### 4.6 🟡 Nothing is clickable on the map
Tiles, animals, buildings, people — none respond. At minimum a hover readout of
what a tile is and holds.

**Effort** 4h · **Impact** medium-high

---

## 5. Technical

### 5.1 🟠 `Sim.gd` is over 3,000 lines
It holds ecology, population, jobs, building, tech, upgrades, decrees, council,
festivals, boons, outposts, settlements, roads, weather, trade, saves and the
offline digest. Every one of those is coherent on its own.

Splitting along the obvious seams (`SimEconomy`, `SimEcology`, `SimAgency`,
`SimPersistence`) would make the next ten features much cheaper.

**Effort** 8h · **Impact** zero visible, large on velocity

### 5.2 🟠 Save format has no migration path
`SAVE_VERSION` is 7 and every load is `d.get(key, default)`. That has worked so
far and will keep working until a field changes *meaning* rather than being
added. A real migration chain should exist before release.

**Effort** 3h · **Impact** zero now, critical at launch

### 5.3 🟠 No performance budget enforcement
The renderer is careful, but nothing measures it. A headless frame-time harness
that fails the build if a frame exceeds a budget at 40,000 population would keep
pillar five honest.

**Effort** 4h · **Impact** medium

### 5.4 🟢 The hex shader runs per-fragment at every zoom
Correct and cheap, but at MIN_ZOOM the whole world is a few hundred pixels and
the per-fragment hex maths is still running. Negligible now; worth knowing.

**Effort** 1h · **Impact** negligible

### 5.5 🟠 Export presets do not exist
Non-imported `res://` assets need an explicit export filter to make it into a
PCK. The drop-in art pipeline **will silently ship with no art** unless this is
set up. Nothing has been exported yet, so this is untested end to end.

**Effort** 3h · **Impact** critical before any build goes out

### 5.6 🟢 CI runs one command
`--days 2000 --seeds 4`. Now that runs are deterministic, CI could assert exact
numbers rather than wide tolerances, and catch a balance change nobody intended.

**Effort** 2h · **Impact** medium

---

## 6. Onboarding and retention

### 6.1 🔴 There is no tutorial
Five opening beats, all advisory, all in the log. A new player faces eleven
panels and no explanation of any of them.

Minimum: a first-run overlay that points at one thing at a time and waits.

**Effort** 6h · **Impact** very high — this is the difference between a build
and a game people play

### 6.2 🟠 The offline digest is the best screen in the game and appears once
It is genuinely good. It should also be reachable on demand, and it should be
what the Chronicle looks like.

**Effort** 2h · **Impact** medium

### 6.3 🟠 Achievements are invisible until earned
Ten exist, all listed in Legacy, none hinted at during play. For an idler,
visible medium-term goals are a large part of what keeps a session going.

**Effort** 2h · **Impact** medium

### 6.4 🟢 No goals or contracts layer
A rotating "reach 5,000 people before day 900" with a reward would give the
middle hours a spine. Cheap to build on the existing achievement machinery.

**Effort** 4h · **Impact** high for retention

---

## 7. Content

### 7.1 🟢 Only five council questions
They repeat quickly. Twenty would not feel repetitive for a long time, and each
is pure data.

**Effort** 3h · **Impact** medium-high — best value-per-hour on this list

### 7.2 🟢 Only five decrees and seven boons
Same argument. All data, no code.

**Effort** 2h · **Impact** medium

### 7.3 🟢 The tech tree has one spine
Thirty-seven techs but very few real choices — most are prerequisites of one
path. Branching techs (mutually exclusive pairs) would make two runs differ.

**Effort** 5h · **Impact** high for replay

### 7.4 🟢 No wonders
An idler wants a few enormous, named, expensive things that change a rule.
Obvious slot, nothing in it.

**Effort** 5h · **Impact** high

### 7.5 🟢 Legacy perks stop at eight
And the last one costs 20. A run banks 1–14. There is no long-term perk ladder.

**Effort** 2h · **Impact** medium

---

## 8. Suggested order

**Now (makes the game correct):** 1.1 → 2.1 → 1.2 → 4.1

**Next (makes it a game):** 6.1 → 4.3 → 7.1 → 6.4

**Then (makes it deep):** 2.2 + 3.1 together → 2.3 → 4.2

**Before any public build:** 5.5 → 5.2 → 5.3

**Whenever velocity hurts:** 5.1

---

*Companion documents: [`DESIGN.md`](DESIGN.md) for how the simulation works,
[`GDD.md`](GDD.md) for what everything is, [`BACKLOG.md`](BACKLOG.md) for the
older list this supersedes, [`PLATFORMS.md`](PLATFORMS.md) for shipping.*
