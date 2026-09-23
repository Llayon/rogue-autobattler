extends RefCounted
## Phase 3 / EffectExecutor — routes EffectRequest to the
## appropriate effect implementation.
##
## This is the SINGLE mutation path for supported Phase 3 combat
## effects. Adding a new effect kind:
##   1. Add constant to EffectKind
##   2. Add static execute() in <NewEffect>.gd
##   3. Wire into EffectExecutor.execute()
##
## EffectExecutor does NOT introduce new RNG, does NOT depend on
## RunDomain, and does NOT mutate world state directly.

const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const DamageEffectScript = preload("res://core/battle_ecs/effects/damage_effect.gd")
const HealEffectScript = preload("res://core/battle_ecs/effects/heal_effect.gd")
const ApplyStatusEffectScript = preload("res://core/battle_ecs/effects/apply_status_effect.gd")
const RemoveStatusEffectScript = preload("res://core/battle_ecs/effects/remove_status_effect.gd")
const PerformAttackEffectScript = preload("res://core/battle_ecs/effects/perform_attack_effect.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")


## Execute one EffectRequest in the given context.
## Returns EffectResult. Never raises exceptions for combat
## outcomes; failed targets produce failed results.
func execute(ctx, req) -> RefCounted:
	var k: int = int(req.kind)
	if k == EffectKindScript.DAMAGE:
		return DamageEffectScript.execute(ctx, req)
	if k == EffectKindScript.HEAL:
		return HealEffectScript.execute(ctx, req)
	if k == EffectKindScript.APPLY_STATUS:
		return ApplyStatusEffectScript.execute(ctx, req)
	if k == EffectKindScript.REMOVE_STATUS:
		return RemoveStatusEffectScript.execute(ctx, req)
	if k == EffectKindScript.MOVE:
		return EffectResultScript.failed("move not implemented", [], false)
	if k == EffectKindScript.PERFORM_ATTACK:
		return PerformAttackEffectScript.execute(ctx, req)
	return EffectResultScript.failed("unknown effect kind: %d" % k, [], false)
