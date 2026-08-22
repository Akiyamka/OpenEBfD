extends Node3D

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const BuildingUpgradeControllerScript := preload("res://scripts/buildings/building_upgrade_controller.gd")
const UnitCommandControllerScript := preload("res://scripts/match/unit_command_controller.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const FrameTickDriverScript := preload("res://scripts/match/frame_tick_driver.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const CommandExecutorScript := preload("res://scripts/match/command_executor.gd")
const UnitDeploymentControllerScript := preload("res://scripts/units/unit_deployment_controller.gd")
const UnitRosterControllerScript := preload("res://scripts/units/unit_roster_controller.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const UnitNavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const NavigationGridDebugScript := preload("res://scripts/units/navigation/navigation_grid_debug.gd")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const ReplayRecorderScript := preload("res://scripts/match/replay_recorder.gd")
const ReplayPlayerScript := preload("res://scripts/match/replay_player.gd")
const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const AbilityBarScript := preload("res://scripts/ui/ability_bar.gd")
const AdvancedCarryallAbilityScript := preload("res://scripts/match/advanced_carryall_ability.gd")
const PLACEMENT_ARROW_SCENE := preload("res://assets/converted/placement/build_arrow.scn")
const PLACEMENT_BUILDING_SCENE := preload("res://assets/converted/placement/build_building.scn")
const PLACEMENT_CANT_BUILD_SCENE := preload("res://assets/converted/placement/build_cantbuild.scn")
const PLACEMENT_SKIRT_SCENE := preload("res://assets/converted/placement/build_skirt.scn")
const PLACEMENT_WALL_SCENE := preload("res://assets/converted/placement/build_wall.scn")
const LOCAL_PLAYER_ID := 1
const ENEMY_PLAYER_ID := 2

@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var camera_rig: Node3D = $CameraRig
@onready var terrain: MapLoader = $Terrain
@onready var selection_label: Label = $HUD/Selection
@onready var selection_rectangle = $HUD/SelectionRectangle
@onready var fps_label: Label = $HUD/FPS
@onready var side_panel: SidePanel = $HUD/SidePanel
@onready var ability_bar: AbilityBar = get_node_or_null("HUD/AbilityBar") as AbilityBar

var _fps_update_time := 0.0
var _clock: MatchClock
var _tick_driver: FrameTickDriver
## Owned alongside _entity_index (see that field's comment) for the same
## reason: this is the phase 2 spine everything else in the command path is
## built on. _command_executor is constructed with _entity_index because
## resolving a command's entity ids to Nodes is the one thing the sim-zone
## bus itself may never do -- see scripts/match/command_executor.gd. It is
## also constructed with _unit_navigation_system, _unit_deployment_controller,
## terrain and _target_ability_handlers -- Move's, Deploy's and target
## abilities' collaborators, none of which Stop ever needed -- which is why
## its construction is deferred past _setup_unit_navigation_system() and
## _setup_unit_deployment_controller() in _ready() rather than sitting next
## to _command_bus's.
var _command_bus: SimCommandBus
## Off by default (see ReplayRecorder's doc comment,
## scripts/match/replay_recorder.gd) -- nothing in this file calls start()
## on it. It is still constructed unconditionally here, alongside
## _command_bus, so _advance_simulation_tick() has a stable, never-null
## place to hand drained commands to; record_tick() is a no-op until
## something outside this file calls start().
var _replay_recorder: ReplayRecorder
## Off by default for the identical reason _replay_recorder is (see that
## field's comment): nothing in this file calls load() on it. Constructed
## unconditionally here too, so _advance_simulation_tick() has a stable,
## never-null place to ask for this tick's recorded commands; play_tick() is
## a no-op until something outside this file calls load(). See
## ReplayPlayer's own doc comment (scripts/match/replay_player.gd) for why a
## live player's input is not suppressed while this is active -- there is no
## UI yet that could make both happen at once.
var _replay_player: ReplayPlayer
var _command_executor: CommandExecutor
var _building_controller: BuildingController
var _building_upgrade_controller: BuildingUpgradeController
var _unit_command_controller: UnitCommandController
var _unit_deployment_controller
var _unit_navigation_system
var _navigation_grid_debug
var _debug_layers_enabled := false
## Whole roster of the local player's house, gated by the technology tree
## rather than a hardcoded demo list -- see docs/mechanics/production.md.
var _building_option_ids: Array[StringName] = []
## Walls are mixed into the constructible roster; upgrades use their own rules
## roster because it also includes deployed Construction Yards and refinery
## docks. Both special building types still route through map-picking flows.
var _wall_building_ids: Array[StringName] = []
var _upgrade_option_ids: Array[StringName] = []
## Units share the building grid's tabs (Infantry/Vehicles via art
## sidebar_type); their availability is gated by the same technology tree
## through UnitRosterController.
var _unit_option_ids: Array[StringName] = []
var _unit_roster_controller: UnitRosterController
var _sidebar_house_pages: Array[StringName] = []
static var _unit_definition_catalog := UnitSceneCatalogScript.shared()
static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()
var _match_snapshot
## Binds stable entity ids (scripts/sim/entity_registry.gd) to the units and
## buildings that carry them. Created in _enter_tree(), not _ready(): the
## engine runs _enter_tree() top-down for a whole freshly-added subtree
## before any node in it reaches _ready(), and every Unit/Building looks
## itself up (via MatchLookupScript.entity_index()) from its own _ready() --
## see that comment below.
var _entity_index: EntityNodeIndex
## The flat hot-state position store slice C1 built (scripts/sim/entity_state.gd)
## and slice C2 wires in: decision 3 ("Simulation core owns state; nodes are
## views"). Constructed here, immediately after _entity_index and for the
## identical reason -- it takes the registry _entity_index owns
## (SimEntityState._init() wants a SimEntityRegistry by reference so it can ask
## is_alive() rather than keep a second copy of that bookkeeping) -- so it must
## exist before any child's _ready() can reach it via
## MatchLookupScript.entity_state(), the same route entity_state() itself
## follows for the node index. See _entity_index's own comment for why
## _enter_tree() and not _ready(): units and buildings self-register (and, as
## of C2, write their position) from their own _ready(), which the engine runs
## only after _enter_tree() has finished for the whole freshly-added subtree.
var _entity_state: SimEntityState
## Shared between _command_executor and _unit_command_controller (see both
## setup call sites below) so a target ability id resolves to the same
## handler on both sides of the command bus -- SelectionTargetAbilityController.
## handler_for() (scripts/match/selection_target_ability_controller.gd) is
## the shared lookup; this is the shared list it is asked to search. Built
## once here rather than as two separate `[AdvancedCarryallAbilityScript.new()]`
## literals, which would hand each side its own instance -- harmless for this
## stateless handler today, but a second instance is not "the same handler",
## and nothing here should have to reason about whether that distinction
## matters.
var _target_ability_handlers: Array = [AdvancedCarryallAbilityScript.new()]


func _enter_tree() -> void:
	# Both of these must exist before any child's _ready() runs: units and
	# buildings self-register into _entity_index from their own _ready(), and
	# they find this Match through MatchLookupScript.entity_index(), which
	# looks up MatchLookupScript.GROUP. _enter_tree() fires top-down for the
	# whole freshly-added subtree before any node in it reaches _ready(), so
	# both are set up here rather than there -- see the same reasoning below
	# for why _configure_demo_players() also cannot wait for _ready().
	add_to_group(MatchLookupScript.GROUP)
	_entity_index = EntityNodeIndexScript.new()
	_entity_state = SimEntityStateScript.new(_entity_index.registry())
	# Children initialize their owner visuals in _ready(), so the player
	# roster must exist before buildings and units enter the scene tree.
	# The Rules autoload's catalog, in contrast, only loads in its own
	# _ready() -- _enter_tree() fires for the whole tree before any _ready()
	# does, so a Rules-dependent roster computed here would always read an
	# empty catalog. That computation is deferred to _ready() below instead.
	_configure_demo_players()


func _ready() -> void:
	_clock = MatchClockScript.new()
	_tick_driver = FrameTickDriverScript.new()
	_command_bus = SimCommandBusScript.new()
	_replay_recorder = ReplayRecorderScript.new()
	_replay_player = ReplayPlayerScript.new()
	_match_snapshot = MatchSnapshotScript.new(_snapshot_storage_path())
	_restore_saved_startup_state()
	_building_option_ids = _local_player_building_option_ids()
	_wall_building_ids = _local_player_wall_building_ids()
	_upgrade_option_ids = _local_player_upgrade_option_ids()
	_unit_option_ids = _local_player_unit_option_ids()
	_sidebar_house_pages = [_local_player_house_id()]
	_setup_unit_navigation_system()
	_setup_navigation_grid_debug()
	_setup_unit_deployment_controller()
	_setup_unit_command_controller()
	_setup_building_controller()
	_setup_building_upgrade_controller()
	_setup_unit_roster_controller()
	# Built last, once every collaborator it dispatches to exists: Move needs
	# the navigation system and the deployment controller, and the three queue
	# order types need the controllers that own those queues. It is only ever
	# used from _advance_simulation_tick(), so nothing above needs it earlier,
	# and one construction with everything present beats a setter someone can
	# forget to call.
	_command_executor = CommandExecutorScript.new(
		_entity_index,
		_unit_navigation_system,
		_unit_deployment_controller,
		terrain,
		_target_ability_handlers,
		_building_controller,
		_unit_roster_controller,
		_building_upgrade_controller
	)
	_update_selection_label()
	_update_fps_label()
	_place_on_map()


func _on_panel_command(command: StringName) -> void:
	if _building_controller != null and _building_controller.handle_command(command):
		return
	if _building_upgrade_controller != null and _building_upgrade_controller.handle_command(command):
		return
	_update_selection_label("Command: %s (not implemented)" % command)


func _on_panel_building_intent(building_id: StringName, button_index: int, quantity: int) -> void:
	if _building_controller != null and _building_controller.handle_building_intent(building_id, button_index):
		return
	if _unit_roster_controller != null:
		_unit_roster_controller.handle_unit_intent(building_id, button_index, quantity)


func _on_panel_upgrade_intent(upgrade_id: StringName, button_index: int) -> void:
	if _building_upgrade_controller != null:
		_building_upgrade_controller.handle_upgrade_intent(upgrade_id, button_index)


func _on_building_resources_changed(credits: int, energy: int) -> void:
	side_panel.set_credits(credits)
	side_panel.set_energy(energy)


func _setup_building_controller() -> void:
	var building_grid_ids := _building_option_ids + _wall_building_ids
	# Units live in the same grid as buildings -- the panel sorts every id
	# into its tab by art sidebar_type -- but only building ids go to
	# BuildingController below; unit clicks route to UnitRosterController.
	side_panel.configure_ordered_roster(
		building_grid_ids + _unit_option_ids, _sidebar_house_pages, _local_player_subhouse_ids()
	)
	_building_controller = BuildingControllerScript.new()
	_building_controller.name = "BuildingController"
	add_child(_building_controller)
	side_panel.building_intent_pressed.connect(_on_panel_building_intent)
	side_panel.command_pressed.connect(_on_panel_command)
	_building_controller.status_changed.connect(_update_selection_label)
	_building_controller.resources_changed.connect(_on_building_resources_changed)
	_building_controller.sell_mode_changed.connect(side_panel.set_sell_mode)
	_building_controller.building_option_state_changed.connect(side_panel.set_building_option_state)
	_building_controller.setup(
		terrain,
		camera,
		$Buildings,
		building_grid_ids,
		PLACEMENT_ARROW_SCENE,
		PLACEMENT_BUILDING_SCENE,
		PLACEMENT_CANT_BUILD_SCENE,
		PLACEMENT_SKIRT_SCENE,
		PLACEMENT_WALL_SCENE,
		_command_bus,
		Callable(self, "next_orderable_tick")
	)
	_building_controller.interaction_mode_changed.connect(_on_building_interaction_mode_changed)


func _setup_building_upgrade_controller() -> void:
	_building_upgrade_controller = BuildingUpgradeControllerScript.new()
	_building_upgrade_controller.name = "BuildingUpgradeController"
	add_child(_building_upgrade_controller)
	side_panel.upgrade_intent_pressed.connect(_on_panel_upgrade_intent)
	_building_upgrade_controller.status_changed.connect(_update_selection_label)
	_building_upgrade_controller.upgrade_option_state_changed.connect(side_panel.set_upgrade_option_state)
	_building_upgrade_controller.setup(_upgrade_option_ids, _command_bus, Callable(self, "next_orderable_tick"))
	# setup() filters upgrade_grid_ids down to buildings that actually have
	# an upgrade defined (see BuildingUpgradeController.upgrade_option_ids());
	# the panel grid must be built from that filtered set, not the raw roster,
	# or unfiltered slots default to QueueSlot's normal AVAILABLE look.
	side_panel.configure_upgrade_options(_building_upgrade_controller.upgrade_option_ids())


func _setup_unit_roster_controller() -> void:
	_unit_roster_controller = UnitRosterControllerScript.new()
	_unit_roster_controller.name = "UnitRosterController"
	add_child(_unit_roster_controller)
	_unit_roster_controller.status_changed.connect(_update_selection_label)
	_unit_roster_controller.unit_option_state_changed.connect(side_panel.set_building_option_state)
	_unit_roster_controller.setup(_unit_option_ids, _command_bus, Callable(self, "next_orderable_tick"))


func _setup_unit_command_controller() -> void:
	_unit_command_controller = UnitCommandControllerScript.new()
	_unit_command_controller.name = "UnitCommandController"
	add_child(_unit_command_controller)
	_unit_command_controller.status_changed.connect(_update_selection_label)
	_unit_command_controller.target_ability_mode_changed.connect(_on_target_ability_mode_changed)
	_unit_command_controller.setup(
		camera,
		terrain,
		_unit_navigation_system,
		selection_rectangle,
		_unit_deployment_controller,
		ability_bar,
		_target_ability_handlers,
		_command_bus,
		Callable(self, "next_orderable_tick")
	)


func _setup_unit_deployment_controller() -> void:
	_unit_deployment_controller = UnitDeploymentControllerScript.new()
	_unit_deployment_controller.name = "UnitDeploymentController"
	add_child(_unit_deployment_controller)
	_unit_deployment_controller.setup(
		terrain.navigation_grid, $Buildings, $Units, _unit_navigation_system
	)


func _setup_unit_navigation_system() -> void:
	_unit_navigation_system = UnitNavigationSystemScript.new()
	_unit_navigation_system.name = "UnitNavigationSystem"
	add_child(_unit_navigation_system)
	if terrain.navigation_grid != null:
		_unit_navigation_system.setup(terrain.navigation_grid)
	_unit_navigation_system.set_debug_enabled(_debug_layers_enabled)


func _setup_navigation_grid_debug() -> void:
	_navigation_grid_debug = NavigationGridDebugScript.new()
	_navigation_grid_debug.name = "NavigationGridDebug"
	add_child(_navigation_grid_debug)
	_navigation_grid_debug.setup(terrain, _unit_navigation_system)
	_navigation_grid_debug.set_enabled(_debug_layers_enabled)


func _place_on_map() -> void:
	var center := terrain.map_center()
	camera_rig.set_map_view(center, terrain.map_bounds())

	# Terrain collision is not queryable until the first physics frame.
	await get_tree().physics_frame
	await get_tree().physics_frame
	for building in get_tree().get_nodes_in_group("buildings"):
		if building is Node3D:
			var spot: Vector3 = building.global_position
			building.global_position = _snap_to_ground(spot)

	for unit in get_tree().get_nodes_in_group("units"):
		var spot: Vector3 = unit.global_position
		# Routes through Unit.set_simulation_position() (its own doc comment)
		# rather than writing global_position directly: by this point every
		# scene-authored unit has already run its own _ready() (see
		# _entity_index's and _entity_state's comments on why both are built in
		# _enter_tree(), before any child's _ready() runs), so entity_id is
		# already set and this initial snap-to-ground is this unit's very first
		# write into the running match's SimEntityState.
		unit.set_simulation_position(_snap_to_ground(spot))
		unit.stop_at_current_position()


func _snap_to_ground(point: Vector3) -> Vector3:
	return TerrainProbeScript.snap_to_ground(get_world_3d(), point)


func _process(delta: float) -> void:
	var due := _tick_driver.pending_ticks(delta)
	for _i in due:
		_advance_simulation_tick()

	_refresh_sidebar_house_pages()
	if _building_controller != null:
		_building_controller.process(delta)
	if _unit_command_controller != null:
		_unit_command_controller.process()
	if _building_upgrade_controller != null:
		_building_upgrade_controller.process(delta)
	if _unit_roster_controller != null:
		_unit_roster_controller.process(delta)

	_fps_update_time += delta
	if _fps_update_time >= 0.25:
		_fps_update_time = 0.0
		_update_fps_label()


## The single place a system gets attached to the simulation tick as phase 1
## proceeds -- nothing else may call MatchClock.advance(). The order systems
## are added here is itself part of the simulation: every client's frame rate
## and stall pattern differs, but _process() always calls this once per due
## tick in the same sequence, so a fixed, deliberate order here is what keeps
## every client's tick-by-tick history identical.
##
## Draining and executing due commands (see scripts/sim/command_bus.gd and
## scripts/match/command_executor.gd) is now the first thing this function
## does, before _clock.advance() has given any system below a chance to
## move. A command scheduled for tick T must see the world exactly as it
## stood at the *start* of T -- not as it stands after production queues,
## turret reloads or repair have already advanced that same tick -- or its
## outcome would depend on where in this function the drain happened to be
## called from, which is exactly the kind of order-dependent result lockstep
## cannot let two clients disagree about. This is "commands, then systems",
## and it has to be the same everywhere a tick runs, which is why it is the
## very first line here and not folded into any one system's own advance_tick().
##
## _replay_player.play_tick() runs between _clock.advance() and the drain,
## not before commands-then-systems as a whole -- see its call site's own
## comment and ReplayPlayer's doc comment (scripts/match/replay_player.gd)
## for why a replay's commands must reach the bus before this same drain
## rather than after it.
##
## Every command type goes through CommandExecutor, the three that name a
## production or upgrade queue included. Those have nothing for its
## EntityNodeIndex to resolve and are forwarded straight to the controller
## that owns the queue -- but they are dispatched in the same single place as
## the rest, because two match statements on type_id() would let a new
## command type be registered in one and forgotten in the other, and the
## symptom of that is the command quietly never running at all.
##
## They execute here, before any controller's own advance_tick() below, for
## the same reason every other command does: commands, then systems.
##
## _unit_navigation_system.sim_tick() runs immediately after the command drain
## above, before any of the three controllers below it: navigation is the
## direct consumer of the move commands that loop just executed, so a move
## order targeting this tick is acted on this tick instead of one tick late.
## That is the same "commands, then systems" reasoning the drain's own
## position enforces, applied to the one system commands hand data to
## directly rather than through a controller. Null-guarded like the three
## controllers below it: tests instantiate a match with no navigation grid
## loaded at all.
##
## _building_controller, then _building_upgrade_controller, then
## _unit_roster_controller -- exactly the order these three appeared in
## _process() before this slice split their simulation half out. Within a
## single tick all three compete for the same player's credits (building
## construction/repair, upgrades, and unit production all spend from the same
## PlayerData), and whoever advances first spends first when funds are short:
## reordering them would silently change who gets starved of credits on a
## tight budget, without changing anything else about the simulation.
## Preserving today's order keeps this slice a pure restructuring. In a
## lockstep match this stops being a nice-to-have: every client must resolve
## that credit contention identically, or their simulations diverge.
## _unit_command_controller.process() is input handling, not simulation, and
## stays out of this function -- see its call in _process() instead. Its
## on_command_executed() is different and does belong here: the command
## drain above calls it once per executed command, purely to hand back a
## result (e.g. how many entities actually stopped) for the status label --
## reporting, not deciding, and no more "simulation" than
## _building_controller.status_changed already was before this slice.
## After the three controllers above: units, then linger effects, then
## projectiles, then buildings, then units' own combat pass, then spice
## mounds -- each entity's or system's own sim_tick(). For units that first
## pass is CombatTurret.advance_tick() for reload/burst countdowns,
## locomotion, and (for a harvester) unload credits (see Unit.sim_tick(),
## B2); for linger effects it is CombatLingerEffect.sim_tick() delivering one
## damage tick and decrementing its own countdown (see combat_linger_effect.gd);
## for projectiles it is CombatProjectile.sim_tick() advancing one tick of
## flight and resolving whatever that tick's travel hits (see
## combat_projectile.gd -- B3a moved this off _physics_process(), which
## advanced on engine frame time rather than the tick a replay or checksum can
## see); for buildings (B3b) it is CombatTurret.advance_tick() for
## reload/burst plus BuildingCombat's popup transition countdown, the
## authored fire controller's shot committal, and the refinery dock departure
## cooldown (see Building.sim_tick()) -- the middle of those can itself add a
## new member to the "sim_projectiles" group walked just above, which is why
## this loop moved here (see the "Firing" paragraphs below); for units' combat
## pass (B3c) it is Unit.sim_tick_combat() -- target acquisition, attack order
## progression, turret aim and authored fire-sequence committal, i.e.
## everything UnitCombat.advance() decides, including the same kind of new
## "sim_projectiles" member the buildings pass can add, which is why this
## second units pass sits down here rather than inside the first one (see the
## "Firing" paragraphs below); for spice mounds it is SpiceMound.sim_tick()
## decrementing the maturity countdown that replaced its old MaturityTimer
## (see spice_mound.gd). What is centrally maintained here
## is the list of *systems*, not of entities: group membership maintains
## itself (Unit.gd calls add_to_group(SIM_UNITS_GROUP) and Building.gd calls
## add_to_group(SIM_BUILDINGS_GROUP), both in code, in _ready(), alongside the
## view-facing membership each already had -- unit scenes declare "units" in
## their .tscn, Building.gd calls add_to_group("buildings") in code;
## CombatLingerEffect adds itself to "sim_linger_effects" in its own
## configure(); CombatProjectile adds itself to "sim_projectiles" in its own
## _ready(); SpiceMound adds itself to "sim_spice_mounds" in its own
## _ready()), so adding a new unit or building type, spawning another linger
## effect or projectile, or placing another mound needs no change in this
## function. The units group is walked twice, by two different functions,
## rather than being two systems -- see the "Firing" paragraphs below for why
## one Unit needs two sim_tick-shaped calls at two different points in this
## order today.
##
## Slice C6a (docs/architecture/network-multiplayer.md) is why the two loops
## below read "sim_units"/"sim_buildings" instead of "units"/"buildings"
## directly, the way they did before. "units" and "buildings" are not this
## function's alone to read: selection, the side panel, availability
## tracking, blocker refresh and navigation all read them too, none of which
## this function owns or orders. C6b (deferred spawn, the reason the split
## exists at all) needs to change when an entity starts being simulated
## without changing when it becomes selectable or visible to the UI -- which
## it can only do if the tick's iteration source is a group nothing else
## reads. Membership is identical to "units"/"buildings" at every instant as
## of this slice, so this alone changes no behaviour; it is C6b that spends
## the separation.
##
## What this buys, stated honestly: the tick order is now these few lines in
## one function instead of whatever order the scene tree happened to hand
## out, so it is observable and changeable in one place. What it does not yet
## buy: cross-machine determinism. There are no stable entity ids in this
## codebase -- get_instance_id() differs per machine -- so
## get_nodes_in_group() iteration order is not guaranteed to match across
## clients; the flat id-indexed arrays that would fix that land in phase 3.
## This is centralization, not determinism; the determinism gate is phase 4.
##
## Units before linger effects is a deliberate fixed choice, not an accident,
## for the sharper reason the next paragraph gives. "Units" here means the
## first pass, unit.sim_tick() -- locomotion and reload -- not the second
## pass, unit.sim_tick_combat(), which sits far below (see the "Firing"
## paragraphs) for a reason specific to it. Buildings no longer follows units
## directly (B3b moved it -- see below); nothing about that move changes
## units' own position, which stays first because nothing upstream of it
## needs to observe a tick-fresher unit or building than the controllers
## above already produced.
##
## Linger effects go after units, for a sharper reason than "fixed and
## arbitrary": a linger effect's sim_tick() delivers damage to the very units
## the loop above just ticked this same frame. Resolving effects after
## entities means a unit's reload advances before the gas that may kill it
## lands, every tick, on every client -- an entity's own countdown for this
## tick is never disturbed by damage that arrives on this same tick. That is a
## real ordering decision, not a formality: reversing it would still be
## internally consistent, but it would be a different, silently-chosen
## simulation. Buildings do not drive this ordering choice: nothing
## Building.sim_tick() does (reload, popup transition, fire committal,
## refinery cooldown) changes a building's health, position, or hit geometry,
## so a linger effect's damage resolution against a building is exactly as
## fresh regardless of where the buildings loop sits -- which is exactly what
## leaves buildings free to move for the reason below instead.
##
## Projectiles (B3a) sit right after linger effects and right before
## buildings (B3b moved buildings past this loop; before B3b it sat right
## before linger effects instead -- see "Firing itself" below), and both
## boundaries are load-bearing rather than "after entities" restated a second
## time:
##
## After linger effects, for the identical reason linger effects sit after
## units: CombatProjectile.sim_tick() can resolve a hit against the very unit
## the loop above just ticked this tick, and it is deliberately made to land
## after it -- a unit's reload and locomotion for this tick are decided before
## any damage that might kill it arrives on that same tick, on every client.
## Reversing this would still be internally consistent; it would just be a
## different, silently-chosen simulation, the same caveat the linger-effect
## ordering above carries. (Buildings carry no equivalent freshness
## requirement here either, for the same reason given above -- nothing a
## building's own sim_tick() does affects whether a projectile hits it.)
##
## Right after the linger-effect loop specifically, not merely somewhere after
## it: a projectile's impact can itself spawn a new CombatLingerEffect (see
## combat_projectile.gd's _spawn_linger_effect()), which joins
## SIM_LINGER_GROUP the instant it is configured, mid-loop. Running projectiles
## after this tick's linger-effect loop has already executed means a linger
## effect born from an impact this tick gets its first sim_tick() -- and its
## first damage tick -- next tick, not this one. That is the same "docked one
## tick" avoidance the spice-layer-before-mound-loop ordering below relies on,
## applied here to the other pair of systems in this function that can spawn
## one another mid-loop.
##
## Firing used to be split across two clocks. B3a put projectile flight on
## the tick while both unit_combat.gd and building_combat.gd still launched a
## shot from their facade's own _process(), which the scene tree runs after
## Match's own _process() every frame -- see
## tests/combat/support/sim_tick_pump.gd's doc comment -- so neither shot
## could join "sim_projectiles" in time to be ticked by this same call,
## regardless of where any loop in this function sat: "a projectile fired
## this tick must not also travel this tick" held by scene-tree ordering
## alone, exactly as B3a recorded.
##
## B3b moved building_combat.gd first: AuthoredFireController.advance() --
## the call that actually commits a shot, via turret.try_fire_at() -- moved
## onto Building.sim_tick(), inside this function, alongside every other
## building in the "buildings" loop below. Scene-tree ordering no longer
## protected that path at all, because there was no frame boundary left
## between "a building fires" and "the projectile loop might walk it": both
## now happen inside this one function call. That was exactly the trap B3a's
## own doc comment named for whichever slice moved firing onto the tick next.
## The fix was reordering: the "buildings" loop moved to run *after*
## "sim_projectiles" instead of before it (it had sat directly after "units",
## before linger effects and projectiles), so a projectile a building fires
## this tick joins the group too late for this tick's already-completed
## projectile walk -- it gets its first sim_tick(), and its first chance to
## travel, next tick, the same way a frame-fired projectile always had.
##
## B3c moves unit_combat.gd the same way, and hits the identical trap: committing
## a shot from Unit.sim_tick_combat() parents a CombatProjectile synchronously,
## which joins "sim_projectiles" in _ready() before the call returns. The fix
## is the same shape -- run after "sim_projectiles" -- but it cannot be
## bought by moving the existing "units" loop the way "buildings" moved
## wholesale, because unlike Building.sim_tick(), Unit.sim_tick() sets
## global_position (locomotion) and that position feeds the freshness
## argument two paragraphs above: a projectile resolves its hit against the
## unit position this tick's "units" loop already produced, and reversing
## that would be a different, silently-chosen simulation, not merely a
## reshuffle. So "units" stays split: Unit.sim_tick() (reload, locomotion,
## harvester) keeps its original early position, and the new
## Unit.sim_tick_combat() (target acquisition, attack order progression, aim,
## fire-sequence committal -- everything UnitCombat.advance() decides) runs
## from a second pass over the same "units" group, positioned after
## "buildings" below, for the identical too-late-to-travel-this-tick reason
## buildings' own loop moved. Unit.sim_tick_combat()'s own doc comment carries
## the other half of this argument: nothing it does sets global_position,
## changes health, or changes hit geometry, which is what leaves it free to
## move even though its sibling pass is not. Placed after "buildings" rather
## than between "sim_projectiles" and "buildings": the two loops share no
## state (neither reads nor writes anything the other touches), so their
## relative order is exactly as arbitrary as spice mounds' own position
## below, and appending is again the smallest diff -- it leaves "buildings"
## directly following "sim_projectiles", which the paragraphs above already
## justify, untouched.
##
## Reverting either "buildings" or the new "units combat" pass to run before
## "sim_projectiles" reintroduces the same-tick travel bug for that system's
## own shots; see the wiring test that proves this loop's position is load-
## bearing rather than incidental.
##
## Like the five group loops above it, this one inherits the
## get_nodes_in_group() ordering caveat recorded above: which projectile in a
## multi-shot volley resolves first, on a tick where more than one could hit
## the same target, is not guaranteed to match across clients yet. That is a
## known, owned gap for phase 4 to close, the same as the other five loops --
## not something this slice tries to solve.
##
## The spice layer is the one step here that is not a group loop: unlike
## units, buildings, linger effects and mounds, it is a single system this
## match owns through its terrain (see map_loader.gd), so it is called
## directly, the same way the three controllers above are. Both it and the
## terrain are null-guarded because tests instantiate a match with no map
## loaded at all.
##
## It runs *before* the mound loop, and that ordering is load-bearing in one
## specific way: a mound that matures on this tick arms a fresh spread job and
## hazard inside its own sim_tick(). Advancing the layer first means those
## countdowns begin on the next tick with their full interval, instead of
## being docked one tick for having been created late in the same one.
##
## Spice mounds go last, and unlike the loops above this really is "fixed and
## arbitrary": a mound's maturity countdown reads and writes nothing any other
## system in this function touches -- not a unit, not a building, not a
## linger effect's damage, not a projectile's flight, not a controller's
## credits -- so this loop could sit anywhere among the eight steps above it
## without changing a single outcome. Appending it is simply the smallest
## diff, the one that leaves the already-justified
## controller/unit/linger/projectile/building/units-combat order untouched.
## Recording that explicitly is the point: the next system to join this loop
## should not have to guess whether "spice mounds are last" was load-bearing
## or just where the diff happened to land.
##
## is_instance_valid() guards all six group loops because queue_free() does
## not remove a node from its groups until the frame ends: a unit that gave
## itself away this frame (see Unit's set_process(false) call site) -- which
## the second "units" pass (Unit.sim_tick_combat()) needs exactly as much as
## the first, since a unit can die from this same tick's linger damage or
## projectile impact before that second pass ever reaches it -- a linger
## effect whose own countdown just ran out (see CombatLingerEffect._finish()),
## a projectile that just impacted or expired (see CombatProjectile._finish(),
## which also calls remove_from_group() itself for the same reason -- belt and
## braces, since the group walk below cannot tell "freed" from "finished but
## not yet freed" on its own), or a mound freed this same frame by
## map_spice_layer.gd's _remove_spice_mound() can still be listed here as a
## freed instance and must not be ticked.
##
## apply_pending_releases() runs last, draining whatever this same tick's
## eight steps above queued through Unit.request_despawn() /
## Building.request_despawn() (slice C5). Not deferred to the start of the
## next call instead: queue_free() frees its node at the end of the engine
## *frame*, not the end of the tick that requested it, regardless of which of
## up to FrameTickDriver.MAX_TICKS_PER_FRAME's five ticks did the requesting
## -- so draining here, at the end of the tick that produced the death, costs
## zero wall-clock and is not observable from outside this function. Draining
## at the start of the next tick instead would be observable: a death on a
## frame's *last* tick would sit queued, still resolvable by
## EntityNodeIndex.node_for() as absent but not yet freed, for a whole extra
## frame before the drain that was supposed to belong to the tick that killed
## it finally ran.
func _advance_simulation_tick() -> void:
	var tick := _clock.advance()
	# Must run before drain(tick) below, not after: a replay command
	# targeting `tick` has to be queued while _last_tick_drained is still
	# tick - 1, or SimCommandBus.submit_at() (scripts/sim/command_bus.gd)
	# would count it as late purely because playback was asked one
	# statement too late, not because the replay is actually corrupt -- see
	# ReplayPlayer.play_tick()'s doc comment (scripts/match/replay_player.gd).
	# A no-op when no replay is loaded, so this costs nothing in the common
	# case.
	_replay_player.play_tick(_command_bus, tick)
	# Captured once so record_tick() below sees exactly what the executor
	# loop iterates -- drain() empties the bus of what it returns, so
	# calling it a second time here would silently hand the recorder
	# nothing. This is also why recording happens at the drain rather than
	# anywhere else: `commands` is already drain()'s total order (see
	# scripts/sim/command_bus.gd), so "recorded order" and "executed order"
	# are the same variable, not two facts a bug could let drift apart.
	var commands := _command_bus.drain(tick)
	_replay_recorder.record_tick(tick, commands)
	for command in commands:
		var result: Dictionary = _command_executor.execute(command)
		if _unit_command_controller != null:
			_unit_command_controller.on_command_executed(command, result)
	# Navigation decides where every unit ends up, and it is the direct
	# consumer of the move commands the loop just executed -- running it
	# immediately after means a move order targeting this tick is acted on
	# this tick, not one tick late.
	if _unit_navigation_system != null:
		_unit_navigation_system.sim_tick()
	if _building_controller != null:
		_building_controller.advance_tick()
	if _building_upgrade_controller != null:
		_building_upgrade_controller.advance_tick()
	if _unit_roster_controller != null:
		_unit_roster_controller.advance_tick()
	for unit in get_tree().get_nodes_in_group("sim_units"):
		if is_instance_valid(unit):
			unit.sim_tick()
	for linger_effect in get_tree().get_nodes_in_group("sim_linger_effects"):
		if is_instance_valid(linger_effect):
			linger_effect.sim_tick()
	for projectile in get_tree().get_nodes_in_group("sim_projectiles"):
		if is_instance_valid(projectile):
			projectile.sim_tick()
	for building in get_tree().get_nodes_in_group("sim_buildings"):
		if is_instance_valid(building):
			building.sim_tick()
	# Second pass over "sim_units" -- see the "Firing" paragraphs above for why
	# this cannot be folded into the first pass near the top of this
	# function: committing a shot here can add a new member to
	# "sim_projectiles" walked above, so this has to run after that walk.
	for unit in get_tree().get_nodes_in_group("sim_units"):
		if is_instance_valid(unit):
			unit.sim_tick_combat()
	if terrain != null and terrain.spice_layer != null:
		terrain.spice_layer.sim_tick()
	for spice_mound in get_tree().get_nodes_in_group("sim_spice_mounds"):
		if is_instance_valid(spice_mound):
			spice_mound.sim_tick()
	_entity_index.apply_pending_releases()


## The simulation's current tick, for later slices and tests that need a way
## to observe it without reaching into _clock directly.
func current_tick() -> int:
	return _clock.current_tick()


## The earliest tick a command submitted right now can still legally target.
## _advance_simulation_tick() drains tick T as the first thing it does after
## advancing the clock to T -- see that function's doc comment. So the drain
## for T has already happened by the moment anyone anywhere can observe
## current_tick() == T: the two are set in consecutive statements, and
## nothing outside this function runs between them. A command aimed at
## current_tick() is therefore late by construction rather than by unlucky
## timing, and SimCommandBus.submit() would count it in dropped_late_count()
## every single time. That argument needs no claim about where input
## handling falls relative to _process() within a frame, which is the
## tempting way to reason about this and the wrong one: it would make the
## answer depend on engine callback order, and this does not. +1 is what
## makes "submit a command right now" and "the earliest tick it can run"
## agree. Handed to
## UnitCommandController as a Callable (see
## _setup_unit_command_controller()) so this reasoning lives in the one
## place that owns _clock, instead of being re-derived by every issuer.
func next_orderable_tick() -> int:
	return _clock.current_tick() + 1


## The id<->Node binding every Unit and Building self-registers into. Exposed
## so MatchLookupScript.entity_index() (which entities call, duck-typed
## through has_method()/call() to avoid this script preloading unit.gd or
## building.gd) can reach it without a hardcoded path.
func entity_index() -> EntityNodeIndex:
	return _entity_index


## The id-indexed position store every Unit's own write path
## (Unit.set_simulation_position()) routes through, when one exists -- exposed
## the same way entity_index() is, for the same reason: MatchLookupScript.
## entity_state() (duck-typed, see its own comment) reaches this without
## preloading match.gd's entire dependency chain.
func entity_state() -> SimEntityState:
	return _entity_state


func _unhandled_input(event: InputEvent) -> void:
	if _handle_debug_shortcut(event):
		get_viewport().set_input_as_handled()
		return

	if _handle_snapshot_shortcut(event):
		get_viewport().set_input_as_handled()
		return

	if _unit_command_controller != null and _unit_command_controller.has_active_target_ability() \
	and _unit_command_controller.handle_unhandled_input(event):
		get_viewport().set_input_as_handled()
		return

	if _building_controller != null and _building_controller.handle_unhandled_input(event):
		get_viewport().set_input_as_handled()
		return

	if _building_upgrade_controller != null and _building_upgrade_controller.handle_unhandled_input(event):
		get_viewport().set_input_as_handled()
		return

	if _unit_command_controller != null and _unit_command_controller.handle_unhandled_input(event):
		get_viewport().set_input_as_handled()


func _on_target_ability_mode_changed(active: bool) -> void:
	if active and _building_controller != null:
		_building_controller.cancel_interaction_modes()


func _on_building_interaction_mode_changed(active: bool) -> void:
	if active and _unit_command_controller != null:
		_unit_command_controller.cancel_target_ability()


func _handle_debug_shortcut(event: InputEvent) -> bool:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return false
	if event.keycode != KEY_F3 and event.physical_keycode != KEY_F3:
		return false
	_set_debug_layers_enabled(not _debug_layers_enabled)
	return true


func _set_debug_layers_enabled(value: bool) -> void:
	_debug_layers_enabled = value
	if _navigation_grid_debug != null:
		_navigation_grid_debug.set_enabled(value)
	if _unit_navigation_system != null:
		_unit_navigation_system.set_debug_enabled(value)
	print("Navigation debug layers: %s" % ("visible" if value else "hidden"))


func debug_layers_enabled() -> bool:
	return _debug_layers_enabled


func _handle_snapshot_shortcut(event: InputEvent) -> bool:
	if not (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7):
		return false
	if _match_snapshot == null:
		return false
	var result: Dictionary = _match_snapshot.erase() if event.shift_pressed else _match_snapshot.save($Buildings, $Units)
	_update_selection_label(String(result.get("message", "")))
	return true


func _snapshot_storage_path() -> String:
	if scene_file_path.is_empty():
		return MatchSnapshotScript.DEFAULT_PATH
	return "user://main_snapshot_%s.json" % scene_file_path.get_file().get_basename()


func _restore_saved_startup_state() -> void:
	if _match_snapshot == null:
		return
	var result: Dictionary = _match_snapshot.restore($Buildings, $Units)
	if bool(result.get("ok", false)):
		print("Match: %s" % String(result.get("message", "")))


func _update_selection_label(status := "") -> void:
	selection_label.text = _unit_command_controller.selection_text(status)


func _update_fps_label() -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _configure_demo_players() -> void:
	var players = _players()
	if players == null:
		push_warning("Players autoload is not available; units and buildings will stay neutral")
		return

	players.reset_for_match()
	players.create_player(
		LOCAL_PLAYER_ID,
		"Atreides Commander",
		Color(0.12, 0.44, 1.0),
		&"Atreides",
		[&"Fremen"],
		1,
		500000,
		0
	)
	players.create_player(
		ENEMY_PLAYER_ID,
		"Ordos Rival",
		Color(0.16, 0.75, 0.34),
		&"Ordos",
		[&"Ix"],
		2,
		5000,
		0
	)
	players.local_player_id = LOCAL_PLAYER_ID
	players.set_relation(LOCAL_PLAYER_ID, ENEMY_PLAYER_ID, PlayerDataScript.Relation.ENEMY)


## The local player's PlayerData, or null when the roster autoload is missing
## (headless tests) or the match has not been set up yet. Every sidebar option
## list below gates on it: without a player there is no house to filter by, and
## falling back to the unfiltered catalog would offer the local side buildings
## it cannot construct.
func _local_player():
	var players = _players()
	return players.player(LOCAL_PLAYER_ID) if players != null else null


func _local_player_building_option_ids() -> Array[StringName]:
	var local_player = _local_player()
	if local_player == null:
		return []
	return _building_definition_catalog.buildable_ids_for_house(
		local_player.house_id, local_player.subhouse_ids
	)


func _local_player_house_id() -> StringName:
	var local_player = _local_player()
	return local_player.house_id if local_player != null else &""


func _local_player_subhouse_ids() -> Array[StringName]:
	var local_player = _local_player()
	return local_player.subhouse_ids.duplicate() if local_player != null else []


## Great-House pages are allocated at the instant the local player gains a
## foreign Construction Yard.  They are deliberately never reordered when a
## yard is later lost: a page is a stable sidebar address for that captured
## technology tree.
func _refresh_sidebar_house_pages() -> void:
	var buildings_root := get_node_or_null("Buildings")
	if buildings_root == null:
		return
	var changed := false
	for building in buildings_root.get_children():
		# A dying building's DeathCorpse is spawned as a sibling under this same
		# container (BuildingDeathSequence.begin(), mirrors the unit side) but,
		# like a unit's corpse, never joins the "buildings" group — it has no
		# config_id/house_id and must not be mistaken for a live building here.
		if not building.is_in_group("buildings"):
			continue
		if not EntityQueryScript.is_owned_by(building, LOCAL_PLAYER_ID):
			continue
		if not EntityQueryScript.is_operational(building):
			continue
		var definition := _building_definition_catalog.definition(
			StringName(String(building.get("config_id")))
		)
		if definition == null or not definition.is_construction_yard:
			continue
		var house_id: StringName = definition.house_id
		if house_id.is_empty() or house_id in _sidebar_house_pages:
			continue
		_sidebar_house_pages.append(house_id)
		changed = true
	if not changed:
		return
	var building_grid_ids := _building_option_ids + _wall_building_ids
	side_panel.configure_ordered_roster(
		building_grid_ids + _unit_option_ids, _sidebar_house_pages, _local_player_subhouse_ids()
	)


func _local_player_wall_building_ids() -> Array[StringName]:
	var local_player = _local_player()
	if local_player == null:
		return []
	return _building_definition_catalog.wall_ids_for_house(
		local_player.house_id, local_player.subhouse_ids
	)


## The producible unit list is house-independent (a factory builds whatever its
## own rules allow), but the gate stays: with no local player there is no
## sidebar to populate at all.
func _local_player_unit_option_ids() -> Array[StringName]:
	if _local_player() == null:
		return []
	return _unit_definition_catalog.producible_unit_ids()


func _local_player_upgrade_option_ids() -> Array[StringName]:
	var local_player = _local_player()
	if local_player == null:
		return []
	return _building_definition_catalog.upgrade_ids_for_house(
		local_player.house_id, local_player.subhouse_ids
	)


func _players():
	return AutoloadLookupScript.roster(self)
