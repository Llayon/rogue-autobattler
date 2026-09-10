class_name BattleSimulation extends RefCounted
## Phase 2 / BattleSimulation — minimal headless simulation
## controller.
##
## Contract (this slice):
##   - initialize(setup: BattleSetup): owns a DeterministicRng
##     seeded with setup.seed; creates a BattleWorld; spawns one
##     entity per BattleUnitSetup, allocating numeric entity IDs.
##   - step_tick() -> Array[BattleEvent]: advances the simulation
##     by one tick; returns the events emitted during that tick
##     (may be empty).
##   - is_finished() -> bool: true when one side is fully dead.
##   - get_result() -> BattleResult: only valid after is_finished;
##     immutable result.
##   - world() -> BattleWorld: read-only handle to internal state
##     for tests/debug.
##
## Hard rules:
##   - NO Node/Control/Sprite/Tween/AnimationPlayer inside.
##   - NO global Rng, NO RandomNumberGenerator.new(), NO
##     @GlobalScope rand*, NO randomize(). The owned
##     DeterministicRng is the sole randomness source.
##
## Two simultaneous BattleSimulation instances must not influence
## each other's RNG.

const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")

var _rng: RefCounted = null           # DeterministicRng
var _world: RefCounted = null         # BattleWorld
var _setup: RefCounted = null         # BattleSetup
var _tick_count: int = 0
var _finished: bool = false
var _result: RefCounted = null        # BattleResult
var _next_event_id: int = 0


func initialize(setup: BattleSetup) -> void:
	_rng = DeterministicRngScript.new(0)
	_rng.seed_with(int(setup.seed))
	_setup = setup
	_world = BattleWorldScript.new(int(setup.grid_width), int(setup.grid_height))
	_tick_count = 0
	_finished = false
	_result = null
	_next_event_id = 0
	# Spawn entities (placeholder for Gauntlet 2/3; here we just
	# record the seed and defer real spawning to Gauntlet 5 slice).
	_world.spawn_from_setup(setup)


## Returns events emitted during this tick (may be empty Array).
## After is_finished() returns true, step_tick is a no-op and
## returns [].
func step_tick() -> Array:
	if _finished:
		return []
	_tick_count += 1
	var events: Array = []
	# Drive basic attack scheduling. Gauntlet 5 expands this.
	events.append_array(_drive_basic_attacks())
	# Check termination.
	if _world.one_side_empty():
		_finished = true
		_result = _build_result()
		events.append(_make_battle_ended_event())
	return events


func is_finished() -> bool:
	return _finished


func get_result() -> BattleResult:
	return _result


func world() -> RefCounted:
	return _world


func rng() -> RefCounted:
	return _rng


# === Internal helpers ===

func _drive_basic_attacks() -> Array:
	# Single-attack-per-tick for the lowest-id living entity on
	# each side (deterministic ordering). Picks the closest living
	# enemy by Manhattan distance. Applies damage equal to
	# max(1, attack_base - defense_base/2).
	var events: Array = []
	var player_ids: Array = _world.alive_ids_by_team(0)
	var enemy_ids: Array = _world.alive_ids_by_team(1)
	if player_ids.is_empty() or enemy_ids.is_empty():
		return events
	# Player -> Enemy
	var attacker_id: int = int(player_ids[0])
	var target_id: int = _world.nearest_enemy_id(attacker_id, enemy_ids)
	if target_id >= 0:
		events.append_array(_resolve_attack(attacker_id, target_id))
	# Enemy -> Player (if still alive)
	if not _world.is_alive(target_id):
		# If the player killed the target on this tick, enemies
		# still get their counterattack.
		pass
	enemy_ids = _world.alive_ids_by_team(1)
	player_ids = _world.alive_ids_by_team(0)
	if enemy_ids.is_empty() or player_ids.is_empty():
		return events
	var e_attacker: int = int(enemy_ids[0])
	var e_target: int = _world.nearest_enemy_id(e_attacker, player_ids)
	if e_target >= 0:
		events.append_array(_resolve_attack(e_attacker, e_target))
	return events


func _resolve_attack(attacker_id: int, target_id: int) -> Array:
	var events: Array = []
	var atk_pos: Vector2i = _world.position_of(attacker_id)
	var tgt_pos: Vector2i = _world.position_of(target_id)
	if not _world.in_attack_range(attacker_id, target_id):
		# Out of range: skip attack (no events emitted).
		return events
	var atk: int = _world.attack_of(attacker_id)
	var dfs: int = _world.defense_of(target_id)
	var dmg: int = maxi(1, atk - int(dfs / 2))
	# Emit attack_resolved event.
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
	# Apply damage.
	var dealt: int = _world.apply_damage(target_id, dmg)
	# Emit damage_applied event.
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
	# Emit unit_died if target died.
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


func _build_result() -> BattleResult:
	var r: BattleResultScript = BattleResultScript.new()
	r.tick_count = _tick_count
	r.winner_team = _result_winner_team()
	if r.winner_team == 0:
		r.outcome = BattleResultScript.OUTCOME_VICTORY
	elif r.winner_team == 1:
		r.outcome = BattleResultScript.OUTCOME_DEFEAT
	else:
		r.outcome = BattleResultScript.OUTCOME_DRAW
	r.surviving_player_ids = _world.alive_ids_by_team(0)
	r.surviving_enemy_ids = _world.alive_ids_by_team(1)
	r.source_run_unit_mapping = _world.source_run_unit_mapping()
	return r


func _result_winner_team() -> int:
	# Caller already verified one side is empty.
	var p_empty: bool = _world.alive_ids_by_team(0).is_empty()
	var e_empty: bool = _world.alive_ids_by_team(1).is_empty()
	if p_empty and e_empty:
		return -1
	if p_empty:
		return 1
	return 0
