extends SceneTree
## B6.4c — PERIODIC-PHASE DISCOVERY REGRESSION (critic #2 BLOCKER).
##
## Legacy a5dd87d dispatched the periodic phase's PUBLIC events
## (STATUS_TICKED, STATUS_EXPIRED) to the trigger dispatcher:
##
##   status_events = _periodic_status_processor.process_tick(...)
##   for e in status_events: events.append(e)
##   ...
##   _trigger_dispatcher.process(status_events, ...)
##
## B6.4c replaced process_tick() with the lazy cursor and now
## drains ONLY `step.dispatch_work`:
##
##   for e in step.events: events.append(e)      # sink only
##   process_work(step.dispatch_work, ...)        # discovery
##
## So the phase's own public events are appended to the tick sink
## but NEVER handed to the dispatcher — a reaction triggered by
## STATUS_TICKED no longer fires in the production path.
##
## This suite proves the production step_tick() path performs
## discovery on the periodic phase's public events.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_status_ticked_reaction_is_discovered()
	_test_status_ticked_reaction_sees_the_committed_world()
	_test_heal_only_status_tick_is_discovered()
	_test_status_expired_is_discovered()
	print("\n=== B6.4c periodic-phase discovery: %d pass / %d fail ==="
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


# A provider that reacts to STATUS_TICKED with a HEAL.
class _HealOnStatusTicked extends TriggerProviderScript:
	var fired: int = 0
	var heal_amount: int = 100
	func discover(p_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.STATUS_TICKED:
			return []
		fired += 1
		var req = EffectRequestScript.root(
			EffectKindScript.HEAL,
			int(p_event.source_entity), int(p_event.target_entity),
			self.heal_amount)
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.target_entity)
		tr.kind = &"heal_on_tick"
		tr.request = req
		tr.trigger_chance = 1.0
		return [tr]


func _make_sim() -> BattleSimulationScript:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var sim = BattleSimulationScript.new()
	sim.initialize(S.new(42, [p0], [e0], 7, 4))
	return sim


func _seed_burn(p_sim, p_entity: int) -> void:
	var container = p_sim.world().get_status_container(p_entity)
	if container == null:
		container = p_sim.world().create_status_container(p_entity)
	var inst = StatusInstanceScript.new(&"burn", 0, p_entity, 1, 100, 0)
	container.add(inst, "stackable", 99)


func _test_status_ticked_reaction_is_discovered() -> void:
	print("[PD-1] a STATUS_TICKED reaction is discovered in production")
	var sim = _make_sim()
	var provider = _HealOnStatusTicked.new()
	sim.set_trigger_provider(provider)
	# Burn on entity 1 (the enemy). The burn's STATUS_TICKED must
	# reach the dispatcher so the heal reaction fires.
	_seed_burn(sim, 1)
	sim.set_max_ticks(2)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	_assert(provider.fired >= 1,
		"the provider saw the STATUS_TICKED (fired %d times)"
			% provider.fired)
	var healed: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			healed += 1
	_assert(healed >= 1,
		"the reaction's HEAL_APPLIED was published (got %d)" % healed)


func _test_status_ticked_reaction_sees_the_committed_world() -> void:
	print("[PD-2] the STATUS_TICKED reaction observes the committed world")
	var sim = _make_sim()
	var provider = _HealOnStatusTicked.new()
	sim.set_trigger_provider(provider)
	# A BURN (damage) on entity 1 lowers its HP; the HEAL
	# reaction must then see the POST-damage HP.
	_seed_burn(sim, 1)
	sim.set_max_ticks(2)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	# The burn did 5 damage. A heal that saw the pre-damage HP
	# would heal 100 (clamped to the 100 max). A heal that saw the
	# post-damage HP (95) heals at most 5.
	var heal_amounts: Array = []
	for e in events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heal_amounts.append(int(e.amount))
	_assert(heal_amounts.size() >= 1,
		"a HEAL_APPLIED was published (got %d)" % heal_amounts.size())
	if heal_amounts.size() >= 1:
		_assert(int(heal_amounts[0]) <= 5,
			"the heal observed the POST-burn HP (amount %d, expected <= 5)"
				% int(heal_amounts[0]))


func _test_heal_only_status_tick_is_discovered() -> void:
	print("[PD-3] a HEAL-ONLY status tick is discovered (no window)")
	# REGEN is a HEAL-only periodic status: it does NOT open a
	# damage window, so its STATUS_TICKED is NOT a delayed
	# dispatch seed of any window. It must still reach the
	# dispatcher so that a STATUS_TICKED reaction fires.
	#
	# This is the exact path the B6.4c cursor refactor broke:
	# the periodic phase drained only `step.dispatch_work`, and a
	# heal-only step has NONE.
	var sim = _make_sim()
	var provider = _HealOnStatusTicked.new()
	sim.set_trigger_provider(provider)
	# REGEN on entity 1, at REDUCED HP (so the reaction's heal
	# has room to actually heal — a heal at full HP is a no-op
	# and would publish nothing, which would make this test
	# vacuous).
	var container = sim.world().get_status_container(1)
	if container == null:
		container = sim.world().create_status_container(1)
	var inst = StatusInstanceScript.new(&"regen", 0, 1, 1, 100, 0)
	container.add(inst, "stackable", 99)
	sim.world().apply_damage(1, 50)
	sim.set_max_ticks(2)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	_assert(provider.fired >= 1,
		"the provider saw the heal-only STATUS_TICKED (fired %d times)"
			% provider.fired)
	var healed: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			healed += 1
	_assert(healed >= 1,
		"the reaction's HEAL_APPLIED was published (got %d)" % healed)


func _test_status_expired_is_discovered() -> void:
	print("[PD-4] STATUS_EXPIRED is discovered")
	# A status that expires on tick 1 emits STATUS_EXPIRED and
	# opens NO window, so it never becomes a delayed seed.
	var sim = _make_sim()
	var provider = _HealOnStatusTicked.new()
	sim.set_trigger_provider(provider)
	# A 1-tick REGEN expires immediately.
	var container = sim.world().get_status_container(1)
	if container == null:
		container = sim.world().create_status_container(1)
	var inst = StatusInstanceScript.new(&"regen", 0, 1, 1, 1, 0)
	container.add(inst, "stackable", 99)
	sim.set_max_ticks(2)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	var expired: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_EXPIRED:
			expired += 1
	_assert(expired >= 1,
		"STATUS_EXPIRED was published (got %d)" % expired)
