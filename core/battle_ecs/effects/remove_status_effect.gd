extends RefCounted
## Phase 3 / B1 / RemoveStatusEffect — removes a StatusInstance
## from the target entity.
##
## B1: StatusDef is consulted only to confirm the status_id is
## known. Removal itself is owner-scoped.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")

const STATUS_REMOVED: int = 8


## Execute remove-status effect.
static func execute(ctx, req) -> RefCounted:
	var world = ctx.world()
	var tgt: int = int(req.target_entity)
	if not world.is_alive(tgt):
		return EffectResultScript.failed("remove_status target not alive", [], false)
	var status_id: StringName = &""
	if req.payload.has("status_id"):
		status_id = StringName(String(req.payload["status_id"]))
	elif String(req.definition_id) != "":
		status_id = req.definition_id
	else:
		return EffectResultScript.failed("remove_status missing status_id", [], false)
	# B1: confirm status_id is known via StatusDef lookup.
	if not StatusDefResolverScript.has(status_id):
		return EffectResultScript.failed("remove_status unknown status_id: %s" % str(status_id), [], false)
	var container = world.get_status_container(tgt)
	if container == null:
		return EffectResultScript.failed("no status container", [], false)
	if not container.remove(status_id):
		return EffectResultScript.failed("status not present", [], false)
	var emitter = ctx.emitter()
	var ev = emitter.emit(
		STATUS_REMOVED,
		int(req.source_entity),
		tgt,
		"",
		"",
		0,
		String(status_id),
		Vector2i(-1, -1),
		Vector2i(-1, -1),
		int(req.root_action_id),
		int(req.parent_event_id),
		int(req.chain_depth))
	ctx.emit_through_sink(ev)
	return EffectResultScript.succeeded([ev], false)
