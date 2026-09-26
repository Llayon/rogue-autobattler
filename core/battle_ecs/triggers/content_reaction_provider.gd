extends "res://core/battle_ecs/triggers/trigger_provider.gd"
## B6.2b / ContentReactionProvider — production content-backed
## discovery layer.
##
## Pure: reads BattleWorld + BattleEvent + ReactionDefResolver.
## MUST NOT mutate world, RNG, emitter, events, ReactionDef, or
## reaction ownership arrays.
##
## B5 contract: discovery is RNG-PURE. In B6.2b an active
## ReactionDef must declare trigger_chance=1.0; the validator
## rejects anything else upstream. Therefore this provider does
## not consult RNG for chance. If validation rejects a def
## for any reason, this provider skips it deterministically.

const ReactionDefResolverScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_resolver.gd")
const ReactionDefValidatorScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_validator.gd")
const ReactionDefScript = preload(
	"res://core/data/reaction_def.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")

var _emitter = null


func _init(p_emitter = null) -> void:
	_emitter = p_emitter


## Provider discovery: build an ORDERED list of TriggerReaction
## specs. Returns Array (possibly empty). Order = sorted candidate
## entity IDs ascending, then within each entity: ownership
## snapshot order.
##
## Provider expresses INTENT. Executor remains authoritative for
## PerformAttackEffect validation (Stun, range, same-team, etc.).
func discover(p_world, p_event, p_rng) -> Array:
	var reactions: Array = []
	if p_event == null or p_world == null:
		return reactions
	var ev_type: int = int(p_event.type)
	# Build unique candidate entity IDs from event participants.
	# Sort numerically ASCENDING. Ignore invalid negative IDs.
	var candidate_ids: Array = []
	for id in [
		int(p_event.source_entity),
		int(p_event.target_entity),
	]:
		if id < 0:
			continue
		if not candidate_ids.has(id):
			candidate_ids.append(id)
	candidate_ids.sort()
	for entity_id in candidate_ids:
		var owned_reaction_ids: Array = p_world.reaction_ids_of(
			int(entity_id))
		# Iterate in ownership snapshot order.
		for reaction_id in owned_reaction_ids:
			var rid_str: StringName = StringName(reaction_id)
			# Resolve through typed ReactionDefResolver.
			var def: Resource = ReactionDefResolverScript.resolve(rid_str)
			if def == null:
				continue
			# Validate the resolved def is executable.
			var v: Dictionary = \
				ReactionDefValidatorScript.validate_for_execution(def)
			if not bool(v.get("ok", false)):
				continue
			# Event-type match.
			if int(def.event_type) != ev_type:
				continue
			# Excluded-trigger-tag check. Compare via StringName
			# semantics on both sides so StringName vs String
			# mismatches cannot bypass exclusion.
			var ev_tag: StringName = StringName(
				String(p_event.tag))
			var excluded: Array = def.excluded_trigger_tags
			var skip_due_to_tag: bool = false
			for ex in excluded:
				if StringName(String(ex)) == ev_tag:
					skip_due_to_tag = true
					break
			if skip_due_to_tag:
				continue
			# Resolve owner entity by selector.
			var owner_entity: int = -1
			if int(def.owner_selector) == \
					int(ReactionDefScript.OWNER_EVENT_SOURCE):
				owner_entity = int(p_event.source_entity)
			elif int(def.owner_selector) == \
					int(ReactionDefScript.OWNER_EVENT_TARGET):
				owner_entity = int(p_event.target_entity)
			else:
				continue
			# Owner-match rule: the owner entity MUST equal the
			# entity whose reaction_ids list we are inspecting.
			# Otherwise entity A's reaction cannot execute under
			# entity B.
			if owner_entity != int(entity_id):
				continue
			# Owner must exist + be alive before producing the
			# reaction. Target must exist + be alive too.
			if not p_world.is_alive(owner_entity):
				continue
			var selected_target: int = -1
			if int(def.target_selector) == \
					int(ReactionDefScript.TARGET_EVENT_SOURCE):
				selected_target = int(p_event.source_entity)
			elif int(def.target_selector) == \
					int(ReactionDefScript.TARGET_EVENT_TARGET):
				selected_target = int(p_event.target_entity)
			elif int(def.target_selector) == \
					int(ReactionDefScript.TARGET_OWNER):
				selected_target = int(owner_entity)
			else:
				continue
			if not p_world.is_alive(selected_target):
				continue
			# Build the TEMPLATE EffectRequest. The dispatcher is
			# the sole authority for child ancestry via
			# child_from_template(template, triggering_event).
			var template = EffectRequestScript.root(
				int(EffectKindScript.PERFORM_ATTACK),
				int(owner_entity),
				int(selected_target),
				0)
			# Semantic payload: output_tag if authored.
			if String(def.output_tag) != "":
				var payload: Dictionary = {}
				payload[EffectRequestScript.PAYLOAD_EVENT_TAG] = \
					StringName(String(def.output_tag))
				template.payload = payload
			# definition_id preserves semantic provenance.
			template.definition_id = rid_str
			var tr = TriggerReactionScript.new()
			tr.reacting_entity = int(owner_entity)
			tr.kind = String(rid_str)
			tr.request = template
			reactions.append(tr)
	return reactions
