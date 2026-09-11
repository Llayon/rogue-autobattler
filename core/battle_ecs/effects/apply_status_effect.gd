extends RefCounted
## Phase 3 / ApplyStatusEffect — applies a StatusInstance to
## the target entity (creates the StatusContainer if absent).

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")

const STATUS_APPLIED: int = 7


## Execute apply-status effect.
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
	var stacks: int = int(req.payload.get("stacks", 1))
	var duration: int = int(req.payload.get("duration", -1))
	var magnitude: int = int(req.payload.get("magnitude", 0))
	var container = world.get_status_container(tgt)
	if container == null:
		container = StatusContainerScript.new()
		world.set_status_container(tgt, container)
	var inst = StatusInstanceScript.new(
		status_id,
		int(req.source_entity),
		tgt,
		stacks,
		duration,
		magnitude)
	container.add(inst)
	var emitter = ctx.emitter()
	var ev = emitter.emit(
		STATUS_APPLIED,
		int(req.source_entity),
		tgt,
		"",
		"",
		int(inst.stacks),
		String(status_id),
		Vector2i(-1, -1),
		Vector2i(-1, -1),
		int(req.root_action_id),
		int(req.parent_event_id),
		int(req.chain_depth))
	ctx.emit_through_sink(ev)
	return EffectResultScript.succeeded([ev], true)
