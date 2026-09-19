extends RefCounted
## B5 / Test-only helpers for TriggerDispatcher tests.
## NOT shipped. Only used in tests/battle_ecs/effects/.

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")


# A test provider that returns no reactions.
class NoopProvider extends TriggerProvider:
	func discover(p_world, p_event, p_rng) -> Array:
		return []


# A provider that, for any DAMAGE_APPLIED event, queues one
# HEAL of 1 HP with chain_depth derived from the event.
# If mirror=true, also queues a back-trigger DAMAGE so we
# can stress depth / reaction budgets via ping-pong.
class PingPongProvider extends TriggerProvider:
	var mirror: bool = true

	func discover(p_world, p_event, p_rng) -> Array:
		var reactions: Array = []
		if int(p_event.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			var heal_req = EffectRequest.new(
				EffectKindScript.HEAL,
				int(p_event.source_entity),
				int(p_event.target_entity),
				1,
				-1, -1, 0)
			var r1 = TriggerReaction.new()
			r1.reacting_entity = int(p_event.target_entity)
			r1.kind = "test_heal_dmg"
			r1.request = heal_req
			reactions.append(r1)
			if mirror:
				var back = EffectRequest.new(
					EffectKindScript.DAMAGE,
					int(p_event.target_entity),
					int(p_event.source_entity),
					1,
					-1, -1, 0)
				var r2 = TriggerReaction.new()
				r2.reacting_entity = int(p_event.source_entity)
				r2.kind = "test_dmg_heal"
				r2.request = back
				reactions.append(r2)
		elif mirror and int(p_event.type) == BattleEventTypeScript.HEAL_APPLIED:
			var dmg_req = EffectRequest.new(
				EffectKindScript.DAMAGE,
				int(p_event.source_entity),
				int(p_event.target_entity),
				1,
				-1, -1, 0)
			var r3 = TriggerReaction.new()
			r3.reacting_entity = int(p_event.target_entity)
			r3.kind = "test_dmg_heal"
			r3.request = dmg_req
			reactions.append(r3)
		return reactions


# Helper: build a single committed DAMAGE_APPLIED event.
class EventBuilder extends RefCounted:
	static func damage_event(
			p_emitter,
			p_source: int,
			p_target: int,
			p_amount: int = 1) -> RefCounted:
		return p_emitter.emit(
			BattleEventTypeScript.DAMAGE_APPLIED,
			p_source, p_target,
			"", "", p_amount, "")
