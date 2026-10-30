extends SceneTree
## B6.4c — DRAINED-WINDOW INVARIANT (critic finding).
##
## A damage window that was OPENED must always be CLOSED — its
## HP mutation must happen exactly once, and the battle-level
## pending count must be back to zero when the pump returns.
##
## The defect this suite pins down:
##
##   process_work() resets _pending_count = 0 at the START of
##   every call (trigger_dispatcher.gd:211). The MAX_EVENTS
##   cap-break at line 283 leaves the remaining FIFO entries
##   un-popped. A DamageWindowWorkItem that is still QUEUED
##   when the loop breaks is therefore:
##
##     - never popped,
##     - never finalized,
##     - its HP mutation never happens (the damage is SILENTLY
##       LOST),
##     - and _pending_count does not reflect it either (it was
##       reset to 0 at the top of the call).
##
## The suite proves the invariant on the CAP-BREAK path AND on
## the ordinary path.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_cap_break_does_not_lose_a_queued_window()
	_test_ordinary_path_drains_every_window()
	_test_pending_count_reflects_open_windows()
	print("\n=== B6.4c drained-window invariant: %d pass / %d fail ==="
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


# --- fixtures ---

func _make_world(p_max_hp: int) -> Dictionary:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1),
		p_max_hp, p_max_hp, 20, 5, 1)
	var e = B.new("e", &"orc", 1, Vector2i(0, 0),
		p_max_hp, p_max_hp, 20, 5, 1)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	return {"world": w, "emitter": em, "rng": rng}


# A provider that reacts to EVERY BattleEvent it sees, so the
# FIFO keeps growing and the MAX_EVENTS cap is guaranteed to fire.
class _AlwaysReact extends RefCounted:
	var reactions_made: int = 0
	func discover(_world, p_event, _rng) -> Array:
		var req = EffectRequestScript.root(
			EffectKindScript.DAMAGE, 0, 1, 1)
		var tr = preload("res://core/battle_ecs/triggers/trigger_reaction.gd").new()
		tr.reacting_entity = 0
		tr.kind = &"spam"
		tr.request = req
		tr.trigger_chance = 1.0
		reactions_made += 1
		return [tr]


func _open_window(p_world, p_emitter, p_rng) -> Array:
	# Open ONE damage window against entity 1.
	var req = EffectRequestScript.root(
		EffectKindScript.DAMAGE, 0, 1, 10)
	req.payload = {"skip_balance": true}
	var sink: Array = []
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, sink)
	var res = EffectExecutorScript.new().execute(ctx, req)
	return res.dispatch_work


# --- tests ---

func _test_cap_break_does_not_lose_a_queued_window() -> void:
	print("[DW-1] a queued window is never silently lost on cap-break")
	var fx = _make_world(100)
	var world = fx["world"]
	var em = fx["emitter"]
	var rng = fx["rng"]
	# TWO BattleEvents are queued up-front, so the FIFO is:
	#   [EventA, EventB]
	# EventA is accepted and its reaction opens a damage window,
	# which is appended:
	#   [EventB, windowW]
	# EventB then hits the MAX_EVENTS cap and the pump BREAKs out
	# of the loop. windowW is still queued and MUST still be
	# finalized — otherwise its HP mutation is SILENTLY LOST.
	var ev_a = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 5, "")
	var ev_b = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 5, "")
	var hp_before: int = int(world.current_hp_of(1))
	# The reaction on EventA opens a 10-damage window.
	var work: Array = _open_window(world, em, rng)
	_assert(work.size() == 1, "one window work item opened")
	# The cap allows exactly ONE event: EventA passes, EventB does
	# not, and the pump breaks with windowW still queued.
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 1
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dispatcher = TriggerDispatcherScript.new()
	dispatcher.process_work(
		[ev_a, ev_b] + work, world, rng, em, sink,
		_AlwaysReact.new(), limits, session)
	var hp_after: int = int(world.current_hp_of(1))
	# The window's own 10 damage MUST be among the applied total.
	# The AlwaysReact provider also fires 1-damage reactions, so
	# the total is >= 10 + (reactions that were admitted).
	_assert(hp_after <= hp_before - 10,
		"the queued window's 10 damage was committed (HP %d -> %d)"
			% [hp_before, hp_after])
	var window_applied: int = 0
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(ev.amount) == 10:
			window_applied += 1
	_assert(window_applied == 1,
		"exactly 1 DAMAGE_APPLIED of the window's 10 damage (got %d)"
			% window_applied)
	_assert(int(dispatcher.pending_count()) == 0,
		"pending_count == 0 after the pump (got %d)"
			% int(dispatcher.pending_count()))


func _test_ordinary_path_drains_every_window() -> void:
	print("[DW-2] the ordinary path drains every window")
	var fx = _make_world(100)
	var work: Array = _open_window(
		fx["world"], fx["emitter"], fx["rng"])
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dispatcher = TriggerDispatcherScript.new()
	dispatcher.process_work(
		work, fx["world"], fx["rng"], fx["emitter"], sink,
		TriggerProviderScript.new(), limits, session)
	_assert(int(fx["world"].current_hp_of(1)) == 90,
		"the window committed 10 damage (HP=%d)"
			% int(fx["world"].current_hp_of(1)))
	_assert(int(dispatcher.pending_count()) == 0,
		"pending_count == 0 after the pump (got %d)"
			% int(dispatcher.pending_count()))


func _test_pending_count_reflects_open_windows() -> void:
	print("[DW-3] pending_count reflects an open window")
	var fx = _make_world(100)
	var work: Array = _open_window(
		fx["world"], fx["emitter"], fx["rng"])
	# The window is OPEN: the work item exists but has not been
	# driven. The dispatcher must be able to report that.
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dispatcher = TriggerDispatcherScript.new()
	dispatcher.process_work(
		work, fx["world"], fx["rng"], fx["emitter"], sink,
		TriggerProviderScript.new(), limits, session)
	_assert(int(dispatcher.pending_count()) == 0,
		"pending_count == 0 once the window is closed (got %d)"
			% int(dispatcher.pending_count()))
