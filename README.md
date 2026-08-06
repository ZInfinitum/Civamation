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

Underneath it is a real ecology model (see [docs/DESIGN.md](docs/DESIGN.md)),
but a **hopeful** one. The herds always come back, the forest always grows
back, and the settlement never falls below three quarters of the largest it has
ever been. Hard stretches cost you time, never your civilization.

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

## Controls

Everything is reachable with a gamepad — the UI is focus-navigable throughout,
which console certification will require later and which costs nothing now.

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Pause / resume | `Space` | Select / View |
| Faster | `]` | Right shoulder |
| Slower | `[` | Left shoulder |

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
  sim/CivWorld.gd        world generation and the living stocks on the map
  ui/HUD.gd              the whole interface
  ui/WorldView.gd        the map, drawn with primitives
tools/headless_sim.gd    autopilot harness + save round-trip test
tools/screenshot.gd      render a real frame to a PNG
docs/DESIGN.md           how the simulation works and why
docs/PLATFORMS.md        what shipping to Steam, Xbox, console and web takes
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
