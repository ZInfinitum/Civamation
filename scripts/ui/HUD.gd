class_name HUD
extends Control
## The whole interface, built in code.
##
## Built procedurally rather than as .tscn files on purpose: it keeps the layout
## diffable, keeps the repo free of scene churn, and means there is exactly one
## place to look when something moves. Individual panels are easy to lift into
## scenes once the layout settles.
##
## Refresh discipline, since this runs beside a simulation: nothing rebuilds a
## list unless the *set* of things in it changed. Per-frame work is limited to
## rewriting the text of labels that already exist, ten times a second.

const BG := Color("13161a")
const PANEL := Color("1b2027")
const PANEL_HI := Color("232a33")
const TEXT := Color("d7dbe0")
const MUTED := Color("8b939c")
const ACCENT := Color("d9a441")
const GOOD := Color("7fbf6a")
const BAD := Color("d1685e")
const TECHCOL := Color("b08ad4")

## Interface tick. Subtracted rather than zeroed when it fires, so the cadence
## is the same at thirty frames a second as at three hundred.
const REFRESH_INTERVAL := 0.1
var _refresh_accum := 0.0
var _dirty := true

# Top bar
var _era_label: Label
var _day_label: Label
var _pop_label: Label
var _fps_label: Label
var _season_label: Label
var _weather_label: Label
var _temp_label: Label
var _speed_buttons: Array[Button] = []

# Panels
var _resource_rows := {}
var _vitals := {}
var _job_rows := {}
var _job_list: VBoxContainer
var _build_list: VBoxContainer
var _queue_list: VBoxContainer
var _tech_list: VBoxContainer
var _upgrade_list: VBoxContainer
var _upgrade_tab_label: Label
var _research_label: Label
var _research_bar: ProgressBar
var _log_text: RichTextLabel
var _map: WorldView

var _known_jobs: Array[String] = []
var _known_buildings: Array[String] = []
var _known_upgrades: Array[String] = []
var _queue_signature := ""
var _summary: Label
var _plan_label: Label
var _boon_button: Button
var _legacy_button: Button
var _surge_button: Button
var _sparks := {}
var _decree_list: VBoxContainer
var _festival_button: Button
var _outpost_button: Button
var _settlement_button: Button
var _settlement_note: Label
var _rule_note: Label
var _trade_note: Label
var _trade_sell: OptionButton
var _trade_buy: OptionButton
var _council_dialog: AcceptDialog
var _placing_outpost := false
var _placing_settlement := false
var _filter_pick: OptionButton
var _filter_note: Label


func _ready() -> void:
	# Anchors alone are not enough: the HUD is parented to a plain Node, so
	# nothing lays it out and it would sit at its own content minimum size.
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

	# One line that answers "how is it going" without reading four panels.
	var sum_panel := _panel()
	_summary = _text("", 13, TEXT)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sum_panel.add_child(_summary)
	_plan_label = _text("", 11, MUTED)
	_plan_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sum_panel.add_child(_plan_label)
	root.add_child(_panel_of(sum_panel))

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 8)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(middle)
	middle.add_child(_build_left_column())
	middle.add_child(_build_center_column())
	middle.add_child(_build_right_column())

	root.add_child(_build_log_panel())

	Sim.state_changed.connect(func() -> void: _dirty = true)
	Sim.logged.connect(_append_log)
	Sim.game_reset.connect(_on_game_reset)
	Settings.changed.connect(_on_settings_changed)

	_rebuild_lists()
	_replay_log()
	_on_settings_changed()
	_refresh()
	# Whatever happened while the game was closed, told properly rather than as
	# one line in the log.
	if not Sim.offline_digest.is_empty():
		_show_digest()


func _fit_to_viewport() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	# The clock is the one thing that has to look continuous, so it runs every
	# frame while the rest of the interface stays on the 10Hz tick. It is a
	# single Label assignment - the panels behind it are what cost anything.
	_day_label.text = Balance.fmt_clock(Sim.day)

	_refresh_accum += delta
	if _refresh_accum < REFRESH_INTERVAL:
		return
	_refresh_accum -= REFRESH_INTERVAL
	if Settings.show_fps:
		_fps_label.text = "%d fps" % Engine.get_frames_per_second()
	if _dirty:
		_dirty = false
		_refresh()
		_refresh_tutorial()


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


# --- Construction helpers ---------------------------------------------------

func _make_theme() -> Theme:
	var t := Theme.new()
	var box := StyleBoxFlat.new()
	box.bg_color = PANEL
	box.set_corner_radius_all(6)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	t.set_stylebox("panel", "PanelContainer", box)
	t.set_stylebox("panel", "TabContainer", box.duplicate() as StyleBoxFlat)
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", 14)
	t.set_font_size("font_size", "Button", 14)
	return t


func _panel() -> VBoxContainer:
	var p := PanelContainer.new()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	p.add_child(v)
	return v


func _panel_of(v: Control) -> Control:
	return v.get_parent()


func _card() -> VBoxContainer:
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_HI
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	box.add_theme_stylebox_override("panel", style)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	box.add_child(v)
	return v


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


func _wrapped(text: String, size: int = 11, color: Color = MUTED) -> Label:
	var l := _text(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 300
	return l


func _row(name_text: String) -> Array:
	var row := HBoxContainer.new()
	var l := _text(name_text, 13, MUTED)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var v := _text("", 13, TEXT)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	return [row, l, v]


# --- Top bar ----------------------------------------------------------------

func _build_top_bar() -> Control:
	var v := _panel()
	# An HBox here forced a minimum width of roughly sixteen hundred logical
	# pixels - title, era, day, population, five speed buttons, and five more
	# buttons after them. A container cannot shrink below its children, so the
	# whole interface was pushed wider than the window and the right-hand tabs
	# fell off the edge of the screen. Flowing means the bar takes a second line
	# when it has to, which is also what a Steam Deck and a phone browser need.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(row)

	row.add_child(_text("CIVAMATION", 18, ACCENT))
	_era_label = _text("", 14, TEXT)
	row.add_child(_era_label)
	_day_label = _text("", 13, MUTED)
	row.add_child(_day_label)
	_pop_label = _text("", 16, TEXT)
	row.add_child(_pop_label)

	_fps_label = _text("", 12, MUTED)
	row.add_child(_fps_label)

	_season_label = _text("", 13, TEXT)
	row.add_child(_season_label)
	_weather_label = _text("", 13, MUTED)
	row.add_child(_weather_label)
	_temp_label = _text("", 12, MUTED)
	row.add_child(_temp_label)

	_speed_buttons.clear()
	for i in Balance.SPEEDS.size():
		var b := Button.new()
		b.text = String(Balance.SPEED_LABELS[i])
		b.toggle_mode = true
		b.custom_minimum_size.x = 44
		b.pressed.connect(_set_speed.bind(i))
		row.add_child(b)
		_speed_buttons.append(b)

	# Appears only when there is something on the map worth going to look at.
	_boon_button = Button.new()
	_boon_button.visible = false
	_boon_button.pressed.connect(func() -> void:
		Sim.collect_boon()
		_dirty = true)
	row.add_child(_boon_button)

	_legacy_button = Button.new()
	_legacy_button.text = "Legacy"
	_legacy_button.visible = false
	_legacy_button.pressed.connect(_open_legacy)
	row.add_child(_legacy_button)

	# A designer should not have to wait an hour to see an hour of consequences.
	_surge_button = Button.new()
	_surge_button.text = "+100d"
	_surge_button.tooltip_text = "Run a hundred days immediately. Shown while the verbose log is on."
	_surge_button.visible = false
	_surge_button.pressed.connect(func() -> void:
		Sim.surge(100.0)
		_dirty = true)
	row.add_child(_surge_button)

	var chron_btn := Button.new()
	chron_btn.text = "Chronicle"
	chron_btn.pressed.connect(_open_chronicle)
	row.add_child(chron_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.pressed.connect(_open_settings)
	row.add_child(settings_btn)

	var new_btn := Button.new()
	new_btn.text = "New World"
	new_btn.pressed.connect(_open_new_world)
	row.add_child(new_btn)
	return _panel_of(v)


# --- Left column ------------------------------------------------------------

func _build_left_column() -> Control:
	# Scrollable, because the stat panels are taller than a 720p window and
	# because console and web both hand us window sizes we did not choose.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 264
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 248
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	scroll.add_child(col)

	var res := _panel()
	res.add_child(_heading("STORES"))
	for id in Balance.RESOURCE_ORDER:
		var row := HBoxContainer.new()
		# Icon if one has been dropped in; the coloured name carries it if not.
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(18, 18)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = Art.resource_icon(id)
		icon.visible = icon.texture != null
		row.add_child(icon)
		var name_label := _text(Balance.RESOURCES[id]["name"], 14, Balance.RESOURCES[id]["color"])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var amount := _text("0", 14, TEXT)
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		amount.custom_minimum_size.x = 78
		row.add_child(amount)
		var rate := _text("", 12, MUTED)
		rate.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		rate.custom_minimum_size.x = 58
		row.add_child(rate)
		res.add_child(row)
		_resource_rows[id] = {"name": name_label, "amount": amount, "rate": rate, "icon": icon}
	col.add_child(_panel_of(res))

	var hist := _panel()
	hist.add_child(_heading("HISTORY"))
	for spec in [["pop", "People", ACCENT], ["food", "Food", Color("d9a441")],
			["herd", "Wild herds", Color("d98555")], ["output", "Total ever made", GOOD]]:
		hist.add_child(_text(String(spec[1]), 11, MUTED))
		var spark := Sparkline.new()
		spark.color = spec[2]
		spark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hist.add_child(spark)
		_sparks[spec[0]] = spark
	hist.add_child(_text("last %d days" % Balance.HISTORY_SAMPLES, 10, MUTED))
	col.add_child(_panel_of(hist))

	var vit := _panel()
	vit.add_child(_heading("THE PEOPLE"))
	for pair in [["housing", "Shelter for"], ["capacity", "Land supports"],
			["growth", "Births / deaths"], ["fed", "Fed"], ["watered", "Watered"]]:
		var r := _row(pair[1])
		vit.add_child(r[0])
		_vitals[pair[0]] = r[2]
	col.add_child(_panel_of(vit))

	var eco := _panel()
	eco.add_child(_heading("THE LAND"))
	for pair in [["game", "Wild herds"], ["forage", "Wild plants"], ["forest", "Tree cover"],
			["territory", "Worked land"], ["explored", "World mapped"], ["frontier", "Frontier"]]:
		var r := _row(pair[1])
		eco.add_child(r[0])
		_vitals[pair[0]] = r[2]
	eco.add_child(_wrapped("Lean hard on the herds and they thin out, and growth slows until "
			+ "they recover. Farming and mining are how you stop depending on them."))
	col.add_child(_panel_of(eco))

	var work := _panel()
	work.add_child(_heading("WORKSHOPS"))
	for pair in [["plots", "Farm plots"], ["lots", "Woodlots"], ["mines", "Mine shafts"],
			["quarries", "Quarry faces"]]:
		var r := _row(pair[1])
		work.add_child(r[0])
		_vitals[pair[0]] = r[2]
	col.add_child(_panel_of(work))

	return scroll


# --- Centre -----------------------------------------------------------------

func _build_center_column() -> Control:
	var outer := VBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 4)

	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map = WorldView.new()
	_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(_map)
	outer.add_child(p)

	# Flowing for the same reason the top bar is: two buttons, a dropdown and two
	# lines of prose do not fit under a narrow map, and the map is the thing that
	# gets narrow first.
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 6)
	bar.add_theme_constant_override("v_separation", 2)
	var home := Button.new()
	home.text = "Settlement"
	home.pressed.connect(func() -> void: _map.view_home())
	bar.add_child(home)
	var whole := Button.new()
	whole.text = "Whole World"
	whole.pressed.connect(func() -> void: _map.view_world())
	bar.add_child(whole)

	# Overlays. The same picture, asked a different question - who is out there,
	# how many of them, what the ground is worth, how far the reach goes.
	_filter_pick = OptionButton.new()
	for i in Balance.MAP_FILTERS.size():
		var f: Dictionary = Balance.MAP_FILTERS[i]
		_filter_pick.add_item(String(f["name"]), int(f["id"]))
	_filter_pick.selected = 0
	_filter_pick.item_selected.connect(func(i: int) -> void:
		var f: Dictionary = Balance.MAP_FILTERS[i]
		_map.filter = int(f["id"])
		_filter_pick.tooltip_text = String(f["desc"])
		_filter_note.text = String(f["desc"])
		_map.queue_redraw())
	_filter_pick.tooltip_text = String((Balance.MAP_FILTERS[0] as Dictionary)["desc"])
	bar.add_child(_filter_pick)

	_filter_note = _text(String((Balance.MAP_FILTERS[0] as Dictionary)["desc"]), 11, MUTED)
	bar.add_child(_filter_note)

	bar.add_child(_text("scroll to zoom, drag to pan", 11, MUTED))
	outer.add_child(bar)
	return outer


# --- Right tabs -------------------------------------------------------------

func _tab_scroll(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	scroll.add_child(v)
	return v


func _toggle(text: String, pressed: bool, tip: String, on_toggle: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = pressed
	c.tooltip_text = tip
	c.toggled.connect(on_toggle)
	return c


func _build_right_column() -> Control:
	var tabs := TabContainer.new()
	tabs.custom_minimum_size.x = 366
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var work := _tab_scroll("Work")
	work.add_child(_toggle("Assign work automatically", Sim.auto_assign,
			"The settlement decides who does what. Turn this off to place every worker yourself.",
			func(on: bool) -> void:
				Sim.auto_assign = on
				if on:
					Sim._auto_assign_jobs()
				_dirty = true))
	_job_list = VBoxContainer.new()
	_job_list.add_theme_constant_override("separation", 6)
	work.add_child(_job_list)
	tabs.add_child(_panel_of(work))

	var build := _tab_scroll("Build")
	build.add_child(_toggle("Build without being asked", Sim.auto_build,
			"The settlement keeps improving itself while you are away.",
			func(on: bool) -> void:
				Sim.auto_build = on
				_dirty = true))
	build.add_child(_heading("UNDER CONSTRUCTION"))
	_queue_list = VBoxContainer.new()
	_queue_list.add_theme_constant_override("separation", 4)
	build.add_child(_queue_list)
	build.add_child(_heading("ORDERS"))
	_build_list = VBoxContainer.new()
	_build_list.add_theme_constant_override("separation", 6)
	build.add_child(_build_list)
	tabs.add_child(_panel_of(build))

	var up := _tab_scroll("Upgrades")
	up.add_child(_toggle("Buy upgrades automatically", Sim.auto_upgrade,
			"Spends spare Knowledge on the cheapest available upgrade, but never at the cost of stalling research.",
			func(on: bool) -> void:
				Sim.auto_upgrade = on
				_dirty = true))
	_upgrade_tab_label = _wrapped("", 12, MUTED)
	up.add_child(_upgrade_tab_label)
	_upgrade_list = VBoxContainer.new()
	_upgrade_list.add_theme_constant_override("separation", 6)
	up.add_child(_upgrade_list)
	tabs.add_child(_panel_of(up))

	var rule := _tab_scroll("Rule")
	rule.add_child(_wrapped("The elders run the settlement sensibly and will never do any "
			+ "of this. A decree is a commitment with a real cost; a festival spends the "
			+ "granary on a party; an outpost is a judgement about a place. None of them "
			+ "has a right answer a planner could compute, which is why they are yours.",
			12, TEXT))

	rule.add_child(_heading("DECREE"))
	_rule_note = _text("", 11, MUTED)
	_rule_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rule.add_child(_rule_note)
	_decree_list = VBoxContainer.new()
	_decree_list.add_theme_constant_override("separation", 6)
	rule.add_child(_decree_list)
	_build_decree_cards()

	rule.add_child(_heading("THE SETTLEMENT"))
	_festival_button = Button.new()
	_festival_button.pressed.connect(func() -> void:
		Sim.hold_festival()
		_dirty = true)
	rule.add_child(_festival_button)
	rule.add_child(_wrapped("Spends a third of the food. Births and ideas surge for a season, "
			+ "and it counts toward your momentum."))

	_outpost_button = Button.new()
	_outpost_button.pressed.connect(func() -> void:
		_placing_outpost = not _placing_outpost
		_map.placing_outpost = _placing_outpost
		_dirty = true)
	rule.add_child(_outpost_button)
	rule.add_child(_wrapped(("Founded by hand on ground your explorers have walked, at least "
			+ "%d tiles out. It sends back whatever that country gives - so where you put "
			+ "it is the whole decision.") % int(Balance.OUTPOST_MIN_DISTANCE)))
	_settlement_button = Button.new()
	_settlement_button.pressed.connect(func() -> void:
		# The two placement modes are mutually exclusive - arming one disarms the
		# other, so a click on the map is never ambiguous.
		_placing_settlement = not _placing_settlement
		_placing_outpost = false
		_map.placing_outpost = false
		_map.placing_settlement = _placing_settlement
		_dirty = true)
	rule.add_child(_settlement_button)
	_settlement_note = _wrapped("")
	rule.add_child(_settlement_note)

	rule.add_child(_heading("TRADE"))
	_trade_note = _wrapped("", 12, MUTED)
	rule.add_child(_trade_note)
	var trade_row := HBoxContainer.new()
	trade_row.add_theme_constant_override("separation", 6)
	_trade_sell = OptionButton.new()
	_trade_buy = OptionButton.new()
	for picker in [_trade_sell, _trade_buy]:
		picker.add_item("—", 0)
		for i in Balance.RESOURCE_ORDER.size():
			var rid: String = Balance.RESOURCE_ORDER[i]
			if rid == "knowledge":
				continue
			picker.add_item(String(Balance.RESOURCES[rid]["name"]), i + 1)
	trade_row.add_child(_text("send", 12, MUTED))
	trade_row.add_child(_trade_sell)
	trade_row.add_child(_text("get", 12, MUTED))
	trade_row.add_child(_trade_buy)
	var trade_btn := Button.new()
	trade_btn.text = "Agree"
	trade_btn.pressed.connect(func() -> void:
		var s_id := _picker_resource(_trade_sell)
		var b_id := _picker_resource(_trade_buy)
		Sim.set_trade(s_id, b_id)
		_dirty = true)
	trade_row.add_child(trade_btn)
	rule.add_child(trade_row)
	rule.add_child(_wrapped("A standing exchange with the peoples your explorers found. "
			+ "Sends out a slice of one good's production and brings back another, minus "
			+ "the caravan's cut, for a little gold a day. Set it to nothing to close it."))

	tabs.add_child(_panel_of(rule))

	var tech := _tab_scroll("Knowledge")
	tech.add_child(_toggle("Pursue whatever is cheapest", Sim.auto_research, "",
			func(on: bool) -> void:
				Sim.auto_research = on
				_dirty = true))
	_research_label = _wrapped("", 14, TECHCOL)
	tech.add_child(_research_label)
	_research_bar = ProgressBar.new()
	_research_bar.show_percentage = false
	_research_bar.custom_minimum_size.y = 8
	tech.add_child(_research_bar)
	_tech_list = VBoxContainer.new()
	_tech_list.add_theme_constant_override("separation", 6)
	tech.add_child(_tech_list)
	tabs.add_child(_panel_of(tech))

	return tabs


func _build_log_panel() -> Control:
	var v := _panel()
	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = true
	_log_text.scroll_following = true
	_log_text.custom_minimum_size.y = 92
	v.add_child(_log_text)
	return _panel_of(v)


func _build_decree_cards() -> void:
	for c in _decree_list.get_children():
		c.queue_free()
	var none := Button.new()
	none.text = "No decree (let them get on with it)"
	none.pressed.connect(func() -> void:
		Sim.set_decree("")
		_dirty = true)
	_decree_list.add_child(none)

	for id in Balance.DECREE_ORDER:
		var d: Dictionary = Balance.DECREES[id]
		var v := _card()
		var head := HBoxContainer.new()
		var name_label := _text(d["name"], 14, d["color"])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		v.add_child(head)
		v.add_child(_wrapped(d["desc"]))
		v.add_child(_text(_decree_effect_text(d), 11, GOOD))
		var btn := Button.new()
		btn.text = "Issue this decree"
		btn.pressed.connect(func() -> void:
			Sim.set_decree(id)
			_dirty = true)
		v.add_child(btn)
		var box := _panel_of(v)
		box.set_meta("id", id)
		box.set_meta("btn", btn)
		box.set_meta("name", name_label)
		_decree_list.add_child(box)


func _decree_effect_text(d: Dictionary) -> String:
	var parts: Array[String] = []
	for kind in d.get("boost", {}):
		parts.append("+%d%% %s" % [int(round((float(d["boost"][kind]) - 1.0) * 100.0)),
				_kind_name(kind)])
	if d.has("birth_mult"):
		parts.append("+%d%% births" % int(round((float(d["birth_mult"]) - 1.0) * 100.0)))
	if d.has("housing_mult"):
		parts.append("+%d%% room" % int(round((float(d["housing_mult"]) - 1.0) * 100.0)))
	if d.has("regrowth"):
		parts.append("the land recovers %sx faster" % String.num(float(d["regrowth"]), 1))
	if d.has("territory"):
		parts.append("+%s tiles range" % String.num(float(d["territory"]), 1))
	var costs: Array[String] = []
	for kind in d.get("penalty", {}):
		costs.append("%d%% %s" % [int(round((float(d["penalty"][kind]) - 1.0) * 100.0)),
				_kind_name(kind)])
	var out := ", ".join(parts)
	if not costs.is_empty():
		out += "   paid for with " + ", ".join(costs)
	return out


func _kind_name(kind: String) -> String:
	for job_id in Balance.JOB_ORDER:
		if String(Balance.JOBS[job_id]["kind"]) == kind:
			return String(Balance.JOBS[job_id]["name"]).to_lower()
	return kind


func _picker_resource(picker: OptionButton) -> String:
	var id := picker.get_selected_id()
	if id <= 0:
		return ""
	return String(Balance.RESOURCE_ORDER[id - 1])


# --- Council ----------------------------------------------------------------

## A question with a clock. Ignoring it is a real choice - the elders take the
## safe option, which is never a disaster and never the best.
func _open_council() -> void:
	if Sim.council_id == "" or _council_dialog != null:
		return
	var id := Sim.council_id
	var c: Dictionary = Balance.COUNCIL[id]

	var dlg := AcceptDialog.new()
	_council_dialog = dlg
	dlg.title = String(c["title"])
	dlg.ok_button_text = "Let the elders decide"
	dlg.min_size = Vector2i(560, 340)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	dlg.add_child(v)
	var body := _wrapped(String(c["text"]), 13, TEXT)
	body.custom_minimum_size.x = 500
	v.add_child(body)

	for opt in c["options"]:
		var row := _card()
		var label := String(opt["label"])
		if bool(opt.get("safe", false)):
			label += "   (what they will do anyway)"
		var btn := Button.new()
		btn.text = label
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var choice := String(opt["id"])
		btn.pressed.connect(func() -> void:
			Sim.answer_council(choice)
			dlg.hide())
		row.add_child(btn)
		row.add_child(_wrapped(String(opt["detail"])))
		v.add_child(_panel_of(row))

	dlg.close_requested.connect(func() -> void:
		_council_dialog = null
		dlg.queue_free())
	dlg.confirmed.connect(func() -> void:
		_council_dialog = null
		dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


# --- Dynamic lists ----------------------------------------------------------

func _rebuild_lists() -> void:
	_rebuild_jobs()
	_rebuild_buildings()
	_rebuild_techs()
	_rebuild_upgrades()


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
		var v := _card()

		var head := HBoxContainer.new()
		var name_label := _text(job["name"], 14, job["color"])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)

		var minus := Button.new()
		minus.text = "-"
		minus.custom_minimum_size.x = 30
		minus.pressed.connect(func() -> void:
			Sim.auto_assign = false
			Sim.set_job(id, int(Sim.jobs.get(id, 0)) - 1))
		head.add_child(minus)

		var count := _text("0", 14, ACCENT)
		count.custom_minimum_size.x = 42
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		head.add_child(count)

		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size.x = 30
		plus.pressed.connect(func() -> void:
			Sim.auto_assign = false
			Sim.set_job(id, int(Sim.jobs.get(id, 0)) + 1))
		head.add_child(plus)
		v.add_child(head)

		v.add_child(_wrapped(job["desc"]))
		var yield_label := _text("", 12, MUTED)
		v.add_child(yield_label)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 5.0
		slider.step = 1.0
		slider.value = float(Sim.job_weights.get(id, 1.0))
		slider.custom_minimum_size.y = 14
		slider.tooltip_text = "Priority when work is assigned automatically"
		slider.value_changed.connect(func(val: float) -> void: Sim.job_weights[id] = val)
		v.add_child(slider)

		_job_list.add_child(_panel_of(v))
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
		var v := _card()

		var head := HBoxContainer.new()
		var name_label := _text(b["name"], 14, TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		var owned := _text("", 12, MUTED)
		head.add_child(owned)
		v.add_child(head)

		v.add_child(_wrapped(b["desc"]))
		var gain_label := _text("", 12, GOOD)
		gain_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		gain_label.custom_minimum_size.x = 300
		v.add_child(gain_label)
		var cost_label := _text("", 12, MUTED)
		cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cost_label.custom_minimum_size.x = 300
		v.add_child(cost_label)

		var btn := Button.new()
		btn.text = "Build"
		btn.pressed.connect(func() -> void: Sim.queue_building(id))
		v.add_child(btn)

		var box := _panel_of(v)
		box.set_meta("id", id)
		box.set_meta("owned", owned)
		box.set_meta("btn", btn)
		box.set_meta("cost", cost_label)
		box.set_meta("gain", gain_label)
		_build_list.add_child(box)


func _rebuild_techs() -> void:
	for c in _tech_list.get_children():
		c.queue_free()
	for id in Balance.TECH_ORDER:
		if Sim.techs.has(id) or not Sim.tech_available(id):
			continue
		var t: Dictionary = Balance.TECHS[id]
		var v := _card()
		var head := HBoxContainer.new()
		var name_label := _text(t["name"], 14, TECHCOL)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		head.add_child(_text("%s know." % Balance.fmt(float(t["cost"])), 12, MUTED))
		v.add_child(head)
		v.add_child(_wrapped(t["desc"]))
		var btn := Button.new()
		btn.text = "Pursue this"
		btn.pressed.connect(func() -> void:
			Sim.set_research(id)
			_dirty = true)
		v.add_child(btn)
		_tech_list.add_child(_panel_of(v))


func _rebuild_upgrades() -> void:
	for c in _upgrade_list.get_children():
		c.queue_free()
	_known_upgrades = Sim.available_upgrades()
	for id in _known_upgrades:
		var job_id := Sim.upgrade_job(id)
		if job_id == "":
			continue
		var job: Dictionary = Balance.JOBS[job_id]
		var v := _card()
		var head := HBoxContainer.new()
		var name_label := _text(Sim.upgrade_name(id), 14, job["color"])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		head.add_child(_text("%s know." % Balance.fmt(Sim.upgrade_cost(id)), 12, MUTED))
		v.add_child(head)
		var eff := _wrapped(Sim.upgrade_effect_text(id))
		if Sim.is_branch_tier(int(Sim.upgrade_parts(id)[1])):
			eff.add_theme_color_override("font_color", ACCENT)
			v.add_child(_text("A choice — taking one closes the other", 11, ACCENT))
		v.add_child(eff)
		var btn := Button.new()
		btn.text = "Buy"
		btn.pressed.connect(func() -> void:
			Sim.buy_upgrade(id)
			_dirty = true)
		v.add_child(btn)
		var box := _panel_of(v)
		box.set_meta("id", id)
		box.set_meta("btn", btn)
		_upgrade_list.add_child(box)


func _cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for res in cost:
		parts.append("%s %s" % [Balance.fmt(float(cost[res])), Balance.RESOURCES[res]["name"]])
	return "Costs " + ", ".join(parts)


# --- Refresh ----------------------------------------------------------------

func _refresh() -> void:
	_refresh_summary()
	_refresh_top()
	_refresh_resources()
	_refresh_vitals()
	_refresh_jobs()
	_refresh_buildings()
	_refresh_upgrades()
	_refresh_research()


func _refresh_summary() -> void:
	var world := Sim.world
	var trend := "growing" if Sim.births_per_day > Sim.deaths_per_day else "holding steady"
	# The sustained figure, not the instantaneous one: the settlement dips every
	# night now that people sleep, and "hungry" every dusk is noise.
	if Sim.food_satisfaction_avg < 0.9:
		trend = "hungry"
	elif Sim.water_satisfaction < 0.9:
		trend = "short of water"
	var bits: Array[String] = []
	bits.append("%s people and %s" % [Balance.fmt_count(Sim.population), trend])
	bits.append("land supports %s" % Balance.fmt_count(Sim.carrying_capacity))
	if world != null:
		bits.append("%d%% of the world mapped" % int(world.explored_fraction() * 100.0))
	bits.append("%d techs, %d upgrades" % [Sim.techs.size(), Sim.upgrades.size()])
	if Profile.legacy_points > 0.0:
		bits.append("%s Legacy (+%d%% to everything)" % [Balance.fmt(Profile.legacy_points),
				int(round(Profile.legacy_points * Balance.LEGACY_BONUS_PER_POINT * 100.0))])
	if Sim.omen_active():
		bits.append("omen: everything doubled")
	if Sim.momentum_active():
		bits.append("momentum x%d (+%d%%)" % [Sim.momentum,
				int(round(Sim.momentum * Balance.MOMENTUM_PER_BOON * 100.0))])
	if Sim.festival_active():
		bits.append("festival on")
	if Sim.decree != "":
		bits.append("decree: %s" % Balance.DECREES[Sim.decree]["name"])
	if Sim.trade_sell != "":
		bits.append("trading %s for %s" % [
				String(Balance.RESOURCES[Sim.trade_sell]["name"]).to_lower(),
				String(Balance.RESOURCES[Sim.trade_buy]["name"]).to_lower()])
	if not Sim.outposts.is_empty():
		bits.append("%d outposts" % Sim.outposts.size())
	_summary.text = "  -  ".join(bits)
	if Sim.beat_text != "":
		_plan_label.text = "→  " + Sim.beat_text
		_plan_label.add_theme_color_override("font_color", ACCENT)
	else:
		_plan_label.text = Sim.plan_reason if Sim.auto_assign else "Work assigned by hand."
		_plan_label.add_theme_color_override("font_color", MUTED)

	# Decrees
	var can_switch := Sim.can_set_decree()
	_rule_note.text = ("A decree can be changed again in %d days." % int(ceil(Sim.decree_cooldown))
			) if not can_switch else "Held until you change it. Switching has a cooldown."
	for box in _decree_list.get_children():
		if not box.has_meta("id"):
			continue
		var id: String = box.get_meta("id")
		var active := Sim.decree == id
		(box.get_meta("btn") as Button).disabled = not can_switch or active
		(box.get_meta("btn") as Button).text = "In force" if active else "Issue this decree"
		(box.get_meta("name") as Label).add_theme_color_override("font_color",
				ACCENT if active else Balance.DECREES[id]["color"])

	if Sim.can_hold_festival():
		_festival_button.text = "Hold a festival"
		_festival_button.disabled = false
	elif Sim.festival_cooldown > 0.0:
		_festival_button.text = "Festival (in %d days)" % int(ceil(Sim.festival_cooldown))
		_festival_button.disabled = true
	else:
		_festival_button.text = "Festival (not enough food)"
		_festival_button.disabled = true

	var oc := Sim.outpost_cost()
	_outpost_button.text = ("Click the map to place  (cancel)" if _placing_outpost
			else "Found an outpost  -  %s" % _cost_text(oc).replace("Costs ", ""))
	_outpost_button.disabled = Sim.outposts.size() >= Balance.OUTPOST_MAX

	if Sim.settlement_points > 0:
		_settlement_button.text = ("Click the map to place  (cancel)" if _placing_settlement
				else "Found a settlement  -  %s" % _cost_text(Sim.settlement_cost()).replace("Costs ", ""))
		_settlement_button.disabled = false
		_settlement_note.text = ("%d settlement point%s in hand. A settlement is a second place "
				% [Sim.settlement_points, "" if Sim.settlement_points == 1 else "s"]
				+ "people live: it houses %d of them, claims the land around it and works that "
				% int(Balance.SETTLEMENT_HOUSING)
				+ "ground properly. At least %d tiles out." % int(Balance.SETTLEMENT_MIN_DISTANCE))
	else:
		_settlement_button.text = "Found a settlement  -  no points"
		_settlement_button.disabled = true
		var next_at := 0.0
		for t in Balance.SETTLEMENT_POP_THRESHOLDS:
			if Sim.population < float(t):
				next_at = float(t)
				break
		_settlement_note.text = ("Settlement points are earned by growing. The next comes at "
				+ "%s people." % Balance.fmt_count(next_at)) if next_at > 0.0 \
				else "You have founded everywhere there is to found."
	if Sim.settlements.size() > 0:
		var lines: Array[String] = ["%d founded - %s live in the capital:"
				% [Sim.settlements.size(), Balance.fmt_count(Sim.capital_pop())]]
		for i in Sim.settlements.size():
			lines.append("  town %d: %s people, %.0f%% of its ground worked"
					% [i + 1, Balance.fmt_count(Sim.settlement_pop(i)),
					Sim.settlement_staffing(i) * 100.0])
		_settlement_note.text += "\n" + "\n".join(lines)

	if Sim.can_trade():
		_trade_note.text = ("Currently sending %s and receiving %s." % [
				String(Balance.RESOURCES[Sim.trade_sell]["name"]).to_lower(),
				String(Balance.RESOURCES[Sim.trade_buy]["name"]).to_lower()]
				) if Sim.trade_sell != "" else "No route open."
		_trade_sell.disabled = false
		_trade_buy.disabled = false
	else:
		_trade_note.text = "Needs Coinage, and somebody to trade with."
		_trade_sell.disabled = true
		_trade_buy.disabled = true

	if Sim.council_id != "" and _council_dialog == null:
		_open_council()

	for key in _sparks:
		(_sparks[key] as Sparkline).set_values(Sim.history.get(key, PackedFloat32Array()))

	if Sim.boon_id != "":
		var b: Dictionary = Balance.BOONS[Sim.boon_id]
		_boon_button.text = String(b["name"])
		_boon_button.add_theme_color_override("font_color", b["color"])
		_boon_button.visible = true
	else:
		_boon_button.visible = false

	_legacy_button.visible = Sim.can_ascend() or Profile.legacy_points > 0.0
	_legacy_button.text = ("Legacy +%s" % Balance.fmt(Sim.legacy_on_offer())
			) if Sim.can_ascend() else "Legacy %s" % Balance.fmt(Profile.legacy_points)
	_surge_button.visible = Settings.verbose_log


func _refresh_top() -> void:
	_era_label.text = Sim.era_name()
	_day_label.text = Balance.fmt_clock(Sim.day)
	_pop_label.text = "%s people" % Balance.fmt_count(Sim.population)
	var top := Sim.max_speed_index()
	for i in _speed_buttons.size():
		_speed_buttons[i].button_pressed = (i == Sim.speed_index)
		_speed_buttons[i].disabled = i > top
		_speed_buttons[i].tooltip_text = String(Balance.SPEED_TIPS[i]) if i <= top \
				else "Unlocks in the %s" % Balance.ERAS[Balance.SPEED_UNLOCK_ERA[i]]["name"]
	var season: Dictionary = Balance.SEASONS[Sim.season]
	_season_label.text = String(season["name"])
	_season_label.add_theme_color_override("font_color", season["color"])
	_season_label.tooltip_text = String(season["note"])
	var wx := Sim.weather_info()
	_weather_label.text = String(wx["name"])
	_weather_label.add_theme_color_override("font_color", wx["color"])
	_weather_label.tooltip_text = String(wx["note"])

	# Temperature, the clock's companion: the same two cosines that decide
	# whether snow lies also decide whether it is a pleasant afternoon.
	var c := Sim.temperature()
	_temp_label.text = "%.0f C / %.0f F" % [c, Sim.temperature_f()]
	_temp_label.add_theme_color_override("font_color",
			Color("7fb8e0") if c < 4.0 else (Color("e0a45f") if c > 20.0 else MUTED))
	var sky := "night" if Sim.is_night() else "day"
	_temp_label.tooltip_text = ("Sunrise %s, sunset %s - currently %s.\n"
			% [Balance.fmt_hour(Balance.sunrise_hour(Sim.day)),
			Balance.fmt_hour(Balance.sunset_hour(Sim.day)), sky]
			+ "Reference climate is Seattle: 47.6 north, mild and wet.")
	if Sim.snow_depth > 0.5:
		_temp_label.text += "   %.0fcm snow" % Sim.snow_depth


func _refresh_resources() -> void:
	for id in Balance.RESOURCE_ORDER:
		var row: Dictionary = _resource_rows[id]
		if id == "ore":
			# The store is always "ore"; what that word means moves with the age.
			row["name"].text = Sim.ore_name()
			row["name"].add_theme_color_override("font_color",
					Balance.ORE_TIERS[Sim.ore_tier()]["color"])
		var cap := Sim.capacity_of(id)
		var amount: float = Sim.resources[id]
		if cap > 0.0:
			row["amount"].text = "%s / %s" % [Balance.fmt(amount), Balance.fmt(cap)]
			row["amount"].add_theme_color_override("font_color",
					ACCENT if amount >= cap * 0.995 else TEXT)
		else:
			row["amount"].text = Balance.fmt(amount)
		var rate: float = Sim.rates.get(id, 0.0)
		row["rate"].text = Balance.fmt_rate(rate) + "/d"
		row["rate"].add_theme_color_override("font_color", GOOD if rate >= 0.0 else BAD)
		# Where the number comes from, which is what you need to decide what to
		# build next.
		var from := Sim.rate_breakdown(id)
		var tip := "%s: %s" % [Balance.RESOURCES[id]["name"], from] if from != "" else ""
		if id == "food" and Sim.population > 0.0:
			tip += "\neaten: %s/day" % Balance.fmt(Sim.population * Balance.FOOD_PER_PERSON_PER_DAY)
		elif id == "water" and Sim.population > 0.0:
			tip += "\ndrunk: %s/day" % Balance.fmt(Sim.population * Balance.WATER_PER_PERSON_PER_DAY)
		row["amount"].tooltip_text = tip
		row["rate"].tooltip_text = tip
		row["name"].tooltip_text = tip


func _refresh_vitals() -> void:
	var world := Sim.world
	_vitals["housing"].text = Balance.fmt_count(Sim.housing)
	_vitals["capacity"].text = Balance.fmt_count(Sim.carrying_capacity)
	_vitals["capacity"].add_theme_color_override("font_color",
			GOOD if Sim.carrying_capacity >= Sim.population else BAD)
	_vitals["growth"].text = "%.2f / %.2f" % [Sim.births_per_day, Sim.deaths_per_day]
	_vitals["growth"].add_theme_color_override("font_color",
			GOOD if Sim.births_per_day >= Sim.deaths_per_day else BAD)
	_set_pct(_vitals["fed"], Sim.food_satisfaction)
	_set_pct(_vitals["watered"], Sim.water_satisfaction)

	if world == null:
		return
	_set_pct(_vitals["game"], world.stock_health(world.game, world.game_cap))
	_set_pct(_vitals["forage"], world.stock_health(world.forage, world.forage_cap))
	_set_pct(_vitals["forest"], world.stock_health(world.forest, world.forest_cap))
	_vitals["territory"].text = "%d tiles" % world.territory.size()
	_set_pct(_vitals["explored"], world.explored_fraction())
	if Sim.expansion_blocked_by_exploration():
		_vitals["frontier"].text = "needs scouts"
		_vitals["frontier"].add_theme_color_override("font_color", BAD)
	elif world.frontier_open():
		_vitals["frontier"].text = "%s tiles/day" % Balance.fmt(Sim.tiles_explored_per_day, 2)
		_vitals["frontier"].add_theme_color_override("font_color", TEXT)
	else:
		_vitals["frontier"].text = "all mapped"
		_vitals["frontier"].add_theme_color_override("font_color", GOOD)

	_vitals["plots"].text = "%d" % int(Sim.farm_plots())
	_vitals["lots"].text = "%d" % int(Sim.woodlot_slots())
	_vitals["mines"].text = "%d" % int(Sim.mine_slots())
	_vitals["quarries"].text = "%d" % int(Sim.quarry_slots())


func _set_pct(label: Label, value: float) -> void:
	label.text = "%d%%" % int(round(clampf(value, 0.0, 1.0) * 100.0))
	var c := BAD
	if value > 0.66:
		c = GOOD
	elif value > 0.33:
		c = ACCENT
	label.add_theme_color_override("font_color", c)


func _refresh_jobs() -> void:
	var unlocked: Array[String] = []
	for id in Balance.JOB_ORDER:
		if Sim.job_unlocked(id):
			unlocked.append(id)
	if unlocked != _known_jobs:
		_rebuild_jobs()

	for id in _job_rows:
		var row: Dictionary = _job_rows[id]
		var n: int = Sim.jobs.get(id, 0)
		var cap := Sim.job_capacity(id)
		row["count"].text = str(n) if n <= cap else "%d/%d" % [n, cap]
		row["yield"].text = _job_yield_text(id)
		if not row["slider"].has_focus():
			row["slider"].value = float(Sim.job_weights.get(id, 1.0))


func _job_yield_text(id: String) -> String:
	var each := Sim.job_yield_planned(id)
	match String(Balance.JOBS[id]["kind"]):
		"game", "forage", "farm":
			return "%s food/day  (%s each)" % [Balance.fmt(Sim.job_output(id)), Balance.fmt(each, 2)]
		"forest":
			return "%s wood/day from the wild" % Balance.fmt(Sim.job_output(id))
		"timber":
			var ls := int(Sim.woodlot_slots())
			if ls <= 0:
				return "no woodlot planted yet"
			return "%s wood/day  (%d lots)" % [Balance.fmt(Sim.job_output(id)), ls]
		"water":
			return "%s water/day" % Balance.fmt(Sim.job_output(id))
		"stone":
			var qs := int(Sim.quarry_slots())
			if qs <= 0:
				return "no quarry face to work yet"
			return "%s stone/day  (%d faces)" % [Balance.fmt(Sim.job_output(id)), qs]
		"ore":
			var ms := int(Sim.mine_slots())
			if ms <= 0:
				return "no shaft to work yet"
			return "%s %s/day  (%d shafts)" % [Balance.fmt(Sim.job_output(id)),
					Sim.ore_name().to_lower(), ms]
		"explore":
			return "%s tiles/day" % Balance.fmt(Sim.job_output(id), 2)
		"knowledge":
			return "%s knowledge/day" % Balance.fmt(Sim.job_output(id), 2)
		"build":
			return "%d in the queue" % Sim.build_queue.size()
	return ""


func _refresh_buildings() -> void:
	var unlocked: Array[String] = []
	for id in Balance.BUILDING_ORDER:
		if Sim.building_unlocked(id):
			unlocked.append(id)
	if unlocked != _known_buildings:
		_rebuild_buildings()

	for box in _build_list.get_children():
		var id: String = box.get_meta("id")
		var owned: Label = box.get_meta("owned")
		var cap := Sim.building_max(id)
		var have: int = Sim.buildings.get(id, 0)
		owned.text = "%d" % have if cap <= 0 else "%d / %d" % [have, cap]
		(box.get_meta("cost") as Label).text = _cost_text(Sim.cost_of(id))
		var gain: Label = box.get_meta("gain")
		var effect := Sim.building_effect_text(id)
		var payback := Sim.building_payback_days(id)
		if payback > 0.0:
			effect += "  -  pays for itself in %s days" % Balance.fmt(payback, 1)
		gain.text = effect
		(box.get_meta("btn") as Button).disabled = not Sim.can_build(id)

	# The queue is rebuilt only when it actually changes - it used to be torn
	# down and recreated ten times a second, which is a lot of allocation for a
	# list that is usually two rows long and usually identical.
	var sig := ""
	for o in Sim.build_queue:
		sig += "%s:%d;" % [o["id"], int(float(o["work"]) * 4.0)]
	if sig == _queue_signature:
		return
	_queue_signature = sig
	for c in _queue_list.get_children():
		c.queue_free()
	if Sim.build_queue.is_empty():
		_queue_list.add_child(_text("Nothing being built.", 12, MUTED))
		return
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


func _refresh_upgrades() -> void:
	var offered := Sim.available_upgrades()
	if offered != _known_upgrades:
		_rebuild_upgrades()
	if _upgrade_list.get_child_count() == 0:
		_upgrade_tab_label.text = ("Nothing on offer yet. Upgrades unlock as more people take up "
				+ "a trade, and each one doubles what that trade produces. %d bought so far."
				% Sim.upgrades.size())
	else:
		_upgrade_tab_label.text = ("Each doubles a trade outright. %d bought so far."
				% Sim.upgrades.size())
	for box in _upgrade_list.get_children():
		var id: String = box.get_meta("id")
		(box.get_meta("btn") as Button).disabled = Sim.resources["knowledge"] < Sim.upgrade_cost(id)


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
		return
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


func _append_log(entry: Dictionary) -> void:
	var kind := String(entry.get("kind", "info"))
	if kind == "info" and not Settings.verbose_log and String(entry.get("text", "")).begins_with("Saved"):
		return
	var c := _log_color(kind)
	_log_text.append_text("[color=#%s]Day %d[/color]  [color=#%s]%s[/color]\n" % [
			MUTED.to_html(false), int(entry.get("day", 0)), c.to_html(false),
			String(entry.get("text", ""))])


func _replay_log() -> void:
	_log_text.clear()
	for e in Sim.log_entries:
		_append_log(e)


# --- Actions ----------------------------------------------------------------

func _set_speed(index: int) -> void:
	Sim.speed_index = clampi(index, 0, Balance.SPEEDS.size() - 1)
	_dirty = true


func _on_game_reset() -> void:
	_placing_outpost = false
	_placing_settlement = false
	if _map != null:
		_map.placing_outpost = false
		_map.placing_settlement = false
	_queue_signature = "!"
	_rebuild_lists()
	_replay_log()
	_dirty = true


## The tutorial's one call site. Deliberately a no-op while the flag is off -
## the state machine in Sim runs either way, so this can be turned on and tested
## against a game that has not moved on underneath it.
func _refresh_tutorial() -> void:
	if not Settings.tutorial_enabled:
		return
	var step := Sim.tutorial_current()
	if step.is_empty():
		return
	# Nothing draws it yet. When it does, it wants a small panel anchored near
	# the control named by step["panel"], with the title, the text, a "next"
	# that calls Sim.tutorial_advance() and a "skip" that calls
	# Sim.tutorial_dismiss().
	if Settings.verbose_log:
		print("[tutorial] %s: %s" % [step["id"], step["title"]])


func _on_settings_changed() -> void:
	_fps_label.visible = Settings.show_fps
	get_tree().root.content_scale_factor = Settings.ui_scale
	_dirty = true


# --- New world --------------------------------------------------------------

func _open_new_world() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "A New World"
	dlg.ok_button_text = "Begin"
	dlg.add_cancel_button("Cancel")
	dlg.min_size = Vector2i(520, 420)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	dlg.add_child(v)

	v.add_child(_text("What kind of world?", 15, ACCENT))
	var chosen := {"type": Balance.WorldType.EARTH}
	var group := ButtonGroup.new()
	for info in Balance.WORLD_TYPES:
		var btn := Button.new()
		btn.text = String(info["name"])
		btn.toggle_mode = true
		btn.button_group = group
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.button_pressed = int(info["id"]) == Balance.WorldType.EARTH
		btn.pressed.connect(func() -> void: chosen["type"] = int(info["id"]))
		v.add_child(btn)
		var d := _wrapped(String(info["desc"]))
		d.custom_minimum_size.x = 470
		v.add_child(d)

	# A LineEdit rather than a SpinBox, because the thing people actually have in
	# hand is the line the pause menu gave them - "482913 / Archipelago" - and
	# retyping only the number would silently hand them a different world.
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	seed_row.add_child(_text("Seed", 13, MUTED))
	var seed_edit := LineEdit.new()
	seed_edit.placeholder_text = "blank for a new world"
	seed_edit.custom_minimum_size.x = 240
	seed_row.add_child(seed_edit)
	var paste_btn := Button.new()
	paste_btn.text = "Paste"
	paste_btn.pressed.connect(func() -> void: seed_edit.text = DisplayServer.clipboard_get())
	seed_row.add_child(paste_btn)
	v.add_child(seed_row)
	v.add_child(_wrapped("A seed alone gives you the same land with whichever shape you pick "
			+ "above. A whole copied line - \"482913 / Islands\" - picks the shape too."))

	if Settings.confirm_new_world and Sim.day > 5.0:
		v.add_child(_text("This abandons your current settlement.", 12, BAD))

	dlg.confirmed.connect(func() -> void:
		var parsed := _parse_seed(seed_edit.text, int(chosen["type"]))
		Sim.new_game(int(parsed["seed"]), int(parsed["type"]))
		SaveSystem.save_game()
		_map.view_home())
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


## Read whatever was typed or pasted into the seed box. Accepts a bare number,
## the "seed / Shape" line the pause menu copies, or arbitrary words - which are
## hashed, so "midsummer" is a perfectly good seed and always the same world.
## Change the map overlay from outside the interface. The screenshot tool uses
## it, and going through here keeps the dropdown and the map from disagreeing.
func set_map_filter(index: int) -> void:
	index = clampi(index, 0, Balance.MAP_FILTERS.size() - 1)
	_filter_pick.selected = index
	_filter_pick.item_selected.emit(index)


func _parse_seed(raw: String, fallback_type: int) -> Dictionary:
	var text := raw.strip_edges()
	if text.is_empty():
		return {"seed": 0, "type": fallback_type}

	var world_type := fallback_type
	var number := text
	var slash := text.find("/")
	if slash >= 0:
		number = text.substr(0, slash).strip_edges()
		var shape := text.substr(slash + 1).strip_edges().to_lower()
		for info in Balance.WORLD_TYPES:
			if String(info["name"]).to_lower() == shape:
				world_type = int(info["id"])
				break

	if number.is_valid_int():
		# 0 means "roll one", so a literal typed 0 has to become something else.
		var n := absi(number.to_int())
		return {"seed": (n % 1_000_000) if n != 0 else 1, "type": world_type}

	# Not a number: hash it. Non-zero so it never reads as "random".
	return {"seed": int(hash(number.to_lower()) % 1_000_000) + 1, "type": world_type}


# --- Chronicle --------------------------------------------------------------

## The event log was always a history; it was simply thrown away. This is the
## same data, kept, grouped by era, and readable as a document.
func _open_chronicle() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "The Chronicle"
	dlg.ok_button_text = "Close"
	dlg.min_size = Vector2i(620, 560)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(590, 480)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	scroll.add_child(v)
	dlg.add_child(scroll)

	if Sim.chronicle.is_empty() and Sim.notables.is_empty():
		v.add_child(_wrapped("Nothing worth writing down has happened yet.", 13, MUTED))
	var last_era := -1
	for e in Sim.chronicle:
		var era_i := int(e.get("era", 0))
		if era_i != last_era:
			last_era = era_i
			v.add_child(_text(String(Balance.ERAS[era_i]["name"]), 15, ACCENT))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var day_label := _text("Day %d" % int(e.get("day", 0)), 12, MUTED)
		day_label.custom_minimum_size.x = 66
		row.add_child(day_label)
		var body := _wrapped(String(e.get("text", "")), 13, TEXT)
		body.custom_minimum_size.x = 460
		row.add_child(body)
		v.add_child(row)

	if not Sim.notables.is_empty():
		v.add_child(_heading("PEOPLE WORTH REMEMBERING"))
		for n in Sim.notables:
			v.add_child(_wrapped("%s, %s — %s  (day %d)" % [n.get("name", ""),
					n.get("role", ""), n.get("what", ""), int(n.get("day", 0))], 13, TEXT))

	dlg.close_requested.connect(dlg.queue_free)
	dlg.confirmed.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


# --- Offline digest ---------------------------------------------------------

## What happened while nobody was watching. The data was always recorded; only
## the telling was missing.
func _show_digest() -> void:
	var d := Sim.offline_digest
	Sim.offline_digest = {}
	if d.is_empty() or int(d.get("days", 0)) < 3:
		return
	var dlg := AcceptDialog.new()
	dlg.title = "While You Were Away"
	dlg.ok_button_text = "Carry on"
	dlg.min_size = Vector2i(460, 260)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	dlg.add_child(v)
	v.add_child(_text("%d days passed." % int(d.get("days", 0)), 16, ACCENT))
	v.add_child(_text("The people went from %s to %s." % [
			Balance.fmt_count(float(d.get("pop_before", 0.0))),
			Balance.fmt_count(float(d.get("pop_after", 0.0)))], 14, TEXT))
	for line in [
		["%d new techs" % int(d.get("techs", 0)), int(d.get("techs", 0)) > 0],
		["%d upgrades bought" % int(d.get("upgrades", 0)), int(d.get("upgrades", 0)) > 0],
		["%d era advanced" % int(d.get("eras", 0)), int(d.get("eras", 0)) > 0],
		["%d%% more of the world mapped" % int(d.get("explored", 0.0)), float(d.get("explored", 0.0)) >= 1.0],
	]:
		if bool(line[1]):
			v.add_child(_text(String(line[0]), 13, GOOD))
	var elders := int(d.get("elders_decided", 0))
	if elders > 0:
		v.add_child(_wrapped("The elders answered %d question%s without you. Their choices are "
				% [elders, "" if elders == 1 else "s"] + "always safe and never the best.",
				13, BAD))
	dlg.close_requested.connect(dlg.queue_free)
	dlg.confirmed.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


# --- Legacy -----------------------------------------------------------------

func _open_legacy() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Legacy"
	dlg.ok_button_text = "Close"
	dlg.min_size = Vector2i(640, 620)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(610, 540)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)
	dlg.add_child(scroll)

	v.add_child(_text("%s Legacy banked" % Balance.fmt(Profile.legacy_points), 17, ACCENT))
	v.add_child(_wrapped("Earned by setting a civilisation down. Spent on things every "
			+ "civilisation after it is born knowing. Legacy survives everything, including "
			+ "starting a new world.", 13, TEXT))

	# --- Ascend ---
	var offer := Sim.legacy_on_offer()
	v.add_child(_heading("SET THIS ONE DOWN"))
	if offer < Balance.LEGACY_MIN_POINTS:
		v.add_child(_wrapped("This civilisation has not yet done enough to be worth "
				+ "remembering. Keep going.", 13, MUTED))
	else:
		v.add_child(_wrapped("Everything standing is lost — the buildings, the fields, the "
				+ "people, the map. What survives is what they worked out.", 13, TEXT))
		v.add_child(_text("Worth %s Legacy, for a total of %s (+%d%% to every trade)."
				% [Balance.fmt(offer), Balance.fmt(Profile.legacy_points + offer),
				int(round((Profile.legacy_points + offer) * Balance.LEGACY_BONUS_PER_POINT * 100.0))],
				14, GOOD))
		var row := HBoxContainer.new()
		row.add_child(_text("Next world", 13, MUTED))
		var picker := OptionButton.new()
		for i in Balance.WORLD_TYPES.size():
			picker.add_item(String(Balance.WORLD_TYPES[i]["name"]), i)
		picker.selected = Sim.world.world_type if Sim.world != null else 0
		row.add_child(picker)
		var go := Button.new()
		go.text = "Set them down"
		go.pressed.connect(func() -> void:
			Sim.ascend(picker.get_selected_id())
			SaveSystem.save_game()
			_map.view_home()
			dlg.hide())
		row.add_child(go)
		v.add_child(row)

	# --- Perks ---
	v.add_child(_heading("WHAT THE NEXT ONE WILL KNOW"))
	for id in Balance.LEGACY_PERK_ORDER:
		var perk: Dictionary = Balance.LEGACY_PERKS[id]
		var card := _card()
		var head := HBoxContainer.new()
		var owned := Profile.has_perk(id)
		var name_label := _text(String(perk["name"]), 14, GOOD if owned else ACCENT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(name_label)
		head.add_child(_text("%d" % int(perk["cost"]), 13, MUTED))
		card.add_child(head)
		card.add_child(_wrapped(String(perk["desc"])))
		if owned:
			card.add_child(_text("Known for ever.", 12, GOOD))
		else:
			var buy := Button.new()
			buy.text = "Learn it (%d Legacy)" % int(perk["cost"])
			buy.disabled = not Profile.can_buy_perk(id)
			buy.pressed.connect(func() -> void:
				if Profile.buy_perk(id):
					Sim._mods_dirty = true
					dlg.queue_free()
					_open_legacy()
				_dirty = true)
			card.add_child(buy)
		v.add_child(_panel_of(card))

	# --- Achievements ---
	v.add_child(_heading("THINGS DONE"))
	for id in Balance.ACHIEVEMENT_ORDER:
		var a: Dictionary = Balance.ACHIEVEMENTS[id]
		var got := Profile.achievements.has(id)
		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 10)
		var mark := _text("✓" if got else "·", 14, GOOD if got else MUTED)
		mark.custom_minimum_size.x = 18
		row2.add_child(mark)
		var col := VBoxContainer.new()
		col.add_child(_text(String(a["name"]), 13, TEXT if got else MUTED))
		col.add_child(_wrapped(String(a["desc"]), 11, MUTED))
		row2.add_child(col)
		v.add_child(row2)

	dlg.close_requested.connect(dlg.queue_free)
	dlg.confirmed.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


# --- Settings ---------------------------------------------------------------

func _open_settings() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Settings"
	dlg.ok_button_text = "Done"
	dlg.min_size = Vector2i(560, 620)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(540, 560)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	scroll.add_child(v)
	dlg.add_child(scroll)

	# The seed is the one thing in a procedural game worth carrying out of it -
	# to hand somebody the same world, or to come back to this one later.
	v.add_child(_heading("THIS WORLD"))
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	var seed_field := LineEdit.new()
	seed_field.text = Sim.seed_string()
	seed_field.editable = false
	seed_field.custom_minimum_size.x = 240
	seed_field.tooltip_text = "The seed and shape that made this map."
	seed_row.add_child(seed_field)
	var copy_btn := Button.new()
	copy_btn.text = "Copy"
	var copied := _text("", 12, GOOD)
	copy_btn.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(Sim.seed_string())
		copied.text = "copied")
	seed_row.add_child(copy_btn)
	seed_row.add_child(copied)
	v.add_child(seed_row)
	v.add_child(_wrapped("Paste this whole line into New World to settle the same map again - "
			+ "it carries the shape as well as the number."))

	v.add_child(_heading("AUDIO"))
	v.add_child(_slider_row("Master volume", Settings.master_volume, 0.0, 1.0, 0.05,
			func(x: float) -> void:
				Settings.master_volume = x
				Settings.apply_display()))
	v.add_child(_slider_row("Music", Settings.music_volume, 0.0, 1.0, 0.05,
			func(x: float) -> void: Settings.music_volume = x))
	v.add_child(_slider_row("Sound effects", Settings.sfx_volume, 0.0, 1.0, 0.05,
			func(x: float) -> void: Settings.sfx_volume = x))
	v.add_child(_toggle("Mute everything", Settings.muted, "",
			func(on: bool) -> void:
				Settings.muted = on
				Settings.apply_display()))

	v.add_child(_heading("DISPLAY"))
	v.add_child(_toggle("Fullscreen", Settings.fullscreen, "",
			func(on: bool) -> void:
				Settings.fullscreen = on
				Settings.apply_display()))
	v.add_child(_toggle("Vertical sync", Settings.vsync,
			"Off uncaps the frame rate. This game does not need it.",
			func(on: bool) -> void:
				Settings.vsync = on
				Settings.apply_display()))
	v.add_child(_slider_row("Interface scale", Settings.ui_scale, 0.75, 1.75, 0.05,
			func(x: float) -> void:
				Settings.ui_scale = x
				get_tree().root.content_scale_factor = x))
	v.add_child(_toggle("Show frame rate", Settings.show_fps, "",
			func(on: bool) -> void:
				Settings.show_fps = on
				_fps_label.visible = on))
	v.add_child(_toggle("Reduce motion", Settings.reduce_motion,
			"Stops the wildlife wandering and slows map redraws. Also the lightest setting on a weak machine.",
			func(on: bool) -> void: Settings.reduce_motion = on))
	v.add_child(_toggle("High contrast map", Settings.high_contrast,
			"Lifts unwatched ground out of the murk on low-contrast displays.",
			func(on: bool) -> void: Settings.high_contrast = on))

	v.add_child(_heading("GAME"))
	var dis_row := HBoxContainer.new()
	var dis_label := _text("Natural disasters", 13, TEXT)
	dis_label.custom_minimum_size.x = 200
	dis_row.add_child(dis_label)
	var dis_pick := OptionButton.new()
	for i in Balance.DISASTER_FREQUENCY.size():
		dis_pick.add_item(String(Balance.DISASTER_FREQUENCY[i]["name"]), i)
	dis_pick.selected = clampi(Settings.disaster_frequency, 0, Balance.DISASTER_FREQUENCY.size() - 1)
	dis_pick.item_selected.connect(func(i: int) -> void: Settings.disaster_frequency = i)
	dis_row.add_child(dis_pick)
	v.add_child(dis_row)
	v.add_child(_wrapped("Forest fires, floods, hurricanes and tornados. Off by default. "
			+ "Setbacks only - the never-lose floor still holds underneath them."))
	v.add_child(_toggle("Write a CSV of every day", Settings.csv_logging,
			"One row per in-game day to user://civamation_log.csv - population, every resource, "
			+ "every job. For settling balance arguments with a spreadsheet.",
			func(on: bool) -> void: Settings.csv_logging = on))
	v.add_child(_slider_row("Autosave every (seconds)", Settings.autosave_seconds, 5.0, 120.0, 5.0,
			func(x: float) -> void: Settings.autosave_seconds = x))
	v.add_child(_toggle("Warn before abandoning a world", Settings.confirm_new_world, "",
			func(on: bool) -> void: Settings.confirm_new_world = on))
	v.add_child(_toggle("Verbose event log", Settings.verbose_log,
			"Logs everything the settlement does. Noisy, and exactly what you want when testing a balance change.",
			func(on: bool) -> void: Settings.verbose_log = on))

	v.add_child(_heading("CONTROLS"))
	v.add_child(_wrapped("Space or the View button pauses. [ and ] or the shoulder buttons "
			+ "change speed. The map scrolls to zoom and drags to pan. Every control is "
			+ "reachable with a gamepad."))

	# Cheats. Openly labelled rather than hidden behind a key sequence: this is a
	# game about watching a number go up, and the fastest way to find out whether
	# a system is any fun is to give yourself the thing and try it.
	v.add_child(_heading("CHEATS"))
	var cheat_row := HBoxContainer.new()
	cheat_row.add_theme_constant_override("separation", 8)
	var grant := Button.new()
	grant.text = "Grant a settlement point"
	var granted := _text("", 12, GOOD)
	grant.pressed.connect(func() -> void:
		Sim.grant_settlement_point()
		granted.text = "%d in hand" % Sim.settlement_points
		_dirty = true)
	cheat_row.add_child(grant)
	cheat_row.add_child(granted)
	v.add_child(cheat_row)
	v.add_child(_wrapped("Settlement points are normally earned by growing - the first at "
			+ "%s people. This hands you one now so the system can be tried out."
			% Balance.fmt_count(float(Balance.SETTLEMENT_POP_THRESHOLDS[0]))))

	# How much to hand over. One box drives both buttons, because the useful
	# question is nearly always "give me enough of everything to try the thing"
	# rather than a per-resource negotiation.
	var amount_row := HBoxContainer.new()
	amount_row.add_theme_constant_override("separation", 8)
	amount_row.add_child(_text("Amount", 13, MUTED))
	var amount := SpinBox.new()
	amount.min_value = 1
	amount.max_value = 1_000_000_000
	amount.step = 100
	amount.value = 1000
	amount.custom_minimum_size.x = 150
	amount_row.add_child(amount)
	v.add_child(amount_row)

	var give_row := HBoxContainer.new()
	give_row.add_theme_constant_override("separation", 8)
	var gave := _text("", 12, GOOD)

	var give_res := Button.new()
	give_res.text = "Add to every resource"
	give_res.pressed.connect(func() -> void:
		Sim.cheat_add_resources(amount.value)
		gave.text = "+%s of each" % Balance.fmt_count(amount.value)
		_dirty = true)
	give_row.add_child(give_res)

	var give_pop := Button.new()
	give_pop.text = "Add people"
	give_pop.pressed.connect(func() -> void:
		Sim.cheat_add_population(amount.value)
		gave.text = "%s people" % Balance.fmt_count(Sim.population)
		_dirty = true)
	give_row.add_child(give_pop)
	give_row.add_child(gave)
	v.add_child(give_row)
	v.add_child(_wrapped("Knowledge is included, so this will also unlock research. Added "
			+ "people raise the high-water mark straight away, so the never-lose floor "
			+ "will hold them there even if the land cannot feed them yet."))

	v.add_child(_heading("ARTWORK"))
	var reset_row := HBoxContainer.new()
	var art_row := HBoxContainer.new()
	var art_btn := Button.new()
	art_btn.text = "Reload artwork"
	art_btn.tooltip_text = ("Rescans assets/ and user://assets/. Drop sprites in and press "
			+ "this - nothing needs restarting. See assets/README.md.")
	art_btn.pressed.connect(func() -> void:
		Art.reload()
		for id in _resource_rows:
			var icon: TextureRect = _resource_rows[id]["icon"]
			icon.texture = Art.resource_icon(id)
			icon.visible = icon.texture != null
		_dirty = true)
	art_row.add_child(art_btn)
	art_row.add_child(_text("%d replacement textures loaded" % Art.count(), 12, MUTED))
	v.add_child(art_row)

	v.add_child(_heading("DANGER"))
	var defaults := Button.new()
	defaults.text = "Restore defaults"
	defaults.pressed.connect(func() -> void:
		Settings.reset_to_defaults()
		dlg.queue_free()
		_open_settings())
	reset_row.add_child(defaults)
	var wipe := Button.new()
	wipe.text = "Delete save and restart"
	wipe.pressed.connect(func() -> void:
		SaveSystem.delete_save()
		Sim.new_game(0, Balance.WorldType.EARTH)
		SaveSystem.save_game()
		dlg.hide())
	reset_row.add_child(wipe)
	v.add_child(reset_row)

	dlg.confirmed.connect(Settings.save_settings)
	dlg.canceled.connect(Settings.save_settings)
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _slider_row(label: String, value: float, lo: float, hi: float, step: float,
		on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := _text(label, 13, TEXT)
	l.custom_minimum_size.x = 200
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size.x = 220
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)
	var readout := _text(String.num(value, 2), 12, MUTED)
	readout.custom_minimum_size.x = 48
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(readout)
	s.value_changed.connect(func(x: float) -> void:
		readout.text = String.num(x, 2)
		on_change.call(x))
	return row
