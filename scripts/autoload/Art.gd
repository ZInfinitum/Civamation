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
	# Under res://, prefer the imported resource: in an exported build that is
	# the only thing that exists, and it is the compressed, mipmapped one.
	#
	# But running from a clean clone there *are* no .import files, because this
	# project deliberately has no build step and nobody has opened the editor.
	# ResourceLoader then fails with "no loader found", and every shipped sprite
	# silently does not exist - which is how the first batch of terrain tiles
	# came out invisible. So fall through to reading the bytes, exactly as the
	# user:// path already does.
	if path.begins_with("res://"):
		if ResourceLoader.exists(path):
			var res := ResourceLoader.load(path)
			if res is Texture2D:
				return res as Texture2D
		return _from_bytes(path)

	# user:// has never been through the importer by definition. Reading it at
	# runtime is exactly what makes dropping a file in work at all.
	var img := Image.new()
	if img.load(path) != OK:
		push_warning("Art: could not read %s" % path)
		return null
	return ImageTexture.create_from_image(img)


## Decode an image straight out of the file, no import step involved. Works for
## res:// and user:// alike, and for a res:// path it also works inside a PCK.
func _from_bytes(path: String) -> Texture2D:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	var err := FAILED
	match path.get_extension().to_lower():
		"png": err = img.load_png_from_buffer(bytes)
		"webp": err = img.load_webp_from_buffer(bytes)
		"jpg", "jpeg": err = img.load_jpg_from_buffer(bytes)
		"svg": err = img.load_svg_from_buffer(bytes)
	if err != OK:
		push_warning("Art: could not decode %s" % path)
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
