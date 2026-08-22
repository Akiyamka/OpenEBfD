extends CharacterBody3D
class_name Unit

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const TeamColorScript := preload("res://scripts/world/team_color.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const DamagePolicyScript := preload("res://scripts/combat/damage_policy.gd")
const SelectionHaloBindingScript := preload("res://scripts/ui/selection_halo_binding.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const UnitFlightControllerScript := preload("res://scripts/units/navigation/unit_flight_controller.gd")
const UnitTerrainAlignmentScript := preload("res://scripts/units/unit_terrain_alignment.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const UnitDeathSequenceScript := preload("res://scripts/units/unit_death_sequence.gd")
const UnitShaderFxScript := preload("res://scripts/units/unit_shader_fx.gd")
const UnitIdleAnimationsScript := preload("res://scripts/units/unit_idle_animations.gd")
const UnitLocomotionScript := preload("res://scripts/units/unit_locomotion.gd")
const UnitMovementSoundsScript := preload("res://scripts/units/unit_movement_sounds.gd")
const HarvesterControllerScript := preload("res://scripts/units/harvester_controller.gd")
const UnitDeployStateScript := preload("res://scripts/units/unit_deploy_state.gd")
const UnitCombatScript := preload("res://scripts/units/unit_combat.gd")
const UnitAuthoredCollisionScript := preload("res://scripts/units/unit_authored_collision.gd")
const UnitAnimationDirectorScript := preload("res://scripts/units/unit_animation_director.gd")
const AdvancedCarryallTransportScript := preload(
	"res://scripts/units/advanced_carryall_transport.gd"
)
static var _definition_catalog := UnitSceneCatalogScript.shared()

signal owner_changed(player_id: int)
signal navigation_enemy_encountered(enemies: Array[Node3D])
signal deployment_animation_finished
signal attack_order_changed(active: bool, target: Variant)
signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")

## The incidental Tleilaxu walker predates the Mech rule used by the three
## playable House walkers, but its converted model has the same articulated
## leg hierarchy and must retain a level gameplay root as well.
const LEGACY_WALKER_UNIT_IDS: Array[StringName] = [&"INTLWalker"]
## Rules.txt stores TurnRate in radians per movement update, and the original
## engine ran twenty of those per second -- the cadence the rules data was
## authored at, independent of whatever rate navigation or the simulation
## itself ticks at. Used for the unmanaged fallback below to keep turning
## independent of the caller's frame rate.
##
## Mirrors UnitCombat.RULE_MOVEMENT_UPDATES_PER_SECOND (used there for the
## combat module's own hull-turn adjustment); kept here too because
## tests/match/demo_boot_run.gd reads it as Unit.<const>.
const RULE_MOVEMENT_UPDATES_PER_SECOND := UnitTerrainAlignmentScript.MOVEMENT_UPDATES_PER_SECOND
## Converted XBF tracks use a 20 Hz timeline, while the original firing
## cadence measured from ReloadCount and Fire clip frame counts is 25 Hz.
## Fire clips therefore traverse the baked timeline at 25/20 speed.
##
## Mirrors UnitCombat.BAKED_MODEL_FRAMES_PER_SECOND; kept here too because
## tests/combat/fire_sequence_run.gd reads it as UnitScript.<const>.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
## Tick-only twin of the "units" group 99 .tscn files declare statically.
## "units" is read far outside the simulation -- selection, the side panel,
## availability tracking, blocker refresh, navigation -- so the tick cannot
## be pointed at it without also making every one of those a simulation
## reader by accident. SIM_UNITS_GROUP is what Match._advance_simulation_tick()
## and the other simulation systems walk instead, joined alongside "units" in
## _ready() below rather than replacing it. Slice C6a
## (docs/architecture/network-multiplayer.md) introduces this split; C6b is
## what makes it pay for itself, by deferring an entity's entry into this
## group -- and only this group -- until the tick is ready to simulate it.
## Deferring "units" itself would leave a freshly spawned unit unselectable
## and invisible to the UI for a tick, a view regression no simulation
## ordering question should be able to cause. Mirrors
## CombatProjectile.SIM_PROJECTILES_GROUP and CombatLingerEffect.SIM_LINGER_GROUP,
## which already separate their tick-only membership from anything a view or
## command reads, because nothing outside the tick ever wanted to list them.
const SIM_UNITS_GROUP := "sim_units"
## Drives the per-turret reload/cooldown ticks in _process() below, which stay
## on the facade the same way Building._process() keeps its own copy next to
## BuildingCombat (see scripts/buildings/building.gd). Also mirrored on
## UnitCombat and read by tests/combat/fire_sequence_run.gd as UnitScript.<const>.
const RULE_COMBAT_TICKS_PER_SECOND := CombatRulesScript.TICKS_PER_SECOND

enum SlopeAlignmentMode {
	AUTO,
	ENABLED,
	DISABLED,
}

@export var config_id: StringName
## Store-then-mirror, the same order set_simulation_position() and the
## health/shields setters use (scripts/sim/entity_state.gd's own doc
## comment explains why this property is the chokepoint C4 needed no
## separate method for, the way position needed
## set_simulation_position()). Unlike health/shields there is no clamp to
## compute and no float32-narrowing gap between store and mirror to close
## by reading the store's value back afterward -- owner_player_id is an
## int on both sides -- so the value handed to the store is exactly `value`,
## and a refused write (dead but still-registered id) leaves this field
## holding `value` regardless, the same choice set_simulation_position()
## makes for a refused position write and for the identical reason: the
## node stays the loud, visible symptom instead of a quiet one.
##
## This setter alone is not enough to keep the store honest, though: it
## only runs while `_entity_id != 0`, i.e. after this unit has registered.
## A scene's exported value (every fixture and demo scene sets
## owner_player_id this way) and MatchSnapshot._restore_entities() both
## assign this property before add_child() -- before _entity_id exists --
## so _register_entity_id() below makes a second push into the store, at
## registration time, to catch exactly that case. See
## scripts/sim/entity_state.gd's "Registration-time push" section.
@export var owner_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID:
	set(value):
		if owner_player_id == value:
			return
		if _entity_id != 0:
			var store = MatchLookupScript.entity_state(self)
			if store != null:
				store.set_owner_player_id(_entity_id, value)
		owner_player_id = value
		if is_inside_tree():
			_refresh_owner_visuals()
		owner_changed.emit(owner_player_id)
@export var move_speed := 5.0
@export var mech_speed := 0.0
@export var turn_rate := 0.0
@export var can_move_any_direction := false
@export var arrival_radius := 0.2
@export var visual_root_path := NodePath("VisualRoot")
## AUTO follows the terrain only for ground vehicles. Infantry, aircraft and
## articulated Mech units stay upright; individual scenes can force either
## behavior for unusual visuals that are not described by the original rules.
@export var slope_alignment_mode := SlopeAlignmentMode.AUTO
@export var max_health := 0.0
@export var max_shields := 0.0
@export var max_passengers := 0.0
@export var armour_type: StringName = &""

@onready var visual_root: Node3D = get_node_or_null(visual_root_path)

var unit_definition: Resource
var target_position: Vector3
var is_selected := false
var is_hovered := false
var invulnerable := false
## The clamp is a simulation decision -- see SimEntityState's doc comment
## (scripts/sim/entity_state.gd) on why it happens here, once, rather than
## inside the store: this setter is the only place that knows max_health.
## The clamped value is written to SimEntityState first, then mirrored into
## this field, the same order Unit.set_simulation_position() uses for
## position and for the identical reason -- the store is authoritative, this
## field is a view over it. There is no separate chokepoint method the way
## position needed one: every write to `health` anywhere in this project
## already funnels through this setter, because GDScript has no second name
## for a property's backing storage a caller could assign to instead.
var health := 0.0:
	set(value):
		var clamped := clampf(value, 0.0, max_health)
		# Mirrored from the store's own value, not from `clamped`, whenever a
		# store exists: it holds float32 (PackedFloat32Array) while this field
		# is a plain GDScript double, so assigning the pre-narrowing number
		# would leave the mirror holding something the store does not have --
		# "the node is a view over the store" would stop being exactly true,
		# and a snapshot restore would silently shift the value. With no store
		# there is nothing to disagree with, so `clamped` stands.
		var mirrored := clamped
		if _entity_id != 0:
			var store = MatchLookupScript.entity_state(self)
			if store != null:
				store.set_health(_entity_id, clamped)
				# Only when the store actually took it. A write for a dead
				# but still-registered id is refused and push_errored (see
				# SimEntityState), and reading back then returns the
				# non-finite no-value marker -- assigning that would turn a
				# logged, still-visible bug into an entity with INF health,
				# which is far worse than the unnarrowed double this keeps
				# instead. C2 made the same call for position: on a refused
				# write the node still moves, so the symptom stays loud.
				var stored: float = store.health(_entity_id)
				if is_finite(stored):
					mirrored = stored
		health = mirrored
## Same store-then-mirror order as health above; _refresh_shield_visibility()
## runs last because it reads `shields`, which by then already holds the
## clamped, store-agreeing value.
var shields := 0.0:
	set(value):
		var clamped := clampf(value, 0.0, max_shields)
		# Mirrored from the store's own value, not from `clamped`, whenever a
		# store exists: it holds float32 (PackedFloat32Array) while this field
		# is a plain GDScript double, so assigning the pre-narrowing number
		# would leave the mirror holding something the store does not have --
		# "the node is a view over the store" would stop being exactly true,
		# and a snapshot restore would silently shift the value. With no store
		# there is nothing to disagree with, so `clamped` stands.
		var mirrored := clamped
		if _entity_id != 0:
			var store = MatchLookupScript.entity_state(self)
			if store != null:
				store.set_shields(_entity_id, clamped)
				# Only when the store actually took it. A write for a dead
				# but still-registered id is refused and push_errored (see
				# SimEntityState), and reading back then returns the
				# non-finite no-value marker -- assigning that would turn a
				# logged, still-visible bug into an entity with INF health,
				# which is far worse than the unnarrowed double this keeps
				# instead. C2 made the same call for position: on a refused
				# write the node still moves, so the symptom stays loud.
				var stored: float = store.shields(_entity_id)
				if is_finite(stored):
					mirrored = stored
		shields = mirrored
		_refresh_shield_visibility()
var passengers := 0.0
var combat_turrets: Array = []
var _shader_fx := UnitShaderFxScript.new()
var _selection_halo
## Owns the model's AnimationPlayers; every module that needs them gets the
## array from here rather than each finding its own.
var _animation_director := UnitAnimationDirectorScript.new()
var _idle_animations := UnitIdleAnimationsScript.new()
## The harvesting loop, present only on a unit whose rules give it a spice
## capacity. Null on everything else, which is what "is a harvester" means now.
var _harvester = null
## Cargo stays canonical on the facade like health and shields do: the match
## snapshot reads it by name, and the selection halo draws its ring from it.
##
## A *spice* capacity is also what makes a unit a harvester: setting one
## attaches the harvesting loop. Deliberately this field and no other -- a
## carrier's passenger capacity and a launcher's ammunition are their own
## fields (see selection_halo's max_passengers), and neither has anything to do
## with driving to a field and eating it.
@export var max_spice := 0.0:
	set(value):
		max_spice = maxf(value, 0.0)
		_sync_harvester_controller()
		# Re-clamps an existing load against the capacity just applied.
		spice = spice
var spice := 0.0:
	set(value):
		spice = clampf(value, 0.0, max_spice)
var _navigation_managed := false
var _navigation_system = null
var _pending_navigation_order := Vector3.ZERO
var _pending_navigation_exit := Vector3.INF
var _has_pending_navigation_order := false
var _navigation_requested_velocity := Vector3.ZERO
var _navigation_debug_visible := false
var _terrain_alignment := UnitTerrainAlignmentScript.new()
var _locomotion := UnitLocomotionScript.new()
var _movement_sounds := UnitMovementSoundsScript.new()
var _flight_controller: UnitFlightController = null
## AdvancedCarryallTransport owns the transport state machine; Unit exposes
## only the public hooks it needs for tree, navigation, combat and flight.
var _advanced_carryall_transport = null
var _transport_cargo_anchor: Node3D
var _transport_docking_gap := 0.0
var _transport_carrier_ref: WeakRef
var _transport_carried_vertical_bounds := Vector2.ZERO
var _transport_has_carried_vertical_bounds := false
var _transport_carrier_vertical_bounds := Vector2.ZERO
var _transport_has_carrier_vertical_bounds := false
var _transport_reservation_ref: WeakRef
var _transport_docking_locked := false
var _navigation_suspended_for_transport := false
var _transport_reparenting := false
## Internal continuations (transport tracking and post-takeoff routing) belong
## to an already accepted order. They must not pass through the player-order
## cancellation gate and accidentally abort that same transport operation.
var _issuing_internal_navigation := false
var _death_sequence := UnitDeathSequenceScript.new()
## Not `velocity`: navigation_step() zeroes its vertical component, and
## UnitFlightController writes global_position directly, bypassing velocity
## entirely during takeoff/landing. Updated at the top of every
## _advance_locomotion_tick() call (see the comment there) so it always
## holds the unit's position at the start of the most recent simulation
## tick, regardless of which movement path is active.
var _previous_global_position := Vector3.ZERO
## Set once request_despawn() below has run -- including on the branch where
## prepare_model_for_corpse() already handed the model to a corpse first;
## that function itself never touches this flag (see its own comment for
## why setting it early there would break request_despawn()). From that
## moment this unit owns nothing left to simulate, but Match's "units" group
## loop still reaches it -- queue_free() is deferred, so is_instance_valid()
## stays true for the rest of the tick. set_physics_process(false) used to be
## what stopped the locomotion half from running in that window; locomotion
## is on sim_tick() now, which no engine flag gates, so the guard has to be
## explicit.
var _simulation_halted := false
var _deploy := UnitDeployStateScript.new()
## Unit's combat engine (attack orders, turret engagement, fire sequences).
## See scripts/units/unit_combat.gd; modeled on Building/BuildingCombat.
var _combat := UnitCombatScript.new()
## Physics shapes, navigation extents and selection bounds read off the
## converted model's authored collision volumes.
var _authored_collision := UnitAuthoredCollisionScript.new()
## Test-only compatibility property: tests/combat/unit_fire_movement_run.gd reads this by name.
@warning_ignore("unused_private_class_variable")
var _fire_sequence_active: bool:
	get:
		return _combat.has_fire_sequence_active()
## Stable id from the running match's EntityNodeIndex (scripts/sim/entity_registry.gd),
## independent of get_instance_id(). Read-only from outside: bound once by
## _register_entity_id() in _ready() and cleared by _release_entity_id() in
## _exit_tree(). Stays 0 for the lifetime of a unit built with no Match in the
## tree -- most unit/combat tests instantiate a Unit directly (see
## tests/combat/*) -- which is deliberate and must not change unit behaviour.
var _entity_id := 0
var entity_id: int:
	get:
		return _entity_id


## Modules that hold no tree state are bound here rather than in _ready(), so
## they also work on a unit whose _ready() is stubbed out (see the harvester
## suite's TestHarvester) and before the node enters the tree.
func _init() -> void:
	_terrain_alignment.configure(self)
	_death_sequence.configure(self)
	_shader_fx.configure(self)
	_idle_animations.configure(self)
	_locomotion.configure(self)
	_movement_sounds.configure(self)
	_deploy.configure(self)
	_combat.configure(self)
	_authored_collision.configure(self)
	_advanced_carryall_transport = AdvancedCarryallTransportScript.new()
	_advanced_carryall_transport.configure(self)


func _ready() -> void:
	# "units" itself comes from the .tscn (99 scene files declare it
	# statically, unlike Building's own add_to_group("buildings") call below
	# in building.gd) and stays untouched -- this is additional membership,
	# not a replacement. See SIM_UNITS_GROUP's own comment for why the tick
	# needs a group of its own rather than reading "units" directly.
	add_to_group(SIM_UNITS_GROUP)
	_register_entity_id()
	# The authored rest pose only exists once visual_root has resolved.
	_terrain_alignment.capture_rest_pose()
	_apply_unit_definition()
	target_position = global_position
	_previous_global_position = global_position
	# Terrain height is sampled explicitly below. Letting CharacterBody collide
	# with the terrain mesh makes each triangle edge behave like a small wall,
	# which prevents units from climbing otherwise traversable slopes. The
	# collision layer remains enabled, so mouse rays can still select this unit.
	collision_mask = 0
	_authored_collision.add_body_shapes()
	_shader_fx.attach_model()
	var players := _animation_director.refresh(visual_root)
	_locomotion.attach_model(players)
	_movement_sounds.attach_model(players)
	_combat.refresh_weapon_runtime()
	_locomotion.refresh_motion_profile()
	_movement_sounds.refresh_step_schedule()
	_animation_director.prioritize_before(process_priority)
	_prepare_idle_animations()
	_set_movement_animation(false)
	health = max_health
	shields = max_shields
	_add_selection_halo()
	_refresh_owner_visuals()


func _exit_tree() -> void:
	# Reparenting live cargo into or out of CargoAnchor temporarily exits and
	# re-enters the SceneTree. The explicit reparent guard distinguishes that
	# narrow lifecycle event from actual scene teardown while cargo is carried.
	if _transport_reparenting:
		return
	# Every other exit is terminal (see UnitCombat.dispose()'s own doc comment):
	# everything above the module has already run before it drops its back
	# reference.
	_combat.dispose()
	if _advanced_carryall_transport != null:
		_advanced_carryall_transport.dispose()
	for turret in combat_turrets:
		turret.cancel_authored_fire_fx()
	_release_entity_id()


## Self-registration, alongside the "units" group this unit's own scene
## already declares statically: see MatchLookupScript's doc comment for why
## this must run from _ready() rather than anywhere in Match. Leaves
## entity_id at 0, unchanged, when there is no Match in the tree.
##
## The owner_player_id push right after is the fix for a real lifecycle gap,
## not a defensive extra: owner_player_id's own setter (above) can only
## write into the store while _entity_id is nonzero, but this unit's
## owner_player_id is routinely assigned before that -- a scene's exported
## value (every fixture and demo scene) or MatchSnapshot._restore_entities()
## both set it before add_child() ever runs this method. Pushing the
## mirror's current value here, unconditionally, the moment _entity_id
## becomes real, means a write that landed before registration is not lost.
## See scripts/sim/entity_state.gd's "Registration-time push" section.
func _register_entity_id() -> void:
	var index = MatchLookupScript.entity_index(self)
	if index != null:
		_entity_id = index.register(self, SimEntityRegistryScript.Kind.UNIT)
		var store = MatchLookupScript.entity_state(self)
		if store != null:
			store.set_owner_player_id(_entity_id, owner_player_id)


func _release_entity_id() -> void:
	if _entity_id == 0:
		return
	var index = MatchLookupScript.entity_index(self)
	if index != null:
		index.release_id(_entity_id)
	_entity_id = 0


## The single place this unit's position is written -- by this file's own
## locomotion/navigation/transport code, or by a collaborator holding a `_unit`
## / `unit` reference (UnitTerrainAlignment, UnitFlightController,
## UnitPushAside, BuildingSurvivors, UnitDeploymentController,
## UnitRosterController, Match._place_on_map()). Routes through the running
## match's SimEntityState (scripts/sim/entity_state.gd) when this unit has
## one, then mirrors the result into global_position -- decision 3 makes the
## store authoritative and the node a view over it
## (docs/architecture/network-multiplayer.md, phase 3's C2 paragraph).
##
## Mirrors right here, at the write site, rather than once at the end of the
## simulation tick: _advance_locomotion_tick(), navigation_step() and every
## UnitFlightController transition all read global_position again later in
## the very same tick (the offset to target_position, the terrain-snap probe,
## flight_advance_transition_motion()'s own remaining-distance check, the next
## transition's motion target) to decide what they do next, so a mirror
## deferred to the end of the tick would hand that later code last tick's
## position instead of the one this call just produced. That is checked, not
## assumed -- see the call sites this replaces.
##
## _entity_id is 0 for the whole life of a unit built with no Match in the
## tree -- most unit/combat tests build a Unit directly (see
## _register_entity_id()'s own comment) -- and that is not an error: there is
## no store to be authoritative over, so this simply writes the node, exactly
## as every call site here did before this method existed.
##
## An id that IS assigned but that the registry reports dead is a different,
## genuine bug: sim_tick() and sim_tick_combat() are guarded by
## is_instance_valid() and _simulation_halted (see
## Match._advance_simulation_tick()), so nothing should reach here for a dead,
## still-registered id. SimEntityState.set_position() already refuses that
## write and push_errors it, loudly, by id. This still writes the node
## afterward regardless -- silently keeping the node's last position here
## would look exactly like a unit that legitimately stopped moving, which is
## precisely the bug a mirror can make plausible (see this method's own doc
## comment on the class, and the design doc's C2 paragraph). Writing the node
## keeps the visible symptom (a unit still moving while an error is logged for
## its dead id) instead of a quieter one (a unit that mysteriously stops),
## which is what gives a test or a log sweep an actual chance to catch it.
func set_simulation_position(value: Vector3) -> void:
	if _entity_id != 0:
		var store = MatchLookupScript.entity_state(self)
		if store != null:
			store.set_position(_entity_id, value)
	global_position = value


## This entity's simulation half: advances every turret's reload/burst
## countdown, then ground/generic locomotion and terrain snapping (see
## _advance_locomotion_tick()), then -- for a harvester -- the economy, all by
## exactly one simulation tick. Called once per simulation tick by
## Match._advance_simulation_tick() -- see its doc comment for why the tick is
## driven centrally instead of from this node's own _process(). Never call
## this from Unit itself.
##
## _harvester.advance() ends in HarvesterController._transfer_unload_credits()
## -> player.add_money(), and credits gate production: which tick a credit
## lands on must not depend on frame timing, so it advances here rather than
## from _process() below.
##
## Deliberately does not call sim_tick_combat() below, even though both run
## once per tick and both used to be one call: this function's own contents
## decide global_position (locomotion) and the reload countdown that Match's
## doc comment names as the reason "units" runs before "sim_linger_effects"
## and "sim_projectiles" -- a projectile resolves its hit against the fresh
## position this tick already produced. Combat's aim/attack/fire decisions
## carry no such freshness requirement (see sim_tick_combat()'s own comment),
## which is what leaves them free to run later, after this tick's projectile
## walk instead of before it.
func sim_tick() -> void:
	if _simulation_halted:
		return
	for turret in combat_turrets:
		turret.advance_tick()
	_advance_locomotion_tick()
	if _harvester != null:
		_harvester.advance(MatchClockScript.SECONDS_PER_TICK)


## This entity's other simulation half (B3c): target acquisition, attack
## order progression and authored fire-sequence committal -- everything
## UnitCombat.advance() decides, run once per simulation tick with a fixed
## MatchClock.SECONDS_PER_TICK delta instead of the render frame's variable
## one. Split from sim_tick() above into its own function, and its own later
## position in Match._advance_simulation_tick()'s group-loop order, rather
## than folded into that call: committing a shot here parents a
## CombatProjectile synchronously, which joins "sim_projectiles" in _ready()
## before this call returns, so this has to run *after* Match has already
## walked "sim_projectiles" for this tick -- otherwise a shot fired this tick
## would also travel this tick (see combat_projectile.gd and B3b's identical
## finding for buildings). sim_tick() above cannot simply move down there with
## it: locomotion's freshness requirement pulls the other way (see that
## function's comment), and nothing this function does sets global_position,
## changes health, or changes hit geometry -- it only reads _owner's current
## position/rotation, turns the hull (a rotation, not a position), zeroes
## velocity via stop_at_current_position(), or hands the navigation system a
## pursuit request that takes effect on a later tick regardless of where in
## this tick it was requested -- so running it after this tick's damage
## resolution costs the position freshness nothing while still fixing the
## same-tick travel hazard. Never call this from Unit itself.
func sim_tick_combat() -> void:
	if _simulation_halted:
		return
	_combat.advance(MatchClockScript.SECONDS_PER_TICK)


## True once prepare_model_for_corpse() has run and sim_tick() has stopped
## doing anything. The simulation-side counterpart to is_processing().
func is_simulation_halted() -> bool:
	return _simulation_halted


## Slice C5's single entry point for despawning a unit -- see
## docs/architecture/network-multiplayer.md's "Slice C5" paragraph. Every
## call site that used to call queue_free() on a unit directly (both branches
## of UnitDeathSequence.begin(), UnitDeploymentController's deploy-completion
## path) calls this instead, so "a unit is gone" resolves through one place
## instead of the five mechanisms that paragraph found doing the same job
## piecemeal.
##
## This is the only place that sets _simulation_halted -- not
## prepare_model_for_corpse() above, even for the branch that hands the model
## to a corpse; see that function's own comment for why pre-setting the flag
## there would make the return-early guard below trip on this function's
## first real call and skip index.request_release()/queue_free() entirely.
## Both UnitDeathSequence.begin() branches (a matched death clip and no clip
## at all) therefore reach this function still unhalted, and a caller never
## has to know or care which branch it was on.
##
## Idempotent anyway, checked first: a second call -- e.g. a unit that dies
## twice through two different call sites reached in the same synchronous
## chain, or a future caller this function was not written to anticipate --
## must not double-queue the entity or re-run set_process(false) redundantly.
##
## _entity_id != 0 alone is not enough to guard on -- MatchLookupScript.
## entity_index(self) can still be null even for a registered unit whose
## Match has already begun leaving the tree, and the reverse (an index with
## _entity_id still 0) cannot happen by construction, since _register_entity_id()
## is what sets both together -- but checking both costs nothing and states
## the real precondition rather than one half of it.
##
## The queue_free() fallback below is not a defensive extra: most unit and
## combat test suites (tests/combat/*) build a Unit with no Match anywhere in
## the tree at all (see _entity_id's own doc comment), so there is no
## EntityNodeIndex whose apply_pending_releases() will ever run for them --
## Match._advance_simulation_tick() does not exist to call it. Without this
## branch a killed unit in those suites would simply never be freed.
func request_despawn() -> void:
	if _simulation_halted:
		return
	_simulation_halted = true
	set_process(false)
	var index = MatchLookupScript.entity_index(self)
	if index != null and _entity_id != 0:
		index.request_release(_entity_id)
	else:
		queue_free()


func _process(delta: float) -> void:
	# Authored locomotion/fire overlays run before Unit (see
	# _prioritize_animations_before_unit_logic()). The combat-owned aim angle
	# (current_yaw/current_pitch) is simulation state now, advanced at most
	# once per tick by sim_tick_combat() above, which already repaints the
	# pivots with whatever it last computed -- see that function's comment.
	# This call is what repeats that paint on every frame *between* ticks:
	# unlike sim_tick_combat(), it is guaranteed to run every rendered frame,
	# which is what makes the turret hold its last simulated angle instead of
	# snapping back to a looping authored Stationary/Move/Deploy_Gun_Hold clip's
	# rest pose on a frame with no tick of its own.
	restore_combat_turret_poses()
	# Same ordering requirement as restore_combat_turret_poses() above: the
	# looping Deploy_Gun_Hold clip keys the turret pivot every frame, so
	# recentering it must also run after the AnimationPlayers apply this
	# frame's pose -- which only _process() is guaranteed to run after; the
	# simulation tick has no defined relationship to animation playback at
	# all -- or the animation's authored pose instantly overwrites each
	# gradual step, making the turret look like it never turns at all.
	if _deploy.advance_undeploy_alignment(delta):
		_deploy.start_undeploy_animation()
	_advance_visual_slope_alignment(delta)
	# Same _process (not the simulation tick) requirement as the two calls
	# above: the movement clip's playback position is only this frame's value
	# after the AnimationPlayers have run.
	_movement_sounds.advance(delta)
	_shader_fx.advance(delta, shields)


## Ground/generic locomotion's simulation half: driven from sim_tick() above,
## once per simulation tick, never from a per-frame callback -- Unit no
## longer defines _physics_process() at all. Folds in what that callback used
## to do, including the terrain snap (_snap_to_terrain() sets
## global_position.y, which is simulation state exactly like the rest of this
## method).
func _advance_locomotion_tick() -> void:
	var delta := MatchClockScript.SECONDS_PER_TICK
	# Captured before this tick's movement runs, so by the time anything
	# reads it later (death momentum, see _begin_death_sequence) it holds
	# "position at the start of the most recent simulation tick" -- equivalent
	# to updating it at the end of the previous call, but without duplicating
	# the assignment above every early return below.
	_previous_global_position = global_position
	if is_carried():
		velocity = Vector3.ZERO
		return
	if _advanced_carryall_transport != null:
		_advanced_carryall_transport.advance(delta)
	if _flight_controller != null and _flight_controller.flight_controls_transition():
		_flight_controller.advance(delta)
		return
	# A managed flyer receives its locked landing/docking tick through
	# navigation_step().  Without a navigation system there is no such callback,
	# so advance the flight-owned transition here and skip ordinary locomotion;
	# otherwise its stale target_position would pull against the Land approach.
	if _flight_controller != null \
	and _flight_controller.flight_navigation_is_locked() \
	and not _navigation_managed:
		_flight_controller.advance(delta)
		return
	if is_deploying():
		velocity = Vector3.ZERO
		if _deploy.advance_alignment(delta):
			_terrain_alignment.refresh_slope_target()
			_deploy.start_deploy_animation()
		return
	if is_deployed():
		velocity = Vector3.ZERO
		return
	# Match runs navigation_system.sim_tick() -- which moves every managed
	# unit through navigation_step() -- before the "units" group loop reaches
	# this unit's own sim_tick() (see match.gd's ordering comment). Both paths
	# now run on the same 25 Hz clock, so without this guard a managed unit
	# would be integrated a second time here, on top of what navigation_step()
	# already did this same tick.
	if _navigation_managed:
		return
	if _flight_controller != null and _flight_controller.circles_flight_enabled():
		var circles_velocity := _flight_controller.advance_circles_flight(
			_flight_controller.circles_desired_velocity(), delta
		)
		velocity = circles_velocity
		_set_navigation_debug_direction(circles_velocity)
		_set_movement_animation(true)
		_snap_to_terrain(delta)
		return
	_locomotion.advance_start_transition(delta)
	var offset := target_position - global_position
	offset.y = 0.0
	var requested_velocity := Vector3.ZERO
	var movement_speed := navigation_move_speed()
	var turn_animation := &""

	if offset.length() <= arrival_radius:
		velocity = Vector3.ZERO
	else:
		var direction := offset.normalized()
		requested_velocity = direction * movement_speed
		var heading_reached := _turn_toward(direction, delta)
		if can_move_any_direction or heading_reached:
			velocity = direction * movement_speed * _slope_speed_multiplier(direction, delta)
		else:
			velocity = Vector3.ZERO
		if not heading_reached:
			turn_animation = _locomotion.turn_animation_for(direction)

	_set_navigation_debug_direction(requested_velocity)
	var animation_speed_scale := _locomotion.movement_animation_speed_scale()
	_set_movement_animation(
		not velocity.is_zero_approx()
			or not turn_animation.is_empty()
			or _locomotion.transition_or_pause_has_move_order(),
		animation_speed_scale,
		turn_animation
	)
	if _locomotion.is_starting():
		velocity = Vector3.ZERO
	_locomotion.advance_gait(delta, animation_speed_scale)
	# move_and_slide() used to run here. It resolved no collision and returned
	# nothing anyone consulted: collision_mask is 0 (see _ready() -- terrain
	# height is sampled explicitly below, and letting the body collide with
	# the terrain mesh made every triangle edge act as a small wall), and
	# nothing in the project reads is_on_floor(), get_slide_collision(),
	# up_direction or motion_mode. So all it ever did was integrate position,
	# which this does explicitly instead, exactly like navigation_step()
	# already does for managed units. Separation between units is
	# OrcaAvoidance's job, on the navigation tick.
	set_simulation_position(global_position + velocity * delta)
	_snap_to_terrain(delta)


## `exit_point` is a mandatory first waypoint (a production building's front
## exit): the unit walks straight to it before regular routing takes over.
func move_to(world_position: Vector3, exit_point := Vector3.INF) -> void:
	if not _issuing_internal_navigation and not transport_accepts_regular_order():
		return
	if _flight_controller != null and not _issuing_internal_navigation:
		_flight_controller.cancel_pending_landing()
	if _flight_controller != null and _flight_controller.flight_is_landed():
		_flight_controller.begin_takeoff_toward(world_position, exit_point)
		return
	if _flight_controller != null:
		_flight_controller.set_circles_order(world_position)
	if _navigation_managed and _navigation_system != null:
		_navigation_system.command_move([self], world_position, NavConstantsScript.MoveMode.FREE, exit_point)
		return
	if not prepare_navigation_order(world_position, exit_point, 0):
		return
	# The navigation system registers freshly added units deferred, and the
	# registration resets the agent's destination to the unit's position. An
	# order issued in the spawn frame (the production rally point) is kept
	# here so the registration handoff can re-issue it.
	_pending_navigation_order = world_position
	_pending_navigation_exit = exit_point
	_has_pending_navigation_order = true
	target_position = Vector3(world_position.x, global_position.y, world_position.z)
	_set_movement_animation(global_position.distance_to(target_position) > arrival_radius)


## Called only by UnitRosterController right after producing a flying unit:
## the unit first moves along the apron to `exit_point`, then takes off clear of
## the producer and moves toward `rally_point`.
## Non-flying units fall back to an ordinary move order.
func begin_hangar_takeoff(rally_point: Vector3, exit_point: Vector3) -> bool:
	if _flight_controller == null:
		move_to(rally_point, exit_point)
		return true
	_flight_controller.begin_hangar_takeoff(rally_point, exit_point)
	return true


## True for every flight phase except grounded/landed. Used by the nav system
## (duck-typed, see UnitLocalAvoidance/UnitNavigationPlanner) to ignore
## buildings, and internally to route movement/animation through the
## flight controller. Always false for non-flying units.
func flight_is_airborne_phase() -> bool:
	return _flight_controller != null and _flight_controller.flight_is_airborne_phase()


## True while grounded/landed (including a flying unit that has not yet taken
## off). Also feeds combat_is_airborne() so a landed plane counts as a ground
## unit for targeting.
func flight_is_landed() -> bool:
	return _flight_controller == null or _flight_controller.flight_is_landed()


func flight_navigation_is_locked() -> bool:
	return _flight_controller != null and _flight_controller.flight_navigation_is_locked()


## UnitFlightController owns transition timing; Unit performs the corresponding
## owner-local horizontal transform and facing update. Returns true at target.
func flight_advance_transition_motion(
	world_position: Vector3, delta: float, align_to_motion := true
) -> bool:
	var offset := world_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	if distance <= 0.0001 or delta <= 0.0:
		velocity = Vector3.ZERO
		_set_navigation_debug_direction(Vector3.ZERO)
		return distance <= 0.0001
	var direction := offset / distance
	if align_to_motion:
		turn_toward(direction, delta)
	var step := minf(maxf(navigation_move_speed(), 0.0) * delta, distance)
	set_simulation_position(global_position + direction * step)
	velocity = direction * (step / delta)
	_set_navigation_debug_direction(velocity)
	return step >= distance - 0.0001


## Neutralize the normal route when Land takes ownership of horizontal motion.
func flight_stop_navigation_for_transition() -> void:
	if _navigation_managed and _navigation_system != null:
		_navigation_system.stop(self)
	else:
		target_position = global_position
		velocity = Vector3.ZERO
		_has_pending_navigation_order = false
		_pending_navigation_order = Vector3.ZERO
		_pending_navigation_exit = Vector3.INF


## Only Ornithopters (ammo-replenish docking) or carriers (pickup sequence) may
## ever leave cruise/hover to land; every other CanFly unit rejects this and
## only ever takes off once, at spawn. Distant requests fly normally until the
## Land clip can cover the remaining horizontal approach.
func flight_request_land(landing_position: Vector3, allowed_cells: Dictionary = {}) -> bool:
	return _flight_controller != null and _flight_controller.flight_request_land(landing_position, allowed_cells)


## Called by UnitLocalAvoidance when two air agents' lateral paths converge —
## blends this unit's altitude toward cruise_altitude + value.
func flight_set_vertical_offset(value: float) -> void:
	if _flight_controller != null:
		_flight_controller.flight_set_vertical_offset(value)


func flight_circles_enabled() -> bool:
	return _flight_controller != null and _flight_controller.circles_flight_enabled()


func flight_set_circles_order(destination: Vector3) -> void:
	if _flight_controller != null:
		_flight_controller.set_circles_order(destination)


func flight_clear_circles_order() -> void:
	if _flight_controller != null:
		_flight_controller.clear_circles_order()


func flight_circles_desired_velocity() -> Vector3:
	return _flight_controller.circles_desired_velocity() if _flight_controller != null else Vector3.ZERO


func flight_consume_circles_order_completed() -> bool:
	return _flight_controller.consume_circles_order_completed() if _flight_controller != null else false


## UnitFlightController calls this after an authored takeoff finishes. This is
## continuation of the order that initiated takeoff, not a fresh player order;
## in particular it must not cancel an Advanced Carryall pickup approach.
func flight_continue_navigation(world_position: Vector3, exit_point := Vector3.INF) -> void:
	_issuing_internal_navigation = true
	move_to(world_position, exit_point)
	_issuing_internal_navigation = false


## Flight-facing pickup sequence surface. AdvancedCarryallTransport schedules
## the phases; UnitFlightController owns their clips and vertical motion.
func flight_begin_pickup_sequence(
	landing_position := Vector3.INF, landing_clearance := 0.0
) -> void:
	if _flight_controller != null:
		_flight_controller.flight_begin_pickup_sequence(landing_position, landing_clearance)


func flight_advance_pickup(next_sub_phase: int) -> void:
	if _flight_controller != null:
		_flight_controller.flight_advance_pickup(next_sub_phase)


func flight_complete_pickup_sequence() -> void:
	if _flight_controller != null:
		_flight_controller.flight_complete_pickup_sequence()


func flight_pickup_transition_finished() -> bool:
	return _flight_controller != null and _flight_controller.flight_pickup_transition_finished()


func flight_transport_takeoff_finished() -> bool:
	return _flight_controller != null and _flight_controller.flight_transport_takeoff_finished()


## Narrow clip surface used by UnitFlightController; see
## UnitAnimationDirector.play_clip()/clip_length() for the lookups these wrap.
func flight_play_clip(clip_name: StringName, loop: bool, speed_scale: float = 1.0) -> AnimationPlayer:
	return _animation_director.play_clip(clip_name, loop, speed_scale)


func flight_clip_length(clip_name: StringName, fallback: float) -> float:
	return _animation_director.clip_length(clip_name, fallback)


## Narrow public surface used by UnitFlightController. Keeping these details
## on Unit preserves its ownership of terrain and presentation state without
## making the controller reach through to private implementation methods.
func flight_set_movement_animation(is_moving: bool) -> void:
	_set_movement_animation(is_moving)


func flight_snap_to_terrain() -> void:
	_terrain_snap_body()


func flight_set_visual_slope_target(terrain_normal: Vector3) -> void:
	_set_visual_slope_target(terrain_normal)


func flight_set_visual_bank(angle: float) -> void:
	_terrain_alignment.set_flight_bank(angle)


func flight_terrain_hit_at(position: Vector3) -> Dictionary:
	return _terrain_hit_at(position)


## Called by UnitNavigationSystem before it mutates an agent's route. Units may
## perform order-specific cleanup or return false to defer/reject the route.
## Unmanaged fallback movement uses the same API, keeping order preparation in
## the unit instead of teaching command controllers about unit state machines.
func prepare_navigation_order(
	world_position: Vector3, exit_point := Vector3.INF, move_mode := 0
	) -> bool:
	if not _issuing_internal_navigation and not transport_accepts_regular_order():
		return false
	if not can_receive_commands():
		return false
	# A harvester mid-unload answers a move order by finishing its clip first,
	# and takes the order back up when it does.
	if _harvester != null \
	and not _harvester.prepare_navigation_order(world_position, exit_point, move_mode):
		return false
	_combat.prepare_for_move_order()
	return not (is_deploying() or is_deployed())


func set_navigation_managed(active: bool) -> void:
	_navigation_managed = active
	if active:
		velocity = Vector3.ZERO
		_set_navigation_debug_direction(Vector3.ZERO)


func navigation_is_suspended() -> bool:
	return _navigation_suspended_for_transport


func set_navigation_controller(controller) -> void:
	if _harvester != null:
		_harvester.begin_navigation_handoff()
	_navigation_system = controller
	if _navigation_system != null and _has_pending_navigation_order:
		var order := _pending_navigation_order
		var exit_point := _pending_navigation_exit
		_has_pending_navigation_order = false
		_pending_navigation_exit = Vector3.INF
		move_to(order, exit_point)
	if _harvester != null:
		_harvester.end_navigation_handoff()


func set_navigation_destination(world_position: Vector3) -> void:
	target_position = Vector3(world_position.x, global_position.y, world_position.z)


func navigation_collision_radius(fallback: float) -> float:
	return _authored_collision.collision_radius(fallback)


func navigation_rotation_radius(fallback: float) -> float:
	return _authored_collision.rotation_radius(fallback)


func navigation_step(horizontal_velocity: Vector3, delta: float) -> void:
	if _flight_controller != null and _flight_controller.flight_controls_transition():
		_flight_controller.advance(delta)
		return
	if _flight_controller != null and _flight_controller.circles_flight_enabled():
		var circles_velocity := _flight_controller.advance_circles_flight(horizontal_velocity, delta)
		velocity = circles_velocity
		_set_navigation_debug_direction(horizontal_velocity)
		_set_movement_animation(true)
		_snap_to_terrain(delta)
		return
	if is_deploying() or is_deployed():
		velocity = Vector3.ZERO
		_set_navigation_debug_direction(Vector3.ZERO)
		return
	_locomotion.advance_start_transition(delta)
	# Preserve the requested course before a tracked unit possibly converts its
	# translational velocity to zero while turning in place. This is the value
	# shown by the selected-unit navigation debug arrow.
	_set_navigation_debug_direction(horizontal_velocity)
	velocity = Vector3(horizontal_velocity.x, 0.0, horizontal_velocity.z)
	var turn_animation := &""
	var steering_direction := velocity.normalized() \
		if velocity.length_squared() > 0.000001 else Vector3.ZERO
	if steering_direction.is_zero_approx() and _locomotion.wants_destination_heading():
		var destination_offset := target_position - global_position
		destination_offset.y = 0.0
		steering_direction = destination_offset.normalized()
	# Crowded units receive tiny non-zero velocities from collision resolution;
	# skip negligible motion so it cannot jitter the unit's heading.
	if not steering_direction.is_zero_approx():
		var heading_reached := _turn_toward(steering_direction, delta)
		if not can_move_any_direction and not heading_reached:
			velocity = Vector3.ZERO
		if not heading_reached:
			turn_animation = _locomotion.turn_animation_for(steering_direction)
	var animation_speed_scale := _locomotion.movement_animation_speed_scale()
	_set_movement_animation(
		not velocity.is_zero_approx()
			or not turn_animation.is_empty()
			or _locomotion.transition_or_pause_has_move_order(),
		animation_speed_scale,
		turn_animation
	)
	if _locomotion.is_starting():
		velocity = Vector3.ZERO
	_locomotion.advance_gait(delta, animation_speed_scale)
	# Unit/unit collision has already been resolved centrally as swept discs.
	# Applying the exact fixed navigation delta avoids depending on physics-frame
	# frequency and keeps command replays stable.
	set_simulation_position(global_position + velocity * delta)
	_snap_to_terrain(delta)


## The navigation solver must see the phase speed before avoidance is resolved;
## applying it afterwards would let following units plan through a mech that is
## currently in its slower between-step phase.
func navigation_move_speed() -> float:
	return _locomotion.navigation_move_speed()


## Public because UnitLocomotion asks for it: the order itself belongs to the
## facade (target_position plus the navigation system's arrival tolerance),
## the gait only reacts to it.
func has_active_move_order() -> bool:
	if _flight_controller != null and _flight_controller.circles_flight_enabled():
		return _flight_controller.circles_order_is_active()
	var tolerance := arrival_radius
	if (
		_navigation_managed
		and _navigation_system != null
		and _navigation_system.has_method("arrival_tolerance")
	):
		tolerance = maxf(
			tolerance,
			float(_navigation_system.call("arrival_tolerance", self))
		)
	var offset := target_position - global_position
	offset.y = 0.0
	return offset.length() > tolerance


func navigation_blocked_by_enemy(enemies: Array[Node3D]) -> void:
	if enemies.is_empty():
		return
	if has_method("attack_target"):
		call("attack_target", enemies[0])
	else:
		navigation_enemy_encountered.emit(enemies)


func _snap_to_terrain(delta: float = 0.0) -> void:
	if _flight_controller != null:
		_flight_controller.advance(delta)
		return
	_terrain_snap_body()


func _terrain_snap_body() -> void:
	_terrain_alignment.snap_body_to_terrain()


## Test-only shim: tests/match/demo_boot_run.gd calls this by name. Not
## architecture — the state lives in UnitTerrainAlignment.
func _set_visual_slope_target(terrain_normal: Vector3) -> void:
	_terrain_alignment.set_slope_target(terrain_normal)


## Test-only shim: tests/match/demo_boot_run.gd calls this by name.
func _advance_visual_slope_alignment(delta: float) -> void:
	_terrain_alignment.advance_slope_alignment(delta)


func aligns_visual_to_terrain_slope() -> bool:
	match slope_alignment_mode:
		SlopeAlignmentMode.ENABLED:
			return true
		SlopeAlignmentMode.DISABLED:
			return false
	if unit_definition == null:
		return false
	return (
		float(unit_definition.size) > 1.0
		and not unit_definition.infantry
		and not unit_definition.can_fly
		and not unit_definition.mech
		and config_id not in LEGACY_WALKER_UNIT_IDS
	)


func _slope_speed_multiplier(direction: Vector3, delta: float) -> float:
	return _terrain_alignment.slope_speed_multiplier(direction, delta)


## Rotates the hull toward `direction` by at most one tick's worth of yaw.
func turn_toward(direction: Vector3, delta: float) -> bool:
	return _terrain_alignment.turn_toward(direction, delta)


## Test-only shim: tests/match/demo_boot_run.gd calls this by name, and
## Harvester (harvester.gd) calls it as an inherited member.
func _turn_toward(direction: Vector3, delta: float) -> bool:
	return turn_toward(direction, delta)


func facing_direction() -> Vector3:
	return SpatialOrientationScript.world_forward(self)


func face_direction(direction: Vector3) -> void:
	var current_yaw := global_rotation.y if is_inside_tree() else rotation.y
	var target_yaw := SpatialOrientationScript.yaw_facing(direction, current_yaw)
	if is_inside_tree():
		global_rotation.y = target_yaw
		# Yaw moved, so the model's slope tilt is re-derived from the same
		# terrain normal rather than waiting for the next terrain sample.
		_terrain_alignment.refresh_slope_target()
	else:
		rotation.y = target_yaw


func _terrain_hit_at(position: Vector3) -> Dictionary:
	return _terrain_alignment.terrain_hit_at(position)


func setup(unit_id: StringName) -> void:
	_combat.detach_model()
	config_id = unit_id
	if not is_inside_tree():
		return

	_apply_unit_definition()
	_combat.refresh_weapon_runtime()
	_locomotion.refresh_motion_profile()
	_movement_sounds.refresh_step_schedule()
	health = max_health
	shields = max_shields
	_terrain_alignment.refresh_slope_target()


## Used by runtime unit production and startup snapshots when a generic Unit
## scene must display a different converted model.
func replace_visual_scene(model_scene: PackedScene) -> void:
	if model_scene == null or visual_root == null:
		return
	_combat.detach_model()
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(model_scene.instantiate())
	_combat.bind_combat_turrets()
	_shader_fx.attach_model()
	var players := _animation_director.refresh(visual_root)
	_locomotion.attach_model(players)
	_movement_sounds.attach_model(players)
	_combat.refresh_weapon_runtime()
	_locomotion.refresh_motion_profile()
	_movement_sounds.refresh_step_schedule()
	_animation_director.prioritize_before(process_priority)
	_prepare_idle_animations()
	_set_movement_animation(false)
	# Packed model scenes keep gameplay-controlled effect meshes hidden and
	# carry no per-instance owner color. Reapply the unit's current runtime
	# state after swapping the visual (for example during F7 snapshot restore).
	_refresh_shield_visibility()
	_refresh_owner_visuals()
	_rebuild_selection_halo()


## --- Advanced Carryall transport facade ---------------------------------
##
## These are intentionally the only calls the transport state machine makes
## into Unit.  It never reads Unit's private navigation/combat/visual fields;
## Unit remains responsible for its own scene-tree and sibling modules.

func is_advanced_carryall() -> bool:
	return unit_definition != null \
		and bool(unit_definition.can_fly) \
		and bool(unit_definition.advanced_carryall)


func has_transport_cargo() -> bool:
	return _advanced_carryall_transport != null and _advanced_carryall_transport.has_cargo()


func can_offer_transport_pickup() -> bool:
	return is_advanced_carryall() and _advanced_carryall_transport != null \
		and _advanced_carryall_transport.can_offer_pickup()


func can_offer_transport_drop() -> bool:
	return is_advanced_carryall() and _advanced_carryall_transport != null \
		and _advanced_carryall_transport.can_offer_drop()


func transport_cargo() -> Node3D:
	return _advanced_carryall_transport.cargo() if _advanced_carryall_transport != null else null


func transport_state_name() -> StringName:
	return _advanced_carryall_transport.state_name() if _advanced_carryall_transport != null else &"idle"


func can_pickup(target: Node3D) -> bool:
	return is_advanced_carryall() and _advanced_carryall_transport != null \
		and _advanced_carryall_transport.can_pickup(target)


func command_pickup(target: Node3D) -> bool:
	return can_pickup(target) and _advanced_carryall_transport.command_pickup(target)


func can_drop_at(world_position: Vector3) -> bool:
	return is_advanced_carryall() and _advanced_carryall_transport != null \
		and _advanced_carryall_transport.can_drop_at(world_position)


func command_drop(world_position: Vector3) -> bool:
	return can_drop_at(world_position) and _advanced_carryall_transport.command_drop(world_position)


func is_carried() -> bool:
	return _transport_carrier() != null


func can_receive_commands() -> bool:
	return not is_carried() and not _transport_docking_locked \
		and not (_advanced_carryall_transport != null and _advanced_carryall_transport.is_command_locked())


## Selection has a narrower contract than command acceptance: a transport
## remains visibly selected through its locked landing/docking animation, but
## a cargo that is carried or command-locked must disappear from selection.
func can_remain_selected() -> bool:
	return not is_carried() and not _transport_docking_locked


func can_perform_combat() -> bool:
	return can_receive_commands()


func can_be_picked_up_by(carrier: Node3D) -> bool:
	if carrier == null or carrier == self or not combat_is_alive() or is_carried():
		return false
	if unit_definition == null or bool(unit_definition.infantry) or bool(unit_definition.can_fly):
		return false
	# Advanced Carryalls only lift mobile ground vehicles.  Use the runtime
	# speeds so a mission may intentionally make an otherwise normal vehicle
	# stationary without changing its generated definition resource.
	if maxf(move_speed, mech_speed) <= 0.0:
		return false
	if is_deploying() or is_deployed():
		return false
	var reserved := _transport_reservation()
	return reserved == null or reserved == carrier


func reserve_for_transport(carrier: Node3D) -> bool:
	if not can_be_picked_up_by(carrier):
		return false
	_transport_reservation_ref = weakref(carrier)
	return true


func is_reserved_for_transport(carrier: Node3D) -> bool:
	return _transport_reservation() == carrier


func transport_lock_for_docking(carrier: Node3D) -> void:
	if _transport_reservation() != carrier:
		return
	cancel_all_orders()
	_transport_docking_locked = true


func transport_unlock_after_abort(carrier: Node3D) -> void:
	if _transport_reservation() != carrier:
		return
	_transport_docking_locked = false
	_transport_reservation_ref = null


func transport_target_is_enemy(target: Node3D) -> bool:
	if target == null or not target.has_method("combat_owner_player_id"):
		return false
	var players = _players()
	return players != null and players.are_enemies(
		owner_player_id, int(target.call("combat_owner_player_id"))
	)


func transport_move_toward(world_position: Vector3) -> void:
	_issuing_internal_navigation = true
	if _navigation_managed and _navigation_system != null:
		_navigation_system.command_move([self], world_position, NavConstantsScript.MoveMode.FREE)
	else:
		move_to(world_position)
	_issuing_internal_navigation = false


## Semantic handoff between transport approach and authored landing. Navigation
## verifies that this exact destination is still active; the flight controller
## supplies the speed-by-Land-duration radius for the animation handoff.
func transport_approach_reached(world_position: Vector3) -> bool:
	var approach_radius := _flight_controller.flight_landing_approach_radius() \
		if _flight_controller != null else arrival_radius
	if _navigation_managed and _navigation_system != null \
	and _navigation_system.has_method("destination_reached"):
		return bool(_navigation_system.call(
			"destination_reached", self, world_position, approach_radius
		))
	var assigned_offset := target_position - world_position
	assigned_offset.y = 0.0
	var remaining := world_position - global_position
	remaining.y = 0.0
	return assigned_offset.length_squared() <= 0.0001 \
		and remaining.length() <= maxf(arrival_radius, approach_radius)


func transport_align_with(target: Node3D, delta: float) -> bool:
	if target == null or not target.has_method("facing_direction"):
		return true
	return turn_toward(target.call("facing_direction") as Vector3, delta)


func transport_align_with_point(world_position: Vector3, delta: float) -> bool:
	var direction := world_position - global_position
	direction.y = 0.0
	return turn_toward(direction, delta)


func transport_track_pickup_landing(target: Node3D, delta: float) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	# FlightController owns both the Land descent and its horizontal approach.
	# Retargeting each tick lets a still-mobile reserved unit be followed without
	# teleporting the carrier directly above it.
	if _flight_controller != null:
		_flight_controller.flight_update_pickup_landing_target(target.global_position)
	return transport_align_with(target, delta)


func transport_stop_for_docking() -> void:
	# Do not call cancel_all_orders(): its public Stop path intentionally aborts
	# an APPROACH transport.  This is the lower-level route neutralization used
	# after the transport FSM itself has committed to a dock transition.
	flight_stop_navigation_for_transition()
	if _flight_controller != null:
		_flight_controller.clear_circles_order()


func transport_can_drop_cargo_at(cargo: Node3D, world_position: Vector3) -> bool:
	if cargo == null or not is_instance_valid(cargo):
		return false
	if _navigation_system != null and _navigation_system.has_method("can_place_transport_cargo"):
		return bool(_navigation_system.call("can_place_transport_cargo", cargo, world_position, self))
	# Small test fixtures do not create navigation; accepting a finite point
	# preserves the same direct-movement fallback used by ordinary Units.
	return world_position.is_finite()


func transport_bounds_half_height() -> float:
	var bounds := _selection_bounds()
	return maxf(bounds.size.y * 0.5, 0.25)


func transport_vertical_bounds() -> Vector2:
	if _transport_has_carried_vertical_bounds:
		return _transport_carried_vertical_bounds
	if _transport_has_carrier_vertical_bounds:
		return _transport_carrier_vertical_bounds
	var bounds := _selection_bounds()
	return Vector2(bounds.position.y, bounds.end.y) if bounds.size.y > 0.0 else Vector2(-0.25, 0.25)


func transport_attach_cargo(cargo: Node3D, anchor_offset: Vector3) -> void:
	if cargo == null or not is_instance_valid(cargo):
		return
	var anchor := _ensure_transport_cargo_anchor()
	var carrier_bounds := transport_vertical_bounds()
	_transport_carrier_vertical_bounds = carrier_bounds
	_transport_has_carrier_vertical_bounds = true
	var cargo_bounds_before: Vector2 = cargo.call("transport_vertical_bounds") as Vector2 \
		if cargo.has_method("transport_vertical_bounds") else Vector2(-0.5, 0.5)
	var docking_gap := carrier_bounds.x - cargo_bounds_before.y - anchor_offset.y
	_transport_docking_gap = docking_gap
	_set_transport_anchor_offset(anchor, anchor_offset)
	if cargo.has_method("transport_mark_carried"):
		cargo.call("transport_mark_carried", self)
	cargo.call("transport_reparent_to", anchor, false)
	cargo.transform = Transform3D.IDENTITY
	anchor.force_update_transform()
	cargo.force_update_transform()
	# Once cargo is nested below VisualRoot, an uncached recursive bounds query
	# would include its markers as though they belonged to the carrier hull.
	# Refresh through the cached carrier/cargo bounds captured before reparenting.
	_refresh_transport_cargo_anchor(cargo)


func _refresh_transport_cargo_anchor(cargo: Node3D) -> void:
	if cargo == null or not is_instance_valid(cargo) \
	or _transport_cargo_anchor == null or not is_instance_valid(_transport_cargo_anchor):
		return
	var cargo_bounds: Vector2 = cargo.call("transport_vertical_bounds") as Vector2 \
		if cargo.has_method("transport_vertical_bounds") else Vector2(-0.5, 0.5)
	var anchor_offset := Vector3(
		0.0,
		transport_vertical_bounds().x - cargo_bounds.y - _transport_docking_gap,
		0.0
	)
	_set_transport_anchor_offset(_transport_cargo_anchor, anchor_offset)
	_transport_cargo_anchor.force_update_transform()
	cargo.force_update_transform()


func transport_detach_cargo(cargo: Node3D, original_parent: Node, world_position: Vector3) -> void:
	if cargo == null or not is_instance_valid(cargo):
		return
	var destination_parent := original_parent
	if destination_parent == null or not is_instance_valid(destination_parent):
		destination_parent = EntityQueryScript.units_parent(get_tree(), get_parent())
	if destination_parent != null:
		cargo.call("transport_reparent_to", destination_parent, true)
	if cargo.has_method("transport_mark_released"):
		cargo.call("transport_mark_released", world_position, facing_direction())
	_transport_docking_gap = 0.0
	_transport_has_carrier_vertical_bounds = false


func transport_release_destroyed_cargo(cargo: Node3D, original_parent: Node) -> void:
	if cargo == null or not is_instance_valid(cargo):
		return
	var destination_parent := original_parent
	if destination_parent == null or not is_instance_valid(destination_parent):
		destination_parent = EntityQueryScript.units_parent(get_tree(), get_parent())
	if destination_parent != null:
		cargo.call("transport_reparent_to", destination_parent, true)
	if cargo.has_method("transport_mark_destroyed_release"):
		cargo.call("transport_mark_destroyed_release")
	_transport_docking_gap = 0.0
	_transport_has_carrier_vertical_bounds = false


func transport_cargo_destroyed(cargo: Node3D) -> void:
	if _advanced_carryall_transport != null:
		_advanced_carryall_transport.cargo_destroyed(cargo)


## The cargo Unit owns its temporary SceneTree exit guard so terminal module
## disposal remains correct even when an entire carried hierarchy is freed.
func transport_reparent_to(new_parent: Node, keep_global_transform: bool) -> void:
	if new_parent == null or not is_instance_valid(new_parent):
		return
	_transport_reparenting = true
	reparent(new_parent, keep_global_transform)
	_transport_reparenting = false


func transport_accepts_regular_order() -> bool:
	return _advanced_carryall_transport == null or _advanced_carryall_transport.accepts_regular_order()


func transport_abort_docking_recover() -> void:
	if _flight_controller != null:
		_flight_controller.flight_complete_pickup_sequence()


func transport_mark_carried(carrier: Node3D) -> void:
	_transport_carried_vertical_bounds = transport_vertical_bounds()
	_transport_has_carried_vertical_bounds = true
	_transport_carrier_ref = weakref(carrier)
	_transport_reservation_ref = null
	_transport_docking_locked = false
	cancel_all_orders()
	_reset_locomotion_after_transport()
	_navigation_suspended_for_transport = true
	if _navigation_system != null and _navigation_system.has_method("suspend_unit"):
		_navigation_system.call("suspend_unit", self)


func transport_mark_released(world_position: Vector3, carrier_facing: Vector3) -> void:
	_transport_carrier_ref = null
	_transport_has_carried_vertical_bounds = false
	_transport_reservation_ref = null
	_transport_docking_locked = false
	set_simulation_position(world_position)
	face_direction(carrier_facing)
	_terrain_snap_body()
	_reset_locomotion_after_transport()
	_navigation_suspended_for_transport = false
	if _navigation_system != null and _navigation_system.has_method("resume_unit"):
		_navigation_system.call("resume_unit", self)


func _reset_locomotion_after_transport() -> void:
	_idle_animations.reset()
	_locomotion.reset_to_idle(_idle_animations.play_sequence)
	_movement_sounds.notify_movement_state(false)
	restore_combat_turret_poses()


func transport_mark_destroyed_release() -> void:
	_transport_carrier_ref = null
	_transport_has_carried_vertical_bounds = false
	_transport_reservation_ref = null
	_transport_docking_locked = false
	_navigation_suspended_for_transport = true


func _ensure_transport_cargo_anchor() -> Node3D:
	if _transport_cargo_anchor != null and is_instance_valid(_transport_cargo_anchor):
		return _transport_cargo_anchor
	_transport_cargo_anchor = Node3D.new()
	_transport_cargo_anchor.name = "CargoAnchor"
	# The visual root contains the carrier's authored slope/bank transform.
	# Parenting here makes the cargo inherit translation plus yaw, pitch and
	# roll as a real descendant rather than copying a partial transform.
	var anchor_parent: Node = visual_root if visual_root != null else self
	anchor_parent.add_child(_transport_cargo_anchor)
	if visual_root != null:
		_transport_cargo_anchor.basis = _terrain_alignment.visual_rest_basis_inverse()
	return _transport_cargo_anchor


func _set_transport_anchor_offset(anchor: Node3D, unit_local_offset: Vector3) -> void:
	if visual_root == null or anchor.get_parent() != visual_root:
		anchor.position = unit_local_offset
		return
	# CargoAnchor lives below VisualRoot to inherit presentation pitch and roll,
	# but its authored offset is expressed in Unit-local coordinates. Undo the
	# model conversion rest basis when assigning that point, just as the anchor
	# basis itself is corrected in _ensure_transport_cargo_anchor().
	anchor.position = _terrain_alignment.visual_rest_basis_inverse() \
		* (unit_local_offset - visual_root.position)


func _transport_carrier() -> Node3D:
	var carrier: Variant = _transport_carrier_ref.get_ref() if _transport_carrier_ref != null else null
	return carrier as Node3D if carrier != null and is_instance_valid(carrier) else null


func _transport_reservation() -> Node3D:
	var reservation: Variant = _transport_reservation_ref.get_ref() if _transport_reservation_ref != null else null
	return reservation as Node3D if reservation != null and is_instance_valid(reservation) else null


func set_invulnerable(value: bool) -> void:
	invulnerable = value


func grant_temporary_invulnerability(duration: float) -> void:
	# Mirrors Building.set_invulnerable/take_damage; used e.g. by
	# BuildingSurvivors for the 1s post-spawn splash immunity from §2.1.
	invulnerable = true
	get_tree().create_timer(duration).timeout.connect(_clear_invulnerability)


func take_damage(amount: float, death_cause: StringName = &"") -> void:
	# The arithmetic is shared with Building.take_damage(); applying it is not,
	# because the health/shields setters here run unit-specific side effects.
	var outcome := DamagePolicyScript.resolve(amount, health, shields, invulnerable)
	if outcome.absorbed_by_shields > 0.0:
		shields -= outcome.absorbed_by_shields
	if outcome.health_delta == 0.0:
		return
	health += outcome.health_delta
	if outcome.is_lethal:
		_begin_death_sequence(death_cause)


## Transport destruction is a lifecycle rule, not an attack.  It must destroy
## the attached cargo even if a scripted scenario made that vehicle normally
## invulnerable; this narrow bypass is never used by combat damage.
func force_transport_death(death_cause: StringName = &"transport_destroyed") -> void:
	if not combat_is_alive():
		return
	invulnerable = false
	shields = 0.0
	health = 0.0
	_begin_death_sequence(death_cause)


func combat_armour_type() -> StringName:
	return armour_type


func combat_is_airborne() -> bool:
	if is_carried():
		return true
	if _advanced_carryall_transport != null and _advanced_carryall_transport.counts_as_ground_target():
		# Pickup/drop landing and docking deliberately expose the carrier as a
		# ground target even though its flight controller owns the transition.
		return false
	return unit_definition != null and unit_definition.can_fly and not flight_is_landed()


## Entry point kept on the facade: take_damage() calls it, and the surrounding
## docs (death_corpse.gd, unit_death_strategy.gd) name it. Everything it used
## to do lives in UnitDeathSequence; _previous_global_position is the facade's
## own bookkeeping and is handed over by value.
func _begin_death_sequence(cause: StringName) -> void:
	if is_carried():
		var carrier := _transport_carrier()
		if carrier != null and carrier.has_method("transport_cargo_destroyed"):
			carrier.call("transport_cargo_destroyed", self)
		_transport_carrier_ref = null
	if _advanced_carryall_transport != null:
		_advanced_carryall_transport.on_owner_death()
	_death_sequence.begin(cause, _previous_global_position)


## Scrubs the runtime state Unit bound onto the model subtree before handing
## it to the corpse: an unbound combat turret, a lit shield/scroll-fx mesh or
## a leftover fire-overlay AnimationPlayer would otherwise keep acting like a
## live unit under the corpse's ownership.
##
## THIS IS THE HANDOFF NEUTRALIZATION STEP. queue_free() does not stop the
## rest of this frame's ticks or signal emissions — cdc79b6 and 2b745b2 were
## the same defect (a "dead" unit still running code that reaches into a
## subtree it no longer owns) caught at two different symptom sites. Rather
## than trust that every future caching site gets remembered by hand, this
## function is the single place that must be extended whenever a new field
## caches a reference into `model`'s subtree, or a new signal gets connected
## onto one of its nodes: everything below is redundant with
## tests/units/death_animation_run.gd's reflection-based invariant test,
## which walks this instance's own script variables after a death and fails
## if anything still points at a node under the corpse — so forgetting an
## entry here fails loudly in that test rather than regressing silently.
func prepare_model_for_corpse(model: Node3D) -> void:
	# Must run before any overlay player is freed below: a fire sequence's
	# state dict can still hold that same player in state["player"], and
	# freeing it out from under a live entry leaves a dangling reference that
	# _exit_tree()'s teardown (_combat.dispose()) would later cast. Also drops
	# the fire-while-moving overlay AnimationPlayers, same as every other
	# pre-teardown call site (setup(), replace_visual_scene()) that calls this.
	_combat.detach_model()
	for turret in combat_turrets:
		turret.unbind_model()
	_shader_fx.detach_model()
	# Generic: disconnect every signal connection THIS unit made onto `model`
	# or any of its descendants, regardless of which signal or when it was
	# connected. This is what closes _prepare_idle_animations()'s
	# `player.animation_finished.connect(_on_animation_finished.bind(player))`
	# (the connection lives on the AnimationPlayer node handed to the corpse,
	# not on this Unit, so clearing the director's players below never touched
	# it) without needing to know the exact signal/callable shape, and
	# without needing to be revisited if a future change adds another
	# connection onto a model node.
	_sever_connections_into(model)
	# The model subtree (and every AnimationPlayer/mesh inside it) now belongs
	# to the corpse. Direct references into it must be dropped too — a signal
	# disconnect alone does not help a plain field that some other code path
	# reads without going through a signal.
	_animation_director.clear()
	_locomotion.detach_model()
	_movement_sounds.detach_model()
	# UnitDeployState caches the transition AnimationPlayer straight out of
	# the model. Unlike the director's array it is a scalar that keeps pointing
	# at that player until explicitly cleared — nothing else resets it on
	# death, so a unit killed while deploying kept a live direct pointer into
	# the corpse's subtree. This is the newly-found third site in the same
	# class as cdc79b6/2b745b2.
	_deploy.detach_model()
	# _on_animation_finished no longer calls into the flight controller at all
	# (B3d removed notify_animation_finished(): the Fly<->Hover transition now
	# completes on a tick deadline, not the clip's signal), and the controller
	# itself caches no AnimationPlayer to begin with. Nulled anyway, purely
	# defensively, so a still-pending tick this frame (see set_process(false)
	# below) cannot reach a controller whose _unit is this half-torn-down
	# instance.
	_flight_controller = null
	# queue_free() does not stop this frame's remaining _process() call, so
	# without halting processing here, a still-pending tick (e.g. a blocking
	# fire sequence's was_blocking branch in _finish_fire_sequence_for calling
	# _set_movement_animation) can still run this frame and try to act on a
	# unit that has already given everything away.
	set_process(false)
	# The simulation half's own stop is deliberately NOT set here. It used to
	# be ("_simulation_halted = true", pre-C5's request_despawn()), and that
	# looked harmless -- pure redundancy, since request_despawn() sets the
	# identical flag a few statements later in this same synchronous
	# UnitDeathSequence.begin() call. It is not harmless: request_despawn()
	# opens with `if _simulation_halted: return`, so pre-setting the flag here
	# makes that later call a no-op -- it never reaches index.request_release()
	# or its own queue_free() fallback, so the unit is never actually freed
	# and its id is never released. That is exactly the hazard
	# Building.prepare_model_for_corpse()'s own comment already argues for the
	# identical shape on the building side; this function now matches it.
	# request_despawn() (below in this file) is the single place that halts
	# the simulation, for both this corpse branch and the no-clip branch that
	# used to set nothing at all.


## Disconnects every signal connection this Unit made onto `subtree_root` or
## any of its descendants. Generic on purpose: rather than track down each
## individual `.connect()` call site that targets a model node (today just
## _prepare_idle_animations()'s animation_finished hookup, but nothing stops
## a future change from adding another), this walks every signal already
## live on the subtree at handoff time and drops any connection whose
## callable belongs to `self`. Connections other objects made onto these
## nodes (e.g. DeathCorpse's own animation_finished hookup, added after this
## runs) are left untouched.
func _sever_connections_into(subtree_root: Node) -> void:
	var stack: Array[Node] = [subtree_root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		for child in node.get_children():
			stack.append(child)
		for signal_info: Dictionary in node.get_signal_list():
			var signal_name := StringName(signal_info.get("name", &""))
			for connection: Dictionary in node.get_signal_connection_list(signal_name):
				var callable := connection.get("callable") as Callable
				if callable.get_object() == self:
					node.disconnect(signal_name, callable)


func combat_aim_position() -> Vector3:
	# The gameplay root sits on the terrain. A projectile aimed there forces
	# horizontal-only weapons to compare their muzzle direction with a point
	# below the target, so they can turn in yaw forever without ever satisfying
	# the pitch tolerance. The converted selection volume follows the visible
	# body and gives combat a stable centre point after runtime model swaps.
	return to_global(_selection_bounds().get_center())


func combat_is_alive() -> bool:
	return health > 0.0 and not is_queued_for_deletion()


func combat_hit_radius() -> float:
	return maxf(arrival_radius, 0.25)


func combat_owner_player_id() -> int:
	# Stable combat-facing ownership contract used for friendly-fire scaling.
	return owner_player_id


## Test-only accessor into the combat module: tests/combat/unit_fire_movement_run.gd,
## tests/units/death_animation_run.gd and tests/units/deployment_run.gd reach
## fire-sequence/turret-engagement internals through this rather than Unit
## re-exposing them itself. Not architecture.
func combat():
	return _combat


## Rotates every authored weapon joint toward a world-space point. The return
## value becomes true only when every configured weapon is inside its own
## acceptable-aim tolerance from Rules.txt.
func aim_turrets_at(world_position: Vector3, delta: float) -> bool:
	return _combat.aim_turrets_at(world_position, delta)


## Returns world transforms/positions/directions for every authored muzzle of
## one weapon. Multi-barrel weapons expose all >> markers beneath their ::N
## pivot instead of confusing muzzle numbers with weapon numbers.
func turret_emission_points(weapon_index: int = 0) -> Array[Dictionary]:
	return _combat.turret_emission_points(weapon_index)


## Selects the next muzzle in authored marker order and advances the sequence.
func next_turret_emission(weapon_index: int = 0) -> Dictionary:
	return _combat.next_turret_emission(weapon_index)


## Fires one rules-backed weapon from its next authored muzzle. A live target
## remains attached only for homing; ordinary projectiles keep this frame's
## position, matching the original no-lead behavior.
func fire_weapon_at(
		target_or_position: Variant,
		weapon_index: int = 0,
		projectile_parent: Node = null,
		aim_offset := Vector3.ZERO
	) -> Array:
	return _combat.fire_weapon_at(target_or_position, weapon_index, projectile_parent, aim_offset)


func can_attack(target_or_position: Variant) -> bool:
	return _combat.can_attack(target_or_position)


## Installs an explicit player attack order. A Node target is tracked until it
## dies; a Vector3 remains a fixed attack-ground coordinate. Relation checks
## belong to UnitCommandController so Ctrl can deliberately force friendly or
## neutral fire through this same combat-facing API.
func command_attack(target_or_position: Variant) -> bool:
	return _combat.command_attack(target_or_position)


func cancel_attack_order() -> void:
	_combat.cancel_attack_order()


func has_attack_order() -> bool:
	return _combat.has_attack_order()


func has_active_order() -> bool:
	return has_attack_order() \
		or is_deploying() \
		or has_active_move_order() \
		or (_harvester != null and _harvester.has_active_order())


func attack_order_target() -> Variant:
	return _combat.attack_order_target()


## Callbacks _combat reaches through Node.call() (see building.gd:675 for the
## pattern this mirrors) so the module can raise the facade's own signals
## without a private reach into them.
func _emit_attack_order_changed(active: bool, target: Variant) -> void:
	attack_order_changed.emit(active, target)


func _emit_weapon_fired(projectiles: Array, target: Variant, weapon_index: int) -> void:
	weapon_fired.emit(projectiles, target, weapon_index)


## Deployed state always resolves the single canonical Deployed_Fire clip;
## the ordinary Fire_<index> chain is travel-mode only. See
## unit_combat.gd:fire_animation_binding() for the full lookup this wraps.
## Public because UnitFireOverlay calls it by name.
func fire_animation_binding(weapon_index: int) -> Dictionary:
	return _combat.fire_animation_binding(weapon_index)


## Narrow navigation surface for UnitAttackOrder: pursuit needs to know
## whether the current route is hopeless, where it could stand to shoot from,
## and how to ask for a move — but not which navigation system is in play, or
## whether this unit is managed by one at all.
func navigation_route_is_unreachable() -> bool:
	return _navigation_managed \
		and _navigation_system != null \
		and _navigation_system.has_method("route_is_unreachable") \
		and bool(_navigation_system.call("route_is_unreachable", self))


func navigation_reachable_attack_position(
	target_world_position: Vector3, maximum_range: float, probe := Callable()
) -> Vector3:
	if not _navigation_managed \
	or _navigation_system == null \
	or not _navigation_system.has_method("reachable_attack_position"):
		return Vector3.INF
	if probe.is_null():
		return _navigation_system.call(
			"reachable_attack_position", self, target_world_position, maximum_range
		)
	return _navigation_system.call(
		"reachable_attack_position", self, target_world_position, maximum_range, probe
	)


## Perch search biased toward this unit's own slot on the group's firing arc.
## Degrades to navigation_reachable_attack_position() when no arc was assigned
## or the navigation system predates the call.
func navigation_reachable_firing_position(
	target_world_position: Vector3,
	maximum_range: float,
	preferred_direction: Vector3,
	preferred_range: float,
	probe := Callable()
) -> Vector3:
	if not _navigation_managed \
	or _navigation_system == null \
	or not _navigation_system.has_method("reachable_firing_position"):
		return navigation_reachable_attack_position(
			target_world_position, maximum_range, probe
		)
	return _navigation_system.call(
		"reachable_firing_position", self, target_world_position, maximum_range,
		preferred_direction, preferred_range, probe
	)


## Marks this unit as standing on a firing position, so arriving squadmates
## steer around it instead of shoving it off its spot mid-clip. Owned by
## UnitAttackOrder; public only because the navigation system is Unit's.
func set_navigation_firing_anchor(active: bool) -> void:
	if _navigation_managed and _navigation_system != null \
	and _navigation_system.has_method("set_firing_anchor"):
		_navigation_system.call("set_firing_anchor", self, active)


## The bearing this unit should engage its current attack target from, assigned
## per command by UnitNavigationSystem.assign_attack_arcs().
func set_attack_arc_direction(direction: Vector3) -> void:
	_combat.set_attack_arc_direction(direction)


## Ring the group's arc pitch is measured on: how far out this unit prefers to
## stand when engaging `target_or_position`. Zero when it cannot engage it.
func attack_engagement_radius(target_or_position: Variant) -> float:
	return _combat.attack_engagement_radius(target_or_position)


## Issues the pursuit move and returns whether navigation accepted it. The
## note_issuing_attack_move() bracket tells _combat.prepare_for_move_order()
## (reached through prepare_navigation_order()) that the move it is about to
## see is this pursuit's own, not a player order.
func issue_attack_move(pursuit_position: Vector3) -> bool:
	_combat.note_issuing_attack_move(true)
	var move_issued := true
	if _navigation_managed and _navigation_system != null:
		var assignments: Array = _navigation_system.command_move(
			[self], pursuit_position, NavConstantsScript.MoveMode.FREE
		)
		move_issued = not assignments.is_empty()
	else:
		move_to(pursuit_position)
	_combat.note_issuing_attack_move(false)
	return move_issued


func stop_at_current_position() -> void:
	if _navigation_managed and _navigation_system != null:
		_navigation_system.stop(self)
	target_position = global_position
	velocity = Vector3.ZERO
	_set_navigation_debug_direction(Vector3.ZERO)
	_set_movement_animation(false)


## Shared Stop-command contract. Stopping also breaks a harvester's autonomous
## economy loop, which would otherwise pick a new field on the next tick.
func cancel_all_orders() -> bool:
	var cancelled_transport := false
	if _advanced_carryall_transport != null:
		cancelled_transport = _advanced_carryall_transport.cancel_pending_order()
	var had_order := (
		has_attack_order()
		or _has_pending_navigation_order
		or has_active_move_order()
	)
	if had_order:
		cancel_attack_order()
		_has_pending_navigation_order = false
		_pending_navigation_order = Vector3.ZERO
		_pending_navigation_exit = Vector3.INF
		stop_at_current_position()
	var had_harvester_order: bool = _harvester != null and _harvester.cancel_all_orders()
	return had_order or had_harvester_order or cancelled_transport


## Shared unit deployment interface. Eligibility and the per-unit strategy
## live in UnitDeploymentController; UnitDeployState owns the common locked
## alignment and animation phases so future deployable units can reuse the
## same contract.
func deploy(desired_facing: Vector3 = Vector3.ZERO) -> bool:
	if not can_receive_commands():
		return false
	return _deploy.begin_deploy(desired_facing)


func undeploy() -> bool:
	if not can_receive_commands():
		return false
	return _deploy.begin_undeploy()


## Shared "first player owning one of these candidate clips" scan, in
## candidate-preference order. Used by both deployment transitions and death
## animation selection (_begin_death_sequence) so the two don't drift apart.
func find_animation_clip(candidates: Array[StringName]) -> Dictionary:
	return _animation_director.find_clip(candidates)


## Both transition directions count as "deploying" for every gameplay lock: a
## unit is equally immobile while folding out and while folding back in.
func is_deploying() -> bool:
	return _deploy.is_transitioning()


func is_deployed() -> bool:
	return _deploy.is_deployed()


## See UnitDeployState.is_undeploying(): used by idle-animation selection to
## keep showing the deployed pose while the turret-recenter gate runs.
func is_undeploying() -> bool:
	return _deploy.is_undeploying()


## Public because UnitDeployState defers to it when a model has no authored
## transition clip: the signal belongs to the Unit its subscribers hold.
func emit_deployment_animation_finished() -> void:
	if is_deploying():
		deployment_animation_finished.emit()


func finish_deployment(consumed: bool) -> void:
	if not _deploy.finish(consumed):
		return
	_set_movement_animation(false)


## The completed transition has activated a different weapon set, whose target
## must be selected using its own range and priority.
func retarget_after_deployment_state_change() -> void:
	_combat.retarget_after_deployment_state_change()


## Cancels any in-flight fire sequence and clears retained targets for every
## weapon whose turret just became inactive under the current deploy state,
## then zeroes its servo angle for next time it's reactivated. Public because
## UnitDeployState calls it by name on every deploy/undeploy transition.
func sync_active_turret_weapons() -> void:
	_combat.sync_active_turret_weapons()


func set_selected(value: bool) -> void:
	if is_selected == value:
		return

	is_selected = value
	if _selection_halo != null:
		_selection_halo.set_selected(value)


## Whether the navigation system owns this unit's movement. A unit outside it
## (a test fixture, a unit not yet registered) moves by writing target_position
## directly, and must not be given navigation-only orders.
func is_navigation_managed() -> bool:
	return _navigation_managed and _navigation_system != null


## The three navigation orders that are not plain movement. Each reports
## whether the navigation system took it, so a caller can fall back to ordinary
## movement when it did not -- which is also what happens outside the system.
##
## `allowed_cells` is the per-agent exception that lets a harvester stand on a
## refinery's dock cells, which are otherwise blocked.
func navigation_command_dock(world_position: Vector3, allowed_cells: Dictionary) -> bool:
	if not is_navigation_managed() or not _navigation_system.has_method("command_dock"):
		return false
	_navigation_system.call("command_dock", self, world_position, allowed_cells)
	return true


func navigation_command_depart(world_position: Vector3, allowed_cells: Dictionary) -> bool:
	if not is_navigation_managed() or not _navigation_system.has_method("command_depart"):
		return false
	_navigation_system.call("command_depart", self, world_position, allowed_cells)
	return true


func navigation_command_move(
	world_position: Vector3, move_mode: int, exit_point := Vector3.INF
) -> bool:
	if not is_navigation_managed():
		return false
	_navigation_system.call("command_move", [self], world_position, move_mode, exit_point)
	return true


## How close counts as arrived. The navigation system's own tolerance wins when
## it is larger: it parks agents on non-overlapping footprint blocks, so a unit
## can be finished moving while still further from the point than its arrival
## radius.
func navigation_arrival_tolerance(fallback: float) -> float:
	if not is_navigation_managed() or not _navigation_system.has_method("arrival_tolerance"):
		return fallback
	return maxf(fallback, float(_navigation_system.call("arrival_tolerance", self)) + 0.01)


## Public because UnitDeployState needs it: a deploying unit is pinned in
## place, and the navigation system owns that lock.
func set_navigation_hold(locked: bool) -> void:
	if _navigation_system != null and _navigation_system.has_method("set_hold_position"):
		_navigation_system.call("set_hold_position", self, locked)


func _set_navigation_debug_direction(value: Vector3) -> void:
	_navigation_requested_velocity = Vector3(value.x, 0.0, value.z)
	if _selection_halo != null:
		_selection_halo.set_movement_direction(_navigation_requested_velocity)


func set_navigation_debug_visible(value: bool) -> void:
	_navigation_debug_visible = value
	if _selection_halo != null:
		_selection_halo.set_movement_debug_visible(value)


func set_hovered(value: bool) -> void:
	if is_hovered == value:
		return
	is_hovered = value
	if _selection_halo != null:
		_selection_halo.set_hovered(value)


func set_owner_player_id(player_id: int) -> void:
	owner_player_id = player_id


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


func _refresh_shield_visibility() -> void:
	_shader_fx.refresh_shield_visibility(shields)


func _apply_unit_definition() -> void:
	if String(config_id).is_empty():
		return

	unit_definition = _definition_catalog.definition_for(config_id)
	if unit_definition == null:
		push_warning("Unit definition not found: %s" % String(config_id))
		return

	move_speed = float(unit_definition.speed)
	mech_speed = maxf(float(unit_definition.mech_speed), 0.0)
	_locomotion.adopt_definition(unit_definition)
	_movement_sounds.adopt_definition(unit_definition)
	turn_rate = maxf(float(unit_definition.turn_rate), 0.0)
	can_move_any_direction = unit_definition.can_move_any_direction
	max_health = float(unit_definition.health)
	max_shields = float(unit_definition.shield_health)
	armour_type = unit_definition.armour_type
	_death_sequence.adopt_definition(unit_definition)
	_combat.configure_combat_turrets()
	if unit_definition.can_fly:
		if _flight_controller == null:
			_flight_controller = UnitFlightControllerScript.new()
		_flight_controller.configure(self, unit_definition)
	else:
		_flight_controller = null
	# Attaches or drops the harvesting loop through the capacity setter.
	max_spice = float(unit_definition.spice_capacity)
	if _harvester != null:
		_harvester.apply_definition(unit_definition)


## Public because UnitFireOverlay/fire_animation_binding() and
## _travel_fire_variant_bindings() (both in unit_combat.gd) need every player,
## not just the ones _locomotion attaches to.
func animation_players() -> Array[AnimationPlayer]:
	return _animation_director.players()


## The harvesting contract UnitCommandController probes for by name. Every
## unit answers; only one with a harvesting module answers yes.
func can_harvest_spice() -> bool:
	return _harvester != null and _harvester.can_harvest_spice()


func command_harvest(spice_layer, navigation_grid, cell: Vector2i) -> bool:
	return _harvester != null \
		and _harvester.command_harvest(spice_layer, navigation_grid, cell)


func can_unload_at(refinery: Node) -> bool:
	return _harvester != null and _harvester.can_unload_at(refinery)


func command_unload(refinery: Node, navigation_grid, spice_layer = null) -> bool:
	return _harvester != null \
		and _harvester.command_unload(refinery, navigation_grid, spice_layer)


func weapon_can_fire_while_moving(weapon_index: int) -> bool:
	return _combat.weapon_can_fire_while_moving(weapon_index)


## The animation_finished hookup stays here deliberately: _sever_connections_
## into() only recognises connections whose callable belongs to this Unit, so a
## module connecting on its own behalf would silently escape the death handoff.
func _prepare_idle_animations() -> void:
	_idle_animations.reset()
	for player in _animation_director.players():
		_idle_animations.prepare(player)
		if not player.animation_finished.is_connected(_on_animation_finished.bind(player)):
			player.animation_finished.connect(_on_animation_finished.bind(player))


## The harvesting module owns the model while an authored harvest or unload
## clip plays; movement and idle animation must not touch it, and the clip's
## own completion is not theirs to handle either.
## The harvesting loop exists exactly while the unit has somewhere to put
## spice. Attached from data rather than from a dedicated subclass, which is
## why a test fixture that only sets a spice capacity gets one too.
##
## If a future unit needs a hold without harvesting -- or harvesting without a
## hold -- this is the line to change, not the meaning of max_spice.
func _sync_harvester_controller() -> void:
	if max_spice > 0.0:
		if _harvester == null:
			_harvester = HarvesterControllerScript.new()
			_harvester.configure(self)
		return
	if _harvester != null:
		_harvester.dispose()
		_harvester = null


func _harvester_owns_animation() -> bool:
	return _harvester != null and _harvester.owns_animation()


func _set_movement_animation(
		is_moving: bool, speed_scale := 1.0, turn_animation: StringName = &""
	) -> void:
	if _harvester_owns_animation():
		return
	if _flight_controller != null and _flight_controller.flight_is_airborne_phase():
		_flight_controller.set_cruise_moving(is_moving, speed_scale)
		return
	if _combat.has_blocking_fire_sequence():
		if not is_moving:
			return
		_combat.cancel_blocking_fire_sequences()
	_locomotion.apply_movement_animation(
		is_moving, speed_scale, turn_animation, _idle_animations.play_sequence
	)
	_movement_sounds.notify_movement_state(is_moving)
	restore_combat_turret_poses()


## Returns the model to its ordinary movement/idle pose. Used by modules that
## take the model over for an authored action clip and have just given it back.
func restore_movement_animation() -> void:
	_set_movement_animation(false)


## Public because UnitCombat's fire-sequence restore-idle branches call it:
## a fire sequence should not stomp a movement animation that started up
## again while the sequence was still playing.
func is_movement_animation_active() -> bool:
	return _locomotion.is_movement_animation_active()


## Plays a one-shot action clip on every player that has it and returns its
## duration, so a caller can time a state on the authored length. A clip no
## model provides has zero duration, which keeps the state machine running at
## full speed instead of stalling.
## Plays a one-shot action clip on every player that has it and returns its
## authored duration, so a caller can time a state on it. `restore_combat_
## turret_poses` is threaded through because the director must not know about
## combat: a restarted clip leaves an inactive turret's pivot at whatever pose
## the clip's authoring left it in, and only the facade knows to undo that.
func play_action_animation(animation_name: StringName) -> float:
	return _animation_director.play_action(animation_name, restore_combat_turret_poses)


func play_animation_from_start(player: AnimationPlayer, animation_name: StringName) -> void:
	_animation_director.play_from_start(
		player, animation_name, restore_combat_turret_poses
	)


## Public: called both internally and by UnitIdleAnimations after playing a
## random idle variant, so a just-restarted idle clip does not leave an
## inactive-turret's pivot at whatever pose the clip's authoring left it in.
func restore_combat_turret_poses() -> void:
	_combat.restore_combat_turret_poses()


func _on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> void:
	if _harvester_owns_animation():
		return
	if _combat.on_animation_finished(animation_name, player):
		return
	if _deploy.on_animation_finished(animation_name, player):
		deployment_animation_finished.emit()
		return
	if _locomotion.on_animation_finished(
		animation_name, player, _idle_animations.play_sequence
	):
		return
	_idle_animations.on_animation_finished(animation_name, player)


func _refresh_owner_visuals() -> void:
	TeamColorScript.apply(visual_root, _owner_team_color())


func _owner_team_color() -> Color:
	return TeamColorScript.color_for(owner_player(), Color(0.2, 0.85, 1.0))


func _players():
	return AutoloadLookupScript.roster(self)


func _clear_invulnerability() -> void:
	invulnerable = false


## Test-only shim: tests/match/demo_boot_run.gd calls this by name. Not
## architecture — the lookup lives in UnitAuthoredCollision.
func _collision_sources() -> Array[Node3D]:
	return _authored_collision.sources()


func _add_selection_halo() -> void:
	_selection_halo = SelectionHaloScript.new()
	_selection_halo.name = "SelectionHalo"
	add_child(_selection_halo)
	var anchor := SelectionHaloBindingScript.anchor(visual_root)
	_selection_halo.configure(
		self, _selection_radius(), _selection_position(), anchor
	)
	_selection_halo.set_movement_direction(_navigation_requested_velocity)
	_selection_halo.set_movement_debug_visible(_navigation_debug_visible)


func _rebuild_selection_halo() -> void:
	if not is_instance_valid(_selection_halo):
		return
	remove_child(_selection_halo)
	_selection_halo.free()
	_add_selection_halo()
	_selection_halo.set_selected(is_selected)
	_selection_halo.set_hovered(is_hovered)


func _selection_radius() -> float:
	return SelectionHaloBindingScript.radius(visual_root, self)


func _selection_position() -> Vector3:
	return SelectionHaloBindingScript.position(visual_root, self)


func _selection_bounds() -> AABB:
	return _authored_collision.selection_bounds()
