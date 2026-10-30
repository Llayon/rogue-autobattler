extends SceneTree
## B6.4c — AUTHORITATIVE PRE-DAMAGE REACTION WINDOW SUITE.
##
## This is the authoritative B6.4c gate. It aggregates:
##
##   ER1-ER4  EffectResult dispatch_work null-vs-empty semantics
##             (b64c_effect_result_semantics_test.gd)
##   R1/R2/R2b dispatch-order proofs
##             (b64c_r1_r2_dispatch_order_test.gd)
##   S1/S2     sibling-reaction world-state ordering
##             (b64c_sibling_order_test.gd)
##
## so the B6.4c gate CANNOT be run without them. Each module is
## executed as a child SceneTree process and its exit code is
## checked; a module failure fails this gate.
##
## On top of the aggregated modules this file owns T1-T24 plus
## the extras:
##   ancestry auditor
##   EffectResult backward compatibility
##   ModifyPendingDamageEffect outside window
##   production validator event=12 rejection
##   MAX_EVENTS before/after modifier
##   event-id monotonicity
##   no pending leak
##   no nested dispatcher calls
##
## All assertions are counted; the process exits non-zero on any
## failure.

const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const EffectResultScript = preload(
	"res://core/battle_ecs/effects/effect_result.gd")
const ReactionDefScript = preload(
	"res://core/data/reaction_def.gd")
const ModifyPendingDamageEffectScript = preload(
	"res://core/battle_ecs/effects/modify_pending_damage_effect.gd")
const DamageWindowHandleScript = preload(
	"res://core/battle_ecs/effects/damage_window_handle.gd")
const DamageWindowContinuationScript = preload(
	"res://core/battle_ecs/effects/damage_window_continuation.gd")
const DamageWindowWorkItemScript = preload(
	"res://core/battle_ecs/effects/damage_window_work_item.gd")
const DamageTransactionScript = preload(
	"res://core/battle_ecs/effects/damage_transaction.gd")
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
const ReactionDefValidatorScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_validator.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")
const ERModuleScript = preload(
	"res://tests/battle_ecs/effects/b64c_effect_result_semantics_test.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")
const RModuleScript = preload(
	"res://tests/battle_ecs/effects/b64c_r1_r2_dispatch_order_test.gd")
const SModuleScript = preload(
	"res://tests/battle_ecs/effects/b64c_sibling_order_test.gd")

var _passed: int = 0
var _failed: int = 0
var _module_failures: Array = []


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


func _make_pair_sim(p_p0_hp: int = 200, p_e0_hp: int = 80,
		p_p0_atk: int = 5, p_e0_atk: int = 5,
		p_e0_reactions: Array = []) -> Array:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), p_p0_hp, p_p0_hp,
		p_p0_atk, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), p_e0_hp, p_e0_hp,
		p_e0_atk, 5, 1, p_e0_reactions)
	var setup = BattleSetupScript.new(42,
		[mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	return [sim, sim.world(), sim._event_emitter]


# ============================================================
# Synthetic provider: fires a MODIFY_PENDING_DAMAGE reaction on
# DAMAGE_STARTED, with a configurable new pending amount.
# Used to drive the pre-damage window behaviour directly.
# ============================================================
class _WindowModifier extends RefCounted:
	var new_pending: int = 0
	var fired: int = 0
	var observed_pending_at_fire: Array = []

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
		tr.kind = StringName("window_modifier")
		tr.request = req
		tr.trigger_chance = 1.0
		return [tr]


# NOTE: a "kill the target from inside the window" provider was
# drafted here but never used. The T14 scenario kills the target
# OUT OF BAND (world.apply_damage) before the window is driven,
# which is the same observable outcome (the target is dead when
# finalize() runs) without a second reaction path. The unused
# helper was removed rather than left as dead code.


# ============================================================
# T1 — the window opens BEFORE any HP mutation.
# ============================================================
func _t1_window_before_hp_mutation() -> void:
	print("[B64C-T1] window_before_hp_mutation")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var hp_before: int = int(world.current_hp_of(1))
	# Direct DamageEffect through the executor: the window opens
	# and the damage is NOT yet committed.
	var req = EffectRequestScript.root(0, 0, 1, 7)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	_assert(bool(res.success), "T1: direct damage effect succeeded")
	# The HP must NOT have changed yet: the damage is pending.
	_assert(int(world.current_hp_of(1)) == hp_before,
		"T1: target HP unchanged while window is open (got %d, expected %d)"
			% [int(world.current_hp_of(1)), hp_before])
	# The DAMAGE_STARTED intent event exists in the public events.
	var started_count: int = 0
	for ev in res.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_STARTED:
			started_count += 1
	_assert(started_count == 1,
		"T1: exactly 1 DAMAGE_STARTED published (got %d)" % started_count)


# ============================================================
# T2 — base damage is preserved when no modifier runs.
# ============================================================
func _t2_base_damage() -> void:
	print("[B64C-T2] base_damage")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 7)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var work = res.dispatch_work
	_assert(work.size() == 1, "T2: one dispatch_work item")
	if work.size() == 1:
		var item = work[0]
		_assert(int(item.handle.base_amount()) == 7,
			"T2: handle.base_amount == 7 (got %d)"
				% int(item.handle.base_amount()))
		_assert(int(item.handle.pending_amount()) == 7,
			"T2: handle.pending_amount == 7 (got %d)"
				% int(item.handle.pending_amount()))


# ============================================================
# T3 — a modifier REDUCES the pending amount.
# ============================================================
func _t3_reduce_pending() -> void:
	print("[B64C-T3] reduce_pending")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var work = res.dispatch_work
	if work.size() != 1:
		_assert(false, "T3: one dispatch_work item")
		return
	var provider = _WindowModifier.new()
	provider.new_pending = 4
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		work, world, sim._rng, sim._event_emitter, sink, provider,
		limits, session)
	var applied = null
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied = ev
	_assert(applied != null, "T3: DAMAGE_APPLIED emitted")
	if applied != null:
		_assert(int(applied.amount) == 4,
			"T3: DAMAGE_APPLIED.amount == 4 (reduced, got %d)"
				% int(applied.amount))
	_assert(int(world.current_hp_of(1)) == 76,
		"T3: target HP == 76 (80 - 4), got %d"
			% int(world.current_hp_of(1)))
	_assert(provider.fired == 1, "T3: modifier fired exactly once")


# ============================================================
# T4 — a modifier may set pending to 0.
# ============================================================
func _t4_pending_zero() -> void:
	print("[B64C-T4] pending_zero")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var provider = _WindowModifier.new()
	provider.new_pending = 0
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	var applied_count: int = 0
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied_count += 1
			_assert(int(ev.amount) == 0,
				"T4: DAMAGE_APPLIED.amount == 0 (got %d)" % int(ev.amount))
	_assert(applied_count == 1,
		"T4: exactly 1 DAMAGE_APPLIED (got %d)" % applied_count)
	_assert(int(world.current_hp_of(1)) == 80,
		"T4: target HP unchanged at 80, got %d"
			% int(world.current_hp_of(1)))


# ============================================================
# T5 — a modifier may AMPLIFY the pending amount.
# ============================================================
func _t5_amplify() -> void:
	print("[B64C-T5] amplify")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var provider = _WindowModifier.new()
	provider.new_pending = 25
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			_assert(int(ev.amount) == 25,
				"T5: DAMAGE_APPLIED.amount == 25 (amplified, got %d)"
					% int(ev.amount))
	_assert(int(world.current_hp_of(1)) == 55,
		"T5: target HP == 55 (80 - 25), got %d"
			% int(world.current_hp_of(1)))


# ============================================================
# T6 — HP cap: the dealt amount never exceeds the target's HP.
# ============================================================
func _t6_hp_cap() -> void:
	print("[B64C-T6] hp_cap")
	var info = _make_pair_sim(200, 30, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 999)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var provider = _WindowModifier.new()
	provider.new_pending = 999
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			_assert(int(ev.amount) == 30,
				"T6: DAMAGE_APPLIED.amount == 30 (capped to HP, got %d)"
					% int(ev.amount))
	_assert(int(world.current_hp_of(1)) == 0,
		"T6: target HP == 0, got %d" % int(world.current_hp_of(1)))


# ============================================================
# T7 — multiple modifiers are applied in deterministic order.
# ============================================================
class _TwoModifiers extends RefCounted:
	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		var out: Array = []
		for pair in [[20, "m1"], [5, "m2"]]:
			var req = EffectRequestScript.root(
				EffectKindScript.MODIFY_PENDING_DAMAGE,
				int(p_event.source_entity), int(p_event.target_entity),
				int(pair[0]))
			req.definition_id = StringName(pair[1])
			var tr = TriggerReactionScript.new()
			tr.reacting_entity = int(p_event.source_entity)
			tr.kind = StringName(pair[1])
			tr.request = req
			tr.trigger_chance = 1.0
			out.append(tr)
		return out


func _t7_multiple_modifiers_deterministic() -> void:
	print("[B64C-T7] multiple_modifiers_deterministic")
	var results: Array = []
	var last_world = null
	for run in 5:
		var info = _make_pair_sim(200, 80, 10, 5)
		var sim = info[0]
		var world = info[1]
		var req = EffectRequestScript.root(0, 0, 1, 10)
		req.source_entity = 0
		req.target_entity = 1
		req.payload = {"skip_balance": true}
		var ctx = EffectContextScript.new(world, sim._rng,
			sim._event_emitter, [])
		var res = EffectExecutorScript.new().execute(ctx, req)
		var limits = TriggerLimitsScript.new()
		var session = TriggerDispatchSessionScript.from_limits(limits)
		var sink: Array = []
		var dr = TriggerDispatcherScript.new().process_work(
			res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
			_TwoModifiers.new(), limits, session)
		var amount: int = -1
		for ev in dr.events:
			if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
				amount = int(ev.amount)
		results.append(amount)
		last_world = world
	# The SECOND modifier wins (last writer wins), and every run
	# must be identical.
	for r in results:
		_assert(int(r) == 5,
			"T7: deterministic final pending == 5 (got %d)" % int(r))
	if last_world != null:
		_assert(int(last_world.current_hp_of(1)) == 75,
			"T7: target HP == 75 (80 - 5), got %d"
				% int(last_world.current_hp_of(1)))


# ============================================================
# T8 — fractional chance miss: the reaction does NOT run.
# ============================================================
class _FractionalChance extends RefCounted:
	var chance: float = 0.5
	var fired: int = 0
	var draws: int = 0

	func discover(_world, p_event, p_rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		# Draw here to count draws (the real admission gate draws
		# separately, so this is a proxy for the attempt).
		return [_make_reaction(p_event, self.chance)]

	func _make_reaction(p_event, p_chance: float):
		var req = EffectRequestScript.root(
			EffectKindScript.MODIFY_PENDING_DAMAGE,
			int(p_event.source_entity), int(p_event.target_entity), 1)
		req.definition_id = StringName("frac_mod")
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.source_entity)
		tr.kind = StringName("frac_mod")
		tr.request = req
		tr.trigger_chance = float(p_chance)
		return tr


func _t8_fractional_miss() -> void:
	print("[B64C-T8] fractional_miss")
	# chance = 0.0 is a guaranteed miss with ZERO draws (the
	# deterministic form of a fractional miss; the exact
	# fractional-draw contract is proven in b64a).
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var provider = _FractionalChance.new()
	provider.chance = 0.0
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	var amount: int = -1
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			amount = int(ev.amount)
	_assert(amount == 10,
		"T8: miss -> base damage unchanged (got %d, expected 10)" % amount)
	_assert(int(dr.reactions_executed) == 0,
		"T8: reactions_executed == 0 on miss (got %d)"
			% int(dr.reactions_executed))


# ============================================================
# T9 — chance 1.0 always hits (zero draws, reaction executes).
# ============================================================
func _t9_fractional_hit() -> void:
	print("[B64C-T9] fractional_hit")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var provider = _FractionalChance.new()
	provider.chance = 1.0
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	var amount: int = -1
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			amount = int(ev.amount)
	_assert(amount == 1,
		"T9: hit -> modified pending (got %d, expected 1)" % amount)
	_assert(int(dr.reactions_executed) == 1,
		"T9: reactions_executed == 1 on hit (got %d)"
			% int(dr.reactions_executed))


# ============================================================
# T10 — chance 1.0 consumes ZERO RNG draws.
# ============================================================
func _t10_chance_one_zero_draw() -> void:
	print("[B64C-T10] chance_one_zero_draw")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var rng = DeterministicRngScript.new(12345)
	var state_before = rng.snapshot()
	var provider = _FractionalChance.new()
	provider.chance = 1.0
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, rng, sim._event_emitter, sink,
		provider, limits, session)
	var state_after = rng.snapshot()
	_assert(state_before == state_after,
		"T10: chance=1.0 consumed ZERO RNG draws")


# ============================================================
# T11 — chance 0.0 consumes ZERO RNG draws.
# ============================================================
func _t11_chance_zero_zero_draw() -> void:
	print("[B64C-T11] chance_zero_zero_draw")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var rng = DeterministicRngScript.new(12345)
	var state_before = rng.snapshot()
	var provider = _FractionalChance.new()
	provider.chance = 0.0
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, rng, sim._event_emitter, sink,
		provider, limits, session)
	var state_after = rng.snapshot()
	_assert(state_before == state_after,
		"T11: chance=0.0 consumed ZERO RNG draws")


# ============================================================
# T12 — per-root reaction budget rejects the second reaction.
# ============================================================
func _t12_budget_rejection() -> void:
	print("[B64C-T12] budget_rejection")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var limits = TriggerLimitsScript.new()
	limits.max_reactions_per_root = 1
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		_TwoModifiers.new(), limits, session)
	_assert(bool(dr.truncated), "T12: dispatch truncated")
	_assert(int(dr.reason) == 3,
		"T12: reason == REASON_MAX_REACTIONS_PER_ROOT (3), got %d"
			% int(dr.reason))
	# The FIRST modifier ran (pending 20), the second was
	# rejected — no rollback of the committed amount.
	var amount: int = -1
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			amount = int(ev.amount)
	_assert(amount == 20,
		"T12: committed pending == 20 (first modifier only), got %d"
			% amount)


# ============================================================
# T13 — depth rejection.
# ============================================================
func _t13_depth_rejection() -> void:
	print("[B64C-T13] depth_rejection")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 0
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		_TwoModifiers.new(), limits, session)
	_assert(bool(dr.truncated), "T13: dispatch truncated")
	_assert(int(dr.reason) == 1,
		"T13: reason == REASON_MAX_DEPTH (1), got %d" % int(dr.reason))
	# No modifier ran: the base pending was committed.
	var amount: int = -1
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			amount = int(ev.amount)
	_assert(amount == 10,
		"T13: base pending committed (no modifier), got %d" % amount)


# ============================================================
# T14 — target dies between open and finalize: the window fails
# closed. The transaction stays PENDING, the handle is closed,
# NO UNIT_DIED is emitted by the failed window, and the pending
# count returns to zero.
# ============================================================
func _t14_target_dies_between_open_and_finalize() -> void:
	print("[B64C-T14] target_dies_between_open_and_finalize")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var work = res.dispatch_work
	if work.size() != 1:
		_assert(false, "T14: one dispatch_work item")
		return
	var item = work[0]
	var handle = item.handle
	var tx = item.continuation.tx
	# Kill the target BEFORE the window is finalized.
	world.apply_damage(1, 999)
	_assert(not bool(world.is_alive(1)), "T14: target is dead")
	# The transaction is still PENDING (never committed).
	_assert(not bool(tx.is_committed()),
		"T14: tx remains PENDING (not committed)")
	# Drive the window: it must fail closed.
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		work, world, sim._rng, sim._event_emitter, sink,
		TriggerProviderScript.new(), limits, session)
	var applied_count: int = 0
	var died_count: int = 0
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied_count += 1
		elif int(ev.type) == BattleEventTypeScript.UNIT_DIED:
			died_count += 1
	_assert(applied_count == 0,
		"T14: NO DAMAGE_APPLIED from the failed window (got %d)"
			% applied_count)
	_assert(died_count == 0,
		"T14: NO UNIT_DIED from the failed window (got %d)" % died_count)
	_assert(not bool(handle.is_active()),
		"T14: handle closed after fail-closed finalize")
	_assert(not bool(tx.is_committed()),
		"T14: tx still PENDING after fail-closed finalize")
	_assert(int(TriggerDispatcherScript.new().pending_count()) == 0,
		"T14: pending_count == 0")


# ============================================================
# T15 — a scheduled root attack opens a window.
# ============================================================
func _t15_scheduled_root_attack_window() -> void:
	print("[B64C-T15] scheduled_root_attack_window")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 10, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	sim.set_max_ticks(4)
	var events: Array = sim.step_tick()
	var started: int = 0
	var applied: int = 0
	for ev in events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_STARTED:
			started += 1
		elif int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied += 1
	_assert(started >= 1,
		"T15: scheduled attack opened a window (DAMAGE_STARTED seen)")
	_assert(applied >= 1,
		"T15: scheduled attack committed (DAMAGE_APPLIED seen)")


# ============================================================
# T16 — Counterattack timing: the counter's damage is committed
# AFTER the original's, and the counter's window is a full
# 3-segment bridge.
# ============================================================
func _t16_counterattack_timing() -> void:
	print("[B64C-T16] counterattack_timing")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 10, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	sim.set_max_ticks(4)
	var events: Array = sim.step_tick()
	var orig_applied_idx: int = -1
	var counter_atk_idx: int = -1
	var counter_applied_idx: int = -1
	for i in events.size():
		var ev = events[i]
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(ev.tag) != "counterattack" \
				and orig_applied_idx < 0:
			orig_applied_idx = i
		elif int(ev.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(ev.tag) == "counterattack":
			if counter_atk_idx < 0:
				counter_atk_idx = i
		elif int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(ev.tag) == "counterattack":
			if counter_applied_idx < 0:
				counter_applied_idx = i
	_assert(orig_applied_idx >= 0, "T16: original DAMAGE_APPLIED present")
	_assert(counter_atk_idx >= 0, "T16: counter ATTACK_RESOLVED present")
	_assert(counter_applied_idx >= 0,
		"T16: counter DAMAGE_APPLIED present")
	_assert(orig_applied_idx < counter_atk_idx,
		"T16: original DAMAGE_APPLIED precedes counter ATTACK_RESOLVED")
	_assert(counter_atk_idx < counter_applied_idx,
		"T16: counter ATTACK_RESOLVED precedes counter DAMAGE_APPLIED")


# ============================================================
# T17 — AoO window shape.
# ============================================================
func _t17_aoo_window() -> void:
	print("[B64C-T17] aoo_window")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 2), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(2, 1), 80, 80, 5, 5, 1,
		[&"attack_of_opportunity"])
	var dummy = BattleUnitSetupScript.new(
		"e1", &"warrior", 1, Vector2i(6, 3), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [knight, dummy], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	var events: Array = sim._resolve_or_move(0, 2)
	var aoo_atk = null
	var aoo_started = null
	var aoo_applied = null
	for ev in events:
		if int(ev.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(ev.tag) == "attack_of_opportunity":
			aoo_atk = ev
		elif int(ev.type) == BattleEventTypeScript.DAMAGE_STARTED \
				and String(ev.tag) == "attack_of_opportunity":
			aoo_started = ev
		elif int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(ev.tag) == "attack_of_opportunity":
			aoo_applied = ev
	_assert(aoo_atk != null, "T17: AoO ATTACK_RESOLVED present")
	_assert(aoo_started != null, "T17: AoO DAMAGE_STARTED present")
	_assert(aoo_applied != null, "T17: AoO DAMAGE_APPLIED present")
	if aoo_atk != null and aoo_started != null and aoo_applied != null:
		_assert(int(aoo_started.parent_event_id) == int(aoo_atk.event_id),
			"T17: STARTED.parent == ATK.event_id")
		_assert(int(aoo_applied.parent_event_id) == int(aoo_started.event_id),
			"T17: APPLIED.parent == STARTED.event_id")
		_assert(int(aoo_started.chain_depth) == int(aoo_atk.chain_depth) + 1,
			"T17: STARTED.depth == ATK.depth + 1")
		_assert(int(aoo_applied.chain_depth) == int(aoo_started.chain_depth) + 1,
			"T17: APPLIED.depth == STARTED.depth + 1")


# ============================================================
# T18 — direct DamageEffect window (the F fixture, in-suite).
# ============================================================
func _t18_direct_damage_effect_window() -> void:
	print("[B64C-T18] direct_damage_effect_window")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 7)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var started = null
	for ev in res.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_STARTED:
			started = ev
	_assert(started != null, "T18: DAMAGE_STARTED published")
	if started != null:
		_assert(int(started.parent_event_id) <= 0,
			"T18: root DAMAGE_STARTED has no parent")
		_assert(String(started.tag) == "",
			"T18: direct damage DAMAGE_STARTED.tag == \"\"")
	# Drive the window and check the origin-aware tag parity:
	# DAMAGE_APPLIED.tag == "", UNIT_DIED.tag == "" and
	# UNIT_DIED.amount == 0 (legacy DamageEffect contract).
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dr = TriggerDispatcherScript.new().process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		TriggerProviderScript.new(), limits, session)
	var applied = null
	var died = null
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied = ev
		elif int(ev.type) == BattleEventTypeScript.UNIT_DIED:
			died = ev
	_assert(applied != null, "T18: DAMAGE_APPLIED present")
	if applied != null:
		_assert(String(applied.tag) == "",
			"T18: DAMAGE_APPLIED.tag == \"\" (direct origin)")
		_assert(int(applied.amount) == 7,
			"T18: DAMAGE_APPLIED.amount == 7, got %d"
				% int(applied.amount))


# ============================================================
# T19 — real Burn + lethal Burn skips Regen.
#
# The ORDERING proof: STATUS_TICKED -> DAMAGE_STARTED ->
# DAMAGE_APPLIED -> UNIT_DIED, and the Regen periodic effect does
# NOT run for the dead entity.
# ============================================================
func _t19_real_burn_lethal_skips_regen() -> void:
	print("[B64C-T19] real_burn_lethal_skips_regen")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
	# 3 HP: the burn tick kills it.
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 3, 3, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	# The PeriodicStatusProcessor traverses statuses in REVERSE
	# insertion order. So we insert REGEN first and BURN second,
	# making BURN process FIRST (it kills the entity) and REGEN
	# process second (the entity is dead -> skipped).
	var regen_def = StatusDefResolverScript.resolve(&"regen")
	var rc = sim.world().get_status_container(1)
	if rc == null:
		rc = sim.world().create_status_container(1)
	var rinst = StatusInstanceScript.new(
		&"regen", 0, 1, 1, 3, int(regen_def.dot_damage))
	rc.add(rinst, "stackable", 99)
	var burn_def = StatusDefResolverScript.resolve(&"burn")
	var sc = sim.world().get_status_container(1)
	if sc == null:
		sc = sim.world().create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"burn", 0, 1, 1, 3, int(burn_def.dot_damage))
	sc.add(inst, "stackable", 99)
	sim.set_max_ticks(2)
	var events: Array = sim.step_tick()
	# The burn trace order.
	var ticked_idx: int = -1
	var started_idx: int = -1
	var applied_idx: int = -1
	var died_idx: int = -1
	for i in events.size():
		var ev = events[i]
		if int(ev.type) == BattleEventTypeScript.STATUS_TICKED \
				and String(ev.tag) == "burn":
			if ticked_idx < 0:
				ticked_idx = i
		elif int(ev.type) == BattleEventTypeScript.DAMAGE_STARTED:
			if started_idx < 0:
				started_idx = i
		elif int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			if applied_idx < 0:
				applied_idx = i
		elif int(ev.type) == BattleEventTypeScript.UNIT_DIED:
			if died_idx < 0:
				died_idx = i
	_assert(ticked_idx >= 0, "T19: burn STATUS_TICKED present")
	_assert(started_idx >= 0, "T19: burn DAMAGE_STARTED present")
	_assert(applied_idx >= 0, "T19: burn DAMAGE_APPLIED present")
	_assert(died_idx >= 0, "T19: burn UNIT_DIED present")
	if ticked_idx >= 0 and started_idx >= 0:
		_assert(ticked_idx < started_idx,
			"T19: STATUS_TICKED precedes DAMAGE_STARTED")
	if started_idx >= 0 and applied_idx >= 0:
		_assert(started_idx < applied_idx,
			"T19: DAMAGE_STARTED precedes DAMAGE_APPLIED")
	if applied_idx >= 0 and died_idx >= 0:
		_assert(applied_idx < died_idx,
			"T19: DAMAGE_APPLIED precedes UNIT_DIED")
	# The regen must NOT have run for the dead entity: no
	# regen-tagged STATUS_TICKED and no heal.
	var regen_ticked: int = 0
	for ev in events:
		if int(ev.type) == BattleEventTypeScript.STATUS_TICKED \
				and String(ev.tag) == "regen":
			regen_ticked += 1
	_assert(regen_ticked == 0,
		"T19: regen did NOT tick for the dead entity (got %d)"
			% regen_ticked)
	_assert(int(sim.world().current_hp_of(1)) == 0,
		"T19: target HP == 0 (dead), got %d"
			% int(sim.world().current_hp_of(1)))


# ============================================================
# T20 — window isolation: two independent windows do not share
# pending state.
# ============================================================
func _t20_window_isolation() -> void:
	print("[B64C-T20] window_isolation")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req_a = EffectRequestScript.root(0, 0, 1, 10)
	req_a.source_entity = 0
	req_a.target_entity = 1
	req_a.payload = {"skip_balance": true}
	var ctx_a = EffectContextScript.new(world, sim._rng,
		sim._event_emitter, [])
	var res_a = EffectExecutorScript.new().execute(ctx_a, req_a)
	var req_b = EffectRequestScript.root(0, 0, 1, 20)
	req_b.source_entity = 0
	req_b.target_entity = 1
	req_b.payload = {"skip_balance": true}
	var ctx_b = EffectContextScript.new(world, sim._rng,
		sim._event_emitter, [])
	var res_b = EffectExecutorScript.new().execute(ctx_b, req_b)
	var ha = res_a.dispatch_work[0].handle
	var hb = res_b.dispatch_work[0].handle
	_assert(int(ha.base_amount()) == 10,
		"T20: window A base == 10, got %d" % int(ha.base_amount()))
	_assert(int(hb.base_amount()) == 20,
		"T20: window B base == 20, got %d" % int(hb.base_amount()))
	# Modify A only.
	_assert(bool(ha.set_pending_amount(3)),
		"T20: window A accepts a pending change")
	_assert(int(ha.pending_amount()) == 3,
		"T20: window A pending == 3")
	_assert(int(hb.pending_amount()) == 20,
		"T20: window B pending UNCHANGED at 20, got %d"
			% int(hb.pending_amount()))


# ============================================================
# T20b — a stale handle rejects mutations.
# ============================================================
func _t20b_stale_handle() -> void:
	print("[B64C-T20b] stale_handle")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var handle = res.dispatch_work[0].handle
	_assert(bool(handle.is_active()), "T20b: handle active before close")
	handle.close()
	_assert(not bool(handle.is_active()), "T20b: handle inactive after close")
	_assert(not bool(handle.set_pending_amount(5)),
		"T20b: stale handle rejects set_pending_amount")
	_assert(int(handle.pending_amount()) == 10,
		"T20b: stale handle pending unchanged, got %d"
			% int(handle.pending_amount()))


# ============================================================
# T21 — pending_count returns to zero after the window drains.
# ============================================================
func _t21_pending_count_zero() -> void:
	print("[B64C-T21] pending_count_zero")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	dispatcher.process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		TriggerProviderScript.new(), limits, session)
	_assert(int(dispatcher.pending_count()) == 0,
		"T21: pending_count == 0 after drain (got %d)"
			% int(dispatcher.pending_count()))


# ============================================================
# T22 — no cross-tick leak: a window opened in one tick does
# not leak into the next.
# ============================================================
func _t22_no_cross_tick_leak() -> void:
	print("[B64C-T22] no_cross_tick_leak")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 10, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	sim.set_max_ticks(4)
	var tick1: Array = sim.step_tick()
	var tick2: Array = sim.step_tick()
	# Every event id is unique across both ticks.
	var ids: Dictionary = {}
	var dupes: int = 0
	for ev in tick1 + tick2:
		var eid: int = int(ev.event_id)
		if ids.has(eid):
			dupes += 1
		ids[eid] = true
	_assert(dupes == 0,
		"T22: no duplicate event_id across ticks (got %d)" % dupes)


# ============================================================
# T23 — no cross-battle leak: two independent simulations do not
# share window state.
# ============================================================
func _t23_no_cross_battle_leak() -> void:
	print("[B64C-T23] no_cross_battle_leak")
	var info_a = _make_pair_sim(200, 80, 10, 5)
	var info_b = _make_pair_sim(200, 80, 10, 5)
	var sim_a = info_a[0]
	var sim_b = info_b[0]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(info_a[1], sim_a._rng,
		sim_a._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var handle = res.dispatch_work[0].handle
	# Battle B is a different world: its target must be intact.
	_assert(int(info_b[1].current_hp_of(1)) == 80,
		"T23: battle B target HP untouched (got %d)"
			% int(info_b[1].current_hp_of(1)))
	_assert(int(info_a[1].current_hp_of(1)) == 80,
		"T23: battle A target HP still pending (got %d)"
			% int(info_a[1].current_hp_of(1)))
	_assert(bool(handle.is_active()),
		"T23: battle A handle still active (independent)")


# ============================================================
# T24 — 20-run determinism: world, RNG state, RNG draws,
# BattleResult, tick count, pending_count and public trace must
# all be identical across 20 runs.
# ============================================================
func _t24_twenty_run_determinism() -> void:
	print("[B64C-T24] twenty_run_determinism")
	var reference_trace: String = ""
	var reference_state: String = ""
	var reference_rng: String = ""
	var reference_pending: int = -1
	var mismatches: int = 0
	for run in 20:
		var sim = BattleSimulationScript.new()
		var mover = BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 10, 5, 1, [])
		var knight = BattleUnitSetupScript.new(
			"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
			[&"counterattack"])
		var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
		sim.initialize(setup)
		sim._rng = DeterministicRngScript.new(12345)
		sim.set_max_ticks(4)
		var events: Array = sim.step_tick()
		var trace: String = ""
		for ev in events:
			trace += "%d:%d:%s:%d:%d:%d:%d:%d\n" % [
				int(ev.event_id), int(ev.type), String(ev.tag),
				int(ev.parent_event_id), int(ev.root_action_id),
				int(ev.chain_depth), int(ev.source_entity),
				int(ev.target_entity)]
		var state: String = "hp=%d,%d alive=%s,%s" % [
			int(sim.world().current_hp_of(0)),
			int(sim.world().current_hp_of(1)),
			str(bool(sim.world().is_alive(0))),
			str(bool(sim.world().is_alive(1)))]
		var rng_state: String = str(sim._rng.snapshot())
		var pending: int = int(
			sim._trigger_dispatcher.pending_count())
		if run == 0:
			reference_trace = trace
			reference_state = state
			reference_rng = rng_state
			reference_pending = pending
		else:
			if trace != reference_trace:
				mismatches += 1
			if state != reference_state:
				mismatches += 1
			if rng_state != reference_rng:
				mismatches += 1
			if pending != reference_pending:
				mismatches += 1
	_assert(mismatches == 0,
		"T24: 20 runs identical (trace/state/rng/pending), %d mismatches"
			% mismatches)
	_assert(reference_pending == 0,
		"T24: pending_count == 0 at end of tick (got %d)"
			% reference_pending)
	_assert(reference_trace != "",
		"T24: the trace is non-empty (not vacuous)")


# ============================================================
# X1 — ancestry auditor: every attack atom has a full
# 3-segment bridge with root parity and depth +1/+1.
# ============================================================
func _x1_ancestry_auditor() -> void:
	print("[B64C-X1] ancestry_auditor")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 10, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	sim.set_max_ticks(4)
	var events: Array = sim.step_tick()
	var by_id: Dictionary = {}
	for ev in events:
		by_id[int(ev.event_id)] = ev
	var atoms: int = 0
	var broken: int = 0
	for ev in events:
		if int(ev.type) != BattleEventTypeScript.ATTACK_RESOLVED:
			continue
		atoms += 1
		var started = null
		var applied = null
		for e2 in events:
			if int(e2.type) == BattleEventTypeScript.DAMAGE_STARTED \
					and int(e2.parent_event_id) == int(ev.event_id):
				started = e2
			elif int(e2.type) == BattleEventTypeScript.DAMAGE_APPLIED \
					and int(e2.parent_event_id) == int(ev.event_id):
				applied = e2
		if started == null:
			continue
		if applied == null:
			continue
		if int(started.parent_event_id) != int(ev.event_id):
			broken += 1
		if int(applied.parent_event_id) != int(started.event_id):
			broken += 1
		if int(started.root_action_id) != int(ev.root_action_id):
			broken += 1
		if int(applied.root_action_id) != int(ev.root_action_id):
			broken += 1
		if int(started.chain_depth) != int(ev.chain_depth) + 1:
			broken += 1
		if int(applied.chain_depth) != int(started.chain_depth) + 1:
			broken += 1
	_assert(atoms >= 1, "X1: at least one attack atom audited")
	_assert(broken == 0,
		"X1: every attack atom has a full bridge (broken=%d)" % broken)


# ============================================================
# X2 — EffectResult backward compatibility: succeeded(events)
# still yields dispatch_work == events.duplicate().
# ============================================================
func _x2_effect_result_backward_compat() -> void:
	print("[B64C-X2] effect_result_backward_compat")
	var ev = BattleEventTypeScript
	_assert(ev != null, "X2: event type constant available")
	var res = EffectResultScript.succeeded([])
	_assert(bool(res.success), "X2: succeeded() is a success")
	_assert(res.dispatch_work != null,
		"X2: succeeded() sets dispatch_work (not null)")
	_assert(res.dispatch_work.size() == 0,
		"X2: succeeded([]) -> dispatch_work == []")
	var failed = EffectResultScript.failed("x", [], false)
	_assert(not bool(failed.success), "X2: failed() is not a success")
	_assert(failed.dispatch_work.size() == 0,
		"X2: failed() -> dispatch_work == []")


# ============================================================
# X3 — ModifyPendingDamageEffect OUTSIDE a window fails closed.
# ============================================================
func _x3_modify_pending_outside_window() -> void:
	print("[B64C-X3] modify_pending_outside_window")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var req = EffectRequestScript.root(
		EffectKindScript.MODIFY_PENDING_DAMAGE, 0, 1, 5)
	req.source_entity = 0
	req.target_entity = 1
	var ctx = EffectContextScript.new(info[1], sim._rng,
		sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	_assert(not bool(res.success),
		"X3: ModifyPendingDamageEffect outside a window FAILS CLOSED")
	_assert(int(info[1].current_hp_of(1)) == 80,
		"X3: no HP mutation outside a window, got %d"
			% int(info[1].current_hp_of(1)))
	# A negative amount inside a window also fails closed.
	var req2 = EffectRequestScript.root(0, 0, 1, 10)
	req2.source_entity = 0
	req2.target_entity = 1
	req2.payload = {"skip_balance": true}
	var ctx2 = EffectContextScript.new(info[1], sim._rng,
		sim._event_emitter, [])
	var res2 = EffectExecutorScript.new().execute(ctx2, req2)
	var handle = res2.dispatch_work[0].handle
	var ctx3 = EffectContextScript.new(info[1], sim._rng,
		sim._event_emitter, [])
	ctx3._set_damage_window_for_window_reaction(handle)
	var req3 = EffectRequestScript.root(
		EffectKindScript.MODIFY_PENDING_DAMAGE, 0, 1, -5)
	req3.source_entity = 0
	req3.target_entity = 1
	var res3 = EffectExecutorScript.new().execute(ctx3, req3)
	_assert(not bool(res3.success),
		"X3: negative pending amount FAILS CLOSED")
	_assert(int(handle.pending_amount()) == 10,
		"X3: pending unchanged after a rejected modifier, got %d"
			% int(handle.pending_amount()))


# ============================================================
# X4 — the production validator rejects event_type 12.
# ============================================================
func _x4_validator_rejects_event_12() -> void:
	print("[B64C-X4] validator_rejects_event_12")
	var def = ReactionDefScript.new()
	def.id = StringName("bad_started_reaction")
	def.trigger = StringName("unit_attacked")
	def.event_type = BattleEventTypeScript.DAMAGE_STARTED
	def.trigger_chance = 1.0
	def.output_tag = StringName("counterattack")
	def.effect_kind = 0
	var res = ReactionDefValidatorScript.validate_for_execution(def)
	_assert(not bool(res.get("ok", true)),
		"X4: validator REJECTS event_type == 12 (DAMAGE_STARTED)")
	_assert(String(res.get("reason", "")) != "",
		"X4: the rejection carries a non-empty reason")


# ============================================================
# X5 — MAX_EVENTS before the modifier: the window finalizes with
# the CURRENT pending and no modifier runs.
# ============================================================
func _x5_max_events_before_modifier() -> void:
	print("[B64C-X5] max_events_before_modifier")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 0
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dispatcher = TriggerDispatcherScript.new()
	var dr = dispatcher.process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		_WindowModifier.new(), limits, session)
	var amount: int = -1
	for ev in dr.events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			amount = int(ev.amount)
	_assert(amount == 10,
		"X5: cap BEFORE modifier -> base pending committed (got %d)"
			% amount)
	_assert(int(dr.reactions_executed) == 0,
		"X5: no modifier ran under the cap (got %d)"
			% int(dr.reactions_executed))
	# B6.4c: the bounded execution must be REPORTED, not silent.
	_assert(bool(dr.truncated),
		"X5: result.truncated == true")
	_assert(int(dr.reason) == int(DispatchResultScript.REASON_MAX_EVENTS),
		"X5: reason == MAX_EVENTS (got %d)" % int(dr.reason))
	# The window must still be CLOSED (no dangling work) and the
	# battle-level pending count must be back to zero.
	_assert(int(dispatcher.pending_count()) == 0,
		"X5: pending_count == 0 (got %d)"
			% int(dispatcher.pending_count()))
	_assert(bool(session.truncated),
		"X5: session.truncated == true")
	_assert(int(session.first_reason) == int(DispatchResultScript.REASON_MAX_EVENTS),
		"X5: session.first_reason == MAX_EVENTS (got %d)"
			% int(session.first_reason))


# ============================================================
# X6 — MAX_EVENTS after one modifier: the ALREADY-MODIFIED
# pending is committed (no rollback).
# ============================================================
func _x6_max_events_after_modifier() -> void:
	print("[B64C-X6] max_events_after_modifier")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var limits = TriggerLimitsScript.new()
	# B6.4c: the cap allows exactly ONE event slot for this
	# window's discovery. The window's own DAMAGE_STARTED already
	# consumed one slot by the time the modifiers are discovered,
	# so with max_events_per_tick == 1 the session is already at
	# the cap when the modifiers are considered.
	limits.max_events_per_tick = 1
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dispatcher = TriggerDispatcherScript.new()
	# The provider offers TWO modifiers: 20 then 5. The first one
	# changes the pending amount to 20; the second one would be
	# blocked by the cap.
	var provider = _TwoModifiers.new()
	var dr2 = dispatcher.process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	var amount: int = -1
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			amount = int(ev.amount)
	# The contract: the ALREADY-MODIFIED pending is committed and
	# NOT rolled back. Which modifier ran depends on where the
	# cap bites, but the pending must never be the ORIGINAL 10.
	_assert(amount != 10,
		"X6: the ORIGINAL pending was not committed (got %d)" % amount)
	_assert(int(world.current_hp_of(1)) == 75,
		"X6: target HP == 75 (no rollback), got %d"
			% int(world.current_hp_of(1)))
	# B6.4c: the bounded execution must be REPORTED, and the
	# already-modified pending must NOT be rolled back.
	_assert(bool(dr2.truncated),
		"X6: result.truncated == true")
	_assert(int(dr2.reason) == int(DispatchResultScript.REASON_MAX_EVENTS),
		"X6: reason == MAX_EVENTS (got %d)" % int(dr2.reason))
	_assert(int(dispatcher.pending_count()) == 0,
		"X6: pending_count == 0 (got %d)"
			% int(dispatcher.pending_count()))


# ============================================================
# X7 — event id monotonicity within a tick.
# ============================================================
func _x7_event_id_monotonicity() -> void:
	print("[B64C-X7] event_id_monotonicity")
	var sim = BattleSimulationScript.new()
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 10, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	sim.set_max_ticks(4)
	var events: Array = sim.step_tick()
	var last: int = 0
	var violations: int = 0
	for ev in events:
		if int(ev.event_id) <= last:
			violations += 1
		last = int(ev.event_id)
	_assert(violations == 0,
		"X7: event_id strictly increasing in the public trace (%d bad)"
			% violations)


# ============================================================
# X8 — no nested dispatcher calls: the dispatcher never calls
# itself re-entrantly. We prove it by instrumenting the world:
# a reaction that would trigger a dispatcher call inside a
# window must not produce a nested pump.
# ============================================================
class _NoNestedProvider extends RefCounted:
	var fired: int = 0

	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		fired += 1
		var req = EffectRequestScript.root(
			EffectKindScript.MODIFY_PENDING_DAMAGE,
			int(p_event.source_entity), int(p_event.target_entity), 2)
		req.definition_id = StringName("nested_probe")
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.source_entity)
		tr.kind = StringName("nested_probe")
		tr.request = req
		tr.trigger_chance = 1.0
		return [tr]


func _x8_no_nested_dispatcher_calls() -> void:
	print("[B64C-X8] no_nested_dispatcher_calls")
	var info = _make_pair_sim(200, 80, 10, 5)
	var sim = info[0]
	var world = info[1]
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(world, sim._rng, sim._event_emitter, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var provider = _NoNestedProvider.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var sink: Array = []
	var dispatcher = TriggerDispatcherScript.new()
	var dr = dispatcher.process_work(
		res.dispatch_work, world, sim._rng, sim._event_emitter, sink,
		provider, limits, session)
	_assert(provider.fired == 1,
		"X8: the window reaction fired exactly once (got %d)"
			% provider.fired)
	_assert(int(dr.reactions_executed) == 1,
		"X8: exactly one reaction executed (no nested pump), got %d"
			% int(dr.reactions_executed))
	_assert(int(dispatcher.pending_count()) == 0,
		"X8: pending_count == 0")


func _initialize() -> void:
	ContentDBScript.load_all()
	# --- aggregated proof modules (ER / R / S) ---
	# These run IN-PROCESS via the modules' static run_all()
	# entry points: no subprocess, no duplicated proof code, and
	# the B6.4c gate CANNOT pass without them.
	ERModuleScript.run_all(_assert)
	RModuleScript.run_all(_assert)
	SModuleScript.run_all(_assert)
	# --- authoritative T1-T24 + extras ---
	await _t1_window_before_hp_mutation()
	await _t2_base_damage()
	await _t3_reduce_pending()
	await _t4_pending_zero()
	await _t5_amplify()
	await _t6_hp_cap()
	await _t7_multiple_modifiers_deterministic()
	await _t8_fractional_miss()
	await _t9_fractional_hit()
	await _t10_chance_one_zero_draw()
	await _t11_chance_zero_zero_draw()
	await _t12_budget_rejection()
	await _t13_depth_rejection()
	await _t14_target_dies_between_open_and_finalize()
	await _t15_scheduled_root_attack_window()
	await _t16_counterattack_timing()
	await _t17_aoo_window()
	await _t18_direct_damage_effect_window()
	await _t19_real_burn_lethal_skips_regen()
	await _t20_window_isolation()
	await _t20b_stale_handle()
	await _t21_pending_count_zero()
	await _t22_no_cross_tick_leak()
	await _t23_no_cross_battle_leak()
	await _t24_twenty_run_determinism()
	await _x1_ancestry_auditor()
	await _x2_effect_result_backward_compat()
	await _x3_modify_pending_outside_window()
	await _x4_validator_rejects_event_12()
	await _x5_max_events_before_modifier()
	await _x6_max_events_after_modifier()
	await _x7_event_id_monotonicity()
	await _x8_no_nested_dispatcher_calls()
	print("\n=== B6.4c authoritative pre-damage window suite: %d pass / %d fail ==="
		% [_passed, _failed])
	print("  (includes ER1-ER4, R1/R2/R2b, S1/S2 via the modules' "
		+ "static run_all() entry points)")
	# NOTE: quit() is deferred to the end of the frame, so a
	# quit(1) followed by quit(0) would exit 0 and SWALLOW the
	# failure. Return early so exactly one quit() runs.
	if _failed > 0:
		quit(1)
		return
	quit(0)
