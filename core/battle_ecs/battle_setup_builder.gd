class_name BattleSetupBuilder extends RefCounted
## Phase 2 / Gauntlet 3 — adapter from Run Domain to BattleSetup.
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
## The deployment pattern mirrors legacy start_battle:
##   - player at y = grid_height - 1, x = board_index
##   - enemy at y = 0, x = wave_index
##
## Enemies get empty source_run_unit_id ("").

const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const BalanceScript = preload("res://core/balance.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")


## Build a BattleSetup from a RunDomainState.
##
## p_seed: deterministic seed for the new simulation RNG.
## p_round_index: round number (1-based), used by the enemy
## spawner. For Phase 2 vertical slice the enemy spawner is the
## same one legacy _spawn_enemy_wave uses (so existing balance
## numbers are honoured), but routed through this adapter so we
## can swap implementations later without touching RunController.
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
	# S5.4 + T3F.5: board snapshot captured here. Dead units
	# skipped — same semantics as legacy start_battle.
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
		# Apply persistent bonuses (attack, defense, max_hp) from
		# the equipped items and starting HP override — same as
		# legacy start_battle. Adapter reads equipped items
		# directly from state so it does NOT depend on
		# RunController.get_unit_bonus_stats.
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
	# Enemy wave — replicate legacy _spawn_enemy_wave logic.
	var enemy_units: Array = _build_enemy_wave(p_round_index, p_grid_width)
	return BattleSetupScript.new(
			int(p_seed),
			player_units,
			enemy_units,
			int(p_grid_width),
			int(p_grid_height))


## Returns a deterministic-ish enemy wave for a round.
## Mirrors the legacy `_spawn_enemy_wave` logic but uses the
## adapter's own seed-derived Rng path (NOT the global Rng).
##
## For Phase 2 vertical slice the enemy pool / count / HP scaling
## continue to come from Balance + ContentDB, exactly as before.
static func _build_enemy_wave(round_index: int, grid_width: int) -> Array:
	var n: int = BalanceScript.enemy_count_for_round(round_index)
	var pool: Array = BalanceScript.enemy_pool_for_round(round_index)
	var hp_mult: float = BalanceScript.enemy_hp_multiplier(round_index)
	var result: Array = []
	for i in n:
		if i >= grid_width:
			break
		var pool_id: StringName = &"goblin"
		if not pool.is_empty():
			pool_id = pool[0]  # vertical slice: pick pool[0] for determinism
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
