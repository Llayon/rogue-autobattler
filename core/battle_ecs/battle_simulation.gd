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
const BalanceScript = preload("res://core/balance.gd")

const _MAX_NO_PROGRESS_TICKS: int = 2

var _rng: RefCounted = null
var _world: RefCounted = null
var _setup: RefCounted = null
var _tick_count: int = 0
var _finished: bool = false
var _result: RefCounted = null
var _next_event_id: int = 0
var _max_ticks: int = 0
var _no_progress_count: int = 0
var _last_progress_sig: String = ""
var _valid: bool = false
var _termination_reason: int = BattleResultScript.TERMINATION_NATURAL


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
	_next_event_id = 0
	_no_progress_count = 0
	_last_progress_sig = ""
	_termination_reason = BattleResultScript.TERMINATION_NATURAL
	_max_ticks = 0  # reset caller-overridden tick budget
	# HIGH 6 fix: snapshot the setup so caller mutation of the
	# original BattleSetup after initialize() cannot retroactively
	# alter an in-progress battle. BattleSetup constructor already
	# deep-copies unit arrays, so reassigning the reference is
	# sufficient for this slice.
	_setup = setup
	# BLOCKER 5: validate setup before spawning. If validate
	# returns non-empty, reject and leave _valid=false.
	var err: String = setup.validate()
	if err != "":
		_world = null
		_rng = null
		_setup = null
		return false
	_rng = DeterministicRngScript.new(0)
	_rng.seed_with(int(setup.seed))
	_world = BattleWorldScript.new(int(setup.grid_width), int(setup.grid_height))
	# Spawn first, THEN capture the initial progress signature
	# (BLOCKER 9 fix).
	_world.spawn_from_setup(setup)
	_last_progress_sig = _progress_signature()
	_valid = true
	return true


## Set a hard tick ceiling. After this many ticks step_tick
## force-finishes the simulation with OUTCOME_DRAW and
## termination_reason = TICK_BUDGET.
func set_max_ticks(p_max_ticks: int) -> void:
	_max_ticks = maxi(0, int(p_max_ticks))


## Loop step_tick until finished or until max_ticks reached.
## Returns all collected events in emission order.
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
func step_tick() -> Array:
	if not _valid:
		return []
	if _finished:
		return []
	_tick_count += 1
	var events: Array = []
	events.append_array(_drive_basic_attacks())
	var natural: bool = _world.one_side_empty()
	var budget: bool = _max_ticks > 0 and _tick_count >= _max_ticks
	var progressed: bool = _has_progressed(events)
	# Stalemate detection: 2 consecutive ticks with no progress
	# AND no natural termination -> force-finish as DRAW.
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
	return sig


func _has_progressed(events: Array) -> bool:
	# Progress = at least one DAMAGE_APPLIED / UNIT_DIED /
	# UNIT_MOVED event OR alive state changed.
	for e in events:
		if e.type == 3 or e.type == 1 or e.type == 5:
			return true
	var current: String = _progress_signature()
	return current != _last_progress_sig


# === Internal helpers ===

func _drive_basic_attacks() -> Array:
	# Vertical-slice scheduler: one acting entity per side per
	# tick (lowest-ID living, deterministic). Per BLOCKER 1:
	# if out of range, move one cell toward target.
	var events: Array = []
	var player_ids: Array = _world.alive_ids_by_team(0)
	var enemy_ids: Array = _world.alive_ids_by_team(1)
	if player_ids.is_empty() or enemy_ids.is_empty():
		return events
	var attacker_id: int = int(player_ids[0])
	var target_id: int = _world.nearest_enemy_id(attacker_id, enemy_ids)
	if target_id >= 0:
		events.append_array(_resolve_or_move(attacker_id, target_id))
	enemy_ids = _world.alive_ids_by_team(1)
	player_ids = _world.alive_ids_by_team(0)
	if enemy_ids.is_empty() or player_ids.is_empty():
		return events
	var e_attacker: int = int(enemy_ids[0])
	var e_target: int = _world.nearest_enemy_id(e_attacker, player_ids)
	if e_target >= 0:
		events.append_array(_resolve_or_move(e_attacker, e_target))
	return events


## If attacker is in attack range of target, attack; otherwise
## move one cell toward target and emit UNIT_MOVED. Returns all
## events emitted.
func _resolve_or_move(attacker_id: int, target_id: int) -> Array:
	if not _world.is_alive(attacker_id) or not _world.is_alive(target_id):
		return []
	if _world.in_attack_range(attacker_id, target_id):
		return _resolve_attack(attacker_id, target_id)
	# Out of range — try to move one cell toward target.
	var src: Vector2i = _world.position_of(attacker_id)
	var dst: Vector2i = _world.try_move_toward(attacker_id, target_id)
	if dst == src:
		# No movement possible (target cell occupied or OOB).
		# Emit no event — caller will detect no-progress and
		# eventually force-finish.
		return []
	# Emit UNIT_MOVED with from_cell/to_cell.
	_next_event_id += 1
	var moved_event: BattleEventScript = BattleEventScript.new()
	moved_event.event_id = _next_event_id
	moved_event.type = BattleEventTypeScript.UNIT_MOVED
	moved_event.tick = _tick_count
	moved_event.source_entity = attacker_id
	moved_event.target_entity = target_id
	moved_event.source_run_unit_id = _world.source_run_unit_id_of(attacker_id)
	moved_event.target_run_unit_id = _world.source_run_unit_id_of(target_id)
	moved_event.from_cell = src
	moved_event.to_cell = dst
	return [moved_event]


## BLOCKER 2 fix: damage formula uses the established pure-defense
## scaling from Balance.compute_damage. No crit / dodge / variance
## / statuses / effects for this slice. Variance + crit + dodge
## are explicitly deferred (NORMATIVE FEATURE DEFER).
func _compute_damage(attacker_id: int, target_id: int) -> int:
	var atk: int = _world.attack_of(attacker_id)
	var dfs: int = _world.defense_of(target_id)
	if atk <= 0:
		return 1
	var eff_def: int = dfs  # is_magic=false in this slice
	return BalanceScript.compute_damage(atk, eff_def, false, 0.0, 1.0)


func _resolve_attack(attacker_id: int, target_id: int) -> Array:
	var events: Array = []
	if not _world.is_alive(attacker_id) or not _world.is_alive(target_id):
		return events
	if not _world.in_attack_range(attacker_id, target_id):
		return events
	var dmg: int = _compute_damage(attacker_id, target_id)
	_next_event_id += 1
	var attack_event: BattleEventScript = BattleEventScript.new()
	attack_event.event_id = _next_event_id
	attack_event.type = BattleEventTypeScript.ATTACK_RESOLVED
	attack_event.tick = _tick_count
	attack_event.source_entity = attacker_id
	attack_event.target_entity = target_id
	attack_event.source_run_unit_id = _world.source_run_unit_id_of(attacker_id)
	attack_event.target_run_unit_id = _world.source_run_unit_id_of(target_id)
	attack_event.amount = dmg
	events.append(attack_event)
	var dealt: int = _world.apply_damage(target_id, dmg)
	_next_event_id += 1
	var dmg_event: BattleEventScript = BattleEventScript.new()
	dmg_event.event_id = _next_event_id
	dmg_event.type = BattleEventTypeScript.DAMAGE_APPLIED
	dmg_event.tick = _tick_count
	dmg_event.source_entity = attacker_id
	dmg_event.target_entity = target_id
	dmg_event.source_run_unit_id = _world.source_run_unit_id_of(attacker_id)
	dmg_event.target_run_unit_id = _world.source_run_unit_id_of(target_id)
	dmg_event.amount = dealt
	events.append(dmg_event)
	if not _world.is_alive(target_id):
		_next_event_id += 1
		var died_event: BattleEventScript = BattleEventScript.new()
		died_event.event_id = _next_event_id
		died_event.type = BattleEventTypeScript.UNIT_DIED
		died_event.tick = _tick_count
		died_event.source_entity = attacker_id
		died_event.target_entity = target_id
		died_event.source_run_unit_id = _world.source_run_unit_id_of(attacker_id)
		died_event.target_run_unit_id = _world.source_run_unit_id_of(target_id)
		died_event.amount = dealt
		events.append(died_event)
	return events


func _make_battle_ended_event() -> BattleEvent:
	_next_event_id += 1
	var e: BattleEventScript = BattleEventScript.new()
	e.event_id = _next_event_id
	e.type = BattleEventTypeScript.BATTLE_ENDED
	e.tick = _tick_count
	e.amount = _result.winner_team if _result != null else -1
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
