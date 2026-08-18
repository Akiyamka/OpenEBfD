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

const GROUP := &"match_root"


## The EntityNodeIndex the running Match owns, or null when `node` is not in
## a tree yet, or no Match is anywhere in that tree. Returns Variant rather
## than the EntityNodeIndex type so this file does not have to preload
## match.gd's entire dependency chain merely to name a return type; callers
## that need the type already preload entity_node_index.gd themselves.
static func entity_index(node: Node) -> Variant:
	if node == null or not node.is_inside_tree():
		return null
	var match_node := node.get_tree().get_first_node_in_group(GROUP)
	if match_node == null or not match_node.has_method("entity_index"):
		return null
	return match_node.call("entity_index")
