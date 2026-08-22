class_name MatchLookup
extends RefCounted

## Finds the running Match instance by group membership instead of a
## hardcoded node path -- the scene-tree counterpart to AutoloadLookup
## (scripts/players/autoload_lookup.gd), which does the same job for /root
## singletons. Match adds itself to GROUP in its own _enter_tree(), which the
## engine calls top-down for a whole freshly-added subtree before any node in
## that subtree runs _ready() -- see the comment on Match._enter_tree() -- so
## by the time a Unit or Building looks itself up from its own _ready(),
## Match (if one exists at all) is already findable this way.
##
## Every lookup here is null-tolerant, and that is not incidental: most test
## suites in this repo build a Unit or a Building directly, with no Match
## anywhere in the tree (see tests/combat/*). An entity that cannot find a
## Match simply gets no id and behaves exactly as it did before ids existed.
##
## The question both lookups answer is "which Match owns this node", not
## "which Match is first in GROUP" -- and those two questions only usually
## agree. get_first_node_in_group() answers the second one, which is close
## enough for as long as exactly one Match is ever in the group at a time,
## and this repo's suites mostly arrange exactly that. It stops being close
## enough the instant a second Match exists in the same frame -- a rematch,
## a reconnect, or (in tests) two fixtures instantiated back to back --
## because group order then has nothing to do with which Match a given node
## actually sits under.
##
## Measured directly: a Unit or Building newly entering the tree beside a
## dying Match (queue_free() defers the actual removal, and the group
## membership that goes with it, to this frame's teardown) took its entity
## id from that dying Match's registry, and every later write resolved
## entity_state() to whichever Match replaced it -- where that id was never
## allocated -- reported as a refused write for the rest of that entity's
## life. Making both lookups skip a dying candidate before choosing (still
## visible in git history) fixed exactly that population and nothing else:
## measured on tests/match/demo_boot_run.gd, 1696 refused writes with the
## skip against 1698 without it -- not a fix, noise. The skip could never
## touch the mirror population: an entity *already registered* before a
## second Match ever showed up keeps being ticked every frame through the
## global "units"/"buildings" groups, and its writes still went through
## entity_state(), which was still resolving the running match by group
## position -- so once two Matches were briefly both in the group, an
## already-registered entity's writes could resolve to whichever one
## get_first_node_in_group() preferred, not necessarily its own, regardless
## of which candidate happened to be dying.
##
## Ancestry is what actually answers the ownership question, because it is
## the one thing group order only ever coincidentally tracked: a node's
## Match ancestor -- the Match it was add_child()'d under, directly or
## transitively -- is unambiguous no matter how many other Matches the group
## holds at that instant. _live_match() below walks `node`'s ancestors first
## and returns the first one in GROUP that answers `method`, deliberately
## with no is_queued_for_deletion() check: the entity genuinely belongs to
## that ancestor, and its registry and store stay alive until this frame's
## teardown actually removes it, so returning it rather than falling through
## to null is exactly what fixes the second population above. Measured after
## this change: demo_boot_run.gd produces 0 refused writes (364 assertions,
## exit 0), and the full suite (63 passed, 0 failed) drops refused writes
## across the whole run from 1707 to 9 -- 7 of them
## tests/sim/entity_state_run.gd's own deliberate error-path cases, and 2
## tests/match/despawn_run.gd hitting a separate, known, one-tick gap
## recorded in docs/architecture/network-multiplayer.md's phase 3 section.
##
## The group walk stays, as a fallback, for a named reason rather than out
## of caution: a node with no Match ancestor at all still needs an answer,
## and at least one real caller depends on exactly that --
## tests/match/support/command_pump.gd installs a stub Match node into GROUP
## that answers entity_index() but is deliberately never made an ancestor of
## the entities under test, standing in for Match without the rest of the
## scene tree a real Match would own. Do not simplify this fallback away:
## removing it would strip that stub, and every suite built on it, of entity
## ids. Unlike the ancestor walk, the fallback does skip a dying candidate
## (is_queued_for_deletion()): here there is no ownership evidence to fall
## back on, only group membership, so the reasoning that keeps a dying
## ancestor an entity's own does not apply -- a dying group member is no
## more this node's Match than a live one picked at random would be.

const GROUP := &"match_root"


## The lookup both public functions below share, in two passes.
##
## Pass one walks `node` up through get_parent() and returns the first
## ancestor in GROUP that answers `method` -- ownership, not position, and
## deliberately not filtered by is_queued_for_deletion(). A queued-for-
## deletion ancestor is still this node's own Match: its registry and store
## remain live until this frame's teardown actually removes it, and treating
## it as absent is exactly the bug this function replaces (see the class doc
## comment above for the measured numbers).
##
## Pass two runs only when no ancestor answered -- a node with no Match
## above it in the tree at all. It walks the whole group for the first
## candidate that is_instance_valid(), not is_queued_for_deletion(), and
## answers `method`, in that order, because here there is no ownership
## evidence to rely on: group membership is the only signal available, and a
## dying candidate is no more this node's own than any other live one would
## be. This pass exists for tests/match/support/command_pump.gd's stub
## Match, a GROUP member that answers entity_index() but is never an
## ancestor of the entities it serves -- removing this fallback would leave
## that stub's suites with no entity ids at all.
##
## Takes `method` rather than hardcoding one, because entity_index() and
## entity_state() are asking about two different methods on the same Match
## and neither should risk being satisfied by a candidate that only happens
## to answer the other one.
static func _live_match(node: Node, method: StringName) -> Node:
	var ancestor: Node = node
	while ancestor != null:
		if ancestor.is_in_group(GROUP) and ancestor.has_method(method):
			return ancestor
		ancestor = ancestor.get_parent()
	for candidate in node.get_tree().get_nodes_in_group(GROUP):
		if is_instance_valid(candidate) and not candidate.is_queued_for_deletion() \
		and candidate.has_method(method):
			return candidate
	return null


## The EntityNodeIndex the running Match owns, or null when `node` is not in
## a tree yet, or no live Match anywhere in that tree answers to
## entity_index(). Returns Variant rather than the EntityNodeIndex type so
## this file does not have to preload match.gd's entire dependency chain
## merely to name a return type; callers that need the type already preload
## entity_node_index.gd themselves.
static func entity_index(node: Node) -> Variant:
	if node == null or not node.is_inside_tree():
		return null
	var match_node := _live_match(node, &"entity_index")
	if match_node == null:
		return null
	return match_node.call("entity_index")


## The SimEntityState the running Match owns (scripts/sim/entity_state.gd), or
## null under the identical conditions entity_index() returns null -- same
## lookup, same null-tolerance, so a Unit written with no live Match in the
## tree (most unit/combat tests) simply has no store to write through.
static func entity_state(node: Node) -> Variant:
	if node == null or not node.is_inside_tree():
		return null
	var match_node := _live_match(node, &"entity_state")
	if match_node == null:
		return null
	return match_node.call("entity_state")


## The SimAdmissionQueue the running Match owns (scripts/match/sim_admission_queue.gd),
## or null under the identical conditions entity_index()/entity_state() return
## null -- same lookup, same null-tolerance, for the same reason: most
## combat/effect suites build a CombatProjectile, CombatLingerEffect or
## SpiceMound directly, with no Match anywhere in the tree.
static func admission_queue(node: Node) -> Variant:
	if node == null or not node.is_inside_tree():
		return null
	var match_node := _live_match(node, &"admission_queue")
	if match_node == null:
		return null
	return match_node.call("admission_queue")


## The one call every group join C6b defers goes through: resolves the
## running Match's SimAdmissionQueue for `node` and asks it to request entry
## into `group`, or, when there is no queue -- no Match anywhere in `node`'s
## tree -- adds `node` to `group` immediately instead of queueing at all.
##
## That fallback mirrors Unit.request_despawn()'s own (scripts/units/unit.gd):
## most combat and effect suites in this repo build a CombatProjectile,
## CombatLingerEffect or SpiceMound with no Match anywhere in the tree (see
## tests/combat/*), and nothing would ever call apply_pending_entries() to
## drain a queue for them -- a node that requested entry and was never
## admitted would simply never simulate, which is a regression these suites
## would have no way to notice short of every assertion timing out. Joining
## immediately in that case is exactly what these nodes did before C6b, so
## behaviour there is unchanged.
##
## This is the one place all three C6b call sites (combat_projectile.gd,
## combat_linger_effect.gd, spice_mound.gd) route through, rather than each
## repeating admission_queue(node)'s null check itself: three call sites
## duplicating that check would be three places to keep correct if the
## fallback's reasoning ever changed; this is one.
static func request_sim_entry(node: Node, group: StringName) -> void:
	var queue: Variant = admission_queue(node)
	if queue == null:
		node.add_to_group(group)
		return
	queue.request_entry(node, group)
