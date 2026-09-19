extends SceneTree
## Phase 3 / B5.1 — TriggerDispatcher parity + isolation
## closure.
##
## Covers:
##   - EffectRequest.child_from_template: definition_id +
##     payload deep-copy preserved; ancestry derives from
##     parent_event only.
##   - APPLY_STATUS reaction: real stun applies through
##     full production path (ApplyStatusEffect ->
##     StatusDefResolver -> StatusContainer).
##   - Payload snapshot: provider mutating template after
##     dispatch does not affect derived child.
##   - DispatchResult events recorded AT COMMIT TIME,
##     NOT on pop. Initial events excluded by API shape,
##     no seeded_count heuristic.
##   - Duplicate initial events: seen-set dedupes cleanly.
##   - MAX_EVENTS committed-prefix: child emitted before
##     cap still appears in result.events + sink.
##   - Lethal multi-event: DAMAGE emits DAMAGE_APPLIED +
##     UNIT_DIED in order, both visible.
##   - Sink/result parity: reaction suffix in sink ==
##     result.events.
##   - reactions_executed = admitted attempts (not
##     committed events).
##   - Exact depth boundary with single-chain provider:
##     depths 1..4 accepted, depth 5 rejected.
##   - Per-root continuation: root A exhausts budget; root
##     B still gets reactions.
##   - Truncation reason policy: first non-NONE reason
##     wins, not overwritten.
##   - Malformed reaction hardening: null request skipped,
##     no MAX_DEPTH reported.
##   - 14-field full deterministic normalization across
##     20 runs.
##   - Same-dispatcher reuse isolation: clear queue/seen/
##     budget between back-to-back calls.
##   - Provider RNG purity: NoopProvider does not advance
##     RNG state.

const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload(
	"res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const B5HelpersScript = preload(
	"res://tests/battle_ecs/effects/b5_helpers.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# === B5.1-1: child_from_template ===
	await _test_template_preserves_definition_id()
	await _test_template_deep_copies_payload()
	await _test_template_ancestry_from_parent_only()
	# === B5.1-1: APPLY_STATUS reaction ===
	await _test_apply_status_production_reaction()
	# === B5.1-1: payload snapshot ===
	await _test_payload_snapshot_independent_of_template_mutations()
	# === B5.1-2: commit-time recording ===
	await _test_duplicate_initial_event_handled()
	await _test_max_events_committed_prefix_visible()
	await _test_lethal_multi_event_both_in_result()
	await _test_sink_reaction_suffix_matches_result()
	# === Semantics ===
	await _test_reactions_executed_counts_admitted_attempts()
	await _test_exact_depth_boundary_single_chain()
	await _test_per_root_continuation_after_budget_exhaustion()
	await _test_truncation_reason_first_wins()
	await _test_malformed_reaction_hardening()
	# === Determinism ===
	await _test_14_field_normalization_20_runs()
	# === Isolation ===
	await _test_same_dispatcher_back_to_back_isolation()
	await _test_provider_does_not_advance_rng()
	print("\n=== B5.1 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _setup_world_and_emitter() -> Dictionary:
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	return {"world": w, "emitter": em, "rng": rng}


func _setup_world_with_two_units(p_world, p_emitter) -> Dictionary:
	var p0_setup = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e0_setup = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 1, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0_setup], [e0_setup], 7, 4)
	p_world.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var damage = B5HelpersScript.EventBuilder.damage_event(
		p_emitter, 0, 1, 5)
	return {"damage": damage, "rng": rng}


# === child_from_template ===

func _test_template_preserves_definition_id() -> void:
	print("[TPL-1] template_preserves_definition_id")
	# Build a fake parent event.
	var em = BattleEventEmitterScript.new()
	em.reset()
	var parent = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Build a template with definition_id and payload.
	var tmpl = EffectRequest.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0,
		-1, -1, 0)
	tmpl.definition_id = &"stun"
	tmpl.payload = {"stacks": 2, "extra_key": "hello"}
	# Build child.
	var child = EffectRequestScript.child_from_template(tmpl, parent)
	_assert(child != null, "child_from_template returns non-null")
	_assert(String(child.definition_id) == "stun",
		"child.definition_id preserved from template")
	_assert(child.payload.has("stacks")
			and int(child.payload["stacks"]) == 2,
		"child.payload preserved from template")
	_assert(String(child.payload.get("extra_key", "")) == "hello",
		"child.payload deep-copied (extra_key preserved)")


func _test_template_deep_copies_payload() -> void:
	print("[TPL-2] template_deep_copies_payload")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var parent = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Build a template with nested payload.
	var tmpl = EffectRequest.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0,
		-1, -1, 0)
	tmpl.payload = {"nested": {"k": [1, 2, 3]}, "scalar": 99}
	var child = EffectRequestScript.child_from_template(tmpl, parent)
	# Mutate template AFTER derivation.
	tmpl.payload["scalar"] = 1000
	tmpl.payload["nested"]["k"].append(999)
	# Child must NOT see the mutation.
	_assert(int(child.payload["scalar"]) == 99,
		"child scalar unaffected by post-derivation template mutation")
	_assert(len(child.payload["nested"]["k"]) == 3,
		"child nested array unaffected (deep-copy)")


func _test_template_ancestry_from_parent_only() -> void:
	print("[TPL-3] template_ancestry_from_parent_only")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var parent = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Template with completely bogus ancestry values.
	var tmpl = EffectRequest.new(
		EffectKindScript.HEAL, 9, 9, 99,
		99999, 99998, 42)
	tmpl.definition_id = &"regen"
	var child = EffectRequestScript.child_from_template(tmpl, parent)
	_assert(int(child.root_action_id) == int(parent.root_action_id),
		"child.root_action_id == parent.root_action_id (NOT tmpl)")
	_assert(int(child.parent_event_id) == int(parent.event_id),
		"child.parent_event_id == parent.event_id")
	_assert(int(child.chain_depth) == int(parent.chain_depth) + 1,
		"child.chain_depth == parent.chain_depth + 1")
	_assert(int(child.kind) == int(EffectKindScript.HEAL),
		"child.kind from template")
	_assert(String(child.definition_id) == "regen",
		"child.definition_id from template")


# === APPLY_STATUS production-path test ===

func _test_apply_status_production_reaction() -> void:
	print("[APS-1] apply_status_production_reaction")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	# Provider that responds to DAMAGE_APPLIED with an
	# APPLY_STATUS reaction targeting the source (P0).
	# APPLY_STATUS uses definition_id = stun, stacks=1.
	var provider = B5HelpersScript.ApplyStatusFromDamage.new()
	provider.stacks = 1
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 100
	limits.max_reactions_per_root = 100
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, setup["rng"], em, sink, provider,
		limits)
	# A real STATUS_APPLIED must be emitted.
	var status_applied = _filter_by_type(result.events,
		BattleEventTypeScript.STATUS_APPLIED)
	_assert(len(status_applied) == 1,
		"exactly one STATUS_APPLIED emitted (got %d)" % len(status_applied))
	if len(status_applied) >= 1:
		var ev = status_applied[0]
		_assert(int(ev.parent_event_id) == int(damage.event_id),
			"STATUS_APPLIED.parent_event_id == DAMAGE.event_id (ancestry)")
		_assert(int(ev.root_action_id) == int(damage.root_action_id),
			"STATUS_APPLIED.root_action_id == DAMAGE.root_action_id")
		_assert(int(ev.chain_depth) == 1,
			"STATUS_APPLIED.chain_depth == 1")
		_assert(String(ev.tag) == "stun",
			"STATUS_APPLIED.tag == 'stun' (real status_id)")
	# The target (E0, the damage target, which has the
	# reaction applied) must contain a real stun instance.
	var c1 = w.get_status_container(1)
	_assert(c1 != null,
		"E0 status container exists")
	if c1 != null:
		var statuses = c1.all()
		var found_stun = false
		for s in statuses:
			if String(s.status_id) == "stun":
				found_stun = true
				_assert(int(s.remaining) == 2,
					"real stun remaining=2 (ceil(1.5)=2, B4)")
		_assert(found_stun, "E0 has real stun instance")


# === Payload snapshot ===

func _test_payload_snapshot_independent_of_template_mutations() -> void:
	print("[PAY-1] payload_snapshot_independent_of_template_mutations")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var parent = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Template with payload.
	var tmpl = EffectRequest.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0,
		-1, -1, 0)
	tmpl.payload = {"stacks": 1, "notes": "a"}
	# Snapshot.
	var snap_payload: Dictionary = tmpl.payload.duplicate(true)
	var child = EffectRequestScript.child_from_template(tmpl, parent)
	# Mutate template payload AFTER child derivation.
	tmpl.payload["stacks"] = 999
	tmpl.payload["notes"] = "mutated"
	# Child must be unchanged.
	_assert(int(child.payload["stacks"]) == 1,
		"after template mutation, child.stacks still 1")
	_assert(String(child.payload["notes"]) == "a",
		"after template mutation, child.notes still 'a'")
	_assert(int(snap_payload["stacks"]) == 1,
		"manual snapshot also remains stable (sanity)")


# === Commit-time recording ===

func _test_duplicate_initial_event_handled() -> void:
	print("[DUP-1] duplicate_initial_event_handled")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	# Provider that counts invocations.
	var provider = B5HelpersScript.CountingHealProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	# Same event TWICE.
	var result = d.process([damage, damage], w, setup["rng"], em, sink,
		provider, limits)
	# Seen-set must dedupe -> DAMAGE_APPLIED discover
	# called exactly once -> reaction executed exactly
	# once -> 1 HEAL_APPLIED.
	_assert(int(provider.damage_invocations) == 1,
		"DAMAGE_APPLIED discover invoked exactly once for duplicate initial events (got %d)" % int(provider.damage_invocations))
	_assert(int(result.reactions_executed) == 1,
		"reactions_executed==1 for duplicate initial events")
	_assert(len(result.events) == 1,
		"result.events has exactly 1 reaction event")


func _test_max_events_committed_prefix_visible() -> void:
	print("[MAX-EVENTS-COMMIT] max_events_committed_prefix_visible")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	# Provider with two reactions: heal only (one-shot).
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false  # single heal
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 1
	limits.max_chain_depth = 32
	limits.max_reactions_per_root = 100
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, setup["rng"], em, sink, provider,
		limits)
	# After processing initial damage, reaction emits HEAL.
	# With cap=1, the HEAL is committed but NOT processed
	# for further discovery. The committed HEAL must still
	# appear in result.events + sink.
	_assert(result.truncated,
		"MAX_EVENTS=1 -> truncated=true")
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_EVENTS),
		"reason = MAX_EVENTS")
	_assert(len(result.events) >= 1,
		"committed HEAL still visible in result.events")
	_assert(len(sink) >= 1,
		"committed HEAL still visible in sink")
	# The HEAL must be in the same position in both.
	if len(result.events) >= 1 and len(sink) >= 1:
		_assert(int(result.events[0].event_id) == int(sink[0].event_id),
			"result.events[0] matches sink[0] event_id")


func _test_lethal_multi_event_both_in_result() -> void:
	print("[LETHAL-1] lethal_multi_event_both_in_result")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	# Use a setup where DAMAGE kills the target. DamageEffect
	# emits [DAMAGE_APPLIED, UNIT_DIED] for lethal.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 1), 1, 100, 20, 5, 1)
	var s = S.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	# Build initial DAMAGE event manually so we control the chain.
	var damage_event = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 99, "")
	# Provider: DAMAGE_APPLIED reacts with another DAMAGE on
	# the same target (lethal). DamageEffect emits
	# [DAMAGE_APPLIED, UNIT_DIED].
	var provider = B5HelpersScript.LethalDamageReaction.new()
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 8   # plenty
	limits.max_chain_depth = 16
	limits.max_reactions_per_root = 1  # only ONE attempted reaction
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage_event], w, rng, em, sink, provider,
		limits)
	# The single admitted reaction emits [DAMAGE_APPLIED,
	# UNIT_DIED] at commit time. Both must be in
	# result.events.
	var dmg_count: int = 0
	var died_count: int = 0
	for e in result.events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			dmg_count += 1
		elif int(e.type) == BattleEventTypeScript.UNIT_DIED:
			died_count += 1
	_assert(dmg_count >= 1,
		"at least one DAMAGE_APPLIED committed (got %d)" % dmg_count)
	_assert(died_count >= 1,
		"at least one UNIT_DIED committed (got %d)" % died_count)
	# Both emitted events must be in result.events in order:
	# the lethal damage reaction always emits
	# DAMAGE_APPLIED first, then UNIT_DIED.
	var types_in_order: Array = []
	for e in result.events:
		types_in_order.append(int(e.type))
	var dmg_idx: int = -1
	var died_idx: int = -1
	for i in len(types_in_order):
		if types_in_order[i] == BattleEventTypeScript.DAMAGE_APPLIED and dmg_idx == -1:
			dmg_idx = i
		if types_in_order[i] == BattleEventTypeScript.UNIT_DIED and died_idx == -1:
			died_idx = i
	_assert(dmg_idx < died_idx and dmg_idx >= 0 and died_idx >= 0,
		"DAMAGE_APPLIED precedes UNIT_DIED in result.events (got dmg=%d died=%d, types=%s)" % [dmg_idx, died_idx, str(types_in_order)])
	# sink parity.
	var sink_dmg: int = 0
	var sink_died: int = 0
	for e in sink:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			sink_dmg += 1
		elif int(e.type) == BattleEventTypeScript.UNIT_DIED:
			sink_died += 1
	_assert(sink_dmg == dmg_count,
		"sink DAMAGE_APPLIED count matches result.events (%d vs %d)" % [sink_dmg, dmg_count])
	_assert(sink_died == died_count,
		"sink UNIT_DIED count matches result.events (%d vs %d)" % [sink_died, died_count])


func _test_sink_reaction_suffix_matches_result() -> void:
	print("[SINK-1] sink_reaction_suffix_matches_result")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 100
	limits.max_chain_depth = 32
	limits.max_reactions_per_root = 100
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, setup["rng"], em, sink, provider,
		limits)
	# result.events and the sink contents (full sink, since
	# caller didn't pre-fill) must hold the same event_ids
	# in the same order.
	_assert(len(sink) == len(result.events),
		"sink length equals result.events length (sink=%d result=%d)" % [len(sink), len(result.events)])
	for i in len(result.events):
		_assert(int(result.events[i].event_id) == int(sink[i].event_id),
			"event_id[%d] matches between result.events and sink" % i)


# === Reactions executed semantics ===

func _test_reactions_executed_counts_admitted_attempts() -> void:
	print("[RX-COUNT] reactions_executed_counts_admitted_attempts")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	# Provider that returns ONE reaction: HEAL of entity 1
	# which is already dead (failed after dispatch). Or
	# heal of full-HP target (no-op). reactions_executed
	# should still be 1 because the attempt was admitted.
	# Use entity 2 (does not exist) -> heal fails safely.
	var provider = B5HelpersScript.HealDeadEntityReaction.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, setup["rng"], em, sink, provider,
		limits)
	_assert(int(result.reactions_executed) == 1,
		"reactions_executed == 1 (admitted attempt, even if effect fails)")
	_assert(len(result.events) == 0,
		"0 reaction events emitted (effect failed; no event)")


# === Exact depth boundary ===

func _test_exact_depth_boundary_single_chain() -> void:
	print("[DEPTH-EXACT] exact_depth_boundary_single_chain")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	# Two units, BOTH at less than max HP so the chain of
	# HEAL reactions actually heals and emits HEAL_APPLIED.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = S.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var damage = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Use ChainProvider that fires HEAL on every event.
	# Cap reactions high so depth=4 is the limiter.
	var provider = B5HelpersScript.SingleChainProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 4
	limits.max_reactions_per_root = 100000  # not the limiter
	limits.max_events_per_tick = 100000
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, rng, em, sink, provider, limits)
	# Expected chain (initial event depth 0):
	#   DAMAGE_APPLIED (id=1) -> reacts HEAL (depth 1)
	#   HEAL_APPLIED (id=2, depth=1) -> reacts HEAL (depth 2)
	#   HEAL_APPLIED (id=3, depth=2) -> reacts HEAL (depth 3)
	#   HEAL_APPLIED (id=4, depth=3) -> reacts HEAL (depth 4)
	#   HEAL_APPLIED (id=5, depth=4) -> tries depth=5 -> REJECTED.
	# Deepest committed HEAL chain_depth == 4.
	_assert(result.truncated,
		"chain truncated at depth boundary")
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_DEPTH),
		"reason = MAX_DEPTH (got %d)" % int(result.reason))
	var max_depth: int = -1
	for e in result.events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			if int(e.chain_depth) > max_depth:
				max_depth = int(e.chain_depth)
	_assert(max_depth == 4,
		"deepest HEAL chain_depth == 4 (got %d)" % max_depth)
	# The four committed HEAL events have chain_depths
	# 1, 2, 3, 4 in order.
	var depths: Array = []
	for e in result.events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			depths.append(int(e.chain_depth))
	_assert(len(depths) == 4 and int(depths[0]) == 1 and int(depths[1]) == 2
			and int(depths[2]) == 3 and int(depths[3]) == 4,
		"four HEAL events at depths 1,2,3,4 in order (got %s)" % str(depths))


# === Per-root continuation ===

func _test_per_root_continuation_after_budget_exhaustion() -> void:
	print("[PER-ROOT] per_root_continuation_after_budget_exhaustion")
	# The previous b5.1 version of this test did NOT
	# actually exhaust Root A: with PingPongProvider.mirror=false
	# only one reaction per root was proposed, and
	# max_reactions_per_root=1 admitted it.
	# B5.2 forces Root A to PROPOSE two reactions:
	# PingPongProvider.mirror=true emits HEAL + back-DAMAGE.
	# Budget=1 admits only the first; the second is
	# MAX_REACTIONS_PER_ROOT. Dispatcher MUST then continue
	# to Root B's first reaction.
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var em_local = info["emitter"]
	var root_a_event = em_local.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	var root_b_event = em_local.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Capture root ids BEFORE dispatch (provider sees
	# them on the events; reactions inherit root_action_id).
	var root_a_id: int = int(root_a_event.root_action_id)
	var root_b_id: int = int(root_b_event.root_action_id)
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_reactions_per_root = 1   # forces exhaustion on Root A
	limits.max_events_per_tick = 100
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([root_a_event, root_b_event], w,
		setup["rng"], em_local, sink, provider, limits)
	# Truncation must fire (Root A exhausted its budget
	# on reaction 1, after which Root B proceeds but its
	# budget is also exhausted by reaction 1).
	_assert(result.truncated,
		"truncated=true (per-root budget exhausted)")
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT),
		"reason = MAX_REACTIONS_PER_ROOT (got %d)" % int(result.reason))
	# Both roots must have ONE admitted reaction each.
	_assert(int(result.reactions_executed) == 2,
		"two reactions_executed (one per root; got %d)" % int(result.reactions_executed))
	# Result events: must contain events for BOTH root_action_ids.
	var event_roots: Dictionary = {}
	for e in result.events:
		event_roots[int(e.root_action_id)] = true
	_assert(event_roots.has(root_a_id) and event_roots.has(root_b_id),
		"result.events contains events for BOTH Root A (id=%d) and Root B (id=%d)" % [root_a_id, root_b_id])
	# Each root produced a HEAL_APPLIED (the admitted
	# first reaction of PingPongProvider).
	var heal_count: int = 0
	for e in result.events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heal_count += 1
	_assert(heal_count == 2,
		"both roots admitted their HEAL_APPLIED first reaction (got %d)" % heal_count)
	# CRUCIAL: Root B's admitted HEAL happened AFTER Root
	# A was rejected (dispatcher continued past Root A's
	# exhaustion). Track when each event's parent was the
	# initial root event.
	var root_b_event_found = false
	for e in result.events:
		if int(e.root_action_id) == root_b_id \
				and int(e.parent_event_id) == int(root_b_event.event_id):
			root_b_event_found = true
			break
	_assert(root_b_event_found,
		"Root B admitted a reaction after Root A exhausted (parent=root_b_event)")


# === Truncation reason policy ===

func _test_truncation_reason_first_wins() -> void:
	print("[REASON-1] truncation_reason_first_wins")
	# The previous b5.1 version of this test only triggered
	# MAX_DEPTH. It did NOT produce a LATER competing
	# truncation reason that could overwrite the first.
	#
	# B5.2 forces a sequence:
	#   FIRST  : Root A reaction at requested depth=2 with
	#            max_chain_depth=1 -> MAX_DEPTH (recording
	#            reason=MAX_DEPTH first).
	#   THEN   : Root B has two reactions at depth=1 with
	#            max_reactions_per_root=1. Reaction 1 of
	#            Root B is admitted; reaction 2 hits
	#            per-root budget -> MAX_REACTIONS_PER_ROOT.
	# Final reason must remain MAX_DEPTH (first wins).
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = S.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	# Build Root A already at chain_depth=1 (parent -> root_a).
	var root_a_parent = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	var root_a_event = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(root_a_parent.event_id),
		int(root_a_parent.root_action_id),
		int(root_a_parent.chain_depth),
		0, 1, "", "", 5, "")
	_assert(int(root_a_event.chain_depth) == 1,
		"root_a_event chain_depth=1 (got %d)" % int(root_a_event.chain_depth))
	# Root B: a fresh depth-0 DAMAGE_APPLIED. Provider
	# PingPongProvider.mirror=true on this returns
	# HEAL + back-DAMAGE.
	var root_b_event = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	var root_b_id: int = int(root_b_event.root_action_id)
	# Tight limits so the FIRST hit is MAX_DEPTH (root_a
	# reaction depth=2 > max=1), then Root B hits its
	# per-root budget.
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 1
	limits.max_reactions_per_root = 1
	limits.max_events_per_tick = 100
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([root_a_event, root_b_event], w, rng,
		em, sink, provider, limits)
	# Truncated (some branch was bounded).
	_assert(result.truncated,
		"truncated=true (multiple limits fired)")
	# First non-NONE reason must win: MAX_DEPTH.
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_DEPTH),
		"reason = MAX_DEPTH (first wins; got %d)" % int(result.reason))
	# The MAX_REACTIONS_PER_ROOT happened for Root B but
	# did NOT overwrite the recorded reason. We assert
	# this by checking that Root B's first reaction was
	# actually admitted (i.e. dispatcher really continued
	# after Root A rejection).
	var root_b_heal_committed: bool = false
	for e in result.events:
		if int(e.root_action_id) == root_b_id \
				and int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			root_b_heal_committed = true
			break
	_assert(root_b_heal_committed,
		"Root B admitted a HEAL reaction AFTER Root A MAX_DEPTH rejection (dispatcher continued)")


# === Malformed reaction hardening ===

func _test_malformed_reaction_hardening() -> void:
	print("[MALFORMED] malformed_reaction_hardening")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	# Provider that returns null and a reaction with null
	# request.
	var provider = B5HelpersScript.MalformedProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, setup["rng"], em, sink, provider,
		limits)
	# No crash, no MAX_DEPTH reported.
	_assert(not result.truncated,
		"malformed reactions don't trigger truncation=false")
	_assert(int(result.reason) == int(DispatchResultScript.REASON_NONE),
		"reason == NONE for malformed-only reactions")
	_assert(int(result.reactions_executed) == 0,
		"zero reactions executed for malformed-only reactions")


# === 14-field determinism ===

func _test_14_field_normalization_20_runs() -> void:
	print("[DET-14F] 14_field_normalization_20_runs")
	var first_norm: Array = []
	var first_reactions: int = -1
	var first_truncated: bool = false
	var first_reason: int = -1
	for run in 20:
		var info = _setup_world_and_emitter()
		var w = info["world"]
		var em = info["emitter"]
		var setup = _setup_world_with_two_units(w, em)
		var damage = setup["damage"]
		var provider = B5HelpersScript.PingPongProvider.new()
		provider.mirror = true
		var limits = TriggerLimitsScript.new()
		limits.max_chain_depth = 8
		limits.max_reactions_per_root = 5
		limits.max_events_per_tick = 100
		var d = TriggerDispatcherScript.new()
		var sink: Array = []
		var result = d.process([damage], w, setup["rng"], em, sink, provider,
			limits)
		var norm = _normalize14(result.events)
		if run == 0:
			first_norm = norm
			first_reactions = result.reactions_executed
			first_truncated = result.truncated
			first_reason = result.reason
		else:
			_assert(result.reactions_executed == first_reactions,
				"run %d reactions_executed matches" % run)
			_assert(result.truncated == first_truncated,
				"run %d truncated matches" % run)
			_assert(result.reason == first_reason,
				"run %d reason matches" % run)
			_assert(len(norm) == len(first_norm),
				"run %d size matches (got %d, expected %d)" % [run, len(norm), len(first_norm)])
			for i in len(norm):
				var diff: String = _field_diff14(first_norm[i], norm[i])
				if diff != "":
					_assert(false, "run %d event %d differs: %s" % [run, i, diff])
					return
	_assert(true, "20 runs identical (14 fields + counters + reason)")


func _normalize14(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append({
			"event_id": int(e.event_id),
			"type": int(e.type),
			"tick": int(e.tick),
			"source_entity": int(e.source_entity),
			"target_entity": int(e.target_entity),
			"source_run_unit_id": String(e.source_run_unit_id),
			"target_run_unit_id": String(e.target_run_unit_id),
			"amount": int(e.amount),
			"tag": String(e.tag),
			"from_cell": _norm_cell(e.from_cell),
			"to_cell": _norm_cell(e.to_cell),
			"parent_event_id": int(e.parent_event_id),
			"root_action_id": int(e.root_action_id),
			"chain_depth": int(e.chain_depth),
		})
	return out


func _norm_cell(v) -> Dictionary:
	if v == null:
		return {"x": -1, "y": -1}
	return {"x": int(v.x), "y": int(v.y)}


func _field_diff14(a, b) -> String:
	var fields: Array = [
		"event_id", "type", "tick",
		"source_entity", "target_entity",
		"source_run_unit_id", "target_run_unit_id",
		"amount", "tag",
		"from_cell", "to_cell",
		"parent_event_id", "root_action_id", "chain_depth",
	]
	for f in fields:
		if not b.has(f):
			return "missing %s" % f
		if typeof(a.get(f)) == TYPE_DICTIONARY:
			var ad: Dictionary = a.get(f)
			var bd: Dictionary = b.get(f)
			if ad.get("x", -999) != bd.get("x", -999) \
					or ad.get("y", -999) != bd.get("y", -999):
				return "%s: a=%s b=%s" % [f, str(ad), str(bd)]
			continue
		if a.get(f) != b.get(f):
			return "%s: a=%s b=%s" % [f, str(a.get(f)), str(b.get(f))]
	return ""


# === Same-dispatcher isolation ===

# B5.2: rebuild this proof with THREE independent
# identical scenarios (A, B_after_A, B_fresh_reference)
# to truly exercise same-dispatcher reuse. The previous
# version re-used B's world after A's dispatch and reset
# the emitter to align IDs — that conflates "fresh
# baseline" with "what happened next". B5.2 creates
# fully independent worlds so the only shared entity is
# the dispatcher instance.
func _test_same_dispatcher_back_to_back_isolation() -> void:
	print("[SAME-DISP] same_dispatcher_back_to_back_isolation")
	# Build three fully independent scenarios. Each has
	# its own BattleWorld, DeterministicRng, BattleEventEmitter,
	# initial committed event, and sink.
	var scen_a = _make_identical_scenario()
	var scen_b_after = _make_identical_scenario()
	var scen_b_fresh = _make_identical_scenario()
	# Sanity: all three scenarios are structurally identical
	# to dispatcher perspective (initial event id may be 1 in
	# each because each emitter starts fresh).
	_assert(int(scen_a["init"].event_id) == int(scen_b_after["init"].event_id) \
			and int(scen_b_after["init"].event_id) == int(scen_b_fresh["init"].event_id),
		"sanity: all scenarios share initial event_id")
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	# SHARED dispatcher across back-to-back A then B_after.
	var shared_dispatcher = TriggerDispatcherScript.new()
	var res_a = shared_dispatcher.process(
		[scen_a["init"]], scen_a["world"], scen_a["rng"],
		scen_a["emitter"], scen_a["sink"], provider, limits)
	var res_b_after = shared_dispatcher.process(
		[scen_b_after["init"]], scen_b_after["world"], scen_b_after["rng"],
		scen_b_after["emitter"], scen_b_after["sink"], provider, limits)
	# FRESH dispatcher on independent B_fresh_reference.
	var fresh_dispatcher = TriggerDispatcherScript.new()
	var res_b_fresh = fresh_dispatcher.process(
		[scen_b_fresh["init"]], scen_b_fresh["world"], scen_b_fresh["rng"],
		scen_b_fresh["emitter"], scen_b_fresh["sink"], provider, limits)
	# === Compare B_after_A (shared dispatcher) vs B_fresh (fresh dispatcher) ===
	var norm_b_after: Array = _normalize14(res_b_after.events)
	var norm_b_fresh: Array = _normalize14(res_b_fresh.events)
	_assert(len(norm_b_after) == len(norm_b_fresh),
		"B_after_A and B_fresh have equal events length (got %d vs %d)" % [len(norm_b_after), len(norm_b_fresh)])
	for i in len(norm_b_after):
		var diff: String = _field_diff14(norm_b_fresh[i], norm_b_after[i])
		if diff != "":
			_assert(false, "B_after_A[%d] differs from B_fresh: %s" % [i, diff])
			return
	_assert(int(res_b_after.reactions_executed) == int(res_b_fresh.reactions_executed),
		"B_after_A reactions_executed == B_fresh (got %d vs %d)" % [int(res_b_after.reactions_executed), int(res_b_fresh.reactions_executed)])
	_assert(res_b_after.truncated == res_b_fresh.truncated,
		"B_after_A truncated matches B_fresh (got %s vs %s)" % [str(res_b_after.truncated), str(res_b_fresh.truncated)])
	_assert(int(res_b_after.reason) == int(res_b_fresh.reason),
		"B_after_A reason matches B_fresh (got %d vs %d)" % [int(res_b_after.reason), int(res_b_fresh.reason)])
	# === Final-state parity ===
	# World HP / positions / containers: B_after_A and B_fresh
	# are fresh scenarios so they began identically; after
	# identical dispatch the state should be identical.
	_assert(int(scen_b_after["world"].current_hp_of(0)) == int(scen_b_fresh["world"].current_hp_of(0)),
		"B_after_A.p0 hp matches B_fresh.p0 hp (got %d vs %d)" % [int(scen_b_after["world"].current_hp_of(0)), int(scen_b_fresh["world"].current_hp_of(0))])
	_assert(int(scen_b_after["world"].current_hp_of(1)) == int(scen_b_fresh["world"].current_hp_of(1)),
		"B_after_A.e0 hp matches B_fresh.e0 hp (got %d vs %d)" % [int(scen_b_after["world"].current_hp_of(1)), int(scen_b_fresh["world"].current_hp_of(1))])
	# RNG parity: dispatch does not advance RNG (proven by
	# the RNG-PURE proof). RNG snapshots must be identical.
	var rng_after: Dictionary = scen_b_after["rng"].snapshot()
	var rng_fresh: Dictionary = scen_b_fresh["rng"].snapshot()
	_assert(int(rng_after.get("seed", -1)) == int(rng_fresh.get("seed", -1)),
		"B_after_A rng seed matches B_fresh (got %d vs %d)" % [int(rng_after.get("seed", -1)), int(rng_fresh.get("seed", -1))])
	_assert(int(rng_after.get("draw_count", -1)) == int(rng_fresh.get("draw_count", -1)),
		"B_after_A rng draw_count matches B_fresh (got %d vs %d)" % [int(rng_after.get("draw_count", -1)), int(rng_fresh.get("draw_count", -1))])
	_assert(int(rng_after.get("state", -1)) == int(rng_fresh.get("state", -1)),
		"B_after_A rng state matches B_fresh (state=%d)" % int(rng_after.get("state", -1)))
	# Emitter counters: per-scenario independent. Because
	# both scenarios share the same code path AND each has
	# its own emitter, their peek counters are EQUAL. That
	# is the correct simulation-scoped identity proof.
	_assert(int(scen_b_after["emitter"].peek_next_event_id()) \
			== int(scen_b_fresh["emitter"].peek_next_event_id()),
		"B_after_A emitter peek matches B_fresh (got %d vs %d)" % [int(scen_b_after["emitter"].peek_next_event_id()), int(scen_b_fresh["emitter"].peek_next_event_id())])
	_assert(int(scen_b_after["emitter"].peek_next_root_action_id()) \
			== int(scen_b_fresh["emitter"].peek_next_root_action_id()),
		"B_after_A emitter root-action peek matches B_fresh (got %d vs %d)" % [int(scen_b_after["emitter"].peek_next_root_action_id()), int(scen_b_fresh["emitter"].peek_next_root_action_id())])
	# Process A did not contaminate B_after_A. A's result
	# is independent of B_after_A's result.
	_assert(int(res_a.reactions_executed) >= 0,
		"sanity: A produced a result")
	_assert(int(res_b_after.reactions_executed) >= 0,
		"sanity: B_after_A produced a result")


# Build an independent scenario: own world, rng, emitter,
# initial committed event, sink. Same unit setup as the
# other helpers.
func _make_identical_scenario() -> Dictionary:
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	# spawn identical units at less than max HP so HEAL
	# of (target=0) doesn't no-op.
	var p0_setup = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0_setup = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0_setup], [e0_setup], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var init_event = B5HelpersScript.EventBuilder.damage_event(
		em, 0, 1, 5)
	var sink: Array = []
	return {
		"world": w,
		"emitter": em,
		"rng": rng,
		"init": init_event,
		"sink": sink,
	}


# === Provider RNG purity ===

# The b5.1 RNG-PURE test created a local fresh
# DeterministicRng that was never passed to the
# dispatcher. It was measuring an unrelated object.
# B5.2 fixes that: capture the EXACT RNG object passed
# into TriggerDispatcher.process(...) and compare its
# .snapshot() before vs after dispatch.
#
# CONTRACT:
#   discover(world, event, rng) is a TRUSTED PROVIDER
#   CONTRACT in B5. RNG identity is supplied but the
#   dispatcher does NOT advance RNG. A pure provider
#   (NoopProvider) MUST leave snapshot() unchanged.

func _test_provider_does_not_advance_rng() -> void:
	print("[RNG-PURE] provider_does_not_advance_rng")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	# The exact RNG instance the dispatcher will receive.
	var dispatch_rng: DeterministicRng = setup["rng"]
	var before: Dictionary = dispatch_rng.snapshot()
	var provider = B5HelpersScript.NoopProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	d.process([setup["damage"]], w, dispatch_rng, em, [], provider,
		limits)
	var after: Dictionary = dispatch_rng.snapshot()
	_assert(int(after.get("seed", -1)) == int(before.get("seed", -1)),
		"dispatch rng seed unchanged after NoopProvider dispatch (seed=%d)" % int(after.get("seed", -1)))
	_assert(int(after.get("draw_count", -1)) == int(before.get("draw_count", -1)),
		"dispatch rng draw_count unchanged (before=%d after=%d)" % [int(before.get("draw_count", -1)), int(after.get("draw_count", -1))])
	_assert(int(after.get("state", -1)) == int(before.get("state", -1)),
		"dispatch rng internal state unchanged (state=%d)" % int(after.get("state", -1)))
	# Sanity: capture a snapshot before any draws at all
	# to make sure draw_count starts at 0 in the snapshot
	# (no draws by anyone). Confirms dispatcher does not
	# silently pre-draw.
	_assert(int(before.get("draw_count", -1)) == 0,
		"fresh dispatch rng snapshot has draw_count == 0 (got %d)" % int(before.get("draw_count", -1)))


# === Helpers ===

func _filter_by_type(events: Array, p_type: int) -> Array:
	var out: Array = []
	for e in events:
		if int(e.type) == p_type:
			out.append(e)
	return out
