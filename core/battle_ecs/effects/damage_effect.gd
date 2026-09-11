extends RefCounted
## Phase 3 / DamageEffect — deterministic physical damage.
##
## Semantics (Phase 2 parity):
##   - Uses Balance.compute_damage (pure defense scaling)
##   - NO crit / dodge / variance (NORMATIVE FEATURE DEFER)
##   - Damage amount = actual HP removed (not requested)
##   - Dead target -> EffectResult.failed (no mutation, no event)
##   - Invalid target -> EffectResult.failed
##   - Emits DAMAGE_APPLIED with actual amount
##   - Emits UNIT_DIED on kill (once)
##
## Called ONLY through EffectExecutor. Never invoked directly.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const BalanceScript = preload("res://core/balance.gd")


## Execute damage effect against the world's target_entity.
## Emits ATTACK_RESOLVED + DAMAGE_APPLIED (and UNIT_DIED on kill).
static func execute(ctx, req) -> RefCounted:
	var world = ctx.world()
	# Validate target.
	if not world.is_alive(int(req.target_entity)):
		return EffectResultScript.failed("target not alive", [], false)
	var src: int = int(req.source_entity)
	var tgt: int = int(req.target_entity)
	if src == tgt:
		# source == target: rejected explicitly.
		return EffectResultScript.failed("source equals target", [], false)
	# Compute damage via Balance.compute_damage with attacker
	# attack vs target defense. is_magic=false in this slice.
	var atk: int = int(world.attack_of(src))
	var dfs: int = int(world.defense_of(tgt))
	var dmg: int = int(BalanceScript.compute_damage(
		atk, dfs, false, 0.0, 1.0))
	# Override with request amount if explicitly provided and
	# non-zero (request is the source of truth for damage
	# magnitude when set by callers).
	if int(req.amount) > 0:
		dmg = int(req.amount)
	# ATTACK_RESOLVED event (intent start).
	ctx.emit({
		"type": BattleEventTypeScript.ATTACK_RESOLVED,
		"tick": 0,
		"event_id": 0,
		"source_entity": src,
		"target_entity": tgt,
		"source_run_unit_id": "",
		"target_run_unit_id": "",
		"amount": dmg,
		"parent_event_id": int(req.parent_event_id),
		"root_action_id": int(req.root_action_id),
		"chain_depth": int(req.chain_depth),
		"definition_id": String(req.definition_id),
		"from_cell": Vector2i(-1, -1),
		"to_cell": Vector2i(-1, -1),
	})
	# Apply damage (returns actual amount removed, capped at HP).
	var dealt: int = int(world.apply_damage(tgt, dmg))
	# DAMAGE_APPLIED event with actual amount.
	ctx.emit({
		"type": BattleEventTypeScript.DAMAGE_APPLIED,
		"tick": 0,
		"event_id": 0,
		"source_entity": src,
		"target_entity": tgt,
		"source_run_unit_id": "",
		"target_run_unit_id": "",
		"amount": dealt,
		"parent_event_id": int(req.parent_event_id),
		"root_action_id": int(req.root_action_id),
		"chain_depth": int(req.chain_depth),
		"definition_id": String(req.definition_id),
		"from_cell": Vector2i(-1, -1),
		"to_cell": Vector2i(-1, -1),
	})
	# If lethal, emit UNIT_DIED exactly once.
	if dealt > 0 and not world.is_alive(tgt):
		ctx.emit({
			"type": BattleEventTypeScript.UNIT_DIED,
			"tick": 0,
			"event_id": 0,
			"source_entity": src,
			"target_entity": tgt,
			"source_run_unit_id": "",
			"target_run_unit_id": "",
			"amount": 0,
			"parent_event_id": int(req.parent_event_id),
			"root_action_id": int(req.root_action_id),
			"chain_depth": int(req.chain_depth),
			"definition_id": String(req.definition_id),
			"from_cell": Vector2i(-1, -1),
			"to_cell": Vector2i(-1, -1),
		})
	return EffectResultScript.succeeded([], true)
