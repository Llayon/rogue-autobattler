class_name BattleSetupBuilder extends RefCounted
## Phase 2 / Gauntlet 3 — adapter from Run Domain to BattleSetup.
##
## HIGH 7 fix: enemy wave picks are produced from an EXPLICIT
## DeterministicRng derived from the battle seed (NOT the legacy
## global Rng facade). Same seed -> same enemy wave (deterministic
## across runs). Different seeds can yield different pool picks
## within the established Balance enemy pool.
##
## Reads a RunDomainState + battle seed + round_index and
## produces a BattleSetup with:
##   - one BattleUnitSetup per ALIVE board RunUnit (skipping dead)
##   - one BattleUnitSetup per enemy spawned for the round
##
## Stable RunUnit.instance_id is preserved as
## BattleUnitSetup.source_run_unit_id. definition_id is content
## only — never used as entity identity.
##
## Does NOT mutate RunDomainState.
##
## Deployment mirrors legacy start_battle:
##   - player at y = grid_height - 1, x = board_index
##   - enemy at y = 0, x = wave_index
##
## Enemies get empty source_run_unit_id ("").
##
## Damage/variance/crit/dodge intentionally omitted — see
## BattleSimulation._compute_damage() and the legacy comparison
## test classification (NORMATIVE FEATURE DEFER).

const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const BalanceScript = preload("res://core/balance.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")


## Build a BattleSetup from a RunDomainState.
##
## p_seed: deterministic seed for the new simulation RNG. Also
## seeds the explicit builder RNG for enemy wave picks.
## p_round_index: 1-based, used by the enemy spawner (count,
## pool, HP scaling via Balance).
##
## Returns a BattleSetup. Caller is responsible for calling
## `setup.validate()` and handling any returned error.
static func build(
		p_state: RunDomainStateScript,
		p_seed: int,
		p_round_index: int,
		p_grid_width: int = 7,
		p_grid_height: int = 4) -> BattleSetupScript:
	var player_units: Array = []
	var board_units: Array = p_state.get_board_units()
	var total_atk_bonus: int = int(p_state.meta_modifiers.get("rest_attack_bonus", 0)) + \
			int(p_state.meta_modifiers.get("shrine_attack_bonus", 0))
	var atk_mul: float = 1.0 + float(total_atk_bonus) / 100.0
	for i in board_units.size():
		var u = board_units[i]
		if u == null:
			continue
		if not u.is_alive():
			continue
		var def: Resource = ContentDBScript.get_by_id(u.definition_id)
		if def == null:
			continue
		var bonus_atk: int = int(u.bonus_attack)
		var bonus_def: int = 0
		var bonus_hp: int = 0
		var equipped: Array = p_state.get_equipped_items(String(u.instance_id))
		for it in equipped:
			if it == null:
				continue
			var item_def: Resource = ContentDBScript.get_by_id(it.definition_id)
			if item_def == null:
				continue
			bonus_atk += int(item_def.bonus_attack) if "bonus_attack" in item_def else 0
			bonus_def += int(item_def.bonus_defense) if "bonus_defense" in item_def else 0
			bonus_hp += int(item_def.bonus_max_hp) if "bonus_max_hp" in item_def else 0
		var starting_hp: int = int(u.current_hp)
		if starting_hp <= 0:
			starting_hp = int(def.max_hp)
		var max_hp: int = int(round(float(def.max_hp) * 1.0)) + bonus_hp
		var atk: int = int(round(float(def.attack) * atk_mul)) + bonus_atk
		var dfs: int = int(round(float(def.defense) * 1.0)) + bonus_def
		var cell: Vector2i = Vector2i(int(i), p_grid_height - 1)
		var unit_setup: BattleUnitSetupScript = BattleUnitSetupScript.new(
				String(u.instance_id),
				def.id,
				0,
				cell,
				starting_hp,
				max_hp,
				atk,
				dfs,
				int(def.attack_range))
		player_units.append(unit_setup)
	# HIGH 7 fix: explicit deterministic RNG for enemy wave
	# picks. The seed is derived deterministically from the
	# battle seed so the same battle seed always produces the
	# same enemy wave.
	var builder_rng: RefCounted = DeterministicRngScript.new(0)
	builder_rng.seed_with(int(p_seed) ^ 0x5eed_b4bb)
	var enemy_units: Array = _build_enemy_wave(
		p_round_index, p_grid_width, builder_rng)
	return BattleSetupScript.new(
			int(p_seed),
			player_units,
			enemy_units,
			int(p_grid_width),
			int(p_grid_height))


## Build a deterministic enemy wave for a round using an
## explicit DeterministicRng (NOT the global Rng facade).
##
## Mirrors legacy semantics (count + pool + HP scaling via
## Balance). Each enemy ID is drawn via randi_range from the
## provided RNG, so the same seed produces the same wave.
static func _build_enemy_wave(round_index: int, grid_width: int, rng) -> Array:
	var n: int = BalanceScript.enemy_count_for_round(round_index)
	var pool: Array = BalanceScript.enemy_pool_for_round(round_index)
	var hp_mult: float = BalanceScript.enemy_hp_multiplier(round_index)
	var result: Array = []
	for i in n:
		if i >= grid_width:
			break
		var pool_id: StringName = &"goblin"
		if not pool.is_empty():
			var idx: int = int(rng.randi_range(0, pool.size() - 1))
			pool_id = pool[idx]
		var enemy_def: Resource = ContentDBScript.get_by_id(pool_id)
		if enemy_def == null:
			continue
		var scaled: Resource = enemy_def.duplicate()
		scaled.max_hp = int(round(float(scaled.max_hp) * hp_mult))
		var cell: Vector2i = Vector2i(int(i), 0)
		var unit_setup: BattleUnitSetupScript = BattleUnitSetupScript.new(
				"",
				scaled.id,
				1,
				cell,
				int(scaled.max_hp),
				int(scaled.max_hp),
				int(scaled.attack),
				int(scaled.defense),
				int(scaled.attack_range))
		result.append(unit_setup)
	return result
