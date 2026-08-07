# Civamation

An idle civilization builder. Six people stop walking somewhere with water and
good grass, and over the next few hours they become a city.

You do not click a cookie. You watch a small population work a randomly
generated landscape — hunting, foraging, cutting timber, carrying water — and
you nudge them: where the hands go, what gets built, what gets figured out
next. Left completely alone it assigns its own labour, builds its own
buildings and pursues its own research — it plays itself competently and keeps
growing, which is the point. It is something to have running on the side. Every
one of those three autopilots has an off switch when you want the decisions.

The whole design is written up in [docs/GDD.md](docs/GDD.md) — every system,
mechanic, tile, animal, trade and number in one document.

Underneath it is a real ecology model (see [docs/DESIGN.md](docs/DESIGN.md)),
but a **hopeful** one. The herds always come back, the forest always grows
back, and the settlement never falls below three quarters of the largest it has
ever been. Hard stretches cost you time, never your civilization.

On top of that sits an idler economy in the Cookie Clicker mould: costs grow
geometrically, output grows with what you own, and upgrades periodically double
a whole trade outright. Nothing caps. The numbers keep going up.

## The world

Pick a shape when you start one: **Earth** (continents, real climate bands,
polar ice), **Continents** (fewer, larger landmasses), **Islands**, or
**Archipelago** (where you will want Seafaring badly). Plains, grassland,
forest, rainforest, hills, mountains, desert and tundra are laid out by
elevation, latitude and rainfall; mountains are impassable until you learn to
cross them.

Every world comes from a seed, and the pause menu hands it back as one copyable
line — `482913 / Archipelago`. New World takes that whole line, or a bare
number, or any words at all, which are hashed: `midsummer` is a perfectly good
seed and always the same world.

Tiles change. Fell a wood and it becomes a clearing until it grows back. Deer,
wolves, rabbits and birds live where they would actually live and wander between
tiles. Fog of war has three states: black where nobody has ever walked, faded
where you have been but nobody is now — you remember the country but not what is
happening on it — and full colour where somebody is standing right now.

## Running it

Requires [Godot 4.4](https://godotengine.org/download) or newer. No addons, no
asset imports, no build step — the entire game is GDScript and primitive
drawing, so it runs the moment you clone it.

```bash
godot --path .              # play
godot --path . --editor     # open in the editor
```

Headless simulation harness — plays the game on autopilot and prints the
trajectory. This is how the balance actually gets tuned, and it is what CI runs:

```bash
godot --headless --path . res://tools/HeadlessSim.tscn -- --days 2000 --seeds 3
```

```
day    pop    K     food   wood   ore    gold   herd  plants forest  techs era  metal    jobs
9      7      7     21     5      0      0      97    100    99      0     0    -        hu3 fo1 wa1 bu1
249    123    124   740    491    2      0      86    99     91      8     2    Copper   hu30 fo7 wo22 wa20 mi22
750    1468   1468  6802   1430   1540   1393   30    63     100     18    4    Iron     hu95 fo185 fa80
```

Render a real frame to a PNG (needs a display, or `xvfb-run`):

```bash
godot --path . --resolution 1280x720 res://tools/Screenshot.tscn -- --days 300 --out shot.png
```

## The year turns

Four seasons multiply what every trade brings in. Spring is for foraging,
summer for the fields, autumn for the harvest and the hunt at once, and winter
for whatever is in the store. It is one extra term in the multiplier chain and
it gives the whole game a rhythm — and it makes *when* you issue a decree a real
question.

## Running it yourself vs leaving it running

The elders manage the settlement sensibly and will never do any of the
following, because none of it has an answer a planner could compute:

- **Decrees** — a large bonus to one thing paid for with a real penalty to
  another, held until you change your mind.
- **Council decisions** — a question with a clock. Ignore it and the elders take
  the safe option, which is never a disaster and never the best.
- **Festivals** — spend a third of the granary on a party.
- **Boons** — rare, brief, visible on the map. Catch several in a row and they
  compound.
- **Outposts** — founded by hand on ground your explorers walked. Where you put
  one is the whole decision.

The gap is measured, not asserted: `_test_engagement` in the harness runs the
same seed twice, once left alone and once managed, and fails the build if
managing does not win. It currently comes out at roughly **1.6x population and
100x+ lifetime output**.

## Artwork

Every sprite in the game is a drop-in replacement. Put `hut.png` in
`assets/buildings/`, `deer.png` in `assets/animals/`, and they appear — nothing
to register and no code to change. Anything without a file keeps its built-in
drawn shape, so the art can be replaced one piece at a time and the game always
runs. `user://assets/` overrides the shipped folder at runtime, and Settings has
a **Reload artwork** button. See [assets/README.md](assets/README.md).

## Legacy

When a civilisation has done enough, you can set it down. Everything standing
is lost — the buildings, the fields, the people, the map — and what survives is
what they worked out.

Legacy is banked in your **profile**, not the save file, so it survives starting
a new world. It buys a flat percentage on every trade, and it buys **perks** —
permanent unlocks that every civilisation after this one is born knowing. Begin
with fire already carried, with the country already walked, with the first plots
already broken.

The **Chronicle** keeps what happened: the era it happened in, and the people
worth remembering. **Achievements** are for odd play rather than for playing —
reaching the Neolithic without a single hunter, or the Age of Steel on an
archipelago.

## Controls

Everything is reachable with a gamepad — the UI is focus-navigable throughout,
which console certification will require later and which costs nothing now.

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Pause / resume | `Space` | Select / View |
| Faster | `]` | Right shoulder |
| Slower | `[` | Left shoulder |
| Zoom / pan the map | wheel, drag | — |

Time runs day by day. Thirty seconds a day to start, then fifteen, then one,
and a top speed of a second a month once the civilisation is old enough to have
earned it. The map has a filter dropdown under it — everyone coloured by trade,
everyone in one colour so the crowd reads as a crowd, how worn the land is, what
is worth having on it, and how far the reach goes.

Settings covers audio, fullscreen, vsync, interface scale, reduced motion, high
contrast, autosave interval, a verbose log for play-testing, and natural
disasters (fires, floods, hurricanes, tornados) which are **off by default** and
have Rare / Normal / Harsh settings. There is also a CSV recorder - one row per
in-game day - for balance work.

The game autosaves every 20 seconds and on focus loss, and credits up to 12
hours of offline progress when you come back.

## Layout

```
project.godot            autoloads, renderer, input map
scenes/Main.tscn         entry point (one node; the UI is built in code)
scripts/
  Main.gd                boot: load save or roll a world, then show the HUD
  autoload/
    Balance.gd           every tuning number and data table in the game
    Sim.gd               the simulation - ecology, population, jobs, tech
    SaveSystem.gd        JSON persistence, autosave, offline credit
    Settings.gd          player settings, separate from the save file
  sim/CivWorld.gd        world generation and the living stocks on the map
  ui/HUD.gd              the whole interface
  ui/WorldView.gd        the map, drawn with primitives
tools/headless_sim.gd    autopilot harness + save round-trip test
tools/screenshot.gd      render a real frame to a PNG
docs/GDD.md              the full design document - every system, in one place
docs/NEXT_STEPS.md       everything worth building next, ranked
docs/DESIGN.md           how the simulation works and why
docs/PLATFORMS.md        what shipping to Steam, Xbox, console and web takes
docs/NEXT.md             how much detail this can afford, and what to build next
docs/BACKLOG.md          everything worth building, with effort and impact
```

Two files matter most. **`Balance.gd`** holds every number and every data table
— resources, jobs, buildings, techs, biomes, ore tiers — so the whole game can
be retuned without touching simulation code. **`Sim.gd`** holds the mechanism
and reads its numbers from there.

## Status

This is a first playable build. It runs, it is balanced, it saves, and CI
verifies all of that on every push. What it does not have yet — audio, art,
settings, tutorial, and the console work — is written up honestly in
[docs/PLATFORMS.md](docs/PLATFORMS.md).
