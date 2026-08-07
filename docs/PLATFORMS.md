# What it takes to ship this

Written down honestly, because the four targets you named are not four
equivalent amounts of work. One is easy, one is medium, one is a business
negotiation, and one is the reason most Godot games never reach console.

Verify anything with a price or a program name attached before budgeting
against it — these change.

## The game itself, before any platform

The build in this repo is playable and balanced. To be a *good* first build it
still wants:

**Audio.** Idle games live or die on ambience. A loop that changes with the era,
and small confirmations on build/tech/era. Godot's `AudioStreamPlayer` and an
audio bus layout; budget a day plus sourcing.

**Art.** Everything is drawn with primitives right now, which is honest
programmer art that reads clearly and costs nothing. A tileset for the map and
sprites for the buildings would transform how the game looks with no
simulation changes — `WorldView.gd` is the only file that would move.

**A settings screen.** Volume, UI scale, language, and a reset. UI scale is not
optional if you want this on a TV.

**First-run guidance.** The systems are legible but not self-explaining. Three
or four contextual prompts ("your hunters are running out of game — try more
foragers") beats a tutorial for a game like this.

**Number formatting for the long game.** `Balance.fmt()` handles up to
millions. If you extend the era ladder past Iron Age, it needs scientific or
suffixed notation.

**More content past the Iron Age.** The simulation happily runs forever, but the
tech tree ends at 37 techs and an autopilot run reaches the industrial era
in a few thousand days. More eras, buildings and
techs are pure data edits in `Balance.gd` — no simulation work.

**Localization.** Cheap now, expensive later. All player-facing strings are
currently literals in `Balance.gd` and the UI files. Moving them to a
`.csv`/`.translation` set is an afternoon today and a week after content grows.
Console certification generally expects at least the platform's regional
languages.

## Web

The easiest target and the fastest way to get people playing. The project is
already configured for it: the **GL Compatibility** renderer is set in
`project.godot`, and a Web preset is in `export_presets.cfg`.

The one real decision is **threads**. Godot's threaded web export needs
`SharedArrayBuffer`, which needs cross-origin isolation (`COOP: same-origin`,
`COEP: require-corp`) — headers many hosts will not serve. The preset therefore
ships with `variant/thread_support=false`. The simulation is a few thousand
float operations per tick; it does not need threads. Single-threaded runs
essentially anywhere, itch.io included.

Also worth knowing: `user://` maps to IndexedDB on web, so saves survive a
closed tab but not a cleared browser store. If you want saves to follow players
between devices, that is a server, and it is worth deciding early.

## Steam

Straightforward and self-serve. Roughly:

1. Steamworks account, $100 per-app fee, tax/bank paperwork.
2. Integrate the Steamworks SDK. Godot has no built-in support; the standard
   route is **GodotSteam**, which for Godot 4 is available as a GDExtension you
   can drop in without recompiling the engine.
3. Steam Cloud for saves — trivial here because everything is one JSON file
   under `user://`, and genuinely valuable for an idle game people leave running
   on more than one machine.
4. Achievements. This game has natural ones already: first fire, first harvest,
   first iron, population milestones, era advances. `Sim.gd` emits
   `tech_researched`, `building_completed` and `era_advanced` signals, so
   wiring them up is a listener, not a refactor.
5. Store page, capsule art, trailer, build upload via `steamcmd`, and a review
   pass that takes days not hours.

Budget the *store presence* as the real work. The integration is small.

## Xbox, Game Pass, and console generally

This is the hard one, and it is worth being blunt about it.

**Godot has no official console support.** Not Xbox, not PlayStation, not
Switch. This is not an oversight — console SDKs are under NDA and cannot ship
in an open-source repository. Godot 3 had a UWP export that could reach Xbox
through the retail-console dev mode path; it was **removed in Godot 4**, and
that route no longer exists. There is no DIY option.

What actually exists:

- **Third-party porting SDKs and services.** W4 Games (founded by Godot's
  creators) sells console SDKs for Godot; Lone Wolf Technology and Pineapple
  Works are among the studios doing Godot console ports as a service. All are
  commercial, all require you to already be an authorised console developer.
- **Authorisation first.** For Xbox that means **ID@Xbox** — free to join but
  approval-gated, and it is what gets you SDK access and dev kits. Similar
  programs exist for PlayStation and Nintendo.
- **Game Pass is a separate business deal.** It is not a distribution checkbox
  you tick after porting. Microsoft curates it and negotiates each title
  individually, usually against a shipped or demonstrably promising game. The
  realistic order is: ship on Steam, build an audience and a track record, then
  pitch Game Pass — not port to Xbox first and hope.

**What to do now, while it is free:** build as if certification is coming,
because retrofitting these hurts.

- *Full gamepad navigation.* Every control reachable and operable on a
  controller, no mouse-only affordances. The UI here is focus-navigable
  Godot `Control` nodes throughout, which is most of the way there.
- *Suspend and resume.* Console players suspend constantly. `SaveSystem` already
  saves on `NOTIFICATION_APPLICATION_PAUSED` and `WM_WINDOW_FOCUS_OUT`.
- *TV-safe UI.* Title-safe margins, minimum font sizes, readable at 10 feet.
  The current layout is a dense desktop one and would need a pass.
- *No hardcoded paths outside `user://`.* Already true.
- *Deterministic, resumable simulation.* Already true — fixed substeps, and
  offline catch-up runs the same code as live play.

**A realistic order:** Web first (fastest feedback), Steam second (revenue and
audience), console last and only with a porting partner.

## What CI does and does not cover

`.github/workflows/ci.yml` compiles the project and runs the autopilot harness
on every push, asserting the balance and save-integrity promises in
[DESIGN.md](DESIGN.md).

It does **not** produce builds. Exporting needs Godot's export templates and,
for macOS and Windows, signing identities — worth adding when there is
something to distribute, and worth keeping the signing credentials in Actions
secrets rather than the repo when you do.
