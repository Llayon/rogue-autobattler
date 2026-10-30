extends SceneTree
## B6.4c R1 + R2 — runtime proofs for the events / dispatch_work
## separation contract. These are the tests that prove the
## work-pump fix is correct by construction, not by accident.
##
## R1 — ordinary legacy event discovered EXACTLY ONCE.
##      Proves events.duplicate() in dispatch_work does not
##      create double-discovery.
##
## R2 — reaction-origin attack waits for its OWN damage commit.
##      Proves exec_result.events do NOT drive discovery
##      directly: a counter-counterattack can only fire after
##      the counterattack's DAMAGE_APPLIED.

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
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")

var _passed: int = 0
var _failed: int = 0


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


# ============================================================
# Counting provider — records every discover() call so R1 can
# assert "discovered exactly once".
# ============================================================
class _CountingProvider extends RefCounted:
	var gate_event_id: int
	var reactions: Array
	var discover_calls: Dictionary = {}
	var call_order: Array = []

	func _init(p_reactions: Array, p_gate_event_id: int) -> void:
		reactions = p_reactions
		gate_event_id = int(p_gate_event_id)

	func discover(_world, p_event, _rng) -> Array:
		var eid: int = int(p_event.event_id)
		discover_calls[eid] = int(discover_calls.get(eid, 0)) + 1
		call_order.append(eid)
		if eid == int(gate_event_id):
			return reactions
		return []


# Synthetic reaction producing a DAMAGE effect (a real
# DamageWindowWorkItem path is NOT wanted here — R1 needs an
# ORDINARY, non-window effect).
static func _ordinary_reaction(
		p_tag: String, p_amount: int) -> RefCounted:
	# HEAL is an ORDINARY (non-window) effect: EffectResult.
	# succeeded(events) sets dispatch_work = events.duplicate(),
	# which is exactly the double-enqueue trap R1 must prove is
	# absent. The target must be below max HP for HEAL_APPLIED to
	# fire, so the fixture pre-damages it (see _r1_* below).
	var template = EffectRequestScript.root(
		EffectKindScript.HEAL, 1, 0, int(p_amount))
	template.definition_id = StringName("r1_" + p_tag)
	template.payload = {
		EffectRequestScript.PAYLOAD_EVENT_TAG:
			StringName(p_tag),
	}
	var tr = TriggerReactionScript.new()
	tr.reacting_entity = 0
	tr.kind = StringName("r1_" + p_tag)
	tr.request = template
	tr.trigger_chance = 1.0
	return tr


static func _make_sim(
		p_p0_reactions: Array, p_e0_reactions: Array) -> RefCounted:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1,
		p_p0_reactions)
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 200, 200, 5, 5, 1,
		p_e0_reactions)
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(7)
	return sim


# ============================================================
# R1 — ordinary legacy event discovered EXACTLY ONCE
# ============================================================
static func _r1_ordinary_event_discovered_once(p_assert: Callable) -> void:
	print("[B64C-R1] ordinary_event_discovered_exactly_once")
	var sim = _make_sim([], [])
	var em = sim._event_emitter
	# HEAL only emits HEAL_APPLIED when the target is below max
	# HP. The synthetic reaction heals entity 0 (source=1,
	# target=0), so pre-damage entity 0 to create room.
	sim.world().apply_damage(0, 50)

	# A synthetic root event we hand to the pump directly.
	var root_ev = em.emit(
		BattleEventTypeScript.STATUS_TICKED,
		0, 1, "p0", "e0", 0, "r1_root",
		Vector2i(-1, -1), Vector2i(-1, -1))

	# The reaction produces one ordinary HEAL event.
	var provider = _CountingProvider.new(
		[_ordinary_reaction("r1_evt_x", 3)], int(root_ev.event_id))

	var limits = TriggerLimitsScript.new(32, 10000, 256)
	var sink: Array = []
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dr = TriggerDispatcherScript.new().process_work(
		[root_ev], sim.world(), sim._rng, em, sink,
		provider, limits, session)

	# The downstream HEAL_APPLIED event must appear EXACTLY ONCE.
	# (HEAL hardcodes tag="", so we identify EVENT_X by TYPE +
	# target, not by tag. The reaction's output tag does not
	# reach the event for HEAL — that is legacy a5dd87d
	# behaviour and out of scope here.)
	var x_count: int = 0
	var x_ids: Array = []
	for e in dr.events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED \
				and int(e.target_entity) == 0:
			x_count += 1
			x_ids.append(int(e.event_id))
	p_assert.call(x_count == 1,
		"R1: downstream HEAL_APPLIED public count == 1 (got %d)" % x_count)

	# It must have been DISCOVERED exactly once.
	var x_discover: int = 0
	for k in provider.discover_calls.keys():
		if int(k) in x_ids:
			x_discover += int(provider.discover_calls[k])
	p_assert.call(x_discover == 1,
		"R1: provider.discover(EVENT_X) called exactly once (got %d)"
			% x_discover)

	# It must be marked seen exactly once in the session.
	for xid in x_ids:
		p_assert.call(session.has_seen(int(xid)),
			"R1: session marks EVENT_X (id=%d) seen" % int(xid))

	# No duplicate event_id in the public trace.
	var seen_ids: Dictionary = {}
	var dup: Array = []
	for e in dr.events:
		var eid: int = int(e.event_id)
		if seen_ids.has(eid):
			dup.append(eid)
		seen_ids[eid] = true
	p_assert.call(dup.is_empty(),
		"R1: no duplicate event_id in public trace (dups=%s)" % str(dup))

	# Truncation must NOT be marked: ordinary dispatch is not
	# truncation.
	p_assert.call(not bool(dr.truncated),
		"R1: ordinary dispatch does not mark truncated")
	p_assert.call(int(dr.reason) == DispatchResultScript.REASON_NONE,
		"R1: reason == REASON_NONE after ordinary dispatch")

	# pending_count drains to zero (no leaked work items).
	var disp = sim._trigger_dispatcher
	if disp != null:
		p_assert.call(int(disp.pending_count()) == 0,
			"R1: pending_count == 0 after pump")


# ============================================================
# R2 — reaction-origin attack waits for its own commit
# ============================================================
static func _r2_reaction_origin_waits_for_commit(p_assert: Callable) -> void:
	print("[B64C-R2] reaction_origin_waits_for_own_commit")
	# Content-driven counterattack: the guardian counterattacks.
	# We assert the public ordering invariants across all attack
	# atoms present in the trace. Counter-counterattack only
	# happens if BOTH sides counterattack; with a single
	# counterattack the trace still proves:
	#
	#   original DMG_APPLIED < counter ATTACK_RESOLVED
	#   counter   DMG_APPLIED < counter-counter ATTACK_RESOLVED
	#     (vacuous when no counter-counter exists — we then
	#      assert the counter attack's own 3-segment bridge
	#      completes, which is the same proof applied to a
	#      reaction-origin atom.)
	var sim = _make_sim([], [&"counterattack"])
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim.step_tick()
	p_assert.call(events.size() > 0, "R2: trace non-empty")

	# Helper: walk a 3-segment attack bridge.
	# Returns {atk, started, damage} or {} when not present.
	var _bridge := func(p_events: Array, p_atk) -> Dictionary:
		if p_atk == null:
			return {}
		var started = null
		for e in p_events:
			if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
					and int(e.parent_event_id) == int(p_atk.event_id):
				started = e
				break
		if started == null:
			return {}
		var dmg = null
		for e2 in p_events:
			if int(e2.type) == BattleEventTypeScript.DAMAGE_APPLIED \
					and int(e2.parent_event_id) == int(started.event_id):
				dmg = e2
				break
		if dmg == null:
			return {}
		return {"atk": p_atk, "started": started, "damage": dmg}

	# Collect attack atoms: root attacks (parent == -1) and
	# reaction-origin attacks (tag == "counterattack").
	var root_atks: Array = []
	var counter_atks: Array = []
	for e in events:
		if int(e.type) != BattleEventTypeScript.ATTACK_RESOLVED:
			continue
		if int(e.parent_event_id) == -1:
			root_atks.append(e)
		elif String(e.tag) == "counterattack":
			counter_atks.append(e)

	p_assert.call(root_atks.size() >= 1,
		"R2: at least one ROOT ATTACK_RESOLVED present")
	p_assert.call(counter_atks.size() >= 1,
		"R2: counterattack ATTACK_RESOLVED present")

	# R2 hard invariant #1: original DMG_APPLIED strictly before
	# counterattack ATTACK_RESOLVED in the PUBLIC trace.
	if root_atks.size() >= 1 and counter_atks.size() >= 1:
		var rb: Dictionary = _bridge.call(events, root_atks[0])
		p_assert.call(rb.has("damage"),
			"R2: original attack has full 3-segment bridge")
		if rb.has("damage"):
			var orig_dmg_idx: int = events.find(rb["damage"])
			var counter_idx: int = events.find(counter_atks[0])
			p_assert.call(orig_dmg_idx >= 0 and counter_idx >= 0,
				"R2: original DMG_APPLIED and counter ATK both in trace")
			p_assert.call(orig_dmg_idx < counter_idx,
				"R2 index: original DMG_APPLIED < counterattack ATTACK_RESOLVED")

	# R2 hard invariant #2: counter-counter discovery happens
	# ONLY AFTER counter DMG_APPLIED. When a counter-counter
	# atom exists we assert it; otherwise the counter atom's
	# own completion proves the same gate.
	var counter_counter: Array = []
	for e3 in events:
		if int(e3.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e3.tag) == "counterattack" \
				and counter_atks.size() >= 1 \
				and e3 != counter_atks[0] \
				and int(e3.parent_event_id) == int(counter_atks[0].event_id):
			counter_counter.append(e3)
	if counter_atks.size() >= 1:
		var cb: Dictionary = _bridge.call(events, counter_atks[0])
		p_assert.call(cb.has("damage"),
			"R2: counterattack attack has full 3-segment bridge")
		if cb.has("damage") and counter_counter.size() >= 1:
			var c_dmg_idx: int = events.find(cb["damage"])
			var cc_idx: int = events.find(counter_counter[0])
			p_assert.call(c_dmg_idx < cc_idx,
				"R2 index: counter DMG_APPLIED < counter-counter ATTACK_RESOLVED")

	# R2/R13 ancestry audit for EVERY attack atom in the trace.
	var all_atks: Array = []
	for e4 in events:
		if int(e4.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			all_atks.append(e4)
	for atk in all_atks:
		var b: Dictionary = _bridge.call(events, atk)
		if not b.has("damage"):
			continue
		var a = b["atk"]
		var s = b["started"]
		var d = b["damage"]
		p_assert.call(int(s.parent_event_id) == int(a.event_id),
			"R13: started.parent == attack.event_id")
		p_assert.call(int(d.parent_event_id) == int(s.event_id),
			"R13: damage.parent == started.event_id")
		p_assert.call(int(s.root_action_id) == int(a.root_action_id)
				and int(d.root_action_id) == int(a.root_action_id),
			"R13: root_action_id parity across attack atom")
		p_assert.call(int(s.chain_depth) == int(a.chain_depth) + 1,
			"R13: started.depth == attack.depth + 1")
		p_assert.call(int(d.chain_depth) == int(s.chain_depth) + 1,
			"R13: damage.depth == started.depth + 1")
		var ai: int = events.find(a)
		var si: int = events.find(s)
		var di: int = events.find(d)
		p_assert.call(ai < si and si < di,
			"R13: trace index attack < started < damage")
		p_assert.call(int(a.event_id) < int(s.event_id)
				and int(s.event_id) < int(d.event_id),
			"R13: event_id monotonic attack < started < damage")
		p_assert.call(int(a.source_entity) == int(d.source_entity)
				and int(a.target_entity) == int(d.target_entity),
			"R13: source/target parity between attack and damage")

	# Counterattack inverts source/target relative to the root.
	if root_atks.size() >= 1 and counter_atks.size() >= 1:
		var ra = root_atks[0]
		var ca = counter_atks[0]
		p_assert.call(int(ra.source_entity) == int(ca.target_entity)
				and int(ra.target_entity) == int(ca.source_entity),
			"R13: counterattack inverts source/target vs root attack")

	# Event ids strictly increasing across the whole public trace.
	var last_id: int = 0
	var mono: bool = true
	for e5 in events:
		if int(e5.event_id) <= last_id:
			mono = false
			break
		last_id = int(e5.event_id)
	p_assert.call(mono, "R2: event_id strictly increasing in public trace")

	# No window left pending.
	p_assert.call(int(sim._trigger_dispatcher.pending_count()) == 0,
		"R2: pending_count == 0 at end of tick")


# ============================================================
# R2b — explicit counter-counter ordering proof.
#
# Content EXCLUDES counter-counterattack via
# excluded_trigger_tags=[&"counterattack"] on the
# counterattack ReactionDef. So a counter-counterattack atom
# cannot be produced through production content — we must use
# a SYNTHETIC provider that fires on the counterattack's
# ATTACK_RESOLVED.
#
# This is the assertion that protects us from re-introducing
# early discovery of reaction-origin ATTACK_RESOLVED events.
# ============================================================
class _CounterChainProvider extends RefCounted:
	## Fires a PERFORM_ATTACK reaction on:
	##   - the ROOT attack's ATTACK_RESOLVED (counterattack)
	##   - the COUNTER attack's ATTACK_RESOLVED (counter-counter)
	## We identify them by trace order, so the provider simply
	## returns a fresh PERFORM_ATTACK reaction for every
	## ATTACK_RESOLVED it sees, with alternating source/target.
	var seen_atk_count: int = 0
	var fired: Array = []

	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.ATTACK_RESOLVED:
			return []
		# Only fire on attacks that are NOT yet countered (i.e.
		# the first two ATTACK_RESOLVED events in the chain).
		seen_atk_count += 1
		if seen_atk_count > 2:
			return []
		# The reaction attacks BACK: source = the attacked
		# party, target = the attacker.
		var src: int = int(p_event.target_entity)
		var tgt: int = int(p_event.source_entity)
		# PERFORM_ATTACK requires amount == 0: the damage is
		# computed internally by AttackMath from src/tgt stats.
		var template = EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, src, tgt, 0)
		template.definition_id = StringName("r2b_counter")
		template.payload = {
			EffectRequestScript.PAYLOAD_EVENT_TAG:
				StringName("r2b_counter"),
		}
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = src
		tr.kind = StringName("r2b_counter")
		tr.request = template
		tr.trigger_chance = 1.0
		fired.append(int(p_event.event_id))
		return [tr]


static func _r2b_counter_counter_waits_for_counter_commit(p_assert: Callable) -> void:
	print("[B64C-R2b] counter_counter_waits_for_counter_commit")
	var sim = _make_sim([], [])
	sim._rng = DeterministicRngScript.new(7)
	# The provider is injected into the simulation's provider slot
	# so the WHOLE tick (not just a hand-made pump call)
	# exercises the real path.
	var provider = _CounterChainProvider.new()
	sim.set_trigger_provider(provider)
	var events: Array = sim.step_tick()

	# We must see at least two ATTACK_RESOLVED atoms (the root
	# attack and the counterattack) — otherwise the fixture did
	# not produce a chain and the proof would be vacuous.
	var atks: Array = []
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			atks.append(e)
	p_assert.call(atks.size() >= 2,
		"R2b: at least 2 ATTACK_RESOLVED atoms in trace (got %d)"
			% atks.size())
	if atks.size() < 2:
		return

	var root_atk = atks[0]
	var counter_atk = atks[1]

	# Walk the 3-segment bridge for each atom.
	var _bridge := func(p_events: Array, p_atk) -> Dictionary:
		if p_atk == null:
			return {}
		var started = null
		for e in p_events:
			if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
					and int(e.parent_event_id) == int(p_atk.event_id):
				started = e
				break
		if started == null:
			return {}
		var dmg = null
		for e2 in p_events:
			if int(e2.type) == BattleEventTypeScript.DAMAGE_APPLIED \
					and int(e2.parent_event_id) == int(started.event_id):
				dmg = e2
				break
		if dmg == null:
			return {}
		return {"atk": p_atk, "started": started, "damage": dmg}

	var rb: Dictionary = _bridge.call(events, root_atk)
	p_assert.call(rb.has("damage"), "R2b: root attack has 3-segment bridge")
	var cb: Dictionary = _bridge.call(events, counter_atk)
	p_assert.call(cb.has("damage"),
		"R2b: counter attack has 3-segment bridge (its OWN commit happened)")

	# HARD INVARIANT #1: original DAMAGE_APPLIED strictly before
	# the counterattack's ATTACK_RESOLVED.
	if rb.has("damage"):
		var root_dmg_idx: int = events.find(rb["damage"])
		var counter_idx: int = events.find(counter_atk)
		p_assert.call(root_dmg_idx >= 0 and counter_idx >= 0,
			"R2b: root DMG_APPLIED and counter ATK both in trace")
		p_assert.call(root_dmg_idx < counter_idx,
			"R2b: original DMAGE_APPLIED < counterattack ATTACK_RESOLVED")

	# HARD INVARIANT #2: counter DAMAGE_APPLIED strictly before
	# the counter-counterattack's ATTACK_RESOLVED. The
	# counter-counterattack is the THIRD ATTACK_RESOLVED if the
	# provider fired twice.
	var counter_counter = null
	for e3 in atks:
		if e3 != root_atk and e3 != counter_atk:
			counter_counter = e3
			break
	p_assert.call(counter_counter != null,
		"R2b: counter-counterattack ATTACK_RESOLVED present (chain of 3)")
	if counter_counter != null:
		if cb.has("damage"):
			var counter_dmg_idx: int = events.find(cb["damage"])
			var cc_idx: int = events.find(counter_counter)
			p_assert.call(counter_dmg_idx >= 0 and cc_idx >= 0,
				"R2b: counter DMG_APPLIED and counter-counter ATK both in trace")
			p_assert.call(counter_dmg_idx < cc_idx,
				"R2b: counter DAMAGE_APPLIED < counter-counterattack ATTACK_RESOLVED")
		# The counter-counterattack must NOT appear before the
		# counter's own damage commit.
		var counter_idx2: int = events.find(counter_atk)
		var cc_idx2: int = events.find(counter_counter)
		p_assert.call(counter_idx2 < cc_idx2,
			"R2b: counterattack ATK_RESOLVED < counter-counterattack ATK_RESOLVED")

	# The FORBIDDEN ordering must be absent:
	#   counter ATTACK_RESOLVED, counter-counter ATTACK_RESOLVED,
	#   counter DAMAGE_APPLIED
	if cb.has("damage") and counter_counter != null:
		var c_atk_i: int = events.find(counter_atk)
		var c_dmg_i: int = events.find(cb["damage"])
		var cc_i: int = events.find(counter_counter)
		p_assert.call(not (c_atk_i < cc_i and cc_i < c_dmg_i),
			"R2b: forbidden ordering absent (counter ATK < counter-counter ATK < counter DMG)")

	# Every attack atom in the trace must have a complete
	# 3-segment bridge (no half-open windows).
	for atk in atks:
		var b: Dictionary = _bridge.call(events, atk)
		p_assert.call(b.has("damage"),
			"R2b: attack atom has complete 3-segment bridge")

	# TAIL ASSERTIONS — the LAST opened window must itself be
	# guaranteed to finalize. R2b proves "the next reaction does
	# not start before the previous window commits", but the
	# final opened window must ALSO be proven to reach its
	# DAMAGE_APPLIED. Otherwise a leaked window would go
	# unnoticed.
	if counter_counter != null:
		var ccb: Dictionary = _bridge.call(events, counter_counter)
		p_assert.call(ccb.has("started"),
			"R2b: counter-counterattack has a DAMAGE_STARTED (window opened)")
		p_assert.call(ccb.has("damage"),
			"R2b: counter-counterattack window FINALIZED (DAMAGE_APPLIED present)")
		if ccb.has("started") and ccb.has("damage"):
			var cc_started = ccb["started"]
			var cc_dmg = ccb["damage"]
			# parent linkage: damage.parent == started.event_id
			p_assert.call(int(cc_dmg.parent_event_id) == int(cc_started.event_id),
				"R2b: counter-counter DAMAGE_APPLIED.parent == counter-counter DAMAGE_STARTED.event_id")
			# root parity with the ORIGINAL attack atom.
			p_assert.call(int(cc_dmg.root_action_id) == int(root_atk.root_action_id),
				"R2b: counter-counter DAMAGE_APPLIED.root == original ATTACK_RESOLVED.root")
			# depth +1.
			p_assert.call(int(cc_dmg.chain_depth) == int(cc_started.chain_depth) + 1,
				"R2b: counter-counter DAMAGE_APPLIED.depth == counter-counter DAMAGE_STARTED.depth + 1")
			# strict trace order for the third atom.
			var cc_atk_i: int = events.find(counter_counter)
			var cc_st_i: int = events.find(cc_started)
			var cc_dm_i: int = events.find(cc_dmg)
			p_assert.call(cc_atk_i >= 0 and cc_st_i >= 0 and cc_dm_i >= 0,
				"R2b: counter-counter atom, started and damage all in trace")
			p_assert.call(cc_atk_i < cc_st_i and cc_st_i < cc_dm_i,
				"R2b: counter-counter ATTACK_RESOLVED < DAMAGE_STARTED < DAMAGE_APPLIED")
			# event_id monotonicity for the third atom.
			p_assert.call(int(counter_counter.event_id) < int(cc_started.event_id)
					and int(cc_started.event_id) < int(cc_dmg.event_id),
				"R2b: counter-counter event_id monotonic attack < started < damage")
			# source/target parity for the third atom.
			p_assert.call(int(counter_counter.source_entity) == int(cc_dmg.source_entity)
					and int(counter_counter.target_entity) == int(cc_dmg.target_entity),
				"R2b: counter-counter source/target parity attack vs damage")
			# Nothing in the REACTION CHAIN may follow the final
			# commit: the last opened window is the last thing
			# this root_action_id produced. (Events belonging to
			# a DIFFERENT root — e.g. the enemy team's own later
			# turn — may legitimately follow.)
			var after_chain: int = 0
			for k in range(cc_dm_i + 1, events.size()):
				if int(events[k].root_action_id) == int(root_atk.root_action_id):
					after_chain += 1
			p_assert.call(after_chain == 0,
				"R2b: no further event of the reaction chain after the counter-counter commit (got %d)"
					% after_chain)
			# The chain depth grows by exactly 2 per attack atom
			# (ATK -> DAMAGE_STARTED -> DAMAGE_APPLIED), so the
			# third atom's damage sits 4 levels below the root.
			p_assert.call(int(cc_dmg.chain_depth) == int(root_atk.chain_depth) + 4,
				"R2b: counter-counter DAMAGE_APPLIED.depth == root.depth + 4 (2 atoms deep)")
			if rb.has("damage"):
				p_assert.call(int(cc_dmg.chain_depth)
						== int(rb["damage"].chain_depth) + 2,
					"R2b: counter-counter DAMAGE_APPLIED.depth == original DAMAGE_APPLIED.depth + 2")

	p_assert.call(int(sim._trigger_dispatcher.pending_count()) == 0,
		"R2b: pending_count == 0 at end of tick")


# ============================================================
# Static proof API. The caller provides the assert callable
# so the counting stays with the caller. This lets the
# authoritative B6.4c suite run the proofs IN-PROCESS.
# ============================================================
static func run_all(p_assert: Callable) -> void:
	_r1_ordinary_event_discovered_once(p_assert)
	_r2_reaction_origin_waits_for_commit(p_assert)
	_r2b_counter_counter_waits_for_counter_commit(p_assert)


func _initialize() -> void:
	run_all(_assert)
	ContentDBScript.load_all()
	print("\n=== B6.4c R1+R2+R2b dispatch-order proofs: %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)