extends SceneTree
## B6.4b.1 / Damage Transaction Hardening + Final Proof Closure.
## 22 GREEN proofs covering:
##   Lifecycle (UNINITIALIZED -> PENDING -> COMMITTED):
##     1.  construction
##     2.  negative-base setup rejected (no silent clamp)
##     3.  setup twice before commit rejected
##     4.  setup after commit rejected
##     5.  commit before setup rejected
##     6.  set_pending after commit rejected
##     7.  set_pending before setup rejected
##     8.  set_pending negative rejected
##     9.  zero pending valid commit (preserves target HP)
##    10.  commit exactly once
##    11.  HP cap
##    12.  dead target fail-closed (state remains PENDING)
##    13.  source may be dead
##   Behavior contracts:
##    14.  amplification allowed
##    15.  no side effect before commit
##   Production parity (vs 8b3f777 baseline):
##    16.  perform_attack nonlethal parity
##    17.  perform_attack lethal parity
##    18.  child reaction counterattack ancestry proof
##    19.  direct damage parity
##    20.  real periodic burn via PeriodicStatusProcessor
##   Determinism:
##    21.  same-seed 20-run determinism (full 14-field event
##         trace + world + RNG + emitter equality)
##   Failure-path publication:
##    22.  DamageEffect fail-closed: no event published, no
##         UNIT_DIED fabricated, no HP mutation on commit fail.

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
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _t1_construction()
	await _t2_setup_rejects_negative_base()
	await _t3_setup_twice_rejected()
	await _t4_setup_after_commit_rejected()
	await _t5_commit_before_setup_rejected()
	await _t6_set_pending_after_commit_rejected()
	await _t7_set_pending_before_setup_rejected()
	await _t8_set_pending_negative_rejected()
	await _t9_zero_pending_valid_commit()
	await _t10_commit_exactly_once()
	await _t11_hp_cap()
	await _t12_dead_target_fail_closed()
	await _t13_source_may_be_dead()
	await _t14_amplification_allowed()
	await _t15_no_side_effect_before_commit()
	await _t16_perform_attack_nonlethal_parity()
	await _t17_perform_attack_lethal_parity()
	await _t18_counterattack_ancestry_proof()
	await _t19_direct_damage_parity()
	await _t20_real_periodic_burn()
	await _t21_same_seed_20_run_determinism()
	await _t22_damage_effect_fail_closed_no_phantom_event()
	print("\n=== B6.4b.1 damage transaction proofs: %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


# Helper: build a sim with a 2-unit pair.
# Returns [sim, world, em].
func _make_pair_sim(p_p0_hp: int = 200, p_e0_hp: int = 80,
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
# T1: Construction
# ============================================================
func _t1_construction() -> void:
	print("[B64B1-T1] construction")
	var tx = DamageTransactionScript.new()
	_assert(int(tx.base_amount()) == 0,
		"base_amount == 0 (uninitialized)")
	_assert(int(tx.pending_amount()) == 0,
		"pending_amount == 0 (uninitialized)")
	_assert(not bool(tx.is_committed()),
		"is_committed == false (uninitialized)")


# ============================================================
# T2: setup(negative) rejects, no silent clamp
# ============================================================
func _t2_setup_rejects_negative_base() -> void:
	print("[B64B1-T2] setup_rejects_negative_base")
	var tx = DamageTransactionScript.new()
	var ok: bool = bool(tx.setup(0, 1, -1))
	_assert(not ok,
		"setup(0, 1, -1) returns false")
	_assert(int(tx.base_amount()) == 0,
		"base still 0 (no silent clamp)")
	_assert(int(tx.pending_amount()) == 0,
		"pending still 0")
	_assert(not bool(tx.is_committed()),
		"not committed")
	# Subsequent valid setup must succeed.
	var ok2: bool = bool(tx.setup(0, 1, 10))
	_assert(ok2,
		"valid setup(0, 1, 10) after rejected setup succeeds")
	_assert(int(tx.base_amount()) == 10,
		"base now 10")
	_assert(int(tx.pending_amount()) == 10,
		"pending now 10")


# ============================================================
# T3: setup twice before commit rejected
# ============================================================
func _t3_setup_twice_rejected() -> void:
	print("[B64B1-T3] setup_twice_rejected")
	var tx = DamageTransactionScript.new()
	var ok1: bool = bool(tx.setup(0, 1, 10))
	_assert(ok1, "first setup ok")
	var ok2: bool = bool(tx.setup(2, 3, 999))
	_assert(not ok2, "second setup rejected")
	# Original state preserved.
	_assert(int(tx.base_amount()) == 10, "base still 10")
	_assert(int(tx.pending_amount()) == 10, "pending still 10")


# ============================================================
# T4: setup after commit rejected
# ============================================================
func _t4_setup_after_commit_rejected() -> void:
	print("[B64B1-T4] setup_after_commit_rejected")
	var pair = _make_pair_sim()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	var ok1: bool = bool(tx.setup(0, 1, 10))
	_assert(ok1, "first setup ok")
	var r1: Dictionary = tx.commit(world)
	_assert(bool(r1.get("ok", false)), "first commit ok")
	_assert(bool(tx.is_committed()), "tx committed")
	_assert(int(world.current_hp_of(1)) == 70, "target HP = 70")
	# Second setup rejected.
	var ok2: bool = bool(tx.setup(0, 1, 50))
	_assert(not ok2, "second setup rejected")
	# Second commit rejected.
	var r2: Dictionary = tx.commit(world)
	_assert(not bool(r2.get("ok", true)),
		"second commit rejected (already_committed)")
	_assert(String(r2.get("reason", "")) == "already_committed",
		"reason == already_committed")
	_assert(int(world.current_hp_of(1)) == 70,
		"HP unchanged (no second mutation)")


# ============================================================
# T5: commit before setup rejected
# ============================================================
func _t5_commit_before_setup_rejected() -> void:
	print("[B64B1-T5] commit_before_setup_rejected")
	var pair = _make_pair_sim()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	var r: Dictionary = tx.commit(world)
	_assert(not bool(r.get("ok", true)), "commit before setup: ok=false")
	_assert(String(r.get("reason", "")) == "not_initialized",
		"reason == not_initialized")
	_assert(int(r.get("dealt", -1)) == 0, "dealt=0")
	_assert(int(world.current_hp_of(1)) == 80, "HP unchanged")
	_assert(not bool(tx.is_committed()), "not committed")
	_assert(int(tx.base_amount()) == 0, "base still 0")
	_assert(int(tx.pending_amount()) == 0, "pending still 0")


# ============================================================
# T6: set_pending_amount after commit rejected
# ============================================================
func _t6_set_pending_after_commit_rejected() -> void:
	print("[B64B1-T6] set_pending_after_commit_rejected")
	var pair = _make_pair_sim()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(7))
	_assert(ok, "set_pending(7) before commit ok")
	tx.commit(world)
	var ok2: bool = bool(tx.set_pending_amount(999))
	_assert(not ok2, "set_pending(999) after commit rejected")
	# Pending must remain at the value set before commit.
	_assert(int(tx.pending_amount()) == 7, "pending still 7")
	# HP unchanged from the first commit only (pending was 7).
	_assert(int(world.current_hp_of(1)) == 73,
		"HP = 73 (single commit with pending=7 only)")


# ============================================================
# T7: set_pending_amount before setup rejected
# ============================================================
func _t7_set_pending_before_setup_rejected() -> void:
	print("[B64B1-T7] set_pending_before_setup_rejected")
	var tx = DamageTransactionScript.new()
	var ok: bool = bool(tx.set_pending_amount(5))
	_assert(not ok, "set_pending(5) before setup rejected")
	_assert(int(tx.pending_amount()) == 0, "pending still 0")


# ============================================================
# T8: set_pending negative rejected
# ============================================================
func _t8_set_pending_negative_rejected() -> void:
	print("[B64B1-T8] set_pending_negative_rejected")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(-5))
	_assert(not ok, "set_pending(-5) rejected")
	_assert(int(tx.pending_amount()) == 10, "pending still 10")


# ============================================================
# T9: zero pending valid commit
# ============================================================
func _t9_zero_pending_valid_commit() -> void:
	print("[B64B1-T9] zero_pending_valid_commit")
	var pair = _make_pair_sim()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(0))
	_assert(ok, "set_pending(0) accepted")
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)), "commit ok=true")
	_assert(int(r.get("dealt", -1)) == 0, "dealt=0")
	_assert(bool(tx.is_committed()), "tx committed")
	_assert(int(world.current_hp_of(1)) == 80, "HP unchanged (target was 80)")


# ============================================================
# T10: commit exactly once
# ============================================================
func _t10_commit_exactly_once() -> void:
	print("[B64B1-T10] commit_exactly_once")
	var pair = _make_pair_sim()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r1: Dictionary = tx.commit(world)
	_assert(bool(r1.get("ok", false)), "first commit ok")
	_assert(int(r1.get("dealt", -1)) == 10, "first dealt=10")
	_assert(int(world.current_hp_of(1)) == 70, "HP=70")
	var r2: Dictionary = tx.commit(world)
	_assert(not bool(r2.get("ok", true)), "second commit ok=false")
	_assert(int(r2.get("dealt", -1)) == 0, "second dealt=0")
	_assert(int(world.current_hp_of(1)) == 70, "HP still 70 (no double mutation)")


# ============================================================
# T11: HP cap
# ============================================================
func _t11_hp_cap() -> void:
	print("[B64B1-T11] hp_cap")
	var pair = _make_pair_sim(200, 3, 5, 5)
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)), "commit ok")
	_assert(int(r.get("dealt", -1)) == 3, "dealt=3 (HP cap)")
	_assert(not world.is_alive(1), "target dead")


# ============================================================
# T12: dead target fail-closed, state remains PENDING
# ============================================================
func _t12_dead_target_fail_closed() -> void:
	print("[B64B1-T12] dead_target_fail_closed")
	var pair = _make_pair_sim(200, 1, 999, 5)
	var world = pair[1]
	world.apply_damage(1, 1)
	_assert(not world.is_alive(1), "target pre-dead")
	var tx = DamageTransactionScript.new()
	var ok: bool = bool(tx.setup(0, 1, 10))
	_assert(ok, "setup ok (target liveness is commit-time)")
	var r: Dictionary = tx.commit(world)
	_assert(not bool(r.get("ok", false)), "commit ok=false on dead target")
	_assert(String(r.get("reason", "")) == "target_dead",
		"reason == target_dead")
	_assert(int(r.get("dealt", -1)) == 0, "dealt=0")
	# State must remain PENDING (not COMMITTED).
	_assert(not bool(tx.is_committed()),
		"tx not committed after dead-target fail")
	# Pending can still be mutated.
	var ok2: bool = bool(tx.set_pending_amount(5))
	_assert(ok2, "set_pending(5) still works (PENDING state preserved)")
	_assert(int(tx.pending_amount()) == 5, "pending now 5")


# ============================================================
# T13: source may be dead (DOT compat)
# ============================================================
func _t13_source_may_be_dead() -> void:
	print("[B64B1-T13] source_may_be_dead")
	var pair = _make_pair_sim()
	var world = pair[1]
	world.apply_damage(0, 200)
	_assert(not world.is_alive(0), "source pre-dead")
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)), "commit ok with dead source")
	_assert(int(r.get("dealt", -1)) == 10, "dealt=10")
	_assert(bool(tx.is_committed()), "tx committed")


# ============================================================
# T14: amplification allowed
# ============================================================
func _t14_amplification_allowed() -> void:
	print("[B64B1-T14] amplification_allowed")
	var pair = _make_pair_sim()
	var world = pair[1]
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	var ok: bool = bool(tx.set_pending_amount(50))
	_assert(ok, "set_pending(50) > base(10) accepted")
	_assert(int(tx.pending_amount()) == 50, "pending now 50")
	var r: Dictionary = tx.commit(world)
	_assert(bool(r.get("ok", false)), "commit ok")
	_assert(int(r.get("dealt", -1)) == 50, "dealt=50 (amplified)")
	_assert(int(world.current_hp_of(1)) == 30, "HP=30")


# ============================================================
# T15: no side effect before commit
# ============================================================
func _t15_no_side_effect_before_commit() -> void:
	print("[B64B1-T15] no_side_effect_before_commit")
	var pair = _make_pair_sim()
	var sim = pair[0]
	var world = pair[1]
	var em = pair[2]
	var hp_before: int = int(world.current_hp_of(1))
	var alive_before: bool = bool(world.is_alive(1))
	var rng_before: Dictionary = sim._rng.snapshot()
	var next_id_before: int = int(em.peek_next_event_id())
	var tx = DamageTransactionScript.new()
	tx.setup(0, 1, 10)
	tx.set_pending_amount(7)
	tx.set_pending_amount(3)
	_assert(int(world.current_hp_of(1)) == hp_before,
		"world HP unchanged before commit")
	_assert(bool(world.is_alive(1)) == alive_before,
		"alive state unchanged")
	var rng_after: Dictionary = sim._rng.snapshot()
	_assert(rng_after == rng_before, "RNG snapshot unchanged")
	_assert(int(em.peek_next_event_id()) == next_id_before,
		"emitter counters unchanged")


# ============================================================
# B6.4c 3-segment ancestry helper.
# Walks: ATTACK_RESOLVED -> DAMAGE_STARTED -> DAMAGE_APPLIED
# (and optional UNIT_DIED grandchild). Returns null if any
# segment is missing.
# Returns a Dictionary with keys:
#   atk: ATTACK_RESOLVED event
#   started: DAMAGE_STARTED event (child of atk)
#   damage: DAMAGE_APPLIED event (child of started)
#   died: UNIT_DIED event (child of damage) or null
#   started_idx / damage_idx / died_idx: positions in events
#   damage_event_id: int (handy for trace parity asserts)
# Validates:
#   - started.parent_event_id == atk.event_id
#   - damage.parent_event_id == started.event_id
#   - started.depth == atk.depth + 1
#   - damage.depth == started.depth + 1
#   - root_action_id parity across all three
#   - strict index order atk < started < damage < died?
# ============================================================
func _bridge_attack_window(events: Array) -> Dictionary:
	# Step 1: find first ATTACK_RESOLVED (root scheduled attack).
	var atk_idx: int = -1
	var atk = null
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.parent_event_id) == -1 \
				and int(e.chain_depth) == 0:
			atk_idx = i
			atk = e
			break
	if atk == null:
		return {"atk": null, "started": null, "damage": null,
			"died": null, "atk_idx": -1, "started_idx": -1,
			"damage_idx": -1, "died_idx": -1}
	# Step 2: find DAMAGE_STARTED whose parent == atk.event_id.
	var started_idx: int = -1
	var started = null
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
				and int(e.parent_event_id) == int(atk.event_id) \
				and int(e.root_action_id) == int(atk.root_action_id):
			started_idx = i
			started = e
			break
	if started == null:
		return {"atk": atk, "atk_idx": atk_idx, "started": null,
			"damage": null, "died": null,
			"started_idx": -1, "damage_idx": -1, "died_idx": -1}
	# Step 3: find DAMAGE_APPLIED whose parent == started.event_id.
	var damage_idx: int = -1
	var damage = null
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.parent_event_id) == int(started.event_id) \
				and int(e.root_action_id) == int(atk.root_action_id):
			damage_idx = i
			damage = e
			break
	if damage == null:
		return {"atk": atk, "atk_idx": atk_idx, "started": started,
			"started_idx": started_idx, "damage": null,
			"died": null, "damage_idx": -1, "died_idx": -1}
	# Step 4 (optional): find UNIT_DIED whose parent == damage.event_id.
	var died_idx: int = -1
	var died = null
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.UNIT_DIED \
				and int(e.parent_event_id) == int(damage.event_id) \
				and int(e.root_action_id) == int(atk.root_action_id):
			died_idx = i
			died = e
			break
	return {"atk": atk, "started": started, "damage": damage,
		"died": died, "atk_idx": atk_idx,
		"started_idx": started_idx, "damage_idx": damage_idx,
		"died_idx": died_idx}


# ============================================================
# T16: perform_attack nonlethal parity
# ============================================================
func _t16_perform_attack_nonlethal_parity() -> void:
	print("[B64B1-T16] perform_attack_nonlethal_parity")
	var pair = _make_pair_sim(200, 200, 5, 5)
	var sim = pair[0]
	sim._rng = DeterministicRngScript.new(7)
	# B6.4c: drive the WHOLE tick so the work-pump drains the
	# DamageWindowWorkItem and finalize() emits DAMAGE_APPLIED.
	var events: Array = sim.step_tick()
	# B6.4c: trace now contains ATTACK_RESOLVED, DAMAGE_STARTED,
	# DAMAGE_APPLIED. Use the 3-segment bridge helper.
	var bridge = _bridge_attack_window(events)
	_assert(bridge.atk != null, "ATK_RESOLVED present")
	_assert(bridge.started != null, "DAMAGE_STARTED present (child of ATK)")
	_assert(bridge.damage != null, "DAMAGE_APPLIED present (child of DAMAGE_STARTED)")
	if bridge.atk == null or bridge.started == null or bridge.damage == null:
		return
	_assert(int(bridge.started.parent_event_id) == int(bridge.atk.event_id),
		"DAMAGE_STARTED.parent == ATK.event_id")
	_assert(int(bridge.damage.parent_event_id) == int(bridge.started.event_id),
		"DAMAGE_APPLIED.parent == DAMAGE_STARTED.event_id")
	_assert(int(bridge.atk.root_action_id) == int(bridge.damage.root_action_id),
		"shared root_action_id (ATK == DMG)")
	_assert(int(bridge.started.chain_depth) == int(bridge.atk.chain_depth) + 1,
		"DAMAGE_STARTED.depth == ATK.depth + 1")
	_assert(int(bridge.damage.chain_depth) == int(bridge.started.chain_depth) + 1,
		"DAMAGE_APPLIED.depth == DAMAGE_STARTED.depth + 1")
	_assert(bridge.atk_idx < bridge.started_idx
			and bridge.started_idx < bridge.damage_idx,
		"strict trace order: ATK < DAMAGE_STARTED < DAMAGE_APPLIED")
	_assert(sim.world().is_alive(1), "knight still alive")


# ============================================================
# T17: perform_attack lethal parity
# ============================================================
func _t17_perform_attack_lethal_parity() -> void:
	print("[B64B1-T17] perform_attack_lethal_parity")
	var pair = _make_pair_sim(200, 200, 999, 5)
	var sim = pair[0]
	sim._rng = DeterministicRngScript.new(7)
	# B6.4c: drive the WHOLE tick so the work-pump drains the
	# DamageWindowWorkItem and finalize() emits DAMAGE_APPLIED
	# + UNIT_DIED.
	var events: Array = sim.step_tick()
	# B6.4c: bridge contains ATK -> DAMAGE_STARTED -> DAMAGE_APPLIED
	# -> UNIT_DIED (lethal).
	var bridge = _bridge_attack_window(events)
	_assert(bridge.atk != null, "ATK_RESOLVED present")
	_assert(bridge.started != null, "DAMAGE_STARTED present")
	_assert(bridge.damage != null, "DAMAGE_APPLIED present")
	_assert(bridge.died != null, "UNIT_DIED present (lethal)")
	if bridge.died == null:
		return
	_assert(int(bridge.died.parent_event_id) == int(bridge.damage.event_id),
		"UNIT_DIED.parent == DAMAGE_APPLIED.event_id")
	_assert(int(bridge.atk.root_action_id) == int(bridge.died.root_action_id),
		"shared root_action_id across all 4 events")
	_assert(int(bridge.damage.amount) == 200,
		"DMG.amount == 200 (target full HP removed)")
	_assert(not sim.world().is_alive(1), "knight dead")


# ============================================================
# T18: counterattack ancestry proof (by tag)
# ============================================================
func _t18_counterattack_ancestry_proof() -> void:
	print("[B64B1-T18] counterattack_ancestry_proof")
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
	var events: Array = sim.step_tick()
	# B6.4c: build the bridge for the warrior's ROOT attack.
	# Used downstream to assert timing relative to the
	# counterattack (counter must fire AFTER original DMG).
	var bridge = _bridge_attack_window(events)
	_assert(bridge.atk != null, "warrior ROOT ATK_RESOLVED present")
	if bridge.atk == null:
		return
	var root_atk = bridge.atk
	_assert(bridge.damage != null, "warrior ROOT DAMAGE_APPLIED present")
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.parent_event_id) == -1 \
				and int(e.chain_depth) == 0 \
				and int(e.source_entity) == 0:
			root_atk = e
			break
	_assert(root_atk != null, "ROOT warrior->guardian ATK_RESOLVED present")
	if root_atk == null:
		return
	# Identify counterattack ATK by tag.
	var counter_atk = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "counterattack":
			counter_atk = e
			break
	_assert(counter_atk != null,
		"counterattack ATK with tag='counterattack' present")
	if counter_atk == null:
		return
	# Counter ATK source/target.
	_assert(int(counter_atk.source_entity) == 1,
		"counter source = guardian (1)")
	_assert(int(counter_atk.target_entity) == 0,
		"counter target = warrior (0)")
	# Counter ATK ancestry.
	_assert(int(counter_atk.parent_event_id) == int(root_atk.event_id),
		"counter.parent == ROOT.event_id")
	_assert(int(counter_atk.root_action_id) == int(root_atk.root_action_id),
		"counter shares root_action_id with ROOT")
	_assert(int(counter_atk.chain_depth) == int(root_atk.chain_depth) + 1,
		"counter.depth == ROOT.depth + 1")
	# B6.4c: counterattack DMG.parent is no longer counter ATK
	# directly; it is the new counter DAMAGE_STARTED. The
	# walk-bridge code below re-finds it. Do NOT keep the
	# legacy `parent == counter ATK` check.
	var counter_dmg = null  # assigned by the bridge walk below.
	# B6.4c: counterattack is now a 3-segment bridge:
	# counter ATK -> counter DAMAGE_STARTED -> counter DMG.
	# Walk the bridge explicitly. counter_dmg.parent must be
	# counter_started.event_id (NOT counter_atk.event_id).
	var counter_started = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
				and int(e.parent_event_id) == int(counter_atk.event_id) \
				and String(e.tag) == "counterattack":
			counter_started = e
			break
	_assert(counter_started != null,
		"counter DAMAGE_STARTED with parent=counter ATK and tag='counterattack'")
	if counter_started == null:
		return
	# Re-find counter_dmg whose parent is now counter_started.
	# B6.4c: use parent linkage (NOT root_action_id) as the
	# discriminator. The COUNTER-COUNTERATTACK's DMG has
	# different parent (its own counterattack ATK, not our
	# counter_started). The root_action_id is shared across
	# the entire causal family and is asserted as an invariant
	# (atk.root == started.root == damage.root), not used as
	# a filter.
	counter_dmg = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.parent_event_id) == int(counter_started.event_id) \
				and String(e.tag) == "counterattack":
			counter_dmg = e
			break
	_assert(counter_dmg != null,
		"counter DAMAGE_APPLIED with parent=counter DAMAGE_STARTED and tag='counterattack'")
	if counter_dmg != null:
		_assert(int(counter_dmg.root_action_id) == int(counter_atk.root_action_id),
			"counter DMG shares root_action_id")
		_assert(int(counter_dmg.chain_depth) == int(counter_started.chain_depth) + 1,
			"counter DMG.depth == counter DAMAGE_STARTED.depth + 1")
		_assert(int(counter_started.chain_depth) == int(counter_atk.chain_depth) + 1,
			"counter DAMAGE_STARTED.depth == counter ATK.depth + 1")
		# B6.4c frozen tag parity: counter DAMAGE_APPLIED.tag ==
		# "counterattack" (final_event_tag, NOT sem_tag). Same as
		# a5dd87d legacy.
		_assert(String(counter_dmg.tag) == "counterattack",
			"counter DAMAGE_APPLIED.tag == 'counterattack' (B6.4c legacy parity)")
		_assert(String(counter_started.tag) == "counterattack",
			"counter DAMAGE_STARTED.tag == 'counterattack'")
	# Event order assertion.
	# B6.4c: counter must fire AFTER the warrior's original
	# DAMAGE_APPLIED. This preserves legacy timing. The original
	# DMG_APPLIED is bridge.damage from the warrior's attack.
	var root_dmg_idx: int = -1
	var catk_idx: int = -1
	var cstarted_idx: int = -1
	var cdmg_idx: int = -1
	for i in events.size():
		var e = events[i]
		if e == bridge.damage:
			root_dmg_idx = i
		elif e == counter_atk:
			catk_idx = i
		elif e == counter_started:
			cstarted_idx = i
		elif e == counter_dmg:
			cdmg_idx = i
	_assert(root_dmg_idx >= 0 and catk_idx >= 0
			and root_dmg_idx < catk_idx,
		"original DMG_APPLIED appears BEFORE counterattack ATK_RESOLVED (preserves legacy timing)")
	_assert(catk_idx >= 0 and cstarted_idx >= 0 and cdmg_idx >= 0
			and catk_idx < cstarted_idx and cstarted_idx < cdmg_idx,
		"counter ATK < counter DAMAGE_STARTED < counter DAMAGE_APPLIED in trace")
	# Unique event IDs.
	var seen: Dictionary = {}
	for e in events:
		var id: int = int(e.event_id)
		_assert(not seen.has(id),
			"unique event_id (id=%d)" % id)
		seen[id] = true


# ============================================================
# T19: direct damage parity
# ============================================================
func _t19_direct_damage_parity() -> void:
	print("[B64B1-T19] direct_damage_parity")
	var pair = _make_pair_sim()
	var sim = pair[0]
	var em = pair[2]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.amount = 10
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(
		sim.world(), sim._rng, em, [])
	# B6.4c: DamageEffect returns succeeded_with_work; the
	# work-pump must drain the DamageWindowWorkItem so
	# finalize() commits the transaction. The executor's
	# return value (r) carries dispatch_work.
	var r = DamageEffectScript.new().execute(ctx, req)
	_assert(r != null, "DamageEffect returned a result")
	_assert(r.dispatch_work != null, "DamageEffect result has dispatch_work array")
	if r != null and r.dispatch_work != null and r.dispatch_work.size() > 0:
		# B6.4c: drain the DamageWindowWorkItem through the work-
		# pump. Use a real TriggerProvider (default discover
		# returns []) so discovery doesn't crash. ContentDBScript
		# is a static utility class, not a TriggerProvider.
		var TriggerDispatcherScript = load(
			"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
		var TriggerProviderScript = load(
			"res://core/battle_ecs/triggers/trigger_provider.gd")
		var TriggerLimitsScript = load(
			"res://core/battle_ecs/triggers/trigger_limits.gd")
		var TriggerDispatchSessionScript = load(
			"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
		var provider = TriggerProviderScript.new()
		var limits = TriggerLimitsScript.new()
		var ephemeral = TriggerDispatchSessionScript.from_limits(limits)
		var sink: Array = []
		TriggerDispatcherScript.new().process_work(
			r.dispatch_work, sim.world(), sim._rng, em, sink,
			provider, limits, ephemeral)
	_assert(int(sim.world().current_hp_of(1)) == 70,
		"direct damage=10: HP 70")


# ============================================================
# T20: real periodic burn (PeriodicStatusProcessor path)
# ============================================================
func _t20_real_periodic_burn() -> void:
	print("[B64B1-T20] real_periodic_burn")
	# Use real loaded burn StatusDef. Inject a burn StatusInstance
	# on the knight (entity 1). Run one step_tick which drives
	# PeriodicStatusProcessor -> STATUS_TICKED -> DamageEffect
	# -> DamageTransaction. Verify the chain.
	var burn_def = StatusDefResolverScript.resolve(&"burn")
	_assert(burn_def != null, "burn StatusDef loaded")
	if burn_def == null:
		return
	_assert(float(burn_def.tick_interval) == 1.0,
		"burn.tick_interval == 1.0")
	_assert(int(burn_def.dot_damage) > 0,
		"burn.dot_damage > 0")
	# Build a knight with low HP so the burn tick is nonlethal
	# (to keep it simple — we just verify STATUS_TICKED + DMG).
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 200, 200, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42,
		[mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(7)
	# Apply burn status to the knight.
	var sc = sim.world().get_status_container(1)
	if sc == null:
		sc = sim.world().create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"burn", 0, 1, 1, 3, int(burn_def.dot_damage))
	sc.add(inst, "stackable", 99)
	_assert(sc.has_status(&"burn"), "burn status applied to knight")
	# Run one step_tick. Periodic phase should fire.
	var events: Array = sim.step_tick()
	# Find STATUS_TICKED.
	var status_ticked = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED \
				and String(e.tag) == "burn":
			status_ticked = e
			break
	_assert(status_ticked != null,
		"STATUS_TICKED with tag=burn emitted by periodic phase")
	if status_ticked == null:
		return
	# B6.4c: bridge is STATUS_TICKED -> DAMAGE_STARTED -> DAMAGE_APPLIED.
	# Walk the 3-segment bridge.
	var burn_started = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
				and int(e.parent_event_id) == int(status_ticked.event_id) \
				and String(e.tag) == "burn":
			burn_started = e
			break
	_assert(burn_started != null,
		"burn DAMAGE_STARTED (parent=STATUS_TICKED, tag=burn)")
	if burn_started == null:
		return
	_assert(int(burn_started.chain_depth) == int(status_ticked.chain_depth) + 1,
		"burn DAMAGE_STARTED.depth == STATUS_TICKED.depth + 1")
	_assert(int(burn_started.source_entity) == 0,
		"burn DAMAGE_STARTED.source = source(0)")
	_assert(int(burn_started.target_entity) == 1,
		"burn DAMAGE_STARTED.target = target(1)")
	# Find DAMAGE_APPLIED whose parent is burn_started.
	var burn_dmg = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.parent_event_id) == int(burn_started.event_id):
			burn_dmg = e
			break
	_assert(burn_dmg != null,
		"burn DAMAGE_APPLIED (parent=burn DAMAGE_STARTED)")
	if burn_dmg != null:
		_assert(int(burn_dmg.amount) == int(burn_def.dot_damage),
			"DAMAGE_APPLIED.amount == burn.dot_damage")
		_assert(int(burn_dmg.chain_depth) == int(burn_started.chain_depth) + 1,
			"DAMAGE_APPLIED.depth == burn DAMAGE_STARTED.depth + 1")
		_assert(int(burn_dmg.source_entity) == 0,
			"DAMAGE_APPLIED.source = source(0)")
		# B6.4c frozen tag parity: DAMAGE_APPLIED.tag == "" for
		# direct / Burn path.
		_assert(String(burn_dmg.tag) == "",
			"burn DAMAGE_APPLIED.tag == '' (B6.4c legacy parity)")
		# Trace order: STATUS_TICKED < DAMAGE_STARTED < DAMAGE_APPLIED.
		var st_idx: int = -1
		var ds_idx: int = -1
		var dm_idx: int = -1
		for i in events.size():
			var e = events[i]
			if e == status_ticked:
				st_idx = i
			elif e == burn_started:
				ds_idx = i
			elif e == burn_dmg:
				dm_idx = i
		_assert(st_idx >= 0 and ds_idx >= 0 and dm_idx >= 0
				and st_idx < ds_idx and ds_idx < dm_idx,
			"STATUS_TICKED < burn DAMAGE_STARTED < burn DAMAGE_APPLIED in trace")


# ============================================================
# T21: same-seed 20-run determinism (full 14-field equality)
# ============================================================
func _t21_same_seed_20_run_determinism() -> void:
	print("[B64B1-T21] same_seed_20_run_determinism")
	var first_events: Array = []
	var first_world: Dictionary = {}
	var first_rng: Array = []
	var first_emitter: Dictionary = {}
	for i in 20:
		var pair = _make_pair_sim(200, 200, 5, 5)
		var sim = pair[0]
		sim._rng = DeterministicRngScript.new(7)  # SAME seed every run
		# B6.4c: step_tick drains the DamageWindowWorkItem so
		# the full trace including DAMAGE_APPLIED is observable.
		var events: Array = sim.step_tick()
		# Normalized 14-field event trace.
		var ev_norm: Array = []
		for e in events:
			ev_norm.append([
				int(e.event_id), int(e.type), int(e.tick),
				int(e.source_entity), int(e.target_entity),
				String(e.source_run_unit_id),
				String(e.target_run_unit_id),
				int(e.amount), String(e.tag),
				str(e.from_cell), str(e.to_cell),
				int(e.parent_event_id), int(e.root_action_id),
				int(e.chain_depth),
			])
		var world_state: Dictionary = {
			"0_hp": int(sim.world().current_hp_of(0)),
			"0_alive": bool(sim.world().is_alive(0)),
			"0_pos": str(sim.world().position_of(0)),
			"1_hp": int(sim.world().current_hp_of(1)),
			"1_alive": bool(sim.world().is_alive(1)),
			"1_pos": str(sim.world().position_of(1)),
		}
		var rng_snap: Dictionary = sim._rng.snapshot()
		var rng_state: Array = [
			int(rng_snap.get("seed", 0)),
			int(rng_snap.get("draw_count", 0)),
		]
		var em = sim._event_emitter
		var em_state: Dictionary = {
			"next_event_id": int(em.peek_next_event_id()),
			"next_root_action_id": int(em.peek_next_root_action_id()),
			"current_tick": int(em.current_tick()),
		}
		if i == 0:
			first_events = ev_norm
			first_world = world_state
			first_rng = rng_state
			first_emitter = em_state
		else:
			_assert(ev_norm == first_events,
				"run %d: full 14-field event trace equals run 0" % i)
			_assert(world_state == first_world,
				"run %d: world state equals run 0" % i)
			_assert(rng_state == first_rng,
				"run %d: RNG seed+draw_count equals run 0" % i)
			_assert(em_state == first_emitter,
				"run %d: emitter state equals run 0" % i)


# ============================================================
# T22: DamageEffect fail-closed: no phantom event on commit fail
# ============================================================
func _t22_damage_effect_fail_closed_no_phantom_event() -> void:
	print("[B64B1-T22] damage_effect_fail_closed_no_phantom_event")
	# Pre-kill the target so commit() returns target_dead.
	var pair = _make_pair_sim(200, 1, 999, 5)
	var sim = pair[0]
	var em = sim._event_emitter
	sim.world().apply_damage(1, 1)
	_assert(not sim.world().is_alive(1), "target pre-dead")
	# Direct invocation: DamageEffect with explicit amount.
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.amount = 10
	req.payload = {"skip_balance": true}
	var sink: Array = []
	var ctx = EffectContextScript.new(
		sim.world(), sim._rng, em, sink)
	var r = DamageEffectScript.new().execute(ctx, req)
	_assert(r != null and int(r.success) == 0,
		"DamageEffect returns failure on dead target")
	_assert(r.events.is_empty(),
		"EffectResult.events empty (no phantom DAMAGE_APPLIED)")
	_assert(sink.is_empty(),
		"sink empty (no event published)")
	# World unchanged.
	_assert(not sim.world().is_alive(1), "target still dead")
	_assert(int(sim.world().current_hp_of(1)) == 0,
		"target HP still 0 (no second mutation)")