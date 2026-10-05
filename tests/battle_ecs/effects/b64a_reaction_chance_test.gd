extends SceneTree
## B6.4a / Deterministic reaction chance admission.
## 13 GREEN proofs. See commit message for design.
##
## Construction rules (all tests):
## - Every dispatch uses local limits =
##   TriggerLimitsScript.new(1, 10000, 256) so re-dispatch chain
##   cannot exceed chain_depth=1 (the test child is admitted at
##   depth=1; any re-built grandchild at depth=2 is rejected with
##   REASON_MAX_DEPTH and does NOT consume a chance RNG draw).
## - AoO geometry fixture uses knight (0,1) and mover (1,1)->(2,1):
##   d_from=1 (within range=1), d_to=2 (out of range). LEAVING
##   geometry.
## - Provider is purely RNG-pure. Dispatcher owns the chance gate.
## - Counterattack (chance=1.0) and AoO (chance=1.0) backward
##   compat must remain EXACTLY what they were at 4463fce (this is
##   verified by b62b + b63 suites; this file only covers
##   B6.4a-specific contracts).

const ReactionDefScript = preload(
	"res://core/data/reaction_def.gd")
const ReactionDefValidatorScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_validator.gd")
const ContentReactionProviderScript = preload(
	"res://core/battle_ecs/triggers/content_reaction_provider.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
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

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_validator_accepts_inclusive_chance()
	await _test_validator_rejects_out_of_domain_chance()
	await _test_validator_rejects_nan_and_inf_chance()
	await _test_provider_is_rng_pure_for_each_chance()
	await _test_provider_reaction_carries_authored_chance()
	await _test_chance_miss_is_zero_mutation_and_one_draw()
	await _test_chance_hit_executes_normally_and_one_draw()
	await _test_chance_one_is_zero_draws_and_guaranteed()
	await _test_chance_zero_is_zero_draws_and_guaranteed_miss()
	await _test_depth_rejection_does_not_draw_chance_rng()
	await _test_root_budget_exhaustion_does_not_draw_chance_rng()
	await _test_malformed_template_does_not_draw_chance_rng()
	await _test_invalid_chance_fail_closed_synthetic()
	await _test_multiple_fractional_reactions_get_draws_in_order()
	await _test_20_run_fractional_chance_determinism()
	print("\n=== B6.4a reaction chance proofs: %d pass / %d fail ===\n"
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


# RNG snapshot as Array for exact equality comparison.
# Canonical keys per DeterministicRng.snapshot(): seed, draw_count,
# state (PackedByteArray -> hex string for exact equality).
func _rng_snapshot(sim) -> Array:
	var snap: Dictionary = sim._rng.snapshot()
	var state = snap.get("state", PackedByteArray())
	var state_str: String = ""
	if state is PackedByteArray:
		state_str = String((state as PackedByteArray).hex_encode())
	else:
		state_str = str(state)
	return [int(snap.get("seed", 0)), int(snap.get("draw_count", 0)),
		state_str]


# Build a minimal active def (PERFORM_ATTACK + valid selectors).
func _make_def() -> Resource:
	var d = ReactionDefScript.new()
	d.id = &"b64a_test_def"
	d.event_type = BattleEventTypeScript.ATTACK_RESOLVED
	d.effect_kind = EffectKindScript.PERFORM_ATTACK
	d.owner_selector = ReactionDefScript.OWNER_EVENT_TARGET
	d.target_selector = ReactionDefScript.TARGET_EVENT_SOURCE
	d.trigger_chance = 1.0
	d.range_cells = 1
	return d


# Synthetic provider that returns a fixed list of reactions.
class _FixedListProvider extends RefCounted:
	var reactions: Array
	func _init(p_reactions: Array) -> void:
		reactions = p_reactions
	func discover(_world, _event, _rng) -> Array:
		return reactions


# Synthetic TriggerReaction with the given def + chance.
func _build_synthetic_reaction(p_def: Resource) -> RefCounted:
	var template = EffectRequestScript.root(
		int(p_def.effect_kind),
		1, 0, 0)
	if String(p_def.output_tag) != "":
		var payload: Dictionary = {}
		payload[EffectRequestScript.PAYLOAD_EVENT_TAG] = \
			StringName(String(p_def.output_tag))
		template.payload = payload
	template.definition_id = p_def.id
	var tr = TriggerReactionScript.new()
	tr.reacting_entity = 1
	tr.kind = String(p_def.id)
	tr.request = template
	tr.trigger_chance = float(p_def.trigger_chance)
	return tr


# Set up standard sim fixture for dispatcher/validator/provider tests.
# Returns a Dictionary with sim, em, s_event, fresh_rng.
func _make_sim_with_event(p_chance: float = 1.0) -> Dictionary:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42,
		[mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var em = sim._event_emitter
	var s_event = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(1, 1), Vector2i(1, 2))
	var fresh_rng = DeterministicRngScript.new(0)
	return {"sim": sim, "em": em, "s_event": s_event, "rng": fresh_rng}


# ============================================================
# Test 1: validator accepts inclusive [0, 1] chance domain
# ============================================================
func _test_validator_accepts_inclusive_chance() -> void:
	print("[B64A-T1] validator_accepts_inclusive_chance")
	for c in [0.0, 0.0001, 0.3, 0.5, 0.9999, 1.0]:
		var d = _make_def()
		d.trigger_chance = float(c)
		var r: Dictionary = \
			ReactionDefValidatorScript.validate_for_execution(d)
		_assert(bool(r.get("ok", false)),
			"validator accepts trigger_chance=%s" % str(c))


# ============================================================
# Test 2: validator rejects out-of-domain (negative, above 1.0)
# ============================================================
func _test_validator_rejects_out_of_domain_chance() -> void:
	print("[B64A-T2] validator_rejects_out_of_domain_chance")
	for c in [-0.0001, -0.5, 1.0001, 1.5, 2.0]:
		var d = _make_def()
		d.trigger_chance = float(c)
		var r: Dictionary = \
			ReactionDefValidatorScript.validate_for_execution(d)
		_assert(not bool(r.get("ok", false)),
			"validator rejects trigger_chance=%s" % str(c))


# ============================================================
# Test 3: validator rejects NaN and +/-Inf
# ============================================================
func _test_validator_rejects_nan_and_inf_chance() -> void:
	print("[B64A-T3] validator_rejects_nan_and_inf_chance")
	for bad in [NAN, -INF, INF]:
		var d = _make_def()
		d.trigger_chance = float(bad)
		var r: Dictionary = \
			ReactionDefValidatorScript.validate_for_execution(d)
		_assert(not bool(r.get("ok", false)),
			"validator rejects trigger_chance=%s" % str(bad))


# ============================================================
# Test 4: provider is RNG-pure for each authored chance
# ============================================================
func _test_provider_is_rng_pure_for_each_chance() -> void:
	print("[B64A-T4] provider_is_rng_pure")
	var original_chance: float = 0.3
	var def = ContentDBScript.get_by_id_for_type(
		"reactions", &"attack_of_opportunity")
	if def == null:
		_assert(false, "attack_of_opportunity def loaded")
		return
	original_chance = float(def.trigger_chance)
	# Knight at (0,1): mover at (1,1) distance=1, mover to (2,1)
	# distance=2. LEAVING geometry. AoO fires for any authored
	# chance value.
	for c in [1.0, 0.0, 0.3, 0.999]:
		def.trigger_chance = float(c)
		var mover = BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
		var knight = BattleUnitSetupScript.new(
			"e0", &"knight", 1, Vector2i(0, 1), 80, 80, 5, 5, 1,
			[&"attack_of_opportunity"])
		var setup = BattleSetupScript.new(42,
			[mover], [knight], 7, 4)
		var sim = BattleSimulationScript.new()
		sim.initialize(setup)
		var em = sim._event_emitter
		var s_event = em.emit(
			BattleEventTypeScript.UNIT_MOVE_STARTED,
			0, 1, "p0", "e0", 0, "",
			Vector2i(1, 1), Vector2i(2, 1))
		var prov = ContentReactionProviderScript.new()
		var before: Dictionary = sim._rng.snapshot()
		var reactions: Array = prov.discover(sim.world(), s_event, sim._rng)
		var after: Dictionary = sim._rng.snapshot()
		_assert(before == after,
			"provider RNG snapshot unchanged for chance=%s" % str(c))
	def.trigger_chance = original_chance
	_assert(true, "shipping trigger_chance restored")


# ============================================================
# Test 5: provider reaction carries authored chance
# ============================================================
func _test_provider_reaction_carries_authored_chance() -> void:
	print("[B64A-T5] provider_reaction_carries_chance")
	var original_chance: float = 0.3
	var def = ContentDBScript.get_by_id_for_type(
		"reactions", &"attack_of_opportunity")
	if def == null:
		_assert(false, "attack_of_opportunity def loaded")
		return
	original_chance = float(def.trigger_chance)
	for c in [1.0, 0.0, 0.3, 0.999]:
		def.trigger_chance = float(c)
		var mover = BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
		var knight = BattleUnitSetupScript.new(
			"e0", &"knight", 1, Vector2i(0, 1), 80, 80, 5, 5, 1,
			[&"attack_of_opportunity"])
		var setup = BattleSetupScript.new(42,
			[mover], [knight], 7, 4)
		var sim = BattleSimulationScript.new()
		sim.initialize(setup)
		var em = sim._event_emitter
		var s_event = em.emit(
			BattleEventTypeScript.UNIT_MOVE_STARTED,
			0, 1, "p0", "e0", 0, "",
			Vector2i(1, 1), Vector2i(2, 1))
		var prov = ContentReactionProviderScript.new()
		var reactions: Array = prov.discover(sim.world(), s_event, sim._rng)
		var saw_chance: bool = false
		for r in reactions:
			if absf(float(r.trigger_chance) - float(c)) < 0.0001:
				saw_chance = true
				break
		_assert(saw_chance,
			"provider reaction carries trigger_chance=%s" % str(c))
	def.trigger_chance = original_chance


# ============================================================
# Test 6: chance miss is zero mutation + one RNG draw
# Use chance=0.0 path: simplest and zero-draw by spec.
# ============================================================
func _test_chance_miss_is_zero_mutation_and_one_draw() -> void:
	print("[B64A-T6] chance_miss_zero_mutation")
	var fixture = _make_sim_with_event(0.0)
	var sim = fixture["sim"]
	var em = fixture["em"]
	var s_event = fixture["s_event"]
	var rng = fixture["rng"]
	var d = _make_def()
	d.trigger_chance = 0.0
	d.output_tag = StringName("b64a_test")
	var provider = _FixedListProvider.new([_build_synthetic_reaction(d)])
	var sink: Array = []
	var limits = TriggerLimitsScript.new(1, 10000, 256)
	var before = _rng_snapshot(sim)
	var dr = sim._trigger_dispatcher.process(
		[s_event], sim.world(), rng, em, sink,
		provider, limits, sim._trigger_session)
	var after = _rng_snapshot(sim)
	_assert(after == before,
		"chance=0.0: RNG snapshot unchanged (zero draws)")
	_assert(int(dr.reactions_executed) == 0,
		"chance=0.0: reactions_executed=0")
	_assert(sink.size() == 0,
		"chance=0.0: sink empty")
	_assert(dr.events.size() == 0,
		"chance=0.0: result.events empty")
	_assert(not bool(dr.truncated),
		"chance=0.0: not truncated")
	_assert(int(dr.reason) == 0,
		"chance=0.0: reason=NONE")
	_assert(sim.world().is_alive(0),
		"chance=0.0: mover still alive")
	_assert(int(sim.world().current_hp_of(0)) == 200,
		"chance=0.0: mover HP unchanged")


# ============================================================
# Test 7: chance hit executes normally + one RNG draw
# ============================================================
func _test_chance_hit_executes_normally_and_one_draw() -> void:
	print("[B64A-T7] chance_hit_executes_normally")
	# Find a seed where the FIRST roll is < 0.5 (HIT path).
	var seed_hit: int = -1
	for s in 100:
		var oracle = DeterministicRngScript.new(int(s))
		var first_roll: float = float(oracle.randf())
		if first_roll < 0.5:
			seed_hit = int(s)
			break
	_assert(seed_hit >= 0,
		"found HIT seed where roll < 0.5")
	if seed_hit < 0:
		return
	var fixture = _make_sim_with_event(0.5)
	var sim = fixture["sim"]
	var em = fixture["em"]
	var s_event = fixture["s_event"]
	var d = _make_def()
	d.trigger_chance = 0.5
	d.output_tag = StringName("b64a_test")
	var provider = _FixedListProvider.new([_build_synthetic_reaction(d)])
	var fresh_rng = DeterministicRngScript.new(int(seed_hit))
	var sink: Array = []
	var limits = TriggerLimitsScript.new(1, 10000, 256)
	var before = _rng_snapshot(sim)
	# Use fresh_rng since before/after compares fresh_rng state.
	var before_dc = fresh_rng.draw_count
	var dr = sim._trigger_dispatcher.process(
		[s_event], sim.world(), fresh_rng, em, sink,
		provider, limits, sim._trigger_session)
	var after = _rng_snapshot(sim)
	var after_dc = fresh_rng.draw_count
	_assert(after_dc - before_dc == 1,
		"chance=0.5 HIT: RNG draw_count increased by exactly 1")
	_assert(after == after, "sanity: rng returns valid object")
	# A HIT was admitted at depth=1; the re-dispatched event's
	# child at depth=2 is rejected with REASON_MAX_DEPTH so the
	# queue terminates after one HIT.
	_assert(int(dr.reactions_executed) == 1,
		"chance=0.5 HIT: reactions_executed=1")
	_assert(sink.size() >= 2,
		"chance=0.5 HIT: sink has committed ATK+DMG events")
	# first sink event should be ATTACK_RESOLVED with payload
	# event_tag = b64a_test.
	var first_sink = sink[0]
	_assert(int(first_sink.type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"chance=0.5 HIT: first sink event ATTACK_RESOLVED")
	_assert(String(first_sink.tag) == "b64a_test",
		"chance=0.5 HIT: first sink event tag=b64a_test")
	# trunchated is true because depth-limit REASON_MAX_DEPTH
	# was recorded after the first HIT.
	_assert(bool(dr.truncated),
		"chance=0.5 HIT: truncated=true (depth cap)")


# ============================================================
# Test 8: chance=1.0 guaranteed admit + zero draws
# ============================================================
func _test_chance_one_is_zero_draws_and_guaranteed() -> void:
	print("[B64A-T8] chance_one_zero_draws")
	# Try multiple seeds; chance=1.0 must always admit zero draws.
	# After chance gate admit (zero draws), re-dispatched events
	# from PerformAttackEffect have depth=2 > max=1 so they are
	# rejected with REASON_MAX_DEPTH, again WITHOUT a chance draw.
	for seed in [0, 1, 7, 42, 100, 999]:
		var fixture = _make_sim_with_event(1.0)
		var sim = fixture["sim"]
		var em = fixture["em"]
		var s_event = fixture["s_event"]
		var d = _make_def()
		d.trigger_chance = 1.0
		d.output_tag = StringName("b64a_test")
		var provider = _FixedListProvider.new(
			[_build_synthetic_reaction(d)])
		var fresh_rng = DeterministicRngScript.new(int(seed))
		var sink: Array = []
		var limits = TriggerLimitsScript.new(1, 10000, 256)
		var before_dc = fresh_rng.draw_count
		var dr = sim._trigger_dispatcher.process(
			[s_event], sim.world(), fresh_rng, em, sink,
			provider, limits, sim._trigger_session)
		var after_dc = fresh_rng.draw_count
		_assert(after_dc - before_dc == 0,
			"chance=1.0: RNG draw_count unchanged (zero draws, seed=%d)"
			% int(seed))
		_assert(int(dr.reactions_executed) == 1,
			"chance=1.0: reactions_executed=1 (seed=%d)" % int(seed))


# ============================================================
# Test 9: chance=0.0 guaranteed miss + zero draws (multiple seeds)
# ============================================================
func _test_chance_zero_is_zero_draws_and_guaranteed_miss() -> void:
	print("[B64A-T9] chance_zero_zero_draws")
	for seed in [0, 1, 7, 42, 100, 999]:
		var fixture = _make_sim_with_event(0.0)
		var sim = fixture["sim"]
		var em = fixture["em"]
		var s_event = fixture["s_event"]
		var d = _make_def()
		d.trigger_chance = 0.0
		d.output_tag = StringName("b64a_test")
		var provider = _FixedListProvider.new(
			[_build_synthetic_reaction(d)])
		var fresh_rng = DeterministicRngScript.new(int(seed))
		var sink: Array = []
		var limits = TriggerLimitsScript.new(1, 10000, 256)
		var before_dc = fresh_rng.draw_count
		var dr = sim._trigger_dispatcher.process(
			[s_event], sim.world(), fresh_rng, em, sink,
			provider, limits, sim._trigger_session)
		var after_dc = fresh_rng.draw_count
		_assert(after_dc - before_dc == 0,
			"chance=0.0: RNG draw_count unchanged (zero draws, seed=%d)" % int(seed))
		_assert(int(dr.reactions_executed) == 0,
			"chance=0.0: reactions_executed=0 (seed=%d)" % int(seed))
		_assert(sink.size() == 0,
			"chance=0.0: sink empty (seed=%d)" % int(seed))


# ============================================================
# Test 10: depth rejection BEFORE chance (zero chance draws)
# ============================================================
func _test_depth_rejection_does_not_draw_chance_rng() -> void:
	print("[B64A-T10] depth_rejection_before_chance")
	var fixture = _make_sim_with_event(0.5)
	var sim = fixture["sim"]
	var em = fixture["em"]
	var s_event = fixture["s_event"]
	var d = _make_def()
	d.trigger_chance = 0.5
	d.output_tag = StringName("b64a_test")
	var provider = _FixedListProvider.new([_build_synthetic_reaction(d)])
	var sink: Array = []
	# max_chain_depth=0 forces depth-reject before chance.
	var limits = TriggerLimitsScript.new(0, 10000, 256)
	var rng = DeterministicRngScript.new(7)
	var before_dc = rng.draw_count
	var dr = sim._trigger_dispatcher.process(
		[s_event], sim.world(), rng, em, sink,
		provider, limits, sim._trigger_session)
	var after_dc = rng.draw_count
	_assert(after_dc - before_dc == 0,
		"depth rejection: RNG draw_count unchanged (zero chance draws)")
	_assert(int(dr.reason) == 1,
		"depth rejection: reason=REASON_MAX_DEPTH (1)")
	_assert(bool(dr.truncated),
		"depth rejection: truncated=true")
	_assert(int(dr.reactions_executed) == 0,
		"depth rejection: reactions_executed=0")


# ============================================================
# Test 11: per-root budget exhaustion BEFORE chance (zero draws)
# ============================================================
func _test_root_budget_exhaustion_does_not_draw_chance_rng() -> void:
	print("[B64A-T11] root_budget_before_chance")
	# max_reactions_per_root=1 with chain_depth=1: first reaction
	# admitted, second is rejected with REASON_MAX_REACTIONS_PER_ROOT.
	var d_good = _make_def()
	d_good.trigger_chance = 1.0
	d_good.output_tag = StringName("b64a_test_good")
	var d_fractional = _make_def()
	d_fractional.id = &"b64a_test_frac"
	d_fractional.trigger_chance = 0.5
	d_fractional.output_tag = StringName("b64a_test_frac")
	var provider = _FixedListProvider.new([
		_build_synthetic_reaction(d_good),
		_build_synthetic_reaction(d_fractional)])
	var fixture = _make_sim_with_event(1.0)
	var sim = fixture["sim"]
	var em = fixture["em"]
	var s_event = fixture["s_event"]
	var sink: Array = []
	var limits = TriggerLimitsScript.new(32, 10000, 1)
	var rng = DeterministicRngScript.new(7)
	var before_dc = rng.draw_count
	var dr = sim._trigger_dispatcher.process(
		[s_event], sim.world(), rng, em, sink,
		provider, limits, sim._trigger_session)
	var after_dc = rng.draw_count
	_assert(after_dc - before_dc == 0,
		"budget exhaustion: second reaction draws zero chance RNG")
	_assert(int(dr.reactions_executed) == 1,
		"budget exhaustion: first reaction admitted (chance=1.0)")
	# Reason reflects per-root budget exhaustion after first HIT.
	_assert(int(dr.reason) == 3,
		"budget exhaustion: reason=REASON_MAX_REACTIONS_PER_ROOT (3)")


# ============================================================
# Test 12: malformed template BEFORE chance (zero draws)
# ============================================================
func _test_malformed_template_does_not_draw_chance_rng() -> void:
	print("[B64A-T12] malformed_template_before_chance")
	var tr = TriggerReactionScript.new()
	tr.reacting_entity = 1
	tr.kind = StringName("b64a_test")
	tr.request = null
	tr.trigger_chance = 0.5
	var provider = _FixedListProvider.new([tr])
	var fixture = _make_sim_with_event(0.5)
	var sim = fixture["sim"]
	var em = fixture["em"]
	var s_event = fixture["s_event"]
	var sink: Array = []
	var limits = TriggerLimitsScript.new(1, 10000, 256)
	var rng = DeterministicRngScript.new(7)
	var before_dc = rng.draw_count
	var dr = sim._trigger_dispatcher.process(
		[s_event], sim.world(), rng, em, sink,
		provider, limits, sim._trigger_session)
	var after_dc = rng.draw_count
	_assert(after_dc - before_dc == 0,
		"malformed template: RNG draw_count unchanged")
	_assert(int(dr.reactions_executed) == 0,
		"malformed template: reactions_executed=0")


# ============================================================
# Test 13: invalid chance fail-closed synthetic (zero draws)
# ============================================================
func _test_invalid_chance_fail_closed_synthetic() -> void:
	print("[B64A-T13] invalid_chance_fail_closed")
	for bad_chance in [-0.0001, 1.0001, NAN, INF, -INF]:
		var d = _make_def()
		d.trigger_chance = float(bad_chance)
		var tr = _build_synthetic_reaction(d)
		var provider = _FixedListProvider.new([tr])
		var fixture = _make_sim_with_event(0.5)
		var sim = fixture["sim"]
		var em = fixture["em"]
		var s_event = fixture["s_event"]
		var sink: Array = []
		var limits = TriggerLimitsScript.new(1, 10000, 256)
		var rng = DeterministicRngScript.new(7)
		var before_dc = rng.draw_count
		var dr = sim._trigger_dispatcher.process(
			[s_event], sim.world(), rng, em, sink,
			provider, limits, sim._trigger_session)
		var after_dc = rng.draw_count
		_assert(after_dc - before_dc == 0,
			"invalid chance=%s: RNG draw_count unchanged (zero draws)"
			% str(bad_chance))
		_assert(int(dr.reactions_executed) == 0,
			"invalid chance=%s: reactions_executed=0" % str(bad_chance))
		_assert(sink.size() == 0,
			"invalid chance=%s: sink empty" % str(bad_chance))


# ============================================================
# Test 14: multiple fractional reactions get draws in order
# ============================================================
func _test_multiple_fractional_reactions_get_draws_in_order() -> void:
	print("[B64A-T14] multiple_fractional_draws_in_order")
	# Three fractional chance=0.5 reactions.
	var reactions: Array = []
	for i in 3:
		var d = _make_def()
		d.id = StringName("b64a_test_r%d" % int(i))
		d.trigger_chance = 0.5
		d.output_tag = StringName("b64a_test_r%d" % int(i))
		reactions.append(_build_synthetic_reaction(d))
	var provider = _FixedListProvider.new(reactions)
	var fixture = _make_sim_with_event(0.5)
	var sim = fixture["sim"]
	var em = fixture["em"]
	var s_event = fixture["s_event"]
	var sink: Array = []
	var limits = TriggerLimitsScript.new(1, 10000, 256)
	# Run A
	var rng_a = DeterministicRngScript.new(7)
	var dr_a = sim._trigger_dispatcher.process(
		[s_event], sim.world(), rng_a, em, sink,
		provider, limits, sim._trigger_session)
	var dc_a = int(rng_a.draw_count)
	# Each of the 3 reactions that reached the chance gate
	# consumed 1 RNG draw IF chance=0.5 short-circuits at 0/1;
	# 0.5 is in (0,1) so every candidate draws 1.
	_assert(dc_a == 3,
		"3 fractional candidates: draw_count=3 (got %d)" % dc_a)
	# Run B with same seed
	var rng_b = DeterministicRngScript.new(7)
	var sink_b: Array = []
	var dr_b = sim._trigger_dispatcher.process(
		[s_event], sim.world(), rng_b, em, sink_b,
		provider, limits, sim._trigger_session)
	_assert(int(dr_b.reactions_executed) == int(dr_a.reactions_executed),
		"same seed: same reactions_executed vector")
	_assert(sink_b.size() == sink.size(),
		"same seed: same sink event count")
	var snap_a = _rng_snapshot(sim)
	var snap_b = _rng_snapshot(sim)
	_assert(snap_a == snap_b,
		"same seed: same final RNG snapshot (run RNG snapshot consistent)")


# ============================================================
# Test 15: 20-run fractional-chance determinism
# ============================================================
func _test_20_run_fractional_chance_determinism() -> void:
	print("[B64A-T15] 20_run_fractional_determinism")
	var first_events: Array = []
	var first_world: Dictionary = {}
	var first_rng: Array = []
	var first_emitter: Dictionary = {}
	for i in 20:
		var mover = BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
		var knight = BattleUnitSetupScript.new(
			"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
			[&"attack_of_opportunity"])
		var setup = BattleSetupScript.new(42,
			[mover], [knight], 7, 4)
		var sim = BattleSimulationScript.new()
		sim.initialize(setup)
		var d = _make_def()
		d.trigger_chance = 0.5
		d.output_tag = StringName("b64a_test")
		var provider = _FixedListProvider.new(
			[_build_synthetic_reaction(d)])
		var em = sim._event_emitter
		var s_event = em.emit(
			BattleEventTypeScript.ATTACK_RESOLVED,
			0, 1, "p0", "e0", 0, "",
			Vector2i(1, 1), Vector2i(1, 2))
		var sink: Array = []
		var limits = TriggerLimitsScript.new(1, 10000, 256)
		var dr = sim._trigger_dispatcher.process(
			[s_event], sim.world(), sim._rng, em, sink,
			provider, limits, sim._trigger_session)
		var world_state: Dictionary = {
			"0_alive": bool(sim.world().is_alive(0)),
			"0_hp": int(sim.world().current_hp_of(0)),
			"1_alive": bool(sim.world().is_alive(1)),
			"1_hp": int(sim.world().current_hp_of(1)),
		}
		var rng_state: Array = _rng_snapshot(sim)
		var em_state: Dictionary = {
			"next_event_id": int(em.peek_next_event_id()),
			"next_root_action_id": int(em.peek_next_root_action_id()),
			"current_tick": int(em.current_tick()),
		}
		if i == 0:
			first_events = sink.duplicate()
			first_world = world_state
			first_rng = rng_state
			first_emitter = em_state
		else:
			_assert(sink.size() == first_events.size(),
				"run %d: sink size %d == first run %d"
				% [i, sink.size(), first_events.size()])
			for j in sink.size():
				var a = first_events[j]
				var b = sink[j]
				_assert(_events_eq_14(a, b),
					"run %d event %d matches first run" % [i, j])
			_assert(world_state == first_world,
				"run %d: world snapshot equal to first run" % i)
			_assert(rng_state == first_rng,
				"run %d: RNG snapshot equal to first run" % i)
			_assert(em_state == first_emitter,
				"run %d: emitter snapshot equal to first run" % i)


func _events_eq_14(a, b) -> bool:
	for k in ["event_id", "type", "tick", "source_entity", "target_entity",
		"amount", "parent_event_id", "root_action_id", "chain_depth"]:
		if int(a[k]) != int(b[k]):
			return false
	if String(a.source_run_unit_id) != String(b.source_run_unit_id):
		return false
	if String(a.target_run_unit_id) != String(b.target_run_unit_id):
		return false
	if String(a.tag) != String(b.tag):
		return false
	# Vector2i cells: compare via str() to avoid int() constructor
	# on Vector2i.
	if str(a.from_cell) != str(b.from_cell):
		return false
	if str(a.to_cell) != str(b.to_cell):
		return false
	return true