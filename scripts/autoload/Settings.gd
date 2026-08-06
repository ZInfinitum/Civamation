extends Node
## Player settings, persisted to `user://settings.cfg`.
##
## Kept separate from the save file on purpose: settings should survive starting
## a new world, and a corrupt save should never cost somebody their audio and
## accessibility choices.

signal changed

const PATH := "user://settings.cfg"
const CSV_PATH := "user://civamation_log.csv"

# --- Audio ---
var master_volume := 0.8
var music_volume := 0.7
var sfx_volume := 0.8
var muted := false

# --- Display ---
var fullscreen := false
var vsync := true
var ui_scale := 1.0
var show_fps := false
## Skips the wandering-animal updates and slows map redraws. Also the right
## switch for anyone who finds constant small movement distracting.
var reduce_motion := false
## Thicker outlines and brighter marks on the map, for low-contrast displays.
var high_contrast := false

# --- Game ---
## Off by default. The default game is a calm one you leave running; disasters
## are for players who want the world to push back.
## 0 off, 1 rare, 2 normal, 3 harsh - index into Balance.DISASTER_FREQUENCY.
var disaster_frequency := 0
## Writes one CSV row per in-game day to CSV_PATH. For balance work.
var csv_logging := false
var autosave_seconds := 20.0
var confirm_new_world := true
## Show the running commentary of everything the settlement does. Verbose, and
## exactly what you want when play-testing a balance change.
var verbose_log := false


func _ready() -> void:
	load_settings()
	apply_display()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	master_volume = float(cfg.get_value("audio", "master", master_volume))
	music_volume = float(cfg.get_value("audio", "music", music_volume))
	sfx_volume = float(cfg.get_value("audio", "sfx", sfx_volume))
	muted = bool(cfg.get_value("audio", "muted", muted))

	fullscreen = bool(cfg.get_value("display", "fullscreen", fullscreen))
	vsync = bool(cfg.get_value("display", "vsync", vsync))
	ui_scale = float(cfg.get_value("display", "ui_scale", ui_scale))
	show_fps = bool(cfg.get_value("display", "show_fps", show_fps))
	reduce_motion = bool(cfg.get_value("display", "reduce_motion", reduce_motion))
	high_contrast = bool(cfg.get_value("display", "high_contrast", high_contrast))

	disaster_frequency = int(cfg.get_value("game", "disaster_frequency", disaster_frequency))
	csv_logging = bool(cfg.get_value("game", "csv_logging", csv_logging))
	autosave_seconds = float(cfg.get_value("game", "autosave_seconds", autosave_seconds))
	confirm_new_world = bool(cfg.get_value("game", "confirm_new_world", confirm_new_world))
	verbose_log = bool(cfg.get_value("game", "verbose_log", verbose_log))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("audio", "muted", muted)

	cfg.set_value("display", "fullscreen", fullscreen)
	cfg.set_value("display", "vsync", vsync)
	cfg.set_value("display", "ui_scale", ui_scale)
	cfg.set_value("display", "show_fps", show_fps)
	cfg.set_value("display", "reduce_motion", reduce_motion)
	cfg.set_value("display", "high_contrast", high_contrast)

	cfg.set_value("game", "disaster_frequency", disaster_frequency)
	cfg.set_value("game", "csv_logging", csv_logging)
	cfg.set_value("game", "autosave_seconds", autosave_seconds)
	cfg.set_value("game", "confirm_new_world", confirm_new_world)
	cfg.set_value("game", "verbose_log", verbose_log)
	cfg.save(PATH)
	changed.emit()


## Push display and audio settings at the engine. Safe to call on any platform:
## the window calls are no-ops on web and console.
func apply_display() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS):
		# Web and most console targets own the window; do not fight them.
		_apply_audio()
		return
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen \
			else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
	DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	_apply_audio()


func _apply_audio() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, muted or master_volume <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(clampf(master_volume, 0.0001, 1.0)))


func reset_to_defaults() -> void:
	master_volume = 0.8
	music_volume = 0.7
	sfx_volume = 0.8
	muted = false
	fullscreen = false
	vsync = true
	ui_scale = 1.0
	show_fps = false
	reduce_motion = false
	high_contrast = false
	disaster_frequency = 0
	csv_logging = false
	autosave_seconds = 20.0
	confirm_new_world = true
	verbose_log = false
	apply_display()
	save_settings()
