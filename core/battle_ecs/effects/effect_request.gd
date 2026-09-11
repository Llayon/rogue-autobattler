class_name EffectRequest extends RefCounted
## Phase 3 / EffectRequest — pure data carrier for one effect
## execution.
##
## Carries NO Node/scene references. Stateless. Reusable across
## effects.

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
