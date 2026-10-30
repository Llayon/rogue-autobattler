extends SceneTree
## B6.4c — LEGACY process_tick() SYNCHRONOUS COMMIT REGRESSION.
##
## There are TWO periodic-status APIs:
##
##   1. the lazy cursor (begin_tick / next_step) — the B6.4c
##      production path used by BattleSimulation.step_tick();
##   2. the legacy process_tick() — a SYNCHRONOUS compatibility
##      API.
##
## The legacy API had to be repaired during B6.4c: the periodic
## DAMAGE effect now OPENS a pre-damage window instead of
## mutating HP immediately, so process_tick() had to complete
## that window itself. Without the repair, a lethal Burn left the
## target alive, and the following Regen in the SAME phase fired
## on a target that should have been dead.
##
## This suite locks the legacy contract down:
##
##   - HP is committed BEFORE the next periodic status runs;
##   - a lethal Burn makes the following Regen skip;
##   - exactly ONE commit (no duplicate finalize of the same
##     window work item);
##   - exactly ONE UNIT_DIED;
##   - the legacy API does not later re-finalize the same work
##     item (a second process_tick() call must not re-apply the
##     damage).
##
## It also proves the legacy API and the cursor agree on WHICH
## entities are visited (see b64c_cursor_first_entity_test.gd for
## the cursor's own first-entity regression).

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_legacy_process_tick_commits_hp_before_next_status()
	_test_legacy_process_tick_lethal_burn_skips_following_regen()
	_test_legacy_process_tick_commits_exactly_once()
	_test_legacy_process_tick_emits_one_unit_died()
	_test_legacy_process_tick_does_not_refinalize_same_window()
	_test_legacy_process_tick_nonlethal_burn_then_regen()
	print("\n=== B6.4c legacy process_tick synchronous commit: %d pass / %d fail ==="
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


func _seed(p_fixture: Dictionary, p_entity_id: int,
		p_status_id: StringName, p_remaining: int,
		p_source_entity: int = 0) -> void:
	var w: BattleWorldScript = p_fixture["world"]
	var container = w.get_status_container(p_entity_id)
	if container == null:
		container = w.create_status_container(p_entity_id)
	# NOTE: the status' source_entity must DIFFER from the entity
	# it sits on — a damage effect with source == target is
	# rejected by the effect contract.
	var inst = StatusInstanceScript.new(
		p_status_id, p_source_entity, p_entity_id, 1, p_remaining, 0)
	container.add(inst, "stackable", 99)


func _count_type(p_events: Array, p_type: int) -> int:
	var n: int = 0
	for e in p_events:
		if int(e.type) == p_type:
			n += 1
	return n


# --- tests ---

func _test_legacy_process_tick_commits_hp_before_next_status() -> void:
	print("[LP-1] legacy process_tick commits HP synchronously")
	# Entity 1 (the enemy) has 100 HP. Burn does 5 per tick.
	# The commit must be visible to the caller AFTER
	# process_tick() returns — the legacy API is synchronous.
	var fx = _make_world(100)
	_seed(fx, 1, &"burn", 100)
	var evs: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var hp: int = int(fx["world"].current_hp_of(1))
	_assert(hp == 95,
		"HP committed by the time process_tick() returns (got %d, expected 95)"
			% hp)
	_assert(_count_type(evs, BattleEventTypeScript.DAMAGE_APPLIED) == 1,
		"exactly 1 DAMAGE_APPLIED published by process_tick()")


func _test_legacy_process_tick_lethal_burn_skips_following_regen() -> void:
	print("[LP-2] lethal Burn suppresses the following Regen")
	# Target has 5 HP. Burn (source entity 1) does 5 damage ->
	# lethal. Regen (also source entity 1) must NOT fire, because
	# the target is dead by the time the next status is processed.
	#
	# Insert REGEN first and BURN second: the processor traverses
	# statuses in REVERSE insertion order, so BURN runs FIRST.
	var fx = _make_world(5)
	_seed(fx, 0, &"regen", 100)
	_seed(fx, 0, &"burn", 100, 1)
	var evs: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	_assert(not bool(fx["world"].is_alive(0)),
		"target is dead after the lethal burn")
	var tick_tags: Array = []
	for e in evs:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_tags.append(String(e.tag))
	_assert(tick_tags.size() == 1,
		"only burn fired (got %d STATUS_TICKED tags: %s)"
			% [tick_tags.size(), str(tick_tags)])
	if tick_tags.size() == 1:
		_assert(tick_tags[0] == "burn",
			"the fired status is burn (got %s)" % tick_tags[0])
	_assert(_count_type(evs, BattleEventTypeScript.HEAL_APPLIED) == 0,
		"no HEAL_APPLIED for the dead target")


func _test_legacy_process_tick_commits_exactly_once() -> void:
	print("[LP-3] the window is committed exactly once")
	var fx = _make_world(100)
	_seed(fx, 1, &"burn", 100)
	var evs: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var hp: int = int(fx["world"].current_hp_of(1))
	_assert(hp == 95,
		"exactly 5 HP removed, not 10 (got %d, expected 95)" % hp)
	_assert(_count_type(evs, BattleEventTypeScript.DAMAGE_STARTED) == 1,
		"exactly 1 DAMAGE_STARTED (intent published once)")
	_assert(_count_type(evs, BattleEventTypeScript.DAMAGE_APPLIED) == 1,
		"exactly 1 DAMAGE_APPLIED (commit published once)")


func _test_legacy_process_tick_emits_one_unit_died() -> void:
	print("[LP-4] exactly one UNIT_DIED on a lethal burn")
	var fx = _make_world(5)
	_seed(fx, 1, &"burn", 100)
	var evs: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	_assert(_count_type(evs, BattleEventTypeScript.UNIT_DIED) == 1,
		"exactly 1 UNIT_DIED (got %d)"
			% _count_type(evs, BattleEventTypeScript.UNIT_DIED))
	# The UNIT_DIED is a CHILD of the DAMAGE_APPLIED.
	var dmg = null
	var died = null
	for e in evs:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED and dmg == null:
			dmg = e
		if int(e.type) == BattleEventTypeScript.UNIT_DIED and died == null:
			died = e
	if dmg != null and died != null:
		_assert(int(died.parent_event_id) == int(dmg.event_id),
			"UNIT_DIED.parent == DAMAGE_APPLIED.event_id")
		_assert(int(died.chain_depth) == int(dmg.chain_depth) + 1,
			"UNIT_DIED.depth == DAMAGE_APPLIED.depth + 1")


func _test_legacy_process_tick_does_not_refinalize_same_window() -> void:
	print("[LP-5] a second process_tick() does not re-apply the damage")
	var fx = _make_world(100)
	_seed(fx, 1, &"burn", 100)
	var evs1: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var hp1: int = int(fx["world"].current_hp_of(1))
	_assert(hp1 == 95, "first tick committed 5 damage (HP=%d)" % hp1)
	# Second tick: a NEW window is opened and committed, so the
	# total is 10 removed — but the FIRST window must not have
	# been finalized a second time (which would have removed 15).
	var evs2: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var hp2: int = int(fx["world"].current_hp_of(1))
	_assert(hp2 == 90,
		"second tick removed exactly 5 more, no double-finalize (HP=%d, expected 90)"
			% hp2)
	_assert(_count_type(evs2, BattleEventTypeScript.DAMAGE_APPLIED) == 1,
		"second tick published exactly 1 DAMAGE_APPLIED")
	_assert(_count_type(evs1, BattleEventTypeScript.DAMAGE_APPLIED) == 1,
		"first tick published exactly 1 DAMAGE_APPLIED")


func _test_legacy_process_tick_nonlethal_burn_then_regen() -> void:
	print("[LP-6] nonlethal burn leaves the target alive for the regen")
	# Target has 100 HP: burn removes 5 (not lethal), then regen
	# heals 5. Both must fire — the regen sees the target ALIVE
	# with 95 HP.
	var fx = _make_world(100)
	_seed(fx, 0, &"regen", 100)
	_seed(fx, 0, &"burn", 100, 1)
	var evs: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var tick_tags: Array = []
	for e in evs:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_tags.append(String(e.tag))
	_assert(tick_tags.size() == 2,
		"both burn and regen fired (got %d tags: %s)"
			% [tick_tags.size(), str(tick_tags)])
	_assert(bool(fx["world"].is_alive(0)),
		"target survived (nonlethal burn)")
	# Burn 5 then regen 5 -> back to 100.
	var hp: int = int(fx["world"].current_hp_of(0))
	_assert(hp == 100,
		"HP back to 100 after burn 5 + regen 5 (got %d)" % hp)
	_assert(_count_type(evs, BattleEventTypeScript.HEAL_APPLIED) == 1,
		"exactly 1 HEAL_APPLIED")
