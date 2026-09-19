extends SceneTree
## Phase 3 / B3.1 — ContentDB type-scoped resource index.
##
## Covers:
##   - cross-type duplicate IDs (e.g. ability regen + status
##     regen) coexist in their own typed maps.
##   - same-type duplicates still get rejected (first wins).
##   - get_by_id_for_type() returns the exact Resource registered
##     under (type_name, id).
##   - list_resources_by_type() returns Resources directly from
##     the typed map (no cross-type substitution via legacy
##     global _by_id).
##   - StatusDefResolver.resolve() uses typed lookup and returns
##     the StatusDef for &"regen" / &"burn".
##   - Legacy global get_by_id() preserves "first loaded wins"
##     behavior (regen from whichever directory loads first).

const ContentDBScript = preload("res://core/utils/content_db.gd")
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_typed_lookup_ability_regen()
	await _test_typed_lookup_status_regen()
	await _test_typed_resources_are_distinct()
	await _test_ability_regen_keeps_abilitydef_content()
	await _test_status_regen_keeps_statusdef_content()
	await _test_status_ids_unique_per_type()
	await _test_list_resources_by_type_is_typed()
	await _test_statusdefresolver_resolves_regen_as_statusdef()
	await _test_global_get_by_id_preserves_first_loaded_wins()
	await _test_typed_lookup_unknown_type_returns_null()
	await _test_typed_lookup_unknown_id_returns_null()
	await _test_load_all_clears_typed_index()
	print("\n=== B3.1 ContentDB typed-id tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Typed lookups return the right resource ===

func _test_typed_lookup_ability_regen() -> void:
	print("[T-1] typed_lookup_ability_regen")
	var res: Resource = ContentDBScript.get_by_id_for_type(
		"abilities", &"regen")
	_assert(res != null, "ability regen resolves (not null)")
	_assert(res.get_script() == load("res://core/data/ability_def.gd"),
		"ability regen script == AbilityDef")


func _test_typed_lookup_status_regen() -> void:
	print("[T-2] typed_lookup_status_regen")
	var res: Resource = ContentDBScript.get_by_id_for_type(
		"effects", &"regen")
	_assert(res != null, "status regen resolves (not null)")
	_assert(res.get_script() == load("res://core/data/status_def.gd"),
		"status regen script == StatusDef")


func _test_typed_resources_are_distinct() -> void:
	print("[T-3] typed_resources_are_distinct")
	var ab = ContentDBScript.get_by_id_for_type("abilities", &"regen")
	var st = ContentDBScript.get_by_id_for_type("effects", &"regen")
	_assert(ab != null and st != null, "both resolve")
	_assert(ab != st, "ability regen and status regen are distinct objects")


# === Content fidelity ===

func _test_ability_regen_keeps_abilitydef_content() -> void:
	print("[T-4] ability_regen_keeps_abilitydef_content")
	var res = ContentDBScript.get_by_id_for_type("abilities", &"regen")
	# Real content/effects/regen.tres says: cooldown=8.0, mana_cost=30.
	_assert(float(res.cooldown) == 8.0,
		"ability regen cooldown == 8.0 (got %s)" % str(res.cooldown))
	_assert(int(res.mana_cost) == 30,
		"ability regen mana_cost == 30 (got %d)" % int(res.mana_cost))


func _test_status_regen_keeps_statusdef_content() -> void:
	print("[T-5] status_regen_keeps_statusdef_content")
	var res = ContentDBScript.get_by_id_for_type("effects", &"regen")
	# Real content/effects/regen.tres says: duration=5.0, dot_heal=5.
	_assert(float(res.duration) == 5.0,
		"status regen duration == 5.0 (got %s)" % str(res.duration))
	_assert(int(res.dot_heal) == 5,
		"status regen dot_heal == 5 (got %d)" % int(res.dot_heal))


# === get_all_ids_for_type ===

func _test_status_ids_unique_per_type() -> void:
	print("[T-6] status_ids_unique_per_type")
	var ab_ids = ContentDBScript.get_all_ids_for_type("abilities")
	var st_ids = ContentDBScript.get_all_ids_for_type("effects")
	var regen_in_ab: bool = false
	var regen_in_st: bool = false
	for id in ab_ids:
		if String(id) == "regen":
			regen_in_ab = true
	for id in st_ids:
		if String(id) == "regen":
			regen_in_st = true
	_assert(regen_in_ab, "&\"regen\" appears in abilities list")
	_assert(regen_in_st, "&\"regen\" appears in effects list")


# === list_resources_by_type ===

func _test_list_resources_by_type_is_typed() -> void:
	print("[T-7] list_resources_by_type_is_typed")
	var ab = ContentDBScript.list_resources_by_type("abilities")
	var st = ContentDBScript.list_resources_by_type("effects")
	_assert(ab.size() > 0, "abilities list non-empty")
	_assert(st.size() > 0, "effects list non-empty")
	# Confirm regen in each list has the right script.
	var ab_regen_found: bool = false
	for r in ab:
		if String(r.id) == "regen":
			_assert(r.get_script() == load("res://core/data/ability_def.gd"),
				"abilities regen has AbilityDef script")
			ab_regen_found = true
	var st_regen_found: bool = false
	for r in st:
		if String(r.id) == "regen":
			_assert(r.get_script() == load("res://core/data/status_def.gd"),
				"effects regen has StatusDef script")
			st_regen_found = true
	_assert(ab_regen_found, "abilities list contains regen")
	_assert(st_regen_found, "effects list contains regen")


# === StatusDefResolver uses typed lookup ===

func _test_statusdefresolver_resolves_regen_as_statusdef() -> void:
	print("[T-8] statusdefresolver_resolves_regen_as_statusdef")
	var st_regen = StatusDefResolverScript.resolve(&"regen")
	_assert(st_regen != null, "StatusDefResolver.resolve(&regen) returns StatusDef")
	_assert(st_regen.get_script() == load("res://core/data/status_def.gd"),
		"resolved regen has StatusDef script")
	var burn = StatusDefResolverScript.resolve(&"burn")
	_assert(burn != null, "StatusDefResolver.resolve(&burn) returns StatusDef")
	_assert(float(burn.duration) == 3.0,
		"real burn.tres duration == 3.0 (got %s)" % str(burn.duration))


# === Legacy global get_by_id compat ===

func _test_global_get_by_id_preserves_first_loaded_wins() -> void:
	print("[T-9] global_get_by_id_preserves_first_loaded_wins")
	# B3.1: load order in CONTENT_DIRS is:
	#   units, enemies, abilities, effects, items
	# abilities loads BEFORE effects, so &"regen" in _by_id
	# maps to the AbilityDef.
	var res: Resource = ContentDBScript.get_by_id(&"regen")
	_assert(res != null, "global get_by_id(&regen) returns one resource")
	_assert(res.get_script() == load("res://core/data/ability_def.gd"),
		"global get_by_id returns AbilityDef regen (first-loaded wins)")


# === Robustness ===

func _test_typed_lookup_unknown_type_returns_null() -> void:
	print("[T-10] typed_lookup_unknown_type_returns_null")
	var res = ContentDBScript.get_by_id_for_type("not_a_type", &"regen")
	_assert(res == null, "unknown type returns null")


func _test_typed_lookup_unknown_id_returns_null() -> void:
	print("[T-11] typed_lookup_unknown_id_returns_null")
	var res = ContentDBScript.get_by_id_for_type("effects", &"not_an_id")
	_assert(res == null, "unknown id returns null")


# === Reload semantics ===

func _test_load_all_clears_typed_index() -> void:
	print("[T-12] load_all_clears_typed_index")
	# First load registers regen.
	ContentDBScript.load_all()
	_assert(ContentDBScript.get_by_id_for_type("effects", &"regen") != null,
		"regen in effects after first load")
	# Mutate the index by clearing one of the typed maps.
	ContentDBScript._by_id_by_type["effects"] = {}
	_assert(ContentDBScript.get_by_id_for_type("effects", &"regen") == null,
		"clearing typed effects map hides regen")
	# Re-load; typed map should be repopulated.
	ContentDBScript.load_all()
	_assert(ContentDBScript.get_by_id_for_type("effects", &"regen") != null,
		"regen in effects after reload")
	# Same for abilities.
	ContentDBScript._by_id_by_type["abilities"] = {}
	_assert(ContentDBScript.get_by_id_for_type("abilities", &"regen") == null,
		"clearing typed abilities map hides regen")
	ContentDBScript.load_all()
	_assert(ContentDBScript.get_by_id_for_type("abilities", &"regen") != null,
		"regen in abilities after reload")
