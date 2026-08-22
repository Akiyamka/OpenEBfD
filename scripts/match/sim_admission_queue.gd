class_name SimAdmissionQueue
extends RefCounted

## Holds Node references waiting to enter the simulation -- the creation-side
## mirror of EntityNodeIndex's despawn half (scripts/match/entity_node_index.gd,
## slice C5). This lives outside the sim zone deliberately, for the identical
## reason EntityNodeIndex does: it holds Node references, which
## tools/architecture_rules.toml's sim-no-node-api rule forbids sim code from
## holding. See docs/architecture/network-multiplayer.md, decision 3, and
## "Slice C6, decided 2026-08-22" for why entry into the simulation is what
## gets deferred here, not the creation of the node itself.

## One node waiting for its requested group, paired with the group it asked
## to join. Modeled on SimCommandBus._QueuedCommand (scripts/sim/command_bus.gd),
## which solves the identical "hold what a request needs until its drain"
## shape for commands.
class _PendingEntry extends RefCounted:
	var node: Node
	var group: StringName


## Requests queued by request_entry() since the last apply_pending_entries()
## call, in request order. That order is deterministic by construction, the
## same reasoning SimEntityRegistry._pending_release rests on (see that
## field's comment, scripts/sim/entity_registry.gd): every caller reaches
## request_entry() from the simulation tick, whether directly (a node built
## with no Match, see MatchLookup.request_sim_entry()'s own comment) or, for
## every node built inside a running match, from Node._ready()/configure()
## call sites that themselves only ever run as a synchronous consequence of
## tick-driven code (CombatTurret.try_fire_at(), SpiceMound placement, and so
## on).
##
## Unlike SimEntityRegistry._pending_release, this determinism is not
## something a caller can observe or depend on downstream: request order only
## decides the order apply_pending_entries() below *walks* `_pending` in, and
## its only effect per entry is add_to_group(), which lands in Godot group
## membership -- a set, not a sequence. Two entries admitted in either order
## produce the identical set. Nothing here asserts or should ever assert an
## admission order via get_nodes_in_group(): that call's own iteration order
## is Godot's to decide, not this queue's, and is already a known, separate
## gap recorded in Match._advance_simulation_tick()'s doc comment ("which
## projectile in a multi-shot volley resolves first... is not guaranteed to
## match across clients yet") for phase 4 to close.
var _pending: Array[_PendingEntry] = []


## Queues `node` to join `group` on the next apply_pending_entries() drain.
func request_entry(node: Node, group: StringName) -> void:
	var entry := _PendingEntry.new()
	entry.node = node
	entry.group = group
	_pending.append(entry)


## Drains every entry request_entry() queued since the last call, walking
## `_pending` in request order, and adds each node still alive and in the
## tree to its requested group. That walk order is internal bookkeeping, not
## a promise about the result: add_to_group() lands in group membership,
## which is a set, so nothing downstream may depend on which entry was
## admitted "first" -- see `_pending`'s own comment above for why this is not
## the despawn queue's take_pending_releases(), whose PackedInt32Array return
## value does make order observable and worth asserting. Returns how many
## actually joined -- not necessarily the number queued, because a node freed
## between request and drain is skipped, not an error: CombatTurret.try_fire_at()
## (scripts/combat/combat_turret.gd) frees a projectile whose launch() call
## fails -- an out-of-range shot, or a target
## that died between muzzle selection and the call -- in the same frame it
## created it, and that projectile already called request_entry() from its
## own _ready() (combat_projectile.gd) before launch() ever ran. Skipping a
## freed entry here is the deferred-admission mirror of the tolerance
## combat_projectile.gd's own _ready() comment already documents for the
## immediate-join case: a brief, never-admitted queue entry on a doomed
## instance costs nothing.
func apply_pending_entries() -> int:
	var entries := _pending
	_pending = []
	var joined := 0
	for entry in entries:
		if is_instance_valid(entry.node) and entry.node.is_inside_tree():
			entry.node.add_to_group(entry.group)
			joined += 1
	return joined


func pending_entry_count() -> int:
	return _pending.size()
