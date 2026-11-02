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
## B6.4c: process_tick() (legacy synchronous path) is preserved
## for backward compat. The new begin_tick() / has_next() /
## next_step() API returns a lazy / resumable cursor. Each step
## inspects LIVE world state. BattleSimulation's step_tick
## drains each step's dispatch_work via the dispatcher BEFORE
## asking for the next step. This preserves:
##   - Burn kill -> later Regen on the same target does NOT
##     execute (cursor resumes against updated world state).
##   - STATUS_TICKED discovery remains post-Burn-commit
##     (work_item.delayed_dispatch_seeds includes STATUS_TICKED).
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
const PERIODIC_NONE: int = 0
const PERIODIC_DAMAGE: int = 1
const PERIODIC_HEAL: int = 2
const PERIODIC_DUAL: int = 3
const PERIODIC_INVALID: int = 4


## Classify the periodic payload of a StatusDef. Pure function.
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
	return PERIODIC_INVALID


## Run one periodic effect (Damage or Heal) through EffectExecutor.
## Returns [events, dispatch_work]. Caller drains dispatch_work
## via the dispatcher work-pump.
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
		return [[], []]
	return [result.events, result.dispatch_work]


# ============================================================
# B6.4c: Lazy / resumable cursor API.
# ============================================================

class PeriodicStatusStep extends RefCounted:
	var events: Array = []
	var dispatch_work: Array = []


class PeriodicStatusCursor extends RefCounted:
	var _owner = null
	# B6.4c: parent-script reference so this inner class can
	# call the outer static helpers (classify_periodic_payload,
	# _execute_periodic_effect). GDScript does not resolve
	# outer-scope statics from inner-class instance methods.
	var _world = null
	var _rng = null
	var _emitter = null
	var _entity_ids: Array = []
	var _entity_idx: int = 0
	var _statuses: Array = []
	var _indices: Array = []
	var _idx_pos: int = 0

	func has_next() -> bool:
		while true:
			# B6.4c REGRESSION FIX: the cursor must visit EVERY alive
			# entity, INCLUDING the first one.
			#
			# The previous guard advanced _entity_idx whenever
			# _idx_pos >= _indices.size(). On the very first call
			# _idx_pos == 0 and _indices == [], so the guard fired
			# immediately and skipped entity 0 entirely. Any status
			# on the first alive entity never ticked in the
			# production step_tick() path.
			#
			# The advance must only happen when the current
			# entity's status list is actually EXHAUSTED — i.e.
			# when _statuses is non-empty and _idx_pos has run
			# past it. A fresh entity (_statuses empty) must be
			# loaded first, not skipped.
			if _statuses.size() > 0 and _idx_pos >= _indices.size():
				_entity_idx += 1
				_idx_pos = 0
				_statuses = []
				_indices = []
			if _entity_idx >= _entity_ids.size():
				return false
			var entity_id: int = int(_entity_ids[_entity_idx])
			if not bool(_world.is_alive(entity_id)):
				_entity_idx += 1
				_idx_pos = 0
				_statuses = []
				_indices = []
				continue
			if _statuses.size() == 0:
				var container = _world.get_status_container(entity_id)
				if container == null:
					_entity_idx += 1
					_idx_pos = 0
					_statuses = []
					_indices = []
					continue
				_statuses = container.all()
				_indices = []
				for i in _statuses.size():
					_indices.append(i)
				_indices.reverse()
				_idx_pos = 0
			if _indices.size() == 0:
				_entity_idx += 1
				_idx_pos = 0
				_statuses = []
				continue
			return true
		# Unreachable fallback.
		return false

	func next_step() -> RefCounted:
		if _world == null:
			return null
		if not has_next():
			return null
		var step = PeriodicStatusStep.new()
		step.events = []
		step.dispatch_work = []
		var entity_id: int = int(_entity_ids[_entity_idx])
		if not bool(_world.is_alive(entity_id)):
			return step
		if _idx_pos >= _indices.size():
			return step
		if _idx_pos >= _statuses.size():
			var container = _world.get_status_container(entity_id)
			if container == null:
				return step
			_statuses = container.all()
		var idx: int = int(_indices[_idx_pos])
		_idx_pos += 1
		if idx >= _statuses.size():
			return step
		var inst = _statuses[idx]
		if inst == null:
			return step
		var status_id = inst.status_id
		# B6.4c STALE-INSTANCE REVALIDATION.
		#
		# `_statuses` is a snapshot of the container's instances
		# taken when this entity was loaded. The container can
		# change between two next_step() calls: the simulation
		# drains the previous step's events, window work and
		# reactions in between, and those can remove a status, or
		# remove it and re-apply the same status_id.
		#
		# The snapshot entry is allowed to execute ONLY when the
		# EXACT same object is still the current live instance for
		# that status_id in this entity's live container:
		#
		#   live_inst == snapshot_inst -> execute
		#   live_inst == null           -> removed  -> skip
		#   live_inst != snapshot_inst -> replaced -> skip
		#
		# Checking only status_id membership is NOT enough: after a
		# remove + re-apply the id IS present again, but it is a
		# DIFFERENT object. Ticking the stale one would mutate a
		# detached instance, emit a stale STATUS_TICKED / heal, and
		# — when the stale instance expires — remove the LIVE
		# replacement by id.
		#
		# The check happens BEFORE any status mutation: no tick, no
		# remaining change, no STATUS_EXPIRED, no STATUS_TICKED, no
		# EffectRequest, no RNG draw.
		var live_container = _world.get_status_container(entity_id)
		if live_container == null:
			return step
		var live_inst = live_container.get_status(status_id)
		if live_inst == null:
			return step
		if live_inst != inst:
			return step
		var expired: bool = inst.tick(1)
		if expired:
			var container = _world.get_status_container(entity_id)
			if container != null:
				container.remove(status_id)
			var expired_event = _emitter.emit(
				BattleEventTypeScript.STATUS_EXPIRED,
				int(inst.source_entity),
				int(entity_id),
				"",
				String(_world.source_run_unit_id_of(int(entity_id))),
				0,
				String(status_id))
			step.events.append(expired_event)
			return step
		var def: Resource = StatusDefResolverScript.resolve(status_id)
		if def == null:
			return step
		var interval: float = float(def.tick_interval)
		if interval <= 0.0 or interval != 1.0:
			return step
		var dot_damage: int = int(def.dot_damage)
		var dot_heal: int = int(def.dot_heal)
		var kind: int = _owner.classify_periodic_payload(dot_damage, dot_heal)
		if kind == _owner.PERIODIC_NONE or kind == _owner.PERIODIC_DUAL or kind == _owner.PERIODIC_INVALID:
			return step
		var stacks: int = int(inst.stacks)
		var periodic_amount: int = 0
		if kind == _owner.PERIODIC_DAMAGE:
			periodic_amount = dot_damage * stacks
		else:
			periodic_amount = dot_heal * stacks
		var status_tick_root = _emitter.emit(
			BattleEventTypeScript.STATUS_TICKED,
			int(inst.source_entity),
			int(entity_id),
			"",
			String(_world.source_run_unit_id_of(int(entity_id))),
			periodic_amount,
			String(status_id))
		step.events.append(status_tick_root)
		var effect_kind: int = EffectKindScript.DAMAGE \
				if kind == _owner.PERIODIC_DAMAGE \
				else EffectKindScript.HEAL
		var req = EffectRequestScript.child_from_parent(
			effect_kind,
			status_tick_root,
			int(inst.source_entity),
			int(entity_id),
			periodic_amount)
		if req == null:
			return step
		# B6.4c: attach the status_id as a semantic tag so the
		# downstream DamageEffect can propagate it to
		# DAMAGE_STARTED / DAMAGE_APPLIED for ancestry
		# identity. This preserves the legacy B3 status-tick
		# tag contract.
		if req.payload == null:
			req.payload = {}
		req.payload[EffectRequestScript.PAYLOAD_EVENT_TAG] = status_id
		# B6.4d: state the damage origin explicitly so a pre-damage
		# reaction can discriminate a periodic window from an attack
		# window without string guessing. Only a DAMAGE request
		# carries a damage origin: a HEAL opens no damage window, so
		# stamping an origin on it would be meaningless metadata.
		if effect_kind == int(EffectKindScript.DAMAGE):
			req.payload[EffectRequestScript.PAYLOAD_DAMAGE_ORIGIN] = \
				int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC)
		var per_result: Array = _owner._execute_periodic_effect(
			_world, _rng, _emitter, effect_kind, req)
		var per_events: Array = per_result[0] if per_result.size() > 0 else []
		var per_work: Array = per_result[1] if per_result.size() > 1 else []
		for ev in per_events:
			step.events.append(ev)
		# B6.4c: for periodic Burn (DAMAGE), the DamageEffect
		# opened a window. The DamageWindowWorkItem is in
		# per_work. Attach STATUS_TICKED as a delayed seed so
		# the dispatcher delays STATUS_TICKED's discovery
		# until after the window commits.
		for w in per_work:
			if w != null and w.get_script() != null \
					and w.get_script().get_global_name() == "DamageWindowWorkItem":
				if w.delayed_dispatch_seeds == null:
					w.delayed_dispatch_seeds = []
				if not w.delayed_dispatch_seeds.has(status_tick_root):
					w.delayed_dispatch_seeds.append(status_tick_root)
			step.dispatch_work.append(w)
		return step


func begin_tick(p_world, p_rng,
		p_emitter: BattleEventEmitterScript):
	# B6.4c: pass `self` (the outer PeriodicStatusProcessor
	# script) so the inner PeriodicStatusCursor class can call
	# the outer's static helpers (classify_periodic_payload,
	# _execute_periodic_effect) and access the constants
	# PERIODIC_DAMAGE / PERIODIC_HEAL. GDScript inner classes
	# do not resolve outer-scope statics directly.
	var cursor = PeriodicStatusCursor.new()
	cursor._owner = self
	cursor._world = p_world
	cursor._rng = p_rng
	cursor._emitter = p_emitter
	if p_world != null:
		cursor._entity_ids = p_world.alive_ids_in_order()
	cursor._entity_idx = 0
	cursor._idx_pos = 0
	return cursor


## Legacy synchronous process_tick (preserved for backward
## compat). BattleSimulation's step_tick uses the cursor API.
static func process_tick(
		p_world,
		p_rng,
		p_emitter: BattleEventEmitterScript) -> Array:
	var events: Array = []
	# B6.4c: the legacy synchronous path collects the window's
	# committed events in its own sink, because the periodic
	# effect's own context uses a private sink.
	var sink: Array = []
	if p_world == null or p_rng == null or p_emitter == null:
		return events
	var entities: Array = p_world.alive_ids_in_order()
	for entity_id in entities:
		var container = p_world.get_status_container(int(entity_id))
		if container == null:
			continue
		var statuses: Array = container.all()
		var indices: Array = []
		for i in statuses.size():
			indices.append(i)
		indices.reverse()
		for idx in indices:
			if not p_world.is_alive(int(entity_id)):
				break
			if idx >= statuses.size():
				statuses = container.all()
				if idx >= statuses.size():
					continue
			var inst = statuses[int(idx)]
			if inst == null:
				continue
			var status_id = inst.status_id
			var stacks = int(inst.stacks)
			var expired: bool = inst.tick(1)
			if expired:
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
				continue
			var def: Resource = StatusDefResolverScript.resolve(status_id)
			if def == null:
				continue
			var interval: float = float(def.tick_interval)
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
				continue
			if kind == PERIODIC_DUAL:
				continue
			if kind == PERIODIC_INVALID:
				continue
			var periodic_amount: int = 0
			if kind == PERIODIC_DAMAGE:
				periodic_amount = dot_damage * stacks
			else:
				periodic_amount = dot_heal * stacks
			var status_tick_root = p_emitter.emit(
				BattleEventTypeScript.STATUS_TICKED,
				int(inst.source_entity),
				int(entity_id),
				"",
				String(p_world.source_run_unit_id_of(int(entity_id))),
				periodic_amount,
				String(status_id))
			events.append(status_tick_root)
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
			# B6.4d: state the damage origin explicitly.
			#
			# The cursor path above already sets it, but the LEGACY
			# synchronous path built its request without the origin
			# payload. DamageEffect._origin_of_request() then fell
			# back to its default, DAMAGE_ORIGIN_DIRECT, which made
			# a burn window indistinguishable from an ability-damage
			# window. A pre-damage reaction with a DIRECT-only scope
			# (Shield Block) would then have blocked Burn — violating
			# the frozen "PERIODIC excluded" contract.
			#
			# Only a DAMAGE request carries a damage origin: a HEAL
			# opens no damage window, so stamping an origin on it
			# would be meaningless metadata.
			if effect_kind == int(EffectKindScript.DAMAGE):
				if req.payload == null:
					req.payload = {}
				req.payload[EffectRequestScript.PAYLOAD_DAMAGE_ORIGIN] = \
					int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC)
			var per_result: Array = _execute_periodic_effect(
				p_world, p_rng, p_emitter, effect_kind, req)
			var per_events: Array = per_result[0] if per_result.size() > 0 else []
			var per_work: Array = per_result[1] if per_result.size() > 1 else []
			for ev in per_events:
				events.append(ev)
			# B6.4c: the periodic DAMAGE effect opened a
			# pre-damage window. The legacy process_tick() is a
			# SYNCHRONOUS API: on a5dd87d the burn mutated HP
			# inside this call, so the NEXT status in the same
			# phase saw the post-damage world (a lethal burn
			# suppressed the following regen).
			#
			# The window must therefore be COMPLETED here, before
			# the loop advances to the next status. We finalize the
			# window's continuation directly (the same commit path
			# the canonical pump uses) and publish its events.
			# Post-commit DISCOVERY stays out of this legacy
			# synchronous API — it is the canonical pump's job.
			for w in per_work:
				if w == null or w.get_script() == null:
					continue
				if String(w.get_script().get_global_name()) \
						!= "DamageWindowWorkItem":
					continue
				var cont = w.continuation
				if cont == null:
					continue
				var fr = cont.finalize(p_world, sink, p_emitter)
				if fr != null:
					for ev2 in fr.emitted:
						events.append(ev2)
			if not p_world.is_alive(int(entity_id)):
				break
	return events