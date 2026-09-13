extends RefCounted
## Phase 3 / B2.2 / HealEffect — restore HP via the effect pipeline.
##
## Semantics:
##   - Cannot exceed max HP (overheal capped at max).
##   - Does NOT resurrect dead units.
##   - Emits HEAL_APPLIED with ACTUAL HP restored (not requested).
##
## Event semantics:
##   - Emits HEAL_APPLIED only when actual HP is restored.
##   - result.events contains EVERY event emitted (typically
##     exactly [HEAL_APPLIED] on success, [] on no-op).
##
## B2.2 ancestry contract:
##   - Validates req.validate_ancestry() BEFORE world.heal().
##   - Bad ancestry -> success=false, no world mutation, no
##     event, no emitter counter advance.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")


## Execute heal effect.
static func execute(ctx, req) -> RefCounted:
	# B2.2: validate ancestry FIRST. No mutation may occur before.
	var av = req.validate_ancestry()
	if not bool(av.get("ok", false)):
		return EffectResultScript.failed(
			"heal invalid ancestry: %s" % String(av.get("reason", "")),
			[], false)
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
	if String(av.get("kind", "")) == EffectRequestScript.ANCESTRY_CHILD:
		heal_event = emitter.emit_child(
			BattleEventTypeScript.HEAL_APPLIED,
			int(req.parent_event_id),
			int(req.root_action_id),
			int(req.chain_depth) - 1,
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
	if heal_event == null:
		return EffectResultScript.failed(
			"heal emit failed (ancestry valid but emitter refused)", [], false)
	ctx.emit_through_sink(heal_event)
	return EffectResultScript.succeeded([heal_event], false)
