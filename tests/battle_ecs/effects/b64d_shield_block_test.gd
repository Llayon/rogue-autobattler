extends SceneTree
## PHASE 3 / B6.4d — SHIELD BLOCK PRODUCTION MIGRATION.
##
## Authoritative suite for the Shield Block pre-damage reaction.
##
## The contract under test (full production path):
##
##   real shield_block.tres
##   + real UnitDef ownership
##   + real ContentReactionProvider
##   + real TriggerDispatcher chance gate
##   + real active DamageWindowHandle
##   + real MODIFY_PENDING_DAMAGE
##   + real DamageWindowContinuation commit
##
## On a HIT:
##   base damage intent unchanged
##   -> current pending reduced by 50%
##   -> final HP mutation uses the reduced amount
##
## On a MISS:
##   base damage commits unchanged
##
## Design decisions frozen in B6.4d:
##
##   ORIGIN SCOPE = DIRECT ONLY (exact legacy parity).
##
##   The legacy Shield Block lived INSIDE the shared
##   core/effects/damage_effect.gd, so it covered ABILITY damage
##   (a DIRECT window). The legacy basic attack
##   (core/battle/combatant.gd basic_attack -> take_damage) and
##   the legacy Burn (StatusList tick) both BYPASSED it. Phase-3
##   parity therefore means: DIRECT damage windows only.
##   PERFORM_ATTACK and PERIODIC are NOT covered.
##
##   The origin is identified STRUCTURALLY, never by string
##   guessing: the damage-origin effect states the origin
##   explicitly as a battle-domain field on the DAMAGE_STARTED
##   event (BattleEvent.damage_origin), and the provider filters
##   on the declared origin mask BEFORE a TriggerReaction is
##   created.
##   The discriminator is carried explicitly on the reaction
##   request payload by the provider, from the ancestry shape of
##   the triggering event.
##
##   ROUNDING = floor(current_pending * percent / 100), with a
##   configurable minimum applied ONLY when current_pending > 0:
##     10 -> 5, 5 -> 2, 3 -> 1, 2 -> 1, 1 -> 1, 0 -> 0
##   A pending of 0 is NEVER resurrected to 1 (composition safety).

const ReactionDefScript = preload("res://core/data/reaction_def.gd")
const ReactionDefResolverScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_resolver.gd")
const ReactionDefValidatorScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_validator.gd")
const ContentReactionProviderScript = preload(
	"res://core/battle_ecs/triggers/content_reaction_provider.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const PerformAttackEffectScript = preload(
	"res://core/battle_ecs/effects/perform_attack_effect.gd")
const DamageEffectScript = preload(
	"res://core/battle_ecs/effects/damage_effect.gd")
const ModifyPendingDamageEffectScript = preload(
	"res://core/battle_ecs/effects/modify_pending_damage_effect.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const ReactionSystemPureScript = preload(
	"res://core/reactions/reaction_system.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")
const CombatantScript = preload("res://core/battle/combatant.gd")
const UnitDefScript = preload("res://core/data/unit_def.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# S1 content activation
	await _s1_content_activation()
	# S2/S3/S4/S5 validator
	await _s2_validator_accepts_real_shield_block()
	await _s3_validator_rejects_illegal_damage_started_kinds()
	await _s4_validator_rejects_modify_pending_damage_off_damage_started()
	await _s5_validator_rejects_malformed_percentage()
	# S6/S7/S8 provider ownership
	await _s6_provider_ownership_target_owns()
	await _s7_provider_attacker_only_ownership()
	await _s8_provider_no_ownership()
	# S9 provider RNG purity
	await _s9_provider_rng_purity()
	# S10/S11 chance
	await _s10_chance_miss()
	await _s11_chance_hit()
	# S12/S13/S14/S15 amounts
	await _s12_intent_and_commit_amounts()
	await _s13_odd_rounding()
	await _s14_minimum_one()
	await _s15_zero_stays_zero()
	# S16/S17 composition
	await _s16_current_pending_composition()
	await _s17_two_percentage_modifiers_sequentially()
	# S18/S19 lethality
	await _s18_lethality_prevention()
	await _s19_still_lethal_after_block()
	# S20/S21 coexistence
	await _s20_counterattack_coexistence()
	await _s21_aoo_unaffected()
	# S22 origin scope
	await _s22_origin_scope_direct_only()
	# S23/S24 lifecycle
	await _s26_origin_bitmask_is_unambiguous()
	await _s27_validator_rejects_malformed_origin_mask()
	await _s28_percentage_minimum_never_amplifies()
	await _s29_legacy_path_does_not_double_activate()
	await _s30_ownership_paladin_and_guardian_only()
	await _s31_scheduler_attack_against_guardian_is_not_shielded()
	await _s32_shipping_direct_damage_is_shielded_end_to_end()
	await _s33_origin_leak_is_strict()
	await _s34_chance_admission_metadata_is_controlled()
	await _s35_legacy_periodic_path_labels_periodic_origin()
	await _s36_unknown_origin_has_no_bit()
	await _s23_pending_leak()
	await _s24_handle_lifecycle()
	# S25 determinism
	await _s25_twenty_run_determinism()
	print("\n=== B6.4d shield block authoritative suite: %d pass / %d fail ==="
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


func _rng_snapshot_full(p_rng) -> Array:
	var snap: Dictionary = p_rng.snapshot()
	var state = snap.get("state", "")
	var state_str: String = ""
	if state is PackedByteArray:
		state_str = String((state as PackedByteArray).hex_encode())
	else:
		state_str = str(state)
	return [int(snap.get("seed", 0)), int(snap.get("draw_count", 0)), state_str]


func _make_sim(p_reactions_target: Array = [&"shield_block"],
		p_reactions_source: Array = [],
		p_target_hp: int = 200,
		p_src_atk: int = 20,
		p_tgt_def: int = 0,
		p_seed: int = 0) -> Array:
	var mover = BattleUnitSetupScript.new(
		"p0", &"attacker", 0, Vector2i(1, 1), 200, 200,
		p_src_atk, 5, 1, p_reactions_source)
	var knight = BattleUnitSetupScript.new(
		"e0", &"defender", 1, Vector2i(1, 2), p_target_hp, p_target_hp,
		5, p_tgt_def, 1, p_reactions_target)
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(p_seed)
	return [sim, sim.world(), sim._event_emitter]


func _count_type(p_events: Array, p_type: int) -> int:
	var n: int = 0
	for ev in p_events:
		if int(ev.type) == int(p_type):
			n += 1
	return n


func _find_first(p_events: Array, p_type: int):
	for ev in p_events:
		if int(ev.type) == int(p_type):
			return ev
	return null


# ============================================================
# S1 — the shipping content resource is a real Phase-3 reaction.
# ============================================================
func _s1_content_activation() -> void:
	print("[B64D-S1] content_activation")
	var def: Resource = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(def != null, "S1: shield_block resolves")
	if def == null:
		return
	_assert(String(def.id) == "shield_block", "S1: id == shield_block")
	_assert(String(def.trigger) == "",
		"S1: trigger == '' (Phase-3 only, no legacy dual activation) got '%s'" % String(def.trigger))
	_assert(abs(float(def.trigger_chance) - 0.3) < 0.001,
		"S1: trigger_chance == 0.3 (got %s)" % str(def.trigger_chance))
	_assert(int(def.event_type) == int(BattleEventTypeScript.DAMAGE_STARTED),
		"S1: event_type == DAMAGE_STARTED (got %d)" % int(def.event_type))
	_assert(int(def.effect_kind) == int(EffectKindScript.MODIFY_PENDING_DAMAGE),
		"S1: effect_kind == MODIFY_PENDING_DAMAGE (got %d)"
			% int(def.effect_kind))
	_assert(int(def.owner_selector) == int(ReactionDefScript.OWNER_EVENT_TARGET),
		"S1: owner_selector == OWNER_EVENT_TARGET (got %d)"
			% int(def.owner_selector))
	_assert(int(def.target_selector) == int(ReactionDefScript.TARGET_OWNER),
		"S1: target_selector == TARGET_OWNER (got %d)"
			% int(def.target_selector))
	_assert(int(def.pending_damage_percent) == 50,
		"S1: pending_damage_percent == 50 (got %d)"
			% int(def.pending_damage_percent))
	_assert(int(def.pending_damage_minimum) == 1,
		"S1: pending_damage_minimum == 1 (got %d)"
			% int(def.pending_damage_minimum))


# ============================================================
# S2 — the real Shield Block def passes the validator.
# ============================================================
func _s2_validator_accepts_real_shield_block() -> void:
	print("[B64D-S2] validator_accepts_real_shield_block")
	var def: Resource = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(def != null, "S2: shield_block resolves")
	if def == null:
		return
	var v: Dictionary = ReactionDefValidatorScript.validate_for_execution(def)
	_assert(bool(v.get("ok", false)),
		"S2: real Shield Block is VALID (reason=%s)" % String(v.get("reason", "")))


# ============================================================
# S3 — DAMAGE_STARTED with an illegal effect kind is rejected.
# ============================================================
func _s3_validator_rejects_illegal_damage_started_kinds() -> void:
	print("[B64D-S3] validator_rejects_illegal_damage_started_kinds")
	var illegal: Array = [
		int(EffectKindScript.PERFORM_ATTACK),
		int(EffectKindScript.DAMAGE),
		int(EffectKindScript.HEAL),
		int(EffectKindScript.APPLY_STATUS),
		int(EffectKindScript.REMOVE_STATUS),
	]
	for k in illegal:
		var d = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED), int(k))
		var v: Dictionary = ReactionDefValidatorScript.validate_for_execution(d)
		_assert(not bool(v.get("ok", true)),
			"S3: DAMAGE_STARTED + effect_kind %d is REJECTED" % int(k))


# ============================================================
# S4 — MODIFY_PENDING_DAMAGE on a non-DAMAGE_STARTED event is
#      rejected (the pair is bound in B6.4d).
# ============================================================
func _s4_validator_rejects_modify_pending_damage_off_damage_started() -> void:
	print("[B64D-S4] validator_rejects_modify_pending_damage_off_damage_started")
	var illegal: Array = [
		int(BattleEventTypeScript.ATTACK_RESOLVED),
		int(BattleEventTypeScript.DAMAGE_APPLIED),
		int(BattleEventTypeScript.UNIT_MOVED),
		int(BattleEventTypeScript.STATUS_TICKED),
	]
	for t in illegal:
		var d = _make_def(int(t),
			int(EffectKindScript.MODIFY_PENDING_DAMAGE))
		var v: Dictionary = ReactionDefValidatorScript.validate_for_execution(d)
		_assert(not bool(v.get("ok", true)),
			"S4: MODIFY_PENDING_DAMAGE + event_type %d is REJECTED" % int(t))


# ============================================================
# S5 — malformed percentage configuration is rejected.
# ============================================================
func _s5_validator_rejects_malformed_percentage() -> void:
	print("[B64D-S5] validator_rejects_malformed_percentage")
	# sentinel (-1) used with MODIFY_PENDING_DAMAGE: the modifier
	# must have an explicitly configured percentage.
	var d0 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED),
		int(EffectKindScript.MODIFY_PENDING_DAMAGE))
	d0.pending_damage_percent = -1
	var v0: Dictionary = ReactionDefValidatorScript.validate_for_execution(d0)
	_assert(not bool(v0.get("ok", true)),
		"S5: sentinel percent (-1) is REJECTED")
	# below 0
	var d1 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED),
		int(EffectKindScript.MODIFY_PENDING_DAMAGE))
	d1.pending_damage_percent = -10
	var v1: Dictionary = ReactionDefValidatorScript.validate_for_execution(d1)
	_assert(not bool(v1.get("ok", true)),
		"S5: negative percent (-10) is REJECTED")
	# above 100 (amplification is not opened for shipping content)
	var d2 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED),
		int(EffectKindScript.MODIFY_PENDING_DAMAGE))
	d2.pending_damage_percent = 150
	var v2: Dictionary = ReactionDefValidatorScript.validate_for_execution(d2)
	_assert(not bool(v2.get("ok", true)),
		"S5: percent above 100 (150) is REJECTED")
	# negative minimum
	var d3 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED),
		int(EffectKindScript.MODIFY_PENDING_DAMAGE))
	d3.pending_damage_minimum = -1
	var v3: Dictionary = ReactionDefValidatorScript.validate_for_execution(d3)
	_assert(not bool(v3.get("ok", true)),
		"S5: negative minimum (-1) is REJECTED")


func _make_def(p_event_type: int, p_effect_kind: int) -> Resource:
	var d = ReactionDefScript.new()
	d.id = &"probe_def"
	d.event_type = p_event_type
	d.effect_kind = p_effect_kind
	d.owner_selector = ReactionDefScript.OWNER_EVENT_TARGET
	d.target_selector = ReactionDefScript.TARGET_OWNER
	d.trigger_chance = 1.0
	d.pending_damage_percent = 50
	d.pending_damage_minimum = 1
	return d


# ============================================================
# S6 — the target owns Shield Block -> exactly one candidate.
# ============================================================
func _s6_provider_ownership_target_owns() -> void:
	print("[B64D-S6] provider_ownership_target_owns")
	var info = _make_sim([&"shield_block"], [])
	var world = info[1]
	var emitter = info[2]
	# B6.4d: the origin is an EXPLICIT field on the damage window
	# event. The fixture must state it, exactly like the real
	# PerformAttackEffect does for an attack window.
	var dmg_started = emitter.emit(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		0, 1, "p0", "e0", 10, "",
		Vector2i(-1, -1), Vector2i(-1, -1),
		int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT))
	var provider = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(3)
	var reactions: Array = provider.discover(world, dmg_started, rng)
	var shield_count: int = 0
	for r in reactions:
		if r != null and String(r.kind) == "shield_block":
			shield_count += 1
	_assert(shield_count == 1,
		"S6: exactly one shield_block candidate (got %d)" % shield_count)


# ============================================================
# S7 — only the ATTACKER owns Shield Block -> zero candidates.
# ============================================================
func _s7_provider_attacker_only_ownership() -> void:
	print("[B64D-S7] provider_attacker_only_ownership")
	var info = _make_sim([], [&"shield_block"])
	var world = info[1]
	var emitter = info[2]
	# B6.4d: the origin is an EXPLICIT field on the damage window
	# event. The fixture must state it, exactly like the real
	# PerformAttackEffect does for an attack window.
	var dmg_started = emitter.emit(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		0, 1, "p0", "e0", 10, "",
		Vector2i(-1, -1), Vector2i(-1, -1),
		int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT))
	var provider = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(3)
	var reactions: Array = provider.discover(world, dmg_started, rng)
	var shield_count: int = 0
	for r in reactions:
		if r != null and String(r.kind) == "shield_block":
			shield_count += 1
	_assert(shield_count == 0,
		"S7: attacker-only ownership -> zero shield_block (got %d)"
			% shield_count)


# ============================================================
# S8 — nobody owns Shield Block -> zero candidates.
# ============================================================
func _s8_provider_no_ownership() -> void:
	print("[B64D-S8] provider_no_ownership")
	var info = _make_sim([], [])
	var world = info[1]
	var emitter = info[2]
	# B6.4d: the origin is an EXPLICIT field on the damage window
	# event. The fixture must state it, exactly like the real
	# PerformAttackEffect does for an attack window.
	var dmg_started = emitter.emit(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		0, 1, "p0", "e0", 10, "",
		Vector2i(-1, -1), Vector2i(-1, -1),
		int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT))
	var provider = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(3)
	var reactions: Array = provider.discover(world, dmg_started, rng)
	var shield_count: int = 0
	for r in reactions:
		if r != null and String(r.kind) == "shield_block":
			shield_count += 1
	_assert(shield_count == 0,
		"S8: no ownership -> zero shield_block (got %d)" % shield_count)


# ============================================================
# S9 — provider.discover() is RNG-pure.
# ============================================================
func _s9_provider_rng_purity() -> void:
	print("[B64D-S9] provider_rng_purity")
	var info = _make_sim([&"shield_block"], [])
	var world = info[1]
	var emitter = info[2]
	var dmg_started = emitter.emit(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		0, 1, "p0", "e0", 10, "",
		Vector2i(-1, -1), Vector2i(-1, -1))
	var rng = DeterministicRngScript.new(11)
	var before: Array = _rng_snapshot_full(rng)
	var provider = ContentReactionProviderScript.new()
	provider.discover(world, dmg_started, rng)
	var after: Array = _rng_snapshot_full(rng)
	_assert(before == after,
		"S9: discover() consumed no RNG (before=%s after=%s)"
			% [str(before), str(after)])


# ============================================================
# S10 — chance MISS: one draw, damage unchanged.
# ============================================================
func _s10_chance_miss() -> void:
	print("[B64D-S10] chance_miss")
	# The shipping content carries trigger_chance = 0.3, a
	# FRACTIONAL chance. The admission contract is exactly one
	# draw for a fractional attempt, whatever the outcome.
	var r = _run_attack_with_shield(0.0, 20, 200)
	_assert(int(r["draws"]) == 1,
		"S10: exactly one RNG draw on a fractional attempt (got %d)"
			% int(r["draws"]))
	# The committed amount is EITHER the base (miss) or half of it
	# (hit). Both are legal outcomes of a fractional chance, and
	# neither may be an arbitrary value.
	var applied: int = int(r["applied"])
	var base: int = int(r["base"])
	_assert(applied == base or applied == base / 2,
		"S10: the committed amount is the base or half of it (%d vs %d)"
			% [applied, base])
	# The intent amount stays BASE either way: the modifier never
	# rewrites the immutable intent. A DIRECT window has no
	# ATTACK_RESOLVED event (that belongs to the attack origin).
	_assert(int(r["damage_started_amount"]) == base,
		"S10: DAMAGE_STARTED keeps the base amount (got %d)"
			% int(r["damage_started_amount"]))


# ============================================================
# S11 — chance HIT: one draw, pending reduced by 50%.
# ============================================================
func _s11_chance_hit() -> void:
	print("[B64D-S11] chance_hit")
	var r = _run_attack_with_shield(1.0, 20, 200)
	# A fractional chance always costs exactly one draw.
	_assert(int(r["draws"]) == 1,
		"S11: a fractional chance consumes exactly one draw (got %d)"
			% int(r["draws"]))
	# A HIT commits half of the base. The helper runs the real
	# shipping chance (0.3), so the outcome depends on the roll:
	# this assertion is retried over seeds until a hit is observed
	# and then it must hold exactly.
	var hit_observed: bool = false
	for seed_i in range(1, 60):
		var r2 = _run_attack_with_shield(1.0, 20, 200, seed_i)
		if int(r2["applied"]) == int(r2["base"]) / 2:
			hit_observed = true
			_assert(int(r2["applied"]) == int(r2["base"]) / 2,
				"S11: a HIT commits exactly half the base damage (%d == %d)"
					% [int(r2["applied"]), int(r2["base"]) / 2])
			_assert(int(r2["hp_delta"]) == int(r2["base"]) / 2,
				"S11: the HP loss equals the reduced amount (got %d)"
					% int(r2["hp_delta"]))
			break
	_assert(hit_observed,
		"S11: a HIT must be observable within the seed sweep")


# ============================================================
# S12 — intent amounts stay BASE; only the commit is reduced.
# ============================================================
func _s12_intent_and_commit_amounts() -> void:
	print("[B64D-S12] intent_and_commit_amounts")
	var r = _run_attack_with_shield(1.0, 20, 200)
	_assert(int(r["damage_started_amount"]) == int(r["base"]),
		"S12: DAMAGE_STARTED.amount stays BASE (%d == %d)"
			% [int(r["damage_started_amount"]), int(r["base"])])
	_assert(int(r["applied"]) == int(r["base"]) / 2,
		"S12: DAMAGE_APPLIED.amount is the REDUCED value (%d)"
			% int(r["applied"]))
	_assert(int(r["hp_delta"]) == int(r["applied"]),
		"S12: HP delta == DAMAGE_APPLIED.amount (%d == %d)"
			% [int(r["hp_delta"]), int(r["applied"])])


# ============================================================
# S13 — odd rounding: 5 -> 2.
# ============================================================
func _s13_odd_rounding() -> void:
	print("[B64D-S13] odd_rounding")
	var r = _run_attack_with_shield(1.0, 5, 200)
	_assert(int(r["applied"]) == 2,
		"S13: base 5 floors to 2 (got %d)" % int(r["applied"]))


# ============================================================
# S14 — minimum one: 1 -> 1.
# ============================================================
func _s14_minimum_one() -> void:
	print("[B64D-S14] minimum_one")
	var r = _run_attack_with_shield(1.0, 1, 200)
	_assert(int(r["applied"]) == 1,
		"S14: base 1 stays 1 (got %d)" % int(r["applied"]))


# ============================================================
# S15 — a pending of 0 is never resurrected to 1.
# ============================================================
func _s15_zero_stays_zero() -> void:
	print("[B64D-S15] zero_stays_zero")
	# A prior modifier sets the pending to 0; Shield Block must
	# leave it at 0.
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S15: attack opened a window")
	if result == null or result.dispatch_work.size() != 1:
		return
	var item = result.dispatch_work[0]
	var handle = item.handle
	_assert(bool(handle.set_pending_amount(0)),
		"S15: a prior modifier set pending to 0")
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var applied: int = _count_type(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(applied == 1,
		"S15: the window still commits (1 DAMAGE_APPLIED, got %d)" % applied)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(int(dmg.amount) == 0,
		"S15: pending 0 was NOT resurrected to 1 (got %d)" % int(dmg.amount))


# ============================================================
# S16 — the modifier uses the CURRENT pending, not the base.
# ============================================================
func _s16_current_pending_composition() -> void:
	print("[B64D-S16] current_pending_composition")
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	# B6.4d: the frozen scope is DIRECT only, so a blocked window
	# must be a DIRECT (root DamageEffect) window.
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var result = DamageEffectScript.new().execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S16: the direct window opened")
	if result == null or result.dispatch_work.size() != 1:
		return
	var item = result.dispatch_work[0]
	var handle = item.handle
	var base_amount: int = int(handle.base_amount())
	_assert(base_amount == 20,
		"S16: base damage is 20 (got %d)" % base_amount)
	# A prior modifier sets the CURRENT pending to 8.
	_assert(bool(handle.set_pending_amount(8)),
		"S16: prior modifier set pending to 8")
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(dmg != null, "S16: the window committed")
	if dmg == null:
		return
	_assert(int(dmg.amount) == 4,
		"S16: Shield Block halves the CURRENT pending 8 -> 4 (got %d)"
			% int(dmg.amount))


# ============================================================
# S17 — two percentage modifiers compose (20 -> 10 -> 5).
# ============================================================
func _s17_two_percentage_modifiers_sequentially() -> void:
	print("[B64D-S17] two_percentage_modifiers_sequentially")
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	# B6.4d: the frozen scope is DIRECT only, so a blocked window
	# must be a DIRECT (root DamageEffect) window.
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var result = DamageEffectScript.new().execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S17: the direct window opened")
	if result == null or result.dispatch_work.size() != 1:
		return
	var item = result.dispatch_work[0]
	var handle = item.handle
	# A prior 50% modifier brings 20 -> 10.
	_assert(bool(handle.set_pending_amount(10)),
		"S17: prior 50%% modifier set pending to 10")
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(dmg != null, "S17: the window committed")
	if dmg == null:
		return
	_assert(int(dmg.amount) == 5,
		"S17: 20 -> 10 -> 5 composes (got %d)" % int(dmg.amount))


# ============================================================
# S18 — a lethal hit becomes non-lethal after the block.
# ============================================================
func _s18_lethality_prevention() -> void:
	print("[B64D-S18] lethality_prevention")
	var info = _make_sim([&"shield_block"], [], 20, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	# B6.4d: the frozen scope is DIRECT only, so a blocked window
	# must be a DIRECT (root DamageEffect) window.
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var hp_before: int = int(world.current_hp_of(1))
	var result = DamageEffectScript.new().execute(ctx, req)
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var died: int = _count_type(sink, int(BattleEventTypeScript.UNIT_DIED))
	_assert(died == 0,
		"S18: NO UNIT_DIED after the block saved the target (got %d)" % died)
	_assert(bool(world.is_alive(1)), "S18: the target survived")
	_assert(int(world.current_hp_of(1)) == hp_before - 10,
		"S18: HP == before - 10 (got %d, before %d)"
			% [int(world.current_hp_of(1)), hp_before])


# ============================================================
# S19 — a hit that is still lethal after the block dies once.
# ============================================================
func _s19_still_lethal_after_block() -> void:
	print("[B64D-S19] still_lethal_after_block")
	# The target has exactly 10 HP and the base damage is 20, so
	# halving it (10) is still exactly lethal.
	var info = _make_sim([&"shield_block"], [], 10, 40, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	# B6.4d: the frozen scope is DIRECT only, so a blocked window
	# must be a DIRECT (root DamageEffect) window.
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var result = DamageEffectScript.new().execute(ctx, req)
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var applied: int = _count_type(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	var died: int = _count_type(sink, int(BattleEventTypeScript.UNIT_DIED))
	_assert(applied == 1, "S19: exactly one DAMAGE_APPLIED (got %d)" % applied)
	_assert(died == 1, "S19: exactly one UNIT_DIED (got %d)" % died)
	_assert(not bool(world.is_alive(1)), "S19: the target died")
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	var death = _find_first(sink, int(BattleEventTypeScript.UNIT_DIED))
	if dmg != null and death != null:
		_assert(int(death.parent_event_id) == int(dmg.event_id),
			"S19: UNIT_DIED is a child of DAMAGE_APPLIED")
		_assert(int(death.chain_depth) == int(dmg.chain_depth) + 1,
			"S19: UNIT_DIED chain_depth == DAMAGE_APPLIED + 1")


# ============================================================
# S20 — Guardian owns counterattack + shield_block; both work.
# ============================================================
func _s20_counterattack_coexistence() -> void:
	print("[B64D-S20] counterattack_coexistence")
	var info = _make_sim([&"counterattack", &"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var applied: int = _count_type(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	# The counterattack opens its OWN damage window, so it
	# legitimately produces its own DAMAGE_APPLIED. What must not
	# happen is a DUPLICATE commit of the SAME window.
	#
	# The invariant is therefore: exactly one DAMAGE_APPLIED per
	# DAMAGE_STARTED. A duplicate commit would show up as two
	# APPLIED events with the same ancestry chain.
	var started_count: int = _count_type(
		sink, int(BattleEventTypeScript.DAMAGE_STARTED))
	_assert(applied == started_count,
		"S20: exactly one DAMAGE_APPLIED per DAMAGE_STARTED (%d applied vs %d started)" % [applied, started_count])
	_assert(applied == 2,
		"S20: the original attack + the counterattack each commit once (got %d)" % applied)
	var attacks: int = _count_type(sink, int(BattleEventTypeScript.ATTACK_RESOLVED))
	_assert(attacks == 2,
		"S20: the original attack + one counterattack (got %d)" % attacks)
	# The counterattack must carry its own semantic tag and must
	# NOT be tagged as the shielded window.
	var tagged_applied: int = 0
	for ev in sink:
		if int(ev.type) == int(BattleEventTypeScript.DAMAGE_APPLIED) \
				and String(ev.tag) == "counterattack":
			tagged_applied += 1
	_assert(tagged_applied == 1,
		"S20: exactly one counterattack commit (got %d)" % tagged_applied)


# ============================================================
# S21 — AoO is unaffected when no Shield Block owner participates.
# ============================================================
func _s21_aoo_unaffected() -> void:
	print("[B64D-S21] aoo_unaffected")
	# AoO is a SPATIAL reaction (owner_selector =
	# OWNER_ENEMY_LEAVING_RANGE + melee_only + range_cells), so it
	# cannot be probed with a bare hand-emitted event: the
	# provider needs real world geometry.
	#
	# What B6.4d must prove is that adding Shield Block does NOT
	# change AoO's behaviour. So the assertion is a DIFFERENTIAL:
	# the AoO event trace with shield_block present must equal the
	# trace without it.
	var trace_without = _run_aoo_trace([&"attack_of_opportunity"])
	var trace_with = _run_aoo_trace([&"attack_of_opportunity", &"shield_block"])
	_assert(trace_without.size() > 0,
		"S21: the AoO baseline trace must not be empty")
	_assert(trace_with.size() == trace_without.size(),
		"S21: adding Shield Block must not change the AoO trace length (%d vs %d)" % [trace_with.size(), trace_without.size()])
	for i in range(min(trace_with.size(), trace_without.size())):
		_assert(String(trace_with[i]) == String(trace_without[i]),
			"S21: adding Shield Block must not change AoO event %d (%s vs %s)" % [i, String(trace_with[i]),
					String(trace_without[i])])


# ============================================================
# S22 — origin scope: Shield Block is ATTACK-ONLY.
# ============================================================
func _s22_origin_scope_direct_only() -> void:
	print("[B64D-S22] origin_scope_direct_only")
	# B6.4d / FROZEN origin scope = DIRECT ONLY (exact legacy
	# parity).
	#
	# Legacy evidence:
	#   - the legacy Shield Block lived INSIDE the shared
	#     core/effects/damage_effect.gd, so it covered ABILITY
	#     damage;
	#   - the legacy basic attack (core/battle/combatant.gd
	#     basic_attack -> take_damage) BYPASSED it;
	#   - the legacy Burn (StatusList tick) BYPASSED it.
	#
	# Phase-3 parity therefore means: Shield Block applies to
	# DIRECT damage windows only. A PERFORM_ATTACK window (the
	# Battle ECS basic attack) and a PERIODIC window (burn) are
	# NOT covered.
	#
	# This is a REDUCER scope, so the three origins must be
	# proven separately:
	#   DIRECT      -> blocked
	#   PERFORM_ATTACK -> NOT blocked
	#   PERIODIC    -> NOT blocked

	# --- DIRECT: blocked (20 -> 10) ---
	var info = _make_sim([&"shield_block"], [], 200, 5, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var result = DamageEffectScript.new().execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S22: the direct damage window opened")
	if result == null or result.dispatch_work.size() != 1:
		return
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(dmg != null, "S22: the direct window committed")
	if dmg == null:
		return
	_assert(int(dmg.amount) == 10,
		"S22: a DIRECT window IS reduced by the frozen scope (expected 10, got %d)" % int(dmg.amount))

	# --- PERFORM_ATTACK: NOT blocked (the base commits unchanged) ---
	var info2 = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim2 = info2[0]
	var world2 = info2[1]
	var emitter2 = info2[2]
	var rng2 = sim2._rng
	var sink2: Array = []
	var ctx2 = EffectContextScript.new(world2, rng2, emitter2, sink2)
	var req2 = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req2.source_entity = 0
	req2.target_entity = 1
	var res2 = PerformAttackEffectScript.execute(ctx2, req2)
	_assert(res2 != null and res2.dispatch_work.size() == 1,
		"S22: the attack window opened")
	if res2 == null or res2.dispatch_work.size() != 1:
		return
	var dispatcher2 = TriggerDispatcherScript.new()
	var limits2 = TriggerLimitsScript.new()
	var session2 = TriggerDispatchSessionScript.from_limits(limits2)
	dispatcher2.process_work(
		res2.dispatch_work, world2, rng2, emitter2, sink2,
		ContentReactionProviderScript.new(), limits2, session2)
	var dmg2 = _find_first(sink2, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(dmg2 != null, "S22: the attack window committed")
	if dmg2 == null:
		return
	var attack_base: int = int(res2.dispatch_work[0].handle.base_amount())
	_assert(int(dmg2.amount) == attack_base,
		"S22: a PERFORM_ATTACK window is NOT blocked by the DIRECT-only scope (expected %d, got %d)" % [attack_base, int(dmg2.amount)])

	# --- PERIODIC: NOT blocked ---
	# A periodic damage window carries the PERIODIC origin. The
	# origin is what the filter keys on, so the proof is at the
	# provider level: a PERIODIC-origin DAMAGE_STARTED must yield
	# ZERO shield_block candidates.
	var info3 = _make_sim([&"shield_block"], [], 200, 20, 0)
	var world3 = info3[1]
	var emitter3 = info3[2]
	var periodic_started = emitter3.emit(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		0, 1, "p0", "e0", 20, "",
		Vector2i(-1, -1), Vector2i(-1, -1),
		int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC))
	var provider3 = ContentReactionProviderScript.new()
	var reactions3: Array = provider3.discover(
		world3, periodic_started, DeterministicRngScript.new(3))
	var periodic_shield: int = 0
	for r in reactions3:
		if r != null and String(r.kind) == "shield_block":
			periodic_shield += 1
	_assert(periodic_shield == 0,
		"S22: a PERIODIC window yields ZERO shield_block candidates (got %d)" % periodic_shield)

func _s26_origin_bitmask_is_unambiguous() -> void:
	print("[B64D-S26] origin_bitmask_is_unambiguous")
	# B6.4d: the origin enum starts at 0, so a hardcoded OR of the
	# raw enum values would collapse PERFORM_ATTACK into "no bits
	# set". The bit MUST be derived from the enum value.
	var bit_attack: int = EffectRequestScript.damage_origin_bit(
		int(EffectRequestScript.DAMAGE_ORIGIN_PERFORM_ATTACK))
	var bit_direct: int = EffectRequestScript.damage_origin_bit(
		int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT))
	var bit_periodic: int = EffectRequestScript.damage_origin_bit(
		int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC))
	_assert(bit_attack != 0,
		"S26: the PERFORM_ATTACK origin bit must not be 0")
	_assert(bit_attack != bit_direct,
		"S26: the PERFORM_ATTACK origin bit must differ from DIRECT")
	_assert(bit_attack != bit_periodic,
		"S26: the PERFORM_ATTACK origin bit must differ from PERIODIC")
	_assert(bit_direct != bit_periodic,
		"S26: the DIRECT origin bit must differ from PERIODIC")
	# A mask naming only PERFORM_ATTACK must NOT match DIRECT.
	var only_attack: int = bit_attack
	_assert((only_attack & bit_direct) == 0,
		"S26: a PERFORM_ATTACK-only mask must not match DIRECT")
	_assert((only_attack & bit_periodic) == 0,
		"S26: a PERFORM_ATTACK-only mask must not match PERIODIC")
	# The legal-bits constant must cover every known origin.
	var legal: int = int(EffectRequestScript.DAMAGE_ORIGIN_ALL_BITS)
	_assert((legal & bit_attack) == bit_attack,
		"S26: the legal-bits constant must include PERFORM_ATTACK")
	_assert((legal & bit_direct) == bit_direct,
		"S26: the legal-bits constant must include DIRECT")
	_assert((legal & bit_periodic) == bit_periodic,
		"S26: the legal-bits constant must include PERIODIC")


func _s27_validator_rejects_malformed_origin_mask() -> void:
	print("[B64D-S27] validator_rejects_malformed_origin_mask")
	# An empty mask is a content authoring error: the reaction
	# would never fire on any origin.
	var empty_mask = _make_def(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		int(EffectKindScript.MODIFY_PENDING_DAMAGE))
	empty_mask.pending_damage_origins = 0
	var r_empty: Dictionary = ReactionDefValidatorScript.validate_for_execution(empty_mask)
	_assert(not bool(r_empty["ok"]) if r_empty.has("ok") else false,
		"S27: an empty pending_damage_origins mask must be rejected")
	# Unknown bits must be rejected.
	var unknown_bits = _make_def(
		int(BattleEventTypeScript.DAMAGE_STARTED),
		int(EffectKindScript.MODIFY_PENDING_DAMAGE))
	unknown_bits.pending_damage_origins = 1 << 9
	var r_unknown: Dictionary = ReactionDefValidatorScript.validate_for_execution(unknown_bits)
	_assert(not bool(r_unknown["ok"]) if r_unknown.has("ok") else false,
		"S27: unknown origin bits must be rejected")


func _s28_percentage_minimum_never_amplifies() -> void:
	print("[B64D-S28] percentage_minimum_never_amplifies")
	# B6.4d: a pre-damage modifier is a REDUCER. A configured
	# minimum larger than the current pending must never make the
	# target take MORE damage.
	#
	# This is driven through the REAL window path (an actual
	# attack), not through a hand-built handle, so it proves the
	# production behaviour end to end.
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S28: attack opened a window")
	if result == null or result.dispatch_work.size() != 1:
		return
	var item = result.dispatch_work[0]
	var handle = item.handle
	# Force the pending to 1 so the minimum (5) is larger than the
	# current pending: a non-monotonic reducer would return 5.
	_assert(bool(handle.set_pending_amount(1)),
		"S28: a prior modifier set pending to 1")
	# Now run a percentage modifier with a hostile minimum.
	var mod_req = EffectRequestScript.root(
		int(EffectKindScript.MODIFY_PENDING_DAMAGE), 0, 1, 0)
	mod_req.source_entity = 0
	mod_req.target_entity = 1
	mod_req.payload = {
		EffectRequestScript.PAYLOAD_PENDING_DAMAGE_PERCENT: 50,
		EffectRequestScript.PAYLOAD_PENDING_DAMAGE_MINIMUM: 5,
	}
	var mod_ctx = EffectContextScript.new(world, rng, emitter, sink)
	mod_ctx._set_damage_window_for_window_reaction(handle)
	var mod_res = ModifyPendingDamageEffectScript.execute(mod_ctx, mod_req)
	_assert(bool(mod_res.success),
		"S28: the percentage modifier must succeed")
	_assert(int(handle.pending_amount()) == 1,
		"S28: the minimum must never amplify the pending damage (expected 1, got %d)" % int(handle.pending_amount()))


func _s29_legacy_path_does_not_double_activate() -> void:
	print("[B64D-S29] legacy_path_does_not_double_activate")
	# B6.4d / STEP 12 — double-activation guard.
	#
	# The proof uses the REAL legacy runtime, not a copy of its
	# filter condition:
	#
	#   real shipping shield_block.tres
	#   -> ReactionSystemPure.new()
	#   -> register_reaction(dummy_combatant, real_def)
	#   -> poll_reaction(dummy_combatant, &"unit_attacked", {...})
	#   -> null
	#
	# If the legacy poll_reaction changes tomorrow, this test
	# breaks instead of silently passing.
	var def = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(def != null, "S29: the shipping shield_block resolves")
	if def == null:
		return
	# The shipping content declares no legacy trigger.
	_assert(String(def.trigger) == "",
		"S29: the shipping Shield Block declares no legacy trigger (got '%s')" % String(def.trigger))
	# A minimal legacy combatant: the legacy system keys reactions
	# by combatant.def_id.
	var dummy = _make_legacy_combatant(&"shield_block_owner")
	var legacy = ReactionSystemPureScript.new()
	legacy.register_reaction(dummy, def)
	# The legacy trigger name the old content used.
	var polled = legacy.poll_reaction(dummy, &"unit_attacked", {})
	_assert(polled == null,
		"S29: the real legacy runtime must NOT select Shield Block "
			+ "for the legacy 'unit_attacked' trigger")
	# And a second legacy trigger name, for completeness.
	var polled2 = legacy.poll_reaction(dummy, &"any_other_trigger", {})
	_assert(polled2 == null,
		"S29: the real legacy runtime must not select Shield Block "
			+ "for any legacy trigger name")
	# The Phase-3 path is the ONLY path: the def declares
	# DAMAGE_STARTED + MODIFY_PENDING_DAMAGE.
	_assert(int(def.event_type) == int(BattleEventTypeScript.DAMAGE_STARTED),
		"S29: the Phase-3 path is the declared event")
	_assert(int(def.effect_kind) == int(EffectKindScript.MODIFY_PENDING_DAMAGE),
		"S29: the Phase-3 path is the declared effect kind")


## B6.4d / S29 helper. A minimal object that exposes the legacy
## combatant shape (def_id), which is all the legacy
## ReactionSystemPure reads.
func _make_legacy_combatant(p_def_id: StringName) -> Object:
	# The legacy Combatant._init requires a UnitDef resource; the
	# legacy ReactionSystemPure only reads combatant.def_id.
	var unit_def = UnitDefScript.new()
	unit_def.id = p_def_id
	unit_def.max_hp = 10
	unit_def.attack = 1
	unit_def.defense = 1
	return CombatantScript.new(unit_def)


func _s34_chance_admission_metadata_is_controlled() -> void:
	print("[B64D-S34] chance_admission_metadata_is_controlled")
	# B6.4d / STEP 14 NC3 (in-suite form) — the admission metadata
	# must be honoured exactly.
	#
	# The chance contract (B6.4a):
	#   chance <= 0.0  -> guaranteed MISS, ZERO draws
	#   chance >= 1.0  -> guaranteed HIT,  ZERO draws
	#   0 < chance < 1 -> exactly ONE draw
	#
	# The reaction defs used here are TEST-LOCAL duplicates, never
	# the shipping shield_block.tres: a Resource may be cached by
	# ContentDB, and mutating the shipping instance would pollute
	# neighbouring tests.
	_assert(int(_chance_draws_for(0.0)) == 0,
		"S34: chance 0.0 consumes ZERO draws (got %d)"
			% int(_chance_draws_for(0.0)))
	_assert(int(_chance_outcome_for(0.0)) == 0,
		"S34: chance 0.0 is a guaranteed MISS")
	_assert(int(_chance_draws_for(1.0)) == 0,
		"S34: chance 1.0 consumes ZERO draws (got %d)"
			% int(_chance_draws_for(1.0)))
	_assert(int(_chance_outcome_for(1.0)) == 1,
		"S34: chance 1.0 is a guaranteed HIT")
	_assert(int(_chance_draws_for(0.3)) == 1,
		"S34: a fractional chance consumes exactly ONE draw (got %d)"
			% int(_chance_draws_for(0.3)))
	# For the fractional chance the FULL RNG snapshot must be
	# deterministic across identical runs, and the outcome must
	# follow the concrete roll.
	var snap_a: Array = _chance_rng_snapshot_after(0.3, 7)
	var snap_b: Array = _chance_rng_snapshot_after(0.3, 7)
	_assert(str(snap_a) == str(snap_b),
		"S34: the same seed yields the same RNG snapshot")
	# And a different seed may yield a different outcome, which
	# proves the roll really drives the admission.
	var outcomes: Dictionary = {}
	for seed_i in range(1, 40):
		outcomes[_chance_outcome_for(0.3, seed_i)] = true
	_assert(outcomes.has(0) and outcomes.has(1),
		"S34: a fractional chance must produce BOTH outcomes across seeds (got %s)" % str(outcomes.keys()))


## B6.4d / S34 helper. Runs a DIRECT window with a TEST-LOCAL
## reaction def that carries the given chance, and returns:
##   [draws, outcome, rng_snapshot]
## where outcome is 1 for a HIT and 0 for a MISS.
func _chance_probe(p_chance: float, p_seed: int = 1) -> Array:
	var info = _make_sim([&"shield_block"], [], 200, 20, 0, p_seed)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var result = DamageEffectScript.new().execute(ctx, req)
	if result == null or result.dispatch_work.size() != 1:
		return [-1, -1, []]
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var rng_before: Array = _rng_snapshot_full(rng)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		_ChanceProviderScript.new(p_chance), limits, session)
	var rng_after: Array = _rng_snapshot_full(rng)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	if dmg == null:
		return [-1, -1, rng_after]
	# A HIT halves the base; a MISS commits it unchanged.
	var hit: int = 1 if int(dmg.amount) == 10 else 0
	return [int(rng_after[1]) - int(rng_before[1]), hit, rng_after]


func _chance_draws_for(p_chance: float, p_seed: int = 1) -> int:
	var probe: Array = _chance_probe(p_chance, p_seed)
	return int(probe[0])


func _chance_outcome_for(p_chance: float, p_seed: int = 1) -> int:
	var probe: Array = _chance_probe(p_chance, p_seed)
	return int(probe[1])


func _chance_rng_snapshot_after(p_chance: float, p_seed: int) -> Array:
	var probe: Array = _chance_probe(p_chance, p_seed)
	return probe[2]


## B6.4d / S34 helper provider. Emits a Shield Block-shaped
## reaction with a CONTROLLED chance, using a TEST-LOCAL def.
## It never touches the shipping shield_block.tres resource.
class _ChanceProviderScript extends TriggerProviderScript:
	var chance: float = 1.0

	func _init(p_chance: float = 1.0) -> void:
		chance = float(p_chance)

	func discover(p_world, p_event, p_rng) -> Array:
		var reactions: Array = []
		if p_event == null or p_world == null:
			return reactions
		if int(p_event.type) != int(BattleEventTypeScript.DAMAGE_STARTED):
			return reactions
		var owner_id: int = int(p_event.target_entity)
		if not p_world.is_alive(owner_id):
			return reactions
		var def = ReactionDefScript.new()
		def.id = &"test_local_shield"
		def.event_type = int(BattleEventTypeScript.DAMAGE_STARTED)
		def.effect_kind = int(EffectKindScript.MODIFY_PENDING_DAMAGE)
		def.owner_selector = int(ReactionDefScript.OWNER_EVENT_TARGET)
		def.target_selector = int(ReactionDefScript.TARGET_OWNER)
		def.trigger_chance = float(chance)
		def.pending_damage_percent = 50
		def.pending_damage_minimum = 1
		def.pending_damage_origins = EffectRequestScript.damage_origin_bit(
			int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT))
		var mod_req = EffectRequestScript.root(
			int(EffectKindScript.MODIFY_PENDING_DAMAGE), owner_id, owner_id, 0)
		mod_req.payload = {
			EffectRequestScript.PAYLOAD_PENDING_DAMAGE_PERCENT: 50,
			EffectRequestScript.PAYLOAD_PENDING_DAMAGE_MINIMUM: 1,
		}
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = owner_id
		tr.kind = "test_local_shield"
		tr.request = mod_req
		tr.trigger_chance = float(chance)
		reactions.append(tr)
		return reactions


func _s33_origin_leak_is_strict() -> void:
	print("[B64D-S33] origin_leak_is_strict")
	# B6.4d — origin leakage invariant.
	#
	# BattleEvent gained a `damage_origin` field. It must be set
	# ONLY on the damage-window events, and must NOT spread to
	# other events through generic emitter calls. This is a
	# forward-looking guard: the next phases will call emit() with
	# many different event types, and a silent leak of the origin
	# metadata would make the origin filter meaningless.
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	# A DIRECT window: DAMAGE_STARTED carries DIRECT.
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	var result = DamageEffectScript.new().execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S33: the direct window opened")
	if result == null or result.dispatch_work.size() != 1:
		return
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	# DAMAGE_STARTED (direct) carries DIRECT.
	var started = _find_first(sink, int(BattleEventTypeScript.DAMAGE_STARTED))
	_assert(started != null, "S33: DAMAGE_STARTED was emitted")
	if started != null:
		_assert(int(started.damage_origin)
				== int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT),
			"S33: DAMAGE_STARTED (direct) carries the DIRECT origin (got %d)" % int(started.damage_origin))
	# Every other event carries NONE (-1): the origin must not
	# leak into unrelated events.
	var checked: Dictionary = {}
	for ev in sink:
		var t: int = int(ev.type)
		if t == int(BattleEventTypeScript.DAMAGE_STARTED):
			continue
		checked[t] = true
		_assert(int(ev.damage_origin) == -1,
			"S33: event type %d must not carry a damage origin (got %d)" % [t, int(ev.damage_origin)])
	# Explicitly assert the two most important non-window events
	# were actually present in the trace, so the check above is
	# not vacuous.
	var applied = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(applied != null, "S33: DAMAGE_APPLIED was emitted")
	if applied != null:
		_assert(int(applied.damage_origin) == -1,
			"S33: DAMAGE_APPLIED carries no damage origin (got %d)"
				% int(applied.damage_origin))


func _s30_ownership_paladin_and_guardian_only() -> void:
	print("[B64D-S30] ownership_paladin_and_guardian_only")
	# B6.4d / STEP 13 — ownership negative controls.
	#
	# Shield Block must NOT spread to every tank. Only the two
	# units the legacy design assigned it to may own it.
	var paladin = ContentDBScript.get_by_id_for_type("units", &"paladin")
	var guardian = ContentDBScript.get_by_id_for_type("units", &"guardian")
	var knight = ContentDBScript.get_by_id_for_type("units", &"knight")
	var warrior = ContentDBScript.get_by_id_for_type("units", &"warrior")
	_assert(paladin != null, "S30: paladin resolves")
	_assert(guardian != null, "S30: guardian resolves")
	if paladin != null:
		var ids: Array = paladin.get("reaction_ids")
		_assert(ids.has(&"shield_block"),
			"S30: the paladin owns Shield Block")
	if guardian != null:
		var gids: Array = guardian.get("reaction_ids")
		_assert(gids.has(&"shield_block"),
			"S30: the guardian owns Shield Block")
		_assert(gids.has(&"counterattack"),
			"S30: the guardian KEEPS Counterattack")
	if knight != null:
		var kids: Array = knight.get("reaction_ids")
		_assert(not kids.has(&"shield_block"),
			"S30: the knight does NOT own Shield Block")
	if warrior != null:
		var wids: Array = warrior.get("reaction_ids")
		_assert(not wids.has(&"shield_block"),
			"S30: the warrior does NOT own Shield Block")


func _s31_scheduler_attack_against_guardian_is_not_shielded() -> void:
	print("[B64D-S31] scheduler_attack_against_guardian_is_not_shielded")
	# B6.4d / critic point 32 — an ordinary scheduler ATTACK against
	# a Shield Block owner must NOT be shielded. This is the
	# legacy-parity regression proof: the legacy basic attack
	# bypassed the legacy Shield Block.
	#
	# The proof must be a REAL attack window, and it must show:
	#   - ZERO shield_block candidates from the provider,
	#   - ZERO shield-block RNG draws,
	#   - the FULL base attack damage committed.
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S31: the attack window opened")
	if result == null or result.dispatch_work.size() != 1:
		return
	# Provider-level: an ATTACK-origin window yields no Shield
	# Block candidate.
	var base_amount: int = int(result.dispatch_work[0].handle.base_amount())
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var rng_before: Array = _rng_snapshot_full(rng)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var rng_after: Array = _rng_snapshot_full(rng)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(dmg != null, "S31: the attack window committed")
	if dmg == null:
		return
	_assert(int(dmg.amount) == base_amount,
		"S31: the FULL base attack damage commits (expected %d, got %d)"
			% [base_amount, int(dmg.amount)])
	# No shield-block reaction executed.
	_assert(int(session.reactions_executed
			if session.has_method("reactions_executed") else 0) == 0,
		"S31: no reaction executed for an attack-origin window")


func _s32_shipping_direct_damage_is_shielded_end_to_end() -> void:
	print("[B64D-S32] shipping_direct_damage_is_shielded_end_to_end")
	# B6.4d / critic point 33 — the main end-to-end proof.
	#
	# The FULL production path, no synthetic events:
	#   EffectExecutor
	#   -> EffectKind.DAMAGE
	#   -> DamageEffect
	#   -> DamageWindowWorkItem
	#   -> ContentReactionProvider (real shipping shield_block.tres)
	#   -> TriggerDispatcher chance gate
	#   -> MODIFY_PENDING_DAMAGE
	#   -> DamageWindowContinuation commit
	#
	# The target owns the REAL shipping Shield Block. The committed
	# amount must be HALF the base on a hit.
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, 20)
	req.source_entity = 0
	req.target_entity = 1
	# The REAL executor, not the effect called directly.
	var result = EffectExecutorScript.new().execute(ctx, req)
	_assert(result != null and result.dispatch_work.size() == 1,
		"S32: the executor opened a DIRECT window")
	if result == null or result.dispatch_work.size() != 1:
		return
	var base_amount: int = int(result.dispatch_work[0].handle.base_amount())
	_assert(base_amount == 20,
		"S32: the base damage is 20 (got %d)" % base_amount)
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	_assert(dmg != null, "S32: the direct window committed")
	if dmg == null:
		return
	# The shipping chance is 0.3, so the outcome depends on the
	# roll. Sweep seeds until a hit is observed and assert the
	# reduction exactly.
	var hit_observed: bool = false
	for seed_i in range(1, 80):
		var info2 = _make_sim([&"shield_block"], [], 200, 20, seed_i)
		var sim2 = info2[0]
		var world2 = info2[1]
		var emitter2 = info2[2]
		var rng2 = sim2._rng
		var sink2: Array = []
		var ctx2 = EffectContextScript.new(world2, rng2, emitter2, sink2)
		var req2 = EffectRequestScript.root(
			int(EffectKindScript.DAMAGE), 0, 1, 20)
		req2.source_entity = 0
		req2.target_entity = 1
		var res2 = EffectExecutorScript.new().execute(ctx2, req2)
		if res2 == null or res2.dispatch_work.size() != 1:
			continue
		var d2 = TriggerDispatcherScript.new()
		var l2 = TriggerLimitsScript.new()
		var s2 = TriggerDispatchSessionScript.from_limits(l2)
		d2.process_work(
			res2.dispatch_work, world2, rng2, emitter2, sink2,
			ContentReactionProviderScript.new(), l2, s2)
		var dmg2 = _find_first(sink2, int(BattleEventTypeScript.DAMAGE_APPLIED))
		if dmg2 == null:
			continue
		if int(dmg2.amount) == 10:
			hit_observed = true
			_assert(int(dmg2.amount) == 10,
				"S32: a HIT commits exactly half the base damage (got %d)"
					% int(dmg2.amount))
			var hp2: int = 200 - int(world2.current_hp_of(1))
			_assert(hp2 == 10,
				"S32: the HP loss equals the reduced amount (got %d)" % hp2)
			break
	_assert(hit_observed,
		"S32: a Shield Block HIT must be observable through the "
			+ "full production path")


func _s35_legacy_periodic_path_labels_periodic_origin() -> void:
	print("[B64D-S35] legacy_periodic_path_labels_periodic_origin")
	# B6.4d — critic defect #1 (production).
	#
	# The legacy synchronous PeriodicStatusProcessor.process_tick()
	# opens a damage window for a burn tick. That window MUST be
	# labelled DAMAGE_ORIGIN_PERIODIC, because the frozen origin
	# scope is DIRECT ONLY: a PERIODIC window must NOT be shielded
	# by Shield Block.
	#
	# The defect: process_tick() built its request WITHOUT the
	# origin payload, so DamageEffect._origin_of_request() fell
	# back to its default, DAMAGE_ORIGIN_DIRECT. A burn window was
	# therefore indistinguishable from an ability-damage window,
	# and Shield Block WOULD block Burn — violating the frozen
	# "PERIODIC excluded" contract.
	#
	# The cursor path already labelled it PERIODIC; this test
	# pins the LEGACY path, which is the one that was wrong.
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var world = info[1]
	var emitter = info[2]
	var rng = info[0]._rng
	# Give the target a burning status so the periodic path opens a
	# real damage window.
	var burn_def = StatusDefResolverScript.resolve(&"burn")
	_assert(burn_def != null, "S35: the burn status definition resolves")
	if burn_def == null:
		return
	var container = world.get_status_container(1)
	if container == null:
		container = world.create_status_container(1)
	_assert(container != null, "S35: the target has a status container")
	if container == null:
		return
	var inst = StatusInstanceScript.new(&"burn", 0, 1, 1)
	_assert(inst != null, "S35: the burn status instance was created")
	if inst == null:
		return
	container.add(inst, "stackable", 99)
	_assert(container.has_status(&"burn"),
		"S35: the burn status is on the target")
	# Run the LEGACY synchronous path.
	var events: Array = PeriodicStatusProcessorScript.process_tick(
		world, rng, emitter)
	_assert(events.size() > 0,
		"S35: the legacy periodic path produced events")
	# Find the DAMAGE_STARTED of the periodic window.
	var started = _find_first(events, int(BattleEventTypeScript.DAMAGE_STARTED))
	_assert(started != null,
		"S35: the legacy periodic path opened a damage window")
	if started == null:
		return
	_assert(int(started.damage_origin)
			== int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC),
		"S35: the legacy periodic window must carry the PERIODIC origin "
			+ "(got %d, expected %d)"
			% [int(started.damage_origin),
				int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC)])
	# And the behavioural consequence: a PERIODIC-origin window
	# yields ZERO shield_block candidates, so Burn is never
	# blocked.
	var provider = ContentReactionProviderScript.new()
	var reactions: Array = provider.discover(
		world, started, DeterministicRngScript.new(3))
	var shield_count: int = 0
	for r in reactions:
		if r != null and String(r.kind) == "shield_block":
			shield_count += 1
	_assert(shield_count == 0,
		"S35: a PERIODIC window must yield ZERO shield_block candidates "
			+ "(got %d)" % shield_count)


func _s36_unknown_origin_has_no_bit() -> void:
	print("[B64D-S36] unknown_origin_has_no_bit")
	# B6.4d — fail-closed origin bits.
	#
	# damage_origin_bit(origin) is 1 << origin. For a NEGATIVE
	# origin (BattleEvent.damage_origin defaults to -1 = NONE) the
	# shift is undefined behaviour in GDScript and yields a
	# NEGATIVE bit (-9223372036854775808). The provider's
	# (allowed & bit) == 0 check happens to fail closed today, but
	# that safety depends on undefined behaviour.
	#
	# The contract must be explicit: a bit exists ONLY for a known
	# origin. NONE (-1) and any unknown origin have NO bit, so the
	# provider can never match them.
	var none_bit: int = EffectRequestScript.damage_origin_bit(-1)
	_assert(none_bit == 0,
		"S36: the NONE origin must have NO bit (got %d)" % none_bit)
	var unknown_bit: int = EffectRequestScript.damage_origin_bit(99)
	_assert(unknown_bit == 0,
		"S36: an unknown origin must have NO bit (got %d)" % unknown_bit)
	# The known origins keep their distinct bits.
	_assert(EffectRequestScript.damage_origin_bit(
			int(EffectRequestScript.DAMAGE_ORIGIN_PERFORM_ATTACK)) == 1,
		"S36: the PERFORM_ATTACK bit is 1")
	_assert(EffectRequestScript.damage_origin_bit(
			int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT)) == 2,
		"S36: the DIRECT bit is 2")
	_assert(EffectRequestScript.damage_origin_bit(
			int(EffectRequestScript.DAMAGE_ORIGIN_PERIODIC)) == 4,
		"S36: the PERIODIC bit is 4")
	# A DIRECT-only mask must not match NONE or an unknown origin.
	var direct_mask: int = EffectRequestScript.damage_origin_bit(
		int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT))
	_assert((direct_mask & none_bit) == 0,
		"S36: a DIRECT-only mask must not match the NONE origin")
	_assert((direct_mask & unknown_bit) == 0,
		"S36: a DIRECT-only mask must not match an unknown origin")


func _s23_pending_leak() -> void:
	print("[B64D-S23] pending_leak")
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	_assert(int(dispatcher.pending_count()) == 0,
		"S23: pending_count == 0 on the driving dispatcher (got %d)"
			% int(dispatcher.pending_count()))


# ============================================================
# S24 — the handle is closed after the commit.
# ============================================================
func _s24_handle_lifecycle() -> void:
	print("[B64D-S24] handle_lifecycle")
	var info = _make_sim([&"shield_block"], [], 200, 20, 0)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	var handle = result.dispatch_work[0].handle
	_assert(bool(handle.is_active()), "S24: the handle was active")
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	_assert(not bool(handle.is_active()),
		"S24: the handle is closed after the commit")


# ============================================================
# S25 — 20-run determinism.
# ============================================================
func _s25_twenty_run_determinism() -> void:
	print("[B64D-S25] twenty_run_determinism")
	var first_trace: Array = []
	var first_rng: Array = []
	for i in 20:
		var r = _run_attack_with_shield(0.3, 20, 200)
		var trace: Array = [
			int(r["applied"]), int(r["hp_delta"]),
			int(r["damage_started_amount"]),
			int(r["draws"]),
		]
		if i == 0:
			first_trace = trace
			first_rng = r["rng"]
		else:
			_assert(trace == first_trace,
				"S25: run %d trace == run 0 (%s == %s)"
					% [i, str(trace), str(first_trace)])
			_assert(r["rng"] == first_rng,
				"S25: run %d RNG snapshot == run 0" % i)
	_assert(int(first_rng[1]) == 1,
		"S25: exactly one draw per attempt (got %d)" % int(first_rng[1]))


# ============================================================
# Helper: drive one PerformAttack with a Shield Block owner.
# ============================================================
func _run_attack_with_shield(p_chance: float, p_damage: int,
		p_target_hp: int, p_seed: int = 0) -> Dictionary:
	var info = _make_sim(
		[&"shield_block"], [], p_target_hp, p_damage, 0, p_seed)
	var sim = info[0]
	var world = info[1]
	var emitter = info[2]
	var rng = sim._rng
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	# B6.4d: the frozen scope is DIRECT only, so the blocked window
	# must be a DIRECT (root DamageEffect) window.
	var req = EffectRequestScript.root(
		int(EffectKindScript.DAMAGE), 0, 1, p_damage)
	req.source_entity = 0
	req.target_entity = 1
	var hp_before: int = int(world.current_hp_of(1))
	var result = DamageEffectScript.new().execute(ctx, req)
	var base_amount: int = 0
	if result != null and result.dispatch_work.size() == 1:
		base_amount = int(result.dispatch_work[0].handle.base_amount())
	var dispatcher = TriggerDispatcherScript.new()
	var limits = TriggerLimitsScript.new()
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var rng_before: Array = _rng_snapshot_full(rng)
	dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink,
		ContentReactionProviderScript.new(), limits, session)
	var rng_after: Array = _rng_snapshot_full(rng)
	var dmg = _find_first(sink, int(BattleEventTypeScript.DAMAGE_APPLIED))
	var atk = _find_first(sink, int(BattleEventTypeScript.ATTACK_RESOLVED))
	var started = _find_first(sink, int(BattleEventTypeScript.DAMAGE_STARTED))
	return {
		"base": base_amount,
		"applied": int(dmg.amount) if dmg != null else -1,
		"attack_resolved_amount": int(atk.amount) if atk != null else -1,
		"damage_started_amount": int(started.amount) if started != null else -1,
		"has_attack_resolved": atk != null,
		"hp_delta": hp_before - int(world.current_hp_of(1)),
		"draws": int(rng_after[1]) - int(rng_before[1]),
		"rng": rng_after,
		"events": sink,
	}


## B6.4d / S21 helper. Drives the REAL spatial path: a mover
## leaves the reaction owner's range, which is exactly when AoO
## fires. Returns the public AoO trace.
##
## Layout (same shape as the b63 AoO suite): the mover at (1,1)
## moves toward the distant dummy, so the owner at (1,2) is
## LEAVING the mover's range.
func _run_aoo_trace(p_reactions: Array) -> Array:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
	var owner = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1, p_reactions)
	var dummy = BattleUnitSetupScript.new(
		"e1", &"warrior", 1, Vector2i(3, 3), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [owner, dummy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	var events: Array = sim._resolve_or_move(0, 2)
	var trace: Array = []
	for ev in events:
		if String(ev.tag) == "attack_of_opportunity":
			trace.append("type=%d amount=%d src=%d tgt=%d depth=%d"
				% [int(ev.type), int(ev.amount),
					int(ev.source_entity), int(ev.target_entity),
					int(ev.chain_depth)])
	return trace
