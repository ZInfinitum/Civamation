# Backlog

Everything worth building, with an honest guess at what each costs and what it
buys. Effort is in developer-days for someone who knows the codebase. Impact is
judged against the game this is trying to be: something you leave running, that
rewards you for looking, and that you want to see grow.

Ordered within each section by value per unit of effort. Anything marked
**[perf]** has a cost note, because the one rule this codebase holds is that
cost may scale with the *map*, never with the *population*.

---

## 1. Content — the cheapest wins

Pure data edits in `Balance.gd`. No simulation work, no risk, and the tech tree
is currently the thing that runs out first.

| | Effort | Impact |
| --- | --- | --- |
| **More eras past Industrial Dawn** — Steam, Electricity, and a final one. Nine eras currently end at day ~1,500 on a good run. | 1d | High |
| **More buildings per era.** The Bronze and Iron tiers have four each; Neolithic has nine. The later game visibly thins out. | 1d | High |
| **A fifth and sixth ore tier** — steel is the last. Titanium, or something invented. The tier system already handles it. | 0.5d | Medium |
| **More council questions.** Five is enough to notice the repeat by the second run. Twenty would not. | 1d | High |
| **More boon types**, and boons that are era-specific — a returning fleet, a foreign delegation. | 0.5d | Medium |
| **Region-specific flavour.** A tundra start and a rainforest start currently read identically in the log. | 1d | Medium |
| **More decrees**, including era-gated ones. Five is thin for a system that is meant to be the main choice. | 0.5d | High |
| **Building upgrade paths** — a Hut that becomes a Longhouse for a discount rather than being replaced. | 1d | Medium |

---

## 2. Mechanics worth adding

### Near-term, high confidence

**Specialists.** A fraction of the population that can only take skilled work —
miners, elders, builders — growing with Knowledge rather than food. Makes the
learning branch matter to labour and not only to the tech tree, and gives the
late game a second constraint once food has long since stopped binding.
*2d. High impact.*

**Outposts that become towns.** An outpost is a flat production trickle. Letting
one grow its own small territory, population and buildings — a miniature of the
main loop — is the natural next system, and the map, the fog and the ecology
already carry everything it needs. **[perf]** Keep the cost per-outpost, never
per-person: a dozen outposts each doing 1/20th of the main sim is fine, and
`MAX_TERRITORY_RADIUS` should be smaller for them.
*5d. High impact, highest risk in this document.*

**Rival settlements.** Not war — competition for the same ground. Another
civilisation's territory expanding toward yours, claiming tiles you wanted, and
either trading or not. It gives exploration urgency and makes *where* you expand
a decision rather than a formality. **[perf]** One extra territory set and a
handful of aggregate numbers; no second full simulation.
*4d. High impact.*

**Weather and multi-year climate.** Seasons are in; a slow climate cycle on top
(a decade of good years, a decade of hard ones) would make storage and the
`Let It Rest` decree matter far more than they do.
*1d. Medium-high.*

**Disease as an opt-in pressure.** Sanitation, aqueducts and public health
already exist as techs and currently only give flat bonuses. A plague system
would make them mean something.
*2d. Medium, and only with the disaster toggle.*

**Migration in and out.** People arriving because your settlement is good, and
leaving when it is not. Gives the population number a second input the player
can influence and a reason to care about food *surplus* rather than sufficiency.
*1.5d. Medium-high.*

### Speculative but interesting

- **Named regions.** Name a valley when you first work it; it appears in the
  chronicle for ever. Nearly free, disproportionate attachment.
- **Roads as real tiles** the player places between the settlement and outposts,
  raising the territory radius along their length. **[perf]** Pure data.
- **A river-mouth port** unlocking ocean tiles for food, making coastal starts
  meaningfully different.
- **Wonders** — enormously expensive singular buildings with a unique permanent
  effect and a place in the chronicle. The natural sink for a late-game economy
  that currently has nothing to buy.
- **Cultural drift** — small permanent modifiers earned from how you played
  (never hunted, always explored) that carry into Legacy.

---

## 3. Interface

| | Effort | Impact |
| --- | --- | --- |
| **Marked spans on the population sparkline** — "the hungry decade" shown as a shaded region. A curve with scars is a story. | 0.5d | High |
| **A proper tech tree view.** The Knowledge tab is a flat list; the prerequisites are invisible, so the shape of the tree is unknowable. | 2d | High |
| **Tooltips on the map.** Hovering a tile should say what it is, what lives there and what it yields. The data is all there. | 0.5d | High |
| **Job cards showing marginal value** — the planner computes it; the player cannot see it. | 0.5d | Medium-high |
| **A build-queue reorder**, and pinning a building so the autopilot always keeps one queued. | 1d | Medium |
| **Compare-to-last-run overlay** on the sparklines after an ascension. | 1d | Medium |
| **Number format options** — suffixes vs scientific vs full digits. Idle players have strong opinions. | 0.25d | Medium |
| **A collapsible left column.** Four panels of statistics is a lot on a small window. | 0.5d | Medium |
| **Keyboard shortcuts** for the tabs and the speed control. | 0.25d | Medium |
| **An "explain this number" mode** — click any figure and get the full multiplier chain that produced it. | 1.5d | Medium, and enormous for balance work |

---

## 4. Presentation

**Artwork.** The drop-in pipeline is built and documented (`assets/README.md`);
what is missing is the art. Terrain first — it is 90% of what the eye sees —
then buildings, then workers, then animals. Every one is optional and
independent.
*Art time, no engineering.*

**Audio.** Idle games live on ambience. One loop per era, and small
confirmations on build, tech and era. Godot's `AudioStreamPlayer` and a bus
layout; the settings screen already has the volume sliders wired.
*1d plus sourcing.*

**Era transitions as moments.** Advancing an era is currently a log line. A
brief full-width card — the era's name, what changed, one line of flavour —
would give the run its punctuation.
*0.5d. High impact for the cost.*

**A settlement that visibly changes shape.** Buildings scatter at random around
the hearth. Placing them on real tiles, with roads between, would transform how
the map reads. **[perf]** Free — an array of (tile, type).
*2d. High.*

**Day/night and weather tinting** on the terrain texture. One extra multiply in
the buffer rebuild.
*0.5d. Medium.*

**A shareable card at ascension** — world shape, seed, final population, era,
Legacy earned, and the population curve, rendered to a PNG.
*1d. Medium.*

---

## 5. Systems and polish

- **Cloud saves** (Steam Cloud is trivial — one JSON file under `user://`).
- **Multiple save slots**, and a run history.
- **A proper main menu** — currently the game boots straight into a world.
- **Localisation.** All strings are literals in `Balance.gd` and the UI files.
  An afternoon now, a week after content grows.
- **Controller-native UI pass.** Focus navigation works; focus *order* has never
  been checked, and console certification will care.
- **Difficulty settings** beyond the disaster toggle — a "harsh" mode that
  lowers the never-lose floor for players who want the ecology to bite.
- **An in-game glossary** for the ecology terms the design actually uses.
- **Accessibility**: colourblind-safe terrain palette option, text size, and a
  screen-reader pass on the summary line.

---

## 6. Technical

- **Threaded world generation** — it approaches a second on the larger world
  sizes and currently blocks. **[perf]**
- **A bigger world**, 192×128. Free: the simulation cost is bounded by the
  territory radius, not the map. **[perf]**
- **A larger worked territory** (radius 36). Roughly 4× the hot loop, leaving
  ~6× headroom. The most impactful single perf spend. **[perf]**
- **Save compression.** The save is JSON with three float arrays; it will get
  large with a bigger map.
- **Deterministic replay** — record the seed and the player's inputs, replay a
  whole run. Would make balance regressions reproducible rather than statistical.
- **A second CI job** that runs 20 seeds nightly and posts the distribution,
  because the economy is exponential and single-seed variance is enormous.

---

## 7. Known rough edges

Honest list of things that are wrong or unfinished right now.

- **Population drawdowns reach exactly 25%** on some seeds — the never-lose
  floor is doing real work rather than being a backstop. Winter plus a badly
  timed event can still bite hard. Either the autopilot needs to stockpile
  harder or the floor should be raised to 82%.
- **Seed variance is enormous.** Two runs of the same length can differ by three
  orders of magnitude in lifetime output, because the economy is exponential and
  compounds early differences. Legacy's cube-root curve absorbs most of it, but
  the balance harness needs multi-seed distributions rather than single runs.
- **The tab bar overflows** at five tabs on a narrow window and falls back to
  arrows.
- **Late-game job assignment is spiky** — headcounts swing between passes
  because several caps interact. It settles, but it looks unstable.
- **Trade is only a single agreement** and cannot be tuned in size.
- **No audio at all**, and no art.
- **The chronicle is not written to disk separately**, so it is capped at 200
  entries and old history is lost on a long run.
- **Achievements cannot be inspected before they are earned** beyond the list —
  no progress indicators.

---

## If you only did five things

1. **Artwork for the terrain.** It is 90% of what the eye sees and the pipeline
   is already built.
2. **Era transitions as moments**, plus marked spans on the sparkline. Half a
   day each, and they turn a growing number into a story.
3. **A proper tech tree view.** The shape of the progression is currently
   invisible.
4. **More content per era** — buildings, decrees, council questions. Cheap, and
   it is what the late game is short of.
5. **Rival settlements.** The single addition that would most change what the
   game *is*, and the map is already carrying the data for it.
