class_name EffectRequest extends RefCounted
## Phase 3 / EffectRequest — pure data carrier for one effect
## execution.
##
## Carries NO Node/scene references. Stateless. Reusable across
## effects.
##
## B2.3 ancestry contract:
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
## Any other combination is INVALID. validate_ancestry_shape()
## returns {ok: false, reason: "..."} for invalid requests.
## No effect may mutate state for an invalid request.
##
## IMPORTANT (B2.3): validate_ancestry_shape() validates the
## SHAPE of the ancestry fields. It does NOT prove that the
## referenced parent_event_id corresponds to a real BattleEvent
## with root_action_id == self.root_action_id and
## chain_depth == self.chain_depth - 1. Production chain code
## MUST use child_from_parent(parent_event) which derives those
## fields from an actual parent BattleEvent. The raw
## constructor is reserved for tests and low-level use.

## B2.3 ancestry kinds.
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


## Raw constructor. Use root() or child_from_parent() in
## production code. The raw constructor remains available for
## tests, serialization, and other low-level consumers.
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


## B2.3 canonical ROOT factory. All raw fields are explicitly
## the ROOT shape (-1, -1, 0). Use this in production code
## that wants to emit a fresh-root event.
static func root(
		p_kind: int,
		p_source: int = 0,
		p_target: int = 0,
		p_amount: int = 0) -> EffectRequest:
	var r = EffectRequest.new(
		int(p_kind), int(p_source), int(p_target), int(p_amount),
		-1, -1, 0)
	return r


## B2.3 canonical CHILD factory. Derives root_action_id,
## parent_event_id, and chain_depth FROM the parent BattleEvent.
## No caller-supplied child ancestry. If the parent is null or
## malformed, returns null.
##
## Production chain code (TriggerDispatcher, future Burn/Regen
## reactions) MUST use this factory.
static func child_from_parent(
		p_kind: int,
		p_parent_event,
		p_source: int = 0,
		p_target: int = 0,
		p_amount: int = 0) -> RefCounted:
	if p_parent_event == null:
		return null
	var parent_event_id: int = int(p_parent_event.event_id)
	var parent_root_action_id: int = int(p_parent_event.root_action_id)
	var parent_chain_depth: int = int(p_parent_event.chain_depth)
	if parent_event_id <= 0:
		return null
	if parent_root_action_id <= 0:
		return null
	if parent_chain_depth < 0:
		return null
	return EffectRequest.new(
		int(p_kind),
		int(p_source),
		int(p_target),
		int(p_amount),
		parent_root_action_id,
		parent_event_id,
		parent_chain_depth + 1)


## Returns the kind without validation cost.
func ancestry_kind() -> StringName:
	if int(root_action_id) == -1 and int(parent_event_id) == -1 and int(chain_depth) == 0:
		return ANCESTRY_ROOT
	if int(root_action_id) > 0 and int(parent_event_id) > 0 and int(chain_depth) >= 1:
		return ANCESTRY_CHILD
	return ANCESTRY_INVALID


## B2.3: renamed from validate_ancestry() — this method
## validates the SHAPE of the ancestry fields. It cannot
## detect forged parent metadata (it does not have access to
## the parent BattleEvent). Use a trace auditor for
## referential parent consistency.
func validate_ancestry_shape() -> Dictionary:
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


## Backward-compatible instance method alias.
func validate_ancestry() -> Dictionary:
	return validate_ancestry_shape()


static func _invalid(p_reason: String) -> Dictionary:
	return {"ok": false, "kind": ANCESTRY_INVALID, "reason": p_reason}
