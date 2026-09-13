extends RefCounted
## Phase 3 / B1 / ApplyStatusEffect — applies a StatusInstance to
## the target entity using a real StatusDef.
##
## Architectural rules (B1):
##   - StatusDef is content definition (immutable Resource).
##   - StatusInstance is runtime state.
##   - Resolve StatusDef via StatusDefResolver BEFORE mutating
##     state. Unknown status_id fails safely (no container
##     mutation, no STATUS_APPLIED event).
##   - StatusContainer.add() enforces stackable/max_stacks via
##     the StatusDef's policy.
##   - Duration is converted from float seconds to integer ticks
##     via StatusDefResolver.convert_duration_to_ticks.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")

## Execute apply-status effect. The status_id is read from the
## request payload's "status_id" or from request.definition_id.
## ApplyStatusEffect will:
##   1. resolve the StatusDef via ContentDB
##   2. validate target is alive
##   3. get-or-create the entity's StatusContainer
##   4. convert StatusDef.duration (float) -> integer ticks
##   5. delegate to StatusContainer.add() with the
##      stackable/max_stacks policy from the StatusDef
##   6. emit a STATUS_APPLIED BattleEvent on success
static func execute(ctx, req) -> RefCounted:
	var world = ctx.world()
	var tgt: int = int(req.target_entity)
	if not world.is_alive(tgt):
		return EffectResultScript.failed("apply_status target not alive", [], false)
	var status_id: StringName = &""
	if req.payload.has("status_id"):
		status_id = StringName(String(req.payload["status_id"]))
	elif String(req.definition_id) != "":
		status_id = req.definition_id
	else:
		return EffectResultScript.failed("apply_status missing status_id", [], false)
	# B1: resolve StatusDef via real content lookup.
	var def: Resource = StatusDefResolverScript.resolve(status_id)
	if def == null:
		return EffectResultScript.failed("apply_status unknown status_id: %s" % str(status_id), [], false)
	# B1.1: validate duration via the explicit result Dictionary.
	# Reject INVALID (fractional / negative / non-finite) and
	# INSTANT (duration==0) BEFORE creating any container or
	# StatusInstance.
	var dur_res: Dictionary = StatusDefResolverScript.convert_duration(float(def.duration))
	if not bool(dur_res.get("ok", false)):
		# Do NOT create a container. Do NOT mutate state. Return
		# failure with the reason from the validation.
		return EffectResultScript.failed(
			"apply_status invalid duration: %s (status_id=%s)" % [
				String(dur_res.get("reason", "")),
				String(status_id),
			], [], false)
	var ticks: int = int(dur_res.get("ticks", 0))
	# Determine stacks from payload (default 1).
	var stacks: int = int(req.payload.get("stacks", 1))
	# B1.2: reject stacks <= 0 explicitly (the container also
	# rejects, but we want an explicit failure reason at the
	# ApplyStatusEffect boundary).
	if stacks <= 0:
		return EffectResultScript.failed(
			"apply_status invalid stacks: %d (must be > 0)" % stacks, [], false)
	# B1.2: defensive policy + max_stacks normalization from
	# StatusDef. Malformed content cannot weaken the invariant:
	#   - def.stackable == false -> policy = "unique",
	#     effective_max_stacks = 1 (regardless of def.max_stacks).
	#   - def.stackable == true  -> policy = "stackable",
	#     effective_max_stacks = def.max_stacks (must be >= 1).
	var policy: String = "unique"
	var effective_max_stacks: int = 1
	if bool(def.stackable):
		policy = "stackable"
		var m: int = int(def.max_stacks)
		if m < 1:
			# Defensive: malformed stackable status without a valid
			# max_stacks cannot silently use an arbitrary fallback.
			# Refuse rather than invent one.
			return EffectResultScript.failed(
				"apply_status stackable def has invalid max_stacks: %d" % m, [], false)
		effective_max_stacks = m
	# Apply policy via the container boundary.
	var container = world.get_status_container(tgt)
	if container == null:
		container = world.create_status_container(tgt)
	# Create the runtime StatusInstance.
	var inst = StatusInstanceScript.new(
		status_id,
		int(req.source_entity),
		tgt,
		stacks,
		ticks,
		0)
	var accepted = container.add(inst, policy, effective_max_stacks)
	if accepted == null:
		return EffectResultScript.failed("apply_status rejected by container", [], false)
	var emitter = ctx.emitter()
	var ev = null
	if int(req.parent_event_id) > 0 and int(req.root_action_id) > 0:
		# Caller is operating inside a parent root action.
		# STATUS_APPLIED is a child of that action.
		ev = emitter.emit_child(
			BattleEventTypeScript.STATUS_APPLIED,
			int(req.parent_event_id),
			int(req.root_action_id),
			int(req.chain_depth),
			int(req.source_entity),
			tgt,
			"",
			"",
			int(accepted.stacks),
			String(status_id))
	else:
		# Standalone root emission (no parent action).
		ev = emitter.emit(
			BattleEventTypeScript.STATUS_APPLIED,
			int(req.source_entity),
			tgt,
			"",
			"",
			int(accepted.stacks),
			String(status_id))
	ctx.emit_through_sink(ev)
	return EffectResultScript.succeeded([ev], true)
