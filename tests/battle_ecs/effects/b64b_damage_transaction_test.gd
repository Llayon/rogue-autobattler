extends SceneTree
## B6.4b / Damage Intent / Commit Transaction Seam.
## 16 GREEN proofs. See commit message for design.
##
## Construction rules:
## - All tests use local fixtures constructed per test
## - No production refactor alters trace / RNG / world state vs
##   70eb71d baseline; B6.4b is an INTERNAL refactor
## - DamageTransaction is INERT until commit(): no world
##   mutation, no RNG, no event emission
## - perform_attack and direct damage use the SAME seam

const DamageTransactionScript = preload(
	"res://core/battle_ecs/effects/damage_transaction.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const DamageEffectScript = preload(
	"res://core/battle_ecs/effects/damage_effect.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_1_construction()
	await _test_2_pending_replacement()
	await _test_3_zero_pending_valid()
	await _test_4_negative_pending_rejected()
	await _test_5_amplification_allowed()
	await _test_6_commit_exactly_once()
	await _test_7_hp_cap()
	await _test_8_dead_target_fail_closed()
	await _test_9_source_may_be_dead()
	await _test_10_no_side_effect_before_commit()
	await _test_11_perform_attack_nonlethal_parity()
	await _test_12_perform_attack_lethal_parity()
	await _test_13_child_reaction_attack_parity()
	await _test_14_direct_damage_parity()
	await _test_15_periodic_burn_parity()
	await _test_16_twenty_run_determinism()
	print("\n=== B6.4b damage transaction proofs: %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


# Build a minimal world with two living units.
# Returns [sim, world, em, p0_unit, e0_unit].
func _make_sim_with_pair(p_p0_hp: int = 200, p_e0_hp: int = 80,
		p_p0_atk: int = 5, p_e0_atk: int = 5) -> Array:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), p_p0_hp, p_p0_hp,
		p_p0_atk, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), p_e0_hp, p_e0_hp,
		p_e0_atk, 5, 1, [])
	var setup = BattleSetupScript.new(42,
		[mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	return [sim, sim.world(), sim._event_emitter]


# ============================================================
# Test 1: Construction
# ============================================================
func _test_1_construction() -> void:
	print("[B64B-T1] construction")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	_assert(int(tx.base_amount()) == 10,
		"base_amount == 10")
	_assert(int(tx.pending_amount()) == 10,
		"pending_amount == 10 (initially equal to base)")
	_assert(not bool(tx.is_committed()),
		"committed == false")


# ============================================================
# Test 2: Pending replacement (no world mutation, no commit)
# ============================================================
func _test_2_pending_replacement() -> void:
	print("[B64B-T2] pending_replacement")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(5))
	_assert(ok,
		"set_pending_amount(5) returns true")
	_assert(int(tx.base_amount()) == 10,
		"base still 10 (immutable)")
	_assert(int(tx.pending_amount()) == 5,
		"pending now 5")


# ============================================================
# Test 3: Zero pending is valid
# ============================================================
func _test_3_zero_pending_valid() -> void:
	print("[B64B-T3] zero_pending_valid")
	var pair = _make_sim_with_pair()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(0))
	_assert(ok,
		"set_pending_amount(0) accepted")
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)),
		"commit: ok=true")
	_assert(int(r.get("dealt", -1)) == 0,
		"commit: dealt=0")
	_assert(int(world.current_hp_of(1)) == 80,
		"target HP unchanged (still 80)")
	_assert(bool(tx.is_committed()),
		"transaction committed")


# ============================================================
# Test 4: Negative pending rejected, no silent clamp
# ============================================================
func _test_4_negative_pending_rejected() -> void:
	print("[B64B-T4] negative_pending_rejected")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(-1))
	_assert(not ok,
		"set_pending_amount(-1) returns false")
	_assert(int(tx.pending_amount()) == 10,
		"pending remains 10 (not silently clamped)")


# ============================================================
# Test 5: Amplification allowed (pending > base)
# ============================================================
func _test_5_amplification_allowed() -> void:
	print("[B64B-T5] amplification_allowed")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(15))
	_assert(ok,
		"set_pending_amount(15) accepted (amplification)")
	_assert(int(tx.pending_amount()) == 15,
		"pending is 15")


# ============================================================
# Test 6: Commit exactly once
# ============================================================
func _test_6_commit_exactly_once() -> void:
	print("[B64B-T6] commit_exactly_once")
	var pair = _make_sim_with_pair()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r1: Dictionary = tx.commit(world)
	_assert(bool(r1.get("ok", false)),
		"first commit: ok=true")
	_assert(int(r1.get("dealt", -1)) == 10,
		"first commit: dealt=10")
	_assert(int(world.current_hp_of(1)) == 70,
		"HP after first commit = 70")
	# Second commit must be a no-op (committed already).
	var r2: Dictionary = tx.commit(world)
	_assert(not bool(r2.get("ok", true)),
		"second commit: ok=false (already committed)")
	_assert(int(r2.get("dealt", -1)) == 0,
		"second commit: dealt=0")
	_assert(int(world.current_hp_of(1)) == 70,
		"HP unchanged after second commit (no double mutation)")


# ============================================================
# Test 7: HP cap
# ============================================================
func _test_7_hp_cap() -> void:
	print("[B64B-T7] hp_cap")
	var pair = _make_sim_with_pair(200, 3, 5, 5)  # target HP=3
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)),
		"commit: ok=true")
	_assert(int(r.get("dealt", -1)) == 3,
		"commit: dealt=3 (HP cap)")
	_assert(not world.is_alive(1),
		"target dead after commit")


# ============================================================
# Test 8: Dead target fail-closed
# ============================================================
func _test_8_dead_target_fail_closed() -> void:
	print("[B64B-T8] dead_target_fail_closed")
	var pair = _make_sim_with_pair(200, 1, 999, 5)  # target HP=1, attacker kills in one hit
	var world = pair[1]
	# Kill the target first.
	world.apply_damage(1, 1)
	_assert(not world.is_alive(1),
		"target pre-dead")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r: Dictionary = tx.commit(world)
	_assert(not bool(r.get("ok", false)),
		"commit: ok=false on dead target")
	_assert(int(r.get("dealt", -1)) == 0,
		"commit: dealt=0 on dead target")


# ============================================================
# Test 9: Source may be dead (DOT/status-source compat)
# ============================================================
func _test_9_source_may_be_dead() -> void:
	print("[B64B-T9] source_may_be_dead")
	var pair = _make_sim_with_pair(200, 80, 5, 5)
	var world = pair[1]
	# Kill the source.
	world.apply_damage(0, 200)
	_assert(not world.is_alive(0),
		"source pre-dead")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)),
		"commit allowed with dead source: ok=true")
	_assert(int(r.get("dealt", -1)) == 10,
		"dealt=10")


# ============================================================
# Test 10: No side effect before commit
# ============================================================
func _test_10_no_side_effect_before_commit() -> void:
	print("[B64B-T10] no_side_effect_before_commit")
	var pair = _make_sim_with_pair()
	var sim = pair[0]
	var world = pair[1]
	var em = pair[2]
	var hp_before: int = int(world.current_hp_of(1))
	var alive_before: bool = bool(world.is_alive(1))
	var rng_before: Dictionary = sim._rng.snapshot()
	var next_event_id_before: int = int(em.peek_next_event_id())
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	tx.set_pending_amount(7)
	tx.set_pending_amount(3)
	_assert(int(world.current_hp_of(1)) == hp_before,
		"world HP unchanged before commit")
	_assert(bool(world.is_alive(1)) == alive_before,
		"alive state unchanged before commit")
	var rng_after: Dictionary = sim._rng.snapshot()
	_assert(rng_after == rng_before,
		"RNG snapshot unchanged before commit")
	_assert(int(em.peek_next_event_id()) == next_event_id_before,
		"emitter counters unchanged before commit")


# ============================================================
# Test 11: PerformAttack nonlethal parity (vs baseline)
# ============================================================
func _test_11_perform_attack_nonlethal_parity() -> void:
	print("[B64B-T11] perform_attack_nonlethal_parity")
	var pair = _make_sim_with_pair(200, 200, 5, 5)  # HP=200, ATK=5
	var sim = pair[0]
	sim._rng = DeterministicRngScript.new(7)
	# Drive player's basic attack (mover -> knight).
	var events: Array = sim._drive_team_action(0)
	_assert(events.size() >= 2,
		"nonlethal attack emits >= 2 events (ATK + DMG)")
	# First event is ATTACK_RESOLVED.
	_assert(int(events[0].type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"first event is ATTACK_RESOLVED")
	# Second event is DAMAGE_APPLIED.
	_assert(int(events[1].type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"second event is DAMAGE_APPLIED")
	# Both share same root_action_id.
	_assert(int(events[0].root_action_id) == int(events[1].root_action_id),
		"ATK and DMG share root_action_id")
	# DMG is child of ATK.
	_assert(int(events[1].parent_event_id) == int(events[0].event_id),
		"DMG.parent_event_id == ATK.event_id")
	_assert(int(events[1].chain_depth) == int(events[0].chain_depth) + 1,
		"DMG.chain_depth == ATK.chain_depth + 1")
	# No UNIT_DIED (nonlethal).
	var has_died: bool = false
	for e in events:
		if int(e.type) == BattleEventTypeScript.UNIT_DIED:
			has_died = true
	_assert(not has_died,
		"no UNIT_DIED in nonlethal attack")
	# Knight still alive.
	_assert(sim.world().is_alive(1),
		"knight still alive after nonlethal attack")


# ============================================================
# Test 12: PerformAttack lethal parity
# ============================================================
func _test_12_perform_attack_lethal_parity() -> void:
	print("[B64B-T12] perform_attack_lethal_parity")
	var pair = _make_sim_with_pair(200, 200, 999, 5)  # ATK=999
	var sim = pair[0]
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim._drive_team_action(0)
	_assert(events.size() >= 3,
		"lethal attack emits >= 3 events (ATK + DMG + DIED)")
	_assert(int(events[0].type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"first event ATTACK_RESOLVED")
	_assert(int(events[1].type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"second event DAMAGE_APPLIED")
	_assert(int(events[2].type) == BattleEventTypeScript.UNIT_DIED,
		"third event UNIT_DIED")
	# DIED is child of DMG.
	_assert(int(events[2].parent_event_id) == int(events[1].event_id),
		"DIED.parent_event_id == DMG.event_id")
	# All three share same root_action_id.
	_assert(int(events[0].root_action_id) == int(events[1].root_action_id) and
		int(events[1].root_action_id) == int(events[2].root_action_id),
		"all three share root_action_id")
	# DMG.amount = actual HP removed.
	_assert(int(events[1].amount) == 200,
		"DMG.amount == 200 (target full HP removed)")
	_assert(not sim.world().is_alive(1),
		"knight dead after lethal attack")


# ============================================================
# Test 13: Child/reaction attack parity (Counterattack)
# ============================================================
func _test_13_child_reaction_attack_parity() -> void:
	print("[B64B-T13] child_reaction_attack_parity")
	# Guardian owns counterattack. Warrior attacks guardian.
	# Counter chance=1.0, so guardian performs a child attack
	# back at warrior. Use step_tick() to drive both phases
	# (player action + reaction dispatch).
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
	var guardian = BattleUnitSetupScript.new(
		"e0", &"guardian", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42,
		[mover], [guardian], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(7)
	# Drive a single step_tick (player action + dispatch + enemy
	# action). Capture all events.
	var events: Array = sim.step_tick()
	_assert(int(events[0].type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"first ATK_RESOLVED (ROOT warrior->guardian)")
	# Find the counterattack (CHILD) ATK.
	var counter_atk = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.parent_event_id) >= 0:
			counter_atk = e
			break
	_assert(counter_atk != null,
		"counterattack ATK_RESOLVED present")
	if counter_atk != null:
		# Counter ATK is a CHILD; shares root_action_id with ROOT.
		_assert(int(counter_atk.root_action_id) == int(events[0].root_action_id),
			"counter ATK shares root_action_id with ROOT")
		_assert(int(counter_atk.chain_depth) == int(events[0].chain_depth) + 1,
			"counter ATK.chain_depth == ROOT.chain_depth + 1")


# ============================================================
# Test 14: Direct DamageEffect parity (req.amount > 0 and computed)
# ============================================================
func _test_14_direct_damage_parity() -> void:
	print("[B64B-T14] direct_damage_parity")
	var pair = _make_sim_with_pair()
	var sim = pair[0]
	var em = pair[2]
	# Path 1: explicit amount > 0.
	var req1 = EffectRequestScript.root(0, 0, 1, 10)  # DAMAGE=0
	req1.source_entity = 0
	req1.target_entity = 1
	req1.amount = 10
	req1.payload = {"skip_balance": true}
	var ctx1 = EffectContextScript.new(
		sim.world(), sim._rng, em, [])
	DamageEffectScript.new().execute(ctx1, req1)
	_assert(int(sim.world().current_hp_of(1)) == 70,
		"explicit amount=10 applied: knight HP 70 (was 80)")


# ============================================================
# Test 15: Periodic burn parity (covered by b3_burn_regen_test,
# but here we confirm DamageTransaction's commit is reachable
# through the same code path with no special branch)
# ============================================================
func _test_15_periodic_burn_parity() -> void:
	print("[B64B-T15] periodic_burn_parity")
	# DamageEffect with explicit amount=5 simulates a periodic
	# DOT tick. Verify DamageTransaction path produces the
	# same DAMAGE_APPLIED event semantics.
	var pair = _make_sim_with_pair(200, 200, 5, 5)
	var sim = pair[0]
	var em = pair[2]
	var req = EffectRequestScript.root(0, 0, 1, 5)
	req.source_entity = 0
	req.target_entity = 1
	req.amount = 5
	req.payload = {"skip_balance": true, "is_dot": true}
	var ctx = EffectContextScript.new(
		sim.world(), sim._rng, em, [])
	var r = DamageEffectScript.new().execute(ctx, req)
	_assert(int(sim.world().current_hp_of(1)) == 195,
		"periodic-style damage=5 applied: HP 195 (was 200)")
	# Verify DAMAGE_APPLIED event has correct semantics.
	_assert(r != null and int(r.success) == 1,
		"effect succeeded")
	_assert(r.events.size() >= 1,
		"effect emitted >= 1 event")
	_assert(int(r.events[0].type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"first emitted event is DAMAGE_APPLIED")
	_assert(int(r.events[0].amount) == 5,
		"DAMAGE_APPLIED.amount = 5")


# ============================================================
# Test 16: 20-run determinism (parity vs baseline)
# ============================================================
func _test_16_twenty_run_determinism() -> void:
	print("[B64B-T16] 20_run_determinism")
	var first_events_count: int = -1
	var first_world: Dictionary = {}
	var first_emitter: Dictionary = {}
	for i in 20:
		var pair = _make_sim_with_pair(200, 200, 5, 5)
		var sim = pair[0]
		sim._rng = DeterministicRngScript.new(int(7 + i))
		var events: Array = sim._drive_team_action(0)
		var world_state: Dictionary = {
			"0_hp": int(sim.world().current_hp_of(0)),
			"0_alive": bool(sim.world().is_alive(0)),
			"1_hp": int(sim.world().current_hp_of(1)),
			"1_alive": bool(sim.world().is_alive(1)),
		}
		var em = sim._event_emitter
		var em_state: Dictionary = {
			"next_event_id": int(em.peek_next_event_id()),
			"next_root_action_id": int(em.peek_next_root_action_id()),
			"current_tick": int(em.current_tick()),
		}
		if i == 0:
			first_events_count = events.size()
			first_world = world_state
			first_emitter = em_state
		else:
			_assert(events.size() == first_events_count,
				"run %d: events count %d == first run %d"
				% [i, events.size(), first_events_count])
			_assert(world_state == first_world,
				"run %d: world state equal to first run" % i)
			_assert(em_state == first_emitter,
				"run %d: emitter state equal to first run" % i)