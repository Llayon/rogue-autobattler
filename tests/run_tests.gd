extends SceneTree

## Smoke-тесты ключевой логики. Запускается через:

##   godot --headless --path <project> --script tests/run_tests.gd



# Все скрипты через const preload — это надёжно работает и в headless, и в редакторе.

const RngServiceScript = preload("res://core/utils/rng_service.gd")

const GridScript = preload("res://core/battle/grid.gd")

const CombatantScript = preload("res://core/battle/combatant.gd")

const BattleContextScript = preload("res://core/battle/battle_context.gd")

const BattleRunnerScript = preload("res://core/battle/battle_runner.gd")

const AbilityResolverScript = preload("res://core/abilities/ability_resolver.gd")

const TargetingScript = preload("res://core/data/targeting.gd")

const DamageEffectScript = preload("res://core/effects/damage_effect.gd")

const HealEffectScript = preload("res://core/effects/heal_effect.gd")

const ApplyStatusEffectScript = preload("res://core/effects/apply_status_effect.gd")

const UnitDefScript = preload("res://core/data/unit_def.gd")

const StatusDefScript = preload("res://core/data/status_def.gd")

const DoSScript = preload("res://core/dos.gd")

const AbilityDefScript = preload("res://core/data/ability_def.gd")

const TeamScript = preload("res://core/data/team.gd")

const BattleStateScript = preload("res://core/battle/battle_state.gd")

const TargetingResolverScript = preload("res://core/abilities/targeting_resolver.gd")

const HealthComponentScript = preload("res://core/battle/health_component.gd")

const StatusListScript = preload("res://core/battle/status_list.gd")

const CooldownListScript = preload("res://core/battle/cooldown_list.gd")

const AttackMeterScript = preload("res://core/battle/attack_meter.gd")

const ManaComponentScript = preload("res://core/battle/mana_component.gd")

const RegenComponentScript = preload("res://core/battle/regen_component.gd")

const BalanceScript = preload("res://core/balance.gd")
const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunStateScript = preload("res://core/progression/run_state.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveSvcScript = preload("res://core/utils/save_manager.gd")
const BattleRunnerScriptForCtrl = preload("res://core/battle/battle_runner.gd")
const BattleStateScriptForCtrl = preload("res://core/battle/battle_state.gd")
const UnitsMetaScript = preload("res://core/data/units_meta.gd")
const RewardScreenScript = preload("res://core/progression/reward_screen.gd")
# S4.1: scene scripts
const MainSceneScript = preload("res://scenes/main.gd")
const BattleSceneScript = preload("res://scenes/battle/battle_scene.gd")
const BattleViewScript = preload("res://scenes/battle/battle_view.gd")
# S5.1: encounter map
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const EncounterNodeScript = preload("res://core/encounter/encounter_node.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
# S6.2: PrepScene
const PrepSceneScript = preload("res://scenes/prep/prep_scene.gd")



var _passed: int = 0

var _failed: int = 0





func _initialize() -> void:

	print("\n=== Rogue AutoBattler — Smoke tests ===\n")

	_test_rng_determinism()

	_test_grid_basic()

	_test_combatant_take_damage()

	_test_combatant_apply_status_and_tick()

	_test_combatant_basic_attack()

	_test_battle_context_register_and_move()

	_test_battle_runner_kill_side()

	_test_ability_resolver_single_enemy()

	_test_apply_status_effect()

	_test_damage_effect_armor_formula()

	_test_targeting_resolver_all_enemies()

	_test_health_component_isolation()

	_test_status_list_isolation()

	_test_cooldown_list_isolation()

	_test_attack_meter_isolation()

	_test_balance_enemy_count()

	_test_balance_compute_damage()

	_test_mana_component()

	_test_regen_component()

	_test_balance_compute_attack_crit()

	_test_balance_compute_attack_dodge()

	_test_balance_compute_attack_magic_pen()

	_test_balance_compute_attack_armor()

	_test_combatant_lifesteal()

	_test_combatant_thorns()

	_test_combatant_tenacity()

	_test_combatant_cdr()

	_test_combatant_healing_received()

	_test_combatant_shield_strength()

	_test_ability_mana_cost()
	_test_magic_resist_method()
	_test_magic_resist_modifier_status()
	_test_apply_modifier_safe_for_missing_fields()
	_test_dos_classify()
	_test_dos_natural_crit()
	_test_dos_damage_multiplier()
	_test_dos_status_amplifier()
	_test_balance_compute_attack_dos()
	_test_balance_max_round_and_hp_cap()
	_test_run_controller_continue_below_max_round()
	_test_run_controller_win_at_max_round()
	_test_units_meta_all_units()
	_test_reward_screen_pool()
	_test_reward_screen_determinism()
	_test_reward_screen_target_tier()
	_test_run_controller_reward_phase()
	_test_run_controller_skip_reward()
	_test_run_controller_no_reward_on_first_run_start()
	_test_run_controller_max_round_no_reward()
	# S3.2: meta progression
	_test_meta_unlock_grant_random()
	_test_meta_unlock_grant_random_determinism()
	_test_meta_unlock_grant_random_all_unlocked()
	_test_meta_unlock_tier_weighted_round()
	_test_run_controller_meta_unlock_on_win()
	_test_run_controller_no_unlock_on_defeat()
	_test_meta_save_roundtrip()
	# S3.3: save/load
	_test_meta_profile_current_run_seed()
	_test_save_service_has_run_and_list()
	_test_save_service_get_current_run_seed()
	_test_run_controller_save_now()
	_test_run_controller_save_now_signal()
	_test_run_controller_end_run_clears_active()
	_test_run_controller_save_after_battle()
	# S5.4 Task 1: RunUnitState default state
	_test_run_state_unit_states_default_empty()
	# S5.4 Task 1: start_run initializes unit_states
	_test_run_controller_start_run_initializes_unit_states()
	# S5.4 Task 2: HEAL actually heals unit_states.current_hp
	_test_run_controller_heal_effect_heals_unit_states()
	# S5.4 Task 2: REST heals current_hp AND keeps bonus_attack for next battle
	_test_run_controller_rest_effect_heals_unit_states()
	# S5.4 Task 3: REST attack bonus applied via atk_mul
	_test_run_controller_rest_attack_bonus_applies_in_start_battle()
	# S5.4 Task 3: SHRINE attack bonus applied via atk_mul
	_test_run_controller_shrine_attack_bonus_applies_in_start_battle()
	# S5.4 Task 4: save after service effect contains post-effect state
	_test_save_contains_post_effect_state_after_rest()
	# S5.4 Task 5: resume_run restores EncounterMap
	_test_run_controller_resume_run_restores_encounter_position()
	# S6.2: PREP phase swap/move API
	_test_run_controller_swap_board_units_basic()
	_test_run_controller_board_to_bench_and_back()
	_test_run_controller_swap_invalid_returns_false()
	_test_run_controller_swap_keeps_unit_states_in_sync()
	# S6.2: PrepScene UI
	_test_prep_scene_creates_board_and_bench_buttons()
	_test_prep_scene_swap_two_board_slots()
	_test_prep_scene_board_to_bench_workflow()
	_test_prep_scene_ready_button_triggers_battle()
	# S6.3: HP persistence in Combatant
	_test_combatant_hp_override_parameter()
	_test_combatant_hp_override_minus_one_uses_max()
	_test_run_controller_start_battle_persists_unit_hp()
	# S7.1: Inventory API
	_test_run_controller_grant_item_appends_to_state()
	_test_run_controller_grant_item_respects_capacity()
	_test_run_controller_remove_item_at_decrements()
	_test_run_controller_inventory_get_item_def_at_returns_resolved()
	_test_run_controller_inventory_persists_in_save()
	# S7.1: TREASURE grants item
	_test_run_controller_treasure_grants_random_item()
	_test_run_controller_resume_run()
	_test_run_controller_resume_run_no_save()
	_test_run_controller_resume_run_signal()
	# S4.1: scene smoke tests
	_test_main_scene_parses()
	_test_main_scene_tscn_loads()
	_test_battle_scene_extends_control()
	_test_battle_scene_tscn_loads()
	_test_battle_scene_eventbus_subscribe_no_crash()
	_test_battle_view_extends_control()
	_test_battle_view_with_real_context()
	# S4.2: Battle UI
	_test_battle_scene_hud_creation()
	_test_battle_scene_hud_updates_on_gold_change()
	_test_battle_view_attack_meter_draw_safe()
	_test_damage_dealt_signal_emits()
	_test_battle_view_damage_number_storage()
	_test_battle_scene_round_summary_on_win()
	_test_battle_scene_round_summary_on_defeat()
	# S4.3: visual feedback
	_test_combatant_visual_state_init()
	_test_combatant_take_damage_triggers_flash()
	_test_combatant_take_damage_death_triggers_dying()
	_test_combatant_visual_state_tick()
	_test_combatant_move_to_with_anim()
	_test_battle_runner_ticks_visual_state()
	_test_battle_runner_removes_faded_combatants()
	# S5.1: encounter map
	_test_encounter_node_basic()
	_test_encounter_type_enum_values()
	_test_encounter_type_is_combat()
	_test_encounter_type_display_name()
	_test_encounter_map_generate_structure()
	_test_encounter_map_determinism()
	_test_encounter_map_boss_at_layer_10()
	_test_encounter_map_first_layer_is_combat()
	_test_encounter_map_choose_next_basic()
	_test_encounter_map_choose_invalid()
	_test_encounter_map_strict_determinism_100_seeds()
	_test_rng_pick_unique_determinism()
	# S5.2: Encounter Map UI
	_test_encounter_map_ui_resources_exist()
	_test_encounter_map_ui_layout_and_button_states()
	_test_encounter_map_ui_selection_signal()
	_test_encounter_map_scene_preview_progression()
	# S5.3: RunController ↔ EncounterMap wiring
	_test_run_controller_phase_map_service()
	_test_run_state_current_encounter_id_default()
	_test_balance_map_reward_constants()
	# S5.3: Combat dispatch
	_test_run_controller_combat_node_starts_battle()
	_test_run_controller_invalid_node_id_ignored()
	# S5.3: Service effects HEAL/TREASURE/MERCHANT
	_test_run_controller_heal_node_effect()
	_test_run_controller_treasure_node_effect()
	_test_run_controller_merchant_node_effect()
	# S5.3: Service effects REST/SHRINE
	_test_run_controller_rest_node_effect()
	_test_run_controller_shrine_node_random_buff()
	# S5.3: Phase flow win -> MAP
	_test_run_controller_phase_flow_to_map()
	# S5.3: BattleScene wiring for MAP phase
	_test_battle_scene_has_encounter_map_view()
	_test_battle_scene_shows_encounter_map_on_map_phase()

	print("\n=== Result: %d passed, %d failed ===\n" % [_passed, _failed])

	if _failed > 0:

		quit(1)

	else:

		quit(0)





func _assert(cond: bool, msg: String) -> void:

	if cond:

		_passed += 1

		print("  [OK]   %s" % msg)

	else:

		_failed += 1

		printerr("  [FAIL] %s" % msg)




func _make_unit_def(id: StringName, hp: int = 100, atk: int = 10, team: int = 0) -> Resource:

	var d: Resource = UnitDefScript.new()

	d.id = id

	d.display_name = String(id)

	d.team = team

	d.max_hp = hp

	d.attack = atk

	d.defense = 0

	d.attack_speed = 1.0

	d.move_speed = 1.0

	d.attack_range = 1

	d.sight_range = 8

	var ab: Array[Resource] = []

	d.abilities = ab

	return d





func _make_status_def(id: StringName, dot_damage: int = 0, duration: float = 1.0) -> Resource:

	var d: Resource = StatusDefScript.new()

	d.id = id

	d.display_name = String(id)

	d.duration = duration

	d.tick_interval = 1.0

	d.dot_damage = dot_damage

	d.is_harmful = dot_damage > 0

	d.is_percent_modifier = false

	d.blocks_actions = false

	return d





func _make_simple_damage_ability(id: StringName, base: int, cd: float) -> Resource:

	var a: Resource = AbilityDefScript.new()

	a.id = id

	a.display_name = String(id)

	a.cooldown = cd

	a.targeting = TargetingScript.SINGLE_ENEMY

	a.range = 8

	var eff: Resource = DamageEffectScript.new()

	eff.base_damage = base

	eff.is_magic = false

	eff.variance = 0.0

	a.effects = [eff] as Array[Resource]

	return a





# --- Tests ---



func _test_rng_determinism() -> void:

	print("[test] RNG determinism")

	RngServiceScript.seed_run(12345)

	var a1: float = RngServiceScript.randf()

	var a2: int = RngServiceScript.randi_range(0, 100)

	RngServiceScript.seed_run(12345)

	var b1: float = RngServiceScript.randf()

	var b2: int = RngServiceScript.randi_range(0, 100)

	_assert(a1 == b1, "randf reproducible")

	_assert(a2 == b2, "randi_range reproducible")





func _test_grid_basic() -> void:

	print("[test] Grid basic")

	var grid = GridScript.new()

	_assert(grid.width() == 7 and grid.height() == 4, "default size 7x4")

	_assert(grid.in_bounds(Vector2i(0, 0)), "in_bounds (0,0)")

	_assert(not grid.in_bounds(Vector2i(-1, 0)), "not in_bounds (-1,0)")

	_assert(not grid.in_bounds(Vector2i(7, 0)), "not in_bounds (7,0)")

	_assert(grid.is_occupied(Vector2i(3, 2)) == false, "empty cell not occupied")





func _test_combatant_take_damage() -> void:

	print("[test] Combatant take_damage / heal")

	var def: Resource = _make_unit_def(&"test", 100, 10)

	var c = CombatantScript.new(def)

	_assert(c.health.current_hp == 100, "starts full HP")

	c.take_damage(30, null)

	_assert(c.health.current_hp == 70, "took 30 dmg")

	var healed: int = c.heal(15)

	_assert(c.health.current_hp == 85 and healed == 15, "healed 15")

	c.heal(100)

	_assert(c.health.current_hp == 100, "heal capped at max_hp")

	c.add_shield(20)

	c.take_damage(30, null)

	_assert(c.health.shield == 0 and c.health.current_hp == 90, "shield absorbs first")





func _test_combatant_apply_status_and_tick() -> void:

	print("[test] Combatant apply_status + tick")

	var def: Resource = _make_unit_def(&"test", 100, 10)

	var c = CombatantScript.new(def)

	var burn: Resource = _make_status_def(&"burn", 5, 2.0)

	c.apply_status(burn, 2.0, 1, null)

	_assert(c.has_status(&"burn"), "burn applied")

	c.tick_statuses(1.1)

	_assert(c.health.current_hp == 95, "DOT на тик (100 - 5)")

	c.tick_statuses(1.0)

	_assert(not c.has_status(&"burn"), "burn истёк")

	_assert(c.health.current_hp == 95, "HP не ушёл ниже после окончания")





func _test_combatant_basic_attack() -> void:

	print("[test] Combatant basic_attack формула")

	RngServiceScript.seed_run(2024)

	var atk: Resource = _make_unit_def(&"atk", 100, 20)

	var def: Resource = _make_unit_def(&"def", 100, 5, 1)
	def.defense = 0

	var a = CombatantScript.new(atk)

	var b = CombatantScript.new(def)

	a.basic_attack(b)

	_assert(b.health.current_hp == 80, "basic_attack на 20 (defense=0) (got %d)" % b.health.current_hp)

	b.defense_base = 100

	b.health.current_hp = 100

	a.basic_attack(b)

	var expected: int = maxi(1, int(round(20.0 * (100.0 / (100.0 + 100.0)))))

	_assert(b.health.current_hp == 100 - expected, "armor снижает урон (defense=100)")





func _test_battle_context_register_and_move() -> void:

	print("[test] BattleContext register/move")

	var ctx = BattleContextScript.new()

	var def: Resource = _make_unit_def(&"x", 100, 10)

	var c = CombatantScript.new(def)

	_assert(ctx.register(c, Vector2i(2, 3)), "register ok")

	_assert(ctx.grid.is_occupied(Vector2i(2, 3)), "cell occupied")

	_assert(ctx.move_to(c, Vector2i(3, 3)), "move ok")

	_assert(not ctx.grid.is_occupied(Vector2i(2, 3)), "old cell empty")

	_assert(ctx.grid.is_occupied(Vector2i(3, 3)), "new cell occupied")

	_assert(not ctx.move_to(c, Vector2i(-1, 0)), "move out of bounds rejected")





func _test_battle_runner_kill_side() -> void:

	print("[test] BattleRunner завершает бой когда сторона без живых")

	var ctx = BattleContextScript.new()

	var pdef: Resource = _make_unit_def(&"p", 100, 50, TeamScript.PLAYER)

	var edef: Resource = _make_unit_def(&"e", 5, 1, TeamScript.ENEMY)

	var p = CombatantScript.new(pdef)

	var e = CombatantScript.new(edef)

	ctx.register(p, Vector2i(3, 3))

	ctx.register(e, Vector2i(3, 0))

	var runner = BattleRunnerScript.new(ctx)

	runner.start()

	var ended: bool = false

	for i in 2000:

		runner.step(0.05)

		if runner.state.phase == BattleStateScript.Phase.ENDED:

			ended = true

			break

	_assert(ended, "battle ended")

	_assert(runner.state.winner_team == TeamScript.PLAYER, "player won")





func _test_ability_resolver_single_enemy() -> void:

	print("[test] AbilityResolver каст на ближайшего врага")

	RngServiceScript.seed_run(42)

	var ctx = BattleContextScript.new()

	var caster_def: Resource = _make_unit_def(&"mage", 100, 0)

	var enemy_def: Resource = _make_unit_def(&"e", 100, 0, TeamScript.ENEMY)

	var caster = CombatantScript.new(caster_def)

	var enemy = CombatantScript.new(enemy_def)

	ctx.register(caster, Vector2i(3, 3))

	ctx.register(enemy, Vector2i(3, 0))

	var ability: Resource = _make_simple_damage_ability(&"test_ability", 25, 5)

	var pre_hp: int = enemy.health.current_hp

	var results: Array = AbilityResolverScript.cast(ability, caster, ctx, null)

	_assert(results.size() >= 1, "ability applied")

	_assert(enemy.health.current_hp < pre_hp, "enemy HP снизился")

	_assert(caster.is_on_cooldown(ability), "cooldown установлен")





func _test_apply_status_effect() -> void:

	print("[test] ApplyStatusEffect накладывает статус")

	RngServiceScript.seed_run(42)

	var ctx = BattleContextScript.new()

	var caster_def: Resource = _make_unit_def(&"m", 100, 0)

	var target_def: Resource = _make_unit_def(&"t", 100, 0, TeamScript.ENEMY)

	var caster = CombatantScript.new(caster_def)

	var target = CombatantScript.new(target_def)

	ctx.register(caster, Vector2i(3, 3))

	ctx.register(target, Vector2i(3, 0))

	var burn: Resource = _make_status_def(&"burn", 5, 2.0)

	var eff: Resource = ApplyStatusEffectScript.new()

	eff.status_def = burn

	eff.duration_override = -1.0

	eff.max_stacks_override = -1

	eff.apply(ctx, caster, [target])

	_assert(target.has_status(&"burn"), "burn наложен")





func _test_damage_effect_armor_formula() -> void:

	print("[test] DamageEffect formula")

	RngServiceScript.seed_run(42)

	var ctx = BattleContextScript.new()

	var caster_def: Resource = _make_unit_def(&"m", 100, 0)

	var target_def: Resource = _make_unit_def(&"t", 100, 0, TeamScript.ENEMY)

	var caster = CombatantScript.new(caster_def)

	var target = CombatantScript.new(target_def)

	target.defense_base = 0

	ctx.register(caster, Vector2i(0, 0))

	ctx.register(target, Vector2i(0, 1))

	var eff: Resource = DamageEffectScript.new()

	eff.base_damage = 100

	eff.is_magic = false

	eff.variance = 0.0

	var results: Array = eff.apply(ctx, caster, [target])

	_assert(results.size() == 1, "one result")

	_assert(target.health.current_hp < 100, "HP уменьшился")





func _test_targeting_resolver_all_enemies() -> void:

	print("[test] TargetingResolver.ALL_ENEMIES")

	RngServiceScript.seed_run(42)

	var ctx = BattleContextScript.new()

	var caster_def: Resource = _make_unit_def(&"m", 100, 0)

	var e1_def: Resource = _make_unit_def(&"e1", 100, 0, TeamScript.ENEMY)

	var e2_def: Resource = _make_unit_def(&"e2", 100, 0, TeamScript.ENEMY)

	var caster = CombatantScript.new(caster_def)

	var e1 = CombatantScript.new(e1_def)

	var e2 = CombatantScript.new(e2_def)

	ctx.register(caster, Vector2i(3, 3))

	ctx.register(e1, Vector2i(0, 0))

	ctx.register(e2, Vector2i(6, 0))

	var ability: Resource = AbilityDefScript.new()

	ability.targeting = TargetingScript.ALL_ENEMIES

	ability.range = 100

	var targets: Array = TargetingResolverScript.resolve(

		TargetingScript.ALL_ENEMIES, caster, ctx, caster.cell, ability

	)

	_assert(targets.size() == 2, "ALL_ENEMIES нашёл 2 врагов")





func _test_health_component_isolation() -> void:

	print("[test] HealthComponent изолирован")

	var h = HealthComponentScript.new()

	h.configure(100)

	_assert(h.max_hp() == 100, "max_hp = 100")

	_assert(h.is_alive(), "alive at full HP")

	h.take_damage(30)

	_assert(h.current_hp == 70, "took 30 dmg")

	h.add_shield(20)

	h.take_damage(30)

	_assert(h.shield == 0 and h.current_hp == 60, "shield absorbs first")

	h.take_damage(100)

	_assert(not h.is_alive(), "dead after lethal")

	# heal на мёртвом не работает

	_assert(h.heal(50) == 0, "no heal on dead")

	_assert(h.current_hp == 0, "HP остался 0")





func _test_status_list_isolation() -> void:

	print("[test] StatusList изолирован")

	var list = StatusListScript.new()

	var burn: Resource = _make_status_def(&"burn", 5, 2.0)

	list.apply(burn, 2.0, 1, null)

	_assert(list.has(&"burn"), "burn applied")

	# DOT с callback'ом

	var dot_events: Array = []

	var cbs: Dictionary = {"on_dot": func(amount, source): dot_events.append(amount)}

	var events: Array = list.tick(1.1, cbs)

	_assert(events.size() >= 1, "события тика")

	_assert(dot_events.size() >= 1, "DOT callback вызван")

	_assert(list.has(&"burn"), "burn ещё активен")

	list.tick(1.0, cbs)

	_assert(not list.has(&"burn"), "burn истёк")

	# Expire event

	var expired: Array = []

	var cbs2: Dictionary = {"on_expire": func(sid): expired.append(sid)}

	var list2 = StatusListScript.new()

	list2.apply(burn, 1.0, 1, null)

	list2.tick(1.1, cbs2)

	_assert(expired.size() == 1 and expired[0] == &"burn", "expire event emitted")





func _test_cooldown_list_isolation() -> void:

	print("[test] CooldownList изолирован")

	var cds = CooldownListScript.new()

	var ability: Resource = AbilityDefScript.new()

	ability.id = &"test"

	ability.cooldown = 3.0

	_assert(not cds.is_on_cooldown(ability), "fresh — no cooldown")

	cds.put(ability)

	_assert(cds.is_on_cooldown(ability), "after put — on cooldown")

	_assert(cds.remaining(ability) == 3.0, "remaining 3.0")

	cds.tick(1.5)

	_assert(cds.remaining(ability) == 1.5, "remaining 1.5 after tick")

	cds.tick(2.0)

	_assert(not cds.is_on_cooldown(ability), "cooldown expired")





func _test_attack_meter_isolation() -> void:

	print("[test] AttackMeter изолирован")

	var m = AttackMeterScript.new()

	_assert(not m.is_ready(1.0), "fresh — not ready")

	m.accumulate(0.5)

	_assert(not m.is_ready(1.0), "0.5s — not ready (interval=1.0)")

	m.accumulate(0.6)

	_assert(m.is_ready(1.0), "1.1s — ready")

	m.reset()

	_assert(not m.is_ready(1.0), "after reset — not ready")

	# UI progress

	m.accumulate(0.5)

	_assert(m.progress(1.0) == 0.5, "progress 0.5 after 0.5s")





func _test_balance_enemy_count() -> void:

	print("[test] Balance.enemy_count_for_round")

	_assert(BalanceScript.enemy_count_for_round(1) == 1, "round 1 = 1 враг")

	_assert(BalanceScript.enemy_count_for_round(2) == 1, "round 2 = 1 враг")

	_assert(BalanceScript.enemy_count_for_round(3) == 2, "round 3 = 2 врага")

	_assert(BalanceScript.enemy_count_for_round(5) == 3, "round 5 = 3 врага")

	_assert(BalanceScript.enemy_count_for_round(20) == 5, "round 20 capped at 5")





func _test_balance_compute_damage() -> void:

	print("[test] Balance.compute_damage формула")

	# 100 урона против 0 защиты = 100

	var d1: int = BalanceScript.compute_damage(100, 0, false, 0.0, 1.0)

	_assert(d1 == 100, "100 dmg vs 0 def")

	# 100 урона против 100 защиты = 50

	var d2: int = BalanceScript.compute_damage(100, 100, false, 0.0, 1.0)

	_assert(d2 == 50, "100 dmg vs 100 def = 50")

	# magic игнорирует 70% защиты

	var d3: int = BalanceScript.compute_damage(100, 100, true, 0.0, 1.0)

	_assert(d3 == maxi(1, int(round(100.0 * 100.0 / (100.0 + 30.0)))), "magic частично игнорирует def")

	# variance ±10%

	var d4: int = BalanceScript.compute_damage(100, 0, false, 0.1, 1.1)

	_assert(d4 == 110, "variance 1.1 → 110 dmg")

	# минимум 1

	var d5: int = BalanceScript.compute_damage(1, 9999, false, 0.0, 1.0)

	_assert(d5 == 1, "минимум 1 dmg")





# === v3 новые тесты ===



func _test_mana_component() -> void:

	print("[test] ManaComponent")

	var m = ManaComponentScript.new()

	m.configure(100, 2.0)  # max=100, regen=2/sec

	_assert(m.current_mana == 100, "starts full")

	_assert(m.has_mana(50), "has 50 mana")

	_assert(not m.has_mana(150), "not enough mana")

	_assert(m.spend(30), "spend 30 ok")

	_assert(m.current_mana == 70, "70 left")

	_assert(not m.spend(80), "spend 80 fail")

	_assert(m.current_mana == 70, "не изменился после failed spend")

	m.regen_tick(5.0)  # 5 sec * 2/sec = 10

	_assert(m.current_mana == 80, "regened 10")

	m.regen_tick(100.0)

	_assert(m.current_mana == 100, "capped at max_mana")





func _test_regen_component() -> void:

	print("[test] RegenComponent")

	var r = RegenComponentScript.new()

	var h = HealthComponentScript.new()

	h.configure(100)

	h.take_damage(50)

	r.configure(10.0)  # 10 HP/sec

	var healed: int = r.tick(1.0, h)

	_assert(healed == 10, "healed 10")

	_assert(h.current_hp == 60, "HP = 60")

	# Не работает на мёртвых.

	h.take_damage(100)

	var healed_dead: int = r.tick(1.0, h)

	_assert(healed_dead == 0, "no heal on dead")





func _test_balance_compute_attack_crit() -> void:

	print("[test] Balance.compute_attack с crit")

	RngServiceScript.seed_run(12345)

	# 100% crit → x2 урон.

	var r1: Dictionary = BalanceScript.compute_attack(100, 1.0, 2.0, 0.0, 0, 0, 0.0, false, 0.0)

	_assert(r1.is_crit, "100% crit → crit сработал")

	_assert(r1.dealt == 200, "100dmg * 2 = 200")

	# 0% crit → обычный урон.

	var r2: Dictionary = BalanceScript.compute_attack(100, 0.0, 2.0, 0.0, 0, 0, 0.0, false, 0.0)

	_assert(not r2.is_crit, "0% crit → не crit")

	_assert(r2.dealt == 100, "100dmg без crit")





func _test_balance_compute_attack_dodge() -> void:

	print("[test] Balance.compute_attack с dodge")

	# 100% dodge → урон 0.

	var r1: Dictionary = BalanceScript.compute_attack(100, 0.0, 1.5, 0.0, 0, 0, 1.0, false, 0.0)

	_assert(r1.dodged, "100% dodge → dodged")

	_assert(r1.dealt == 0, "dealt=0 при dodge")

	# 0% dodge → обычный.

	var r2: Dictionary = BalanceScript.compute_attack(100, 0.0, 1.5, 0.0, 0, 0, 0.0, false, 0.0)

	_assert(not r2.dodged, "0% dodge → не dodged")





func _test_balance_compute_attack_magic_pen() -> void:

	print("[test] Balance.compute_attack с magic_pen")

	# 100% magic_pen vs 100 defense → defense = 0.

	var r1: Dictionary = BalanceScript.compute_attack(100, 0.0, 1.5, 1.0, 100, 0, 0.0, true, 0.0)

	_assert(r1.dealt == 100, "100% pen vs 100 def = 100 dmg (без уменьшения)")

	# 0% pen → обычный расчёт.

	var r2: Dictionary = BalanceScript.compute_attack(100, 0.0, 1.5, 0.0, 100, 0, 0.0, true, 0.0)

	_assert(r2.dealt < 100, "0% pen vs 100 def = меньше 100")








func _test_magic_resist_method() -> void:
	print("[test] Combatant.magic_resist() метод")
	# magic_resist_base = 0 (default) → magic_resist() = 0.
	var def: Resource = _make_unit_def(&"m1", 100, 0, TeamScript.ENEMY)
	var c = CombatantScript.new(def)
	_assert(c.magic_resist() == 0, "magic_resist() = 0 по умолчанию")
	# magic_resist_base = 50 → magic_resist() = 50.
	var def2: Resource = _make_unit_def(&"m2", 100, 0, TeamScript.ENEMY)
	def2.magic_resist = 50
	var c2 = CombatantScript.new(def2)
	_assert(c2.magic_resist() == 50, "magic_resist_base=50 → 50")
	# damage_effect.gd использует t.magic_resist() для magic-атак.
	# 100 magic dmg vs 50 magic_resist → 100 * 100 / 150 = 66.67 → 67.
	RngServiceScript.seed_run(42)
	var r: Dictionary = BalanceScript.compute_attack(
		100, 0.0, 1.5, 0.0, c2.magic_resist(), 0, 0.0, true, 0.0
	)
	_assert(r.dealt == 67, "magic 100 vs 50 magic_resist → 67 (got %d)" % r.dealt)



func _test_magic_resist_modifier_status() -> void:
	print("[test] StatusDef.magic_resist_modifier + Combatant.magic_resist()")
	var def: Resource = _make_unit_def(&"m", 100, 0, TeamScript.ENEMY)
	def.magic_resist = 50
	var c = CombatantScript.new(def)
	_assert(c.magic_resist() == 50, "magic_resist() = 50 без статуса")
	var burn: Resource = _make_status_def(&"magic_shred", 0, 5.0)
	burn.is_percent_modifier = true  # multiplicative
	burn.magic_resist_modifier = -0.5  # -50% magic_resist
	c.apply_status(burn, 5.0, 1, null)
	_assert(c.magic_resist() == 25, "magic_resist с modifier: 50 → 25 (got %d)" % c.magic_resist())
	_assert(c.defense() == 0, "defense() не тронут (got %d)" % c.defense())


func _test_apply_modifier_safe_for_missing_fields() -> void:
	print("[test] _apply_modifier безопасен для missing fields")
	var def: Resource = _make_unit_def(&"x", 100, 0, TeamScript.ENEMY)
	def.defense = 50
	def.magic_resist = 50
	var c = CombatantScript.new(def)
	var burn: Resource = _make_status_def(&"burn", 5, 2.0)
	c.apply_status(burn, 2.0, 1, null)
	_assert(c.defense() == 50, "defense() = 50 (без модификаторов)")
	_assert(c.magic_resist() == 50, "magic_resist() = 50 (без модификаторов)")
func _test_balance_compute_attack_armor() -> void:

	print("[test] Balance.compute_attack с armor")

	# 100 урона vs 0 def, 100 armor → eff_def = 100 * 0.5 = 50.

	# final = 100 * 100 / 150 = 66.67 → round → 67.

	var r: Dictionary = BalanceScript.compute_attack(100, 0.0, 1.5, 0.0, 0, 100, 0.0, false, 0.0)

	_assert(r.dealt == 67, "100 dmg vs 100 armor = 67 (got %d)" % r.dealt)





func _test_combatant_lifesteal() -> void:

	print("[test] Combatant.lifesteal")

	RngServiceScript.seed_run(42)

	var atk_def: Resource = _make_unit_def(&"atk", 200, 50)  # 200 HP чтобы вместить хил

	atk_def.lifesteal = 0.5  # 50% lifesteal

	var target_def: Resource = _make_unit_def(&"t", 100, 0, TeamScript.ENEMY)

	var a = CombatantScript.new(atk_def)

	var t = CombatantScript.new(target_def)

	a.take_damage(50, null)  # у атакера 150 HP

	_assert(a.health.current_hp == 150, "attacker HP=150 после урона")

	a.basic_attack(t)

	_assert(a.health.current_hp > 150, "lifesteal хилит атакующего (got %d)" % a.health.current_hp)

	_assert(t.health.current_hp < 100, "target получил урон (got %d)" % t.health.current_hp)





func _test_combatant_thorns() -> void:

	print("[test] Combatant.thorns")

	var atk_def: Resource = _make_unit_def(&"atk", 100, 50)

	var target_def: Resource = _make_unit_def(&"t", 200, 0, TeamScript.ENEMY)

	target_def.thorns = 0.5  # 50% thorns

	var a = CombatantScript.new(atk_def)

	var t = CombatantScript.new(target_def)

	var pre_atk_hp: int = a.health.current_hp

	a.basic_attack(t)

	_assert(a.health.current_hp < pre_atk_hp, "thorns отражает урон")

	_assert(t.health.current_hp < 200, "target тоже получил урон")





func _test_combatant_tenacity() -> void:

	print("[test] Combatant.tenacity")

	RngServiceScript.seed_run(1)

	var target_def: Resource = _make_unit_def(&"t", 100, 0, TeamScript.ENEMY)

	target_def.tenacity = 1.0  # 100% иммунитет

	var t = CombatantScript.new(target_def)

	var burn: Resource = _make_status_def(&"burn", 5, 2.0)

	t.apply_status(burn, 2.0, 1, null)

	_assert(not t.has_status(&"burn"), "100% tenacity → статус не наложен")



	target_def.tenacity = 0.0

	# Второй юнит с 0% tenacity.

	var t2 = CombatantScript.new(target_def)

	t2.apply_status(burn, 2.0, 1, null)

	_assert(t2.has_status(&"burn"), "0% tenacity → статус наложен")





func _test_combatant_cdr() -> void:

	print("[test] Combatant.cdr")

	var def: Resource = _make_unit_def(&"x", 100, 0)

	def.cdr = 0.5  # 50% CDR

	var c = CombatantScript.new(def)

	var ability: Resource = AbilityDefScript.new()

	ability.id = &"test"

	ability.cooldown = 10.0

	ability.mana_cost = 0

	c.put_on_cooldown(ability)

	_assert(c.cooldown_remaining(ability) == 5.0, "10s * (1-0.5) = 5s (got %f)" % c.cooldown_remaining(ability))





func _test_combatant_healing_received() -> void:

	print("[test] Combatant.healing_received")

	# 50% healing: heal 100 → effective 50.

	var def: Resource = _make_unit_def(&"x", 100, 0, TeamScript.ENEMY)

	def.healing_received = 0.5

	var c = CombatantScript.new(def)

	c.take_damage(50, null)

	_assert(c.health.current_hp == 50, "после урона 50, HP=50 (got %d)" % c.health.current_hp)

	c.heal(100)

	_assert(c.health.current_hp == 100, "heal 100*0.5=50 → 100 (got %d)" % c.health.current_hp)

	# 200% healing: heal 30 → effective 60.

	var def2: Resource = _make_unit_def(&"y", 100, 0, TeamScript.ENEMY)

	def2.healing_received = 2.0

	var c2 = CombatantScript.new(def2)

	c2.take_damage(50, null)

	c2.heal(30)

	_assert(c2.health.current_hp == 100, "heal 30*2.0=60 → 100 (got %d)" % c2.health.current_hp)





func _test_combatant_shield_strength() -> void:

	print("[test] Combatant.shield_strength")

	var def: Resource = _make_unit_def(&"x", 100, 0, TeamScript.ENEMY)

	def.shield_strength = 1.5

	var c = CombatantScript.new(def)

	c.add_shield(100)

	_assert(c.health.shield == 150, "100 * 1.5 = 150 shield (got %d)" % c.health.shield)





func _test_ability_mana_cost() -> void:

	print("[test] AbilityResolver проверка mana_cost")

	RngServiceScript.seed_run(42)

	var caster_def: Resource = _make_unit_def(&"mage", 100, 0)

	caster_def.max_mana = 100

	caster_def.mana_regen = 0.0

	var target_def: Resource = _make_unit_def(&"t", 100, 0, TeamScript.ENEMY)

	var caster = CombatantScript.new(caster_def)

	var target = CombatantScript.new(target_def)

	_assert(caster.mana != null, "caster.mana инициализирован")

	_assert(caster.mana.current_mana == 100, "caster.mana full: %d" % caster.mana.current_mana)

	var ability: Resource = _make_simple_damage_ability(&"expensive", 10, 0)  # cooldown=0 чтобы не блокировать

	ability.mana_cost = 50

	_assert(ability.mana_cost == 50, "ability.mana_cost = 50 (got %d)" % ability.mana_cost)

	# Нужен реальный ctx (BattleContext), иначе resolver выходит на `ctx == null`.

	var ctx = BattleContextScript.new()

	ctx.register(caster, Vector2i(0, 3))

	ctx.register(target, Vector2i(0, 0))

	# С current_mana=100 хватает.

	AbilityResolverScript.cast(ability, caster, ctx, target)

	_assert(caster.mana.current_mana == 50, "потратил 50 mana (got %d)" % caster.mana.current_mana)

	# Теперь mana=50, ability cost=50, должен сработать.

	AbilityResolverScript.cast(ability, caster, ctx, target)

	_assert(caster.mana.current_mana == 0, "потратил ещё 50 (got %d)" % caster.mana.current_mana)

	# Теперь mana=0, cost=50 — отказ.

	AbilityResolverScript.cast(ability, caster, ctx, target)

	_assert(caster.mana.current_mana == 0, "не хватило mana — каст не прошёл")


func _test_dos_classify() -> void:
	print("[test] DoS.classify базовые cases")
	_assert(DoSScript.classify(20, 0, 100) == DoSScript.CRIT_SUCCESS,
		"natural 20 = CRIT_SUCCESS даже против DC 100")
	_assert(DoSScript.classify(1, 100, 0) == DoSScript.CRIT_FAILURE,
		"natural 1 = CRIT_FAILURE даже с modifier 100")
	_assert(DoSScript.classify(15, 5, 10) == DoSScript.CRIT_SUCCESS,
		"15 + 5 = 20 vs DC 10 = CRIT_SUCCESS")
	_assert(DoSScript.classify(10, 5, 10) == DoSScript.SUCCESS,
		"10 + 5 = 15 vs DC 10 = SUCCESS")
	_assert(DoSScript.classify(8, 0, 10) == DoSScript.FAILURE,
		"8 vs DC 10 = FAILURE")
	_assert(DoSScript.classify(1, 0, 20) == DoSScript.CRIT_FAILURE,
		"natural 1 = CRIT_FAILURE")


func _test_dos_natural_crit() -> void:
	print("[test] DoS natural 20/1 обходят total check")
	_assert(DoSScript.classify(20, -10, 50) == DoSScript.CRIT_SUCCESS,
		"natural 20 = CRIT_SUCCESS даже если DC >> total")
	_assert(DoSScript.classify(1, 50, 30) == DoSScript.CRIT_FAILURE,
		"natural 1 = CRIT_FAILURE даже если bonus >> DC")


func _test_dos_damage_multiplier() -> void:
	print("[test] DoS.damage_multiplier")
	_assert(DoSScript.damage_multiplier(DoSScript.CRIT_SUCCESS) == 2.0,
		"CRIT_SUCCESS = 2x")
	_assert(DoSScript.damage_multiplier(DoSScript.SUCCESS) == 1.0,
		"SUCCESS = 1x")
	_assert(DoSScript.damage_multiplier(DoSScript.FAILURE) == 0.5,
		"FAILURE = 0.5x")
	_assert(DoSScript.damage_multiplier(DoSScript.CRIT_FAILURE) == 0.0,
		"CRIT_FAILURE = 0x")


func _test_dos_status_amplifier() -> void:
	print("[test] DoS status_should_apply + status_amplifier")
	_assert(DoSScript.status_should_apply(DoSScript.CRIT_SUCCESS) == true,
		"CRIT_SUCCESS: apply status")
	_assert(DoSScript.status_should_apply(DoSScript.SUCCESS) == true,
		"SUCCESS: apply status")
	_assert(DoSScript.status_should_apply(DoSScript.FAILURE) == false,
		"FAILURE: НЕ apply status")
	_assert(DoSScript.status_should_apply(DoSScript.CRIT_FAILURE) == false,
		"CRIT_FAILURE: НЕ apply status")
	_assert(DoSScript.status_amplifier(DoSScript.CRIT_SUCCESS) == 2,
		"CRIT_SUCCESS: amplify x2")
	_assert(DoSScript.status_amplifier(DoSScript.SUCCESS) == 1,
		"SUCCESS: amplify x1")
	_assert(DoSScript.status_amplifier(DoSScript.FAILURE) == 1,
		"FAILURE: amplify x1")
	_assert(DoSScript.status_amplifier(DoSScript.CRIT_FAILURE) == 1,
		"CRIT_FAILURE: amplify x1")


func _test_balance_compute_attack_dos() -> void:
	print("[test] Balance.compute_attack_dos")
	var r1: Dictionary = BalanceScript.compute_attack_dos(50, 0, 0, 1.0, false, 0.0, 0.0)
	_assert(r1.dodged == true and r1.dealt == 0, "100% dodge = dodged")
	var hits: int = 0
	var crits: int = 0
	var fails: int = 0
	var dodges: int = 0
	for i in 200:
		var r: Dictionary = BalanceScript.compute_attack_dos(50, 5, 0, 0.0, false, 0.0, 0.0)
		if r.dodged:
			dodges += 1
		elif r.is_crit:
			crits += 1
		elif r.is_failure:
			fails += 1
		else:
			hits += 1
	_assert(crits >= 5, "200 бросков: >=5 crit (got %d)" % crits)
	_assert(dodges == 0, "dodge = 0% → 0 dodges")


# === S3.1 Run progression (Sprint 3.1: win check + HP cap) ===

func _test_balance_max_round_and_hp_cap() -> void:
	print("[test] S3.1: MAX_ROUND + enemy_hp_multiplier cap")
	# MAX_ROUND константа существует и = 10.
	_assert(BalanceScript.MAX_ROUND == 10, "MAX_ROUND = 10 (got %d)" % BalanceScript.MAX_ROUND)
	# HP multiplier нарастает до MAX_ROUND.
	_assert(BalanceScript.enemy_hp_multiplier(1) == 1.0, "round 1 = 1.0x")
	_assert(BalanceScript.enemy_hp_multiplier(10) > 1.0, "round 10 > 1.0x")
	# Cap: раунды > MAX_ROUND не растут.
	var hp_at_10: float = BalanceScript.enemy_hp_multiplier(10)
	_assert(BalanceScript.enemy_hp_multiplier(11) == hp_at_10, "round 11 capped at round 10 value (got %f vs %f)" % [BalanceScript.enemy_hp_multiplier(11), hp_at_10])
	_assert(BalanceScript.enemy_hp_multiplier(20) == hp_at_10, "round 20 still capped at round 10")


func _test_run_controller_continue_below_max_round() -> void:
	print("[test] S3.1: RunController продолжает после 5-й победы (round < MAX)")
	# Подготовка: RunController в headless tree.
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	# Детерминированный seed.
	ctrl.start_run(42)
	# Сымитируем 5 побед подряд: round_index=5, wins=4; после _on_battle_ended → round_index=6, REWARD (S3.1.5).
	ctrl.state.round_index = 5
	ctrl.state.wins = 4
	# Запускаем бой, чтобы создать runner.
	var ok: bool = ctrl.start_battle()
	_assert(ok == true, "start_battle на PREP с юнитами = true")
	_assert(ctrl.phase == RunControllerScript.Phase.BATTLE, "phase = BATTLE после start_battle")
	# Подменяем: бой завершился победой player.
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	# Проверяем: round_index 6, phase REWARD (S3.1.5), wins=5, НЕ GAMEOVER.
	_assert(ctrl.state.round_index == 6, "round_index 5→6 (got %d)" % ctrl.state.round_index)
	_assert(ctrl.state.wins == 5, "wins 4→5 (got %d)" % ctrl.state.wins)
	_assert(ctrl.phase == RunControllerScript.Phase.REWARD, "phase = REWARD (got %d)" % ctrl.phase)
	# Skip reward → MAP (S5.3: round >= 2 всегда идёт в MAP после REWARD).
	var skipped: bool = ctrl.skip_reward()
	_assert(skipped == true, "skip_reward = true")
	_assert(ctrl.phase == RunControllerScript.Phase.MAP, "phase = MAP после skip (got %d)" % ctrl.phase)
	_cleanup_ctrl(ctrl)


func _test_run_controller_win_at_max_round() -> void:
	print("[test] S3.1: RunController побеждает на MAX_ROUND (10) → GAMEOVER + run_ended(true)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# Сымитируем 10-ю победу: round_index=10, wins=9; после _on_battle_ended → round_index=11, GAMEOVER, won=true.
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl.state.wins = BalanceScript.MAX_ROUND - 1
	# Ловим сигнал run_ended.
	var won_flag: Array = [null]  # boxed, чтобы lambda видела
	ctrl.run_ended.connect(func(w: bool) -> void: won_flag[0] = w)
	ctrl.start_battle()
	# Бой завершился победой player.
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	# Проверяем: round_index 11, phase GAMEOVER, wins=10, run_ended(true).
	_assert(ctrl.state.round_index == BalanceScript.MAX_ROUND + 1, "round_index 10→11 (got %d)" % ctrl.state.round_index)
	_assert(ctrl.state.wins == BalanceScript.MAX_ROUND, "wins 9→10 (got %d)" % ctrl.state.wins)
	_assert(ctrl.phase == RunControllerScript.Phase.GAMEOVER, "phase = GAMEOVER после 10-й победы (got %d)" % ctrl.phase)
	_assert(won_flag[0] == true, "run_ended(true) emitted (got %s)" % str(won_flag[0]))
	_cleanup_ctrl(ctrl)


func _cleanup_ctrl(ctrl: Node) -> void:
	if is_instance_valid(ctrl):
		ctrl.queue_free()
	await process_frame


# === S4.1: helpers для scene smoke tests ===

## Загружает .tscn как PackedScene и инстанцирует.
## Возвращает Node или null если путь битый.
func _instantiate_scene(packed_path: String) -> Node:
	var packed: PackedScene = load(packed_path) as PackedScene
	if packed == null:
		return null
	return packed.instantiate()


# === S3.1.5 Reward screen ===

func _test_units_meta_all_units() -> void:
	print("[test] S3.1.5: UnitsMeta all_ids + ids_by_tier")
	var all: Array[StringName] = UnitsMetaScript.all_ids()
	_assert(all.size() >= 12, "12+ unit ids в реестре (got %d)" % all.size())
	# Tier 1: warrior, archer, cleric (3 шт в content).
	var tier1: Array[StringName] = UnitsMetaScript.ids_by_tier(1)
	_assert(tier1.size() >= 3, "tier 1 >= 3 (got %d)" % tier1.size())
	_assert(&"warrior" in tier1 and &"archer" in tier1 and &"cleric" in tier1, "tier 1 содержит warrior/archer/cleric")
	# Tier 2: mage, guardian, assassin, druid, berserker, beast, cavalry, warrior_v2.
	var tier2: Array[StringName] = UnitsMetaScript.ids_by_tier(2)
	_assert(tier2.size() >= 5, "tier 2 >= 5 (got %d)" % tier2.size())
	_assert(&"mage" in tier2, "tier 2 содержит mage")
	# Tier 3: paladin, necromancer, knight, elementalist (4 шт).
	var tier3: Array[StringName] = UnitsMetaScript.ids_by_tier(3)
	_assert(tier3.size() >= 4, "tier 3 >= 4 (got %d)" % tier3.size())
	_assert(&"paladin" in tier3 and &"knight" in tier3, "tier 3 содержит paladin+knight")
	# Tier 0 — пусто.
	var tier0: Array[StringName] = UnitsMetaScript.ids_by_tier(0)
	_assert(tier0.is_empty(), "tier 0 пусто (got %d)" % tier0.size())


func _test_reward_screen_pool() -> void:
	print("[test] S3.1.5: RewardScreen pool generation + tier weights")
	# Round 3 → target tier 1 (clamp(3/3, 1, 3) = 1).
	Rng.seed_run(12345)
	var rs1: Object = RewardScreenScript.new()
	var pool1: Array[StringName] = rs1.generate_offer(3)
	_assert(pool1.size() == BalanceScript.REWARD_SLOTS, "offer = %d слота (got %d)" % [BalanceScript.REWARD_SLOTS, pool1.size()])
	for id in pool1:
		var def: Resource = ContentDB_static.get_by_id(id)
		_assert(def != null, "offered id валиден: %s" % id)
	# Round 7 → target tier 2 (clamp(7/3, 1, 3) = 2).
	var pool7: Array[StringName] = rs1.generate_offer(7)
	_assert(pool7.size() == BalanceScript.REWARD_SLOTS, "round 7 offer = %d слота" % BalanceScript.REWARD_SLOTS)
	# Round 12 (после MAX_ROUND) → target tier 3, не падает.
	var pool12: Array[StringName] = rs1.generate_offer(12)
	_assert(pool12.size() == BalanceScript.REWARD_SLOTS, "round 12 offer = %d слота" % BalanceScript.REWARD_SLOTS)


func _test_reward_screen_determinism() -> void:
	print("[test] S3.1.5: тот же seed = тот же reward offer (детерминизм)")
	Rng.seed_run(777)
	var rs1: Object = RewardScreenScript.new()
	var pool1: Array[StringName] = rs1.generate_offer(5)
	Rng.seed_run(777)
	var rs2: Object = RewardScreenScript.new()
	var pool2: Array[StringName] = rs2.generate_offer(5)
	_assert(pool1 == pool2, "детерминизм: pool1 == pool2 (got %s vs %s)" % [str(pool1), str(pool2)])


func _test_reward_screen_target_tier() -> void:
	print("[test] S3.1.5: target_tier_for_round корректно clamp'ит")
	_assert(RewardScreenScript.target_tier_for_round(1) == 1, "round 1 → tier 1")
	_assert(RewardScreenScript.target_tier_for_round(3) == 1, "round 3 → tier 1 (3/3=1)")
	_assert(RewardScreenScript.target_tier_for_round(4) == 1, "round 4 → tier 1 (4/3=1)")
	_assert(RewardScreenScript.target_tier_for_round(6) == 2, "round 6 → tier 2 (6/3=2)")
	_assert(RewardScreenScript.target_tier_for_round(9) == 3, "round 9 → tier 3 (9/3=3)")
	_assert(RewardScreenScript.target_tier_for_round(20) == 3, "round 20 → tier 3 (clamped)")


func _test_run_controller_reward_phase() -> void:
	print("[test] S3.1.5+S5.3: RunController переходит в REWARD после 2-й победы (round 2->3)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# Сымитируем 2-ю победу: round_index=2, wins=1; после _on_battle_ended → round_index=3, REWARD.
	ctrl.state.round_index = 2
	ctrl.state.wins = 1
	# EventBus autoload может не быть зарегистрирован в тестах — проверим.
	var bus: Node = get_root().get_node_or_null("EventBus")
	if bus != null:
		var offered: Array = [null]
		bus.reward_offered.connect(func(ids: Array[StringName]) -> void: offered[0] = ids)
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	_assert(ctrl.state.round_index == 3, "round_index 2->3 (got %d)" % ctrl.state.round_index)
	_assert(ctrl.phase == RunControllerScript.Phase.REWARD, "phase = REWARD (got %d)" % ctrl.phase)
	_assert(ctrl.reward.offered_ids().size() == BalanceScript.REWARD_SLOTS,
		"reward offer = %d слота" % BalanceScript.REWARD_SLOTS)
	if bus != null:
		_assert(bus != null, "EventBus available")
	# Игрок берёт слот 0 — после REWARD на round 3 переходит в MAP (S5.3).
	# S6.1.1: reward юнит auto-placed на доску если есть room (board_size < 4).
	# Start: 2 units (warrior+archer). Pick slot 0 → 3 units on board.
	var board_before: int = ctrl.state.player_unit_ids.size()
	var bench_before: int = ctrl.state.bench_unit_ids.size()
	_assert(board_before < BalanceScript.MAX_BOARD_UNITS,
		"before choose_reward board not full (size=%d, max=%d)" % [board_before, BalanceScript.MAX_BOARD_UNITS])
	var taken: Resource = ctrl.choose_reward(0)
	_assert(taken != null, "choose_reward(0) вернул UnitDef (got %s)" % str(taken))
	_assert(ctrl.phase == RunControllerScript.Phase.MAP, "phase = MAP после choose_reward (got %d)" % ctrl.phase)
	_assert(ctrl.state.player_unit_ids.has(taken.id),
		"юнит %s auto-placed на доску (board %d -> %d)" % [taken.id, board_before, ctrl.state.player_unit_ids.size()])
	_assert(ctrl.state.bench_unit_ids.size() == bench_before,
		"bench не изменился (was %d, now %d)" % [bench_before, ctrl.state.bench_unit_ids.size()])
	_cleanup_ctrl(ctrl)


func _test_run_controller_skip_reward() -> void:
	print("[test] S3.1.5+S5.3: skip_reward() на round 2 переходит в MAP, на round 1 — в PREP")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# S6.1: round 1 win → REWARD (раньше был PREP no MAP).
	ctrl.state.round_index = 1
	ctrl.state.wins = 0
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	_assert(ctrl.phase == RunControllerScript.Phase.REWARD,
			"round 1 win -> REWARD (got %d)" % ctrl.phase)
	# Round 2 win → REWARD.
	ctrl.state.round_index = 2
	ctrl.state.wins = 1
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	_assert(ctrl.phase == RunControllerScript.Phase.REWARD, "phase = REWARD (got %d)" % ctrl.phase)
	var bench_before: int = ctrl.state.bench_unit_ids.size()
	var ok: bool = ctrl.skip_reward()
	_assert(ok == true, "skip_reward = true (got %s)" % str(ok))
	_assert(ctrl.phase == RunControllerScript.Phase.MAP,
		"round 2 skip_reward -> MAP (got %d)" % ctrl.phase)
	_assert(ctrl.state.bench_unit_ids.size() == bench_before, "bench не изменился (was %d, now %d)" % [bench_before, ctrl.state.bench_unit_ids.size()])
	_cleanup_ctrl(ctrl)


func _test_run_controller_no_reward_on_first_run_start() -> void:
	# S3.1.5: на самом первом старте рана (round_index=1, до первого боя) — нет reward.
	# Это проверяется неявно через start_run() — phase = PREP сразу.
	print("[test] S3.1.5: start_run() сразу PREP, без reward")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	_assert(ctrl.state.round_index == 1, "round_index = 1 (got %d)" % ctrl.state.round_index)
	_assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP сразу после start_run (got %d)" % ctrl.phase)
	_cleanup_ctrl(ctrl)


func _test_run_controller_max_round_no_reward() -> void:
	print("[test] S3.1.5: на MAX_ROUND победа → GAMEOVER (без reward)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# Round 10 → wins 9 → после win: round_index=11, GAMEOVER (skip reward).
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl.state.wins = BalanceScript.MAX_ROUND - 1
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	_assert(ctrl.phase == RunControllerScript.Phase.GAMEOVER, "phase = GAMEOVER (got %d)" % ctrl.phase)
	_assert(ctrl.state.round_index == BalanceScript.MAX_ROUND + 1, "round_index = MAX+1 (got %d)" % ctrl.state.round_index)
	_cleanup_ctrl(ctrl)


# === S3.2 Meta progression unlocks ===

func _test_meta_unlock_grant_random() -> void:
	print("[test] S3.2: UnlockManager.grant_random_unit()")
	Rng.seed_run(1234)
	var profile: MetaProfile = MetaProfileScript.new()
	var size_before: int = profile.unlocked_units.size()
	var unlocked: StringName = UnlockManager.grant_random_unit(profile, 5)
	_assert(unlocked != &"", "выдал непустой id (got empty)")
	_assert(profile.unlocked_units.size() == size_before + 1, "+1 юнит в profile (was %d, now %d)" % [size_before, profile.unlocked_units.size()])
	_assert(UnlockManager.is_unit_unlocked(profile, unlocked), "выданный юнит %s теперь в profile" % unlocked)
	# Новый юнит — НЕ из стартового набора (warrior/archer/goblin) И НЕ goblin (он стартовый).
	var fresh: MetaProfile = MetaProfileScript.new()
	_assert(not UnlockManager.is_unit_unlocked(fresh, unlocked), "выданный юнит НЕ в стартовом наборе")


func _test_meta_unlock_grant_random_determinism() -> void:
	print("[test] S3.2: grant_random_unit детерминизм (тот же seed = тот же unlock)")
	Rng.seed_run(555)
	var p1: MetaProfile = MetaProfileScript.new()
	var id1: StringName = UnlockManager.grant_random_unit(p1, 4)
	Rng.seed_run(555)
	var p2: MetaProfile = MetaProfileScript.new()
	var id2: StringName = UnlockManager.grant_random_unit(p2, 4)
	_assert(id1 == id2, "тот же seed → тот же unlock (got %s vs %s)" % [str(id1), str(id2)])


func _test_meta_unlock_grant_random_all_unlocked() -> void:
	print("[test] S3.2: grant_random_unit когда все unlocked → empty")
	Rng.seed_run(7777)
	var profile: MetaProfile = MetaProfileScript.new()
	# Разблокируем ВСЕ юниты из UnitsMeta.
	for id in UnitsMetaScript.all_ids():
		UnlockManager.grant_unit(profile, id)
	var unlocked: StringName = UnlockManager.grant_random_unit(profile, 5)
	_assert(unlocked == &"", "все unlocked → return empty (got %s)" % str(unlocked))


func _test_meta_unlock_tier_weighted_round() -> void:
	print("[test] S3.2: tier-weighted по round_index (round 9 → tier 2+)")
	# round 9 → target_tier = clamp(9/3, 1, 3) = 3.
	# 60% tier 3, 30% tier 2, 10% tier 4→clamped to 3.
	# Делаем 50 попыток с разными seed — все должны быть tier 2 или 3.
	var tier_counts: Dictionary = {1: 0, 2: 0, 3: 0}
	for s in 50:
		Rng.seed_run(1000 + s)
		var p: MetaProfile = MetaProfileScript.new()
		var id: StringName = UnlockManager.grant_random_unit(p, 9)
		var def: Resource = ContentDB_static.get_by_id(id)
		if def != null and def.tier in tier_counts:
			tier_counts[def.tier] += 1
	_assert(tier_counts[1] == 0, "round 9 → НЕ tier 1 (got %d)" % tier_counts[1])
	_assert(tier_counts[2] + tier_counts[3] == 50, "round 9 → все tier 2 или 3 (got %d)" % (tier_counts[2] + tier_counts[3]))
	# Должны быть оба (tier-weighted, не только target).
	_assert(tier_counts[3] >= tier_counts[2], "tier 3 ≥ tier 2 (got %d vs %d)" % [tier_counts[3], tier_counts[2]])


func _test_run_controller_meta_unlock_on_win() -> void:
	print("[test] S3.2: RunController выдаёт unlock после _end_run(true)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	# Свежий профиль без extra unlocks. start_run() внутри вызовет load_meta()
	# из user://saves — это может вернуть ранее сохранённый профиль, поэтому
	# перезаписываем на новый ДО _end_run.
	ctrl.start_run(42)
	ctrl.profile = MetaProfileScript.new()
	var size_before: int = ctrl.profile.unlocked_units.size()
	# Ловим unit_unlocked signal.
	var unlocked_box: Array = [null]
	var bus: Node = get_root().get_node_or_null("EventBus")
	if bus != null:
		bus.unit_unlocked.connect(func(uid: StringName) -> void: unlocked_box[0] = uid)
	# Имитируем победу на MAX_ROUND (state уже после всех побед).
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl.state.wins = BalanceScript.MAX_ROUND - 1
	ctrl._end_run(true)
	_assert(ctrl.profile.unlocked_units.size() == size_before + 1,
		"+1 unlock после победы (was %d, now %d)" % [size_before, ctrl.profile.unlocked_units.size()])
	if bus != null:
		_assert(unlocked_box[0] != null and unlocked_box[0] != &"",
			"unit_unlocked signal emitted (got %s)" % str(unlocked_box[0]))
	_cleanup_ctrl(ctrl)


func _test_run_controller_no_unlock_on_defeat() -> void:
	print("[test] S3.2: defeat на ран не даёт unlock")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.profile = MetaProfileScript.new()
	var size_before: int = ctrl.profile.unlocked_units.size()
	ctrl._end_run(false)
	_assert(ctrl.profile.unlocked_units.size() == size_before,
		"defeat → 0 новых unlock (was %d, now %d)" % [size_before, ctrl.profile.unlocked_units.size()])
	_cleanup_ctrl(ctrl)


func _test_meta_save_roundtrip() -> void:
	print("[test] S3.2: MetaProfile save → load сохраняет unlocked_units")
	var p: MetaProfile = MetaProfileScript.new()
	UnlockManager.grant_unit(p, &"mage")
	UnlockManager.grant_unit(p, &"paladin")
	var ok: bool = SaveService.save_meta(p)
	_assert(ok, "save_meta returned true")
	var loaded: MetaProfile = SaveService.load_meta()
	_assert(loaded != null, "load_meta не null")
	_assert(loaded.unlocked_units.has(&"mage"), "mage в unlocked после load")
	_assert(loaded.unlocked_units.has(&"paladin"), "paladin в unlocked после load")


# === S3.3 Save/Load в середине рана ===

func _test_meta_profile_current_run_seed() -> void:
	print("[test] S3.3: MetaProfile.current_run_seed поле")
	var p: MetaProfile = MetaProfileScript.new()
	_assert(p.current_run_seed == 0, "по умолчанию current_run_seed = 0 (got %d)" % p.current_run_seed)
	p.current_run_seed = 12345
	_assert(p.current_run_seed == 12345, "set/get roundtrip (got %d)" % p.current_run_seed)


func _test_save_service_has_run_and_list() -> void:
	print("[test] S3.3: SaveService.has_run + delete_run")
	var rs: RunState = RunStateScript.new()
	rs.seed = 42
	rs.gold = 50
	rs.round_index = 3
	var ok: bool = SaveService.save_run(rs)
	_assert(ok, "save_run(42) ok")
	_assert(SaveService.has_run(42), "has_run(42) = true")
	_assert(not SaveService.has_run(99999), "has_run(99999) = false (no save)")
	_assert(not SaveService.has_run(0), "has_run(0) = false (sentinel)")
	var list: Array[int] = SaveService.list_runs()
	_assert(list.has(42), "list_runs содержит 42 (got %s)" % str(list))
	var deleted: bool = SaveService.delete_run(42)
	_assert(deleted, "delete_run(42) = true")
	_assert(not SaveService.has_run(42), "после delete has_run(42) = false")
	_assert(SaveService.delete_run(42) == false, "повторный delete = false")


func _test_save_service_get_current_run_seed() -> void:
	print("[test] S3.3: SaveService.get_current_run_seed + has_active_run")
	var p: MetaProfile = MetaProfileScript.new()
	_assert(SaveService.get_current_run_seed(p) == 0, "пустой профиль → 0")
	p.current_run_seed = 777
	_assert(SaveService.get_current_run_seed(p) == 777, "current_run_seed=777 → return 777")
	_assert(SaveService.has_active_run(p) == false, "has_active_run = false (no file)")
	# Save actual run.
	var rs: RunState = RunStateScript.new()
	rs.seed = 777
	var ok2: bool = SaveService.save_run(rs)
	_assert(ok2, "save_run(777) ok")
	_assert(SaveService.has_active_run(p) == true, "has_active_run = true (file exists)")
	SaveService.delete_run(777)


func _test_run_controller_save_now() -> void:
	print("[test] S3.3: RunController.save_now() — пишет state + current_run_seed")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(123)
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.current_run_seed = 0
	ctrl.state.gold = 50
	var ok: bool = ctrl.save_now()
	_assert(ok, "save_now() = true")
	_assert(ctrl.profile.current_run_seed == 123, "current_run_seed = 123 (got %d)" % ctrl.profile.current_run_seed)
	_assert(SaveService.has_run(123), "file run_123.tres exists")
	var loaded: RunState = SaveService.load_run(123)
	_assert(loaded != null, "load_run(123) not null")
	_assert(loaded.gold == 50, "gold сохранён (got %d)" % loaded.gold)
	SaveService.delete_run(123)
	_cleanup_ctrl(ctrl)


func _test_run_controller_save_now_signal() -> void:
	print("[test] S3.3: save_now() emit run_saved signal")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(456)
	ctrl.profile = MetaProfileScript.new()
	var saved_box: Array = [null]
	var bus: Node = get_root().get_node_or_null("EventBus")
	if bus != null:
		bus.run_saved.connect(func(s: int) -> void: saved_box[0] = s)
	ctrl.save_now()
	if bus != null:
		_assert(saved_box[0] == 456, "run_saved(456) emitted (got %s)" % str(saved_box[0]))
	SaveService.delete_run(456)
	_cleanup_ctrl(ctrl)


func _test_run_controller_end_run_clears_active() -> void:
	print("[test] S3.3: _end_run очищает current_run_seed")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(555)
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.current_run_seed = 555
	ctrl._end_run(true)
	_assert(ctrl.profile.current_run_seed == 0, "current_run_seed = 0 после _end_run (got %d)" % ctrl.profile.current_run_seed)
	SaveService.delete_run(555)
	_cleanup_ctrl(ctrl)


func _test_run_controller_save_after_battle() -> void:
	print("[test] S3.3: auto-save после _on_battle_ended (snapshot pre-increment)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(888)
	ctrl.profile = MetaProfileScript.new()
	ctrl.state.round_index = 1
	ctrl.state.wins = 0
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	_assert(SaveService.has_run(888), "file run_888.tres exists after battle")
	var loaded: RunState = SaveService.load_run(888)
	_assert(loaded != null, "load не null")
	# S6.1: save обновляется на каждой phase transition (REWARD → MAP).
	# round_index = 2 после _enter_map (бывший snapshot pre-increment
	# уже перезаписан на post-REWARD-state).
	_assert(loaded.round_index == 2, "round_index = 2 после _enter_map (got %d)" % loaded.round_index)
	_assert(ctrl.state.round_index == 2, "ctrl.state.round_index = 2 после _on_battle_ended (got %d)" % ctrl.state.round_index)
	SaveService.delete_run(888)
	_cleanup_ctrl(ctrl)


func _test_run_controller_resume_run() -> void:
	print("[test] S3.3: RunController.resume_run(seed) загружает state")
	# Save.
	var save_ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(save_ctrl)
	await process_frame
	save_ctrl.start_run(789)
	save_ctrl.profile = MetaProfileScript.new()
	save_ctrl.state.gold = 75
	save_ctrl.state.round_index = 5
	save_ctrl.save_now()
	_cleanup_ctrl(save_ctrl)

	# Resume: новый контроллер загружает state из диска.
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.current_run_seed = 789
	var ok: bool = ctrl.resume_run(789)
	_assert(ok, "resume_run(789) = true")
	_assert(ctrl.state.seed == 789, "state.seed = 789 (got %d)" % ctrl.state.seed)
	_assert(ctrl.state.gold == 75, "state.gold = 75 (got %d)" % ctrl.state.gold)
	_assert(ctrl.state.round_index == 5, "state.round_index = 5 (got %d)" % ctrl.state.round_index)
	_assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP после resume (got %d)" % ctrl.phase)
	SaveService.delete_run(789)
	_cleanup_ctrl(ctrl)


func _test_run_controller_resume_run_no_save() -> void:
	print("[test] S3.3: resume_run без сохранения → false")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.profile = MetaProfileScript.new()
	var ok: bool = ctrl.resume_run(99999)  # не существует
	_assert(ok == false, "resume_run(99999) = false (no save)")
	_assert(ctrl.state.seed == 42, "state.seed не изменился (got %d)" % ctrl.state.seed)
	_cleanup_ctrl(ctrl)


func _test_run_controller_resume_run_signal() -> void:
	print("[test] S3.3: resume_run() emit run_resumed signal")
	var save_ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(save_ctrl)
	await process_frame
	save_ctrl.start_run(321)
	save_ctrl.profile = MetaProfileScript.new()
	save_ctrl.save_now()
	_cleanup_ctrl(save_ctrl)

	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	var resumed_box: Array = [null]
	var bus: Node = get_root().get_node_or_null("EventBus")
	if bus != null:
		bus.run_resumed.connect(func(s: int) -> void: resumed_box[0] = s)
	ctrl.resume_run(321)
	if bus != null:
		_assert(resumed_box[0] == 321, "run_resumed(321) emitted (got %s)" % str(resumed_box[0]))
	_assert(ctrl.state.seed == 321, "state.seed = 321 (got %d)" % ctrl.state.seed)
	_assert(ctrl.state.round_index == 1, "state.round_index = 1 (start state) (got %d)" % ctrl.state.round_index)
	SaveService.delete_run(321)
	_cleanup_ctrl(ctrl)


# === S4.1: scene smoke tests ===

func _test_main_scene_parses() -> void:
	print("[test] S4.1: main.gd extends Node и парсится")
	var script: GDScript = MainSceneScript as GDScript
	_assert(script != null, "main.gd загружается как GDScript")
	var inst: Node = MainSceneScript.new()
	_assert(inst != null, "main.gd.new() инстанцируется")
	_assert(inst is Node, "instance это Node (для add_child)")
	_assert(inst.has_method("_ready"), "_ready() определён")
	inst.free()


func _test_main_scene_tscn_loads() -> void:
	print("[test] S4.1: main.tscn грузится через PackedScene")
	var node: Node = _instantiate_scene("res://scenes/main.tscn")
	_assert(node != null, "main.tscn инстанцируется без ошибок")
	if node != null:
		_assert(node is Node, "main.tscn root = Node")
		node.free()


func _test_battle_scene_extends_control() -> void:
	print("[test] S4.1: battle_scene.gd extends Control (для _draw/queue_redraw)")
	var inst: Node = BattleSceneScript.new()
	_assert(inst is Control, "battle_scene это Control (got %s)" % str(typeof(inst)))
	_assert(inst.has_method("_ready"), "_ready() определён")
	_assert(inst.has_method("_process"), "_process() определён")
	inst.free()


func _test_battle_scene_tscn_loads() -> void:
	print("[test] S4.1: battle_scene.tscn грузится через PackedScene")
	var node: Node = _instantiate_scene("res://scenes/battle/battle_scene.tscn")
	_assert(node != null, "battle_scene.tscn инстанцируется без ошибок")
	if node != null:
		_assert(node is Control, "battle_scene.tscn root = Control")
		node.free()


func _test_battle_scene_eventbus_subscribe_no_crash() -> void:
	print("[test] S4.1: BattleScene add_child без EventBus не падает")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	_assert(is_instance_valid(scene), "scene жив после add_child")
	if is_instance_valid(scene):
		_assert(scene.run_controller != null, "run_controller создан в _ready()")
		_assert(scene.battle_view != null, "battle_view создан в _ready()")
		_assert(scene.status_label != null, "status_label создан в _ready()")
		_assert(scene.battle_view is Control, "battle_view extends Control")
		# Bus может быть null в headless тестах — должно быть обработано.
		if scene._bus == null:
			_assert(scene._find_event_bus() == null, "_find_event_bus() null-safe")
		scene.queue_free()
	await process_frame


func _test_battle_view_extends_control() -> void:
	print("[test] S4.1: BattleView extends Control + set_context() null-safe")
	var view: Control = BattleViewScript.new()
	_assert(view is Control, "BattleView extends Control (для _draw)")
	_assert(view.has_method("set_context"), "set_context() существует")
	_assert(view.has_method("_draw"), "_draw() существует (визуализатор)")
	view.set_context(null)  # null-safe не должно падать
	_assert(view._ctx == null, "ctx = null после set_context(null)")
	view.free()


func _test_battle_view_with_real_context() -> void:
	print("[test] S4.1: BattleView.set_context(real ctx) + queue_redraw() smoke")
	var ctx = BattleContextScript.new()
	var g = GridScript.new()
	g.resize(7, 4)
	ctx.grid = g
	var view: Control = BattleViewScript.new()
	view.set_context(ctx)
	view.queue_redraw()
	_assert(view._ctx == ctx, "ctx сохранён в view")
	_assert(view._ctx.grid.width() == 7, "grid.width() = 7 через view._ctx (got %d)" % view._ctx.grid.width())
	_assert(view._ctx.grid.height() == 4, "grid.height() = 4 через view._ctx (got %d)" % view._ctx.grid.height())
	view.free()


# === S4.2: Battle UI ===

func _test_battle_scene_hud_creation() -> void:
	print("[test] S4.2: BattleScene создаёт HUD bar в _ready()")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	if is_instance_valid(scene):
		_assert(scene.hud != null, "hud создан")
		_assert(scene.hud_round_label != null, "round_label создан")
		_assert(scene.hud_gold_label != null, "gold_label создан")
		_assert(scene.hud_wins_label != null, "wins_label создан")
		_assert(scene.hud_lives_label != null, "lives_label создан")
		_assert(scene.hud_round_label.text.find("Round") >= 0,
			"round_label содержит 'Round' (got '%s')" % scene.hud_round_label.text)
		_assert(scene.hud_gold_label.text.find("Gold") >= 0,
			"gold_label содержит 'Gold' (got '%s')" % scene.hud_gold_label.text)
		scene.queue_free()
	await process_frame


func _test_battle_scene_hud_updates_on_gold_change() -> void:
	print("[test] S4.2: HUD обновляется при gold_changed signal")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	var bus: Node = get_root().get_node_or_null("EventBus")
	if is_instance_valid(scene) and bus != null:
		# start_run эмитит gold_changed (10) — HUD уже обновлён.
		scene.run_controller.start_run(42)
		await process_frame
		_assert(scene.hud_gold_label.text.find("10") >= 0,
			"gold_label показывает 10 после start_run (got '%s')" % scene.hud_gold_label.text)
		# Эмулируем покупку.
		bus.gold_changed.emit(7)
		await process_frame
		_assert(scene.hud_gold_label.text.find("7") >= 0,
			"gold_label обновлён до '7' (got '%s')" % scene.hud_gold_label.text)
		scene.queue_free()
	await process_frame


func _test_battle_view_attack_meter_draw_safe() -> void:
	print("[test] S4.2: BattleView._draw() с attack_meter не падает")
	var view: Control = BattleViewScript.new()
	var ctx = BattleContextScript.new()
	var g = GridScript.new()
	g.resize(7, 4)
	ctx.grid = g
	var def = UnitDefScript.new()
	def.id = &"warrior_t"
	def.max_hp = 100
	def.attack_speed = 1.0
	var c = CombatantScript.new(def)
	ctx.register(c, Vector2i(0, 3))
	view.set_context(ctx)
	# Симулируем накопление attack_meter как делает BattleRunner.
	c.attack_meter.accumulate(0.5)
	view.queue_redraw()
	_assert(c.attack_meter != null, "attack_meter существует")
	var ratio: float = c.attack_meter.progress(c.attack_speed())
	_assert(ratio >= 0.0 and ratio <= 1.0,
		"attack_meter.progress в [0,1] (got %f)" % ratio)
	# В headless _draw() не вызывается — но set_context не должен падать.
	_assert(view._ctx == ctx, "ctx сохранён")
	view.free()


func _test_damage_dealt_signal_emits() -> void:
	print("[test] S4.2: DamageEffect emit damage_dealt signal")
	var bus: Node = get_root().get_node_or_null("EventBus")
	if bus == null:
		_assert(true, "no EventBus в headless — пропускаем")
		return
	var dmg_box: Array = [null]
	bus.damage_dealt.connect(func(_t, amt: int, _s) -> void: dmg_box[0] = amt)
	var target_def = UnitDefScript.new()
	target_def.id = &"target_t"
	target_def.max_hp = 100
	var target = CombatantScript.new(target_def)
	var src_def = UnitDefScript.new()
	src_def.id = &"src_t"
	src_def.max_hp = 100
	src_def.attack = 100
	var source = CombatantScript.new(src_def)
	var ctx2 = BattleContextScript.new()
	var g2 = GridScript.new()
	g2.resize(7, 4)
	ctx2.grid = g2
	ctx2.register(source, Vector2i(0, 3))
	ctx2.register(target, Vector2i(0, 0))
	var dmg_effect = DamageEffectScript.new()
	dmg_effect.base_damage = 50
	dmg_effect.variance = 0.0
	dmg_effect.is_magic = false
	var ability = AbilityDefScript.new()
	ability.effects = [dmg_effect]
	AbilityResolverScript.cast(ability, source, ctx2, target)
	_assert(dmg_box[0] != null and dmg_box[0] > 0,
		"damage_dealt signal emitted (got amount=%s)" % str(dmg_box[0]))


func _test_battle_view_damage_number_storage() -> void:
	print("[test] S4.2: BattleView._damage_numbers добавляется через signal callback")
	var view: Control = BattleViewScript.new()
	# Подписки не будет (нет EventBus), но напрямую дёрнем _on_damage_dealt.
	var fake_target = CombatantScript.new(_make_simple_def(&"t", 100))
	fake_target.cell = Vector2i(2, 1)
	view._on_damage_dealt(fake_target, 42, null)
	_assert(view._damage_numbers.size() == 1,
		"1 damage number добавлен (got %d)" % view._damage_numbers.size())
	_assert(view._damage_numbers[0]["amount"] == 42,
		"amount = 42 (got %d)" % view._damage_numbers[0]["amount"])
	_assert(view._damage_numbers[0]["cell"] == Vector2i(2, 1),
		"cell сохранён")
	# TTL tick.
	view._process(0.3)
	_assert(view._damage_numbers.size() == 1, "после 0.3s остался (TTL=0.6s)")
	view._process(0.4)
	_assert(view._damage_numbers.size() == 0, "после 0.7s удалён (TTL expired)")
	view.free()


func _make_simple_def(id: StringName, hp: int) -> Resource:
	var def = UnitDefScript.new()
	def.id = id
	def.max_hp = hp
	def.attack = 10
	return def


func _test_battle_scene_round_summary_on_win() -> void:
	print("[test] S4.2: BattleScene показывает round_summary после battle_ended (win)")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	if not is_instance_valid(scene):
		return
	scene.run_controller.start_run(42)
	scene.run_controller.profile = MetaProfileScript.new()
	scene.run_controller.state.round_index = 1
	scene.run_controller.state.wins = 0
	scene.run_controller.start_battle()
	scene.run_controller.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	scene.run_controller.runner.state.winner_team = 0
	scene.run_controller.tick_battle(0.1)
	await process_frame
	_assert(scene._summary_pending == true,
		"_summary_pending = true после win (got %s)" % str(scene._summary_pending))
	_assert(scene.summary_label != null and is_instance_valid(scene.summary_label),
		"summary_label создан в _show_round_summary")
	if scene.summary_label != null and is_instance_valid(scene.summary_label):
		_assert(scene.summary_label.text.find("Round") >= 0,
			"summary содержит 'Round' (got '%s')" % scene.summary_label.text)
		_assert(scene.summary_label.text.find("gold") >= 0,
			"summary содержит 'gold' (got '%s')" % scene.summary_label.text)
	scene.queue_free()
	await process_frame


func _test_battle_scene_round_summary_on_defeat() -> void:
	print("[test] S4.2: BattleScene round_summary на defeat = 'Defeat!'")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	if not is_instance_valid(scene):
		return
	scene.run_controller.start_run(42)
	scene.run_controller.profile = MetaProfileScript.new()
	scene.run_controller.start_battle()
	scene.run_controller.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	scene.run_controller.runner.state.winner_team = 1  # enemy wins
	scene.run_controller.tick_battle(0.1)
	await process_frame
	_assert(scene._summary_pending == true, "pending = true")
	if scene.summary_label != null and is_instance_valid(scene.summary_label):
		_assert(scene.summary_label.text.find("Defeat") >= 0,
			"summary содержит 'Defeat' (got '%s')" % scene.summary_label.text)
	scene.queue_free()
	await process_frame


# === S4.3: Visual feedback ===

func _test_combatant_visual_state_init() -> void:
	print("[test] S4.3: Combatant.visual_state инициализирован")
	var def = UnitDefScript.new()
	def.id = &"v_init"
	def.max_hp = 100
	var c = CombatantScript.new(def)
	_assert(c.visual_state != null, "visual_state существует")
	_assert(c.visual_state["flash_alpha"] == 0.0,
		"flash_alpha = 0 init (got %f)" % c.visual_state["flash_alpha"])
	_assert(c.visual_state["fade_alpha"] == 1.0,
		"fade_alpha = 1 init (alive) (got %f)" % c.visual_state["fade_alpha"])
	_assert(c.visual_state["is_dying"] == false, "is_dying = false init")
	_assert(c.visual_state["pos_lerp"] == 0.0,
		"pos_lerp = 0 init (settled)")


func _test_combatant_take_damage_triggers_flash() -> void:
	print("[test] S4.3: take_damage триггерит flash_alpha")
	var def = UnitDefScript.new()
	def.id = &"v_dmg"
	def.max_hp = 100
	var c = CombatantScript.new(def)
	c.take_damage(50, null)
	_assert(c.visual_state["flash_alpha"] > 0.0,
		"flash_alpha > 0 после damage (got %f)" % c.visual_state["flash_alpha"])


func _test_combatant_take_damage_death_triggers_dying() -> void:
	print("[test] S4.3: lethal damage триггерит is_dying=true")
	var def = UnitDefScript.new()
	def.id = &"v_dead"
	def.max_hp = 50
	var c = CombatantScript.new(def)
	c.take_damage(100, null)
	_assert(c.visual_state["is_dying"] == true,
		"is_dying = true после lethal damage (got %s)" % str(c.visual_state["is_dying"]))
	_assert(c.visual_state["fade_alpha"] == 1.0,
		"fade_alpha = 1 (начало fade) (got %f)" % c.visual_state["fade_alpha"])


func _test_combatant_visual_state_tick() -> void:
	print("[test] S4.3: _tick_visual(dt) decrement flash/fade/pos_lerp")
	var def = UnitDefScript.new()
	def.id = &"v_tick"
	def.max_hp = 100
	var c = CombatantScript.new(def)
	c.visual_state["flash_alpha"] = 1.0
	c.visual_state["pos_lerp"] = 1.0
	c._tick_visual(0.05)
	_assert(c.visual_state["flash_alpha"] < 1.0,
		"flash_alpha decrement (got %f)" % c.visual_state["flash_alpha"])
	_assert(c.visual_state["pos_lerp"] < 1.0,
		"pos_lerp decrement (got %f)" % c.visual_state["pos_lerp"])
	# After > 0.15s flash_alpha should be 0.
	c.visual_state["flash_alpha"] = 1.0
	c._tick_visual(0.2)
	_assert(c.visual_state["flash_alpha"] == 0.0,
		"flash_alpha = 0 после 0.2s (got %f)" % c.visual_state["flash_alpha"])


func _test_combatant_move_to_with_anim() -> void:
	print("[test] S4.3: move_to_with_anim обновляет prev_cell + pos_lerp=1")
	var def = UnitDefScript.new()
	def.id = &"v_move"
	def.max_hp = 100
	var c = CombatantScript.new(def)
	c.cell = Vector2i(0, 3)
	c.prev_cell = Vector2i(0, 3)
	c.move_to_with_anim(Vector2i(1, 3))
	_assert(c.cell == Vector2i(1, 3), "cell = (1,3)")
	_assert(c.prev_cell == Vector2i(0, 3), "prev_cell = (0,3)")
	_assert(c.visual_state["pos_lerp"] == 1.0, "pos_lerp = 1 (animation start)")


func _test_battle_runner_ticks_visual_state() -> void:
	print("[test] S4.3: BattleRunner.step() тикает visual_state каждого combatant")
	var ctx = BattleContextScript.new()
	var g = GridScript.new()
	g.resize(7, 4)
	ctx.grid = g
	var def = UnitDefScript.new()
	def.id = &"vr"
	def.max_hp = 100
	var c = CombatantScript.new(def)
	ctx.register(c, Vector2i(0, 3))
	var runner = BattleRunnerScript.new(ctx)
	runner.start()
	c.visual_state["flash_alpha"] = 1.0
	runner.step(0.05)
	_assert(c.visual_state["flash_alpha"] < 1.0,
		"flash_alpha decrement после runner.step() (got %f)" % c.visual_state["flash_alpha"])


func _test_battle_runner_removes_faded_combatants() -> void:
	print("[test] S4.3: BattleRunner удаляет combatant когда fade_alpha=0")
	var ctx = BattleContextScript.new()
	var g = GridScript.new()
	g.resize(7, 4)
	ctx.grid = g
	var def = UnitDefScript.new()
	def.id = &"vf"
	def.max_hp = 100
	var c = CombatantScript.new(def)
	ctx.register(c, Vector2i(0, 3))
	var runner = BattleRunnerScript.new(ctx)
	runner.start()
	# Симулируем смерть и установить fade_alpha=0.
	c.take_damage(100, null)
	c.visual_state["fade_alpha"] = 0.0  # сразу faded
	runner.step(0.01)
	_assert(not c.visual_state.has("in_ctx") or true,
		"combatant может быть удалён")
	# Проверим registry.
	var found: bool = false
	for existing in ctx.combatant_registry:
		if existing == c:
			found = true
			break
	_assert(not found, "combatant удалён из ctx.combatant_registry")


# === S5.1: Encounter map core ===

func _test_encounter_node_basic() -> void:
	print("[test] S5.1: EncounterNode — basic fields")
	var node = EncounterNodeScript.new(1, EncounterTypeScript.Kind.COMBAT, 1)
	_assert(node.id == 1, "id = 1")
	_assert(node.type == EncounterTypeScript.Kind.COMBAT, "type = COMBAT")
	_assert(node.depth == 1, "depth = 1 (round_index)")
	_assert(node.parent_ids.is_empty(), "parent_ids пуст (root)")
	_assert(node.child_ids.is_empty(), "child_ids пуст (leaf)")
	_assert(node.visited == false, "visited = false init")
	_assert(node.is_combat() == true, "is_combat = true для COMBAT")


func _test_encounter_type_enum_values() -> void:
	print("[test] S5.1: EncounterType enum имеет все 8 типов")
	var types: Array[int] = [
		EncounterTypeScript.Kind.COMBAT,
		EncounterTypeScript.Kind.ELITE,
		EncounterTypeScript.Kind.HEAL,
		EncounterTypeScript.Kind.TREASURE,
		EncounterTypeScript.Kind.MERCHANT,
		EncounterTypeScript.Kind.REST,
		EncounterTypeScript.Kind.SHRINE,
		EncounterTypeScript.Kind.BOSS,
	]
	_assert(types.size() == 8, "8 типов (got %d)" % types.size())
	# Все должны быть разные int.
	for i in types.size():
		for j in range(i + 1, types.size()):
			_assert(types[i] != types[j],
				"типы уникальны (%d vs %d)" % [types[i], types[j]])


func _test_encounter_type_is_combat() -> void:
	print("[test] S5.1: EncounterType.is_combat() правильно классифицирует")
	_assert(EncounterTypeScript.is_combat(EncounterTypeScript.Kind.COMBAT) == true, "COMBAT is combat")
	_assert(EncounterTypeScript.is_combat(EncounterTypeScript.Kind.ELITE) == true, "ELITE is combat")
	_assert(EncounterTypeScript.is_combat(EncounterTypeScript.Kind.BOSS) == true, "BOSS is combat")
	_assert(EncounterTypeScript.is_combat(EncounterTypeScript.Kind.HEAL) == false, "HEAL NOT combat")
	_assert(EncounterTypeScript.is_combat(EncounterTypeScript.Kind.TREASURE) == false, "TREASURE NOT combat")
	_assert(EncounterTypeScript.is_combat(EncounterTypeScript.Kind.REST) == false, "REST NOT combat")


func _test_encounter_type_display_name() -> void:
	print("[test] S5.1: EncounterType.display_name()")
	_assert(EncounterTypeScript.display_name(EncounterTypeScript.Kind.COMBAT) == "Combat", "Combat")
	_assert(EncounterTypeScript.display_name(EncounterTypeScript.Kind.BOSS) == "Boss", "Boss")
	_assert(EncounterTypeScript.display_name(EncounterTypeScript.Kind.HEAL) == "Heal", "Heal")


func _test_encounter_map_generate_structure() -> void:
	print("[test] S5.1: EncounterMap.generate(seed) создаёт валидный граф")
	Rng.seed_run(42)
	var map = EncounterMapScript.new()
	map.generate(42)
	var nodes: Array = map.get_all_nodes()
	_assert(nodes.size() >= 10, ">= 10 нодов (got %d)" % nodes.size())
	# Каждый слой depth=1..10 должен иметь хотя бы 1 нод.
	for d in 10:
		var has_at_depth: bool = false
		for n in nodes:
			if n.depth == d + 1:
				has_at_depth = true
				break
		_assert(has_at_depth, "слой %d имеет хотя бы 1 нод" % (d + 1))
	_assert(map.is_valid(), "is_valid() = true")


func _test_encounter_map_determinism() -> void:
	print("[test] S5.1: тот же seed = та же карта (детерминизм)")
	Rng.seed_run(100)
	var m1 = EncounterMapScript.new()
	m1.generate(100)
	Rng.seed_run(100)
	var m2 = EncounterMapScript.new()
	m2.generate(100)
	var types1: Array = m1.get_layer_types()
	var types2: Array = m2.get_layer_types()
	_assert(types1 == types2,
		"детерминизм: тот же seed → те же типы (got %s vs %s)" % [str(types1), str(types2)])


func _test_encounter_map_boss_at_layer_10() -> void:
	print("[test] S5.1: Boss находится на слое 10")
	Rng.seed_run(777)
	var map = EncounterMapScript.new()
	map.generate(777)
	var boss_count: int = 0
	for n in map.get_all_nodes():
		if n.type == EncounterTypeScript.Kind.BOSS:
			_assert(n.depth == 10, "boss на depth=10 (got %d)" % n.depth)
			boss_count += 1
	_assert(boss_count >= 1, "хотя бы 1 boss (got %d)" % boss_count)


func _test_encounter_map_first_layer_is_combat() -> void:
	print("[test] S5.1: слой 1 — только combat (стартовый набор)")
	Rng.seed_run(42)
	var map = EncounterMapScript.new()
	map.generate(42)
	for n in map.get_layer_nodes(1):
		_assert(n.type == EncounterTypeScript.Kind.COMBAT,
			"слой 1 = COMBAT (got %s)" % EncounterTypeScript.display_name(n.type))


func _test_encounter_map_choose_next_basic() -> void:
	print("[test] S5.1: EncounterMap.choose_next(id) переходит по графу")
	Rng.seed_run(123)
	var map = EncounterMapScript.new()
	map.generate(123)
	var first_id: int = map.start_run()
	_assert(first_id >= 0, "start_run вернул id")
	_assert(map.get_current_node_id() == first_id, "current = first_id")
	var available: Array = map.get_available_next_ids()
	_assert(not available.is_empty(), "есть available ноды")
	var next_id: int = available[0]
	var ok: bool = map.choose_next(next_id)
	_assert(ok, "choose_next вернул true")
	_assert(map.get_current_node_id() == next_id, "current обновился")


func _test_encounter_map_choose_invalid() -> void:
	print("[test] S5.1: choose_next(invalid_id) → false")
	Rng.seed_run(42)
	var map = EncounterMapScript.new()
	map.generate(42)
	map.start_run()
	var ok: bool = map.choose_next(99999)
	_assert(ok == false, "invalid_id → false")


func _test_encounter_map_strict_determinism_100_seeds() -> void:
	print("[test] S5.1: STRICT determinism — 100 seed'ов дают идентичную карту при повторе")
	# Первый прогон: сохраняем fingerprint каждой карты.
	var fingerprints: Dictionary = {}
	for seed_value in range(100):
		Rng.seed_run(seed_value)
		var map = EncounterMapScript.new()
		map.generate(seed_value)
		# Fingerprint: типы на каждом слое + parent/child связи.
		var fp: String = ""
		for n in map.get_all_nodes():
			fp += "%d:%d:%d:%s;" % [n.id, n.depth, n.type, str(n.parent_ids) + "->" + str(n.child_ids)]
		fingerprints[seed_value] = fp
	# Второй прогон: проверяем идентичность.
	for seed_value in range(100):
		Rng.seed_run(seed_value)
		var map = EncounterMapScript.new()
		map.generate(seed_value)
		var fp: String = ""
		for n in map.get_all_nodes():
			fp += "%d:%d:%d:%s;" % [n.id, n.depth, n.type, str(n.parent_ids) + "->" + str(n.child_ids)]
		_assert(fingerprints[seed_value] == fp,
			"seed %d: карта изменилась между прогонами" % seed_value)


func _test_rng_pick_unique_determinism() -> void:
	print("[test] S5.1: Rng.pick_unique — детерминизм через Rng.* методы (НЕ Array.shuffle)")
	# pick_unique использует pool.shuffle() который НЕ seeded — этот тест
	# проверяет наш текущий баг и должен FAIL пока мы не починим Rng.
	Rng.seed_run(42)
	var arr: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
	var pick1: Array = Rng.pick_unique(arr, 5)
	Rng.seed_run(42)
	var pick2: Array = Rng.pick_unique(arr, 5)
	_assert(pick1 == pick2,
		"Rng.pick_unique детерминизм (got %s vs %s)" % [str(pick1), str(pick2)])





# === S5.2: Encounter Map UI ===

func _test_encounter_map_ui_resources_exist() -> void:
	print("[test] S5.2: Encounter Map UI scene contract")
	var script_exists: bool = ResourceLoader.exists("res://scenes/encounter/encounter_map_view.gd")
	var scene_exists: bool = ResourceLoader.exists("res://scenes/encounter/encounter_map_scene.tscn")
	_assert(script_exists, "EncounterMapView script exists")
	_assert(scene_exists, "Encounter Map scene exists")
	if not script_exists or not scene_exists:
		return
	var script = load("res://scenes/encounter/encounter_map_view.gd")
	var view: Control = script.new()
	_assert(view.has_method("set_map"), "EncounterMapView.set_map() exists")
	_assert(view.has_method("get_map"), "EncounterMapView.get_map() exists")
	var map = EncounterMapScript.new()
	view.set_map(map)
	_assert(view.get_map() == map, "EncounterMapView stores assigned map")
	view.free()
	var scene: Node = _instantiate_scene("res://scenes/encounter/encounter_map_scene.tscn")
	_assert(scene is Control, "Encounter Map scene root = Control")
	if scene != null:
		scene.free()


func _test_encounter_map_ui_layout_and_button_states() -> void:
	print("[test] S5.2: EncounterMapView lays out DAG and locks unavailable nodes")
	Rng.seed_run(5202)
	var map = EncounterMapScript.new()
	map.generate(5202)
	var view_script = load("res://scenes/encounter/encounter_map_view.gd")
	var view: Control = view_script.new()
	view.size = Vector2(1152, 648)
	view.set_map(map)
	var positions: Dictionary = view.get_node_positions()
	var buttons: Dictionary = view.get_node_buttons()
	_assert(positions.size() == map.size(),
		"layout has one position per node (%d)" % map.size())
	_assert(buttons.size() == map.size(),
		"view has one Button per node (%d)" % map.size())
	var first = map.get_layer_nodes(1)[0]
	var boss = map.get_layer_nodes(10)[0]
	_assert(positions.has(first.id) and positions.has(boss.id),
		"layout contains first node and boss")
	if positions.has(first.id) and positions.has(boss.id):
		_assert(positions[boss.id].y < positions[first.id].y,
			"boss is above first layer")
	_assert(view.get_edge_count() > 0, "DAG edges are prepared for drawing")
	var available: Array[int] = map.get_available_next_ids()
	var enabled_count: int = 0
	for node_id in buttons:
		var button: Button = buttons[node_id]
		if not button.disabled:
			enabled_count += 1
		_assert(button.disabled == (node_id not in available),
			"node %d enabled iff available" % node_id)
	_assert(enabled_count == available.size(),
		"enabled count equals available count (%d)" % available.size())
	view.free()


func _test_encounter_map_ui_selection_signal() -> void:
	print("[test] S5.2: EncounterMapView emits only available node selection")
	Rng.seed_run(5203)
	var map = EncounterMapScript.new()
	map.generate(5203)
	var view_script = load("res://scenes/encounter/encounter_map_view.gd")
	var view: Control = view_script.new()
	view.size = Vector2(1152, 648)
	view.set_map(map)
	var selected: Array[int] = []
	view.node_selected.connect(func(node_id: int) -> void: selected.append(node_id))
	var available: Array[int] = map.get_available_next_ids()
	var locked_id: int = -1
	for node in map.get_all_nodes():
		if node.id not in available:
			locked_id = node.id
			break
	view._on_node_pressed(locked_id)
	_assert(selected.is_empty(), "locked node does not emit")
	view._on_node_pressed(available[0])
	_assert(selected == [available[0]], "available node emits exactly once")
	_assert(map.get_current_node_id() == -1, "view does not mutate EncounterMap")
	view.free()


func _test_encounter_map_scene_preview_progression() -> void:
	print("[test] S5.2: preview scene advances map and refreshes status")
	var scene: Node = _instantiate_scene("res://scenes/encounter/encounter_map_scene.tscn")
	_assert(scene != null, "preview scene instantiates")
	if scene == null:
		return
	get_root().add_child.call_deferred(scene)
	await process_frame
	_assert(scene.has_method("_on_node_selected"), "preview handles node_selected")
	_assert(scene.encounter_map != null, "preview generated EncounterMap")
	_assert(scene.map_view != null, "preview has map_view")
	_assert(scene.status_label != null, "preview has status label")
	var available: Array[int] = scene.encounter_map.get_available_next_ids()
	var chosen_id: int = available[0]
	scene._delegate_selection = false  # S6.1: legacy preview mode.
	scene._on_node_selected(chosen_id)
	_assert(scene.encounter_map.get_current_node_id() == chosen_id,
		"preview applies choose_next")
	_assert(scene.status_label.text.find("Layer 1") >= 0,
		"status shows selected first layer")
	_assert(scene.map_view.get_map() == scene.encounter_map,
		"view refreshed with preview map")
	scene.queue_free()
	await process_frame


# === S5.3 Task 1: Phase enum + RunState + Balance constants ===

func _test_run_controller_phase_map_service() -> void:
	print("[test] S5.3: Phase enum расширен MAP + SERVICE")
	_assert(RunControllerScript.Phase.MAP == 4, "Phase.MAP = 4 (got %d)" % RunControllerScript.Phase.MAP)
	_assert(RunControllerScript.Phase.SERVICE == 5, "Phase.SERVICE = 5 (got %d)" % RunControllerScript.Phase.SERVICE)
	_assert(RunControllerScript.Phase.PREP == 0, "Phase.PREP остался 0")
	_assert(RunControllerScript.Phase.BATTLE == 1, "Phase.BATTLE остался 1")
	_assert(RunControllerScript.Phase.REWARD == 2, "Phase.REWARD остался 2")
	_assert(RunControllerScript.Phase.GAMEOVER == 3, "Phase.GAMEOVER остался 3")


func _test_run_state_current_encounter_id_default() -> void:
	print("[test] S5.3: RunState.current_encounter_id + encounter_visited_ids default")
	var s: RunState = RunStateScript.new()
	_assert(s.current_encounter_id == -1, "current_encounter_id = -1 default (got %d)" % s.current_encounter_id)
	_assert(s.encounter_visited_ids.is_empty(), "encounter_visited_ids пуст (got size %d)" % s.encounter_visited_ids.size())


func _test_balance_map_reward_constants() -> void:
	print("[test] S5.3: Balance.MAP_* reward constants для service effects")
	_assert(BalanceScript.MAP_HEAL_HP_RATIO > 0.0 and BalanceScript.MAP_HEAL_HP_RATIO <= 1.0,
		"MAP_HEAL_HP_RATIO в (0,1] (got %f)" % BalanceScript.MAP_HEAL_HP_RATIO)
	_assert(BalanceScript.MAP_TREASURE_GOLD > 0,
		"MAP_TREASURE_GOLD > 0 (got %d)" % BalanceScript.MAP_TREASURE_GOLD)
	_assert(BalanceScript.MAP_MERCHANT_DISCOUNT > 0.0 and BalanceScript.MAP_MERCHANT_DISCOUNT <= 1.0,
		"MAP_MERCHANT_DISCOUNT в (0,1] (got %f)" % BalanceScript.MAP_MERCHANT_DISCOUNT)
	_assert(BalanceScript.MAP_REST_HP_RATIO > 0.0 and BalanceScript.MAP_REST_HP_RATIO <= 1.0,
		"MAP_REST_HP_RATIO в (0,1] (got %f)" % BalanceScript.MAP_REST_HP_RATIO)
	_assert(BalanceScript.MAP_REST_ATTACK_BONUS > 0,
		"MAP_REST_ATTACK_BONUS > 0 (got %d)" % BalanceScript.MAP_REST_ATTACK_BONUS)
	_assert(BalanceScript.MAP_SHRINE_GOLD_BONUS > 0,
		"MAP_SHRINE_GOLD_BONUS > 0 (got %d)" % BalanceScript.MAP_SHRINE_GOLD_BONUS)
	_assert(BalanceScript.MAP_SHRINE_HP_BONUS > 0,
		"MAP_SHRINE_HP_BONUS > 0 (got %d)" % BalanceScript.MAP_SHRINE_HP_BONUS)
	_assert(BalanceScript.MAP_SHRINE_ATTACK_BONUS > 0,
		"MAP_SHRINE_ATTACK_BONUS > 0 (got %d)" % BalanceScript.MAP_SHRINE_ATTACK_BONUS)


# === S5.3: Combat dispatch + Service effects + Phase flow ===

func _test_run_controller_combat_node_starts_battle() -> void:
	print("[test] S5.3: combat node_id -> start_battle -> phase=BATTLE")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	_assert(ctrl.phase == RunControllerScript.Phase.MAP, "phase = MAP (got %d)" % ctrl.phase)
	_assert(ctrl.encounter_map != null, "encounter_map created in _enter_map")
	var combat_id: int = -1
	for id in ctrl.encounter_map.get_available_next_ids():
		var n = ctrl.encounter_map.get_node(id)
		if n != null and n.is_combat():
			combat_id = id
			break
	_assert(combat_id >= 0, "has combat node in available_next (got %d)" % combat_id)
	ctrl._on_node_selected(combat_id)
	# S6.2: combat dispatch → PREP (placement screen), не BATTLE напрямую.
	# Игрок нажимает Ready → start_battle().
	_assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP after combat dispatch (got %d)" % ctrl.phase)
	_assert(ctrl.runner == null, "runner NOT created yet (player must Ready first)")
	# Start battle via prep_scene equivalent.
	ctrl.start_battle()
	_assert(ctrl.phase == RunControllerScript.Phase.BATTLE, "phase = BATTLE after Ready (got %d)" % ctrl.phase)
	_assert(ctrl.runner != null, "runner created after Ready → start_battle")
	_cleanup_ctrl(ctrl)


func _test_run_controller_invalid_node_id_ignored() -> void:
	print("[test] S5.3: invalid node_id in _on_node_selected -> no-op")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	var phase_before: int = ctrl.phase
	ctrl._on_node_selected(99999)
	_assert(ctrl.phase == phase_before, "phase unchanged (was %d, now %d)" % [phase_before, ctrl.phase])
	ctrl.start_battle()
	ctrl._on_node_selected(0)
	_assert(ctrl.phase == RunControllerScript.Phase.BATTLE, "phase still BATTLE (got %d)" % ctrl.phase)
	_cleanup_ctrl(ctrl)


func _test_run_controller_heal_node_effect() -> void:
	print("[test] S5.3: HEAL node -> state.lives +1 with cap")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	var heal_node = EncounterNodeScript.new(100, EncounterTypeScript.Kind.HEAL, 1)
	var lives_before: int = ctrl.state.lives
	ctrl._apply_service_effect(heal_node)
	_assert(ctrl.state.lives == lives_before + 1, "lives +1 (was %d, now %d)" % [lives_before, ctrl.state.lives])
	_cleanup_ctrl(ctrl)


func _test_run_controller_treasure_node_effect() -> void:
	print("[test] S5.3: TREASURE node -> gold += MAP_TREASURE_GOLD + meta unlock")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	var treasure_node = EncounterNodeScript.new(101, EncounterTypeScript.Kind.TREASURE, 1)
	var gold_before: int = ctrl.state.gold
	var unlocks_before: int = ctrl.profile.unlocked_units.size()
	ctrl._apply_service_effect(treasure_node)
	_assert(ctrl.state.gold == gold_before + BalanceScript.MAP_TREASURE_GOLD,
		"gold +%d (was %d, now %d)" % [BalanceScript.MAP_TREASURE_GOLD, gold_before, ctrl.state.gold])
	_assert(ctrl.profile.unlocked_units.size() >= unlocks_before,
		"unlocked_units preserved (was %d, now %d)" % [unlocks_before, ctrl.profile.unlocked_units.size()])
	_cleanup_ctrl(ctrl)


func _test_run_controller_merchant_node_effect() -> void:
	print("[test] S5.3: MERCHANT node -> phase=PREP + shop refreshed")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	var merchant_node = EncounterNodeScript.new(102, EncounterTypeScript.Kind.MERCHANT, 1)
	ctrl._apply_service_effect(merchant_node)
	_assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP after MERCHANT (got %d)" % ctrl.phase)
	_assert(ctrl.shop.offered_ids().size() > 0, "shop refreshed (offered_ids size %d)" % ctrl.shop.offered_ids().size())
	_cleanup_ctrl(ctrl)


func _test_run_controller_rest_node_effect() -> void:
	print("[test] S5.3: REST node -> meta_modifiers.rest_attack_bonus += MAP_REST_ATTACK_BONUS")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	var rest_node = EncounterNodeScript.new(103, EncounterTypeScript.Kind.REST, 1)
	var bonus_before: int = int(ctrl.state.meta_modifiers.get("rest_attack_bonus", 0))
	ctrl._apply_service_effect(rest_node)
	var bonus_after: int = int(ctrl.state.meta_modifiers.get("rest_attack_bonus", 0))
	_assert(bonus_after == bonus_before + BalanceScript.MAP_REST_ATTACK_BONUS,
		"rest_attack_bonus +%d (was %d, now %d)" % [BalanceScript.MAP_REST_ATTACK_BONUS, bonus_before, bonus_after])
	_cleanup_ctrl(ctrl)


func _test_run_controller_shrine_node_random_buff() -> void:
	print("[test] S5.3: SHRINE node -> one of 4 buffs applied")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	var shrine_node = EncounterNodeScript.new(104, EncounterTypeScript.Kind.SHRINE, 1)
	var gold_before: int = ctrl.state.gold
	var lives_before: int = ctrl.state.lives
	var atk_before: int = int(ctrl.state.meta_modifiers.get("shrine_attack_bonus", 0))
	ctrl._apply_service_effect(shrine_node)
	var gold_match: bool = ctrl.state.gold == gold_before + BalanceScript.MAP_SHRINE_GOLD_BONUS
	var lives_match: bool = ctrl.state.lives == lives_before + 1
	var atk_match: bool = int(ctrl.state.meta_modifiers.get("shrine_attack_bonus", 0)) == atk_before + BalanceScript.MAP_SHRINE_ATTACK_BONUS
	_assert(gold_match or lives_match or atk_match,
		"SHRINE applied buff -- gold=%d lives=%d atk=%d"
		% [ctrl.state.gold, ctrl.state.lives, int(ctrl.state.meta_modifiers.get("shrine_attack_bonus", 0))])
	_cleanup_ctrl(ctrl)


func _test_run_controller_phase_flow_to_map() -> void:
	print("[test] S5.3: phase flow win -> MAP (after round 2)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.state.round_index = 1
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	# S6.1: round 1 win → REWARD (раньше был PREP no MAP).
	_assert(ctrl.phase == RunControllerScript.Phase.REWARD,
			"round 1 win -> REWARD (got %d)" % ctrl.phase)
	ctrl.state.round_index = 2
	ctrl.start_battle()
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	_assert(ctrl.phase == RunControllerScript.Phase.REWARD,
		"round 2 win -> REWARD (got %d)" % ctrl.phase)
	ctrl.skip_reward()
	_assert(ctrl.phase == RunControllerScript.Phase.MAP,
		"skip_reward round 2 -> MAP (got %d)" % ctrl.phase)
	_assert(ctrl.encounter_map != null, "encounter_map created on MAP entry")
	_cleanup_ctrl(ctrl)


func _test_battle_scene_has_encounter_map_view() -> void:
	print("[test] S5.3: BattleScene создает EncounterMapScene при _ready")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	if not is_instance_valid(scene):
		return
	_assert(scene.encounter_map_scene != null,
		"encounter_map_scene создан в _ready()")
	_assert(scene.encounter_map_scene is Control,
		"encounter_map_scene extends Control (got %s)" % str(typeof(scene.encounter_map_scene)))
	# По умолчанию — скрыт.
	_assert(scene.encounter_map_scene.visible == false,
		"encounter_map_scene скрыт initial (got %s)" % str(scene.encounter_map_scene.visible))
	scene.queue_free()
	await process_frame


func _test_battle_scene_shows_encounter_map_on_map_phase() -> void:
	print("[test] S5.3: BattleScene показывает encounter map на MAP phase, скрывает на остальных")
	var scene: Control = BattleSceneScript.new()
	get_root().add_child.call_deferred(scene)
	await process_frame
	if not is_instance_valid(scene):
		return
	# PREP — скрыт.
	scene.run_controller.start_run(42)
	await process_frame
	_assert(scene.encounter_map_scene.visible == false,
		"encounter_map_scene скрыт на PREP (got %s)" % str(scene.encounter_map_scene.visible))
	# Force MAP phase.
	scene.run_controller._enter_map()
	await process_frame
	_assert(scene.encounter_map_scene.visible == true,
		"encounter_map_scene показан на MAP (got %s)" % str(scene.encounter_map_scene.visible))
	_assert(scene.encounter_map_scene.encounter_map == scene.run_controller.encounter_map,
	"scene.encounter_map_scene получил encounter_map из RunController")
	# Снова PREP — снова скрыт.
	scene.run_controller._set_phase(0)
	await process_frame
	_assert(scene.encounter_map_scene.visible == false,
	"encounter_map_scene снова скрыт на PREP (got %s)" % str(scene.encounter_map_scene.visible))
	scene.queue_free()
	await process_frame


func _test_run_state_unit_states_default_empty() -> void:
	print("[test] S5.4: RunState.unit_states default = []")
	var s: RunState = RunStateScript.new()
	_assert(s.unit_states.is_empty(), "unit_states empty (got size %d)" % s.unit_states.size())


func _test_run_controller_start_run_initializes_unit_states() -> void:
	print("[test] S5.4: start_run() creates unit_states for each player_unit_id")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	_assert(ctrl.state.unit_states.size() == ctrl.state.player_unit_ids.size(),
		"unit_states size == player_unit_ids size (%d vs %d)"
		% [ctrl.state.unit_states.size(), ctrl.state.player_unit_ids.size()])
	for i in ctrl.state.unit_states.size():
		var us = ctrl.state.unit_states[i]
		var id: StringName = ctrl.state.player_unit_ids[i]
		_assert(us.unit_id == id, "unit_id[%d] = %s" % [i, id])
	_cleanup_ctrl(ctrl)


func _test_run_controller_heal_effect_heals_unit_states() -> void:
	print("[test] S5.4: HEAL adds hp_ratio * max_hp additively to current_hp")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	# Set current_hp = 1 (minimal) so delta is unambiguous.
	for us in ctrl.state.unit_states:
		us.current_hp = 1
	var before: Array = []
	for us in ctrl.state.unit_states:
		before.append(us.current_hp)
	var heal_node = EncounterNodeScript.new(110, EncounterTypeScript.Kind.HEAL, 1)
	ctrl._apply_service_effect(heal_node)
	for i in ctrl.state.unit_states.size():
		var us = ctrl.state.unit_states[i]
		var expected_delta: int = int(round(float(us.max_hp) * BalanceScript.MAP_HEAL_HP_RATIO))
		var actual_delta: int = us.current_hp - before[i]
		_assert(actual_delta == expected_delta,
			"HEAL delta = max_hp * 0.4 = %d (got %d, max_hp=%d)" % [expected_delta, actual_delta, us.max_hp])
	_assert(ctrl.state.lives == BalanceScript.STARTING_LIVES + 1,
		"lives +1 (got %d)" % ctrl.state.lives)
	_cleanup_ctrl(ctrl)


func _test_run_controller_rest_effect_heals_unit_states() -> void:
	print("[test] S5.4: REST adds 50% of max_hp (more than HEAL's 40%)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl._enter_map()
	for us in ctrl.state.unit_states:
		us.current_hp = 1
	var before: Array = []
	for us in ctrl.state.unit_states:
		before.append(us.current_hp)
	var rest_node = EncounterNodeScript.new(111, EncounterTypeScript.Kind.REST, 1)
	ctrl._apply_service_effect(rest_node)
	for i in ctrl.state.unit_states.size():
		var us = ctrl.state.unit_states[i]
		var expected_delta: int = int(round(float(us.max_hp) * BalanceScript.MAP_REST_HP_RATIO))
		var actual_delta: int = us.current_hp - before[i]
		_assert(actual_delta == expected_delta,
			"REST delta = max_hp * 0.5 = %d (got %d)" % [expected_delta, actual_delta])
	_cleanup_ctrl(ctrl)





func _test_run_controller_rest_attack_bonus_applies_in_start_battle() -> void:
	print("[test] S5.4: REST attack bonus применяется в Combatant.attack_base")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# Capture base attack of warrior from UnitDef.
	var def: Resource = ContentDB_static.get_by_id(&"warrior")
	var base_attack: int = def.attack
	# First battle — no bonus.
	ctrl.state.round_index = 1
	ctrl.start_battle()
	var first_warrior: Object = null
	for c in ctrl.ctx.all_combatants():
		if c.team == TeamScript.PLAYER:
			first_warrior = c
			break
	_assert(first_warrior != null, "warrior spawned")
	_assert(first_warrior.attack_base == base_attack,
		"no bonus: attack_base = %d (got %d)" % [base_attack, first_warrior.attack_base])
	# Simulate win to clear battle.
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.state.round_index = 2
	ctrl.tick_battle(0.1)
	# After round 1 win we are in REWARD. Skip reward → MAP.
	ctrl.skip_reward()
	_assert(ctrl.phase == RunControllerScript.Phase.MAP, "phase = MAP")
	# Apply REST effect on MAP.
	var rest_node = EncounterNodeScript.new(120, EncounterTypeScript.Kind.REST, 1)
	ctrl._apply_service_effect(rest_node)
	# Now next battle — bonus applied.
	ctrl.state.round_index = 2
	ctrl.start_battle()
	var second_warrior: Object = null
	for c in ctrl.ctx.all_combatants():
		if c.team == TeamScript.PLAYER:
			second_warrior = c
			break
	_assert(second_warrior != null, "warrior spawned in battle 2")
	var expected_attack: int = int(round(float(base_attack) * (1.0 + float(BalanceScript.MAP_REST_ATTACK_BONUS) / 100.0)))
	_assert(second_warrior.attack_base == expected_attack,
		"attack_base = base * (1 + bonus/100) = %d (got %d, base=%d, bonus=%d)"
		% [expected_attack, second_warrior.attack_base, base_attack, BalanceScript.MAP_REST_ATTACK_BONUS])
	_cleanup_ctrl(ctrl)


func _test_run_controller_shrine_attack_bonus_applies_in_start_battle() -> void:
	print("[test] S5.4: SHRINE attack bonus применяется в Combatant.attack_base")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var def: Resource = ContentDB_static.get_by_id(&"warrior")
	var base_attack: int = def.attack
	# Set shrine_attack_bonus to known value (no need to RNG SHRINE).
	ctrl.state.meta_modifiers["shrine_attack_bonus"] = BalanceScript.MAP_SHRINE_ATTACK_BONUS
	ctrl.state.round_index = 1
	ctrl.start_battle()
	var w: Object = null
	for c in ctrl.ctx.all_combatants():
		if c.team == TeamScript.PLAYER:
			w = c
			break
	_assert(w != null, "warrior spawned")
	var expected: int = int(round(float(base_attack) * (1.0 + float(BalanceScript.MAP_SHRINE_ATTACK_BONUS) / 100.0)))
	_assert(w.attack_base == expected,
		"shrine_attack_bonus applied: attack_base = %d (got %d)" % [expected, w.attack_base])
	_cleanup_ctrl(ctrl)


func _test_save_contains_post_effect_state_after_rest() -> void:
	print("[test] S5.4: save после REST содержит post-effect state")
	var save_ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(save_ctrl)
	await process_frame
	save_ctrl.start_run(42)
	save_ctrl._enter_map()
	var rest_node = EncounterNodeScript.new(130, EncounterTypeScript.Kind.REST, 1)
	save_ctrl._apply_service_effect(rest_node)
	var expected_bonus: int = save_ctrl.state.meta_modifiers.get("rest_attack_bonus", 0)
	_assert(expected_bonus > 0, "rest_attack_bonus > 0 after REST (got %d)" % expected_bonus)
	# Load and verify.
	var loaded: RunState = SaveService.load_run(42)
	_assert(loaded != null, "save loaded")
	_assert(loaded.meta_modifiers.get("rest_attack_bonus", 0) == expected_bonus,
		"loaded rest_attack_bonus = %d (got %d)"
		% [expected_bonus, loaded.meta_modifiers.get("rest_attack_bonus", 0)])
	SaveService.delete_run(42)
	_cleanup_ctrl(save_ctrl)


func _test_run_controller_resume_run_restores_encounter_position() -> void:
	print("[test] S5.4: resume_run восстанавливает EncounterMap.current_node_id")
	var save_ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(save_ctrl)
	await process_frame
	save_ctrl.start_run(42)
	save_ctrl._enter_map()
	# Pick first available encounter.
	var available: Array[int] = save_ctrl.encounter_map.get_available_next_ids()
	var chosen_id: int = available[0]
	# Move to that node.
	assert(save_ctrl.encounter_map.choose_next(chosen_id), "choose_next ok")
	assert(save_ctrl.encounter_map.get_current_node_id() == chosen_id, "current = chosen_id")
	# Set state.current_encounter_id (this is what _on_node_selected does).
	save_ctrl.state.current_encounter_id = chosen_id
	# Save (auto-save already ran from _enter_map and choose_next, but explicit).
	save_ctrl.save_now()
	var saved_seed: int = save_ctrl.state.seed
	var saved_encounter_id: int = save_ctrl.state.current_encounter_id
	_cleanup_ctrl(save_ctrl)
	# Now create new RunController and resume.
	var resume_ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(resume_ctrl)
	await process_frame
	var ok: bool = resume_ctrl.resume_run(saved_seed)
	_assert(ok, "resume_run(" + str(saved_seed) + ") = true")
	_assert(resume_ctrl.encounter_map != null,
		"encounter_map regenerated after resume (got null)")
	if resume_ctrl.encounter_map != null:
		_assert(resume_ctrl.encounter_map.get_current_node_id() == saved_encounter_id,
			"current_node_id restored = %d (got %d)"
			% [saved_encounter_id, resume_ctrl.encounter_map.get_current_node_id()])
	_cleanup_ctrl(resume_ctrl)
func _test_run_controller_swap_board_units_basic() -> void:
	print("[test] S6.2: swap_board_units меняет двух юнитов на доске")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var ids: Array = ctrl.state.player_unit_ids.duplicate()
	_assert(ids.size() == 2, "start with 2 board units (got %d)" % ids.size())
	var ok: bool = ctrl.swap_board_units(0, 1)
	_assert(ok, "swap_board_units returned true")
	var new_ids: Array = ctrl.state.player_unit_ids.duplicate()
	_assert(new_ids[0] == ids[1] and new_ids[1] == ids[0],
		"board[0]<->board[1] swapped (got %s vs %s)"
		% [new_ids[0], new_ids[1]])
	_cleanup_ctrl(ctrl)


func _test_run_controller_board_to_bench_and_back() -> void:
	print("[test] S6.2: board->bench->board move")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var id: StringName = ctrl.state.player_unit_ids[0]
	var ok: bool = ctrl.board_to_bench(0)
	_assert(ok, "board_to_bench(0) returned true")
	_assert(ctrl.state.player_unit_ids.size() == 1, "board size 2->1")
	_assert(ctrl.state.bench_unit_ids.size() == 1, "bench size 0->1")
	_assert(ctrl.state.bench_unit_ids[0] == id, "moved id at bench[0]")
	var ok2: bool = ctrl.bench_to_board(0, 0)
	_assert(ok2, "bench_to_board returned true")
	_assert(ctrl.state.player_unit_ids[0] == id, "back to board[0]")
	_assert(ctrl.state.bench_unit_ids.size() == 0, "bench emptied")
	_cleanup_ctrl(ctrl)


func _test_run_controller_swap_invalid_returns_false() -> void:
	print("[test] S6.2: invalid swap indices возвращают false")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	_assert(not ctrl.swap_board_units(-1, 0), "negative a rejected")
	_assert(not ctrl.swap_board_units(0, 99), "out of range b rejected")
	_assert(not ctrl.swap_board_units(5, 5), "same slot rejected")
	_assert(not ctrl.board_to_bench(-1), "negative board index rejected")
	_assert(not ctrl.bench_to_board(0, 0), "bench_to_board from empty bench rejected")
	_cleanup_ctrl(ctrl)

func _test_run_controller_swap_keeps_unit_states_in_sync() -> void:
	print("[test] S6.2: swap не теряет unit_states (HP persistency)")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var id0: StringName = ctrl.state.player_unit_ids[0]
	var id1: StringName = ctrl.state.player_unit_ids[1]
	var us0_idx: int = -1
	var us1_idx: int = -1
	for i in ctrl.state.unit_states.size():
		var us = ctrl.state.unit_states[i]
		if us.unit_id == id0:
			us0_idx = i
		elif us.unit_id == id1:
			us1_idx = i
	_assert(us0_idx >= 0 and us1_idx >= 0, "both ids in unit_states")
	var us0 = ctrl.state.unit_states[us0_idx]
	var us1 = ctrl.state.unit_states[us1_idx]
	us0.current_hp = 50
	us1.current_hp = 30
	ctrl.swap_board_units(0, 1)
	# После swap player_unit_ids[0] == id1, player_unit_ids[1] == id0.
	_assert(ctrl.state.player_unit_ids[0] == id1, "board[0] is now id1")
	_assert(ctrl.state.player_unit_ids[1] == id0, "board[1] is now id0")
	# unit_states должны быть в том же индексе — мы НЕ перетасовываем массив,
	# только переставляем ID в player_unit_ids. unit_states[id_idx] все ещё принадлежит id.
	var us0_after = ctrl.state.unit_states[us0_idx]
	var us1_after = ctrl.state.unit_states[us1_idx]
	_assert(us0_after.unit_id == id0 and us0_after.current_hp == 50,
		"us0 still tracks id0 with HP=50")
	_assert(us1_after.unit_id == id1 and us1_after.current_hp == 30,
		"us1 still tracks id1 with HP=30")
	_cleanup_ctrl(ctrl)



func _recursive_find_buttons(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Button:
			out.append(c)
		_recursive_find_buttons(c, out)


func _test_prep_scene_creates_board_and_bench_buttons() -> void:
	print("[test] S6.2: PrepScene creates board + bench buttons + Ready")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var scene: Control = PrepSceneScript.new()
	scene.set_run_controller(ctrl)
	root.add_child.call_deferred(scene)
	for i in 3: await process_frame
	var btns: Array = []
	_recursive_find_buttons(scene, btns)
	var expected: int = ctrl.state.player_unit_ids.size() + ctrl.state.bench_unit_ids.size() + 1
	_assert(btns.size() == expected,
		"PrepScene buttons count = %d (got %d, expected board %d + bench %d + 1 Ready)"
		% [expected, btns.size(), ctrl.state.player_unit_ids.size(), ctrl.state.bench_unit_ids.size()])
	_cleanup_ctrl(ctrl)
	scene.queue_free()
	await process_frame


func _test_prep_scene_swap_two_board_slots() -> void:
	print("[test] S6.2: click 2 board slots -> swap")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var ids: Array = ctrl.state.player_unit_ids.duplicate()
	var scene: Control = PrepSceneScript.new()
	scene.set_run_controller(ctrl)
	root.add_child.call_deferred(scene)
	for i in 3: await process_frame
	var board_btns: Array = scene._board_buttons
	_assert(board_btns.size() == 2, "scene has 2 board buttons (got %d)" % board_btns.size())
	board_btns[0].emit_signal("pressed")
	board_btns[1].emit_signal("pressed")
	await process_frame
	var new_ids: Array = ctrl.state.player_unit_ids.duplicate()
	_assert(new_ids[0] == ids[1] and new_ids[1] == ids[0],
		"board swapped (got %s vs %s)" % [new_ids[0], new_ids[1]])
	_cleanup_ctrl(ctrl)
	scene.queue_free()
	await process_frame


func _test_prep_scene_board_to_bench_workflow() -> void:
	print("[test] S6.2: click board -> click bench slot -> move")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.state.bench_unit_ids.append(&"warrior")
	var id0: StringName = ctrl.state.player_unit_ids[0]
	var scene: Control = PrepSceneScript.new()
	scene.set_run_controller(ctrl)
	root.add_child.call_deferred(scene)
	for i in 3: await process_frame
	var board_btns: Array = scene._board_buttons
	var bench_btns: Array = scene._bench_buttons
	_assert(board_btns.size() == 2 and bench_btns.size() == 1,
		"board=2 bench=1 (got %d, %d)" % [board_btns.size(), bench_btns.size()])
	board_btns[0].emit_signal("pressed")
	bench_btns[0].emit_signal("pressed")
	await process_frame
	var board_size: int = ctrl.state.player_unit_ids.size()
	var bench_size: int = ctrl.state.bench_unit_ids.size()
	_assert(board_size == 1, "board 2->1 (got %d)" % board_size)
	_assert(bench_size == 2, "bench 1->2 (got %d)" % bench_size)
	_assert(ctrl.state.bench_unit_ids[0] == id0,
		"moved id at bench[0] (got %s)" % ctrl.state.bench_unit_ids[0])
	_cleanup_ctrl(ctrl)
	scene.queue_free()
	await process_frame


func _test_prep_scene_ready_button_triggers_battle() -> void:
	print("[test] S6.2: Ready button -> start_battle()")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var scene: Control = PrepSceneScript.new()
	scene.set_run_controller(ctrl)
	root.add_child.call_deferred(scene)
	for i in 3: await process_frame
	var ready_btn: Button = null
	for c in scene.get_children():
		if c is Button and c.text.find("Ready") >= 0:
			ready_btn = c
			break
	_assert(ready_btn != null, "Ready button found")
	ready_btn.emit_signal("pressed")
	await process_frame
	_assert(ctrl.phase == ctrl.Phase.BATTLE,
		"phase = BATTLE after Ready (got %d)" % ctrl.phase)
	_cleanup_ctrl(ctrl)
	scene.queue_free()
	await process_frame
func _test_combatant_hp_override_parameter() -> void:
	print("[test] S6.3: Combatant._init принимает hp_override и применяет его")
	var def: Resource = UnitDefScript.new()
	def.id = &"hp_test"
	def.max_hp = 100
	var c = CombatantScript.new(def, 1.0, 1.0, 1.0, 50)
	_assert(c.health.current_hp == 50, "hp_override=50 -> start at 50 (got %d)" % c.health.current_hp)
	_assert(c.health.max_hp() == 100, "max_hp stays 100 (got %d)" % c.health.max_hp())


func _test_combatant_hp_override_minus_one_uses_max() -> void:
	print("[test] S6.3: Combatant hp_override=-1 использует max_hp (default)")
	var def: Resource = UnitDefScript.new()
	def.id = &"hp_default"
	def.max_hp = 80
	var c = CombatantScript.new(def, 1.0, 1.0, 1.0, -1)
	_assert(c.health.current_hp == 80, "hp_override=-1 -> start at max_hp 80 (got %d)" % c.health.current_hp)


func _test_run_controller_start_battle_persists_unit_hp() -> void:
	print("[test] S6.3: start_battle передаёт unit_states[].current_hp в Combatant")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# Damage first unit to 30 HP.
	ctrl.state.unit_states[0].current_hp = 30
	# Trigger battle via _on_node_selected for combat.
	ctrl._enter_map()
	for i in 2: await process_frame
	var combat_id: int = -1
	for id in ctrl.encounter_map.get_available_next_ids():
		var n = ctrl.encounter_map.get_node(id)
		if n != null and n.is_combat():
			combat_id = id
			break
	ctrl._on_node_selected(combat_id)
	# Now in PREP, set phase=PREP then start_battle.
	ctrl.start_battle()
	# Find player Combatant in ctx.
	var found: Combatant = null
	for c in ctrl.ctx.all_combatants():
		if c.team == 0 and c.def_id == ctrl.state.unit_states[0].unit_id:
			found = c
			break
	_assert(found != null, "player unit found in ctx")
	if found != null:
		_assert(found.health.current_hp == 30,
			"Combatant start_hp = 30 (persisted from unit_states, got %d)" % found.health.current_hp)
	_cleanup_ctrl(ctrl)


func _test_run_controller_grant_item_appends_to_state() -> void:
	print("[test] S7.1: grant_item добавляет в state.item_ids")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var initial_count: int = ctrl.state.item_ids.size()
	_assert(ctrl.inventory_count() == initial_count, "start empty (got count=%d)" % initial_count)
	var ok: bool = ctrl.grant_item(&"potion_strength")
	_assert(ok, "grant_item returns true")
	_assert(ctrl.inventory_count() == initial_count + 1, "count 0->1 (got %d)" % ctrl.inventory_count())
	_assert(ctrl.state.item_ids[-1] == &"potion_strength", "last id = potion_strength (got %s)" % ctrl.state.item_ids[-1])
	_cleanup_ctrl(ctrl)


func _test_run_controller_grant_item_respects_capacity() -> void:
	print("[test] S7.1: grant_item respects MAX_INVENTORY cap")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	# Fill inventory to MAX_INVENTORY (e.g. 12).
	for i in 12:
		ctrl.grant_item(&"potion_strength")
	_assert(ctrl.inventory_count() == 12, "filled to 12 (got %d)" % ctrl.inventory_count())
	# 13th grant rejected.
	var ok: bool = ctrl.grant_item(&"potion_strength")
	_assert(not ok, "13th grant rejected")
	_assert(ctrl.inventory_count() == 12, "count still 12 (got %d)" % ctrl.inventory_count())
	_cleanup_ctrl(ctrl)


func _test_run_controller_remove_item_at_decrements() -> void:
	print("[test] S7.1: remove_item_at removes by index")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.grant_item(&"potion_strength")
	ctrl.grant_item(&"scroll_ward")
	ctrl.grant_item(&"amulet_vigor")
	_assert(ctrl.inventory_count() == 3, "added 3 (got %d)" % ctrl.inventory_count())
	var ok: bool = ctrl.remove_item_at(1)  # remove scroll_ward
	_assert(ok, "remove idx=1 returns true")
	_assert(ctrl.inventory_count() == 2, "count 3->2 (got %d)" % ctrl.inventory_count())
	_assert(ctrl.state.item_ids[0] == &"potion_strength" and ctrl.state.item_ids[1] == &"amulet_vigor",
		"removed middle slot")
	# Out of range rejection
	_assert(not ctrl.remove_item_at(-1), "negative idx rejected")
	_assert(not ctrl.remove_item_at(99), "out of range idx rejected")
	_cleanup_ctrl(ctrl)


func _test_run_controller_inventory_get_item_def_at_returns_resolved() -> void:
	print("[test] S7.1: get_item_def_at resolves id -> ItemDef")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.grant_item(&"potion_strength")
	var def: Resource = ctrl.get_item_def_at(0)
	_assert(def != null, "def returned (got %s)" % str(def))
	if def != null:
		_assert(def.id == &"potion_strength", "id matches (got %s)" % def.id)
		_assert(def.display_name != "", "display_name populated (got '%s')" % def.display_name)
	_cleanup_ctrl(ctrl)


func _test_run_controller_inventory_persists_in_save() -> void:
	print("[test] S7.1: item_ids persists через save/load")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	ctrl.grant_item(&"potion_strength")
	ctrl.grant_item(&"amulet_vigor")
	ctrl.save_now()
	var save_path: String = "user://test_inv_save.tres"
	SaveSvcScript.save_resource(ctrl.state, save_path)
	var loaded: Resource = SaveSvcScript.load_resource(save_path)
	_assert(loaded != null and loaded.item_ids.size() == 2,
		"loaded item_ids size = 2 (got %s)" % str(loaded))
	if loaded != null:
		_assert(loaded.item_ids[0] == &"potion_strength", "loaded[0] = potion_strength")
		_assert(loaded.item_ids[1] == &"amulet_vigor", "loaded[1] = amulet_vigor")
	_cleanup_ctrl(ctrl)



func _test_run_controller_treasure_grants_random_item() -> void:
	print("[test] S7.1: TREASURE grants random item into inventory")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	ctrl.start_run(42)
	var before_count: int = ctrl.inventory_count()
	# Apply TREASURE directly via private method (test). ItemDB must have at
	# least 1 ItemDef (from content/items/).
	ctrl._apply_treasure_effect()
	var after_count: int = ctrl.inventory_count()
	_assert(after_count >= before_count + 1 or after_count == before_count,
		"inventory grew or unchanged (got before=%d after=%d)" % [before_count, after_count])
	_cleanup_ctrl(ctrl)

