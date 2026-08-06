# Artwork

Drop a PNG in here and the game uses it. Nothing to register, nothing to wire
up, no code to change. Anything without a file keeps its built-in drawn shape,
so you can replace the art one piece at a time and the game always runs.

## Where things go

| Folder | One file per | Filenames are |
| --- | --- | --- |
| `terrain/` | biome | `plains` `grassland` `forest` `rainforest` `hills` `mountain` `desert` `tundra` `ice` `clearing` `ocean` `lake` `river` `coast` |
| `buildings/` | building | `firepit` `windbreak` `scout_camp` `drying_rack` `hut` `woodshed` `farm_plot` `woodlot` `well` `longhouse` `granary` `quarry` `mine` `smelter` `stone_house` `shrine` `treasury` `great_hall` `tenement` `workshop_row` `university` |
| `animals/` | animal | `deer` `wolf` `rabbit` `bird` |
| `workers/` | job | `hunter` `forager` `woodcutter` `water_carrier` `explorer` `farmer` `forester` `quarrier` `miner` `builder` `thinker` |
| `resources/` | resource | `food` `water` `wood` `stone` `hides` `ore` `gold` `knowledge` |
| `ui/` | odds and ends | `outpost`, `boon_caravan`, `boon_good_omen`, `boon_migrating_herd`, `boon_wandering_scholar`, `boon_master_mason`, `boon_seam_strike`, `boon_fair_season` |

The names are the ids used throughout `scripts/autoload/Balance.gd`, so if you
add a new building called `bathhouse` its artwork is `buildings/bathhouse.png`
and nothing else has to happen.

`.png`, `.svg`, `.webp` and `.jpg` all work.

## Size and shape

Nothing is fixed - every sprite is scaled to the tile size and drawn centred, so
aspect ratio is preserved and only the proportions matter.

- **Terrain** looks best square and seamless-ish; drawn tile-sized. 32x32 or
  64x64 is plenty.
- **Buildings, animals, workers** are drawn centred on a tile at roughly half to
  one tile high. Transparent background, and a shape that reads at ~16 px.
- **Resource icons** are drawn at text height in the stores list. 32x32.

## Two places to put them

- **`res://assets/...`** - this folder. Shipped with the game. Godot imports
  them when the project is next opened.
- **`user://assets/...`** - the same layout under the save directory. Read at
  runtime with no import step and no re-export, and it **overrides** anything
  shipped. This is the one to use for swapping art in a built copy of the game,
  or for iterating quickly without going through the editor.

  On Windows that is `%APPDATA%\Godot\app_userdata\Civamation\assets\`, on Linux
  `~/.local/share/godot/app_userdata/Civamation/assets/`, and on macOS
  `~/Library/Application Support/Godot/app_userdata/Civamation/assets/`.

**Settings has a "Reload artwork" button**, so you can drop files in and see
them without restarting.
