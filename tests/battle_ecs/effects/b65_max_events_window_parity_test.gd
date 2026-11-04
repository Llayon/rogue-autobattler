extends SceneTree
## TD-05 — MAX_EVENTS PARITY FOR THE PRE-DAMAGE WINDOW.
##
## A capped run must behave identically whether the dispatcher runs
## with an explicit TriggerDispatchSession or without one.
##
## Baseline defect: the window branch of TriggerDispatcher checks the
## cap only when a session is present
##
##     if using_session and bool(p_session.cap_reached()):
##
## so in the no-session path a DamageWindowWorkItem was still
## discovered and executed even after the event budget was spent. The
## two paths diverged: HP, DAMAGE_APPLIED and pending_count differed.
##
## Contract:
##   - the cap is checked in BOTH paths;
##   - after the cap the open window MUST finalize (no dangling
##     window, no leaked pending damage);
##   - after the cap there is NO new reaction discovery, NO modifier
##     execution and NO RNG draw;
##   - the result reports truncated = true with reason MAX_EVENTS;
##   - HP / DAMAGE_APPLIED / pending_count are identical between the
##     session and the no-session path.

const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")
const DamageTransactionScript = preload(
	"res://core/battle_ecs/effects/damage_transaction.gd")
const DamageWindowHandleScript = preload(
	"res://core/battle_ecs/effects/damage_window_handle.gd")
const DamageWindowContinuationScript = preload(
	"res://core/battle_ecs/effects/damage_window_continuation.gd")
const DamageWindowWorkItemScript = preload(
	"res://core/battle_ecs/effects/damage_window_work_item.gd")

var _passed: int = 0
var _failed: int = 0


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


## A provider that fires one MODIFY_PENDING_DAMAGE reaction on
## DAMAGE_STARTED. `fired` counts the discoveries, so the test can
## prove that NO discovery happens after the cap.
class _WindowModifier extends RefCounted:
	var new_pending: int = 0
	var fired: int = 0

	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		fired += 1
		var req = EffectRequestScript.root(
			EffectKindScript.MODIFY_PENDING_DAMAGE,
			int(p_event.source_entity), int(p_event.target_entity),
			int(new_pending))
		req.definition_id = StringName("window_modifier")
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.source_entity)
		tr.request = req
		return [tr]


func _make_world() -> Array:
	var attacker = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 20, 5, 1, [])
	var target = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [attacker], [target], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	return [sim, sim.world(), sim._event_emitter]


## Builds a real damage window: transaction + handle + continuation +
## work item, exactly like DamageEffect does.
func _make_window(emitter, source: int, target: int, amount: int) -> RefCounted:
	var dmg_started = emitter.emit(
		BattleEventTypeScript.DAMAGE_STARTED, source, target, "", "", amount)
	var tx = DamageTransactionScript.new()
	tx.setup(source, target, amount)
	var handle = DamageWindowHandleScript.new()
	handle.setup(tx)
	var continuation = DamageWindowContinuationScript.new()
	continuation.tx = tx
	continuation.handle = handle
	continuation.event = dmg_started
	continuation.source_entity = source
	continuation.target_entity = target
	continuation.source_run_unit_id = ""
	continuation.target_run_unit_id = ""
	continuation.final_event_tag = StringName("")
	continuation.died_event_tag = StringName("")
	continuation.died_amount_is_dealt = false
	return DamageWindowWorkItemScript.new(dmg_started, continuation, handle, [])


## Runs the dispatcher over [ordinary event, window item] with the
## event budget already exhausted by the ordinary event.
func _run_window_first(p_use_session: bool, p_new_pending: int) -> Dictionary:
	# The same setup as _run(), but the damage window is handed to the
	# dispatcher FIRST, so the event budget is still intact when the
	# window is processed.
	var parts = _make_world()
	var world = parts[1]
	var emitter = parts[2]
	var sink: Array = []

	var provider = _WindowModifier.new()
	provider.new_pending = p_new_pending
	var rng = DeterministicRngScript.new(12345)

	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 1
	limits.max_chain_depth = 7
	limits.max_reactions_per_root = 4

	var session = null
	if p_use_session:
		session = TriggerDispatchSessionScript.from_limits(limits)

	var window_item = _make_window(emitter, 0, 1, 20)
	var ordinary = emitter.emit(
		BattleEventTypeScript.DAMAGE_STARTED, 0, 1, "", "", 20)
	var before_hp: int = int(world.current_hp_of(1))
	var before_rng: Dictionary = rng.snapshot()

	var dispatcher = TriggerDispatcherScript.new()
	var result = dispatcher.process_work(
		[window_item, ordinary], world, rng, emitter, sink, provider,
		limits, session)

	var after_hp: int = int(world.current_hp_of(1))
	var applied: Array = []
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied.append(int(ev.amount))

	var handle = window_item.handle
	var continuation = window_item.continuation
	var tx = continuation.tx

	return {
		"tx_committed": bool(tx.is_committed()),
		"handle_active": bool(handle.is_active()),
		"truncated": bool(result.truncated),
		"reason": int(result.reason),
		"hp_before": before_hp,
		"hp_after": after_hp,
		"applied": applied,
		"pending": int(dispatcher.pending_count()),
		"discoveries": int(provider.fired),
		"rng_before": before_rng,
		"rng_after": rng.snapshot(),
	}


func _run(p_use_session: bool, p_new_pending: int) -> Dictionary:
	var parts = _make_world()
	var world = parts[1]
	var emitter = parts[2]
	var sink: Array = []

	var provider = _WindowModifier.new()
	provider.new_pending = p_new_pending
	var rng = DeterministicRngScript.new(12345)

	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 1
	limits.max_chain_depth = 7
	limits.max_reactions_per_root = 4

	var session = null
	if p_use_session:
		session = TriggerDispatchSessionScript.from_limits(limits)

	# The ordinary event consumes the whole event budget, and the
	# damage window arrives right after it. Both items are handed to
	# ONE process_work call, because the dispatcher resets its
	# no-session bookkeeping at the start of every call.
	var ordinary = emitter.emit(
		BattleEventTypeScript.DAMAGE_STARTED, 0, 1, "", "", 20)
	var window_item = _make_window(emitter, 0, 1, 20)
	var before_hp: int = int(world.current_hp_of(1))
	var before_rng: Dictionary = rng.snapshot()

	var dispatcher = TriggerDispatcherScript.new()
	var result = dispatcher.process_work(
		[ordinary, window_item], world, rng, emitter, sink, provider,
		limits, session)

	var after_hp: int = int(world.current_hp_of(1))
	var applied: Array = []
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied.append(int(ev.amount))

	var handle = window_item.handle
	var continuation = window_item.continuation
	var tx = continuation.tx

	return {
		"tx_committed": bool(tx.is_committed()),
		"handle_active": bool(handle.is_active()),
		"truncated": bool(result.truncated),
		"reason": int(result.reason),
		"hp_before": before_hp,
		"hp_after": after_hp,
		"applied": applied,
		"pending": int(dispatcher.pending_count()),
		"discoveries": int(provider.fired),
		"rng_before": before_rng,
		"rng_after": rng.snapshot(),
	}


func _initialize() -> void:
	print("=== TD-05: MAX_EVENTS session / no-session parity ===")
	_test_parity()
	_test_window_before_the_budget_is_spent()
	print("\n=== TD-05: %d pass / %d fail ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _test_window_before_the_budget_is_spent() -> void:
	# The window arrives while the event budget is still intact, so it
	# must NOT be truncated: the reaction runs and the pending damage
	# is modified.
	#
	# This is the scenario that proves the dispatcher really installs
	# the effective event budget. Without it, a dispatcher that never
	# installs the budget would treat EVERY window as capped, and the
	# parity assertions alone would still hold (both paths equally
	# wrong).
	var with_session = _run_window_first(true, 5)
	var without_session = _run_window_first(false, 5)

	print("  window-first session    : %s" % str(with_session))
	print("  window-first no-session : %s" % str(without_session))

	# NOTE: result.truncated is NOT the discriminator here. It means
	# "at least one branch was bounded": in this scenario the WINDOW is
	# processed and the ORDINARY event that follows is bounded, so
	# truncated=true is correct. The discriminating signals are the
	# applied amount (the window's reaction modified the pending
	# damage) and the discovery count.
	_assert(int(with_session["discoveries"]) == 1,
		"TD-05: the reaction of an uncapped window runs exactly once (got %d, want 1)"
			% int(with_session["discoveries"]))
	_assert(int(without_session["discoveries"]) == 1,
		"TD-05: the reaction of an uncapped window runs exactly once (no-session, got %d, want 1)"
			% int(without_session["discoveries"]))
	_assert(int(with_session["applied"][0]) == 5,
		"TD-05: the uncapped window applied the MODIFIED pending damage (got %d, want 5)"
			% int(with_session["applied"][0]))
	_assert(int(without_session["applied"][0]) == 5,
		"TD-05: the uncapped window applied the MODIFIED pending damage (no-session, got %d, want 5)"
			% int(without_session["applied"][0]))
	_assert(int(with_session["hp_after"]) == int(with_session["hp_before"]) - 5,
		"TD-05: the uncapped window cost 5 HP (got %d)"
			% (int(with_session["hp_before"]) - int(with_session["hp_after"])))
	_assert(int(without_session["hp_after"]) == int(without_session["hp_before"]) - 5,
		"TD-05: the uncapped window cost 5 HP (no-session, got %d)"
			% (int(without_session["hp_before"]) - int(without_session["hp_after"])))
	_assert(bool(with_session["tx_committed"]) and bool(without_session["tx_committed"]),
		"TD-05: both uncapped windows committed their transaction")
	_assert(not bool(with_session["handle_active"]) and not bool(without_session["handle_active"]),
		"TD-05: both uncapped windows closed their handle")


func _test_parity() -> void:
	# The first event consumes the budget; the window then arrives
	# with nothing left.
	var with_session = _run(true, 5)
	var without_session = _run(false, 5)

	print("  session    : %s" % str(with_session))
	print("  no-session : %s" % str(without_session))

	# Both paths must report the cap.
	_assert(bool(with_session["truncated"]),
		"TD-05: the session path reports truncation")
	_assert(bool(without_session["truncated"]),
		"TD-05: the no-session path reports truncation")
	_assert(int(with_session["reason"]) == int(DispatchResultScript.REASON_MAX_EVENTS),
		"TD-05: the session path reports REASON_MAX_EVENTS")
	_assert(int(without_session["reason"]) == int(DispatchResultScript.REASON_MAX_EVENTS),
		"TD-05: the no-session path reports REASON_MAX_EVENTS")

	# The window must finalize identically in both paths: the target
	# loses the same HP and the same DAMAGE_APPLIED amount is emitted.
	_assert(int(with_session["hp_after"]) == int(without_session["hp_after"]),
		"TD-05: both paths end with the same HP (session %d, no-session %d)"
			% [int(with_session["hp_after"]), int(without_session["hp_after"])])
	_assert(str(with_session["applied"]) == str(without_session["applied"]),
		"TD-05: both paths emit the same DAMAGE_APPLIED (session %s, no-session %s)"
			% [str(with_session["applied"]), str(without_session["applied"])])
	_assert(int(with_session["pending"]) == 0,
		"TD-05: the session path leaves no pending window (got %d)"
			% int(with_session["pending"]))
	_assert(int(without_session["pending"]) == 0,
		"TD-05: the no-session path leaves no pending window (got %d)"
			% int(without_session["pending"]))

	# ANTI-VACUITY: the parity assertions above compare the two paths
	# with EACH OTHER. A defect that breaks BOTH paths identically (for
	# example a dispatcher that never installs the event budget) would
	# keep the parity and pass every comparison above.
	#
	# These assertions pin the ABSOLUTE outcome of the capped run: the
	# window was NOT modified, the transaction committed the full 20,
	# and exactly ONE reaction was discovered. Without them the parity
	# suite would be satisfied by two equally wrong paths.
	_assert(int(with_session["applied"][0]) == 20,
		"TD-05: the capped window committed the FULL pending damage (got %d, want 20)"
			% int(with_session["applied"][0]))
	_assert(int(without_session["applied"][0]) == 20,
		"TD-05: the capped no-session window committed the FULL pending damage (got %d, want 20)"
			% int(without_session["applied"][0]))
	_assert(int(with_session["discoveries"]) == 1,
		"TD-05: exactly ONE reaction was discovered before the cap (got %d, want 1)"
			% int(with_session["discoveries"]))
	_assert(int(without_session["discoveries"]) == 1,
		"TD-05: exactly ONE reaction was discovered before the cap (no-session, got %d, want 1)"
			% int(without_session["discoveries"]))

	# After the cap there must be NO new discovery and NO RNG draw.
	_assert(int(without_session["discoveries"]) == int(with_session["discoveries"]),
		"TD-05: both paths perform the same number of discoveries (session %d, no-session %d)"
			% [int(with_session["discoveries"]), int(without_session["discoveries"])])
	_assert(with_session["rng_after"] == with_session["rng_before"],
		"TD-05: the session path draws no RNG after the cap")
	_assert(without_session["rng_after"] == without_session["rng_before"],
		"TD-05: the no-session path draws no RNG after the cap")

	# The capped window MUST still finalize: the transaction is
	# committed, the handle is closed and no pending damage leaks.
	# A window that dangles would keep the transaction open, so this
	# catches "skip the finalize after the cap".
	_assert(bool(with_session["tx_committed"]),
		"TD-05: the session path commits the capped window")
	_assert(bool(without_session["tx_committed"]),
		"TD-05: the no-session path commits the capped window")
	_assert(not bool(with_session["handle_active"]),
		"TD-05: the session path closes the capped window handle")
	_assert(not bool(without_session["handle_active"]),
		"TD-05: the no-session path closes the capped window handle")
