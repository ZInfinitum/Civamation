extends Node
## Drop-in artwork.
##
## Every drawn thing in the game asks here for a texture first and falls back to
## its hand-drawn primitive if there isn't one. Nothing has to be registered,
## imported by hand, or referenced anywhere in code: put a PNG in the right
## folder with the right name and it appears.
##
##   assets/terrain/forest.png      one per biome     (forest, plains, tundra...)
##   assets/buildings/hut.png       one per building  (hut, mine, granary...)
##   assets/animals/deer.png        one per animal    (deer, wolf, rabbit, bird)
##   assets/workers/hunter.png      one per job       (hunter, miner, explorer...)
##   assets/resources/food.png      one per resource  (food, wood, ore, gold...)
##   assets/ui/boon_caravan.png     odds and ends
##
## The names are the ids in Balance.gd, which is also what the code already uses
## everywhere, so there is exactly one thing to get right.
##
## Two roots are searched, and `user://` wins:
##   res://assets/...   shipped with the game
##   user://assets/...  dropped in afterwards, on a machine that already has it
##
## `user://` is the modding path and needs no editor and no re-export - useful
## while iterating on art, and it is what "drag and drop and it just works"
## means once the game is built. Call `reload()` (or the button in Settings) to
## pick up changes without restarting.

signal reloaded

const ROOTS: Array[String] = ["user://assets", "res://assets"]
const CATEGORIES: Array[String] = ["terrain", "buildings", "animals", "workers", "resources", "ui"]
const EXTENSIONS: Array[String] = ["png", "svg", "webp", "jpg"]

## category -> { id: Texture2D }
var _cache := {}
var _found := 0


func _ready() -> void:
	reload()


## Rescan every root. Cheap - a few directory listings - and safe to call at any
## time, so artwork can be swapped while the game is running.
func reload() -> void:
	_cache = {}
	_found = 0
	for category in CATEGORIES:
		_cache[category] = {}
	# Later roots must not overwrite earlier ones, so scan in priority order and
	# skip anything already claimed.
	for root in ROOTS:
		for category in CATEGORIES:
			_scan(root + "/" + category, category)
	if _found > 0:
		print("Art: loaded %d replacement textures" % _found)
	reloaded.emit()


func _scan(path: String, category: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			# Godot leaves a .import beside every texture it has processed; the
			# real file is the one without it.
			var clean := name.trim_suffix(".import")
			var ext := clean.get_extension().to_lower()
			var id := clean.get_basename().to_lower()
			if EXTENSIONS.has(ext) and not (_cache[category] as Dictionary).has(id):
				var tex := _load(path + "/" + clean)
				if tex != null:
					_cache[category][id] = tex
					_found += 1
		name = dir.get_next()
	dir.list_dir_end()


func _load(path: String) -> Texture2D:
	# Anything under res:// has been through the import pipeline and is loaded
	# normally. Anything under user:// has not, so it is read as an image at
	# runtime - which is exactly what makes dropping a file in work at all.
	if path.begins_with("res://"):
		var res := ResourceLoader.load(path)
		return res as Texture2D if res is Texture2D else null
	var img := Image.new()
	if img.load(path) != OK:
		push_warning("Art: could not read %s" % path)
		return null
	return ImageTexture.create_from_image(img)


func get_texture(category: String, id: String) -> Texture2D:
	var bucket: Dictionary = _cache.get(category, {})
	return bucket.get(id.to_lower(), null)


func has_any(category: String) -> bool:
	return not (_cache.get(category, {}) as Dictionary).is_empty()


func count() -> int:
	return _found


# --- Typed lookups, so callers never have to know the folder names -----------

func terrain(biome: int) -> Texture2D:
	return get_texture("terrain", Balance.biome_id(biome))


func building(id: String) -> Texture2D:
	return get_texture("buildings", id)


func animal(kind: int) -> Texture2D:
	return get_texture("animals", Balance.animal_id(kind))


func worker(job_id: String) -> Texture2D:
	return get_texture("workers", job_id)


func resource_icon(id: String) -> Texture2D:
	return get_texture("resources", id)


func ui(id: String) -> Texture2D:
	return get_texture("ui", id)


## Draw a texture centred on a point at a given size. One call site for all the
## sprite drawing so the fallbacks stay tidy.
static func draw_centred(canvas: CanvasItem, tex: Texture2D, centre: Vector2,
		height: float, tint: Color = Color.WHITE) -> void:
	var size := tex.get_size()
	if size.y <= 0.0:
		return
	var w := height * (size.x / size.y)
	canvas.draw_texture_rect(tex, Rect2(centre - Vector2(w, height) * 0.5,
			Vector2(w, height)), false, tint)
