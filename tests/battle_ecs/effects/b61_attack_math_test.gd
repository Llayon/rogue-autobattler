extends SceneTree
## B6.1 Task 1 RED — shared attack math helper exists and
## delegates to Balance.compute_damage with the canonical
## Phase 2 signature (atk, dfs, false, 0.0, 1.0).
##
## Tiny test because the helper is a 1-line wrapper. The
## semantic proof is downstream (B6.1 Task 3+).

const AttackMathScript = preload(
	"res://core/battle_ecs/effects/attack_math.gd")
const BalanceScript = preload(
	"res://core/balance.gd")


func _initialize() -> void:
	print("[B61-T1] attack_math_compute_basic")
	# Same attacker/defender pair that the canonical
	# BattleSimulation._compute_damage currently feeds
	# into Balance.compute_damage(attack, defense, false, 0.0, 1.0).
	var atk: int = 50
	var dfs: int = 5
	var expected: int = int(BalanceScript.compute_damage(
		atk, dfs, false, 0.0, 1.0))
	var got: int = int(AttackMathScript.compute(atk, dfs))
	_assert_eq(got, expected,
		"AttackMathScript.compute(50, 5) must equal Balance.compute_damage(50, 5, false, 0.0, 1.0)")
	# Edge: zero attack should still delegate cleanly.
	var z: int = int(AttackMathScript.compute(0, 5))
	_assert_eq(z, int(BalanceScript.compute_damage(
		0, 5, false, 0.0, 1.0)),
		"AttackMathScript.compute(0, 5) still delegates to Balance")
	print("\n=== B6.1 attack math: %d pass / %d fail ===\n" % [_pass_count, _fail_count])
	if _fail_count > 0:
		quit(1)
	quit(0)


var _fail_count: int = 0
var _pass_count: int = 0


func _assert_eq(got: int, want: int, label: String) -> void:
	if got == want:
		_pass_count += 1
		print("  [OK]   %s" % label)
	else:
		_fail_count += 1
		print("  [FAIL] %s (got %d, want %d)" % [label, got, want])
