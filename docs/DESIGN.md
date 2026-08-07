# How Civamation works

## The population model you were reaching for

The theory is **logistic growth with a carrying capacity** — the Verhulst
equation:

```
dN/dt = r·N·(1 − N/K)
```

A population grows fastest in the middle, slows as it approaches what the land
can support (`K`), and shrinks when it overshoots. That is the "grows then
shrinks based on resource quantities" idea in its simplest form.

But plain logistic growth assumes `K` is a fixed property of the environment.
The interesting version — the one that actually produces booms and busts — lets
the resource be a living thing that is itself being eaten. That is
**consumer–resource dynamics**: Lotka–Volterra in its original form, and the
**Rosenzweig–MacArthur model** in the refined form this game uses. Three parts:

**1. The prey grows logistically on its own.** Every tile's wild game, wild
plants and forest regrow toward that tile's capacity:

```gdscript
d = rate · n · (1 − n/cap) + immigration · (1 − n/cap)
```

**2. The predator harvests through a Holling type II functional response.**
This is the crucial piece. One hunter's daily yield is not proportional to how
much game exists — it saturates, because past a point the limit is how long it
takes to kill and butcher an animal, not how long it takes to find one:

```gdscript
yield_per_hunter = a·G / (1 + a·h·G)
```

`a` is the attack rate (how effectively a hunter finds game) and `h` is the
handling time. As `G → ∞` the yield tends to `1/h`, a hard ceiling. As `G → 0`
it falls away linearly. So abundance has diminishing returns and scarcity bites
hard, which is exactly the shape that makes hunting feel different from farming.

**3. The consumer's own growth depends on what it caught.** Births scale with
how well fed and watered everyone is; deaths rise as that falls. `K` is
therefore not a constant — it is an *output* of how much the workforce is
currently able to bring in, which is why the game shows you "Land supports: N"
as a live number next to your population.

One more real principle is in there: **Liebig's law of the minimum**. Growth is
set by the scarcest necessity, not the average of them. Plenty of food and no
water is a water problem, and the sim takes `min(food, water)` rather than
blending the two.

## Why it is hopeful anyway

A faithful Rosenzweig–MacArthur system is bleak. Run one on autopilot and it
finds the overexploitation equilibrium: the consumer eats exactly the resource's
regrowth forever, everything sits pinned near zero, and nothing ever improves.
The first tuning pass of this game did exactly that — two of three test worlds
flatlined at a third of their peak population for two thousand days, unable to
spare a single pair of hands to build their way out. That is an accurate model
and a miserable game.

So four things bound the model from below. Each one is a real phenomenon, not a
fudge:

**Refugia.** 30% of every stock lives where the work parties do not go — deep
thickets, high ground, the far bank. `CivWorld.drain()` cannot touch it. Nothing
can be wiped out, and there is always a seed to regrow from. This is a real
mechanism in fisheries and conservation biology, and it is why the herd readout
bottoms out at 30% instead of zero.

**Hunger throttles births far more than it takes lives.** Deprivation cuts the
birth rate to nothing long before mortality becomes significant
(`DEATH_RATE_STARVATION` is 0.028 against a 0.030 max birth rate). A bad
stretch stalls you; it does not depopulate you.

**A labour reserve.** The auto-assigner holds ~12% of the workforce back from
food gathering even when food is short. A tribe that puts every last pair of
hands on hunting can never build the thing that would end the hunger — that is
precisely how a subsistence trap closes, and the reserve is what keeps it open.
It costs a slightly smaller population and buys permanent forward motion.

**A high-water floor.** The population never falls below 75% of the largest it
has ever been. This is the flat promise the game makes: you can lose momentum,
never your civilization.

**The planner uses realised yields, not theoretical ones.** Worth calling out
because it was the subtlest bug in the build. Sizing the hunting party from the
*potential* yield of a Holling curve over-hires massively once the refuge floor
is clamping the actual harvest — you get 130 hunters splitting what 30 could
take. `Sim` tracks a smoothed per-worker figure of what each job is *actually*
delivering and plans on that instead, which makes the workforce drift off
hunting and onto farming by itself as the herds thin, with nobody telling it to.

## The arc

Wild food is the early game and it is genuinely good — Holling saturation means
a pristine herd feeds a small band easily. As the band grows, per-hunter yield
falls, and growth slows. **Agriculture** is the escape: farm yield does not
depend on a wild stock at all, so it breaks the coupling that was limiting you.
**Prospecting** then opens a second uncoupled resource, and mineral seams do not
deplete at all — the industrial floor the late game is built on.

The ore itself upgrades with the civilization rather than the map: the same
tiles yield **copper**, then **bronze**, then **iron** as the techs land. The
rock never changed; the people learned to recognise what was in it. Gold comes
up alongside, and the Treasury turns it into knowledge — wealth buying teachers
and travellers.

## Playing itself

An idle game is mostly unobserved, so three systems run without the player:

**Labour** (`_auto_assign_jobs`) covers water first, then sizes the food
workforce from what each job is actually delivering, then holds ~12% back and
spends it on timber, stone, ore and elders — skipping anything whose store is
already full, which is what lets the forest grow back.

**Building** (`_auto_build`) raises the best shelter the age can manage when the
settlement is filling up, but only while the land can still feed the people
already in it. Housing that outruns food just parks everyone at subsistence on
the never-lose floor, which looks like growth and is not. Then fields, then
storage for whatever is actually overflowing, then production and multipliers.

**Research** takes the cheapest available tech unless told otherwise.

All three are on by default and each has a toggle. Without them the game stalls
at about eight people — which is exactly what the first screenshot of this build
showed, because the balance harness had its own private build logic and the
shipped game had none. The harness now drives the real `auto_build`, so what CI
verifies is what players get.

## The idler layer

The ecology gives the game its shape; the economy gives it its pulse, and that
half is Cookie Clicker's.

**Costs are geometric, output is linear.** The nth of anything costs
`base x 1.15^n` while producing the same as the first. So the next building is
always a little further away, and the curve flattens - which is the setup, not
the problem.

**Upgrades are the punchline.** Every trade has a ladder of upgrades that each
*double* its output outright. Buildings creep, upgrades jump, and a jump resets
a flattening curve. That loop is what makes the numbers keep climbing.

**Nothing has a storage cap**, and this is load-bearing. A ceiling cannot
coexist with geometric costs: prices grow exponentially in what you own while
any cap grows at best linearly, so every run eventually meets a price it can
never save up for and quietly stops. An early build did exactly that - every
world froze at 198 people because a hut cost more wood than the barns could
hold. Perishables are bounded by spoilage instead, which self-scales: stock
settles where production equals decay.

**Upgrades unlock on lifetime output, not headcount.** Gating on "150 people
must work this trade" sounds natural and is a second dead end: the labour
planner only hires what is needed, so those tiers never unlock and the surplus
population stands idle for ever. Total-ever-produced only ever climbs, so there
is always a next upgrade - which is what keeps spare hands worth putting on
Knowledge indefinitely.

**Every wild resource needs a managed successor.** Hunting saturates, so
farming exists. Wild timber saturates, so woodlots exist. Stone and ore never
deplete. Any resource without an unbounded source becomes the wall the whole
economy stops at - wood was exactly that until woodlots were added.

## Why managing beats leaving it alone

An early build had a real problem: the autopilot was good enough that touching
it gained you nothing. Every decision in the game was *locally optimisable* -
"how many woodcutters" has one right answer and the planner computes it
perfectly - so a player could only match it.

The fix is not a worse autopilot. It is decisions an optimiser should not be
making on your behalf, of three kinds:

**Commitments.** A decree is a large bonus to one thing paid for with a real
penalty to another, held until you change it, with a cooldown. There is no
correct decree - only one that matches what you think the next hundred days
need. The elders will not gamble the settlement on a guess.

**Gambles with a mediocre default.** A council question has a clock and a
`safe` option the elders take if nobody answers. Safe is deliberately never a
disaster and never the best. That gap *is* the value of paying attention.

**Moments.** Boons are brief and visible, and catching several in a row
compounds. A festival spends a third of the granary on a party - no optimiser
does that; every civilisation does.

**And one judgement about place rather than quantity:** where to found an
outpost. The planner can rank trades in a single currency, but it cannot tell
you that a particular hillside is worth holding.

Two things had to change for this to show up in the numbers at all:

- **The build pipeline was serial**, one order a day, which meant a five-fold
  economy could not spend itself. Orders queue several deep now and surplus
  builder-effort rolls onto the next one.
- **Population is logarithmic in resources under any geometric cost.** That is
  arithmetic, not tuning: if the nth building costs `g^n`, the count you can
  afford grows with `log(income)`. A settlement producing nine times as much
  housed eleven per cent more people, so the number the player actually watches
  barely moved. Shelter now climbs at 1.04 rather than 1.15, which hands the
  limit back to food - exactly what the ecology model was always supposed to
  decide. Flat was a step too far and the whole economy ran away.

The claim is tested rather than asserted. `_test_engagement` runs one seed
twice, identical but for the levers above, and fails the build if managing does
not win by a clear margin.

## The damping that keeps it a game

An exponential economy with a population feedback loop wants to run away, and
this one did — twice, in ways worth recording because they will be
reintroduced by anyone who does not know.

**Elders have diminishing returns to headcount.** `k = n^0.58`, not `n`. Linear
elders closed a loop — more people, more elders, more knowledge, more upgrades,
more food, more people — that took a run from three hundred to eighteen thousand
people in two hundred and fifty days and exhausted the entire tech tree in
seventeen minutes of play. This single exponent is the most important number in
the file.

**Ten upgrade tiers at 1.75x, not twelve at 2x.** 4,096x per trade, unlocking on
output that the multipliers themselves produce, is doubly exponential. 269x is
a strong ladder that paces a run rather than being climbed in an afternoon.

**Thinkers are capped at a third of the workforce.** Forty-six thousand elders
out of forty-six thousand people is not a settlement, and the knowledge they
produced fed straight back into the multipliers.

The general shape: *any* system where output feeds a multiplier that feeds
output needs one sub-linear term somewhere, and it is worth putting it where it
is thematically true rather than where it is convenient.

## Structure

`Sim.gd` advances in fixed 0.1-day substeps regardless of frame rate, so the
simulation is deterministic and speed-independent. Each step, in order:

```
territory → assign work → ecology → produce → consume & grow
          → build → research → storage & spoilage → events → era
```

Offline progress runs the same substeps rather than approximating, so twelve
hours away produces the same civilization as twelve hours watched.

`Balance.gd` holds every number and data table. `Sim.gd` holds mechanism only.
Adding a resource, job, building, tech, biome or ore tier is a data edit.

## Verifying the design

`tools/headless_sim.gd` plays the game on autopilot across several generated
worlds and asserts the design promises hold, so they cannot quietly regress:

- every civilization grows past subsistence and reaches at least six techs
- no run loses more than 26% of its peak population
- no living stock is ever stripped below its refuge floor
- no resource goes negative, NaN or infinite
- the save file round-trips all 35 tracked state fields exactly

Every claim in this document is a test in CI. Three seeds over 2000 days
currently reach tens of thousands of people and 37 techs, with drawdown well
inside the never-lose floor and herds living above the refuge rather than on it.
