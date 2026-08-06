extends Node
## Entry point: load a save if there is one, otherwise roll a fresh world, then
## put the interface on screen.


func _ready() -> void:
	randomize()

	if SaveSystem.has_save():
		if not SaveSystem.load_game():
			Sim.new_game(0)
	else:
		Sim.new_game(0)

	var hud := HUD.new()
	add_child(hud)
