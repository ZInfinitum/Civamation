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
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--days" and i + 1 < args.size():
			days = float(args[i + 1])
		elif args[i] == "--out" and i + 1 < args.size():
			out = args[i + 1]
		elif args[i] == "--seed" and i + 1 < args.size():
			world_seed = int(args[i + 1])

	Sim.new_game(world_seed)
	Sim.simulate_days(days, true)
	Sim.speed_index = 0

	var hud := HUD.new()
	add_child(hud)

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
