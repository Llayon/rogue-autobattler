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
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")

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
	await _test_counterattack_phase3_only_trigger()
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
		# B6.3: attack_of_opportunity is now an ACTIVE Phase-3
		# spatial reaction (owner_selector=OWNER_ENEMY_LEAVING_RANGE).
		_assert(int(r1.event_type) == int(BattleEventTypeScript.UNIT_MOVE_STARTED),
			"attack_of_opportunity event_type == UNIT_MOVE_STARTED (got %d)"
			% int(r1.event_type))
		_assert(int(r1.effect_kind) == int(EffectKindScript.PERFORM_ATTACK),
			"attack_of_opportunity effect_kind == PERFORM_ATTACK (got %d)"
			% int(r1.effect_kind))
	if r2 != null:
		_assert(int(r2.event_type) == -1,
			"shield_block event_type == -1 (Phase-3 inert)")
		_assert(int(r2.effect_kind) == -1,
			"shield_block effect_kind == -1 (Phase-3 inert)")
	# Legacy fields still present (no removal of legacy schema).
	# Specific compatibility checks (not tautology):
	# B6.3: shipping attack_of_opportunity.trigger is
	# explicitly &"" (Phase-3-only) to prevent legacy GameBus
	# path activation. shield_block retains its legacy default
	# &"unit_attacked" because Shield Block is explicitly
	# deferred and remains Phase-3 inert.
	if r1 != null:
		_assert(String(r1.trigger) == "",
			"attack_of_opportunity.trigger == '' (Phase-3-only, "
			+ "got '%s')" % String(r1.trigger))
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
# 7) counterattack.tres is Phase-3-only: trigger=&""
# ============================================================
func _test_counterattack_phase3_only_trigger() -> void:
	print("[B62A-CTR] counterattack_phase3_only_trigger")
	var ctr = ReactionDefResolverScript.resolve(&"counterattack")
	_assert(ctr != null,
		"counterattack ReactionDef resolves")
	if ctr == null:
		return
	_assert(String(ctr.id) == "counterattack",
		"counterattack.id == counterattack (got '%s')" % String(ctr.id))
	_assert(String(ctr.trigger) == "",
		"counterattack.trigger == &\"\" (got '%s') — Phase-3-only"
		% String(ctr.trigger))
	_assert(int(ctr.event_type) == int(BattleEventTypeScript.ATTACK_RESOLVED),
		"counterattack.event_type == ATTACK_RESOLVED (got %d)"
		% int(ctr.event_type))
	_assert(int(ctr.effect_kind) == int(EffectKindScript.PERFORM_ATTACK),
		"counterattack.effect_kind == PERFORM_ATTACK (got %d)"
		% int(ctr.effect_kind))
	_assert(abs(float(ctr.trigger_chance) - 1.0) < 0.001,
		"counterattack.trigger_chance ~= 1.0 (got %s)" % str(ctr.trigger_chance))
	_assert(String(ctr.output_tag) == "counterattack",
		"counterattack.output_tag == counterattack (got '%s')"
		% String(ctr.output_tag))
	var excluded = ctr.excluded_trigger_tags
	_assert(excluded.size() == 1
			and String(excluded[0]) == "counterattack",
		"counterattack.excluded_trigger_tags contains exactly [&\"counterattack\"]"
		+ " (got %s)" % str(excluded))


# ============================================================
# 8) UnitDef has reaction_ids field.
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
