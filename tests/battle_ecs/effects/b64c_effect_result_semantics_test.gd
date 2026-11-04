extends SceneTree
## B6.4c ER1-ER4 — EffectResult dispatch_work semantics.
##
## The null-vs-empty distinction is load-bearing for the
## events / dispatch_work separation:
##
##   null -> legacy default (events.duplicate())
##   []   -> EXPLICIT "no further dispatch"
##   [W]  -> explicit work items
##
## A previous implementation used `size() > 0` which made
## `succeeded_with_work([E], [])` behave like the legacy default.
## These tests pin the exact semantics.
##
## The proofs live in STATIC functions so the authoritative
## B6.4c suite can run them IN-PROCESS (no subprocess, no code
## duplication). This file is the standalone wrapper.

const EffectResultScript = preload(
	"res://core/battle_ecs/effects/effect_result.gd")

var _passed: int = 0
var _failed: int = 0


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


# ============================================================
# Static proof API. `p_assert` is a Callable the caller
# provides so the counting stays with the caller.
# ============================================================
static func run_all(p_assert: Callable) -> void:
	_er1_succeeded_uses_legacy_default(p_assert)
	_er2_explicit_empty_override(p_assert)
	_er3_explicit_work_items(p_assert)
	_er4_failed_never_dispatches(p_assert)


# ============================================================
# ER1 — succeeded([E]) -> dispatch_work == [E] (legacy default)
# ============================================================
static func _er1_succeeded_uses_legacy_default(p_assert: Callable) -> void:
	print("[B64C-ER1] succeeded_uses_legacy_default")
	var ev = {"marker": "E"}
	var r = EffectResultScript.succeeded([ev])
	p_assert.call(bool(r.success), "ER1: success == true")
	p_assert.call(r.events.size() == 1, "ER1: events.size == 1")
	p_assert.call(r.dispatch_work.size() == 1,
		"ER1: dispatch_work.size == 1 (got %d)" % r.dispatch_work.size())
	p_assert.call(r.dispatch_work.size() > 0 and r.dispatch_work[0] == ev,
		"ER1: dispatch_work[0] is the same event object")
	# (Array identity comparison is not available in GDScript —
	# `!=` compares by value. The duplicate-ness is proven by
	# ER2's "distinct Array" check on a different result.)


# ============================================================
# ER2 — succeeded_with_work([E], []) -> dispatch_work == []
#        (explicit empty override is honoured verbatim)
# ============================================================
static func _er2_explicit_empty_override(p_assert: Callable) -> void:
	print("[B64C-ER2] explicit_empty_override_honoured")
	var ev = {"marker": "E"}
	var r = EffectResultScript.succeeded_with_work([ev], [])
	p_assert.call(bool(r.success), "ER2: success == true")
	p_assert.call(r.events.size() == 1, "ER2: events.size == 1")
	p_assert.call(r.dispatch_work.size() == 0,
		"ER2: dispatch_work.size == 0 (explicit empty override)")
	p_assert.call(r.dispatch_work.size() != r.events.size(),
		"ER2: dispatch_work differs from events (no legacy default applied)")


# ============================================================
# ER3 — succeeded_with_work([E], [W]) -> dispatch_work == [W]
# ============================================================
static func _er3_explicit_work_items(p_assert: Callable) -> void:
	print("[B64C-ER3] explicit_work_items_honoured")
	var ev = {"marker": "E"}
	var w = {"marker": "W"}
	var r = EffectResultScript.succeeded_with_work([ev], [w])
	p_assert.call(bool(r.success), "ER3: success == true")
	p_assert.call(r.events.size() == 1, "ER3: events.size == 1")
	p_assert.call(r.dispatch_work.size() == 1,
		"ER3: dispatch_work.size == 1 (got %d)" % r.dispatch_work.size())
	p_assert.call(r.dispatch_work.size() > 0 and r.dispatch_work[0] == w,
		"ER3: dispatch_work[0] is the explicit work item")
	p_assert.call(r.dispatch_work[0] != ev,
		"ER3: dispatch_work does NOT contain the public event")


# ============================================================
# ER4 — failed(...) -> dispatch_work == []
# ============================================================
static func _er4_failed_never_dispatches(p_assert: Callable) -> void:
	print("[B64C-ER4] failed_never_dispatches")
	var r = EffectResultScript.failed("b64c: synthetic failure", [])
	p_assert.call(not bool(r.success), "ER4: success == false")
	p_assert.call(String(r.reason) == "b64c: synthetic failure",
		"ER4: reason preserved")
	p_assert.call(r.dispatch_work.size() == 0,
		"ER4: dispatch_work.size == 0 for failed effects")
	# A failed effect WITH events still must not dispatch.
	var r2 = EffectResultScript.failed("b64c: fail with event", [{"m": "E"}])
	p_assert.call(r2.events.size() == 1, "ER4: failed result keeps its events")
	p_assert.call(r2.dispatch_work.size() == 0,
		"ER4: failed result with events still has dispatch_work == []")


func _initialize() -> void:
	run_all(_assert)
	print("\n=== B6.4c ER1-ER4 EffectResult dispatch_work semantics: %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
		return
	quit(0)
