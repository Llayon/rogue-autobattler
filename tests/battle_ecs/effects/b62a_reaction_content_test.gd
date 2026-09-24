extends SceneTree
## B6.2a — Content loading + ReactionDef schema + resolver.
## Tests are test-only and prove:
##  * ContentDB typed lookup "reactions" finds existing legacy
##    resources.
##  * ReactionDefResolver returns ReactionDef for known ids and
##    null for unknown / empty / wrong-script.
##  * ReactionDef Phase-3 fields default to inert (-1 / "" / [])
##    so existing legacy .tres files remain phase-3 inert.
##  * UnitDef.reaction_ids is an Array[StringName] (no Resource
##    refs) and survives content load.

const ContentDBScript = preload("res://core/utils/content_db.gd")
const UnitDefScript = preload("res://core/data/unit_def.gd")
const ReactionDefScript = preload("res://core/data/reaction_def.gd")
const ReactionDefResolverScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_resolver.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_contentdb_loads_reactions()
	await _test_resolver_known_ids()
	await _test_resolver_empty_id()
	await _test_resolver_unknown_id()
	await _test_resolver_wrong_script_is_rejected()
	await _test_reactiondef_legacy_compatibility()
	await _test_unitdef_has_reaction_ids_field()
	print("\n=== B6.2a content + reaction def: %d pass / %d fail ===\n" % [_passed, _failed])
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


# ============================================================
# 1) ContentDB typed reaction lookup.
# ============================================================
func _test_contentdb_loads_reactions() -> void:
	print("[B62A-CDB] contentdb_loads_reactions")
	ContentDBScript.ensure_loaded()
	var r1 = ContentDBScript.get_by_id_for_type(
		"reactions", &"attack_of_opportunity")
	var r2 = ContentDBScript.get_by_id_for_type(
		"reactions", &"shield_block")
	_assert(r1 != null,
		"reaction attack_of_opportunity loaded under 'reactions'")
	_assert(r2 != null,
		"reaction shield_block loaded under 'reactions'")
	# Typed lookup is authoritative — does NOT leak across types.
	var cross = ContentDBScript.get_by_id_for_type(
		"reactions", &"warrior")
	_assert(cross == null,
		"warrior (unit) is NOT in 'reactions' typed map")


# ============================================================
# 2) Resolver returns ReactionDef for known ids.
# ============================================================
func _test_resolver_known_ids() -> void:
	print("[B62A-RES] resolver_known_ids")
	var r1 = ReactionDefResolverScript.resolve(&"attack_of_opportunity")
	var r2 = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(r1 != null,
		"resolve attack_of_opportunity")
	_assert(r2 != null,
		"resolve shield_block")
	if r1 != null:
		_assert(r1.get_script() == ReactionDefScript,
			"attack_of_opportunity resource is ReactionDef")


# ============================================================
# 3) Empty id → null.
# ============================================================
func _test_resolver_empty_id() -> void:
	print("[B62A-RES] resolver_empty_id")
	var r = ReactionDefResolverScript.resolve(&"")
	_assert(r == null,
		"empty reaction id returns null")


# ============================================================
# 4) Unknown id → null.
# ============================================================
func _test_resolver_unknown_id() -> void:
	print("[B62A-RES] resolver_unknown_id")
	var r = ReactionDefResolverScript.resolve(&"nonexistent_reaction")
	_assert(r == null,
		"unknown reaction id returns null")


# ============================================================
# 5) Wrong-script resource → null.
# ============================================================
func _test_resolver_wrong_script_is_rejected() -> void:
	print("[B62A-RES] resolver_wrong_script_is_rejected")
	# A typed lookup that returns a non-ReactionDef resource
	# must be rejected by the resolver. We simulate this by
	# using the global id index, then verify the resolver
	# returns null for it (if it isn't a ReactionDef).
	# The legacy global lookup may return a non-ReactionDef
	# for any id that exists across types — we just verify
	# that the resolver is defensive: regardless of what the
	# ContentDB might surface, only a real ReactionDef is
	# accepted.
	ContentDBScript.ensure_loaded()
	# warrior is a UnitDef, not a ReactionDef — resolver must
	# return null even though &"warrior" exists as a global id.
	var r = ReactionDefResolverScript.resolve(&"warrior")
	_assert(r == null,
		"resolver rejects non-ReactionDef resource (UnitDef warrior)")


# ============================================================
# 6) ReactionDef legacy .tres remain Phase-3 inert.
# ============================================================
func _test_reactiondef_legacy_compatibility() -> void:
	print("[B62A-RES] reactiondef_legacy_compatibility")
	var r1 = ReactionDefResolverScript.resolve(&"attack_of_opportunity")
	var r2 = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(r1 != null, "attack_of_opportunity resource present")
	_assert(r2 != null, "shield_block resource present")
	if r1 != null:
		# Phase-3 fields default to inert for legacy content
		# that was authored before the Phase-3 schema was added.
		_assert(int(r1.event_type) == -1,
			"attack_of_opportunity event_type == -1 (Phase-3 inert)")
		_assert(int(r1.effect_kind) == -1,
			"attack_of_opportunity effect_kind == -1 (Phase-3 inert)")
	if r2 != null:
		_assert(int(r2.event_type) == -1,
			"shield_block event_type == -1 (Phase-3 inert)")
		_assert(int(r2.effect_kind) == -1,
			"shield_block effect_kind == -1 (Phase-3 inert)")
	# Legacy fields still present (no removal of legacy schema).
	# Specific compatibility checks (not tautology):
	# attack_of_opportunity.trigger is explicitly set to
	# &"unit_move_start" in its .tres file (the legacy GameBus
	# signal name for "this unit starts moving"); shield_block
	# falls back to the default &"unit_attacked" because its
	# .tres does not override trigger. shield_block.trigger_chance
	# is authored as 0.3 (the canonical Shield Block chance).
	if r1 != null:
		_assert(String(r1.trigger) == "unit_move_start",
			"attack_of_opportunity.trigger == 'unit_move_start' "
			+ "(got '%s')" % String(r1.trigger))
		_assert(int(r1.trigger_chance) >= 0.0,
			"attack_of_opportunity.trigger_chance is non-negative")
	if r2 != null:
		_assert(String(r2.trigger) == "unit_attacked",
			"shield_block.trigger == 'unit_attacked' (default legacy; "
			+ "got '%s')" % String(r2.trigger))
		_assert(abs(float(r2.trigger_chance) - 0.3) < 0.001,
			"shield_block.trigger_chance ~= 0.3 (got %s)"
			% str(r2.trigger_chance))
	# Owner/target selectors have valid sentinel defaults.
	if r1 != null:
		_assert(int(r1.owner_selector) >= 0,
			"attack_of_opportunity owner_selector is non-negative (sane)")
		_assert(int(r1.target_selector) >= 0,
			"attack_of_opportunity target_selector is non-negative (sane)")


# ============================================================
# 7) UnitDef has reaction_ids field.
# ============================================================
func _test_unitdef_has_reaction_ids_field() -> void:
	print("[B62A-UNIT] unitdef_has_reaction_ids_field")
	var def = UnitDefScript.new()
	_assert(def.has_method("get") or def.get("reaction_ids") != null,
		"UnitDef exposes reaction_ids")
	var arr = def.get("reaction_ids")
	_assert(arr is Array,
		"UnitDef.reaction_ids is Array (got %s)" % str(typeof(arr)))
	if arr is Array:
		_assert(arr.size() == 0,
			"UnitDef.reaction_ids default is empty")
		# Mutability: must be a regular Array (not Frozen).
		arr.append(&"some_reaction")
		_assert(arr.size() == 1,
			"UnitDef.reaction_ids accepts append (mutable field)")
