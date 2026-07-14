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
const BattleRunnerScriptForCtrl = preload("res://core/battle/battle_runner.gd")
const BattleStateScriptForCtrl = preload("res://core/battle/battle_state.gd")
const UnitsMetaScript = preload("res://core/data/units_meta.gd")
const RewardScreenScript = preload("res://core/progression/reward_screen.gd")



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

	_assert(c.shield == 0 and c.health.current_hp == 90, "shield absorbs first")





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

	var atk: Resource = _make_unit_def(&"atk", 100, 20)

	var def: Resource = _make_unit_def(&"def", 100, 5, 1)

	def.defense_base = 0

	var a = CombatantScript.new(atk)

	var b = CombatantScript.new(def)

	a.basic_attack(b)

	_assert(b.health.current_hp == 80, "basic_attack на 20 (defense=0)")

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

	_assert(h.health.current_hp == 70, "took 30 dmg")

	h.add_shield(20)

	h.take_damage(30)

	_assert(h.shield == 0 and h.health.current_hp == 60, "shield absorbs first")

	h.take_damage(100)

	_assert(not h.is_alive(), "dead after lethal")

	# heal на мёртвом не работает

	_assert(h.heal(50) == 0, "no heal on dead")

	_assert(h.health.current_hp == 0, "HP остался 0")





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
	# Сымитируем 5 побед подряд: round_index=5, wins=4; после _on_battle_ended → round_index=6, PREP.
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
	# Проверяем: round_index 6, phase PREP, wins=5, НЕ GAMEOVER.
	_assert(ctrl.state.round_index == 6, "round_index 5→6 (got %d)" % ctrl.state.round_index)
	_assert(ctrl.state.wins == 5, "wins 4→5 (got %d)" % ctrl.state.wins)
	_assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP после победы (got %d)" % ctrl.phase)
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



