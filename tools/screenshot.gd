extends Node
## Renders a real frame of the game to a PNG. Needs a display (or xvfb), unlike
## the rest of the tooling.
##
##   godot --path . --resolution 1280x720 res://tools/Screenshot.tscn -- \
##       --days 300 --out shot.png
##
## Worth having: this caught two layout bugs that no headless test could see -
## the HUD sizing itself to its content instead of the window, and the event log
## being pushed off the bottom of the screen.

const DEFAULT_DAYS := 300.0
const DEFAULT_OUT := "user://screenshot.png"
const DEFAULT_SEED := 1337


func _ready() -> void:
	var days := DEFAULT_DAYS
	var out := DEFAULT_OUT
	var world_seed := DEFAULT_SEED
	var zoom := 0.0
	var map_filter := -1
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--days" and i + 1 < args.size():
			days = float(args[i + 1])
		elif args[i] == "--out" and i + 1 < args.size():
			out = args[i + 1]
		elif args[i] == "--seed" and i + 1 < args.size():
			world_seed = int(args[i + 1])
		elif args[i] == "--zoom" and i + 1 < args.size():
			zoom = float(args[i + 1])
		elif args[i] == "--filter" and i + 1 < args.size():
			map_filter = int(args[i + 1])

	Sim.new_game(world_seed)
	Sim.simulate_days(days, true)
	Sim.speed_index = 0

	var hud := HUD.new()
	add_child(hud)
	# Terrain sprites and individual figures only draw in past a zoom threshold,
	# so a shot of the whole world can never show either. Being able to ask for
	# a close shot is the difference between this tool proving the artwork works
	# and this tool proving only that the interface lays out.
	if zoom > 0.0 or map_filter >= 0:
		await get_tree().process_frame
		if map_filter >= 0:
			hud.set_map_filter(map_filter)
		if zoom > 0.0:
			var view: WorldView = hud.find_children("", "WorldView", true, false)[0]
			view.zoom = zoom
			view.queue_redraw()

	# Let the interface build, lay out and settle before grabbing the frame.
	for i in 20:
		await get_tree().process_frame
	Sim.state_changed.emit()
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var err := get_viewport().get_texture().get_image().save_png(out)
	if err != OK:
		push_error("Could not write %s: %s" % [out, error_string(err)])
		get_tree().quit(1)
		return
	print("%s - day %d, %d people, %s, %d techs"
			% [out, int(Sim.day), int(Sim.population), Sim.era_name(), Sim.techs.size()])
	get_tree().quit(0)
