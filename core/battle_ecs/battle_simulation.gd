class_name BattleSimulation extends RefCounted
## Phase 2 / BattleSimulation — minimal headless simulation
## controller.
##
## Contract (this slice):
##   - initialize(setup: BattleSetup): owns a DeterministicRng
##     seeded with setup.seed; creates a BattleWorld; spawns one
##     entity per BattleUnitSetup. Returns false if the setup
##     fails validate() — caller MUST check is_valid() or the
##     bool return value before stepping. Invalid setups leave
##     the simulation in an unusable state.
##   - step_tick() -> Array[BattleEvent]: advances by one tick.
##   - is_finished() -> bool: true once step_tick has produced a
##     BATTLE_ENDED event (natural, stalemate, or tick budget).
##   - get_result() -> BattleResult: only valid after is_finished.
##   - world() -> BattleWorld: TEST/DEBUG mutable escape hatch
##     (see MEDIUM 7 — not a readonly handle).
##   - rng(): the owned DeterministicRng (TEST/DEBUG).
##   - is_valid() -> bool: false if initialize rejected the setup.
##
## Hard rules:
##   - NO Node/Control/Sprite/Tween/AnimationPlayer inside.
##   - NO global Rng, NO RandomNumberGenerator.new(), NO
##     @GlobalScope rand*, NO randomize().
##
## Termination semantics:
##   - NATURAL: one side empty -> winner = surviving side (or -1
##     if both empty). outcome = VICTORY / DEFEAT / DRAW.
##   - STALEMATE: 2 consecutive ticks with no UNIT_DIED /
##     DAMAGE_APPLIED / UNIT_MOVED AND no position+HP change ->
##     winner = -1, outcome = DRAW.
##   - TICK_BUDGET: _max_ticks reached -> winner = -1, DRAW.
##   - Forced termination NEVER awards a victory.
##
## Scheduler (BLOCKER 1 / vertical-slice):
##   - One acting entity per side per tick (lowest-ID living
##     first, deterministic).
##   - Acting entity picks its nearest living enemy.
##   - If in attack range: attack.
##   - Else: move ONE cell toward target (Manhattan, Y-first,
##     occupied-cell-aware). Emit UNIT_MOVED on success.
##   - TODO Phase 3: full scheduler with attack_speed, all-unit
##     activation, abilities/effects.

const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const StatQueryScript = preload("res://core/battle_ecs/status/stat_query.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
# B6.1: route all normal attacks through the canonical
# PERFORM_ATTACK effect. Same emitter instance as
# step_tick reactions, same executor semantics.
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const BalanceScript = preload("res://core/balance.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const ContentReactionProviderScript = preload(
	"res://core/battle_ecs/triggers/content_reaction_provider.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")

const _MAX_NO_PROGRESS_TICKS: int = 2

var _rng: RefCounted = null
var _world: RefCounted = null
var _setup: RefCounted = null
var _tick_count: int = 0
var _finished: bool = false
var _result: RefCounted = null
# B2.0: removed _next_event_id. Simulation owns ONE
# BattleEventEmitter. All event_id / root_action_id allocation
# flows through it.
var _event_emitter: RefCounted = null
# B3: periodic status phase processor (Burn / Regen timing).
# Optional — null means no periodic processing wired in.
var _periodic_status_processor: RefCounted = null
var _max_ticks: int = 0
var _no_progress_count: int = 0
var _last_progress_sig: String = ""
var _valid: bool = false
var _termination_reason: int = BattleResultScript.TERMINATION_NATURAL
# B6: trigger spine. BattleSimulation owns exactly ONE
# TriggerDispatcher + ONE TriggerProvider reference + ONE
# TriggerLimits configuration. Default provider is a fresh
# ContentReactionProvider installed on every initialize()
# (B6.2b). set_trigger_provider() and set_trigger_limits()
# configure content; initialize() resets defaults so prior
# battles do not leak.
var _trigger_dispatcher: RefCounted = null
var _trigger_provider: RefCounted = null
var _trigger_limits: Resource = null
# Per-tick session. reset to null between ticks.
var _trigger_session: RefCounted = null
# Diagnostic accessor for the latest individual
# TriggerDispatcher.process() result during step_tick.
# Each phase (status / player / enemy) overwrites it, so it
# reflects ONLY the most recent single dispatch call. NOT a
# whole-tick aggregate. Null after first initialize().
# Test-only convenience.
var _last_trigger_dispatch_result: RefCounted = null


## Returns the simulation-owned BattleEventEmitter. Effects
## operating outside BattleSimulation may own their own
## emitter; this method exposes the simulation's single
## authoritative one so future EffectContext wiring can share
## it.
func emitter() -> RefCounted:
	return _event_emitter


func is_valid() -> bool:
	return _valid


func is_finished() -> bool:
	return _finished


func initialize(setup: BattleSetup) -> bool:
	# BLOCKER 2 fix: reset ALL per-battle state on every
	# initialize. No previous-battle configuration may leak
	# between runs on the same BattleSimulation instance.
	_valid = false
	_finished = false
	_result = null
	_tick_count = 0
	_periodic_status_processor = null  # B3: fresh default below
	_no_progress_count = 0
	_last_progress_sig = ""
	_termination_reason = BattleResultScript.TERMINATION_NATURAL
	_max_ticks = 0  # reset caller-overridden tick budget
	# B6: reset trigger spine to safe defaults per battle.
	_trigger_dispatcher = TriggerDispatcherScript.new()
	# B6.2b: reset _trigger_provider to a fresh
	# ContentReactionProvider and trigger limits to defaults
	# (32 / 10000 / 256). Custom providers may still override
	# via set_trigger_provider() AFTER initialize(); a
	# subsequent initialize() must discard the custom provider
	# and reinstall the default.
	_trigger_provider = ContentReactionProviderScript.new()
	_trigger_limits = TriggerLimitsScript.new()        # 32/10000/256
	_trigger_session = null
	_last_trigger_dispatch_result = null
	# B2.0: own exactly one BattleEventEmitter. reset() makes
	# the next event_id start at 1 and the next root_action_id
	# start at 1. No previous battle counter leaks across
	# reinitialize.
	_event_emitter = BattleEventEmitterScript.new()
	_event_emitter.reset()
	_event_emitter.set_tick(0)
	# B3: default to the standard periodic status processor.
	var PeriodicStatusProcessorScript = preload(
		"res://core/battle_ecs/status/periodic_status_processor.gd")
	_periodic_status_processor = PeriodicStatusProcessorScript.new()
	# HIGH 6 fix: own a true snapshot copy of the setup so
	# caller mutation of the original BattleSetup after
	# initialize() cannot retroactively alter an in-progress
	# battle. BattleSetup constructor already deep-copies the
	# unit arrays, so passing the same setup reference to the
	# constructor produces a fresh defensive copy.
	_setup = BattleSetupScript.new(
		setup.seed,
		setup.player_units,
		setup.enemy_units,
		setup.grid_width,
		setup.grid_height)
	# BLOCKER 5: validate setup before spawning. If validate
	# returns non-empty, reject and leave _valid=false.
	var err: String = _setup.validate()
	if err != "":
		_world = null
		_rng = null
		_setup = null
		return false
	_rng = DeterministicRngScript.new(0)
	_rng.seed_with(int(_setup.seed))
	_world = BattleWorldScript.new(int(_setup.grid_width), int(_setup.grid_height))
	# Spawn first, THEN capture the initial progress signature
	# (BLOCKER 9 fix).
	_world.spawn_from_setup(_setup)
	_last_progress_sig = _progress_signature()
	_valid = true
	return true


## Set a hard tick ceiling. After this many ticks step_tick
## force-finishes the simulation with OUTCOME_DRAW and
## termination_reason = TICK_BUDGET.
func set_max_ticks(p_max_ticks: int) -> void:
	_max_ticks = maxi(0, int(p_max_ticks))


## B6 trigger configuration lifecycle. CANONICAL CALLER
## SEQUENCE:
##   sim.initialize(setup)
##   sim.set_trigger_provider(provider)
##   sim.set_trigger_limits(limits)
##   sim.step_tick()
## initialize() resets _trigger_provider to a fresh
## ContentReactionProvider and _trigger_limits to
## 32/10000/256 defaults. Configuration applied BEFORE
## initialize() is discarded. Apply AFTER.
func set_trigger_provider(p_provider) -> void:
	_trigger_provider = p_provider


func set_trigger_limits(p_limits: Resource) -> void:
	_trigger_limits = p_limits


## MEDIUM 7: Caller safety helper. Loops step_tick until the
## simulation finishes OR until the local `max_ticks` cap is
## reached. This cap is a CALLER-side safety bound (independent
## of the simulation's own set_max_ticks() termination rule).
##
## Important:
##   - The cap is NOT a battle termination rule. If the cap
##     fires first, is_finished() returns false and get_result()
##     returns null. Caller MUST inspect is_finished().
##   - For real termination rules, use set_max_ticks(N) which
##     produces a TERMINATION_TICK_BUDGET outcome.
##   - Two distinct concepts: `set_max_ticks(N)` (simulation
##     termination rule, produces BATTLE_ENDED) vs
##     `run_until_done(N)` (caller safety cap, may return early
##     without is_finished).
##
## Returns all events collected during the run in emission order.
func run_until_done(max_ticks: int = 10000) -> Array:
	var collected: Array = []
	if not _valid:
		return collected
	while not _finished and _tick_count < max_ticks:
		var evs: Array = step_tick()
		for e in evs:
			collected.append(e)
	return collected


## Advance one tick. Returns events emitted during this tick
## (possibly empty). Once finished, returns [].
##
## B6 TICK ORDER (B6-3 / B6-4 / B6-5 / B6-6):
##   1. set emitter tick
##   2. begin fresh TriggerDispatchSession (snapshotted limits)
##   3. periodic status phase commits events
##   4. dispatch reactions to status-phase events
##   5. refresh alive snapshot (Burn may have killed a unit)
##   6. if both sides alive: player action commits events
##   7. dispatch reactions to player action events (same
##      session -> cumulative MAX_EVENTS, root budget,
##      seen-set across phases this tick)
##   8. refresh alive snapshot (a reaction may have killed)
##   9. if both sides alive: enemy action commits events
##   10. dispatch reactions to enemy action events (same
##       session)
##  11. progress / termination checks
##  12. BATTLE_ENDED if necessary
func step_tick() -> Array:
	if not _valid:
		return []
	if _finished:
		return []
	_tick_count += 1
	_event_emitter.set_tick(_tick_count)
	var events: Array = []
	# B6-2 / B6-3 / B6.4c: ONE TriggerDispatchSession per tick.
	# The session snapshots TriggerLimits numeric values so the
	# in-progress tick cannot be affected by external mutation
	# of the underlying Resource. The session is shared across
	# periodic, player, and enemy phases, so reaction budget
	# and the seen-set cover the whole tick.
	_trigger_session = _trigger_dispatcher.begin_session(
		_trigger_limits)
	# === 1. periodic status phase (lazy cursor) ===
	if _periodic_status_processor != null:
		# Use the new cursor API. Each step's dispatch_work
		# drains BEFORE the next step's status is read.
		var cursor = _periodic_status_processor.begin_tick(
			_world, _rng, _event_emitter)
		while cursor.has_next():
			var step = cursor.next_step()
			if step == null:
				break
			for e in step.events:
				events.append(e)
			# Drain the step's window work. The dispatcher
			# processes DamageWindowWorkItem via the work
			# path; finalize() commits HP; ATTACK_RESOLVED /
			# STATUS_TICKED discovery is delayed.
			#
			# B6.4c PERIODIC-PHASE DISCOVERY (regression fix).
			# Legacy a5dd87d dispatched the periodic phase's
			# PUBLIC events (STATUS_TICKED, STATUS_EXPIRED) to
			# the dispatcher. The cursor refactor drained ONLY
			# `step.dispatch_work`, so a heal-only status tick
			# (REGEN — no damage window, hence no dispatch work)
			# never reached the dispatcher and its STATUS_TICKED
			# reaction never fired.
			#
			# The step's own events are dispatched AFTER the
			# window work, so a damage window's STATUS_TICKED is
			# still discovered AFTER its commit (the window's
			# delayed_dispatch_seeds path). The session's seen-set
			# makes the second delivery a no-op, so nothing is
			# discovered twice.
			if step.dispatch_work != null and step.dispatch_work.size() > 0:
				_last_trigger_dispatch_result = \
					_trigger_dispatcher.process_work(
						step.dispatch_work, _world, _rng, _event_emitter, events,
						_trigger_provider, _trigger_limits, _trigger_session)
			if step.events != null and step.events.size() > 0:
				_last_trigger_dispatch_result = \
					_trigger_dispatcher.process_work(
						step.events, _world, _rng, _event_emitter, events,
						_trigger_provider, _trigger_limits, _trigger_session)
			# Refresh: if a lethal tick happened, the cursor's
			# next iteration will observe updated world state.
	# === 2-3. player normal action ===
	if not _world.one_side_empty():
		var player_work: Array = []
		var player_events: Array = _drive_team_action(0, player_work)
		for e in player_events:
			events.append(e)
		if player_work.size() > 0:
			_last_trigger_dispatch_result = \
				_trigger_dispatcher.process_work(
					player_work, _world, _rng, _event_emitter, events,
					_trigger_provider, _trigger_limits, _trigger_session)
		# B6.4c ACTION-PHASE DISCOVERY (regression fix).
		#
		# Legacy a5dd87d dispatched the action phase's PUBLIC
		# events (UNIT_MOVED, UNIT_ATTACKED, ...), not just the
		# work. The work-only drain dropped every public event
		# that opens NO window — UNIT_MOVED (5) is the canonical
		# example — so a reaction bound to it never fired in the
		# production step_tick() path.
		#
		# The action's own events are dispatched AFTER its work,
		# so a damage window's intent is still discovered after
		# its commit. The session's seen-set makes a second
		# delivery a no-op, so nothing is discovered twice.
		if player_events != null and player_events.size() > 0:
			_last_trigger_dispatch_result = \
				_trigger_dispatcher.process_work(
					player_events, _world, _rng, _event_emitter, events,
					_trigger_provider, _trigger_limits, _trigger_session)
	# === 4-5. enemy normal action (only if not yet natural) ===
	if not _world.one_side_empty():
		var enemy_work: Array = []
		var enemy_events: Array = _drive_team_action(1, enemy_work)
		for e in enemy_events:
			events.append(e)
		if enemy_work.size() > 0:
			_last_trigger_dispatch_result = \
				_trigger_dispatcher.process_work(
					enemy_work, _world, _rng, _event_emitter, events,
					_trigger_provider, _trigger_limits, _trigger_session)
		# B6.4c ACTION-PHASE DISCOVERY — see the player phase.
		if enemy_events != null and enemy_events.size() > 0:
			_last_trigger_dispatch_result = \
				_trigger_dispatcher.process_work(
					enemy_events, _world, _rng, _event_emitter, events,
					_trigger_provider, _trigger_limits, _trigger_session)
	# === termination / progress ===
	var natural: bool = _world.one_side_empty()
	var budget: bool = _max_ticks > 0 and _tick_count >= _max_ticks
	var progressed: bool = _has_progressed(events)
	if not progressed and not natural and not budget:
		_no_progress_count += 1
		if _no_progress_count >= _MAX_NO_PROGRESS_TICKS:
			_termination_reason = BattleResultScript.TERMINATION_STALEMATE
			_finished = true
	else:
		_no_progress_count = 0
		_last_progress_sig = _progress_signature()
	if natural and not _finished:
		_termination_reason = BattleResultScript.TERMINATION_NATURAL
		_finished = true
	if budget and not _finished:
		_termination_reason = BattleResultScript.TERMINATION_TICK_BUDGET
		_finished = true
	if _finished:
		_result = _build_result()
		events.append(_make_battle_ended_event())
	# B6.4c: invariant. If any damage window is still open
	# at end-of-tick, that is a BUG.
	#
	# NOTE: no assert() here — assert() is stripped in release
	# builds (and the lint forbids it in core/). The invariant is
	# checked with a plain runtime branch that FAILS SAFE: the
	# tick is still terminated normally, but the condition is
	# recorded so it cannot pass silently.
	if int(_trigger_dispatcher.pending_count()) != 0:
		GameLog.error("battle_simulation",
			"B6.4c: dangling damage windows at end of step_tick (%d)"
				% int(_trigger_dispatcher.pending_count()))
	_trigger_session = null
	return events


## B6-4: drive one team's normal action. Returns the
## committed action events in emission order. Skipped if
## the team is empty or the selected actor is blocked.
##
## If the team is empty or there are no living enemies,
## returns [] (no action this tick).
##
## Status: replaces the player+enemy coupling in
## `_drive_basic_attacks` so that immediate reactions
## between player and enemy actions do not require a
## second `step_tick`.
##
## B6.1: every alive action resolves via a single canonical
## PERFORM_ATTACK EffectRequest through EffectExecutor. There
## is ONE production mutation path for attacks.
##
## Sink ownership: the effect receives a LOCAL action sink.
## We then append those events to the step_tick output
## exactly once. The EffectContext sink is the SINGLE
## insertion path for reaction events per B6-repair.
##
## Movement (out-of-range) is NOT moved through PERFORM_ATTACK.
## It uses `_resolve_or_move` directly as the scheduler's
## job; PERFORM_ATTACK itself rejects out-of-range cleanly.
## B6.4c: p_work_sink is filled with EffectResult.dispatch_work
## items. step_tick owns draining the work via the SAME
## TriggerDispatchSession shared across phases.
func _drive_team_action(team_id: int, p_work_sink: Array = []) -> Array:
	var events: Array = []
	var attacker_id: int = -1
	var target_id: int = -1
	var p_ids: Array = _world.alive_ids_by_team(0)
	var e_ids: Array = _world.alive_ids_by_team(1)
	if team_id == 0:
		if p_ids.is_empty() or e_ids.is_empty():
			return events
		attacker_id = int(p_ids[0])
		target_id = _world.nearest_enemy_id(attacker_id, e_ids)
	else:
		if e_ids.is_empty() or p_ids.is_empty():
			return events
		attacker_id = int(e_ids[0])
		target_id = _world.nearest_enemy_id(attacker_id, p_ids)
	if target_id < 0:
		return events
	if StatQueryScript.blocks_actions(_world, attacker_id):
		return events
	# Out-of-range → scheduler moves one cell toward target
	# (movement is a scheduler responsibility; PERFORM_ATTACK
	# itself rejects out-of-range).
	if not _world.in_attack_range(attacker_id, target_id):
		return _resolve_or_move(attacker_id, target_id)
	# In range — the canonical path: root PERFORM_ATTACK
	# through EffectExecutor. amount=0 enforced; damage is
	# computed inside PerformAttackEffect from the live
	# BattleWorld stats.
	#
	# B6.4c: dispatch_work is placed into p_work_sink. The
	# tick-level step_tick owns draining work via the SAME
	# TriggerDispatchSession shared across phases. This
	# function MUST NOT call the dispatcher itself.
	var req = EffectRequestScript.root(
		EffectKindScript.PERFORM_ATTACK,
		attacker_id, target_id, 0)
	var action_sink: Array = []
	var ctx = EffectContextScript.new(
		_world, _rng, _event_emitter, action_sink)
	var r = EffectExecutorScript.new().execute(ctx, req)
	events.append_array(action_sink)
	if r != null and r.dispatch_work != null and r.dispatch_work.size() > 0:
		for w in r.dispatch_work:
			p_work_sink.append(w)
	return events


## Backward-compat wrapper retained for any caller that
## still prefers the combined player+enemy function name.
## B6.1: delegates to the canonical _drive_team_action path
## twice (player then enemy). New code should call step_tick().
func _drive_basic_attacks() -> Array:
	var events: Array = []
	events.append_array(_drive_team_action(0))
	events.append_array(_drive_team_action(1))
	return events


func get_result() -> BattleResult:
	return _result


## TEST/DEBUG escape hatch — returns the mutable BattleWorld.
## Comment intentionally documents that this is not a readonly
## handle (GDScript cannot enforce readonly via return type).
func world() -> RefCounted:
	return _world


## TEST/DEBUG escape hatch — returns the mutable owned RNG.
func rng() -> RefCounted:
	return _rng


# === Progress signature ===

## Deterministic, ordered signature of alive (position, HP) state.
## Includes positions so movement counts as progress
## (BLOCKER 1D fix). String-based for stable comparison
## (Dictionary.hash() is randomized in Godot 4).
##
## B4: also includes active FINITE-status remaining for each
## alive entity. This means a Stun with remaining=2 then
## remaining=1 produces a different signature and the
## no-progress counter is reset on each transition. Indefinite
## statuses (remaining < 0) do NOT contribute, so a max-HP
## indefinite Regen still permits true stalemate.
##
## Order: per entity, by status insertion order. Per status:
## entity_id + status_id + remaining + stacks. Excludes
## statuses with remaining == 0 (already expired this tick).
func _progress_signature() -> String:
	var sig: String = ""
	for id in _world.alive_ids_by_team(0):
		var id_i: int = int(id)
		var p: Vector2i = _world.position_of(id_i)
		sig += "P%d:%d,%d:%d;" % [id_i, int(p.x), int(p.y), int(_world.current_hp_of(id_i))]
	for id in _world.alive_ids_by_team(1):
		var id_i: int = int(id)
		var p: Vector2i = _world.position_of(id_i)
		sig += "E%d:%d,%d:%d;" % [id_i, int(p.x), int(p.y), int(_world.current_hp_of(id_i))]
	# B4 active-status contribution (finite only).
	for id in _world.alive_ids_by_team(0):
		sig += _status_signature_segment(int(id))
	for id in _world.alive_ids_by_team(1):
		sig += _status_signature_segment(int(id))
	return sig


## Per-entity active-status contribution to progress signature.
## Only finite statuses (remaining > 0) are included.
func _status_signature_segment(entity_id: int) -> String:
	var container = _world.get_status_container(entity_id)
	if container == null:
		return ""
	var seg: String = ""
	for inst in container.all():
		var rem: int = int(inst.remaining)
		if rem <= 0:
			continue  # indefinite OR already-expired-this-tick
		seg += "S%d:%s:%d:%d;" % [
			entity_id, String(inst.status_id), rem, int(inst.stacks)]
	return seg


func _has_progressed(events: Array) -> bool:
	# Progress = at least one DAMAGE_APPLIED / UNIT_DIED /
	# UNIT_MOVED / STATUS_EXPIRED event OR alive state changed.
	# STATUS_TICKED by itself does NOT count (it's just
	# telemetry for a tick that may be no-op).
	# HEAL_APPLIED changes HP and is caught by the state
	# signature below.
	#
	# DAMAGE_APPLIED is progress IFF its amount is POSITIVE. A
	# fully mitigated damage (amount == 0) leaves the target's HP
	# untouched, so the world did not change: counting it as
	# progress made a battle in which every hit was mitigated look
	# like it was making progress forever, and the stalemate
	# termination was never reached.
	#
	# The event itself is NOT removed: DAMAGE_APPLIED(0) stays a
	# valid telemetry record of a successfully completed, fully
	# mitigated damage transaction.
	for e in events:
		var event_type: int = int(e.type)
		if event_type == BattleEventTypeScript.DAMAGE_APPLIED:
			if int(e.amount) > 0:
				return true
			continue
		if event_type == BattleEventTypeScript.UNIT_DIED \
				or event_type == BattleEventTypeScript.UNIT_MOVED \
				or event_type == BattleEventTypeScript.STATUS_EXPIRED:
			return true
	var current: String = _progress_signature()
	return current != _last_progress_sig


# === Internal helpers ===

## B6.1.1 movement-only helper. The in-range branch moved
## into _drive_team_action (which delegates to
## PerformAttackEffect via EffectExecutor). This function is
## now reached only with target_id outside attack range; it
## emits UNIT_MOVED or returns []. PERFORM_ATTACK is not
## involved (spec: "Movement is scheduler responsibility").
## B6.3: pre-move reaction window.
##
## Movement sequence:
##   1. validate mover + target alive
##   2. confirm target currently out of attack range
##   3. src = current position
##   4. dst = world.next_step_toward (PURE planner)
##   5. if dst == src: return []
##   6. emit ROOT UNIT_MOVE_STARTED
##   7. dispatch reactions to UNIT_MOVE_STARTED using the SAME
##      session / RNG / emitter / provider as the outer tick
##   8. revalidate mover
##   9. if mover dead or blocks_actions: CANCEL (no UNIT_MOVED)
##  10. world.try_commit_move(...)
##  11. if committed: emit UNIT_MOVED as CHILD of UNIT_MOVE_STARTED
##  12. return [start, ...child_unity, ...committed_moved]
##
## The outer step_tick then sees the returned events and may
## also dispatch reactions to them (e.g. children of
## UNIT_MOVE_STARTED). The same tick session ensures
## duplicate discovery is prevented by the seen-set.
func _resolve_or_move(attacker_id: int, target_id: int) -> Array:
	if not _world.is_alive(attacker_id) or not _world.is_alive(target_id):
		return []
	if _world.in_attack_range(attacker_id, target_id):
		return []
	var src: Vector2i = _world.position_of(attacker_id)
	var dst: Vector2i = _world.next_step_toward(attacker_id, target_id)
	if dst == src:
		return []
	var src_run: String = String(
		_world.source_run_unit_id_of(attacker_id))
	var tgt_run: String = String(
		_world.source_run_unit_id_of(target_id))
	# 6. Emit ROOT UNIT_MOVE_STARTED (parent=-1, depth=0,
	# fresh root_action_id from emitter).
	var move_started = _event_emitter.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		attacker_id,
		target_id,
		src_run,
		tgt_run,
		0,
		"",
		src,
		dst)
	if move_started == null:
		return []
	# Local sink for pre-move dispatch reactions. We keep
	# this separate from the outer tick's `events` sink so
	# outer redispatch sees the right parent events.
	var pre_move_sink: Array = []
	# 7. Dispatch reactions to UNIT_MOVE_STARTED using the SAME
	# tick session. This may commit AoO events into
	# pre_move_sink.
	_trigger_dispatcher.process(
		[move_started], _world, _rng, _event_emitter,
		pre_move_sink, _trigger_provider, null,
		_trigger_session)
	# Public action trace: pre-move dispatch events are part
	# of the public trace regardless of whether movement
	# cancels. An AoO that killed the mover MUST still appear
	# in the returned events.
	var out: Array = [move_started]
	for e in pre_move_sink:
		out.append(e)
	# 8-9. Revalidate mover after reaction dispatch.
	var cancelled: bool = false
	if not _world.is_alive(attacker_id):
		cancelled = true
	else:
		var stat_query_script = load(
			"res://core/battle_ecs/status/stat_query.gd")
		if stat_query_script != null \
				and bool(stat_query_script.blocks_actions(
					_world, attacker_id)):
			cancelled = true
	if cancelled:
		# Cancelled movement: UNIT_MOVE_STARTED + pre-move
		# reaction events are still part of the public trace;
		# only UNIT_MOVED is suppressed.
		return out
	# 10. Commit the planned move (validates expected_from).
	if not _world.try_commit_move(attacker_id, src, dst):
		# Destination became invalid between plan and commit
		# (shouldn't normally happen since nothing else moves
		# mid-tick, but be defensive).
		return out
	# 11. Emit UNIT_MOVED as CHILD of UNIT_MOVE_STARTED.
	var moved_event = _event_emitter.emit_child(
		BattleEventTypeScript.UNIT_MOVED,
		int(move_started.event_id),
		int(move_started.root_action_id),
		int(move_started.chain_depth),
		attacker_id,
		target_id,
		src_run,
		tgt_run,
		0,
		"",
		src,
		dst)
	if moved_event == null:
		return out
	# 12. Public events in emission order: start, pre-move
	# reaction children, moved.
	out.append(moved_event)
	return out


## B6.1.1: removed the retired _compute_damage and
## _resolve_attack stubs. There is exactly ONE attack
## mutation path: PerformAttackEffect via EffectExecutor.


## B2.0: BATTLE_ENDED is its own root event under the chosen
## "fresh root per simulation-lifecycle event" policy. It is
## NOT attached to the last attack/death action.
func _make_battle_ended_event() -> BattleEvent:
	var e = _event_emitter.emit(
		BattleEventTypeScript.BATTLE_ENDED,
		-1,
		-1,
		"",
		"",
		(_result.winner_team if _result != null else -1))
	return e


## BLOCKER 1 fix: forced termination (stalemate / tick budget)
## NEVER awards victory. Only natural one-side-empty may award
## victory; stalemate / budget always produce OUTCOME_DRAW with
## winner_team = -1.
func _build_result() -> BattleResult:
	var r: BattleResultScript = BattleResultScript.new()
	r.tick_count = _tick_count
	r.termination_reason = _termination_reason
	if _termination_reason == BattleResultScript.TERMINATION_NATURAL:
		r.winner_team = _natural_winner_team()
		match r.winner_team:
			0: r.outcome = BattleResultScript.OUTCOME_VICTORY
			1: r.outcome = BattleResultScript.OUTCOME_DEFEAT
			_: r.outcome = BattleResultScript.OUTCOME_DRAW
	else:
		r.winner_team = -1
		r.outcome = BattleResultScript.OUTCOME_DRAW
	r.surviving_player_ids = _world.alive_ids_by_team(0)
	r.surviving_enemy_ids = _world.alive_ids_by_team(1)
	r.source_run_unit_mapping = _world.source_run_unit_mapping()
	return r


func _natural_winner_team() -> int:
	var p_empty: bool = _world.alive_ids_by_team(0).is_empty()
	var e_empty: bool = _world.alive_ids_by_team(1).is_empty()
	if p_empty and e_empty:
		return -1
	if p_empty:
		return 1
	if e_empty:
		return 0
	return -1
