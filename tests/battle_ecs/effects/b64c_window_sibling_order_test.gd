extends SceneTree
## B6.4c — WINDOW-PATH SIBLING ORDERING (critic #1 finding #2).
##
## The sibling-ordering contract (contract #7):
##
##   reaction sibling admission observes all synchronous commits
##   of previous siblings
##
## The legacy path (_execute_reaction) honours it: a sibling that
## opens a damage window has that window driven INLINE, so the
## NEXT sibling sees the committed world.
##
## The WINDOW path (_execute_reaction_window) did NOT: every
## sibling runs in COLLECTOR mode and its dispatch_work is only
## enqueued AFTER the outer window finalizes. So a sibling that
## opens a nested damage window has that nested window commit
## LATE, and the next sibling observes the PRE-commit world.
##
## This suite proves the window path honours the same contract:
## sibling A opens a 5-damage window, sibling B heals 100; B must
## see the 5 HP room A's committed damage created, so the heal is
## clamped to 5 (not 0, not 100).

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
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_window_path_sibling_observes_previous_sibling_commit()
	print("\n=== B6.4c window-path sibling ordering: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


# Sibling A opens a 5-damage window; sibling B heals 100.
class _DamageThenHeal extends TriggerProviderScript:
	var fired: int = 0
	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.STATUS_TICKED:
			pass
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		# ONE-SHOT: sibling A opens a NESTED window whose own
		# DAMAGE_STARTED would otherwise re-trigger this provider
		# and cascade. We only want to observe the FIRST window's
		# sibling ordering.
		if self.fired > 0:
			return []
		self.fired += 1
		var out: Array = []
		# Sibling A: a plain DAMAGE effect -> opens its own window.
		var req_a = EffectRequestScript.root(
			EffectKindScript.DAMAGE,
			int(p_event.source_entity), int(p_event.target_entity), 5)
		req_a.payload = {"skip_balance": true}
		var tr_a = TriggerReactionScript.new()
		tr_a.reacting_entity = int(p_event.source_entity)
		tr_a.kind = &"dmg5"
		tr_a.request = req_a
		tr_a.trigger_chance = 1.0
		out.append(tr_a)
		# Sibling B: an ordinary HEAL effect -> no window.
		var req_b = EffectRequestScript.root(
			EffectKindScript.HEAL,
			int(p_event.source_entity), int(p_event.target_entity), 100)
		var tr_b = TriggerReactionScript.new()
		tr_b.reacting_entity = int(p_event.source_entity)
		tr_b.kind = &"heal100"
		tr_b.request = req_b
		tr_b.trigger_chance = 1.0
		out.append(tr_b)
		return out


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


func _test_window_path_sibling_observes_previous_sibling_commit() -> void:
	print("[WS-1] a window-path sibling observes the previous sibling's commit")
	var fx = _make_world(200)
	var world = fx["world"]
	var em = fx["emitter"]
	var rng = fx["rng"]
	# Open the OUTER window (10 damage against entity 1).
	var req = EffectRequestScript.root(
		EffectKindScript.DAMAGE, 0, 1, 10)
	req.payload = {"skip_balance": true}
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, em, sink)
	var res = EffectExecutorScript.new().execute(ctx, req)
	_assert(res.dispatch_work.size() == 1, "the outer window opened")
	var hp_start: int = int(world.current_hp_of(1))
	# Drive the outer window. Its DAMAGE_STARTED discovery finds
	# sibling A (a 5-damage window) and sibling B (a 100 heal).
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var out_sink: Array = []
	var provider = _DamageThenHeal.new()
	TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, rng, em, out_sink,
		provider, limits, session)
	_assert(provider.fired >= 1,
		"the provider saw the DAMAGE_STARTED (fired %d times)"
			% provider.fired)
	# Sibling B's heal must have seen the room that sibling A's
	# committed 5-damage created. A heal of 100 against a target
	# at 195 HP heals 5. A heal against a target at 200 HP heals
	# NOTHING (no room) — which is the contract violation.
	var heal_amounts: Array = []
	for ev in out_sink:
		if int(ev.type) == BattleEventTypeScript.HEAL_APPLIED:
			heal_amounts.append(int(ev.amount))
	_assert(heal_amounts.size() >= 1,
		"sibling B's HEAL_APPLIED was published (got %d heal(s))"
			% heal_amounts.size())
	if heal_amounts.size() >= 1:
		_assert(int(heal_amounts[0]) == 5,
			"sibling B saw sibling A's committed 5 HP of room "
			+ "(healed %d, expected 5)" % int(heal_amounts[0]))
	# The outer window's own damage committed too.
	var applied: int = 0
	for ev in out_sink:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied += 1
	_assert(applied >= 1,
		"the damage was committed (got %d DAMAGE_APPLIED)" % applied)
	var hp_end: int = int(world.current_hp_of(1))
	_assert(hp_end == hp_start - 10 - 5 + 5,
		"final HP reflects outer 10 + sibling A 5, then sibling B's 5 heal "
		+ "(HP %d -> %d, expected %d)"
			% [hp_start, hp_end, hp_start - 10])
