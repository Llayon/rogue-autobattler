class_name EffectRequest extends RefCounted
## Phase 3 / EffectRequest — pure data carrier for one effect
## execution.
##
## Carries NO Node/scene references. Stateless. Reusable across
## effects.
##
## B2.2 ancestry contract:
##
## EffectRequest ancestry describes the EVENT that the effect
## itself will emit (not the parent's depth).
##
## ROOT REQUEST:
##   root_action_id   == -1
##   parent_event_id   == -1
##   chain_depth       == 0
##   -> The emitter allocates a fresh root_action_id. The
##      emitted event has parent_event_id = -1, chain_depth = 0.
##
## CHILD REQUEST:
##   root_action_id   >  0
##   parent_event_id   >  0
##   chain_depth       >= 1
##   -> The emitter places the event under
##      (parent_event_id, root_action_id) with chain_depth =
##      req.chain_depth (one more than parent's depth).
##
## Any other combination is INVALID. validate_ancestry()
## returns {ok: false, reason: "..."} for invalid requests.
## No effect may mutate state for an invalid request.

## B2.2 ancestry kinds.
const ANCESTRY_ROOT: StringName = &"root"
const ANCESTRY_CHILD: StringName = &"child"
const ANCESTRY_INVALID: StringName = &"invalid"

var kind: int = 0
var source_entity: int = 0
var target_entity: int = 0
var amount: int = 0
var root_action_id: int = -1
var parent_event_id: int = -1
var chain_depth: int = 0
var definition_id: StringName = &""
var payload: Dictionary = {}


func _init(
		p_kind: int = 0,
		p_source: int = 0,
		p_target: int = 0,
		p_amount: int = 0,
		p_root_action_id: int = -1,
		p_parent_event_id: int = -1,
		p_chain_depth: int = 0) -> void:
	kind = int(p_kind)
	source_entity = int(p_source)
	target_entity = int(p_target)
	amount = int(p_amount)
	root_action_id = int(p_root_action_id)
	parent_event_id = int(p_parent_event_id)
	chain_depth = int(p_chain_depth)


## Returns the kind without validation cost.
func ancestry_kind() -> StringName:
	if int(root_action_id) == -1 and int(parent_event_id) == -1 and int(chain_depth) == 0:
		return ANCESTRY_ROOT
	if int(root_action_id) > 0 and int(parent_event_id) > 0 and int(chain_depth) >= 1:
		return ANCESTRY_CHILD
	return ANCESTRY_INVALID


## Validates the ancestry contract. Returns a Dictionary:
##   { ok: bool, kind: ANCESTRY_ROOT|ANCESTRY_CHILD|ANCESTRY_INVALID,
##     reason: String (only when !ok) }
##
## ROOT:  exactly root=-1, parent=-1, depth=0
## CHILD: exactly root>0, parent>0, depth>=1
## INVALID: anything else, with a human-readable reason.
func validate_ancestry() -> Dictionary:
	# Disallow 0 (sentinel for unset-but-intentional). -1 is the
	# root sentinel; 0 must not appear in either field.
	if int(root_action_id) == 0:
		return _invalid("root_action_id == 0 not allowed")
	if int(parent_event_id) == 0:
		return _invalid("parent_event_id == 0 not allowed")
	if int(root_action_id) == -1 and int(parent_event_id) == -1:
		# Root shape.
		if int(chain_depth) != 0:
			return _invalid(
				"root request must have chain_depth == 0 (got %d)" % int(chain_depth))
		return {"ok": true, "kind": ANCESTRY_ROOT, "reason": ""}
	if int(root_action_id) > 0 and int(parent_event_id) > 0:
		# Child shape.
		if int(chain_depth) < 1:
			return _invalid(
				"child request must have chain_depth >= 1 (got %d)" % int(chain_depth))
		return {"ok": true, "kind": ANCESTRY_CHILD, "reason": ""}
	# Mixed/partial shape.
	if int(root_action_id) == -1 and int(parent_event_id) > 0:
		return _invalid(
			"root_action_id == -1 but parent_event_id > 0 (must be both -1 or both > 0)")
	if int(root_action_id) > 0 and int(parent_event_id) == -1:
		return _invalid(
			"root_action_id > 0 but parent_event_id == -1 (must be both -1 or both > 0)")
	return _invalid("ancestry: unclassified")


static func _invalid(p_reason: String) -> Dictionary:
	return {"ok": false, "kind": ANCESTRY_INVALID, "reason": p_reason}
