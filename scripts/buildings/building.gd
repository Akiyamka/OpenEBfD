class_name Building
extends Node3D

const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const TeamColorScript := preload("res://scripts/world/team_color.gd")
const DamagePolicyScript := preload("res://scripts/combat/damage_policy.gd")
const CombatHullScript := preload("res://scripts/combat/combat_hull.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const SelectionHaloBindingScript := preload("res://scripts/ui/selection_halo_binding.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const BuildingWallVisualScript := preload("res://scripts/buildings/building_wall_visual.gd")
const BuildingRefineryDocksScript := preload("res://scripts/buildings/building_refinery_docks.gd")
const BuildingRallyPointScript := preload("res://scripts/buildings/building_rally_point.gd")
const BuildingCombatScript := preload("res://scripts/buildings/building_combat.gd")
const BuildingDeathSequenceScript := preload("res://scripts/buildings/building_death_sequence.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const AuthoredFireControllerScript := preload(
	"res://scripts/combat/authored_fire_controller.gd"
)
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
static var _native_definition_catalog := BuildingDefinitionCatalogScript.shared()
## Converted Emperor buildings expose their apron/door on authored local +Z.
const LOCAL_EXIT_DIRECTION := Vector3.BACK

signal owner_changed(player_id: int)
signal health_changed(health: float, max_health: float)
signal primary_changed(is_primary: bool)
signal rally_point_changed(position: Vector3)
signal construction_completed
signal upgrade_level_changed(level: int)
signal attack_order_changed(active: bool, target: Variant)
signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")
const REPAIR_EFFECT_SCENE := preload("res://assets/converted/ui/cursor_models/repair.scn")
const COLLISION_OBJECT_NAME := "#~~0"
const WALL_BUILDING_GROUP := "Wall"
const REFINERY_DOCK_RELEASE_DELAY_SECONDS := 3.0
const MAX_COMBAT_HULL_VERTICES := CombatHullScript.MAX_VERTICES
const RALLY_POINT_LINE_HEIGHT := BuildingRallyPointScript.LINE_HEIGHT

## Refinery dock upgrades are visual states of the refinery itself, not
## separate Building nodes. The first/left upgrade unfolds ~~3SmallPad01 and
## the second/right unfolds ~~4SmallPad02; both retain their final pose.
enum RefineryUpgradeState { NONE, LEFT_DOCK, BOTH_DOCKS }
@export var config_id: StringName
@export var owner_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID:
	set(value):
		if owner_player_id == value:
			return
		if is_inside_tree():
			cancel_attack_order()
		_set_generated_energy(0)
		owner_player_id = value
		if is_inside_tree():
			_refresh_owner_visuals()
			_refresh_generated_energy()
			_sync_purchased_upgrade()
		owner_changed.emit(owner_player_id)
@export var default_state := &"idle"
@export var max_health := 0.0
@export var max_shields := 0.0
@export var armour_type: StringName = &""
@export var upgrade_level := 0
@export_enum("No upgrades", "Left dock", "Both docks") var refinery_upgrade_state: int = RefineryUpgradeState.NONE

var building_definition: Resource
var building_config: Resource:
	get:
		return building_definition
	set(value):
		building_definition = value
var health := 0.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		_refresh_generated_energy()
		_refresh_health_visual_state()
var shields := 0.0:
	set(value):
		shields = clampf(value, 0.0, max_shields)
var is_selected := false
var is_hovered := false
var is_repairing := false:
	set(value):
		if is_repairing == value:
			return
		is_repairing = value
		_refresh_repair_effect()
var rally_point := Vector3.ZERO
var combat_turrets: Array = []

var current_state := &""
var invulnerable := false
## Pre-placed buildings are operational immediately. BuildingPlacement marks
## newly placed buildings incomplete until StatePlayer actually finishes the
## authored construct clip; unit production uses this instead of mere tree/group
## membership when deciding whether the building can accept orders.
var _construction_complete := true
# §1 "primary Construction Yard" / §3 "primary building": true for the one
# instance (per player, per building group) a double-click has designated as
# the exit point for that group's queue. Ownership of which group a building
# belongs to lives with the caller (PrimaryBuildingRegistry); this flag is
# just where the resulting state is rendered/queried from.
var is_primary := false:
	set(value):
		if is_primary == value:
			return
		is_primary = value
		primary_changed.emit(is_primary)
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0
var _generated_energy := 0
var _selection_halo
var _repair_effect: Node3D
var _rally = BuildingRallyPointScript.new()
var _refinery_docks = BuildingRefineryDocksScript.new()
var _wall_visual = BuildingWallVisualScript.new()
var _combat_hull = CombatHullScript.new()
var _building_combat = BuildingCombatScript.new()
var _death_sequence = BuildingDeathSequenceScript.new()
var _authored_fire_controller = AuthoredFireControllerScript.new()
@warning_ignore("unused_private_class_variable")
var _popup_turret_state: int:
	get:
		return _building_combat.popup_state()


func _init() -> void:
	# Placement may apply construct state before this node reaches _ready().
	# Model-facing modules therefore need their owner as soon as the facade is
	# constructed; visual child creation remains in _ready via rally.configure.
	_wall_visual.configure(self)
	_refinery_docks.configure(self)
	_building_combat.configure(self, _authored_fire_controller)
	_death_sequence.configure(self)


func _ready() -> void:
	add_to_group("buildings")
	# The three model-facing modules were already configured in _init() -- see
	# the comment there. Only _rally and _combat_hull are configured below,
	# because they need the scene tree (child creation / model metadata).
	var state_player := get_node_or_null("StatePlayer") as AnimationPlayer
	if state_player != null:
		# The outer state clip contains a full copy of Stationary transforms.
		# Evaluate it first, then the active model clip, then this building's
		# combat servo. Otherwise StatePlayer overwrites both popup motion and
		# the yaw/pitch applied later in _process.
		state_player.process_priority = process_priority - 2
	_authored_fire_controller.weapon_fired.connect(
		_on_authored_weapon_fired
	)
	if String(config_id).is_empty() and has_meta("building_id"):
		config_id = StringName(String(get_meta("building_id")))
	_apply_building_definition()
	health = max_health
	shields = max_shields
	_scroll_fx_meshes = AuthoredModelScript.scroll_fx_meshes(self)
	_refresh_owner_visuals()
	_refresh_generated_energy()
	_sync_purchased_upgrade()
	play_state(default_state)
	_apply_refinery_upgrade_pose()
	_combat_hull.configure(self)
	_add_selection_collision()
	_add_selection_halo()
	_rally.configure(self)
	# Placement assigns a newly-built node's final position immediately after it
	# enters the tree. Deferring this lets both pre-placed and newly-built
	# production buildings receive a point in front of their final transform.
	call_deferred("_set_default_rally_point_if_unset")
	if _has_wall_role():
		# BuildingPlacement writes placement_anchor_cell and the final transform
		# immediately after add_child(), so defer adjacency until both exist.
		call_deferred("refresh_wall_connections")


func _exit_tree() -> void:
	_authored_fire_controller.cancel()
	if is_in_group("wall_buildings"):
		_wall_visual.defer_adjacent_refresh()
	_set_generated_energy(0)
	# Last: dispose() drops the module's back reference to this node, so
	# everything above that still needs a live facade has already run.
	_building_combat.dispose()


## This entity's simulation half: advances every turret's reload/burst
## countdown by exactly one combat tick. Called once per simulation tick by
## Match._advance_simulation_tick() -- see its doc comment for why the tick is
## driven centrally instead of from this node's own _process(). Never call
## this from Building itself.
func sim_tick() -> void:
	for turret in combat_turrets:
		turret.advance_tick()


func _process(delta: float) -> void:
	_building_combat.advance(delta)
	_authored_fire_controller.advance(delta)
	_building_combat.after_authored_advance()
	_refinery_docks.advance(delta)
	if _scroll_fx_meshes.is_empty():
		return
	# Scrolling textures (e.g. the windtrap's spinning blades/spotlights) need
	# a continuously advancing phase; a baked animation track would snap back
	# to 0 every time the (often sub-second) state clip loops, so it is driven
	# here every frame instead (mirrors Unit's energy-shield fx_time).
	_scroll_fx_time += delta
	for mesh_instance in _scroll_fx_meshes:
		mesh_instance.set_instance_shader_parameter("fx_time", _scroll_fx_time)


func can_set_rally_point() -> bool:
	return _rally.can_set()


func set_rally_point(position: Vector3) -> bool:
	return _rally.set_point(position)


func rally_point_position() -> Vector3:
	return _rally.point()


func production_spawn_position() -> Vector3:
	return _rally.spawn_position()


func production_exit_position() -> Vector3:
	return _rally.exit_position()


func _set_default_rally_point_if_unset() -> void:
	_rally.set_default_if_unset()


## The rally line and its marker share one visibility rule, so this is a
## single call -- BuildingRallyPoint.refresh_visibility() updates both.
func _refresh_rally_point_visuals() -> void:
	_rally.refresh_visibility()


func _emit_rally_point_changed(position: Vector3) -> void:
	rally_point_changed.emit(position)

func exit_direction() -> Vector3:
	var direction := SpatialOrientationScript.world_horizontal_axis(self, LOCAL_EXIT_DIRECTION)
	return direction if not direction.is_zero_approx() else Vector3.BACK


func _add_selection_collision() -> void:
	AuthoredModelScript.add_selection_collision(self, _collision_sources())


func _collision_sources() -> Array[Node3D]:
	# A building packs several visual damage states, each with its own #~~0.
	# The footprint is always taken from H0 (Idle), not hidden damage states.
	var idle_state := get_node_or_null("States/Idle")
	var source_root: Node = idle_state if idle_state != null else self
	return collision_sources_for(source_root, true)


## Returns the authored selectable footprint below source_root. Models which
## provide SLCT use it directly; #~~0 is retained for legacy models without
## an explicit selection volume. This API is shared by runtime collision and
## building-scene baking so their footprint decisions cannot diverge.
static func collision_sources_for(source_root: Node, hide_source_meshes := false) -> Array[Node3D]:
	return AuthoredModelScript.collision_sources(source_root, [
		{"name": "slct", "prefix": true},
		{"name": COLLISION_OBJECT_NAME, "prefix": false},
	], hide_source_meshes)


func play_state(state: StringName) -> void:
	current_state = state
	var player := get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)
		# Apply time-zero visibility and pose tracks before the next rendered
		# frame. Otherwise a freshly added building can briefly render its
		# default idle state before construct starts updating.
		player.advance(0.0)
		_refresh_wall_variant_visual()
		_apply_refinery_upgrade_pose()
		_bind_combat_turrets(state_root(state))
		return

	var states := get_node_or_null("States")
	if states == null:
		return

	for child in states.get_children():
		child.visible = _child_state_name(child) == state
	_refresh_wall_variant_visual()
	_apply_refinery_upgrade_pose()
	_bind_combat_turrets(state_root(state))


## Recomputes this wall plus the at-most-four segments whose topology can
## change because of it. Placement calls this deferred from _ready; removal
## schedules the same refresh for surviving neighbours from _exit_tree.
func refresh_wall_connections() -> void:
	_wall_visual.refresh_connections()


func wall_connection_mask() -> int:
	return _wall_visual.connection_mask()


func wall_topology() -> StringName:
	return _wall_visual.topology()


func wall_rotation_quarters() -> int:
	return _wall_visual.rotation_quarters()


func active_wall_variant_path() -> NodePath:
	return _wall_visual.active_variant_path()


func _refresh_wall_topology() -> void:
	_wall_visual.refresh_topology()


func _wall_direction_to(other: Node3D) -> int:
	return _wall_visual.direction_to(other)


func _refresh_wall_variant_visual() -> void:
	_wall_visual.refresh_variant_visual()


## Idle is the single undamaged health band. Every available DamageN state is
## one further equally sized band, ordered by its numeric suffix.  The source
## assets occasionally omit Damage1 while retaining Damage2; those are still
## valid two-band buildings (Idle, Damage2), so state numbers are ordering only
## and never used as band indices.
func _refresh_health_visual_state() -> void:
	if not is_inside_tree() or max_health <= 0.0:
		return
	var damage_states := _damage_visual_states()
	var state_count := damage_states.size() + 1
	var damaged_fraction := 1.0 - health / max_health
	var state_index := clampi(floori(damaged_fraction * state_count), 0, state_count - 1)
	var desired_state: StringName = &"idle"
	if state_index > 0:
		desired_state = damage_states[state_index - 1]
	if desired_state != current_state:
		play_state(desired_state)


func _damage_visual_states() -> Array[StringName]:
	var states_root := get_node_or_null("States")
	if states_root == null:
		return []
	var numbered_states: Array[Dictionary] = []
	for child in states_root.get_children():
		var state_name := String(child.get_meta("state", child.name.to_lower()))
		if not state_name.begins_with("damage"):
			continue
		var suffix := state_name.trim_prefix("damage")
		if not suffix.is_valid_int():
			continue
		numbered_states.append({"name": StringName(state_name), "number": suffix.to_int()})
	numbered_states.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["number"]) < int(right["number"])
	)
	var result: Array[StringName] = []
	for state in numbered_states:
		result.append(state["name"])
	return result


## Single entry point for "which States child is this state?". The extracted
## modules (BuildingWallVisual, BuildingRefineryDocks, BuildingCombat) reach
## their owner through a base-typed `_owner`, and tools/check_architecture.py
## forbids `_owner._private_method`, so this is deliberately public and they
## call it as `_owner.call("state_root", state)` rather than each keeping a
## copy of the search below -- there used to be one per module.
func state_root(state: StringName) -> Node3D:
	var states := get_node_or_null("States")
	if states == null:
		return null
	for child in states.get_children():
		if _child_state_name(child) == state and child is Node3D:
			return child as Node3D
	return null


func _child_state_name(child: Node) -> StringName:
	return StringName(String(child.get_meta("state", child.name.to_lower())))


func set_owner_player_id(player_id: int) -> void:
	owner_player_id = player_id


func set_upgrade_level(level: int) -> void:
	var normalized := maxi(level, 0)
	if upgrade_level == normalized:
		return
	upgrade_level = normalized
	upgrade_level_changed.emit(upgrade_level)


func dock_count() -> int:
	return _refinery_docks.dock_count()


## The base refinery starts with its central pad; refinery_upgrade_state counts
## only the one or two additional pads unfolded by upgrades.
func refinery_dock_capacity() -> int:
	return _refinery_docks.capacity()


func is_refinery() -> bool:
	return _refinery_docks.is_refinery()


## Reserves one currently active pad immediately. A reservation remains owned
## by this harvester through docking and Unload_End, then enters a three-second
## cooldown so the departing vehicle can clear the lane.
func try_reserve_refinery_dock(harvester: Node) -> int:
	return _refinery_docks.try_reserve(harvester)


func refinery_dock_reserved_by(dock_index: int, harvester: Node) -> bool:
	return _refinery_docks.reserved_by(dock_index, harvester)


func release_refinery_dock(
		harvester: Node, cooldown_seconds := REFINERY_DOCK_RELEASE_DELAY_SECONDS
	) -> void:
	_refinery_docks.release(harvester, cooldown_seconds)


## Before a vehicle enters the pad lane there is nothing that needs a departure
## gap. This is used when an approach/wait order is replaced or the refinery is
## captured before parking begins.
func abandon_refinery_dock(harvester: Node) -> void:
	release_refinery_dock(harvester, 0.0)


func refinery_front_position() -> Vector3:
	return _refinery_docks.front_position()


## Converts the authoritative Rules.txt DeployTile into world space. Exported
## occupy rows are Z-mirrored to match converted models, while deploy_points
## intentionally retain their source orientation (import_rules.gd); mirror Y
## here against the occupy height before applying the building transform.
func refinery_dock_world_position(dock_index: int) -> Vector3:
	return _refinery_docks.world_position(dock_index)


func refinery_dock_facing_direction(dock_index: int) -> Vector3:
	return _refinery_docks.facing_direction(dock_index)


func refinery_dock_navigation_cells(navigation_grid) -> Dictionary:
	return _refinery_docks.navigation_cells(navigation_grid)


func can_add_dock() -> bool:
	return _refinery_docks.can_add_upgrade()


func add_refinery_dock_upgrade() -> bool:
	return _refinery_docks.add_upgrade()


func set_refinery_upgrade_state(state: int) -> void:
	_refinery_docks.set_upgrade_state(state)


## Restored/preconfigured refineries do not replay their opening sequence.
## Seeking each completed clip applies the same final transforms immediately;
## later clips target a different pad, so the earlier pose stays untouched.
func _apply_refinery_upgrade_pose() -> void:
	_refinery_docks.apply_upgrade_pose()


func setup(building_id: StringName) -> void:
	cancel_attack_order()
	config_id = building_id
	if not is_inside_tree():
		return

	_apply_building_definition()
	health = max_health


func set_invulnerable(value: bool) -> void:
	invulnerable = value


func begin_construction() -> void:
	_construction_complete = false
	cancel_attack_order()


func finish_construction() -> void:
	if _construction_complete:
		return
	_construction_complete = true
	construction_completed.emit()


func is_construction_complete() -> bool:
	return _construction_complete


func set_primary(value: bool) -> void:
	is_primary = value


func set_selected(value: bool) -> void:
	if is_selected == value:
		return
	is_selected = value
	if _selection_halo != null:
		_selection_halo.set_selected(value)
	_refresh_rally_point_visuals()


func set_hovered(value: bool) -> void:
	if is_hovered == value:
		return
	is_hovered = value
	if _selection_halo != null:
		_selection_halo.set_hovered(value)


func take_damage(amount: float, _death_cause: StringName = &"") -> void:
	# Building destruction has only one outcome (see §2.1 below) regardless of
	# damage type, so the death cause is accepted for signature parity with
	# Unit.take_damage() — callers don't need to branch by target type — but
	# genuinely unused here.
	# The arithmetic is shared with Unit.take_damage(); applying it is not,
	# because the health setter here recomputes power and damage-state visuals.
	var outcome := DamagePolicyScript.resolve(amount, health, shields, invulnerable)
	if outcome.absorbed_by_shields > 0.0:
		shields -= outcome.absorbed_by_shields
	if outcome.health_delta == 0.0:
		return
	health += outcome.health_delta
	if outcome.is_lethal:
		# §2.1 "Building destruction": the footprint is freed the same frame
		# the killing blow lands — survivors must be spawned first, before the
		# building (and its footprint bounds) disappear. What happens after
		# that (a detached death-clip corpse, the rules-authored explosion,
		# and its sound) is BuildingDeathSequence's job; queue_free() always
		# happens inside it, on every branch.
		BuildingSurvivorsScript.spawn_for_destroyed_building(self)
		_begin_death_sequence()


func _begin_death_sequence() -> void:
	_death_sequence.begin()


## Called by BuildingDeathSequence right before it detaches `model`
## (States/Destroy) to hand it to a DeathCorpse. Mirrors
## Unit.prepare_model_for_corpse()'s checklist role (scripts/units/unit.gd:767)
## for the much smaller set of things Building itself caches into its model
## subtree: nothing in Building binds turrets or fire animation to
## States/Destroy specifically (turrets/_building_combat only ever bind to
## state_root(current_state) via _bind_combat_turrets(), and Destroy is never
## a selectable state through play_state()), so there is no combat-facing
## detach step here the way Unit needs one. Still must:
## - drop any _scroll_fx_meshes now living under the detached subtree, so
##   _process()'s per-frame set_instance_shader_parameter() doesn't touch a
##   node the corpse now owns;
## - stop _process()/_physics_process() before queue_free() takes effect at
##   end of frame — otherwise this building's own combat/turret/refinery-dock
##   ticks would still run once more against a node about to be freed, the
##   same class of "dead node still running this frame's logic" bug
##   Unit.prepare_model_for_corpse()'s doc comment calls out (cdc79b6/2b745b2).
func prepare_model_for_corpse(model: Node3D) -> void:
	var remaining: Array[MeshInstance3D] = []
	for mesh_instance in _scroll_fx_meshes:
		if mesh_instance != model and not model.is_ancestor_of(mesh_instance):
			remaining.append(mesh_instance)
	_scroll_fx_meshes = remaining
	set_process(false)
	set_physics_process(false)


func combat_armour_type() -> StringName:
	return armour_type


func combat_is_airborne() -> bool:
	return false


func combat_aim_position() -> Vector3:
	return global_position


## Spreads incoming fire across the footprint-facing edge instead of making
## every attacker converge on the building root.
func combat_aim_position_from(world_origin: Vector3) -> Vector3:
	return _combat_hull.aim_position_from(world_origin, combat_aim_position())


func combat_hull() -> PackedVector2Array:
	return _combat_hull.points()


func combat_has_precise_collision() -> bool:
	return get_node_or_null("CombatCollision") != null


func combat_contains_impact_position(world_position: Vector3) -> bool:
	return _combat_hull.contains_impact_position(world_position)


func combat_is_alive() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func combat_hit_radius() -> float:
	var collision_body := get_node_or_null("SelectionCollision") as StaticBody3D
	if collision_body != null and collision_body.has_meta("collision_bounds"):
		var bounds: AABB = collision_body.get_meta("collision_bounds")
		return maxf(minf(bounds.size.x, bounds.size.z) * 0.5, 0.5)
	return 0.5


## Weapon range is measured to the nearest point of a building's authored
## footprint. Entity roots remain the range point for units and other targets.
func combat_range_distance_from(
		world_origin: Vector3
	) -> float:
	var nearest_world := combat_aim_position_from(world_origin)
	var offset := nearest_world - world_origin
	return Vector2(offset.x, offset.z).length()


func combat_owner_player_id() -> int:
	# Stable combat-facing ownership contract used for friendly-fire scaling.
	return owner_player_id


func aim_turrets_at(world_position: Vector3, delta: float) -> bool:
	if combat_turrets.is_empty():
		return false
	var all_aimed := true
	for turret in combat_turrets:
		all_aimed = turret.aim_at(world_position, delta) and all_aimed
	return all_aimed


func turret_emission_points(weapon_index: int = 0) -> Array[Dictionary]:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.emission_points()


func next_turret_emission(weapon_index: int = 0) -> Dictionary:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return {}
	return turret.next_emission()


func fire_weapon_at(
		target_or_position: Variant,
		weapon_index: int = 0,
		projectile_parent: Node = null,
		aim_offset := Vector3.ZERO
	) -> Array:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.try_fire_at(
		FireRequestScript.at(target_or_position, self, projectile_parent, aim_offset)
	)


func can_attack(target_or_position: Variant) -> bool:
	return _building_combat.can_attack(target_or_position)


func command_attack(target_or_position: Variant) -> bool:
	return _building_combat.command_attack(target_or_position)


func cancel_attack_order() -> void:
	_building_combat.cancel_order()


func cancel_all_orders() -> bool:
	return _building_combat.cancel_all_orders()


func has_attack_order() -> bool:
	return _building_combat.has_order()


func has_active_order() -> bool:
	return _building_combat.has_order()


func attack_order_target() -> Variant:
	return _building_combat.order_target()


func _emit_attack_order_changed(active: bool, target: Variant) -> void:
	attack_order_changed.emit(active, target)


func _emit_weapon_fired(projectiles: Array, target: Variant, weapon_index: int) -> void:
	weapon_fired.emit(projectiles, target, weapon_index)


func _active_model_animation_player(animation_name: StringName) -> AnimationPlayer:
	return _building_combat.active_animation_player(animation_name)

func _combat_turret_for_weapon(weapon_index: int):
	if weapon_index < 0:
		return null
	for turret in combat_turrets:
		if turret.weapon_index() == weapon_index:
			return turret
	return null


func owner_player():
	return EntityQueryScript.owner_player(self, _players())


func is_neutral_owner() -> bool:
	return owner_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID


func is_owned_by(player_id: int) -> bool:
	return EntityQueryScript.is_owned_by(self, player_id)


func is_allied_with(player_id: int) -> bool:
	return EntityQueryScript.is_allied_with(self, player_id, _players())


func is_enemy_of(player_id: int) -> bool:
	return EntityQueryScript.is_enemy_of(self, player_id, _players())


func _refresh_owner_visuals() -> void:
	_apply_team_color(self, _owner_team_color())


func _apply_building_definition() -> void:
	if String(config_id).is_empty():
		return

	building_definition = _native_definition_catalog.definition(config_id)
	if building_definition == null:
		push_warning("Building definition not found: %s" % String(config_id))
		return

	_sync_wall_group()
	max_health = building_definition.health
	max_shields = building_definition.shield_health
	armour_type = building_definition.armour_type
	_configure_combat_turret()


func _has_wall_role() -> bool:
	return building_definition != null \
		and String(building_definition.building_group_id) == WALL_BUILDING_GROUP


func _sync_wall_group() -> void:
	if _has_wall_role():
		add_to_group("wall_buildings")
	elif is_in_group("wall_buildings"):
		remove_from_group("wall_buildings")


func _configure_combat_turret() -> void:
	_authored_fire_controller.cancel()
	combat_turrets.clear()
	var definition := _native_definition_catalog.definition(config_id)
	var turret_id: StringName = definition.turret_id if definition != null else &""
	if turret_id == &"":
		return
	var turret = CombatTurretScript.new()
	if turret.configure(turret_id):
		turret.bind_model(state_root(current_state), 0)
		combat_turrets.append(turret)


func _bind_combat_turrets(model_root: Node3D) -> void:
	_building_combat.bind_model(model_root)


func _on_authored_weapon_fired(
	projectiles: Array, target: Variant, weapon_index: int
	) -> void:
	weapon_fired.emit(projectiles, target, weapon_index)


func _refresh_generated_energy() -> void:
	if not is_inside_tree() or building_definition == null or max_health <= 0.0 or health <= 0.0:
		_set_generated_energy(0)
		return

	var full_power := int(building_definition.power_generated)
	_set_generated_energy(roundi(float(full_power) * health / max_health))


func _set_generated_energy(value: int) -> void:
	if _generated_energy == value:
		return

	var player = owner_player()
	if player != null:
		player.add_energy(value - _generated_energy)
	_generated_energy = value


func _owner_team_color() -> Color:
	return TeamColorScript.color_for(owner_player(), Color(0.58, 0.58, 0.58))


func _apply_team_color(node: Node, color: Color) -> void:
	TeamColorScript.apply(node, color)


func _add_selection_halo() -> void:
	_selection_halo = SelectionHaloScript.new()
	_selection_halo.name = "SelectionHalo"
	add_child(_selection_halo)
	_selection_halo.configure(self, _selection_radius(), _selection_position())
	_refresh_repair_effect()


## The original repair marker reuses the animated repair cursor. It cannot be
## a child of SelectionHalo: that node intentionally hides itself unless its
## building is selected or hovered, whereas an active repair marker is always
## visible.
func _refresh_repair_effect() -> void:
	if not is_instance_valid(_repair_effect):
		_repair_effect = null
	if not is_repairing:
		if _repair_effect != null:
			_repair_effect.queue_free()
			_repair_effect = null
		return
	if _selection_halo == null or _repair_effect != null:
		return
	_repair_effect = REPAIR_EFFECT_SCENE.instantiate() as Node3D
	if _repair_effect == null:
		return
	_repair_effect.name = "RepairEffect"
	_repair_effect.position = _selection_position() + Vector3(0.0, 0.02, 0.0)
	# Cursor assets are authored at screen-cursor scale; they must not inherit a
	# large factory's halo diameter or they overwhelm the building.
	_repair_effect.scale = Vector3.ONE * 0.08
	add_child(_repair_effect)


func _selection_radius() -> float:
	return SelectionHaloBindingScript.radius(self, self)


func _selection_position() -> Vector3:
	return SelectionHaloBindingScript.position(self, self)


func _selection_bounds() -> AABB:
	return AuthoredModelScript.selection_bounds(self, self)


func _halo_anchor_node(node: Node) -> Node3D:
	return SelectionHaloBindingScript.anchor(node)


func _players():
	return AutoloadLookupScript.roster(self)


## docs/mechanics/production.md section 4/5: a purchased global per-type
## upgrade belongs to the player, so any building of that type this player
## owns -- including ones built after the purchase -- should read as
## upgraded. UpgradeEffects pushes the level onto buildings that already
## exist when the purchase completes; this covers the building's own arrival
## afterwards.
func _sync_purchased_upgrade() -> void:
	if not is_inside_tree() or String(config_id).is_empty() or upgrade_level > 0:
		return
	var player = owner_player()
	if player == null or not player.has_method("has_purchased_upgrade"):
		return
	if player.has_purchased_upgrade(config_id):
		set_upgrade_level(1)
