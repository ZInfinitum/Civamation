# Civamation — Next Steps

Everything worth building next, ordered by what it unblocks rather than by how
big it is. **Art and audio assets are deliberately excluded** — the drop-in
pipeline works and the art is a separate track.

Each item carries an honest **effort** (hours of focused work) and **impact**
(what the player actually notices).

Status key: 🔴 known broken · 🟠 known gap · 🟡 design decision needed · 🟢 pure addition

> **Revision 3.** Done and removed since revision 2: the food problem (§1.1 and
> §1.3 — it was never spoilage or the floor, it was that three quarters of the
> workforce had nowhere to stand), the hunger metric that was measuring
> midnight, frame-rate independence, and the `new_game` state leak that proving
> it uncovered. The audit went from five checks to twelve.
>
> Two items are **new and were found by tools**, not by playing: §5.7 and §1.6.

---

## 0. The short list

If only five things get done, these five:

1. **§6.1** — the tutorial exists but draws nothing
2. **§1.2** — the ore-tier dead zone (now the oldest problem here)
3. **§2.1** — towns cap at 140 people and cannot grow
4. **§5.1** — export presets do not exist; the art pipeline would ship empty
5. **§1.6** — output now reaches 1e18 by day 6,000; pacing needs a decision

---

## 1. Balance and pacing

### 1.2 🔴 The ore-tier dead zone
Unchanged from revision 1 and now the oldest known problem. All four ore tiers
are consumed by roughly **day 500**: Steelmaking costs 1,100 knowledge while the
next tech up the ladder, Mathematics, costs 16,000.

Discrete seams help — there is now news underground after day 500 — but the
*tiers* still run out. Raise Steelmaking to ~12,000, and/or add tiers above
Steel (Crucible, Alloy, something industrial).

**Effort** 3h · **Impact** high

### 1.4 🟡 The demographic clock is a visible fiction
Lives run at ⅕ human-year per game day while seasons run at 1/360. This works,
and it is commented where it lives, but it means a person visibly ages ~18 years
per in-game year. Nobody has seen it yet because nothing displays an age.

Decide before anything surfaces individual people: either accept it and never
show ages, or slow lives and lengthen runs.

**Effort** decision, then 0–6h · **Impact** low now, blocking later

### 1.5 🟠 Seed variance is unmeasured since everything changed
Revision 1 said ~3×. Every number under that has moved. The soak now reports the
spread properly — read it before tuning anything.

**Effort** 0 (the soak does it) · **Impact** medium

### 1.6 🟡 Output now reaches 1e18 by day 6,000
The worksite fix employed the three quarters of the workforce that had nowhere
to stand, and lifetime output went up by roughly a hundredfold as a result.
That is arithmetic, not a bug — but it is a real pacing shift, and "too much
power, too fast" has been a stated concern before.

The single dial is the worksite multiplier chain, which currently compounds to
about 27× across six technologies. Halving the exponents would still leave most
people employed. Wants a decision rather than a fix.

**Effort** 1h once decided · **Impact** high on feel

### 1.7 🟢 No difficulty / pace setting
A "Leisurely / Standard / Brisk" scaling `SECONDS_PER_DAY` and the cost-growth
constants.

**Effort** 2h · **Impact** medium

---

## 2. Systems that are half-built

### 2.1 🔴 Towns cap at 140 people
`SETTLEMENT_HOUSING` is a flat 140, so a town fills in a few hundred days and
then stops. Migration works, staffing works, and both become irrelevant almost
immediately.

A town needs its own buildings — or at minimum a housing figure that grows with
era and with the national housing multipliers. Until then a settlement is a
hamlet with a nice ring around it.

**Effort** 6h for scaling housing, 20h+ for real per-town construction ·
**Impact** very high — it is what makes the whole settlement layer matter

### 2.2 🟠 Towns have no age structure and cannot starve
Population is nationally aged and nationally fed. A town cannot have a bad year,
cannot be relieved by road, and cannot be the interesting thing it is set up to
be. This is the natural next chapter and it now has foundations.

**Effort** 12h · **Impact** high

### 2.3 🟠 Roads are inferred, not built
Unchanged. Roads appear automatically when claims overlap: no cost, no
construction, no decision. Making them a build order with a cost per tile turns
"where do I put the town" into "and can I afford to connect it".

**Effort** 4h · **Impact** medium-high

### 2.4 🟠 Temperature drives only snow
It is displayed and it melts snow. It does not touch spoilage (cold preserves),
water demand (heat raises it), winter fuel, or mortality at extremes.

Cheapest meaningful hookup: winter wood consumption for heating scaled by how
far below freezing it is. That makes timber a winter resource and gives the
readout a reason to exist.

**Effort** 3h · **Impact** medium-high

### 2.5 🟠 Ten signals have no listener
The audit found them: `ascended`, `boon_appeared`, `building_completed`,
`council_opened`, `council_closed`, `era_advanced`, `tech_researched`,
`upgrade_bought`, `saved`, `loaded`. Each is either a missing feature (a toast,
a sound, a chronicle entry) or dead code.

They are the natural hooks for audio and for a notification feed (§4.5), so
answer them together.

**Effort** 3h · **Impact** medium

### 2.6 🟡 Disasters remain shallow
Unchanged. Four disasters, all "scale a stock down", off by default.

**Effort** 6h · **Impact** medium

### 2.7 🟢 Rivers and coast do nothing mechanically
Unchanged, and now more glaring: settlements could be sited for river access,
roads could follow water, fishing could be a trade. Archipelago especially needs
this.

**Effort** 6h · **Impact** medium-high

---

## 3. The simulation's structural limits

### 3.1 🟠 Territory is still circles
Claims are radii, not shapes. Real territory would flood-fill from each
settlement with a per-tile cost (mountains expensive, rivers cheap along their
length) and stop at a budget. Now that claims are per-settlement, this is a
contained change.

**Effort** 6h · **Impact** medium

### 3.2 🟡 The job planner is a heuristic cascade
Unchanged. ~150 lines of ordered special cases that work and cannot explain
themselves. A marginal-value optimiser would be shorter and more principled, and
would risk finding degenerate optima the cascade avoids by accident.

**Effort** 8h · **Impact** low visible, high maintainability

### 3.3 🟠 The planner does not know about night or towns
It sizes the workforce from instantaneous yields, which now swing by 5× through
the day, and it assigns every worker as though they were at the capital. The EMA
smooths the first; nothing addresses the second.

**Effort** 5h · **Impact** medium-high

### 3.4 🟢 No demand/price model
Unchanged. Trade is a fixed-ratio swap.

**Effort** 5h · **Impact** medium

---

## 4. Interface

### 4.1 🔴 The top bar overflows at 1280×720
It wraps to two lines now: era, clock, population, season, weather, temperature,
five speed buttons and five more buttons. Needs grouping — a compact world-state
cluster with detail in a popover.

**Effort** 2h · **Impact** medium-high

### 4.2 🟠 Nothing on the map is clickable
Settlements now hold populations, work their ground, and connect by road, and
none of it is inspectable. Click a town → a panel: who lives there, what it
works, what it is joined to.

**Effort** 4h · **Impact** high

### 4.3 🟠 No graphs worth the name
Unchanged, and now worse served: there is an age structure, a temperature curve,
snow depth, herd health and per-town populations, and the interface shows four
unlabelled sparklines.

**Effort** 5h · **Impact** high — this is the genre's core pleasure

### 4.4 🟠 The age structure is invisible
No population pyramid, no dependency ratio, no mean age, no deaths-by-cause —
all of it computed, none of it shown. The soak reports more about the population
than the game does.

**Effort** 3h · **Impact** high

### 4.5 🟢 No notification feed
Unchanged. The offline digest does this well; extend the same treatment to the
live log. §2.5's orphan signals are the hooks.

**Effort** 3h · **Impact** medium-high

### 4.6 🟢 Map filters could go further
Now obvious additions: temperature, snow, the road network, per-town
populations, travel time from the capital.

**Effort** 3h · **Impact** medium

---

## 5. Technical

### 5.1 🔴 Export presets do not exist
Unchanged and still the most dangerous invisible problem. Non-imported `res://`
assets need an explicit export filter to reach a PCK, so **the drop-in art
pipeline would ship with no art in it**. Nothing has been exported yet, so this
is untested end to end.

**Effort** 3h · **Impact** critical before any build goes out

### 5.2 🟠 Save format has no migration path
Unchanged. `SAVE_VERSION` is 7 and every load is `d.get(key, default)`. That
works until a field changes *meaning*. This release added cohorts, tutorial
state, deposits and per-town populations — all additive, all fine, and the
pattern is one semantic change away from breaking.

**Effort** 3h · **Impact** zero now, critical at launch

### 5.3 🟠 No performance budget enforcement
Unchanged. Nothing measures frame time. A headless harness failing the build
above a budget at 40,000 population would keep pillar five honest.

**Effort** 4h · **Impact** medium

### 5.4 🟠 `Sim.gd` is now ~3,500 lines
Worse than revision 1. It gained age bands, migration, weather, snow, deposits,
roads and the tutorial. The seams are obvious: `SimEcology`, `SimPeople`,
`SimEconomy`, `SimAgency`, `SimPersistence`.

**Effort** 8h · **Impact** zero visible, large on velocity

### 5.7 🟠 Nothing checks that `new_game` resets what it should
The state leak in §rev3 was found by accident, by a test written for something
else. Eight caches survived a new game because nothing enumerated them. A check
comparing the member variables declared in `Sim` against the ones `new_game`
and `_reset_runtime_caches` touch would have caught it in seconds, and will
catch the next one — every new cache variable is a candidate.

This is the single highest-value check the audit does not yet have.

**Effort** 2h · **Impact** high

### 5.8 🟢 The audit could check more still
`tools/audit.py` exists and gates CI. Natural additions, each cheap: era
thresholds monotonically increasing; upgrade tiers strictly ascending in cost;
every `Balance` table referenced by at least one `_ORDER` list; save/load field
coverage (every `to_dict` key read by `from_dict`).

Save/load field coverage is done (both directions). What remains: every
`Balance` table referenced by at least one `_ORDER` list; building `max` caps
actually respected by the builder; and the reverse of `dead-constants` —
constants read with a fallback where no declaration exists.

**Effort** 3h · **Impact** medium

### 5.6 🟢 CI could assert exact numbers
Runs are deterministic now, so the harness could pin exact populations rather
than wide tolerances, and catch unintended balance drift. Needs a ratchet
convention (see the audit toolkit's §1.5) so it does not become a chore.

**Effort** 2h · **Impact** medium

---

## 6. Onboarding and retention

### 6.1 🔴 The tutorial draws nothing
Eight steps, trigger conditions, a state machine that runs and saves, and one
call site that is a deliberate no-op. All that remains is a panel anchored near
the named control with next/skip — both already implemented behind it.

**Effort** 4h · **Impact** very high

### 6.2 🟠 The offline digest appears once
Unchanged. It is the best screen in the game and is reachable exactly once per
session. It should be on demand, and it should be what the Chronicle looks like.

**Effort** 2h · **Impact** medium

### 6.3 🟠 Achievements are invisible until earned
Unchanged.

**Effort** 2h · **Impact** medium

### 6.4 🟢 No goals or contracts layer
Unchanged. A rotating "reach 5,000 people before day 900" would give the middle
hours a spine, and the achievement machinery already exists.

**Effort** 4h · **Impact** high for retention

---

## 7. Content

### 7.1 🟢 Only five council questions
Unchanged, and still the best value-per-hour on this list. Twenty would not feel
repetitive for a long time and each is pure data.

**Effort** 3h · **Impact** medium-high

### 7.2 🟢 Only five decrees and seven boons
Unchanged.

**Effort** 2h · **Impact** medium

### 7.3 🟢 The tech tree has one spine
Thirty-seven techs, very few real choices. Mutually exclusive branches would
make two runs differ.

**Effort** 5h · **Impact** high for replay

### 7.4 🟢 No wonders
Unchanged. An idler wants a few enormous named things that change a rule.

**Effort** 5h · **Impact** high

### 7.5 🟢 No lighting line past the fire pit
Night work is gated on `NIGHT_FLOOR`, which a Fire Pit raises from 0.18 to 0.30
and nothing else touches. Lamps, gas, electric light — a whole progression line
with an obvious mechanical meaning, already plumbed.

**Effort** 3h · **Impact** high — it makes the day/night cycle a system rather
than a constraint

### 7.6 🟢 Legacy perks stop at eight
Unchanged.

**Effort** 2h · **Impact** medium

---

## 8. Suggested order

**Now (makes it correct):** 1.1 → 1.2 → 2.1 → 4.1

**Next (makes it a game):** 6.1 → 4.2 + 4.4 → 7.5 → 7.1

**Then (makes it deep):** 2.2 → 2.3 → 2.4 → 7.3

**Before any public build:** 5.1 → 5.2 → 5.5 → 5.3

**Whenever velocity hurts:** 5.4

---

*Companion documents: [`DESIGN.md`](DESIGN.md) for how the simulation works,
[`GDD.md`](GDD.md) for what everything is, [`BACKLOG.md`](BACKLOG.md) for the
older list, [`PLATFORMS.md`](PLATFORMS.md) for shipping. `tools/audit.py` gates
several of the claims above.*
