extends SceneTree

const SidePanelScene := preload("res://scenes/ui/side_panel.tscn")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	var panel = SidePanelScene.instantiate()
	root.add_child(panel)
	await process_frame

	var catalog = BuildingDefinitionCatalogScript.new()
	var ids := catalog.buildable_ids_for_house(&"Atreides", [&"Fremen"])
	ids.append_array(catalog.wall_ids_for_house(&"Atreides", [&"Fremen"]))
	panel.configure_building_options(ids)
	panel._set_active_tab(SidePanel.Tab.BUILDINGS)

	var building_ids: Array = panel._building_ids_for_tab(SidePanel.Tab.BUILDINGS)
	_expect(building_ids.has(&"HKBarracks"), "the panel retains the Harkonnen tree")
	_expect(building_ids.has(&"ORBarracks"), "the panel retains the Ordos tree")
	_expect(building_ids.size() > SidePanel.QUEUE_PAGE_SIZE, "the combined roster spans multiple pages")
	_expect(panel._page_previous.visible and panel._page_next.visible, "page controls appear for a long roster")

	var target_index := building_ids.find(&"ORBarracks")
	var target_page := floori(float(target_index) / float(SidePanel.QUEUE_PAGE_SIZE))
	panel._pages_by_tab[SidePanel.Tab.BUILDINGS] = target_page
	panel._rebuild_queue_grid()
	_expect(panel._slot_for(SidePanel.OptionKind.BUILDING, &"ORBarracks") != null, "an Ordos option is reachable on its page")

	panel.configure_ordered_roster(ids, [&"Atreides"], [&"Fremen"])
	building_ids = panel._building_ids_for_tab(SidePanel.Tab.BUILDINGS)
	_expect(
		building_ids.slice(0, 3) == [&"ATSmWindtrap", &"ATBarracks", &"ATWall"],
		"the first building row follows Rules.txt: Windtrap, Barracks, Wall"
	)
	_expect(
		building_ids.slice(12, 15).has(&"FRCamp"),
		"selected sub-house buildings occupy the dynamic final row"
	)

	panel.configure_ordered_roster(ids, [&"Atreides", &"Harkonnen"], [&"Fremen"])
	building_ids = panel._building_ids_for_tab(SidePanel.Tab.BUILDINGS)
	_expect(
		building_ids.slice(SidePanel.QUEUE_PAGE_SIZE, SidePanel.QUEUE_PAGE_SIZE + 3)
		== [&"", &"HKBarracks", &""],
		"a captured House keeps authored cells while grouped duplicates stay hidden"
	)

	# The building and upgrade families disagree about what DISABLED does to a
	# slot, and that asymmetry is the whole reason they are not one code path:
	# a building roster position is an authored address that must keep its cell,
	# while an upgrade simply stops being offered.
	panel._pages_by_tab[SidePanel.Tab.BUILDINGS] = 0
	panel._rebuild_queue_grid()
	panel.set_building_option_state(
		BuildingOptionStateScript.new(
			&"ATBarracks", BuildingOptionStateScript.State.DISABLED, 0.0, "", "Needs power"
		)
	)
	var building_slot = panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATBarracks")
	_expect(
		building_slot != null and building_slot.visible,
		"a disabled building slot keeps its authored cell"
	)
	_expect(
		building_slot.state == QueueSlot.State.DISABLED
		and building_slot.tooltip_text == "Needs power",
		"a disabled building slot still shows why it is unavailable"
	)
	panel.set_building_option_state(
		BuildingOptionStateScript.new(
			&"ATBarracks", BuildingOptionStateScript.State.PLACING, 100.0, "BUILDING", "Placing"
		)
	)
	_expect(
		building_slot.state == QueueSlot.State.PLACING and building_slot.status_text == "BUILDING",
		"a placing building slot translates its state and caption without the disabled fallback"
	)
	var placing_intents: Array = []
	building_slot.intent_pressed.connect(
		func(button_index: int, quantity: int) -> void: placing_intents.append([button_index, quantity])
	)
	# Set the widget state directly so this click guard remains independently
	# covered when the state-translation case above is deliberately mutated.
	building_slot.state = QueueSlot.State.PLACING
	building_slot._gui_input(_pressed_mouse_button(MOUSE_BUTTON_LEFT))
	building_slot._gui_input(_pressed_mouse_button(MOUSE_BUTTON_RIGHT))
	_expect(placing_intents.is_empty(), "a placing slot emits no left or right intent")
	placing_intents.clear()
	building_slot.state = QueueSlot.State.BLOCKED
	building_slot._gui_input(_pressed_mouse_button(MOUSE_BUTTON_LEFT))
	building_slot._gui_input(_pressed_mouse_button(MOUSE_BUTTON_RIGHT))
	_expect(
		placing_intents.map(func(intent: Array) -> int: return intent[0])
		== [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT],
		"a blocked slot still emits both intents for busy feedback"
	)

	var upgrade_ids: Array[StringName] = []
	for index in SidePanel.QUEUE_PAGE_SIZE + 1:
		upgrade_ids.append(&"ATBarracks" if index == SidePanel.QUEUE_PAGE_SIZE else StringName("Upgrade%d" % index))
	panel.configure_upgrade_options(upgrade_ids)
	panel._set_active_tab(SidePanel.Tab.UPGRADES)
	_expect(panel._page_previous.visible and panel._page_next.visible, "upgrade options paginate independently")
	panel._pages_by_tab[SidePanel.Tab.UPGRADES] = 1
	panel._rebuild_queue_grid()
	var upgrade_slot = panel._slot_for(SidePanel.OptionKind.UPGRADE, &"ATBarracks")
	_expect(upgrade_slot != null, "an upgrade on the second page is reachable")
	var disabled_state = BuildingOptionStateScript.new(
		&"ATBarracks", BuildingOptionStateScript.State.DISABLED, 0.0, "", "Unavailable"
	)
	panel.set_upgrade_option_state(disabled_state)
	_expect(not upgrade_slot.visible, "a disabled upgrade slot is hidden")

	# Slots are rebuilt from scratch on every page turn and tab switch, so the
	# stored state has to be re-applied to the fresh slot rather than surviving
	# on the old one.
	panel._rebuild_queue_grid()
	upgrade_slot = panel._slot_for(SidePanel.OptionKind.UPGRADE, &"ATBarracks")
	_expect(
		upgrade_slot != null and not upgrade_slot.visible,
		"a rebuilt upgrade slot re-applies its stored state"
	)
	panel.set_upgrade_option_state(
		BuildingOptionStateScript.new(
			&"ATBarracks", BuildingOptionStateScript.State.PROGRESS, 40.0, "40%", "Upgrading"
		)
	)
	_expect(
		upgrade_slot.visible
		and upgrade_slot.state == QueueSlot.State.PROGRESS
		and is_equal_approx(upgrade_slot.progress, 40.0)
		and upgrade_slot.status_text == "40%",
		"an upgrade slot shows the progress of its running upgrade"
	)

	# The upgrade grid shares its slots with the building tabs, so an upgrade
	# update that arrives while another tab is shown must not paint over the
	# building occupying the same cell.
	panel._set_active_tab(SidePanel.Tab.BUILDINGS)
	panel._pages_by_tab[SidePanel.Tab.BUILDINGS] = 0
	panel._rebuild_queue_grid()
	var shared_slot = panel.get_slot(0)
	var building_tooltip: String = shared_slot.tooltip_text
	panel.set_upgrade_option_state(
		BuildingOptionStateScript.new(
			&"Upgrade0", BuildingOptionStateScript.State.PROGRESS, 90.0, "90%", "Upgrading"
		)
	)
	_expect(
		shared_slot.tooltip_text == building_tooltip and not is_equal_approx(shared_slot.progress, 90.0),
		"an upgrade update is ignored while a building tab owns the grid"
	)
	panel._set_active_tab(SidePanel.Tab.UPGRADES)
	panel._pages_by_tab[SidePanel.Tab.UPGRADES] = 1
	panel._rebuild_queue_grid()

	var emitted_upgrades: Array[StringName] = []
	panel.upgrade_intent_pressed.connect(
		func(upgrade_id: StringName, _button_index: int): emitted_upgrades.append(upgrade_id)
	)
	panel._on_slot_pressed(MOUSE_BUTTON_LEFT, 1, 0)
	_expect(emitted_upgrades == [&"ATBarracks"], "an upgrade click emits the paged upgrade id")

	panel.free()
	if _failures > 0:
		printerr("SidePanel pagination tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("SidePanel pagination tests: %d assertions passed" % _assertions)
	quit(0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)


func _pressed_mouse_button(button_index: int) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	return event
