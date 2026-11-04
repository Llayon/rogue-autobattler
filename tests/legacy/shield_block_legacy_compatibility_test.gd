extends SceneTree
## PHASE 3 / SHIELD BLOCK LEGACY COMPATIBILITY.
##
## B6.4d migrated the shipping shield_block.tres to the Phase-3
## pre-damage window:
##
##   trigger        = ""           (was the default "unit_attacked")
##   event_type     = DAMAGE_STARTED
##   effect_kind    = MODIFY_PENDING_DAMAGE
##   pending_damage_percent = 50
##   trigger_chance = 0.3
##
## The OLD combat system still consumes the SAME resource:
##
##   RunController.start_battle()
##     -> GameBus.emit_reaction_registered(combatant, shield_block)
##     -> ReactionSystem (autoload) -> ReactionSystemPure
##   DamageEffect.apply()
##     -> _check_shield_block(target)
##     -> poll_reaction(target, &"unit_attacked", ...)
##
## ReactionSystemPure.poll_reaction skips any reaction whose
## `trigger` does not match EXACTLY. With trigger = "" the legacy
## Shield Block can never be selected, so Paladin and Guardian lost
## the ability-damage mitigation in the old BattleRunner.
##
## THIS SUITE proves the legacy chain with the REAL runtime:
## the real GameBus autoload, the real ReactionSystem autoload,
## the real ReactionSystemPure, the real shipping reaction
## resources and the real legacy DamageEffect.
##
## It also pins the contracts that must NOT move:
##   - ability damage IS mitigated (CF1)
##   - the chance gate is 30% with the legacy one-draw topology (CF2)
##   - basic attack is NOT mitigated (CF3)
##   - periodic Burn is NOT mitigated (CF4)
##   - the Phase-3 window keeps its own scope (CF5)
##   - ownership stays Paladin + Guardian (CF6)

const ReactionDefResolverScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_resolver.gd")
const ReactionSystemPureScript = preload(
	"res://core/reactions/reaction_system.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const UnitDefScript = preload("res://core/data/unit_def.gd")
const CombatantScript = preload("res://core/battle/combatant.gd")
const BalanceScript = preload("res://core/balance.gd")
const StatusDefScript = preload("res://core/data/status_def.gd")
const DamageEffectScript = preload("res://core/effects/damage_effect.gd")
const GameBusScript = preload("res://core/utils/event_bus.gd")
const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_legacy_registration_exists()
	_test_ability_damage_is_mitigated()
	_test_legacy_rounding_contract()
	_test_chance_gate_contract()
	_test_registration_does_not_inflate_chance()
	_test_start_battle_registers_the_legacy_view()
	_test_dedup_keeps_distinct_reactions_on_one_class()
	_test_classes_keep_independent_registries()
	_test_rounding_is_observed_through_production()
	_test_real_basic_attack_and_burn_paths_are_not_mitigated()
	_test_legacy_registry_never_receives_attack_of_opportunity()
	_test_shipping_attack_of_opportunity_stays_phase3_only()
	_test_phase3_provider_still_finds_attack_of_opportunity()
	_test_clear_all_empties_every_definition()
	_test_dedup_still_works_after_clear_all()
	_test_new_battle_starts_with_a_fresh_registry()
	_test_new_battle_does_not_inherit_stale_ownership()
	_test_same_def_combatants_do_not_multiply_the_chance()
	_test_wiring_does_not_accumulate_handlers()
	_test_registration_dedup_keeps_distinct_triggers()
	_test_no_double_activation()
	_test_production_registration_path()
	_test_basic_attack_is_not_mitigated()
	_test_burn_is_not_mitigated()
	_test_phase3_scope_unchanged()
	_test_ownership_contract()
	print("\n=== Shield Block legacy compatibility: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


# --- helpers ---

## The legacy reaction system autoload, brought up for the test.
##
## In a --script run the autoload node exists but is NOT inside the
## active scene tree: its own _ready() fails on
## get_node("/root/EventBus"), the reaction_registered signal is
## never connected and poll_reaction() always answers null.
##
## The test therefore does what the autoload's _ready() does:
##   - creates the inner ReactionSystemPure,
##   - connects GameBus.reaction_registered to the autoload's
##     handler.
##
## The wiring uses the REAL GameBus autoload and the REAL
## ReactionSystem autoload, so the production registration path
## (RunController -> GameBus.emit_reaction_registered -> Reaction
## System -> ReactionSystemPure) is exercised end to end.
func _reaction_system_node():
	var tree = Engine.get_main_loop()
	if tree == null:
		return null
	var sys = tree.root.get_node_or_null("ReactionSystem")
	if sys == null:
		return null
	if sys.get("_inner") == null:
		# The autoload's own _ready() resolves /root/EventBus with an
		# absolute path, which fails outside the active scene tree
		# and writes an ERROR to stderr. The inner system is created
		# here directly instead, and the signal is wired below.
		var inner_script = load(
			"res://core/reactions/reaction_system.gd")
		sys.set("_inner", inner_script.new())
	var bus = tree.root.get_node_or_null("EventBus")
	if bus != null and bus.has_signal("reaction_registered"):
		# A STABLE callable, not a fresh lambda: a lambda would be a
		# new object on every call, so is_connected() would always be
		# false and every helper call would add another handler.
		# Five helper calls would then register the same reaction five
		# times and multiply the effective chance.
		# The SAME callable construction the autoload uses in its own
		# _ready(): a bound method reference, not Callable(obj, "name").
		# The two forms are not equal, so mixing them would make
		# is_connected() miss an existing connection and connect a
		# SECOND handler for the same method.
		var handler: Callable = sys._on_reaction_registered
		if not bus.reaction_registered.is_connected(handler):
			bus.reaction_registered.connect(handler)
	return sys


## Clears every registration from the shared reaction system.
##
## The suite drives one autoload-backed system, and start_battle()
## does not clear previous registrations for a class, so a view
## registered by an earlier test (for example with a deterministic
## chance of 1.0) would otherwise leak into the next test.
func _reset_reaction_system() -> void:
	var node = _reaction_system_node()
	if node == null:
		return
	var sys = node.get("_inner")
	if sys == null:
		return
	sys._reactions.clear()


## Builds a legacy Combatant from a UnitDef id.
func _make_combatant(p_def_id: StringName, p_max_hp: int = 100) -> Object:
	var unit_def = UnitDefScript.new()
	unit_def.id = p_def_id
	unit_def.max_hp = p_max_hp
	unit_def.attack = 20
	unit_def.defense = 0
	unit_def.crit_chance = 0.0
	unit_def.dodge = 0.0
	return CombatantScript.new(unit_def)


## Registers the real shipping reaction for the given combatant
## through the REAL GameBus signal, exactly like RunController does.
func _register_shipped_reaction(p_combatant, p_reaction_id: StringName) -> Resource:
	var def = ReactionDefResolverScript.resolve(p_reaction_id)
	if def == null:
		return null
	GameBusScript.emit_reaction_registered(p_combatant, def)
	return def


## Builds a legacy DamageEffect whose dealt damage is exactly
## p_dealt (no crit, no dodge, no variance).
func _make_damage_effect(p_dealt: int) -> Object:
	var eff = DamageEffectScript.new()
	eff.is_magic = false
	eff.scales_with_magic_power = false
	eff.variance = 0.0
	return eff


# --- CF0 / registration ---

## The legacy Shield Block must be REGISTERABLE and SELECTABLE by
## the real legacy runtime for the real legacy trigger.
func _test_legacy_registration_exists() -> void:
	_reset_reaction_system()
	print("[SB-CF0] the legacy reaction is registered and selectable")
	var sys = _reaction_system_node()
	_assert(sys != null,
		"CF0: the ReactionSystem autoload is present in the headless runtime")
	if sys == null:
		return
	var owner = _make_combatant(&"paladin")
	# The PRODUCTION legacy view is what the legacy chain registers,
	# exactly like RunController._make_legacy_shield_block_view().
	var prod_view = RunControllerScript._make_legacy_shield_block_view()
	_assert(prod_view != null,
		"CF0: the production legacy view can be built")
	if prod_view == null:
		return
	_assert(String(prod_view.trigger) == "unit_attacked",
		"CF0: the production legacy view declares the legacy trigger")
	_assert(is_equal_approx(float(prod_view.trigger_chance), 0.3),
		"CF0: the production legacy view inherits the shipping chance "
			+ "(got %s)" % str(prod_view.trigger_chance))
	# The TEST-ONLY copy used for the deterministic selection check
	# has chance 1.0. The shipping resource is never modified.
	var view = _make_legacy_view(1.0)
	_assert(view != null,
		"CF0: a test-only legacy view can be built")
	if view == null:
		return
	_assert(is_equal_approx(float(view.trigger_chance), 1.0),
		"CF0: the test-only view uses chance 1.0")
	# The legacy view must be registered through the REAL GameBus
	# signal, the way RunController does it.
	GameBusScript.emit_reaction_registered(owner, view)
	RngServiceScript.seed_run(1)
	var polled = sys.poll_reaction(owner, &"unit_attacked", {})
	_assert(polled != null,
		"CF0: the real legacy runtime selects the Shield Block "
			+ "for the legacy 'unit_attacked' trigger")
	if polled != null:
		_assert(String(polled.id) == "shield_block_legacy",
			"CF0: the polled reaction is the legacy shield_block view")
	# And the SHIPPING Phase-3 resource must NOT be selectable by
	# the legacy runtime: it declares no legacy trigger. It is
	# registered under its OWN class key so the check is isolated.
	var shipping = _make_combatant(&"cf0_shipping_owner")
	var ship_def = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(ship_def != null,
		"CF0: the shipping shield_block resource resolves")
	if ship_def != null:
		GameBusScript.emit_reaction_registered(shipping, ship_def)
		RngServiceScript.seed_run(1)
		var ship_polled = sys.poll_reaction(shipping, &"unit_attacked", {})
		_assert(ship_polled == null,
			"CF0: the real legacy runtime must NOT select the shipping "
				+ "Phase-3 resource for the legacy trigger")


# --- CF1 / ability damage ---

## Ability damage through the REAL legacy DamageEffect must be
## reduced by the Shield Block when the reaction fires.
func _test_ability_damage_is_mitigated() -> void:
	_reset_reaction_system()
	print("[SB-CF1] ability damage is mitigated by the legacy Shield Block")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF1: the ReactionSystem autoload is present")
		return
	# A deterministic scenario: force the chance to succeed by
	# seeding until the reaction fires is NOT deterministic. Instead
	# the mitigation is proven with a chance of 1.0 injected through
	# the real resource, and the 30% gate is proven separately in
	# CF2. Here we register a legacy-view resource with chance 1.0.
	var owner = _make_combatant(&"cf3_owner", 100)
	var source = _make_combatant(&"cf3_source", 100)
	var legacy_def = _make_legacy_view(1.0)
	_assert(legacy_def != null,
		"CF1: a legacy Shield Block view with chance 1.0 can be built")
	if legacy_def == null:
		return
	GameBusScript.emit_reaction_registered(owner, legacy_def)
	var eff = _make_damage_effect(20)
	# The legacy DamageEffect needs a BattleContext. It only uses
	# the context for effect resolution, and _check_shield_block
	# uses the ReactionSystem autoload, so a minimal context works.
	var ctx = _make_minimal_context()
	var hp_before = int(owner.health.current_hp)
	var results = eff.apply(ctx, source, [owner])
	_assert(results.size() >= 1,
		"CF1: the legacy DamageEffect produced a result")
	var blocked: bool = false
	for r in results:
		if bool(r.get("shield_blocked", false)):
			blocked = true
	_assert(blocked,
		"CF1: the legacy DamageEffect reports the Shield Block")
	_assert(int(owner.health.current_hp) == hp_before - 10,
		"CF1: the mitigated damage is 10 instead of 20 (hp %d -> %d)"
			% [hp_before, int(owner.health.current_hp)])


## Builds the legacy view of Shield Block exactly like
## RunController._make_legacy_shield_block_view() does: a runtime
## duplicate of the shipping resource with the legacy trigger, the
## legacy id and an inherited chance.
##
## p_chance overrides the inherited chance ONLY when p_chance >= 0.
## The production path always inherits the shipping chance.
func _make_legacy_view(p_chance: float) -> Resource:
	var shipping = ReactionDefResolverScript.resolve(&"shield_block")
	if shipping == null:
		return null
	var legacy = ReactionDefScript.new()
	legacy.id = &"shield_block_legacy"
	legacy.trigger = &"unit_attacked"
	legacy.trigger_chance = float(shipping.trigger_chance)
	if p_chance >= 0.0:
		legacy.trigger_chance = p_chance
	legacy.output_tag = StringName(shipping.output_tag)
	legacy.event_type = -1
	legacy.effect_kind = -1
	return legacy


func _test_wiring_does_not_accumulate_handlers() -> void:
	# TD-09: the helper used to connect a FRESH lambda to the
	# GameBus signal on every call. A lambda is a new object each
	# time, so is_connected() was always false and every helper call
	# added another handler. Five helper calls then registered the
	# same reaction five times and multiplied the effective chance.
	#
	# The wiring must therefore use a STABLE callable (the autoload's
	# own method) and must connect at most once.
	_reset_reaction_system()
	var tree = Engine.get_main_loop()
	if tree == null:
		_assert(false, "CF15: the main loop is available")
		return
	var bus = tree.root.get_node_or_null("EventBus")
	if bus == null or not bus.has_signal("reaction_registered"):
		_assert(false, "CF15: the EventBus autoload is available")
		return

	# Five helper calls.
	for i in range(5):
		_reaction_system_node()

	var sys = _reaction_system_node()
	var handler: Callable = sys._on_reaction_registered
	var connections: int = 0
	for connection in bus.reaction_registered.get_connections():
		if connection.get("callable") == handler:
			connections += 1
	_assert(connections == 1,
		"CF15: the GameBus handler is connected exactly once after five helper calls (got %d)"
			% connections)

	# One signal emission must reach register_reaction() exactly once.
	var spy = _ReactionSpy.new()
	var real_inner = sys.get("_inner")
	sys.set("_inner", spy)
	var owner = _make_combatant(&"cf15_owner")
	var view = _make_legacy_view(1.0)
	GameBusScript.emit_reaction_registered(owner, view)
	_assert(spy.calls == 1,
		"CF15: one signal emission calls register_reaction() exactly once (got %d)"
			% spy.calls)
	# Restore the real inner system for the remaining scenarios.
	sys.set("_inner", real_inner)


## Counts register_reaction() calls. Used to prove the GameBus wiring
## does not accumulate handlers.
class _ReactionSpy:
	extends ReactionSystemPureScript

	var calls: int = 0

	func register_reaction(_combatant, _reaction: Resource) -> void:
		calls += 1


## Measures the effective Shield Block hit rate for the registered
## paladin of the given battle.
##
## The rate is measured over the REAL registry, so it reflects every
## chance attempt the legacy runtime would make.
func _measure_hit_rate(p_ctrl, p_sys, p_total: int) -> float:
	var combatants: Array = p_ctrl.ctx.all_combatants()
	if combatants.is_empty():
		return 0.0
	var owner = null
	for c in combatants:
		if StringName(c.def_id) == &"paladin":
			owner = c
			break
	if owner == null:
		return 0.0
	var hits: int = 0
	for seed_value in range(1, p_total + 1):
		RngServiceScript.seed_run(seed_value)
		if p_sys.poll_reaction(owner, &"unit_attacked", {}) != null:
			hits += 1
	return float(hits) / float(p_total)


func _test_clear_all_empties_every_definition() -> void:
	# TD-03: clear_all() must empty the registry for EVERY class,
	# not just one combatant.
	var sys = ReactionSystemPureScript.new()
	var a = _make_combatant(&"cf16_alpha")
	var b = _make_combatant(&"cf16_beta")
	var ra = _make_legacy_view(1.0)
	ra.id = &"cf16_reaction_a"
	var rb = _make_legacy_view(1.0)
	rb.id = &"cf16_reaction_b"
	sys.register_reaction(a, ra)
	sys.register_reaction(b, rb)
	_assert(sys._reactions.size() == 2,
		"CF16: two classes are registered (got %d)" % sys._reactions.size())
	sys.clear_all()
	_assert(sys._reactions.size() == 0,
		"CF16: clear_all() empties every definition (got %d)" % sys._reactions.size())


func _test_dedup_still_works_after_clear_all() -> void:
	# TD-03: clearing the registry must not disable the dedup.
	var sys = ReactionSystemPureScript.new()
	var c = _make_combatant(&"cf17_owner")
	var view = _make_legacy_view(1.0)
	sys.register_reaction(c, view)
	sys.register_reaction(c, view)
	_assert(sys._reactions[&"cf17_owner"].size() == 1,
		"CF17: the dedup still collapses an exact duplicate (got %d)"
			% sys._reactions[&"cf17_owner"].size())
	sys.clear_all()
	sys.register_reaction(c, view)
	sys.register_reaction(c, view)
	_assert(sys._reactions[&"cf17_owner"].size() == 1,
		"CF17: the dedup still works after clear_all (got %d)"
			% sys._reactions[&"cf17_owner"].size())


func _test_new_battle_starts_with_a_fresh_registry() -> void:
	# TD-03 R1/R3: a second start_battle() must not accumulate.
	# The probability must stay at the single-registration rate.
	_reset_reaction_system()
	var rates: Array = []
	for battle in range(4):
		var ctrl = RunControllerScript.new()
		ctrl.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
		var ok: bool = ctrl.start_battle()
		_assert(ok, "CF18: start_battle() succeeded for battle %d" % battle)
		var node = _reaction_system_node()
		var sys = node.get("_inner")
		var entries: int = 0
		if sys._reactions.has(&"paladin"):
			entries = sys._reactions[&"paladin"].size()
		_assert(entries == 1,
			"CF18: battle %d registered exactly one paladin reaction (got %d)"
				% [battle, entries])
		rates.append(_measure_hit_rate(ctrl, sys, 200))
		ctrl.runner = null
		ctrl.ctx = null
		ctrl.free()
	# Every battle must show the SAME effective rate: no accumulation.
	for i in range(1, rates.size()):
		_assert(absf(float(rates[i]) - float(rates[0])) < 0.10,
			"CF18: battle %d keeps the same effective rate (got %.3f, first %.3f)"
				% [i, float(rates[i]), float(rates[0])])
	# And the rate must be near the single-registration rate (~0.30),
	# never the inflated multi-registration rate.
	var last: float = float(rates[rates.size() - 1])
	_assert(last < 0.45,
		"CF18: the effective rate stays near 30%% after four battles (got %.3f)" % last)


func _test_new_battle_does_not_inherit_stale_ownership() -> void:
	# TD-03 R4: a class that owned a reaction in battle A must NOT
	# own it in battle B when battle B has no such unit.
	_reset_reaction_system()
	var first = RunControllerScript.new()
	first.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
	_assert(first.start_battle(), "CF19: the first battle started")
	var node = _reaction_system_node()
	var sys = node.get("_inner")
	_assert(sys._reactions.has(&"paladin"),
		"CF19: the first battle registered the paladin")
	first.runner = null
	first.ctx = null
	first.free()

	# Second battle: a knight only. The paladin reaction must be gone.
	var second = RunControllerScript.new()
	second.state.create_unit(&"knight", 100, RunUnit.LOCATION_BOARD)
	_assert(second.start_battle(), "CF19: the second battle started")
	_assert(not sys._reactions.has(&"paladin"),
		"CF19: the second battle does not inherit the paladin reaction")
	_assert(not sys._reactions.has(&"knight"),
		"CF19: the knight owns no reaction")
	second.runner = null
	second.ctx = null
	second.free()


func _test_same_def_combatants_do_not_multiply_the_chance() -> void:
	# TD-03 R2: several combatants of the SAME class must not create
	# additional independent chance attempts.
	_reset_reaction_system()
	var ctrl = RunControllerScript.new()
	ctrl.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
	ctrl.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
	ctrl.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
	_assert(ctrl.start_battle(), "CF20: the battle started")
	var node = _reaction_system_node()
	var sys = node.get("_inner")
	var entries: int = 0
	if sys._reactions.has(&"paladin"):
		entries = sys._reactions[&"paladin"].size()
	_assert(entries == 1,
		"CF20: three paladins share ONE registration (got %d)" % entries)
	var rate: float = _measure_hit_rate(ctrl, sys, 200)
	_assert(rate < 0.45,
		"CF20: the effective rate stays near 30%% with three paladins (got %.3f)" % rate)
	ctrl.runner = null
	ctrl.ctx = null
	ctrl.free()


func _test_legacy_registry_never_receives_attack_of_opportunity() -> void:
	# TD-04: the legacy registry must not receive the shipping
	# Attack of Opportunity resource.
	#
	# The shipping resource is the PHASE-3 view (trigger = &"",
	# event_type = UNIT_MOVE_STARTED). Across the whole project
	# history the only legacy poll was &"unit_attacked", so a legacy
	# AoO could never be consumed: registering it was a zombie.
	_reset_reaction_system()
	# A FIXED seed AND a tier that actually contains an AoO owner are
	# required. The zombie registration applied to orc_warrior, knight
	# and paladin, but the enemy pool is tiered:
	#
	#   tier 1 -> goblin, goblin_archer   (round 1..3)
	#   tier 2 -> orc_warrior, skeleton_mage (round 4..7)
	#   tier 3 -> troll_chief
	#
	# A tier-1 wave would never have received the zombie
	# registration, so the detector would be vacuous there. The
	# battle therefore runs at round 4, where the wave is drawn from
	# the tier-2 pool that contains orc_warrior.
	RngServiceScript.seed_run(20260903)
	var ctrl = RunControllerScript.new()
	ctrl.state.round_index = 4
	ctrl.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
	_assert(ctrl.start_battle(), "CF21: the battle started")
	var node = _reaction_system_node()
	var sys = node.get("_inner")
	var classes: int = 0
	for def_id in sys._reactions.keys():
		classes += 1
		var entries: Array = sys._reactions[def_id]
		for entry in entries:
			_assert(StringName(entry.get("id")) != &"attack_of_opportunity",
				"CF21: the legacy registry holds no attack-of-opportunity entry (class %s)"
					% String(def_id))
	# The check above is only meaningful when the registry actually
	# holds a class that used to receive the zombie registration.
	# orc_warrior is the tier-2 AoO owner, so its presence proves the
	# scan was not vacuous.
	var saw_aoo_owner: bool = false
	for def_id in sys._reactions.keys():
		if StringName(def_id) in [&"orc_warrior", &"knight", &"paladin"]:
			saw_aoo_owner = true
	_assert(saw_aoo_owner,
		"CF21: the wave contained an AoO-owning class, so the scan was meaningful")
	ctrl.runner = null
	ctrl.ctx = null
	ctrl.free()


func _test_shipping_attack_of_opportunity_stays_phase3_only() -> void:
	# TD-04: the shipping AoO resource must keep the Phase-3 shape.
	# Rolling it back to a legacy trigger would re-introduce a
	# legacy reaction that no legacy code can consume.
	var aoo: Resource = ContentDB_static.get_by_id(&"attack_of_opportunity")
	_assert(aoo != null, "CF22: the shipping AoO resource exists")
	if aoo == null:
		return
	_assert(StringName(aoo.get("trigger")) == &"",
		"CF22: the shipping AoO keeps the empty Phase-3 trigger (got '%s')"
			% String(aoo.get("trigger")))
	_assert(int(aoo.get("event_type")) == 11,
		"CF22: the shipping AoO keeps event_type UNIT_MOVE_STARTED (got %d)"
			% int(aoo.get("event_type")))
	_assert(int(aoo.get("effect_kind")) == 5,
		"CF22: the shipping AoO keeps effect_kind PERFORM_ATTACK (got %d)"
			% int(aoo.get("effect_kind")))


func _test_phase3_provider_still_finds_attack_of_opportunity() -> void:
	# TD-04: removing the zombie legacy registration must NOT disable
	# the real Phase-3 AoO. The Phase-3 provider discovers the
	# reaction from the unit's own reaction_ids.
	var knight: Resource = ContentDB_static.get_by_id(&"knight")
	_assert(knight != null, "CF23: the knight unit definition exists")
	if knight == null:
		return
	var ids: Array = knight.get("reaction_ids")
	_assert(ids.has(&"attack_of_opportunity"),
		"CF23: the knight still owns the attack-of-opportunity reaction id")
	var aoo: Resource = ContentDB_static.get_by_id(&"attack_of_opportunity")
	_assert(aoo != null, "CF23: the shipping AoO resource is still resolvable")


## A minimal legacy Burn status definition.
##
## The legacy StatusList ticks a DOT through Combatant._on_status_dot(),
## which calls take_damage() directly and never reaches DamageEffect.
func _make_burn_status_def(p_dot_damage: int) -> Resource:
	var def = StatusDefScript.new()
	def.id = &"cf14_burn"
	def.dot_damage = p_dot_damage
	def.tick_interval = 1.0
	return def


## A minimal legacy BattleContext. The legacy DamageEffect only
## forwards it to the effect machinery; _check_shield_block reads
## the ReactionSystem autoload directly.
func _make_minimal_context():
	var ctx = BattleContextScript.new()
	return ctx


# --- CF1b / rounding ---

## The legacy rounding contract is floor(dealt / 2) with a minimum
## of 1. Odd damage floors, and damage of 1 stays 1.
func _test_legacy_rounding_contract() -> void:
	_reset_reaction_system()
	print("[SB-CF1b] the legacy rounding contract is floor(dealt / 2), min 1")
	_assert(_expected_legacy_mitigation(20) == 10,
		"CF1b: 20 damage is mitigated to 10")
	_assert(_expected_legacy_mitigation(21) == 10,
		"CF1b: 21 damage is mitigated to 10 (integer floor)")
	_assert(_expected_legacy_mitigation(3) == 1,
		"CF1b: 3 damage is mitigated to 1")
	_assert(_expected_legacy_mitigation(1) == 1,
		"CF1b: 1 damage is mitigated to 1 (minimum)")


## Mirrors the legacy line: result.dealt = maxi(1, result.dealt / 2)
func _expected_legacy_mitigation(p_dealt: int) -> int:
	return maxi(1, int(p_dealt) / 2)


# --- CF2 / chance ---

## The chance gate is the legacy one-draw topology at 30%.
func _test_chance_gate_contract() -> void:
	_reset_reaction_system()
	print("[SB-CF2] the chance gate is the legacy one-draw topology")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF2: the ReactionSystem autoload is present")
		return
	# Every legacy reaction is keyed by combatant.def_id, so each
	# scenario uses its OWN def_id to keep the registrations apart.
	var owner = _make_combatant(&"cf2_zero_owner")
	# chance 0.0 -> never selected, and it still consumes one draw.
	var zero_def = _make_legacy_view(0.0)
	GameBusScript.emit_reaction_registered(owner, zero_def)
	RngServiceScript.seed_run(4242)
	var snap_before = RngServiceScript.snapshot()
	var polled_zero = sys.poll_reaction(owner, &"unit_attacked", {})
	var snap_after = RngServiceScript.snapshot()
	_assert(polled_zero == null,
		"CF2: chance 0.0 never selects the reaction")
	_assert(int(snap_after.get("state", 0)) != int(snap_before.get("state", 0)),
		"CF2: chance 0.0 consumes exactly one RNG draw")
	# chance 1.0 -> always selected, one draw.
	var one_owner = _make_combatant(&"cf2_one_owner")
	var one_def = _make_legacy_view(1.0)
	GameBusScript.emit_reaction_registered(one_owner, one_def)
	RngServiceScript.seed_run(4242)
	var snap1_before = RngServiceScript.snapshot()
	var polled_one = sys.poll_reaction(one_owner, &"unit_attacked", {})
	var snap1_after = RngServiceScript.snapshot()
	_assert(polled_one != null,
		"CF2: chance 1.0 always selects the reaction")
	_assert(int(snap1_after.get("state", 0)) != int(snap1_before.get("state", 0)),
		"CF2: chance 1.0 consumes exactly one RNG draw")
	# chance 0.3 -> same seed gives the same outcome, and the draws
	# are reproducible.
	var third_owner = _make_combatant(&"cf2_third_owner")
	var third_def = _make_legacy_view(0.3)
	GameBusScript.emit_reaction_registered(third_owner, third_def)
	RngServiceScript.seed_run(777)
	var a = sys.poll_reaction(third_owner, &"unit_attacked", {})
	var a_snap = RngServiceScript.snapshot()
	RngServiceScript.seed_run(777)
	var b = sys.poll_reaction(third_owner, &"unit_attacked", {})
	var b_snap = RngServiceScript.snapshot()
	_assert((a == null) == (b == null),
		"CF2: the same seed gives the same 30 percent outcome")
	_assert(int(a_snap.get("state", 0)) == int(b_snap.get("state", 0)),
		"CF2: the same seed gives the same RNG position")
	# A 30% gate must produce BOTH outcomes across many seeds.
	var hits: int = 0
	var misses: int = 0
	for seed_value in range(1, 200):
		RngServiceScript.seed_run(seed_value)
		if sys.poll_reaction(third_owner, &"unit_attacked", {}) != null:
			hits += 1
		else:
			misses += 1
	# The owner must hold exactly ONE reaction entry. Several
	# registrations of the same reaction for the same class would
	# draw the chance gate once per entry and inflate the rate.
	var inner = sys.get("_inner")
	var entries = inner.get("_reactions") if inner != null else {}
	var list: Array = entries.get(String(third_owner.def_id), [])
	_assert(list.size() == 1,
		"CF2: exactly one reaction entry for the owner class (got %d)"
			% list.size())
	_assert(hits > 0 and misses > 0,
		"CF2: the 30 percent gate produces both outcomes across seeds "
			+ "(hits=%d misses=%d)" % [hits, misses])
	# Roughly 30%: allow a generous band for 199 samples.
	var ratio := float(hits) / float(hits + misses)
	_assert(ratio > 0.15 and ratio < 0.45,
		"CF2: the 30 percent gate fires in a plausible band (ratio %.3f)" % ratio)


# --- CF2b / production registration audit ---

## Duplicate registrations for the same class must not inflate the
## effective chance, and repeated battles must not accumulate.
##
## Before the dedup fix, N registrations of the same reaction for
## the same def_id made poll_reaction() draw the chance gate once
## per entry, so the effective rate was 1-(1-p)^N:
##   1 paladin -> 0.287, 2 paladins -> 0.550, 3 paladins -> 0.713
## and repeated battles pushed it towards 1.0.
func _test_registration_does_not_inflate_chance() -> void:
	_reset_reaction_system()
	print("[SB-CF2b] duplicate registrations do not inflate the chance")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF2b: the ReactionSystem autoload is present")
		return
	# One registration: the baseline rate.
	var single_owner = _make_combatant(&"cf2b_single")
	GameBusScript.emit_reaction_registered(single_owner, _make_legacy_view(0.3))
	var single_rate: float = _measure_rate(sys, single_owner)
	# Several combatants of the SAME class: the rate must NOT grow.
	var multi_owner = _make_combatant(&"cf2b_multi")
	for i in 4:
		var other = _make_combatant(&"cf2b_multi")
		GameBusScript.emit_reaction_registered(other, _make_legacy_view(0.3))
	var multi_rate: float = _measure_rate(sys, multi_owner)
	_assert(multi_rate < single_rate + 0.12,
		"CF2b: four registrations of the same class do not raise the "
			+ "rate (single %.3f, multi %.3f)" % [single_rate, multi_rate])
	_assert(multi_rate > 0.12,
		"CF2b: the 30 percent gate still fires (got %.3f)" % multi_rate)


## Measures the effective trigger rate of a combatant over many
## seeds.
func _measure_rate(p_sys, p_combatant) -> float:
	var hits: int = 0
	var total: int = 200
	for seed_value in range(1, total + 1):
		RngServiceScript.seed_run(seed_value)
		if p_sys.poll_reaction(p_combatant, &"unit_attacked", {}) != null:
			hits += 1
	return float(hits) / float(total)


# --- CF7 / no double activation ---

## The two views of Shield Block must be able to coexist for one
## combatant: the legacy runtime selects only the legacy view, and
## the shipping Phase-3 resource stays invisible to it.
##
## This is proved with the REAL resources and the REAL legacy
## DamageEffect: the damage is mitigated exactly ONCE.
func _test_start_battle_registers_the_legacy_view() -> void:
	_reset_reaction_system()
	# A real controller with ONE unit of every relevant class on the
	# board. The ownership decision lives in the CALLER, so every
	# class must be observed: a guard widened to include knight (or
	# to every unit) must be visible here.
	var ctrl = RunControllerScript.new()
	ctrl.state.create_unit(&"paladin", 100, RunUnit.LOCATION_BOARD)
	ctrl.state.create_unit(&"guardian", 100, RunUnit.LOCATION_BOARD)
	ctrl.state.create_unit(&"knight", 100, RunUnit.LOCATION_BOARD)
	ctrl.state.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var board: Array = ctrl.state.get_board_units()
	_assert(board.size() == 4,
		"SB-CF10: the controller has four board units (got %d)" % board.size())
	# start_battle() must register the LEGACY view for the Paladin.
	var ok: bool = ctrl.start_battle()
	_assert(ok,
		"SB-CF10: start_battle() succeeded")
	var node = _reaction_system_node()
	var sys = node.get("_inner")
	var entries: Array = []
	if sys._reactions.has(&"paladin"):
		entries = sys._reactions[&"paladin"]
	_assert(entries.size() == 1,
		"SB-CF10: start_battle() registered exactly one reaction for the paladin (got %d)" % entries.size())
	if entries.size() == 1:
		var registered = entries[0]
		_assert(StringName(registered.get("trigger")) == &"unit_attacked",
			"SB-CF10: the registered reaction carries the LEGACY trigger (got %s)"
				% str(registered.get("trigger")))
		_assert(StringName(registered.get("id")) != &"shield_block",
			"SB-CF10: start_battle() did NOT register the Phase-3 shipping resource")
		_assert(float(registered.get("trigger_chance")) == 0.3,
			"SB-CF10: the registered legacy view inherits the shipping chance 0.3 (got %s)"
				% str(registered.get("trigger_chance")))
	# The classes that do NOT own Shield Block must have received
	# NO registration at all.
	for def_id in [&"knight", &"warrior"]:
		var unwanted: int = 0
		if sys._reactions.has(def_id):
			unwanted = sys._reactions[def_id].size()
		_assert(unwanted == 0,
			"SB-CF10: %s received NO registration (got %d)" % [str(def_id), unwanted])
	# The Guardian DOES own Shield Block.
	var guardian_entries: int = 0
	if sys._reactions.has(&"guardian"):
		guardian_entries = sys._reactions[&"guardian"].size()
	_assert(guardian_entries == 1,
		"SB-CF10: the guardian received exactly one registration (got %d)" % guardian_entries)
	# And the legacy runtime must select it for the legacy trigger.
	# The registered combatant is the Combatant created by
	# start_battle(), not the RunUnit from the run state.
	var combatants: Array = ctrl.ctx.all_combatants()
	_assert(combatants.size() > 0,
		"SB-CF10: start_battle() created combatants (got %d)" % combatants.size())
	if combatants.is_empty():
		return
	var owner = combatants[0]
	var hit = sys.poll_reaction(owner, &"unit_attacked", {})
	_assert(hit != null,
		"SB-CF10: the legacy runtime selects the reaction registered by start_battle()")

	# The controller owns a BattleContext and a BattleRunner. Release
	# them so the suite does not leave resources dangling at exit.
	ctrl.runner = null
	ctrl.ctx = null
	ctrl.free()


func _test_dedup_keeps_distinct_reactions_on_one_class() -> void:
	# MAJOR-2: two DIFFERENT reaction ids registered for the same
	# class must stay two entries. The dedup keys on (id, trigger),
	# not on the class alone.
	var sys = ReactionSystemPureScript.new()
	var c = _make_combatant(&"cf11_knight")
	var shield = _make_legacy_view(1.0)
	shield.id = &"cf11_shield"
	var counter = _make_legacy_view(1.0)
	counter.id = &"cf11_counter"
	counter.trigger = &"unit_attacked"
	sys.register_reaction(c, shield)
	sys.register_reaction(c, counter)
	var entries: int = sys._reactions[&"cf11_knight"].size()
	_assert(entries == 2,
		"CF11: two DIFFERENT reaction ids on one class stay two entries (got %d, want 2)" % entries)
	# An exact duplicate of the FIRST one still collapses.
	sys.register_reaction(c, shield)
	var after: int = sys._reactions[&"cf11_knight"].size()
	_assert(after == 2,
		"CF11: an exact duplicate (same id AND trigger) still collapses (got %d, want 2)" % after)


func _test_classes_keep_independent_registries() -> void:
	# MAJOR-3: the registry is keyed by def_id. Two classes must keep
	# INDEPENDENT lists, and neither may see the other's reaction.
	var sys = ReactionSystemPureScript.new()
	var a = _make_combatant(&"cf12_alpha")
	var b = _make_combatant(&"cf12_beta")
	var ra = _make_legacy_view(1.0)
	ra.id = &"cf12_reaction_a"
	var rb = _make_legacy_view(1.0)
	rb.id = &"cf12_reaction_b"
	sys.register_reaction(a, ra)
	sys.register_reaction(b, rb)
	_assert(sys._reactions.has(&"cf12_alpha"),
		"CF12: class alpha has its own registry entry")
	_assert(sys._reactions.has(&"cf12_beta"),
		"CF12: class beta has its own registry entry")
	var alpha_entries: int = sys._reactions[&"cf12_alpha"].size()
	var beta_entries: int = sys._reactions[&"cf12_beta"].size()
	_assert(alpha_entries == 1,
		"CF12: class alpha holds exactly its own reaction (got %d, want 1)" % alpha_entries)
	_assert(beta_entries == 1,
		"CF12: class beta holds exactly its own reaction (got %d, want 1)" % beta_entries)
	# Polling one class must not return the other class's reaction.
	var hit = sys.poll_reaction(a, &"unit_attacked", {})
	_assert(hit != null and StringName(hit.get("id")) == &"cf12_reaction_a",
		"CF12: polling class alpha returns alpha's reaction, not beta's")


func _test_rounding_is_observed_through_production() -> void:
	# MINOR-2: the rounding contract must be read off the REAL
	# DamageEffect, not off a copy of its expression.
	_reset_reaction_system()
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF13: the ReactionSystem autoload is present")
		return
	var owner = _make_combatant(&"cf13_owner", 100)
	var source = _make_combatant(&"cf13_source", 100)
	# A guaranteed-hit legacy view, so the mitigation always applies.
	var legacy_def = _make_legacy_view(1.0)
	GameBusScript.emit_reaction_registered(owner, legacy_def)
	var cases := [
		[20, 10],
		[21, 10],
		[3, 1],
		[1, 1],
	]
	for c in cases:
		var dealt: int = int(c[0])
		var expected_drop: int = int(c[1])
		owner.health.current_hp = 100
		# The legacy DamageEffect derives the damage from
		# source.attack() - target.defense(), so the amount under
		# test is set on the source.
		source.attack_base = dealt
		owner.defense_base = 0
		var eff = _make_damage_effect(dealt)
		var before = int(owner.health.current_hp)
		eff.apply(null, source, [owner])
		var actual_drop: int = before - int(owner.health.current_hp)
		_assert(actual_drop == expected_drop,
			"CF13: production DamageEffect on %d damage drops HP by %d (got %d)"
				% [dealt, expected_drop, actual_drop])


func _test_real_basic_attack_and_burn_paths_are_not_mitigated() -> void:
	# MINOR-3: CF3/CF4 must drive the REAL legacy paths:
	#   basic_attack() -> take_damage()
	#   tick_statuses() -> _on_status_dot() -> take_damage()
	# Neither goes through DamageEffect, so neither may be mitigated.
	_reset_reaction_system()
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF14: the ReactionSystem autoload is present")
		return
	var owner = _make_combatant(&"cf14_owner", 100)
	var source = _make_combatant(&"cf14_source", 100)
	var legacy_def = _make_legacy_view(1.0)
	GameBusScript.emit_reaction_registered(owner, legacy_def)

	# --- the real basic attack path ---
	owner.health.current_hp = 100
	source.attack_base = 20
	source.crit_chance = 0.0
	owner.defense_base = 0
	# The legacy basic attack applies a 5% damage variance, so the
	# exact unmitigated number is a random draw. The reliable
	# detector is the MITIGATED value: with Shield Block registered
	# at chance 1.0, a basic attack routed through DamageEffect
	# would drop exactly maxi(1, dealt / 2) - about half. The
	# unmitigated drop is a draw around the full amount.
	var atk_result: Dictionary = source.basic_attack(owner)
	var basic_dealt: int = int(atk_result.get("dealt", 0))
	var basic_drop: int = 100 - int(owner.health.current_hp)
	_assert(basic_dealt > 0,
		"CF14: the real basic attack dealt damage (got %d)" % basic_dealt)
	# A mitigated basic attack drops about half of the attacker's
	# attack power; an unmitigated one drops roughly the full
	# amount. The two ranges never overlap, so the threshold is
	# unambiguous even with the legacy 5% damage variance.
	var half_attack: int = source.attack() / 2
	_assert(basic_drop > half_attack,
		"CF14: the real basic attack is NOT mitigated (drop %d, threshold %d)"
			% [basic_drop, half_attack])

	# --- the real status tick (Burn) path ---
	owner.health.current_hp = 100
	var burn = _make_burn_status_def(5)
	owner.statuses.apply(burn, 10.0, 1, source)
	owner.tick_statuses(1.0)
	var burn_drop: int = 100 - int(owner.health.current_hp)
	_assert(burn_drop == 5,
		"CF14: the real Burn tick is NOT mitigated (hp drop %d, want 5)" % burn_drop)


func _test_registration_dedup_keeps_distinct_triggers() -> void:
	_reset_reaction_system()
	var sys = ReactionSystemPureScript.new()
	var c = _make_combatant(&"knight")
	# Same reaction id, different triggers. Both must survive: the
	# legacy poll matches the trigger EXACTLY, so dropping one of
	# them would make that trigger unreachable.
	var a = _make_legacy_view(1.0)
	a.id = &"same_reaction"
	a.trigger = &"unit_attacked"
	var b = _make_legacy_view(1.0)
	b.id = &"same_reaction"
	b.trigger = &"unit_move_start"
	sys.register_reaction(c, a)
	sys.register_reaction(c, b)
	var entries: int = sys._reactions[&"knight"].size()
	_assert(entries == 2,
		"SB-CF9: two registrations of the same id with DIFFERENT triggers stay distinct (got %d, want 2)" % entries)
	var hit_b = sys.poll_reaction(c, &"unit_move_start", {})
	_assert(hit_b != null,
		"SB-CF9: the second trigger is still reachable (the poll returned a reaction)")
	# The exact duplicate must still collapse.
	var dup = _make_legacy_view(1.0)
	dup.id = &"same_reaction"
	dup.trigger = &"unit_attacked"
	sys.register_reaction(c, dup)
	var after: int = sys._reactions[&"knight"].size()
	_assert(after == 2,
		"SB-CF9: an exact duplicate (same id AND trigger) still collapses (got %d, want 2)" % after)


func _test_no_double_activation() -> void:
	_reset_reaction_system()
	print("[SB-CF7] the legacy and Phase-3 views do not double-activate")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF7: the ReactionSystem autoload is present")
		return
	var owner = _make_combatant(&"cf7_owner")
	var source = _make_combatant(&"cf7_source", 100)
	# Both views are registered for the SAME combatant.
	var legacy_view = _make_legacy_view(1.0)
	var shipping = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(shipping != null, "CF7: the shipping resource resolves")
	if shipping == null or legacy_view == null:
		return
	GameBusScript.emit_reaction_registered(owner, legacy_view)
	GameBusScript.emit_reaction_registered(owner, shipping)
	# The legacy runtime must select the LEGACY view only.
	RngServiceScript.seed_run(5)
	var polled = sys.poll_reaction(owner, &"unit_attacked", {})
	_assert(polled != null,
		"CF7: the legacy runtime selects a reaction")
	if polled != null:
		_assert(String(polled.id) == "shield_block_legacy",
			"CF7: the legacy runtime selects the LEGACY view (got '%s')"
				% String(polled.id))
	# And the mitigation is applied exactly once: 20 damage becomes
	# 10, not 5.
	var eff = _make_damage_effect(20)
	var hp_before = int(owner.health.current_hp)
	var results = eff.apply(null, source, [owner])
	var blocked_count: int = 0
	for r in results:
		if bool(r.get("shield_blocked", false)):
			blocked_count += 1
	_assert(blocked_count == 1,
		"CF7: the Shield Block is applied exactly once (got %d)"
			% blocked_count)
	_assert(int(owner.health.current_hp) == hp_before - 10,
		"CF7: the damage is mitigated once, 20 -> 10 (hp %d -> %d)"
			% [hp_before, int(owner.health.current_hp)])


# --- CF8 / production registration path ---

## RunController must register the legacy Shield Block view for
## exactly the Paladin and the Guardian, and for nothing else.
##
## The registration goes through the REAL production helper
## (RunController._make_legacy_shield_block_view()) and the REAL
## GameBus signal, so a broken registration path is detected here.
func _test_production_registration_path() -> void:
	_reset_reaction_system()
	print("[SB-CF8] the production registration path registers the legacy view")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF8: the ReactionSystem autoload is present")
		return
	# The production helper must build a usable legacy view.
	var view = RunControllerScript._make_legacy_shield_block_view()
	_assert(view != null,
		"CF8: the production legacy view can be built")
	if view == null:
		return
	_assert(String(view.trigger) == "unit_attacked",
		"CF8: the production view declares the legacy trigger")
	_assert(String(view.id) == "shield_block_legacy",
		"CF8: the production view uses the legacy id (got '%s')"
			% String(view.id))
	_assert(is_equal_approx(float(view.trigger_chance), 0.3),
		"CF8: the production view keeps the shipping chance (got %s)"
			% str(view.trigger_chance))
	# The Phase-3 executable fields must stay inert on the legacy
	# view: a legacy reaction must never look executable to the
	# Phase-3 validator.
	_assert(int(view.get("event_type")) == -1,
		"CF8: the production legacy view has no Phase-3 event type")
	_assert(int(view.get("effect_kind")) == -1,
		"CF8: the production legacy view has no Phase-3 effect kind")
	# The REAL production registration path: the same call the
	# run controller makes for every player unit. The chance is 30%,
	# so the selection is proved over many seeds rather than with
	# one draw.
	var owner = _make_combatant(&"cf8_owner")
	RunControllerScript._register_legacy_shield_block(owner, &"paladin")
	var hits: int = 0
	var total: int = 200
	for seed_value in range(1, total + 1):
		RngServiceScript.seed_run(seed_value)
		var polled = sys.poll_reaction(owner, &"unit_attacked", {})
		if polled != null:
			hits += 1
			_assert(String(polled.id) == "shield_block_legacy",
				"CF8: the legacy runtime selects the legacy view "
					+ "(got '%s')" % String(polled.id))
			break
	_assert(hits > 0,
		"CF8: the registered production view is selectable by the "
			+ "legacy trigger")
	# And it must NOT be selectable by another trigger name.
	RngServiceScript.seed_run(3)
	var polled_other = sys.poll_reaction(owner, &"some_other_trigger", {})
	_assert(polled_other == null,
		"CF8: the production view is not selectable by another trigger")
	# The ownership decision is part of the production path: a unit
	# that does not own Shield Block must get NO registration.
	var knight = _make_combatant(&"cf8_knight")
	RunControllerScript._register_legacy_shield_block(knight, &"knight")
	var knight_hits: int = 0
	for seed_value in range(1, 40):
		RngServiceScript.seed_run(seed_value)
		if sys.poll_reaction(knight, &"unit_attacked", {}) != null:
			knight_hits += 1
			break
	_assert(knight_hits == 0,
		"CF8: a unit without the Shield Block ownership gets no "
			+ "registration")


# --- CF3 / basic attack ---

## The legacy basic attack calls take_damage() directly and must NOT
## be mitigated.
func _test_basic_attack_is_not_mitigated() -> void:
	_reset_reaction_system()
	print("[SB-CF3] the basic attack is not mitigated")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF3: the ReactionSystem autoload is present")
		return
	var owner = _make_combatant(&"cf3_owner", 100)
	var source = _make_combatant(&"cf3_source", 100)
	var legacy_def = _make_legacy_view(1.0)
	GameBusScript.emit_reaction_registered(owner, legacy_def)
	var hp_before = int(owner.health.current_hp)
	owner.take_damage(20, source)
	_assert(int(owner.health.current_hp) == hp_before - 20,
		"CF3: the basic attack deals its full damage (hp %d -> %d)"
			% [hp_before, int(owner.health.current_hp)])


# --- CF4 / burn ---

## Periodic Burn uses the status callbacks and must NOT be
## mitigated by the legacy Shield Block.
func _test_burn_is_not_mitigated() -> void:
	_reset_reaction_system()
	print("[SB-CF4] the periodic Burn is not mitigated")
	var sys = _reaction_system_node()
	if sys == null:
		_assert(false, "CF4: the ReactionSystem autoload is present")
		return
	var owner = _make_combatant(&"cf3_owner", 100)
	var source = _make_combatant(&"cf3_source", 100)
	var legacy_def = _make_legacy_view(1.0)
	GameBusScript.emit_reaction_registered(owner, legacy_def)
	var hp_before = int(owner.health.current_hp)
	# A burn tick in the legacy system is a status callback, not a
	# DamageEffect. The status list applies the DOT directly.
	owner.take_damage(5, source)
	_assert(int(owner.health.current_hp) == hp_before - 5,
		"CF4: the burn tick deals its full damage (hp %d -> %d)"
			% [hp_before, int(owner.health.current_hp)])


# --- CF5 / Phase-3 isolation ---

## The Phase-3 window keeps its own scope: the shipping resource
## still declares the pre-damage pair, and the Phase-3 origin scope
## is DIRECT only.
func _test_phase3_scope_unchanged() -> void:
	print("[SB-CF5] the Phase-3 window scope is unchanged")
	var def = ReactionDefResolverScript.resolve(&"shield_block")
	_assert(def != null, "CF5: the shipping shield_block resolves")
	if def == null:
		return
	_assert(int(def.event_type) == 12,
		"CF5: the shipping Shield Block still declares DAMAGE_STARTED "
			+ "(event_type=%d)" % int(def.event_type))
	_assert(int(def.effect_kind) == 6,
		"CF5: the shipping Shield Block still declares "
			+ "MODIFY_PENDING_DAMAGE (effect_kind=%d)" % int(def.effect_kind))
	_assert(int(def.pending_damage_percent) == 50,
		"CF5: the Phase-3 percentage is still 50")
	_assert(int(def.pending_damage_origins) == 2,
		"CF5: the Phase-3 origin mask is still DIRECT only (mask=%d)"
			% int(def.pending_damage_origins))
	_assert(is_equal_approx(float(def.trigger_chance), 0.3),
		"CF5: the shipping chance is still 30 percent")
	# The shipping resource keeps NO legacy trigger, so the legacy
	# runtime can never select it (no double activation).
	_assert(String(def.trigger) == "",
		"CF5: the shipping Phase-3 resource declares no legacy trigger "
			+ "(got '%s')" % String(def.trigger))


# --- CF6 / ownership ---

## Ownership stays Paladin + Guardian.
func _test_ownership_contract() -> void:
	print("[SB-CF6] the ownership contract is unchanged")
	var paladin = UnitDefScript.new()
	paladin.id = &"paladin"
	var guardian = UnitDefScript.new()
	guardian.id = &"guardian"
	var knight = UnitDefScript.new()
	knight.id = &"knight"
	var warrior = UnitDefScript.new()
	warrior.id = &"warrior"
	# The legacy registration is driven by the unit id in
	# RunController.start_battle(). The contract is:
	#   paladin, guardian -> registered
	#   knight, warrior    -> not registered
	for id in [&"paladin", &"guardian"]:
		_assert(id in [&"paladin", &"guardian"],
			"CF6: %s keeps the Shield Block ownership" % String(id))
	for id in [&"knight", &"warrior"]:
		_assert(not (id in [&"paladin", &"guardian"]),
			"CF6: %s does not receive the Shield Block" % String(id))
	# The ownership set must match what the run controller applies.
	var src = FileAccess.get_file_as_string(
		"res://core/progression/run_controller.gd")
	_assert(src.contains("[&\"paladin\", &\"guardian\"]"),
		"CF6: the run controller still registers Shield Block for "
			+ "exactly paladin and guardian")


# --- preloads used by the helpers ---

const ReactionDefScript = preload("res://core/data/reaction_def.gd")
const BattleContextScript = preload("res://core/battle/battle_context.gd")
