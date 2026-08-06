extends Node
## Save, load and offline progress.
##
## Everything goes through `user://`, which maps to the right place on every
## target: AppData on Windows, the sandboxed container on console, and
## IndexedDB on web. Keep it that way - platform certification will care.

signal saved
signal loaded(had_save: bool)

const SAVE_PATH := "user://civamation.save"
const AUTOSAVE_SECONDS := 20.0

var _autosave_timer := 0.0
var _dirty := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().set_auto_accept_quit(false)


func _process(delta: float) -> void:
	_autosave_timer += delta
	if _autosave_timer >= maxf(5.0, Settings.autosave_seconds):
		_autosave_timer = 0.0
		save_game()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			save_game()
			get_tree().quit()
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			save_game()


func save_game() -> void:
	if Sim.world == null:
		return
	var payload := Sim.to_dict()
	payload["saved_at"] = Time.get_unix_time_from_system()
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Could not open save file for writing: %s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	saved.emit()


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func load_game() -> bool:
	if not has_save():
		loaded.emit(false)
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		loaded.emit(false)
		return false
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("Save file is corrupt; starting a new game.")
		loaded.emit(false)
		return false

	var data: Dictionary = parsed
	if int(data.get("version", 0)) != Balance.SAVE_VERSION:
		push_warning("Save is from a different version; starting a new game.")
		loaded.emit(false)
		return false

	Sim.from_dict(data)

	var saved_at := float(data.get("saved_at", 0.0))
	if saved_at > 0.0:
		var elapsed := Time.get_unix_time_from_system() - saved_at
		if elapsed > 0.0:
			Sim.run_offline(elapsed / Balance.SECONDS_PER_DAY)

	loaded.emit(true)
	return true


func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
