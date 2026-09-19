extends RefCounted
## Phase 3 / B3 / PeriodicStatusProcessor — periodic status phase
## driver for Burn / Regen (and similar tick-interval=1.0
## statuses).
##
## B3 scope:
##   - Decrement BEFORE periodic effect (legacy parity).
##   - Reverse insertion-order traversal inside one entity
##     (legacy parity).
##   - Deterministic entity iteration via BattleWorld.alive_ids_in_order()
##     (NOT Dictionary iteration).
##   - STATUS_TICKED root event for each actual periodic fire.
##   - STATUS_EXPIRED root event on natural expiry (NOT
##     STATUS_REMOVED — explicit removal is a separate semantic).
##   - DOT/HOT routed through EffectExecutor via child_from_parent
##     (no caller arithmetic).
##   - tick_interval == 1.0 supported. tick_interval == 0.0 means
##     "no repeated periodic processing" (apply-only). Other
##     intervals FEATURE DEFER.
##   - No resurrection. Dead targets in same status phase do
##     NOT receive later Regen.
##   - StatusInstance.remaining == -1 (indefinite) preserved: no
##     decrement, no expiry. Periodic effect may still fire.
##
## B3.2 RNG ownership:
##   The processor MUST NOT instantiate its own RNG.
##   The caller passes the simulation-owned RNG (BattleSimulation._rng)
##   via process_tick(world, rng, emitter). Periodic effect
##   contexts use exactly that RNG instance. Periodic Burn/Regen
##   draw no randomness today, but the contract must hold for
##   chance-based triggers introduced later.
##
## NO Node. NO UI. NO global RNG. NO global event bus.

const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")

## B3.3 / Periodic payload classification.
## DOT vs HOT is determined from dot_damage / dot_heal PAYLOAD
## (the legacy source of truth in core/battle/status_list.gd),
## NOT from StatusDef.is_harmful (which is a UI/classification
## flag and is NOT the periodic effect kind).
##
## Cases:
##   PERIODIC_NONE:        dot_damage == 0 AND dot_heal == 0
##   PERIODIC_DAMAGE:      dot_damage >  0 AND dot_heal == 0
##   PERIODIC_HEAL:        dot_damage == 0 AND dot_heal >  0
##   PERIODIC_DUAL:        dot_damage >  0 AND dot_heal >  0
##   PERIODIC_INVALID:     either value < 0 (malformed content)
const PERIODIC_NONE: int = 0
const PERIODIC_DAMAGE: int = 1
const PERIODIC_HEAL: int = 2
const PERIODIC_DUAL: int = 3
const PERIODIC_INVALID: int = 4


## Classify the periodic payload of a StatusDef. Returns one of
## the PERIODIC_* constants. Pure function — no allocation,
## no side effects, no rng draws. Used for unit-level
## classification tests and by PeriodicStatusProcessor.
static func classify_periodic_payload(
		p_dot_damage,
		p_dot_heal) -> int:
	var dd: int = int(p_dot_damage)
	var dh: int = int(p_dot_heal)
	if dd < 0 or dh < 0:
		return PERIODIC_INVALID
	if dd == 0 and dh == 0:
		return PERIODIC_NONE
	if dd > 0 and dh == 0:
		return PERIODIC_DAMAGE
	if dd == 0 and dh > 0:
		return PERIODIC_HEAL
	if dd > 0 and dh > 0:
		return PERIODIC_DUAL
	# Unreachable for non-negative integers.
	return PERIODIC_INVALID


## Process one status phase tick. Operates on the passed-in
## dependencies (world, simulation-owned RNG, simulation-owned
## emitter). NO RNG is constructed inside this function.
##
## RNG invariant:
##   rng == null -> early-return empty result, no mutation.
##   Same RNG object must reach every periodic EffectContext.
##
## Returns the array of BattleEvents emitted during this phase,
## in emission order.
static func process_tick(
		p_world,
		p_rng,
		p_emitter: BattleEventEmitterScript) -> Array:
	var events: Array = []
	if p_world == null or p_rng == null or p_emitter == null:
		return events
	# Snapshot alive entities in deterministic allocation order.
	var entities: Array = p_world.alive_ids_in_order()
	for entity_id in entities:
		var container = p_world.get_status_container(int(entity_id))
		if container == null:
			continue
		# REVERSE INSERTION ORDER for the entity's status traversal
		# (legacy parity).
		var statuses: Array = container.all()
		var indices: Array = []
		for i in statuses.size():
			indices.append(i)
		indices.reverse()
		for idx in indices:
			# Re-check liveness: a previous status in this same
			# phase may have killed this entity.
			if not p_world.is_alive(int(entity_id)):
				break
			if idx >= statuses.size():
				# Container mutated (status removed). Refresh.
				statuses = container.all()
				if idx >= statuses.size():
					continue
			var inst = statuses[int(idx)]
			if inst == null:
				continue
			var status_id = inst.status_id
			var stacks = int(inst.stacks)
			# 1. DECREMENT first. StatusInstance.tick(1) preserves
			# the indefinite contract (remaining < 0 -> no
			# decrement, returns false). Timed statuses: 3->2,
			# 2->1, 1->0 (expired).
			var expired: bool = inst.tick(1)
			if expired:
				# 2a. EXPIRED — remove from container + emit
				# STATUS_EXPIRED root event.
				container.remove(status_id)
				var expired_event = p_emitter.emit(
					BattleEventTypeScript.STATUS_EXPIRED,
					int(inst.source_entity),
					int(entity_id),
					"",
					String(p_world.source_run_unit_id_of(int(entity_id))),
					0,
					String(status_id))
				events.append(expired_event)
				# Do NOT emit periodic effect on the expiry tick.
				continue
			# 2b. STILL ACTIVE — consider periodic effect.
			var def: Resource = StatusDefResolverScript.resolve(status_id)
			if def == null:
				continue
			var interval: float = float(def.tick_interval)
			# B3 scope: interval == 1.0 -> every tick;
			# interval == 0.0 -> no repeated periodic processing;
			# other -> FEATURE DEFER (skip silently).
			if interval < 0.0:
				continue
			if interval == 0.0:
				continue
			if interval != 1.0:
				continue
			var dot_damage: int = int(def.dot_damage)
			var dot_heal: int = int(def.dot_heal)
			var kind: int = classify_periodic_payload(
				dot_damage, dot_heal)
			if kind == PERIODIC_NONE:
				# Duration still decrements (already done above);
				# no periodic effect, no STATUS_TICKED.
				continue
			if kind == PERIODIC_DUAL:
				# FEATURE DEFER: dual-payload periodic not
				# supported in B3. Skip silently.
				continue
			if kind == PERIODIC_INVALID:
				# Malformed content. Skip silently.
				continue
			# PERIODIC_DAMAGE or PERIODIC_HEAL.
			var periodic_amount: int = 0
			if kind == PERIODIC_DAMAGE:
				periodic_amount = dot_damage * stacks
			else:
				periodic_amount = dot_heal * stacks
			# Emit STATUS_TICKED root.
			var status_tick_root = p_emitter.emit(
				BattleEventTypeScript.STATUS_TICKED,
				int(inst.source_entity),
				int(entity_id),
				"",
				String(p_world.source_run_unit_id_of(int(entity_id))),
				periodic_amount,
				String(status_id))
			events.append(status_tick_root)
			# Route the periodic effect through EffectExecutor
			# using the canonical child_from_parent factory.
			var effect_kind: int = EffectKindScript.DAMAGE \
				if kind == PERIODIC_DAMAGE \
				else EffectKindScript.HEAL
			var req = EffectRequestScript.child_from_parent(
				effect_kind,
				status_tick_root,
				int(inst.source_entity),
				int(entity_id),
				periodic_amount)
			if req == null:
				continue
			var per_events: Array = _execute_periodic_effect(
				p_world, p_rng, p_emitter, effect_kind, req)
			for ev in per_events:
				events.append(ev)
			# After a Burn tick, re-check liveness: a heal cannot
			# resurrect per Phase-2 DamageEffect; a subsequent
			# Regen MUST NOT run on a unit killed this phase.
			if not p_world.is_alive(int(entity_id)):
				break
	return events


## Run one periodic effect (Damage or Heal) through the existing
## EffectExecutor path so we use the SAME semantics as the
## action-phase Damage/Heal effects (capping, no resurrection,
## UNIT_DIED on lethal).
##
## Uses the caller-provided RNG (simulation-owned) to construct
## the EffectContext — no private RNG construction.
static func _execute_periodic_effect(
		p_world,
		p_rng,
		p_emitter: BattleEventEmitterScript,
		p_effect_kind: int,
		p_req) -> Array:
	var sink: Array = []
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, sink)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, p_req)
	if result == null:
		return []
	return result.events
