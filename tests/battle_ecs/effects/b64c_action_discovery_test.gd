extends SceneTree
## B6.4c — ACTION-PHASE DISCOVERY REGRESSION (critic #2, same
## class as the periodic-phase defect, in the player/enemy phases).
##
## Legacy a5dd87d dispatched the action phase's PUBLIC events:
##
##   var player_action_events = _drive_team_action(0)
##   for e in player_action_events: events.append(e)
##   _trigger_dispatcher.process(player_action_events, ...)
##
## B6.4c replaced that with a work-only drain:
##
##   var player_events = _drive_team_action(0, player_work)
##   for e in player_events: events.append(e)
##   process_work(player_work, ...)   # only the work
##
## So a public event that opens NO window — UNIT_MOVED (5) is the
## canonical example — never reaches the dispatcher, and a reaction
## bound to it never fires in the production step_tick() path.
##
## The periodic-phase twin of this defect is covered by
## b64c_periodic_discovery_test.gd. This suite covers the action
## phases.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_unit_moved_reaction_is_discovered()
	_test_attack_damage_applied_reaction_is_discovered()
	print("\n=== B6.4c action-phase discovery: %d pass / %d fail ==="
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


# Records every event type the dispatcher asks about, and fires a
# HEAL reaction on UNIT_MOVED (5) and on DAMAGE_APPLIED (3).
class _Recorder extends TriggerProviderScript:
	var seen: Array = []
	var fired_moved: int = 0
	var fired_damage: int = 0

	func discover(_world, p_event, _rng) -> Array:
		seen.append(int(p_event.type))
		var t: int = int(p_event.type)
		if t == BattleEventTypeScript.UNIT_MOVED:
			self.fired_moved += 1
			return _heal_reaction(p_event)
		if t == BattleEventTypeScript.DAMAGE_APPLIED:
			self.fired_damage += 1
			return _heal_reaction(p_event)
		return []

	func _heal_reaction(p_event) -> Array:
		var req = EffectRequestScript.root(
			EffectKindScript.HEAL,
			int(p_event.source_entity), int(p_event.target_entity), 3)
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.target_entity)
		tr.kind = &"probe_heal"
		tr.request = req
		tr.trigger_chance = 1.0
		return [tr]


func _make_sim() -> BattleSimulationScript:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	# The units start OUT of attack range, so the scheduler MOVES
	# them and the action phase publishes UNIT_MOVED (5) — a
	# public event that opens NO window and therefore has no
	# dispatch work. It must still reach the dispatcher.
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(3, 3), 100, 100, 20, 5, 1)
	var sim = BattleSimulationScript.new()
	sim.initialize(S.new(42, [p0], [e0], 7, 4))
	return sim


func _test_unit_moved_reaction_is_discovered() -> void:
	print("[AD-1] a UNIT_MOVED reaction is discovered in production")
	var sim = _make_sim()
	var provider = _Recorder.new()
	sim.set_trigger_provider(provider)
	sim.set_max_ticks(3)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	var moved_published: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.UNIT_MOVED:
			moved_published += 1
	_assert(moved_published >= 1,
		"UNIT_MOVED was published (got %d)" % moved_published)
	_assert(provider.fired_moved >= 1,
		"the provider was asked about UNIT_MOVED (fired %d times); "
		% provider.fired_moved
		+ "seen=%s" % str(provider.seen))
	_assert(provider.seen.has(int(BattleEventTypeScript.UNIT_MOVED)),
		"UNIT_MOVED reached discovery (seen=%s)" % str(provider.seen))


func _test_attack_damage_applied_reaction_is_discovered() -> void:
	print("[AD-2] an attack's DAMAGE_APPLIED reaction is discovered")
	var sim = _make_sim()
	var provider = _Recorder.new()
	sim.set_trigger_provider(provider)
	sim.set_max_ticks(3)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	var dmg_published: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			dmg_published += 1
	_assert(dmg_published >= 1,
		"DAMAGE_APPLIED was published (got %d)" % dmg_published)
	_assert(provider.seen.has(int(BattleEventTypeScript.DAMAGE_APPLIED)),
		"DAMAGE_APPLIED reached discovery (seen=%s)" % str(provider.seen))
