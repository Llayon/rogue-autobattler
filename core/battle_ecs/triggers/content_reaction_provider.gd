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
##
## B6.2b: no _emitter dependency. A TriggerProvider is a pure
## discovery layer; the emitter is owned by BattleSimulation
## and accessible via the dispatcher's emitter argument, not
## via this provider.

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
	# B6.3: spatial reactions may belong to entities that are
	# neither event.source_entity nor event.target_entity. Scan
	# ALL alive entities for spatial-typed ReactionDefs so we do
	# not silently drop them when iterating candidate_ids alone.
	var spatial_handled: Dictionary = {}
	var alive_ids_scan: Array = p_world.alive_ids_in_order()
	alive_ids_scan.sort()
	for entity_id in alive_ids_scan:
		var owned_reaction_ids: Array = p_world.reaction_ids_of(
			int(entity_id))
		for reaction_id in owned_reaction_ids:
			var rid_str_pre: StringName = StringName(reaction_id)
			if spatial_handled.has(rid_str_pre):
				continue
			var def_pre: Resource = ReactionDefResolverScript.resolve(
				rid_str_pre)
			if def_pre == null:
				continue
			if int(def_pre.owner_selector) != int(
					ReactionDefScript.OWNER_ENEMY_LEAVING_RANGE):
				continue
			spatial_handled[rid_str_pre] = true
			_react_spatial(p_world, p_event, ev_type, rid_str_pre, def_pre,
				reactions)
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
			# B6.3: spatial owner selector enumerates candidates
			# independently of the event participants. Already
			# handled above (alive_ids_scan).
			if int(def.owner_selector) == int(
					ReactionDefScript.OWNER_ENEMY_LEAVING_RANGE):
				continue
			_react_participant(p_world, p_event, ev_type, entity_id,
				rid_str, def, reactions)
	return reactions


## Participant-only discovery (OWNER_EVENT_SOURCE,
## OWNER_EVENT_TARGET). Walks the candidate list and enforces
## owner-match.
func _react_participant(p_world, p_event, ev_type: int, entity_id: int,
		rid_str: StringName, def: Resource, reactions: Array) -> void:
	# Validate the resolved def is executable.
	var v: Dictionary = \
		ReactionDefValidatorScript.validate_for_execution(def)
	if not bool(v.get("ok", false)):
		return
	# Event-type match.
	if int(def.event_type) != ev_type:
		return
	# Excluded-trigger-tag check. Compare via StringName
	# semantics on both sides so StringName vs String
	# mismatches cannot bypass exclusion.
	var ev_tag: StringName = StringName(String(p_event.tag))
	var excluded: Array = def.excluded_trigger_tags
	for ex in excluded:
		if StringName(String(ex)) == ev_tag:
			return
	# Resolve owner entity by selector.
	var owner_entity: int = -1
	if int(def.owner_selector) == \
			int(ReactionDefScript.OWNER_EVENT_SOURCE):
		owner_entity = int(p_event.source_entity)
	elif int(def.owner_selector) == \
			int(ReactionDefScript.OWNER_EVENT_TARGET):
		owner_entity = int(p_event.target_entity)
	else:
		return
	# Owner-match rule: the owner entity MUST equal the
	# entity whose reaction_ids list we are inspecting.
	# Otherwise entity A's reaction cannot execute under
	# entity B.
	if owner_entity != int(entity_id):
		return
	# Owner must exist + be alive before producing the
	# reaction. Target must exist + be alive too.
	if not p_world.is_alive(owner_entity):
		return
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
		return
	if not p_world.is_alive(selected_target):
		return
	_emit_reaction_template(p_world, rid_str, def, owner_entity,
		selected_target, reactions)


## B6.3 / Spatial discovery (OWNER_ENEMY_LEAVING_RANGE).
## Enumerates alive entities, filters by:
##   - not the mover
##   - team differs from mover (enemy)
##   - both alive
##   - distance(mover.from_cell, owner.position) <= range_cells
##   - distance(mover.to_cell, owner.position)  > range_cells
## "Leaving range" pattern. Movement that does NOT exit the
## owner's threatened range is ignored (entering, circling).
##
## Candidate ordering: ascending entity_id (deterministic; matches
## alive_ids_in_order() numeric order).
func _react_spatial(p_world, p_event, ev_type: int, rid_str: StringName,
		def: Resource, reactions: Array) -> void:
	# Validate the resolved def is executable.
	var v: Dictionary = \
		ReactionDefValidatorScript.validate_for_execution(def)
	if not bool(v.get("ok", false)):
		return
	# Event-type match.
	if int(def.event_type) != ev_type:
		return
	# Excluded-trigger-tag check.
	var ev_tag: StringName = StringName(String(p_event.tag))
	var excluded: Array = def.excluded_trigger_tags
	for ex in excluded:
		if StringName(String(ex)) == ev_tag:
			return
	# Spatial event MUST carry from_cell/to_cell. Malformed
	# cells fail closed (no reaction).
	var from_cell = p_event.from_cell
	var to_cell = p_event.to_cell
	if int(from_cell.x) == -1 and int(from_cell.y) == -1:
		return
	if int(to_cell.x) == -1 and int(to_cell.y) == -1:
		return
	var mover: int = int(p_event.source_entity)
	if not p_world.is_alive(mover):
		return
	var mover_team: int = int(p_world.team_of(mover))
	var range_cells: int = maxi(1, int(def.range_cells))
	# Enumerate alive entities in numeric order (deterministic).
	var alive_ids: Array = p_world.alive_ids_in_order()
	# Sort numerically (alive_ids_in_order may already be sorted,
	# but be explicit for the provider ordering contract).
	alive_ids.sort()
	for owner_id in alive_ids:
		var owner_id_int: int = int(owner_id)
		if owner_id_int == mover:
			continue
		if not p_world.is_alive(owner_id_int):
			continue
		if int(p_world.team_of(owner_id_int)) == mover_team:
			continue
		var owner_pos: Vector2i = p_world.position_of(owner_id_int)
		var d_from: int = _manhattan(owner_pos, from_cell)
		var d_to: int = _manhattan(owner_pos, to_cell)
		if d_from > range_cells:
			continue
		if d_to <= range_cells:
			continue
		# Owner is eligible: enemy, alive, distance to from
		# within range, distance to to outside range.
		if not p_world.is_alive(owner_id_int):
			continue
		# Target = the mover (the entity LEAVING the range).
		var selected_target: int = mover
		if not p_world.is_alive(selected_target):
			continue
		_emit_reaction_template(p_world, rid_str, def, owner_id_int,
			selected_target, reactions)


## Manhattan distance helper.
func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(int(a.x) - int(b.x)) + absi(int(a.y) - int(b.y))


## Emit a TriggerReaction template with the canonical
## owner/target pair. Used by both participant and spatial paths.
func _emit_reaction_template(p_world, rid_str: StringName, def: Resource,
		owner_entity: int, selected_target: int,
		reactions: Array) -> void:
	var template = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK),
		int(owner_entity),
		int(selected_target),
		0)
	if String(def.output_tag) != "":
		var payload: Dictionary = {}
		payload[EffectRequestScript.PAYLOAD_EVENT_TAG] = \
			StringName(String(def.output_tag))
		template.payload = payload
	template.definition_id = rid_str
	var tr = TriggerReactionScript.new()
	tr.reacting_entity = int(owner_entity)
	tr.kind = String(rid_str)
	tr.request = template
	reactions.append(tr)
