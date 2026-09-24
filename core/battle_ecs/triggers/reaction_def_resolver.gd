extends RefCounted
## Phase 3 / B6.2a / ReactionDefResolver — resolves a ReactionDef
## by its content id, using the typed lookup in ContentDB.
##
## Use get_by_id_for_type("reactions", id) so that cross-type
## duplicates (e.g. &"regen" in both abilities/ and effects/)
## resolve to the ReactionDef, not the AbilityDef.
##
## Architectural rules (B6.2a):
##   - ReactionDef is content definition (immutable Resource).
##   - BattleUnitSetup snapshots ordered reaction_ids.
##   - BattleWorld stores reaction_ids per entity (read-only).
##   - BattleUnitSetup / BattleWorld NEVER store ReactionDef
##     Resource references — only StringName IDs.
##   - A real ContentReactionProvider is added in a later
##     stage. This resolver is the lookup primitive, NOT a
##     provider.
##   - No RNG. No execution logic. No mutation of any kind.

const ContentDBScript = preload("res://core/utils/content_db.gd")
const ReactionDefScript = preload("res://core/data/reaction_def.gd")


## Returns the ReactionDef for the given id, or null if not
## found, empty, or not actually a ReactionDef resource.
static func resolve(p_reaction_id: StringName) -> Resource:
	if p_reaction_id == &"":
		return null
	ContentDBScript.ensure_loaded()
	var res: Resource = ContentDBScript.get_by_id_for_type(
		"reactions", p_reaction_id)
	if res == null:
		return null
	# Defensive: caller may pass any StringName; only return
	# resources that are actually ReactionDef.
	if res.get_script() != ReactionDefScript:
		return null
	return res


## True iff a ReactionDef exists for the given id. Pure lookup;
## no side effects, no allocation.
static func has(p_reaction_id: StringName) -> bool:
	return resolve(p_reaction_id) != null
