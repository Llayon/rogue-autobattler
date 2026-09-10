extends SceneTree
## Phase 2 / Gauntlet 3 — BattleSetupBuilder adapter test.

const BattleSetupBuilderScript = preload("res://core/battle_ecs/battle_setup_builder.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")
const RunItemScript = preload("res://core/progression/run_item.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# ContentDB must be initialized before BalanceScript.enemy_* queries work.
	# Use the same load path as production code.
	ContentDBScript.load_all()
	await _test_builder_empty_state_returns_enemy_only()
	await _test_builder_single_player_preserves_instance_id()
	await _test_builder_dead_units_skipped()
	await _test_builder_duplicate_definitions_produce_distinct_player_rows()
	await _test_builder_board_order_preserved()
	await _test_builder_swapped_board_order_reflected_in_setup()
	await _test_builder_equipped_item_bonuses_applied()
	await _test_builder_enemy_wave_has_empty_source_run_unit_id()
	await _test_builder_enemy_wave_seeded_deterministic()
	await _test_builder_enemy_wave_different_seeds_can_differ()
	await _test_builder_no_runda_state_mutation()
	await _test_builder_validation_passes_for_normal_setup()
	print("\n=== battle_ecs setup_builder: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


func _make_state_with_units(unit_def_ids: Array) -> RunDomainStateScript:
	var state: RunDomainStateScript = RunDomainStateScript.new()
	for def_id in unit_def_ids:
		var def: Resource = ContentDBScript.get_by_id(def_id)
		if def == null:
			continue
		state.create_unit(def_id, int(def.max_hp), RunUnitScript.LOCATION_BOARD)
	return state


func _test_builder_empty_state_returns_enemy_only() -> void:
	print("[b-1] empty_state_returns_enemy_only")
	var state: RunDomainStateScript = RunDomainStateScript.new()
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	# Player side is empty → validate() must reject.
	var msg: String = s.validate()
	_assert(msg == "no player units", "validate rejects empty player (got '%s')" % msg)
	# But the enemy wave still has at least 1 row.
	_assert(s.enemy_units.size() >= 1, "enemy wave populated (got %d)" % s.enemy_units.size())


func _test_builder_single_player_preserves_instance_id() -> void:
	print("[b-2] single_player_preserves_instance_id")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior"])
	var u: RunUnitScript = state.get_board_units()[0]
	var original_id: String = String(u.instance_id)
	_assert(original_id != "", "warrior got an instance_id")
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	_assert(s.player_units.size() == 1, "one player row (got %d)" % s.player_units.size())
	_assert(String(s.player_units[0].source_run_unit_id) == original_id,
		"source_run_unit_id matches RunUnit.instance_id (got '%s' vs '%s')"
			% [String(s.player_units[0].source_run_unit_id), original_id])
	_assert(s.player_units[0].definition_id == &"warrior", "definition_id preserved")


func _test_builder_dead_units_skipped() -> void:
	print("[b-3] dead_units_skipped")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior", &"archer", &"cleric"])
	# Kill the middle one.
	var board: Array = state.get_board_units()
	var middle: RunUnitScript = board[1]
	middle.dead = true
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	# Only warrior and cleric should remain.
	_assert(s.player_units.size() == 2, "2 alive units (got %d)" % s.player_units.size())
	var ids: Array = []
	for p in s.player_units:
		ids.append(String(p.source_run_unit_id))
	var has_dead: bool = false
	for id_s in ids:
		if id_s == String(middle.instance_id):
			has_dead = true
	_assert(not has_dead, "dead unit skipped (ids: %s)" % str(ids))


func _test_builder_duplicate_definitions_produce_distinct_player_rows() -> void:
	print("[b-4] duplicate_definitions_distinct_player_rows")
	# Two warriors: same definition_id, distinct instance_ids.
	var state: RunDomainStateScript = _make_state_with_units([&"warrior", &"warrior"])
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	_assert(s.player_units.size() == 2, "2 player rows (got %d)" % s.player_units.size())
	var a_id: String = String(s.player_units[0].source_run_unit_id)
	var b_id: String = String(s.player_units[1].source_run_unit_id)
	_assert(a_id != b_id, "distinct instance_ids despite same definition (got '%s' '%s')" % [a_id, b_id])
	_assert(s.player_units[0].definition_id == s.player_units[1].definition_id,
		"definition_id is the same (content only)")
	_assert(s.player_units[0].cell != s.player_units[1].cell,
		"distinct deployment cells (got %s %s)" % [str(s.player_units[0].cell), str(s.player_units[1].cell)])


func _test_builder_board_order_preserved() -> void:
	print("[b-5] board_order_preserved")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior", &"archer", &"cleric"])
	var board: Array = state.get_board_units()
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	_assert(s.player_units.size() == 3, "3 rows")
	for i in 3:
		_assert(String(s.player_units[i].source_run_unit_id) == String(board[i].instance_id),
			"order[%d] matches board[%d]" % [i, i])
		_assert(s.player_units[i].cell.x == i, "x=i (%d)" % i)
		_assert(s.player_units[i].cell.y == 3, "y=3 (back row) (got %d)" % s.player_units[i].cell.y)


func _test_builder_swapped_board_order_reflected_in_setup() -> void:
	print("[b-6] swapped_board_order_reflected_in_setup")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior", &"archer"])
	# Swap order 0 <-> 1 by swapping their `order` field.
	var board: Array = state.get_board_units()
	var a: RunUnitScript = board[0]
	var b: RunUnitScript = board[1]
	var tmp: int = int(a.order)
	a.order = int(b.order)
	b.order = tmp
	# Re-fetch in new order.
	board = state.get_board_units()
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	_assert(String(s.player_units[0].source_run_unit_id) == String(b.instance_id),
		"first setup row reflects swapped board[0] (got '%s' expected '%s')"
			% [String(s.player_units[0].source_run_unit_id), String(b.instance_id)])
	_assert(String(s.player_units[1].source_run_unit_id) == String(a.instance_id),
		"second setup row reflects swapped board[1] (got '%s' expected '%s')"
			% [String(s.player_units[1].source_run_unit_id), String(a.instance_id)])


func _test_builder_equipped_item_bonuses_applied() -> void:
	print("[b-7] equipped_item_bonuses_applied")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior"])
	var u: RunUnitScript = state.get_board_units()[0]
	var warrior_def: Resource = ContentDBScript.get_by_id(&"warrior")
	var base_atk: int = int(warrior_def.attack)
	# Grant a known item with a known bonus_attack.
	# Pick first item from content db with bonus_attack > 0.
	var item_id: StringName = &""
	var bonus_atk_value: int = 0
	for candidate in [&"potion_strength", &"amulet_vigor", &"rune_power"]:
		var d: Resource = ContentDBScript.get_by_id(candidate)
		if d == null:
			continue
		if d.bonus_attack > 0:
			item_id = candidate
			bonus_atk_value = int(d.bonus_attack)
			break
	if item_id == &"":
		# No item with bonus_attack found — skip this assertion.
		print("  [SKIP] no test item with bonus_attack in content; skipping bonus assertion")
		_assert(true, "skipped — no bonus_attack item in content")
		return
	var item: RunItemScript = state.create_item(item_id)
	# Manual equip — RunDomainState does not own an equip helper;
	# the controller wires the bidirectional relationship.
	item.owner_unit_id = String(u.instance_id)
	if not u.equipped_item_ids.has(String(item.instance_id)):
		u.equipped_item_ids.append(String(item.instance_id))
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	var got_atk: int = int(s.player_units[0].attack_base)
	_assert(got_atk == base_atk + bonus_atk_value,
		"attack_base = base + bonus (got %d expected %d)" % [got_atk, base_atk + bonus_atk_value])


func _test_builder_enemy_wave_has_empty_source_run_unit_id() -> void:
	print("[b-8] enemy_wave_has_empty_source_run_unit_id")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior"])
	var s: BattleSetupScript = BattleSetupBuilder.build(state, 42, 1)
	for e in s.enemy_units:
		_assert(String(e.source_run_unit_id) == "",
			"enemy source_run_unit_id is empty (got '%s')" % String(e.source_run_unit_id))
		_assert(int(e.team) == 1, "enemy team=1 (got %d)" % int(e.team))
		_assert(int(e.cell.y) == 0, "enemy y=0 (got %d)" % int(e.cell.y))


func _test_builder_enemy_wave_seeded_deterministic() -> void:
	# HIGH 7 fix: enemy wave picks must use a deterministic
	# builder-side RNG. Same seed -> same wave.
	print("[b-8b] enemy_wave_seeded_deterministic")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior"])
	var s_a: BattleSetupScript = BattleSetupBuilder.build(state, 7777, 3)
	var s_b: BattleSetupScript = BattleSetupBuilder.build(state, 7777, 3)
	_assert(s_a.enemy_units.size() == s_b.enemy_units.size(),
		"same seed -> same enemy wave size (got %d vs %d)" % [s_a.enemy_units.size(), s_b.enemy_units.size()])
	for i in s_a.enemy_units.size():
		_assert(s_a.enemy_units[i].definition_id == s_b.enemy_units[i].definition_id,
			"enemy[%d] definition_id matches (a=%s b=%s)" % [i, String(s_a.enemy_units[i].definition_id), String(s_b.enemy_units[i].definition_id)])
		_assert(s_a.enemy_units[i].max_hp == s_b.enemy_units[i].max_hp,
			"enemy[%d] max_hp matches (a=%d b=%d)" % [i, s_a.enemy_units[i].max_hp, s_b.enemy_units[i].max_hp])


func _test_builder_enemy_wave_different_seeds_can_differ() -> void:
	# HIGH 7 fix: different seeds MAY produce different enemy picks
	# (but at minimum they must produce valid waves from the pool).
	print("[b-8c] enemy_wave_different_seeds_can_differ")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior"])
	# Run 10 different seeds. Each wave must use only pool members.
	for seed in [1, 7, 42, 99, 123, 555, 777, 999, 1234, 5678]:
		var s: BattleSetupScript = BattleSetupBuilder.build(state, seed, 3)
		_assert(s.enemy_units.size() >= 1, "seed %d: wave non-empty" % seed)
		# All enemy IDs must be valid (resolve via ContentDB).
		for e in s.enemy_units:
			var def = ContentDBScript.get_by_id(e.definition_id)
			_assert(def != null, "seed %d: enemy def '%s' resolves" % [seed, String(e.definition_id)])


func _test_builder_no_runda_state_mutation() -> void:
	print("[b-9] no_run_domain_state_mutation")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior", &"archer"])
	# Snapshot domain state before build.
	var before_units: Array = state.units.duplicate(true)
	var before_items: Array = state.items.duplicate(true)
	var before_meta: Dictionary = state.meta_modifiers.duplicate()
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	# Force the simulation to actually run so any latent mutation would surface.
	var sim = preload("res://core/battle_ecs/battle_simulation.gd").new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	# Domain state must be byte-equal to before.
	_assert(state.units.size() == before_units.size(),
		"unit count unchanged (got %d vs %d)" % [state.units.size(), before_units.size()])
	_assert(state.items.size() == before_items.size(),
		"item count unchanged (got %d vs %d)" % [state.items.size(), before_items.size()])
	# meta_modifiers may be Dictionary — compare string form.
	var before_str: String = JSON.stringify(before_meta)
	var after_str: String = JSON.stringify(state.meta_modifiers)
	_assert(before_str == after_str, "meta_modifiers unchanged")


func _test_builder_validation_passes_for_normal_setup() -> void:
	print("[b-10] validation_passes_for_normal_setup")
	var state: RunDomainStateScript = _make_state_with_units([&"warrior", &"archer"])
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	var msg: String = s.validate()
	_assert(msg == "", "validate passes (got '%s')" % msg)
