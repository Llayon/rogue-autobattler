extends RefCounted
## Phase 3 / HealEffect — restore HP via the effect pipeline.
##
## Semantics:
##   - Cannot exceed max HP (overheal capped at max).
##   - Does NOT resurrect dead units.
##   - Emits HEAL_APPLIED with ACTUAL HP restored (not requested).
##
## Event semantics (Phase 3):
##   - Emits HEAL_APPLIED only.
##   - Event has valid event_id, tick, source/target IDs,
##     root_action_id, parent_event_id, chain_depth.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")


## Execute heal effect.
static func execute(ctx, req) -> RefCounted:
	var world = ctx.world()
	var tgt: int = int(req.target_entity)
	if not world.is_alive(tgt):
		return EffectResultScript.failed("heal target not alive", [], false)
	var src: int = int(req.source_entity)
	var cur_hp: int = int(world.current_hp_of(tgt))
	if cur_hp <= 0:
		return EffectResultScript.failed("heal target has 0 HP", [], false)
	var max_hp: int = int(world.max_hp_of(tgt))
	if cur_hp >= max_hp:
		# Already at max. No-op success, no event.
		return EffectResultScript.succeeded([], false)
	var amount: int = int(req.amount)
	var room: int = max_hp - cur_hp
	var restored: int = mini(amount, room)
	world.heal(tgt, restored)
	var emitter = ctx.emitter()
	var heal_event = null
	if int(req.parent_event_id) > 0 and int(req.root_action_id) > 0:
		heal_event = emitter.emit_child(
			BattleEventTypeScript.HEAL_APPLIED,
			int(req.parent_event_id),
			int(req.root_action_id),
			int(req.chain_depth),
			src,
			tgt,
			"",
			"",
			restored,
			"")
	else:
		heal_event = emitter.emit(
			BattleEventTypeScript.HEAL_APPLIED,
			src,
			tgt,
			"",
			"",
			restored,
			"")
	ctx.emit_through_sink(heal_event)
	return EffectResultScript.succeeded([heal_event], false)
