extends SceneTree
## B6.4c S1 / S2 — SIBLING-REACTION WORLD-STATE ORDERING.
##
## The B6.4c pre-damage window splits intent from commit:
##
##   ATTACK_RESOLVED (intent)
##   └ DAMAGE_STARTED  (intent, window opens)
##     └ DAMAGE_APPLIED (commit, HP mutated)
##
## Legacy a5dd87d executed a damage-producing reaction
## SYNCHRONOUSLY: it mutated HP before the NEXT sibling reaction
## on the same event was even admitted. A sibling therefore
## observed the POST-damage live world, and a reaction whose
## target had just died was rejected by the is_alive()
## pre-guard — its ATTACK_RESOLVED was NEVER published.
##
## Without an ordering fix, the sibling would be admitted while
## the first window was still open, publish its intent, and the
## public trace would carry an EXTRA legacy event that the
## baseline does not have. The semantic differential would fail
## on exactly that.
##
## S1 (lethal first): the second sibling must publish NOTHING.
## S2 (nonlethal first): BOTH siblings run, in provider order,
##      and the second observes the HP left by the first.

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
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")

var _passed: int = 0
var _failed: int = 0


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


# ============================================================
# Synthetic provider: fires a HEAL reaction on the first
# DAMAGE_APPLIED it sees. The heal amount is read from the
# CURRENT live world at execution time — so if the sibling
# observes a stale world, the healed HP differs.
#
# We use HEAL (an ordinary, non-window effect) to observe the
# world state the sibling reaction saw. HEAL emits
# HEAL_APPLIED with the ACTUAL amount restored.
# ============================================================
# ============================================================
# Synthetic provider: fires TWO sibling reactions on the same
# event, in order:
#   A = DAMAGE (window-opening) on the target
#   B = HEAL  (ordinary effect) on the target
#
# HEAL emits HEAL_APPLIED with the ACTUAL amount restored,
# which is bounded by the target's live room (max_hp - cur_hp).
# That makes the sibling's view of the world OBSERVABLE:
#
#   target starts at 200/200 HP, max 200.
#   A deals 5 damage -> target at 195.
#   B heals for 100 -> room = 200 - 195 = 5
#                    -> HEAL_APPLIED.amount == 5
#
# If B were admitted BEFORE A's window committed, B would see
# 200/200 -> room = 0 -> NO HEAL_APPLIED at all.
#
# So "HEAL_APPLIED.amount == 5" IS the proof that B observed
# the post-A-commit live world.
# ============================================================
class _TwoSiblings extends RefCounted:
	var fired_on: Array = []
	var observed_target_hp: Array = []
	var damage_amount: int = 5
	var heal_amount: int = 100

	func discover(p_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.UNIT_MOVE_STARTED:
			return []
		fired_on.append(int(p_event.event_id))
		# The MOVER is the event's source_entity. The mover is
		# the unit our two siblings act upon (it is the unit
		# that just left the knights' range).
		var tgt: int = int(p_event.source_entity)
		observed_target_hp.append(int(p_world.current_hp_of(tgt)))
		# Sibling A: DAMAGE (opens a pre-damage window).
		var dreq = EffectRequestScript.root(
			EffectKindScript.DAMAGE, int(p_event.target_entity),
			tgt, int(damage_amount))
		dreq.definition_id = StringName("sibling_a_damage")
		var dtr = TriggerReactionScript.new()
		dtr.reacting_entity = int(p_event.target_entity)
		dtr.kind = StringName("sibling_a_damage")
		dtr.request = dreq
		dtr.trigger_chance = 1.0
		# Sibling B: HEAL (ordinary effect, no window).
		var hreq = EffectRequestScript.root(
			EffectKindScript.HEAL, int(p_event.target_entity),
			tgt, int(heal_amount))
		hreq.definition_id = StringName("sibling_b_heal")
		var htr = TriggerReactionScript.new()
		htr.reacting_entity = int(p_event.target_entity)
		htr.kind = StringName("sibling_b_heal")
		htr.request = hreq
		htr.trigger_chance = 1.0
		return [dtr, htr]


# ============================================================
# S1 — LETHAL FIRST: the second sibling must publish NOTHING.
#
# Two AoO siblings on the same UNIT_MOVE_STARTED. The first is
# lethal (kills the mover). The second must be rejected by the
# is_alive() pre-guard BEFORE publishing anything.
#
# The AoO reactions are CONTENT reactions (attack_of_opportunity
# on two knights), which is the exact production shape.
# ============================================================
static func _s1_lethal_first_sibling_publishes_nothing(p_assert: Callable) -> void:
	print("[B64C-S1] lethal_first_sibling_publishes_nothing")
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 2), 1, 1, 5, 5, 1, [])
	var knight_a = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(2, 1), 80, 80, 999, 5, 1,
		[&"attack_of_opportunity"])
	var knight_b = BattleUnitSetupScript.new(
		"e1", &"knight", 1, Vector2i(2, 3), 80, 80, 5, 5, 1,
		[&"attack_of_opportunity"])
	var dummy = BattleUnitSetupScript.new(
		"e2", &"warrior", 1, Vector2i(6, 3), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover],
		[knight_a, knight_b, dummy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim.set_max_ticks(2)
	var events: Array = sim._resolve_or_move(0, 3)

	# Count the AoO-related legacy events.
	var aoo_atk: int = 0
	var aoo_started: int = 0
	var aoo_applied: int = 0
	var unit_died: int = 0
	var knight_b_atk: int = 0
	var knight_b_started: int = 0
	var knight_b_applied: int = 0
	for e in events:
		var is_aoo: bool = String(e.tag) == "attack_of_opportunity"
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED and is_aoo:
			aoo_atk += 1
			if int(e.source_entity) == 2:
				knight_b_atk += 1
		elif int(e.type) == BattleEventTypeScript.DAMAGE_STARTED and is_aoo:
			aoo_started += 1
			if int(e.source_entity) == 2:
				knight_b_started += 1
		elif int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED and is_aoo:
			aoo_applied += 1
			if int(e.source_entity) == 2:
				knight_b_applied += 1
		elif int(e.type) == BattleEventTypeScript.UNIT_DIED:
			unit_died += 1

	# S1 REQUIREMENTS (legacy parity after projection).
	p_assert.call(aoo_atk == 1,
		"S1: exactly 1 AoO ATTACK_RESOLVED (got %d)" % aoo_atk)
	p_assert.call(aoo_started == 1,
		"S1: exactly 1 AoO DAMAGE_STARTED (got %d)" % aoo_started)
	p_assert.call(aoo_applied == 1,
		"S1: exactly 1 AoO DAMAGE_APPLIED (got %d)" % aoo_applied)
	p_assert.call(unit_died == 1,
		"S1: exactly 1 UNIT_DIED (got %d)" % unit_died)
	# The second sibling must publish NOTHING.
	p_assert.call(knight_b_atk == 0,
		"S1: sibling B published NO ATTACK_RESOLVED (got %d)" % knight_b_atk)
	p_assert.call(knight_b_started == 0,
		"S1: sibling B published NO DAMAGE_STARTED (got %d)" % knight_b_started)
	p_assert.call(knight_b_applied == 0,
		"S1: sibling B published NO DAMAGE_APPLIED (got %d)" % knight_b_applied)


# ============================================================
# S2 — NONLETHAL FIRST: BOTH siblings run, in order, and the
# second observes the world state left by the first.
#
# Fixture: one synthetic trigger event (UNIT_MOVE_STARTED) with
# TWO sibling reactions:
#   A = DAMAGE 5  (opens a pre-damage window)
#   B = HEAL 100  (ordinary effect, no window)
#
# Target: 200/200 HP, max 200.
#
# Legacy a5dd87d: A mutated HP synchronously (target -> 195),
# then B was admitted and saw room = 200 - 195 = 5, so
# HEAL_APPLIED.amount == 5.
#
# B6.4c without the sibling-ordering fix: B would be admitted
# while A's window was still open, see room = 0, and emit NO
# HEAL_APPLIED at all (or one with amount 0).
#
# B6.4c with the fix: A's window is completed inline, B sees
# room = 5, HEAL_APPLIED.amount == 5. That IS the proof that B
# observed the post-A-commit live world.
# ============================================================
static func _s2_nonlethal_first_sibling_sees_committed_world(p_assert: Callable) -> void:
	print("[B64C-S2] nonlethal_first_sibling_sees_committed_world")
	# Mover with 200 HP; a knight that does NOT react (so the
	# only reactions are our two synthetic siblings).
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 2), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(2, 1), 80, 80, 5, 5, 1, [])
	var dummy = BattleUnitSetupScript.new(
		"e1", &"warrior", 1, Vector2i(6, 3), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover],
		[knight, dummy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim.set_max_ticks(2)
	var provider = _TwoSiblings.new()
	sim.set_trigger_provider(provider)
	var events: Array = sim._resolve_or_move(0, 2)

	# The provider must have fired exactly once (on the move
	# event) and returned two siblings.
	p_assert.call(provider.fired_on.size() == 1,
		"S2: provider fired exactly once (got %d)" % provider.fired_on.size())
	# The provider observed the target's pre-damage HP (200).
	p_assert.call(provider.observed_target_hp.size() >= 1
			and int(provider.observed_target_hp[0]) == 200,
		"S2: provider saw pre-damage HP 200 (got %s)"
			% str(provider.observed_target_hp))

	# Sibling A's window: DAMAGE_STARTED + DAMAGE_APPLIED.
	var a_started = null
	var a_applied = null
	var heal_applied = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED:
			a_started = e
		elif int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			a_applied = e
		elif int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heal_applied = e
	p_assert.call(a_started != null, "S2: sibling A DAMAGE_STARTED present")
	p_assert.call(a_applied != null, "S2: sibling A DAMAGE_APPLIED present")
	if a_applied != null:
		p_assert.call(int(a_applied.amount) == 5,
			"S2: sibling A DAMAGE_APPLIED.amount == 5 (got %d)"
				% int(a_applied.amount))
	# Sibling B ran AND observed the post-A-commit world:
	# room = max_hp(200) - cur_hp(195) = 5, so the HEAL was
	# clamped to 5.
	p_assert.call(heal_applied != null,
		"S2: sibling B HEAL_APPLIED present (B saw room after A committed)")
	if heal_applied != null:
		p_assert.call(int(heal_applied.amount) == 5,
			"S2: sibling B HEAL_APPLIED.amount == 5 (saw post-A-commit room, got %d)"
				% int(heal_applied.amount))
	# Final world state: 200 - 5 (A's damage) + 5 (B's heal,
	# clamped to the room A left) = 200. The heal is NOT a full
	# 100 — it was clamped to the 5 HP of room that A's
	# committed damage created. That clamp IS the proof.
	p_assert.call(int(sim.world().current_hp_of(0)) == 200,
		"S2: target HP == 200 after damage 5 + heal 5 (got %d)"
			% int(sim.world().current_hp_of(0)))


# ============================================================
# Static proof API. The caller provides the assert callable
# so the counting stays with the caller. This lets the
# authoritative B6.4c suite run the proofs IN-PROCESS.
# ============================================================
static func run_all(p_assert: Callable) -> void:
	_s1_lethal_first_sibling_publishes_nothing(p_assert)
	_s2_nonlethal_first_sibling_sees_committed_world(p_assert)


func _initialize() -> void:
	run_all(_assert)
	ContentDBScript.load_all()
	print("\n=== B6.4c S1/S2 sibling-reaction ordering proofs: %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
		return
	quit(0)