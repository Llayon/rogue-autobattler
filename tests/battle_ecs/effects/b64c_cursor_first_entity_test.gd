extends SceneTree
## B6.4c — PERIODIC STATUS CURSOR FIRST-ENTITY REGRESSION.
##
## RED (production bug found by the b33 localization matrix):
##
## The B6.4c lazy cursor's has_next() skipped the FIRST alive
## entity:
##
##   func has_next() -> bool:
##       while true:
##           if _idx_pos >= _indices.size():   # 0 >= 0 on the
##               _entity_idx += 1              # FIRST call -> entity 0
##               _idx_pos = 0                  # is SKIPPED FOREVER
##               _statuses = []
##               _indices = []
##
## On the first call _idx_pos == 0 and _indices == [], so the
## guard fires immediately and advances _entity_idx past the
## first alive entity. Any status on that entity NEVER ticks in
## the production step_tick() path.
##
## This is a PRODUCTION regression, not a test-contract change:
## the legacy process_tick() path visits every alive entity, and
## the B6.4c cursor path must visit exactly the same set.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
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
	_test_cursor_visits_first_entity()
	_test_cursor_visits_every_entity_with_status()
	_test_sim_step_tick_ticks_first_entity_status()
	_test_legacy_process_tick_agrees_with_cursor()
	print("\n=== B6.4c cursor first-entity regression: %d pass / %d fail ==="
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


# --- helpers ---

func _make_world(p_status_entities: Array, p_max_hp: int = 100) -> Dictionary:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var players: Array = []
	var enemies: Array = []
	# entity 0 = player (first alive id), entity 1 = second player,
	# entity 2 = first enemy.
	players.append(B.new("p0", &"warrior", 0, Vector2i(0, 0),
		p_max_hp, p_max_hp, 20, 5, 1))
	players.append(B.new("p1", &"warrior", 0, Vector2i(0, 1),
		p_max_hp, p_max_hp, 20, 5, 1))
	enemies.append(B.new("e0", &"orc", 1, Vector2i(0, 3),
		p_max_hp, p_max_hp, 20, 5, 1))
	var s = S.new(42, players, enemies, 1, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	for eid in p_status_entities:
		var container = w.get_status_container(int(eid))
		if container == null:
			container = w.create_status_container(int(eid))
		var inst = StatusInstanceScript.new(
			&"regen", 0, int(eid), 1, 100, 0)
		container.add(inst, "stackable", 99)
	return {"world": w, "emitter": em, "rng": rng}


func _cursor_ticked_count(p_fixture: Dictionary) -> int:
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		p_fixture["world"], p_fixture["rng"], p_fixture["emitter"])
	var n: int = 0
	var guard: int = 0
	while cursor.has_next():
		var step = cursor.next_step()
		if step == null:
			break
		for e in step.events:
			if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
				n += 1
		guard += 1
		if guard > 50:
			break
	return n


# --- tests ---

func _test_cursor_visits_first_entity() -> void:
	print("[CUR-1] cursor visits the FIRST alive entity")
	var fx = _make_world([0])
	var n: int = _cursor_ticked_count(fx)
	_assert(n == 1,
		"status on entity 0 (first alive id) ticks exactly once (got %d)" % n)


func _test_cursor_visits_every_entity_with_status() -> void:
	print("[CUR-2] cursor visits every entity that has a status")
	var fx = _make_world([0, 1, 2])
	var n: int = _cursor_ticked_count(fx)
	_assert(n == 3,
		"statuses on entities 0,1,2 all tick (got %d, expected 3)" % n)


func _test_sim_step_tick_ticks_first_entity_status() -> void:
	print("[CUR-3] sim.step_tick() ticks a status on the first entity")
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var players: Array = [
		B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1),
		B.new("p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)]
	var enemies: Array = [
		B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)]
	var sim = BattleSimulationScript.new()
	sim.initialize(S.new(42, players, enemies, 1, 4))
	var c = sim.world().get_status_container(0)
	if c == null:
		c = sim.world().create_status_container(0)
	c.add(StatusInstanceScript.new(&"regen", 0, 0, 1, 100, 0),
		"stackable", 99)
	var ticked: int = 0
	sim.set_max_ticks(1)
	while not sim.is_finished():
		for e in sim.step_tick():
			if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
				ticked += 1
	_assert(ticked >= 1,
		"STATUS_TICKED published by sim.step_tick() (got %d)" % ticked)


func _test_legacy_process_tick_agrees_with_cursor() -> void:
	print("[CUR-4] legacy process_tick and cursor visit the same set")
	var fx = _make_world([0, 1, 2])
	var legacy: Array = PeriodicStatusProcessorScript.process_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var legacy_ticked: int = 0
	for e in legacy:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			legacy_ticked += 1
	# A fresh fixture for the cursor (the legacy path consumed
	# one tick of duration).
	var fx2 = _make_world([0, 1, 2])
	var cursor_ticked: int = _cursor_ticked_count(fx2)
	_assert(legacy_ticked == cursor_ticked,
		"legacy process_tick (%d) == cursor (%d) STATUS_TICKED count"
			% [legacy_ticked, cursor_ticked])
