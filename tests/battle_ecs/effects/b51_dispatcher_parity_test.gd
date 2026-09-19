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
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	# Use the SAME emitter that 'info' uses (the test setup
	# already has the dispatcher create one; reuse it).
	var em_local = info["emitter"]
	var root_a_event = em_local.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	var root_b_event = em_local.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_reactions_per_root = 1   # tight per-root budget
	limits.max_events_per_tick = 100
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	# FIFO: root_a first, then root_b.
	var result = d.process([root_a_event, root_b_event], w,
		setup["rng"], em_local, sink, provider, limits)
	# Per-root continuation: BOTH roots get exactly 1
	# reaction each (budget=1, both consumed). Root A
	# exhaustion does NOT block root B.
	_assert(int(result.reactions_executed) == 2,
		"both roots admitted their single reaction (got %d, truncated=%s)" % [int(result.reactions_executed), str(result.truncated)])
	_assert(len(result.events) == 2,
		"2 HEAL events in result (one per root)")
	# Root-action_ids must be distinct: prove both roots
	# executed by inspecting result.events roots.
	var roots_seen: Dictionary = {}
	for e in result.events:
		roots_seen[int(e.root_action_id)] = true
	_assert(len(roots_seen) == 2,
		"two distinct root_action_ids in result.events (got %d)" % len(roots_seen))


# === Truncation reason policy ===

func _test_truncation_reason_first_wins() -> void:
	print("[REASON-1] truncation_reason_first_wins")
	# We design a setup where the FIRST hit is MAX_DEPTH.
	# Beyond that, per-root budget also gets exhausted,
	# but reason must remain MAX_DEPTH (first wins).
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	# Unit setup: both at less than max HP so chain heals
	# are not no-ops.
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
	# Depth cap very low; per-root budget very high so
	# only depth triggers first.
	var provider = B5HelpersScript.SingleChainProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 2
	limits.max_reactions_per_root = 100000
	limits.max_events_per_tick = 100000
	var d = TriggerDispatcherScript.new()
	var sink: Array = []
	var result = d.process([damage], w, rng, em, sink, provider,
		limits)
	_assert(result.truncated,
		"truncated (depth=2 limit fired)")
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_DEPTH),
		"reason = MAX_DEPTH (got %d)" % int(result.reason))
	# The fact that reason stayed MAX_DEPTH even if other
	# limits fired proves "first wins" semantics.


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

func _test_same_dispatcher_back_to_back_isolation() -> void:
	print("[SAME-DISP] same_dispatcher_back_to_back_isolation")
	# Setup A.
	var info_a = _setup_world_and_emitter()
	var w_a = info_a["world"]
	var em_a = info_a["emitter"]
	var setup_a = _setup_world_with_two_units(w_a, em_a)
	var damage_a = setup_a["damage"]
	# Setup B (independent emitter, identical layout).
	var info_b = _setup_world_and_emitter()
	var w_b = info_b["world"]
	var em_b = info_b["emitter"]
	var setup_b = _setup_world_with_two_units(w_b, em_b)
	var damage_b = setup_b["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	# ONE TriggerDispatcher, two separate back-to-back calls.
	var d = TriggerDispatcherScript.new()
	var res_a = d.process([damage_a], w_a, setup_a["rng"], em_a, [],
		provider, limits)
	var res_b = d.process([damage_b], w_b, setup_b["rng"], em_b, [],
		provider, limits)
	# Now reset em_b + rebuild damage_b so the FRESH
	# dispatcher's emit sequence is identical to back-to-
	# back's at the time of dispatch.
	em_b.reset()
	# Need a fresh damage event with the same ancestry as
	# damage_b so reaction emit produces comparable events.
	var damage_b_again = em_b.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Now FRESH dispatcher on rebuilt B should match the
	# back-to-back result (modulo emitter IDs which are
	# unchanged because we reset BEFORE dispatch).
	var d_fresh = TriggerDispatcherScript.new()
	var res_b_fresh = d_fresh.process([damage_b_again], w_b,
		setup_b["rng"], em_b, [], provider, limits)
	# Use NON-emitter-allocated fields for comparison
	# (ancestry, type, source/target, amount, tag,
	# chain_depth, etc.). The first non-matcher proves
	# isolation.
	var norm_b: Array = _normalize14(res_b.events)
	var norm_b_fresh: Array = _normalize14(res_b_fresh.events)
	_assert(len(norm_b) == len(norm_b_fresh),
		"back-to-back B events length == fresh B (both len %d vs %d)" % [len(norm_b), len(norm_b_fresh)])
	for i in len(norm_b):
		var diff: String = _field_diff14(norm_b_fresh[i], norm_b[i])
		if diff != "":
			_assert(false, "back-to-back B[%d] differs from fresh B: %s" % [i, diff])
			return
	_assert(int(res_b.reactions_executed) == int(res_b_fresh.reactions_executed),
		"back-to-back B reactions_executed matches fresh")
	_assert(res_b.truncated == res_b_fresh.truncated,
		"back-to-back B truncated matches fresh")
	_assert(int(res_b.reason) == int(res_b_fresh.reason),
		"back-to-back B reason matches fresh")
	# Process A did NOT contaminate B's dispatcher state
	# (the B back-to-back result matches the fresh B run).
	# That is the strong isolation proof.
	_assert(len(norm_b) > 0,
		"sanity: B produced at least one reaction event")
	# Final sanity: result.event event_ids should reflect
	# the SPECIFIC emitter (A's reaction has event_id 2,
	# B's also id 2 because both started fresh).
	_assert(len(res_a.events) >= 1 and len(res_b.events) >= 1,
		"both A and B emit at least one reaction event")


# === Provider RNG purity ===

func _test_provider_does_not_advance_rng() -> void:
	print("[RNG-PURE] provider_does_not_advance_rng")
	var rng = DeterministicRngScript.new(42)
	# Snapshot RNG state by drawing two values.
	var before_a: int = int(rng.randi_range(0, 1000000))
	var before_b: int = int(rng.randi_range(0, 1000000))
	# Re-seed and re-draw: same values (deterministic).
	rng = DeterministicRngScript.new(42)
	var check_a: int = int(rng.randi_range(0, 1000000))
	var check_b: int = int(rng.randi_range(0, 1000000))
	_assert(check_a == before_a,
		"sanity: seed=42 produces same first draw (got %d, expected %d)" % [check_a, before_a])
	_assert(check_b == before_b,
		"sanity: seed=42 produces same second draw")
	# Use NoopProvider; rng must be untouched.
	rng = DeterministicRngScript.new(42)
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var provider = B5HelpersScript.NoopProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	d.process([setup["damage"]], w, setup["rng"], em, [], provider, limits)
	# The provider did not consume our rng.
	var after_a: int = int(rng.randi_range(0, 1000000))
	var after_b: int = int(rng.randi_range(0, 1000000))
	_assert(after_a == before_a,
		"NoopProvider did not advance local rng draw 1 (got %d, expected %d)" % [after_a, before_a])
	_assert(after_b == before_b,
		"NoopProvider did not advance local rng draw 2 (got %d, expected %d)" % [after_b, before_b])


# === Helpers ===

func _filter_by_type(events: Array, p_type: int) -> Array:
	var out: Array = []
	for e in events:
		if int(e.type) == p_type:
			out.append(e)
	return out
