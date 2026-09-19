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


# A provider that, for any DAMAGE_APPLIED event, emits an
# APPLY_STATUS reaction with definition_id=&"stun", stacks, and
# source->target both pointing at the damage target. Verifies
# full APPLY_STATUS production path: EffectExecutor ->
# ApplyStatusEffect -> StatusDefResolver -> StatusContainer.
class ApplyStatusFromDamage extends TriggerProvider:
	var stacks: int = 1
	func discover(p_world, p_event, p_rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		var req = EffectRequest.new(
			EffectKindScript.APPLY_STATUS,
			int(p_event.target_entity),
			int(p_event.target_entity),
			0,
			-1, -1, 0)
		req.definition_id = &"stun"
		req.payload = {"stacks": stacks}
		var tr = TriggerReaction.new()
		tr.reacting_entity = int(p_event.target_entity)
		tr.kind = "apply_status_stun"
		tr.request = req
		return [tr]


# A provider that, for every event, emits a HEAL reaction
# targeting entity 99 (a non-existent entity). EffectExecutor
# rejects; reactions_executed increments; no event emitted.
class HealDeadEntityReaction extends TriggerProvider:
	func discover(p_world, p_event, p_rng) -> Array:
		var req = EffectRequest.new(
			EffectKindScript.HEAL, 1, 99, 1,
			-1, -1, 0)
		var tr = TriggerReaction.new()
		tr.reacting_entity = 99
		tr.kind = "heal_dead"
		tr.request = req
		return [tr]


# A provider that emits a HEAL chain reaction on EVERY
# event (DAMAGE_APPLIED or HEAL_APPLIED). The chain
# starts: damage -> heal -> heal -> heal -> heal...
# until max_chain_depth stops it. Used to assert exact
# depth-boundary semantics.
class SingleChainProvider extends TriggerProvider:
	var seen_chain: Array = []
	func discover(p_world, p_event, p_rng) -> Array:
		var et: int = int(p_event.type)
		if et != BattleEventTypeScript.DAMAGE_APPLIED \
				and et != BattleEventTypeScript.HEAL_APPLIED:
			return []
		# Each DAMAGE_APPLIED restarts the chain; each
		# HEAL_APPLIED extends it.
		var req = EffectRequest.new(
			EffectKindScript.HEAL,
			int(p_event.target_entity),
			int(p_event.source_entity),
			1,
			-1, -1, 0)
		var tr = TriggerReaction.new()
		tr.reacting_entity = int(p_event.target_entity)
		tr.kind = "chain_heal"
		tr.request = req
		return [tr]


# Counts how many times discover() is called. Increments
# inside discover BEFORE the type check so we can compare
# to dup cases where dedupe should prevent a second call.
class CountingHealProvider extends TriggerProvider:
	var invocations: int = 0
	var damage_invocations: int = 0
	func discover(p_world, p_event, p_rng) -> Array:
		invocations += 1
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		damage_invocations += 1
		var req = EffectRequest.new(
			EffectKindScript.HEAL, 0, 1, 1,
			-1, -1, 0)
		var tr = TriggerReaction.new()
		tr.reacting_entity = 1
		tr.kind = "counting_heal"
		tr.request = req
		return [tr]


# Lethal DAMAGE on the same target every time. With attack=20,
# defense=5, req.amount=99 -> lethal damage -> UNIT_DIED child.
class LethalDamageReaction extends TriggerProvider:
	func discover(p_world, p_event, p_rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		# Use req.amount=99 to ensure lethal.
		var req = EffectRequest.new(
			EffectKindScript.DAMAGE,
			0, 1, 99,
			-1, -1, 0)
		var tr = TriggerReaction.new()
		tr.reacting_entity = 1
		tr.kind = "lethal_dmg"
		tr.request = req
		return [tr]


# Returns malformed reactions: one null, one with null request.
class MalformedProvider extends TriggerProvider:
	func discover(p_world, p_event, p_rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		var null_reaction = null
		var bad = TriggerReaction.new()
		bad.reacting_entity = 0
		bad.kind = "bad"
		bad.request = null
		return [null_reaction, bad]
