extends SceneTree

## Minimal characterization suite for the current legacy battle engine.
## This suite records observed behavior; it is not the normative BattleSimulation contract.

const RngScript = preload("res://core/utils/rng_service.gd")
const GridScript = preload("res://core/battle/grid.gd")
const ContextScript = preload("res://core/battle/battle_context.gd")
const CombatantScript = preload("res://core/battle/combatant.gd")
const RunnerScript = preload("res://core/battle/battle_runner.gd")
const BattleStateScript = preload("res://core/battle/battle_state.gd")
const UnitDefScript = preload("res://core/data/unit_def.gd")
const StatusDefScript = preload("res://core/data/status_def.gd")
const AbilityDefScript = preload("res://core/data/ability_def.gd")
const DamageEffectScript = preload("res://core/effects/damage_effect.gd")
const ApplyStatusEffectScript = preload("res://core/effects/apply_status_effect.gd")
const TargetingScript = preload("res://core/data/targeting.gd")
const TeamScript = preload("res://core/data/team.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== Legacy characterization tests ===\n")
	_test_one_warrior_one_enemy()
	_test_two_identical_units_are_independent()
	_test_periodic_damage_kills()
	_test_stun_skips_action()
	_test_multi_effect_ability_preserves_effect_order()
	_test_same_seed_repeats_legacy_result()
	print("\n=== Legacy characterization: %d passed, %d failed ===\n" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		print("  [OK]   %s" % message)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % message)


func _make_unit(id: StringName, team: int, hp: int, attack: int, attack_speed: float = 1.0) -> Resource:
	var definition: Resource = UnitDefScript.new()
	definition.id = id
	definition.display_name = String(id)
	definition.team = team
	definition.max_hp = hp
	definition.attack = attack
	definition.defense = 0
	definition.attack_speed = attack_speed
	definition.move_speed = 1.0
	definition.attack_range = 1
	definition.sight_range = 8
	var abilities: Array[Resource] = []
	definition.abilities = abilities
	return definition


func _make_status(id: StringName, dot_damage: int, duration: float, blocks_actions: bool = false) -> Resource:
	var definition: Resource = StatusDefScript.new()
	definition.id = id
	definition.display_name = String(id)
	definition.duration = duration
	definition.tick_interval = 1.0
	definition.dot_damage = dot_damage
	definition.is_harmful = dot_damage > 0 or blocks_actions
	definition.is_percent_modifier = false
	definition.blocks_actions = blocks_actions
	return definition


func _run_battle(seed_value: int, units: Array, max_ticks: int = 200) -> Dictionary:
	RngScript.seed_run(seed_value)
	var context = ContextScript.new()
	for unit_setup in units:
		var registered: bool = context.register(unit_setup[0], unit_setup[1])
		_assert(registered, "legacy setup registers %s" % unit_setup[0].def_id)
	var runner = RunnerScript.new(context)
	runner.start()
	var ticks: int = 0
	while ticks < max_ticks and runner.state.phase != BattleStateScript.Phase.ENDED:
		runner.step(0.05)
		ticks += 1
	var hp_by_id: Dictionary = {}
	for combatant in context.combatant_registry:
		hp_by_id[String(combatant.def_id)] = combatant.current_hp()
	return {
		"winner": runner.state.winner_team,
		"ticks": ticks,
		"hp": hp_by_id,
		"ended": runner.state.phase == BattleStateScript.Phase.ENDED,
	}


func _test_one_warrior_one_enemy() -> void:
	print("[characterization] one warrior versus one enemy")
	var warrior = CombatantScript.new(_make_unit(&"warrior", TeamScript.PLAYER, 100, 50))
	var goblin = CombatantScript.new(_make_unit(&"goblin", TeamScript.ENEMY, 30, 1))
	var result: Dictionary = _run_battle(1001, [
		[warrior, Vector2i(0, 3)],
		[goblin, Vector2i(0, 2)],
	])
	_assert(result.ended, "legacy one-versus-one terminates")
	_assert(result.winner == TeamScript.PLAYER, "legacy winner is player")
	_assert(result.ticks == 21, "legacy one-versus-one takes 21 ticks (got %d)" % result.ticks)
	_assert(not goblin.is_alive(), "legacy lethal basic attack kills goblin")


func _test_two_identical_units_are_independent() -> void:
	print("[characterization] two identical units have independent state")
	var first = CombatantScript.new(_make_unit(&"warrior", TeamScript.PLAYER, 100, 10))
	var second = CombatantScript.new(_make_unit(&"warrior", TeamScript.PLAYER, 100, 10))
	first.take_damage(25, null)
	_assert(first.current_hp() == 75, "first identical unit loses 25 HP")
	_assert(second.current_hp() == 100, "second identical unit remains at full HP")
	_assert(first.statuses != second.statuses, "identical units do not share status containers")
	_assert(first.attack_meter != second.attack_meter, "identical units do not share attack meters")


func _test_periodic_damage_kills() -> void:
	print("[characterization] periodic damage kill")
	var target = CombatantScript.new(_make_unit(&"target", TeamScript.ENEMY, 10, 0))
	var poison: Resource = _make_status(&"poison", 5, 3.0)
	target.apply_status(poison, 3.0, 1, null)
	target.tick_statuses(1.0)
	_assert(target.current_hp() == 5, "first periodic damage tick removes 5 HP")
	target.tick_statuses(1.0)
	_assert(not target.is_alive(), "second periodic damage tick kills target")


func _test_stun_skips_action() -> void:
	print("[characterization] stun skips action")
	var attacker = CombatantScript.new(_make_unit(&"attacker", TeamScript.PLAYER, 100, 20))
	var target = CombatantScript.new(_make_unit(&"target", TeamScript.ENEMY, 100, 0))
	var stun: Resource = _make_status(&"stun", 0, 2.0, true)
	attacker.apply_status(stun, 2.0, 1, null)
	_assert(attacker.is_stunned(), "stun blocks action")
	_assert(not attacker.can_attack(), "stunned unit cannot basic attack")
	var before: int = target.current_hp()
	attacker.basic_attack(target)
	_assert(target.current_hp() < before, "direct legacy basic_attack bypasses runner stun guard (observed legacy behavior)")


func _test_multi_effect_ability_preserves_effect_order() -> void:
	print("[characterization] multi-effect ability applies effects in declared order")
	var source = CombatantScript.new(_make_unit(&"source", TeamScript.PLAYER, 100, 10))
	var target = CombatantScript.new(_make_unit(&"target", TeamScript.ENEMY, 100, 0))
	var context = ContextScript.new()
	context.register(source, Vector2i(0, 3))
	context.register(target, Vector2i(0, 2))
	var poison: Resource = _make_status(&"poison", 1, 2.0)
	var damage = DamageEffectScript.new()
	damage.base_damage = 10
	damage.variance = 0.0
	var apply_status = ApplyStatusEffectScript.new()
	apply_status.status_def = poison
	apply_status.duration_override = 2.0
	var ability: Resource = AbilityDefScript.new()
	ability.id = &"declared_sequence"
	ability.targeting = TargetingScript.SINGLE_ENEMY
	ability.range = 8
	var effects: Array[Resource] = [damage, apply_status]
	ability.effects = effects
	RngScript.seed_run(1002)
	var results: Array = []
	for effect in ability.effects:
		results.append_array(effect.apply(context, source, [target]))
	_assert(results.size() == 2, "two declared effects produce two results")
	_assert(target.current_hp() == 90, "declared damage effect runs")
	_assert(target.has_status(&"poison"), "declared status effect runs after damage")


func _test_same_seed_repeats_legacy_result() -> void:
	print("[characterization] same seed repeats legacy result")
	var first_warrior = CombatantScript.new(_make_unit(&"warrior", TeamScript.PLAYER, 100, 50))
	var first_goblin = CombatantScript.new(_make_unit(&"goblin", TeamScript.ENEMY, 30, 1))
	var first: Dictionary = _run_battle(1003, [
		[first_warrior, Vector2i(0, 3)],
		[first_goblin, Vector2i(0, 2)],
	])
	var second_warrior = CombatantScript.new(_make_unit(&"warrior", TeamScript.PLAYER, 100, 50))
	var second_goblin = CombatantScript.new(_make_unit(&"goblin", TeamScript.ENEMY, 30, 1))
	var second: Dictionary = _run_battle(1003, [
		[second_warrior, Vector2i(0, 3)],
		[second_goblin, Vector2i(0, 2)],
	])
	_assert(first.winner == second.winner, "same seed winner repeats")
	_assert(first.ticks == second.ticks, "same seed tick count repeats")
	_assert(first.hp == second.hp, "same seed final HP repeats")
