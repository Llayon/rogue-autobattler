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
##
## NO Node. NO UI. NO global RNG. NO global event bus.
## Usage: called once per tick from BattleSimulation BEFORE the
## action phase. The processor uses the simulation-owned
## BattleEventEmitter.

const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")

## Process one status phase tick. Operates directly on the
## passed-in dependencies.
##
## Returns the array of BattleEvents emitted during this phase,
## in emission order.
static func process_tick(
		p_world,
		p_emitter: BattleEventEmitterScript) -> Array:
	var events: Array = []
	if p_world == null or p_emitter == null:
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
			# 1. DECREMENT first.
			var new_remaining: int = int(inst.remaining) - 1
			inst.remaining = new_remaining
			if new_remaining <= 0:
				# 2a. EXPIRED — remove from container + emit
				# STATUS_EXPIRED root event.
				container.remove(status_id)
				var expired = p_emitter.emit(
					BattleEventTypeScript.STATUS_EXPIRED,
					int(inst.source_entity),
					int(entity_id),
					"",
					String(p_world.source_run_unit_id_of(int(entity_id))),
					0,
					String(status_id))
				events.append(expired)
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
			var harmful: bool = bool(def.is_harmful)
			var dot_damage: float = float(def.dot_damage) if harmful else 0.0
			var dot_heal: float = float(def.dot_heal) if not harmful else 0.0
			var periodic_amount: int = 0
			if harmful:
				periodic_amount = int(dot_damage * float(stacks))
			else:
				periodic_amount = int(dot_heal * float(stacks))
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
			var effect_kind: int = EffectKindScript.DAMAGE if harmful else EffectKindScript.HEAL
			var req = EffectRequestScript.child_from_parent(
				effect_kind,
				status_tick_root,
				int(inst.source_entity),
				int(entity_id),
				periodic_amount)
			if req == null:
				continue
			var per_events: Array = _execute_periodic_effect(
				p_world, p_emitter, effect_kind, req)
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
static func _execute_periodic_effect(
		p_world,
		p_emitter: BattleEventEmitterScript,
		p_effect_kind: int,
		p_req) -> Array:
	# Build a minimal EffectContext. B3 periodic path has no
	# random draws (DOT/HOT are fixed amounts); the RNG exists
	# only to satisfy the context shape.
	var rng = DeterministicRngScript.new(0)
	var sink: Array = []
	var ctx = EffectContextScript.new(p_world, rng, p_emitter, sink)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, p_req)
	if result == null:
		return []
	return result.events
