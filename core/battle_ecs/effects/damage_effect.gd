extends RefCounted
## Phase 3 / DamageEffect — generic deterministic physical damage.
##
## Semantics (Phase 2 parity):
##   - Uses Balance.compute_damage (pure defense scaling)
##   - NO crit / dodge / variance (NORMATIVE FEATURE DEFER)
##   - Damage amount = actual HP removed (not requested)
##   - Dead target -> EffectResult.failed (no mutation, no event)
##   - Invalid target -> EffectResult.failed
##   - Self-target -> EffectResult.failed
##
## Event semantics (Phase 3):
##   - Emits DAMAGE_APPLIED (NOT ATTACK_RESOLVED).
##   - Generic damage. PerformAttack (not yet wired) is what
##     emits ATTACK_RESOLVED for combat attacks. Poison / Burn /
##     Thorns / environmental damage all flow through DamageEffect
##     and must NOT masquerade as attacks.
##   - If lethal, emits UNIT_DIED as a CHILD event (parent =
##     DAMAGE_APPLIED.event_id, same root_action_id, depth+1).
##
## Called ONLY through EffectExecutor. Never invoked directly.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const BalanceScript = preload("res://core/balance.gd")


## Execute damage effect against the world's target_entity.
## Emits DAMAGE_APPLIED (and UNIT_DIED on kill) through the
## emitter. Does NOT emit ATTACK_RESOLVED.
static func execute(ctx, req) -> RefCounted:
	var world = ctx.world()
	# Validate target.
	if not world.is_alive(int(req.target_entity)):
		return EffectResultScript.failed("target not alive", [], false)
	var src: int = int(req.source_entity)
	var tgt: int = int(req.target_entity)
	if src == tgt:
		return EffectResultScript.failed("source equals target", [], false)
	# Compute damage via Balance.compute_damage. is_magic=false.
	var atk: int = int(world.attack_of(src))
	var dfs: int = int(world.defense_of(tgt))
	var dmg: int = int(BalanceScript.compute_damage(
		atk, dfs, false, 0.0, 1.0))
	# Override with request amount if explicitly provided and
	# non-zero (caller is source of truth for explicit damage).
	if int(req.amount) > 0:
		dmg = int(req.amount)
	var emitter = ctx.emitter()
	var req_parent: int = int(req.parent_event_id)
	var req_root: int = int(req.root_action_id)
	var req_depth: int = int(req.chain_depth)
	# Build DAMAGE_APPLIED via the emitter. If the caller is
	# inside a parent root action (parent_event_id > 0),
	# DAMAGE_APPLIED is a child of it. Otherwise it is a root.
	var dmg_event = null
	if req_parent > 0 and req_root > 0 and req_depth >= 0:
		dmg_event = emitter.emit_child(
			BattleEventTypeScript.DAMAGE_APPLIED,
			req_parent,
			req_root,
			req_depth,
			src,
			tgt,
			"",
			"",
			0,  # amount placeholder; set after apply
			"")
	else:
		dmg_event = emitter.emit(
			BattleEventTypeScript.DAMAGE_APPLIED,
			src,
			tgt,
			"",
			"",
			0,  # amount placeholder; set after apply
			"")
	# Apply damage (returns actual amount removed, capped at HP).
	var dealt: int = int(world.apply_damage(tgt, dmg))
	# Patch the event with the actual dealt amount (post-apply).
	dmg_event.amount = int(dealt)
	ctx.emit_through_sink(dmg_event)
	# If lethal, emit UNIT_DIED as child of DAMAGE_APPLIED.
	if dealt > 0 and not world.is_alive(tgt):
		var died_event = emitter.emit_child(
			BattleEventTypeScript.UNIT_DIED,
			int(dmg_event.event_id),
			int(dmg_event.root_action_id),
			int(dmg_event.chain_depth),
			src,
			tgt)
		ctx.emit_through_sink(died_event)
	return EffectResultScript.succeeded([dmg_event], true)
