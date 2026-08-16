extends SceneTree

## Phase 1 / T3B contract tests for the v4 mapper.
##
## The mapper is a pure, side-effect-free translator between
## `RunDomainState` (live canonical) and the v4 Save Schema DTO
## (persistence wire format). These tests assert:
##   - instance ids survive round-trip verbatim
##   - sequence counters survive round-trip verbatim (no auto-bump)
##   - hp / location / order / equipment / owner_unit_id round-trip
##   - empty domain round-trip is valid
##   - the produced DTO passes SaveSchemaV4.validate_shape

const RUN_DOMAIN_PRELOAD: GDScript = preload("res://core/progression/run_domain_state.gd")
const RUN_UNIT_PRELOAD: GDScript = preload("res://core/progression/run_unit.gd")
const RunUnit: GDScript = preload("res://core/progression/run_unit.gd")
const RUN_ITEM_PRELOAD: GDScript = preload("res://core/progression/run_item.gd")
const MAPPER: GDScript = preload("res://core/progression/run_state_v4_mapper.gd")
const SCHEMA: GDScript = preload("res://core/save/save_schema_v4.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_to_v4_dto_passes_validate_shape()
	_test_round_trip_preserves_unit_identity()
	_test_round_trip_preserves_item_identity()
	_test_round_trip_preserves_sequence_counters()
	_test_round_trip_preserves_equipment_link()
	_test_round_trip_two_warriors_distinct_hp()
	_test_round_trip_empty_domain()
	_test_round_trip_preserves_location_and_order()
	_test_round_trip_preserves_run_scalars()
	_test_round_trip_does_not_mint_new_ids()
	print("\n=== run state v4 mapper: %d passed, %d failed ===\n" % [_passed, _failed])
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


## Builds a sample domain: two board warriors + one bench warrior,
## one item (inventory) and one item (equipped to unit_000001),
## non-trivial scalars.
func _build_sample_domain() -> RunDomainState:
	var s: RunDomainState = RUN_DOMAIN_PRELOAD.new()
	s.seed = 9001
	s.round_index = 7
	s.gold = 42
	s.xp = 130
	s.level = 3
	s.lives = 2
	s.wins = 4
	s.losses = 1
	s.units_killed = 11
	s.current_encounter_id = 5
	s.encounter_visited_ids = [1, 5, 12]
	s.just_visited_merchant = true
	s.meta_modifiers = {"crit_bonus": 0.1}
	var a: RunUnit = s.create_unit(&"warrior", 30, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 80, RunUnit.LOCATION_BOARD)
	var c: RunUnit = s.create_unit(&"mage", 60, RunUnit.LOCATION_BENCH)
	# Pin a concrete current_hp on b so we can prove it survives.
	b.current_hp = 45
	# Give a known equipped item to a.
	var sword: RunItem = s.create_item(&"sword")
	sword.owner_unit_id = a.instance_id
	a.equipped_item_ids.append(sword.instance_id)
	# b has a potion in inventory (owner_unit_id stays "").
	var potion: RunItem = s.create_item(&"potion")
	# Advance counters so we can verify they survive.
	s.next_unit_instance_seq = 4
	s.next_item_instance_seq = 3
	return s


## The produced DTO must satisfy the v4 shape contract. This is
## the cheap insurance against the mapper drifting from the schema
## (e.g. omitting a required key, using the wrong GDScript type).
func _test_to_v4_dto_passes_validate_shape() -> void:
	print("[shape] to_v4_dto passes SaveSchemaV4.validate_shape")
	var s: RunDomainState = _build_sample_domain()
	var dto: Dictionary = MAPPER.to_v4_dto(s)
	var shape: Dictionary = SCHEMA.validate_shape(dto)
	_assert(bool(shape.get("success", false)),
		"validate_shape passes on mapper output: %s" % str(shape.get("diagnostics", [])))
	_assert(int(dto.get("schema_version", -1)) == SCHEMA.SCHEMA_VERSION,
		"schema_version == 4")
	_assert(String(dto.get("run_id", "")) == "run_9001",
		"run_id derived from seed: run_9001")


## After to_v4_dto -> from_v4_dto the two warriors must still be
## distinct instances with their distinct max_hp. This is the
## load-bearing identity contract.
func _test_round_trip_preserves_unit_identity() -> void:
	print("[unit identity] two warriors survive round-trip with distinct hp")
	var src: RunDomainState = _build_sample_domain()
	var a: RunUnit = src.get_unit("unit_000001")
	var b: RunUnit = src.get_unit("unit_000002")
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst = MAPPER.from_v4_dto(dto)
	var a2 = dst.get_unit("unit_000001")
	var b2 = dst.get_unit("unit_000002")
	_assert(a2 != null and b2 != null, "both warriors present after round-trip")
	_assert(a2.instance_id == "unit_000001", "a.instance_id == unit_000001")
	_assert(b2.instance_id == "unit_000002", "b.instance_id == unit_000002")
	_assert(a2.max_hp == 30 and b2.max_hp == 80,
		"max_hp per-instance survives: 30 / 80")
	_assert(b2.current_hp == 45, "current_hp survives (45)")
	_assert(a2.definition_id == &"warrior", "a definition_id == warrior")
	_assert(b2.definition_id == &"warrior", "b definition_id == warrior")
	_assert(a2.location == RunUnit.LOCATION_BOARD, "a on board")
	_assert(b2.location == RunUnit.LOCATION_BOARD, "b on board")
	_assert(a2.order == 0 and b2.order == 1, "a/b orders preserved")


## Items round-trip too, including owner_unit_id (empty for
## inventory, non-empty for equipped).
func _test_round_trip_preserves_item_identity() -> void:
	print("[item identity] items + owner_unit_id survive round-trip")
	var src: RunDomainState = _build_sample_domain()
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	_assert(dst.items.size() == 2, "two items after round-trip")
	var sword: RunItem = dst.get_item("item_000001")
	var potion: RunItem = dst.get_item("item_000002")
	_assert(sword != null and sword.instance_id == "item_000001",
		"sword instance_id preserved")
	_assert(potion != null and potion.instance_id == "item_000002",
		"potion instance_id preserved")
	_assert(sword.definition_id == &"sword", "sword definition_id")
	_assert(potion.definition_id == &"potion", "potion definition_id")
	_assert(sword.owner_unit_id == "unit_000001",
		"sword.owner_unit_id == unit_000001")
	_assert(potion.owner_unit_id == "",
		"potion.owner_unit_id stays empty (in inventory)")


## Sequence counters survive exactly. Auto-bumping on load would
## create a phantom unused id and could mask a real overflow.
func _test_round_trip_preserves_sequence_counters() -> void:
	print("[seq] next_*_instance_seq survives exactly (no auto-bump)")
	var src: RunDomainState = _build_sample_domain()
	_assert(src.next_unit_instance_seq == 4, "src unit seq is 4")
	_assert(src.next_item_instance_seq == 3, "src item seq is 3")
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	_assert(int(dto.get("next_unit_instance_seq", 0)) == 4,
		"dto unit seq is 4")
	_assert(int(dto.get("next_item_instance_seq", 0)) == 3,
		"dto item seq is 3")
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	_assert(dst.next_unit_instance_seq == 4,
		"dst unit seq is 4 (no auto-bump on load)")
	_assert(dst.next_item_instance_seq == 3,
		"dst item seq is 3 (no auto-bump on load)")


## The two halves of an equipment link must round-trip together.
## `RunUnit.equipped_item_ids` AND `RunItem.owner_unit_id` must
## both arrive at the same state.
func _test_round_trip_preserves_equipment_link() -> void:
	print("[equipment] equipped_item_ids and owner_unit_id agree after round-trip")
	var src: RunDomainState = _build_sample_domain()
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	var a: RunUnit = dst.get_unit("unit_000001")
	var sword: RunItem = dst.get_item("item_000001")
	_assert(a.equipped_item_ids.size() == 1,
		"unit_000001 equipped list size 1 after round-trip")
	_assert(a.equipped_item_ids[0] == "item_000001",
		"unit_000001 equipped list contains item_000001")
	_assert(sword.owner_unit_id == "unit_000001",
		"sword owner_unit_id points back at unit_000001")
	# No spurious link to the inventory item.
	var potion: RunItem = dst.get_item("item_000002")
	_assert(potion.owner_unit_id == "",
		"potion still in inventory (no spurious owner)")
	_assert(not (a.equipped_item_ids.has("item_000002")),
		"unit_000001 does not falsely list the inventory item")


## Two warriors with the SAME definition id but different max_hp
## must round-trip as two distinct units, each keeping its hp. This
## is the proof that the mapper uses `instance_id` for identity.
func _test_round_trip_two_warriors_distinct_hp() -> void:
	print("[two warriors] same definition, distinct hp survives")
	var src: RunDomainState = _build_sample_domain()
	# Force distinct current_hp on both warriors.
	src.get_unit("unit_000001").current_hp = 12
	src.get_unit("unit_000002").current_hp = 55
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	_assert(dst.get_unit("unit_000001").current_hp == 12,
		"unit_000001 current_hp = 12")
	_assert(dst.get_unit("unit_000002").current_hp == 55,
		"unit_000002 current_hp = 55")
	_assert(dst.get_unit("unit_000001").definition_id == &"warrior",
		"unit_000001 definition_id preserved")
	_assert(dst.get_unit("unit_000002").definition_id == &"warrior",
		"unit_000002 definition_id preserved")


## Empty domain must round-trip to a structurally valid DTO that
## still satisfies validate_shape and decodes back to an empty
## state with the canonical defaults.
func _test_round_trip_empty_domain() -> void:
	print("[empty] empty domain round-trips")
	var src: RunDomainState = RUN_DOMAIN_PRELOAD.new()
	src.seed = 9001  # set seed so run_id is non-empty in DTO
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var shape: Dictionary = SCHEMA.validate_shape(dto)
	_assert(bool(shape.get("success", false)),
		"empty DTO passes validate_shape")
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	_assert(dst.units.is_empty(), "dst has no units")
	_assert(dst.items.is_empty(), "dst has no items")
	_assert(dst.next_unit_instance_seq == 1, "dst unit seq default 1")
	_assert(dst.next_item_instance_seq == 1, "dst item seq default 1")


## Bench placement and order must survive, including the
## location+order split.
func _test_round_trip_preserves_location_and_order() -> void:
	print("[location+order] bench placement and orders survive")
	var src: RunDomainState = _build_sample_domain()
	# c is on bench at order 0 in the source.
	_assert(src.get_unit("unit_000003").location == RunUnit.LOCATION_BENCH,
		"src unit_000003 on bench")
	_assert(src.get_unit("unit_000003").order == 0, "src unit_000003 bench order 0")
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	var c2: RunUnit = dst.get_unit("unit_000003")
	_assert(c2.location == RunUnit.LOCATION_BENCH,
		"dst unit_000003 still on bench")
	_assert(c2.order == 0, "dst unit_000003 still bench order 0")
	var board: Array[RunUnit] = dst.get_board_units()
	var bench: Array[RunUnit] = dst.get_bench_units()
	_assert(board.size() == 2, "dst board has 2 units")
	_assert(bench.size() == 1, "dst bench has 1 unit")
	_assert(bench[0].instance_id == "unit_000003",
		"dst bench[0] is unit_000003")


## All run scalars must survive. List them explicitly to catch
## any future additions that get forgotten by the mapper.
func _test_round_trip_preserves_run_scalars() -> void:
	print("[scalars] all run scalars survive")
	var src: RunDomainState = _build_sample_domain()
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	_assert(dst.seed == 9001, "seed")
	_assert(dst.round_index == 7, "round_index")
	_assert(dst.gold == 42, "gold")
	_assert(dst.xp == 130, "xp")
	_assert(dst.level == 3, "level")
	_assert(dst.lives == 2, "lives")
	_assert(dst.wins == 4, "wins")
	_assert(dst.losses == 1, "losses")
	_assert(dst.units_killed == 11, "units_killed")
	_assert(dst.current_encounter_id == 5, "current_encounter_id")
	_assert(dst.encounter_visited_ids == [1, 5, 12],
		"encounter_visited_ids")
	_assert(dst.just_visited_merchant == true, "just_visited_merchant")
	_assert(dst.meta_modifiers.get("crit_bonus", -1) == 0.1,
		"meta_modifiers survives")


## The mapper must NEVER allocate a fresh instance id. After
## round-trip the dst allocator should still produce the NEXT id
## after the highest existing one (counted from next_*_seq), NOT
## start from 1 again.
func _test_round_trip_does_not_mint_new_ids() -> void:
	print("[no minting] next allocate after round-trip continues from saved seq")
	var src: RunDomainState = _build_sample_domain()
	var dto: Dictionary = MAPPER.to_v4_dto(src)
	var dst: RunDomainState = MAPPER.from_v4_dto(dto)
	var new_unit_id: String = dst.allocate_unit_instance_id()
	var new_item_id: String = dst.allocate_item_instance_id()
	_assert(new_unit_id == "unit_000004",
		"next unit allocation after round-trip == unit_000004")
	_assert(new_item_id == "item_000003",
		"next item allocation after round-trip == item_000003")