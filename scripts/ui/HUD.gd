class_name HUD
extends Control
## The whole interface, built in code.
##
## Built procedurally rather than as .tscn files on purpose for this first
## build: it keeps the layout diffable, keeps the repo free of binary-ish scene
## churn, and means there is exactly one place to look when something moves.
## Once the layout settles, individual panels are easy to lift into scenes.

const BG := Color("13161a")
const PANEL := Color("1b2027")
const PANEL_HI := Color("232a33")
const TEXT := Color("d7dbe0")
const MUTED := Color("8b939c")
const ACCENT := Color("d9a441")
const GOOD := Color("7fbf6a")
const BAD := Color("d1685e")
const TECHCOL := Color("b08ad4")

var _refresh_accum := 0.0
var _dirty := true

# Top bar
var _era_label: Label
var _day_label: Label
var _pop_label: Label
var _speed_buttons: Array[Button] = []

# Panels
var _resource_rows := {}
var _vitals := {}
var _job_rows := {}
var _job_list: VBoxContainer
var _build_list: VBoxContainer
var _queue_list: VBoxContainer
var _tech_list: VBoxContainer
var _research_label: Label
var _research_bar: ProgressBar
var _log_text: RichTextLabel

var _known_jobs: Array[String] = []
var _known_buildings: Array[String] = []


func _ready() -> void:
	# Anchors alone are not enough here: the HUD is parented to a plain Node, so
	# nothing lays it out and it would sit at its own content minimum size -
	# which is both narrower and taller than the window. Set offsets explicitly
	# and re-apply whenever the window changes, which on web and console it will.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_viewport().size_changed.connect(_fit_to_viewport)
	theme = _make_theme()

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	root.add_child(_build_top_bar())

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 8)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(middle)

	middle.add_child(_build_left_column())
	middle.add_child(_build_center_column())
	middle.add_child(_build_right_column())

	root.add_child(_build_log_panel())

	Sim.state_changed.connect(func() -> void: _dirty = true)
	Sim.logged.connect(_on_logged)
	Sim.game_reset.connect(_on_game_reset)

	_rebuild_lists()
	_replay_log()
	_refresh()


func _fit_to_viewport() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum >= 0.1:
		_refresh_accum = 0.0
		if _dirty:
			_dirty = false
			_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_pause"):
		_set_speed(0 if Sim.speed_index != 0 else 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_speed_up"):
		_set_speed(mini(Sim.speed_index + 1, Balance.SPEEDS.size() - 1))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_speed_down"):
		_set_speed(maxi(Sim.speed_index - 1, 0))
		get_viewport().set_input_as_handled()


# --- Construction -----------------------------------------------------------

func _make_theme() -> Theme:
	var t := Theme.new()
	var box := StyleBoxFlat.new()
	box.bg_color = PANEL
	box.corner_radius_top_left = 6
	box.corner_radius_top_right = 6
	box.corner_radius_bottom_left = 6
	box.corner_radius_bottom_right = 6
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	t.set_stylebox("panel", "PanelContainer", box)

	var tab_box := box.duplicate() as StyleBoxFlat
	tab_box.bg_color = PANEL
	t.set_stylebox("panel", "TabContainer", tab_box)

	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", 14)
	t.set_font_size("font_size", "Button", 14)
	return t


func _panel(min_width: float = 0.0) -> VBoxContainer:
	var p := PanelContainer.new()
	if min_width > 0.0:
		p.custom_minimum_size.x = min_width
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	p.add_child(v)
	p.set_meta("content", v)
	return v


func _panel_of(v: Control) -> Control:
	return v.get_parent()


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", MUTED)
	return l


func _text(text: String, size: int = 14, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _build_top_bar() -> Control:
	var v := _panel()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)

	var title := _text("CIVAMATION", 18, ACCENT)
	row.add_child(title)

	_era_label = _text("", 14, TEXT)
	row.add_child(_era_label)

	_day_label = _text("", 14, MUTED)
	row.add_child(_day_label)

	_pop_label = _text("", 16, TEXT)
	row.add_child(_pop_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_speed_buttons.clear()
	var labels := ["II", "1x", "2x", "4x"]
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.toggle_mode = true
		b.custom_minimum_size.x = 42
		b.pressed.connect(_set_speed.bind(i))
		row.add_child(b)
		_speed_buttons.append(b)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(func() -> void:
		SaveSystem.save_game()
		Sim.add_log("Saved.", "info"))
	row.add_child(save_btn)

	var new_btn := Button.new()
	new_btn.text = "New World"
	new_btn.pressed.connect(_confirm_new_world)
	row.add_child(new_btn)

	return _panel_of(v)


func _build_left_column() -> Control:
	# Scrollable, because the stat panels are taller than a 720p window once the
	# stores list fills out - and because console and web both hand us window
	# sizes we did not choose.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 266
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 250
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	scroll.add_child(col)

	var res := _panel()
	res.add_child(_heading("STORES"))
	for id in Balance.RESOURCE_ORDER:
		var row := HBoxContainer.new()
		var name_label := _text(Balance.RESOURCES[id]["name"], 14, Balance.RESOURCES[id]["color"])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var amount := _text("0", 14, TEXT)
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		amount.custom_minimum_size.x = 74
		row.add_child(amount)
		var rate := _text("", 12, MUTED)
		rate.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		rate.custom_minimum_size.x = 60
		row.add_child(rate)
		res.add_child(row)
		_resource_rows[id] = {"name": name_label, "amount": amount, "rate": rate}
	col.add_child(_panel_of(res))

	var vit := _panel()
	vit.add_child(_heading("THE PEOPLE"))
	for key in ["housing", "capacity", "growth", "food_sat", "water_sat"]:
		var row := HBoxContainer.new()
		var lname := _text("", 13, MUTED)
		lname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lname)
		var lval := _text("", 13, TEXT)
		lval.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(lval)
		vit.add_child(row)
		_vitals[key] = {"name": lname, "value": lval}
	_vitals["housing"]["name"].text = "Shelter for"
	_vitals["capacity"]["name"].text = "Land supports"
	_vitals["growth"]["name"].text = "Births / deaths"
	_vitals["food_sat"]["name"].text = "Fed"
	_vitals["water_sat"]["name"].text = "Watered"
	col.add_child(_panel_of(vit))

	var eco := _panel()
	eco.add_child(_heading("THE LAND"))
	for key in ["game", "forage", "forest", "territory"]:
		var row := HBoxContainer.new()
		var lname := _text("", 13, MUTED)
		lname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lname)
		var lval := _text("", 13, TEXT)
		lval.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(lval)
		eco.add_child(row)
		_vitals[key] = {"name": lname, "value": lval}
	_vitals["game"]["name"].text = "Wild herds"
	_vitals["forage"]["name"].text = "Wild plants"
	_vitals["forest"]["name"].text = "Tree cover"
	_vitals["territory"]["name"].text = "Range"

	var hint := _text("Lean hard on the herds and they thin out, and growth slows until they recover. Farming and mining are how you stop depending on them.", 11, MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 220
	eco.add_child(hint)
	col.add_child(_panel_of(eco))

	return scroll


func _build_center_column() -> Control:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var view := WorldView.new()
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(view)
	return p


func _build_right_column() -> Control:
	var tabs := TabContainer.new()
	tabs.custom_minimum_size.x = 360
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# --- Work tab ---
	var work := ScrollContainer.new()
	work.name = "Work"
	var work_v := VBoxContainer.new()
	work_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	work_v.add_theme_constant_override("separation", 6)
	work.add_child(work_v)

	var auto_row := HBoxContainer.new()
	var auto_check := CheckButton.new()
	auto_check.text = "Assign work automatically"
	auto_check.button_pressed = Sim.auto_assign
	auto_check.toggled.connect(func(on: bool) -> void:
		Sim.auto_assign = on
		if on:
			Sim._auto_assign_jobs()
		_dirty = true)
	auto_row.add_child(auto_check)
	work_v.add_child(auto_row)

	_job_list = VBoxContainer.new()
	_job_list.add_theme_constant_override("separation", 6)
	work_v.add_child(_job_list)
	tabs.add_child(work)

	# --- Build tab ---
	var build := ScrollContainer.new()
	build.name = "Build"
	var build_v := VBoxContainer.new()
	build_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	build_v.add_theme_constant_override("separation", 6)
	build.add_child(build_v)

	var auto_build_check := CheckButton.new()
	auto_build_check.text = "Build without being asked"
	auto_build_check.button_pressed = Sim.auto_build
	auto_build_check.tooltip_text = "The settlement keeps improving itself while you are away. Turn this off to make every decision yourself."
	auto_build_check.toggled.connect(func(on: bool) -> void:
		Sim.auto_build = on
		_dirty = true)
	build_v.add_child(auto_build_check)

	build_v.add_child(_heading("UNDER CONSTRUCTION"))
	_queue_list = VBoxContainer.new()
	_queue_list.add_theme_constant_override("separation", 4)
	build_v.add_child(_queue_list)

	build_v.add_child(_heading("ORDERS"))
	_build_list = VBoxContainer.new()
	_build_list.add_theme_constant_override("separation", 6)
	build_v.add_child(_build_list)
	tabs.add_child(build)

	# --- Knowledge tab ---
	var tech := ScrollContainer.new()
	tech.name = "Knowledge"
	var tech_v := VBoxContainer.new()
	tech_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tech_v.add_theme_constant_override("separation", 6)
	tech.add_child(tech_v)

	var auto_res := CheckButton.new()
	auto_res.text = "Pursue whatever is cheapest"
	auto_res.button_pressed = Sim.auto_research
	auto_res.toggled.connect(func(on: bool) -> void:
		Sim.auto_research = on
		_dirty = true)
	tech_v.add_child(auto_res)

	_research_label = _text("", 14, TECHCOL)
	_research_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tech_v.add_child(_research_label)
	_research_bar = ProgressBar.new()
	_research_bar.show_percentage = false
	_research_bar.custom_minimum_size.y = 8
	tech_v.add_child(_research_bar)

	_tech_list = VBoxContainer.new()
	_tech_list.add_theme_constant_override("separation", 6)
	tech_v.add_child(_tech_list)
	tabs.add_child(tech)

	return tabs


func _build_log_panel() -> Control:
	var v := _panel()
	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = true
	_log_text.scroll_following = true
	_log_text.custom_minimum_size.y = 92
	_log_text.fit_content = false
	v.add_child(_log_text)
	return _panel_of(v)


# --- Dynamic lists ----------------------------------------------------------

func _rebuild_lists() -> void:
	_rebuild_jobs()
	_rebuild_buildings()
	_rebuild_techs()


func _rebuild_jobs() -> void:
	for c in _job_list.get_children():
		c.queue_free()
	_job_rows.clear()
	_known_jobs.clear()

	for id in Balance.JOB_ORDER:
		if not Sim.job_unlocked(id):
			continue
		_known_jobs.append(id)
		var job: Dictionary = Balance.JOBS[id]

		var box := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = PANEL_HI
		style.set_corner_radius_all(4)
		style.set_content_margin_all(8)
		box.add_theme_stylebox_override("panel", style)

		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		box.add_child(v)

		var head := HBoxContainer.new()
		var name_label := _text(job["name"], 14, TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)

		var minus := Button.new()
		minus.text = "-"
		minus.custom_minimum_size.x = 32
		minus.pressed.connect(func() -> void:
			Sim.auto_assign = false
			Sim.set_job(id, int(Sim.jobs.get(id, 0)) - 1))
		head.add_child(minus)

		var count := _text("0", 14, ACCENT)
		count.custom_minimum_size.x = 30
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		head.add_child(count)

		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size.x = 32
		plus.pressed.connect(func() -> void:
			Sim.auto_assign = false
			Sim.set_job(id, int(Sim.jobs.get(id, 0)) + 1))
		head.add_child(plus)
		v.add_child(head)

		var desc := _text(job["desc"], 11, MUTED)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size.x = 300
		v.add_child(desc)

		var yield_label := _text("", 12, MUTED)
		v.add_child(yield_label)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 5.0
		slider.step = 1.0
		slider.value = float(Sim.job_weights.get(id, 1.0))
		slider.custom_minimum_size.y = 14
		slider.tooltip_text = "Priority when work is assigned automatically"
		slider.value_changed.connect(func(val: float) -> void:
			Sim.job_weights[id] = val)
		v.add_child(slider)

		_job_list.add_child(box)
		_job_rows[id] = {"count": count, "yield": yield_label, "slider": slider}


func _rebuild_buildings() -> void:
	for c in _build_list.get_children():
		c.queue_free()
	_known_buildings.clear()

	for id in Balance.BUILDING_ORDER:
		if not Sim.building_unlocked(id):
			continue
		_known_buildings.append(id)
		var b: Dictionary = Balance.BUILDINGS[id]

		var box := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = PANEL_HI
		style.set_corner_radius_all(4)
		style.set_content_margin_all(8)
		box.add_theme_stylebox_override("panel", style)

		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		box.add_child(v)

		var head := HBoxContainer.new()
		var name_label := _text(b["name"], 14, TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		var owned := _text("", 12, MUTED)
		head.add_child(owned)
		v.add_child(head)

		var desc := _text(b["desc"], 11, MUTED)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size.x = 300
		v.add_child(desc)

		var cost_label := _text(_cost_text(b["cost"]), 12, MUTED)
		v.add_child(cost_label)

		var btn := Button.new()
		btn.text = "Build"
		btn.pressed.connect(func() -> void: Sim.queue_building(id))
		v.add_child(btn)

		_build_list.add_child(box)
		box.set_meta("id", id)
		box.set_meta("owned", owned)
		box.set_meta("btn", btn)
		box.set_meta("cost", cost_label)


func _rebuild_techs() -> void:
	for c in _tech_list.get_children():
		c.queue_free()

	for id in Balance.TECH_ORDER:
		if Sim.techs.has(id) or not Sim.tech_available(id):
			continue
		var t: Dictionary = Balance.TECHS[id]

		var box := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = PANEL_HI
		style.set_corner_radius_all(4)
		style.set_content_margin_all(8)
		box.add_theme_stylebox_override("panel", style)

		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		box.add_child(v)

		var head := HBoxContainer.new()
		var name_label := _text(t["name"], 14, TECHCOL)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		head.add_child(_text("%s know." % Balance.fmt(float(t["cost"])), 12, MUTED))
		v.add_child(head)

		var desc := _text(t["desc"], 11, MUTED)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size.x = 300
		v.add_child(desc)

		var btn := Button.new()
		btn.text = "Pursue this"
		btn.pressed.connect(func() -> void:
			Sim.set_research(id)
			_dirty = true)
		v.add_child(btn)

		_tech_list.add_child(box)


func _cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for res in cost:
		parts.append("%s %s" % [Balance.fmt(float(cost[res])), Balance.RESOURCES[res]["name"]])
	return "Costs " + ", ".join(parts)


# --- Refresh ----------------------------------------------------------------

func _refresh() -> void:
	_refresh_top()
	_refresh_resources()
	_refresh_vitals()
	_refresh_jobs()
	_refresh_buildings()
	_refresh_research()


func _refresh_top() -> void:
	_era_label.text = Sim.era_name()
	_day_label.text = "Year %d, day %d" % [int(Sim.day / 360.0) + 1, int(Sim.day) % 360 + 1]
	_pop_label.text = "%d people" % int(Sim.population)
	for i in _speed_buttons.size():
		_speed_buttons[i].button_pressed = (i == Sim.speed_index)


func _refresh_resources() -> void:
	for id in Balance.RESOURCE_ORDER:
		var row: Dictionary = _resource_rows[id]
		if id == "ore":
			# The store is always "ore"; what that word means moves with the age.
			row["name"].text = Sim.ore_name()
			row["name"].add_theme_color_override(
				"font_color", Balance.ORE_TIERS[Sim.ore_tier()]["color"])
		var cap := Sim.capacity_of(id)
		var amount: float = Sim.resources[id]
		if cap > 0.0:
			row["amount"].text = "%s / %s" % [Balance.fmt(amount), Balance.fmt(cap)]
			row["amount"].add_theme_color_override("font_color", ACCENT if amount >= cap * 0.995 else TEXT)
		else:
			row["amount"].text = Balance.fmt(amount)
		var rate: float = Sim.rates.get(id, 0.0)
		row["rate"].text = Balance.fmt_rate(rate) + "/d"
		row["rate"].add_theme_color_override("font_color", GOOD if rate >= 0.0 else BAD)


func _refresh_vitals() -> void:
	var world := Sim.world
	_vitals["housing"]["value"].text = "%d" % int(Sim.housing)
	_vitals["capacity"]["value"].text = "%d" % int(Sim.carrying_capacity)
	_vitals["capacity"]["value"].add_theme_color_override(
		"font_color", GOOD if Sim.carrying_capacity >= Sim.population else BAD)
	_vitals["growth"]["value"].text = "%.2f / %.2f" % [Sim.births_per_day, Sim.deaths_per_day]
	_vitals["growth"]["value"].add_theme_color_override(
		"font_color", GOOD if Sim.births_per_day >= Sim.deaths_per_day else BAD)

	_set_pct(_vitals["food_sat"]["value"], Sim.food_satisfaction)
	_set_pct(_vitals["water_sat"]["value"], Sim.water_satisfaction)

	if world != null:
		_set_pct(_vitals["game"]["value"], world.stock_health(world.game, world.game_cap))
		_set_pct(_vitals["forage"]["value"], world.stock_health(world.forage, world.forage_cap))
		_set_pct(_vitals["forest"]["value"], world.stock_health(world.forest, world.forest_cap))
		_vitals["territory"]["value"].text = "%d tiles" % world.territory.size()


func _set_pct(label: Label, value: float) -> void:
	label.text = "%d%%" % int(round(clampf(value, 0.0, 1.0) * 100.0))
	var c := BAD
	if value > 0.66:
		c = GOOD
	elif value > 0.33:
		c = ACCENT
	label.add_theme_color_override("font_color", c)


func _refresh_jobs() -> void:
	# Unlocks changed? Rebuild rather than patch.
	var unlocked: Array[String] = []
	for id in Balance.JOB_ORDER:
		if Sim.job_unlocked(id):
			unlocked.append(id)
	if unlocked != _known_jobs:
		_rebuild_jobs()

	for id in _job_rows:
		var row: Dictionary = _job_rows[id]
		row["count"].text = str(int(Sim.jobs.get(id, 0)))
		row["yield"].text = _job_yield_text(id)
		if not row["slider"].has_focus():
			row["slider"].value = float(Sim.job_weights.get(id, 1.0))


func _job_yield_text(id: String) -> String:
	var n: int = Sim.jobs.get(id, 0)
	match Balance.JOBS[id]["kind"]:
		"game":
			return "%s food/day  (%s each)" % [
				Balance.fmt(Sim.job_output(id)), Balance.fmt(Sim.job_output_per_worker(id), 2)]
		"forage", "farm":
			return "%s food/day  (%s each)" % [
				Balance.fmt(Sim.job_output(id)), Balance.fmt(Sim.job_output_per_worker(id), 2)]
		"forest":
			return "%s wood/day" % Balance.fmt(Sim.job_output(id))
		"water":
			return "%s water/day" % Balance.fmt(Sim.job_output(id))
		"stone":
			return "%s stone/day" % Balance.fmt(Sim.job_output(id))
		"ore":
			return "%s %s/day  (+%s gold)" % [
				Balance.fmt(Sim.job_output(id)), Sim.ore_name().to_lower(),
				Balance.fmt(Sim.production.get("gold", 0.0), 2)]
		"knowledge":
			return "%s knowledge/day" % Balance.fmt(Sim.job_output(id), 2)
		"build":
			var queued := Sim.build_queue.size()
			return "%d in the queue" % queued
	return str(n)


func _refresh_buildings() -> void:
	var unlocked: Array[String] = []
	for id in Balance.BUILDING_ORDER:
		if Sim.building_unlocked(id):
			unlocked.append(id)
	if unlocked != _known_buildings:
		_rebuild_buildings()

	for box in _build_list.get_children():
		var id: String = box.get_meta("id")
		var b: Dictionary = Balance.BUILDINGS[id]
		var owned: Label = box.get_meta("owned")
		owned.text = "%d / %d" % [int(Sim.buildings.get(id, 0)), int(b["max"])]
		var btn: Button = box.get_meta("btn")
		btn.disabled = not Sim.can_build(id)

	# Queue
	for c in _queue_list.get_children():
		c.queue_free()
	if Sim.build_queue.is_empty():
		_queue_list.add_child(_text("Nothing being built.", 12, MUTED))
	else:
		for i in Sim.build_queue.size():
			var order: Dictionary = Sim.build_queue[i]
			var row := HBoxContainer.new()
			var name_label := _text(Balance.BUILDINGS[order["id"]]["name"], 13, TEXT)
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_label)
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(90, 8)
			bar.max_value = float(order["total"])
			bar.value = float(order["work"])
			row.add_child(bar)
			var cancel := Button.new()
			cancel.text = "x"
			cancel.custom_minimum_size.x = 26
			cancel.pressed.connect(func() -> void: Sim.cancel_order(i))
			row.add_child(cancel)
			_queue_list.add_child(row)


func _refresh_research() -> void:
	var count := 0
	for id in Balance.TECH_ORDER:
		if Sim.tech_available(id):
			count += 1
	if count != _tech_list.get_child_count():
		_rebuild_techs()

	if Sim.researching == "":
		_research_label.text = "Nobody is puzzling over anything in particular."
		_research_bar.value = 0.0
	else:
		var t: Dictionary = Balance.TECHS[Sim.researching]
		var cost := float(t["cost"])
		var have: float = Sim.resources["knowledge"]
		_research_label.text = "%s  -  %s / %s" % [t["name"], Balance.fmt(have), Balance.fmt(cost)]
		_research_bar.max_value = cost
		_research_bar.value = minf(have, cost)


# --- Log --------------------------------------------------------------------

func _log_color(kind: String) -> Color:
	match kind:
		"good": return GOOD
		"bad": return BAD
		"tech": return TECHCOL
		"era": return ACCENT
	return MUTED


func _on_logged(entry: Dictionary) -> void:
	_append_log(entry)


func _append_log(entry: Dictionary) -> void:
	var c := _log_color(String(entry.get("kind", "info")))
	_log_text.append_text("[color=#%s]Day %d[/color]  [color=#%s]%s[/color]\n" % [
		MUTED.to_html(false), int(entry.get("day", 0)), c.to_html(false), String(entry.get("text", ""))])


func _replay_log() -> void:
	_log_text.clear()
	for e in Sim.log_entries:
		_append_log(e)


# --- Actions ----------------------------------------------------------------

func _set_speed(index: int) -> void:
	Sim.speed_index = clampi(index, 0, Balance.SPEEDS.size() - 1)
	_dirty = true


func _on_game_reset() -> void:
	_rebuild_lists()
	_replay_log()
	_dirty = true


func _confirm_new_world() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = "Abandon these people and generate a new world?\nYour current settlement will be lost."
	dialog.title = "New World"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		Sim.new_game(0)
		SaveSystem.save_game())
	dialog.close_requested.connect(dialog.queue_free)
	dialog.popup_centered()
