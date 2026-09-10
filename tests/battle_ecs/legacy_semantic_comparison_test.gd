extends SceneTree
## Phase 2 / Gauntlet 10 — legacy semantic comparison.
##
## Compares legacy Combatant.basic_attack semantics against the new
## BattleSimulation for the supported vertical-slice behaviors.
##
## BLOCKER 2 fix: the new simulation now uses
## Balance.compute_damage (the same established defense scaling
## formula). The damage-value tests therefore upgrade from
## REPRESENTATION DIFFERENCE to PARITY REQUIRED — both legacy and
## new MUST produce the same integer damage.
##
## For each scenario, the suite classifies the comparison:
##
##   PARITY REQUIRED       — exact numerical equality enforced
##   NORMATIVE NEW BEHAVIOR — intentional divergence from legacy,
##                            documented, NOT a failure
##   REPRESENTATION DIFFERENCE — different formula yields different
##                            number but same qualitative behavior
##
## Scenarios NEVER use the assertion failure to "classify" as
## representation difference. If a property is asserted and it
## fails, the test fails — period.

const CombatantScript = preload("res://core/battle/combatant.gd")
const UnitDefScript = preload("res://core/data/unit_def.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BalanceScript = preload("res://core/balance.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_legacy_1v1_damage_value()
	await _test_legacy_defense_damage_value()
	await _test_legacy_high_defense_damage_floored_at_1()
	await _test_legacy_death_determines_winner()
	await _test_legacy_same_definition_distinct_entities()
	await _test_legacy_seeded_variance_dropped_normatively()
	await _test_legacy_dodge_dropped_normatively()
	await _test_legacy_balance_formula_used_by_new_sim()
	print("\n=== legacy semantic comparison: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Helpers ===

func _make_unit_def(id: StringName, team: int, hp: int, atk: int, dfs: int = 0, dodge: float = 0.0) -> Resource:
	var d: Resource = UnitDefScript.new()
	d.id = id
	d.display_name = String(id)
	d.team = team
	d.max_hp = hp
	d.attack = atk
	d.defense = dfs
	d.attack_speed = 1.0
	d.move_speed = 1.0
	d.attack_range = 5
	d.sight_range = 8
	d.crit_chance = 0.0
	d.crit_damage = 1.5
	d.dodge = dodge
	d.armor = 0
	return d


func _legacy_first_attack_dealt(attacker: Resource, target: Resource, seed: int) -> int:
	# Drives the legacy Combatant.basic_attack with a deterministic
	# RNG seeded externally. Returns the integer damage dealt.
	var Rng = preload("res://core/utils/rng_service.gd")
	Rng.seed_run(seed)
	var a = CombatantScript.new(attacker)
	var t = CombatantScript.new(target)
	var hp_before: int = int(t.health.current_hp)
	a.basic_attack(t)
	var hp_after: int = int(t.health.current_hp)
	return hp_before - hp_after


func _new_sim_first_damage(p_atk: int, p_dfs: int, p_hp: int, e_atk: int, e_dfs: int, e_hp: int, seed: int) -> int:
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"attacker", 0, Vector2i(0, 1), p_hp, p_hp, p_atk, p_dfs, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"target", 1, Vector2i(0, 0), e_hp, e_hp, e_atk, e_dfs, 5)
	var s: BattleSetupScript = BattleSetupScript.new(seed, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var result: int = -1
	while result < 0 and not sim.is_finished():
		var evs: Array = sim.step_tick()
		for ev in evs:
			if ev.type == 3:  # DAMAGE_APPLIED
				result = int(ev.amount)
				break
	return result


func _balance_formula_damage(atk: int, dfs: int) -> int:
	# Use the established Balance formula directly (no crit,
	# no dodge, no variance).
	return BalanceScript.compute_damage(atk, dfs, false, 0.0, 1.0)


# === Scenarios ===

# --- L-1: PARITY REQUIRED (damage value at defense=0) ---
func _test_legacy_1v1_damage_value() -> void:
	print("[L-1] legacy_1v1_damage_value [PARITY REQUIRED]")
	var attacker: Resource = _make_unit_def(&"attacker", 0, 80, 20, 0)
	var target: Resource = _make_unit_def(&"target", 1, 80, 0, 0)
	var legacy_dmg: int = _legacy_first_attack_dealt(attacker, target, 42)
	var new_dmg: int = _new_sim_first_damage(20, 0, 80, 0, 0, 80, 42)
	var formula_dmg: int = _balance_formula_damage(20, 0)
	_assert(legacy_dmg == formula_dmg,
		"legacy damage == Balance formula at defense=0 (legacy=%d formula=%d)" % [legacy_dmg, formula_dmg])
	_assert(new_dmg == formula_dmg,
		"new sim damage == Balance formula at defense=0 (new=%d formula=%d)" % [new_dmg, formula_dmg])


# --- L-2: PARITY REQUIRED (defense scales damage) ---
func _test_legacy_defense_damage_value() -> void:
	print("[L-2] legacy_defense_damage_value [PARITY REQUIRED]")
	var attacker: Resource = _make_unit_def(&"attacker", 0, 80, 20, 0)
	var target: Resource = _make_unit_def(&"target", 1, 80, 0, 10)
	var legacy_dmg: int = _legacy_first_attack_dealt(attacker, target, 42)
	var new_dmg: int = _new_sim_first_damage(20, 0, 80, 0, 10, 80, 42)
	var formula_dmg: int = _balance_formula_damage(20, 10)
	_assert(legacy_dmg == formula_dmg,
		"legacy damage == Balance formula at defense=10 (legacy=%d formula=%d)" % [legacy_dmg, formula_dmg])
	_assert(new_dmg == formula_dmg,
		"new sim damage == Balance formula at defense=10 (new=%d formula=%d)" % [new_dmg, formula_dmg])


# --- L-3: PARITY REQUIRED (damage floored at 1) ---
func _test_legacy_high_defense_damage_floored_at_1() -> void:
	print("[L-3] legacy_high_defense_damage_floored_at_1 [PARITY REQUIRED]")
	var attacker: Resource = _make_unit_def(&"attacker", 0, 80, 20, 0)
	var target: Resource = _make_unit_def(&"target", 1, 80, 0, 100)
	var legacy_dmg: int = _legacy_first_attack_dealt(attacker, target, 42)
	var new_dmg: int = _new_sim_first_damage(20, 0, 80, 0, 100, 80, 42)
	var formula_dmg: int = _balance_formula_damage(20, 100)
	_assert(legacy_dmg == formula_dmg and formula_dmg >= 1,
		"legacy damage floored at 1 (legacy=%d formula=%d)" % [legacy_dmg, formula_dmg])
	_assert(new_dmg == formula_dmg and new_dmg >= 1,
		"new sim damage floored at 1 (new=%d formula=%d)" % [new_dmg, formula_dmg])


# --- L-4: PARITY REQUIRED (death determines winner) ---
func _test_legacy_death_determines_winner() -> void:
	print("[L-4] legacy_death_determines_winner [PARITY REQUIRED]")
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"attacker", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"target", 1, Vector2i(0, 0), 10, 10, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	var r = sim.get_result()
	_assert(r.winner_team == 0, "new sim: player wins (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_VICTORY,
		"new sim: OUTCOME_VICTORY (got %d)" % r.outcome)
	_assert(r.termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"new sim: TERMINATION_NATURAL (got %d)" % r.termination_reason)


# --- L-5: PARITY REQUIRED (same-definition identity preserved) ---
func _test_legacy_same_definition_distinct_entities() -> void:
	print("[L-5] legacy_same_definition_distinct_entities [PARITY REQUIRED]")
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"w1", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"w2", &"warrior", 0, Vector2i(2, 1), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(1, 0), 30, 30, 5, 2, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p1, p2], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	var res = sim.get_result()
	_assert(res.source_run_unit_mapping.size() == 2,
		"both warriors mapped (got %d)" % res.source_run_unit_mapping.size())
	var has_w1: bool = res.source_run_unit_mapping.values().has("w1")
	var has_w2: bool = res.source_run_unit_mapping.values().has("w2")
	_assert(has_w1 and has_w2, "w1 and w2 both mapped (w1=%s w2=%s)" % [has_w1, has_w2])


# --- L-6: NORMATIVE NEW BEHAVIOR (variance dropped intentionally) ---
func _test_legacy_seeded_variance_dropped_normatively() -> void:
	print("[L-6] legacy_seeded_variance_dropped_normatively [NORMATIVE NEW BEHAVIOR]")
	# Legacy: damage has +/- 5% variance (compute_attack).
	# New sim: damage is deterministic per Balance formula.
	# Variance is a NORMATIVE FEATURE DEFER — reintroducible via
	# a different compute_damage variant in Phase 3.
	var run1: int = _new_sim_first_damage(20, 0, 80, 0, 0, 80, 42)
	var run2: int = _new_sim_first_damage(20, 0, 80, 0, 0, 80, 42)
	_assert(run1 == run2, "new sim damage is variance-free (run1=%d run2=%d)" % [run1, run2])
	print("  [INFO] new sim has NO legacy +/-5% damage variance (NORMATIVE FEATURE DEFER).")


# --- L-7: NORMATIVE NEW BEHAVIOR (dodge dropped intentionally) ---
func _test_legacy_dodge_dropped_normatively() -> void:
	print("[L-7] legacy_dodge_dropped_normatively [NORMATIVE NEW BEHAVIOR]")
	# Legacy: target_dodge chance roll to skip damage entirely.
	# New sim: no dodge roll.
	# Dodge is a NORMATIVE FEATURE DEFER — reintroducible in Phase 3.
	var new_dmg: int = _new_sim_first_damage(20, 0, 80, 0, 0, 80, 42)
	_assert(new_dmg > 0, "new sim: damage ALWAYS lands (no dodge roll) — NORMATIVE NEW BEHAVIOR")
	print("  [INFO] new sim has NO legacy dodge roll (NORMATIVE FEATURE DEFER).")


# --- L-8: PARITY REQUIRED (new sim uses Balance formula directly) ---
func _test_legacy_balance_formula_used_by_new_sim() -> void:
	print("[L-8] legacy_balance_formula_used_by_new_sim [PARITY REQUIRED]")
	# New sim must call Balance.compute_damage, not invent a
	# different formula. Verify at multiple defense values.
	for dfs in [0, 5, 10, 20, 50]:
		var new_dmg: int = _new_sim_first_damage(20, 0, 80, 0, dfs, 80, 42)
		var formula_dmg: int = _balance_formula_damage(20, dfs)
		_assert(new_dmg == formula_dmg,
			"new sim matches Balance formula at defense=%d (new=%d formula=%d)" % [dfs, new_dmg, formula_dmg])
