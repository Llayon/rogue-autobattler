extends SceneTree
## B6.4c — ReactionDefValidator FAIL-CLOSED GUARD FOR
## event_type == DAMAGE_STARTED (12).
##
## B6.4c introduces DAMAGE_STARTED (12) as a PRODUCER-ONLY event
## type. Production content must NOT declare a reaction on it:
## the pre-damage reaction schema is not opened in B6.4c (the
## Shield Block gauntlet will replace the guard with an
## allow-list of supported pre-damage modifier kinds).
##
## The validator is the ONLY thing that enforces this for
## production content, and its guard was previously untested —
## so a regression could have silently opened the pre-damage
## reaction surface to production content.
##
## This suite proves the guard rejects event_type == 12 for
## every construction shape the validator accepts otherwise:
##   - a fully valid def except for the event type;
##   - the same def with a different effect_kind;
##   - the same def with a different owner/target selector;
##   - and it still ACCEPTS the legal ATTACK_RESOLVED def, so
##     the guard is not rejecting everything.

const ReactionDefScript = preload("res://core/data/reaction_def.gd")
const ReactionDefValidatorScript = preload(
	"res://core/battle_ecs/triggers/reaction_def_validator.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_valid_def_is_accepted()
	_test_damage_started_def_is_rejected()
	_test_damage_started_rejected_for_every_shape()
	_test_damage_started_rejection_is_not_a_false_positive()
	print("\n=== B6.4c validator fail-closed guard: %d pass / %d fail ==="
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


func _make_def(p_event_type: int) -> Resource:
	var d = ReactionDefScript.new()
	d.id = &"probe_def"
	d.event_type = p_event_type
	d.effect_kind = EffectKindScript.PERFORM_ATTACK
	d.owner_selector = ReactionDefScript.OWNER_EVENT_TARGET
	d.target_selector = ReactionDefScript.TARGET_EVENT_SOURCE
	d.trigger_chance = 1.0
	return d


func _test_valid_def_is_accepted() -> void:
	print("[VG-1] a legal ATTACK_RESOLVED def is accepted")
	var v: Dictionary = ReactionDefValidatorScript.validate_for_execution(
		_make_def(int(BattleEventTypeScript.ATTACK_RESOLVED)))
	_assert(bool(v.get("ok", false)),
		"the legal def is accepted (reason=%s)"
			% String(v.get("reason", "")))


func _test_damage_started_def_is_rejected() -> void:
	print("[VG-2] a DAMAGE_STARTED def is rejected fail-closed")
	var v: Dictionary = ReactionDefValidatorScript.validate_for_execution(
		_make_def(int(BattleEventTypeScript.DAMAGE_STARTED)))
	_assert(not bool(v.get("ok", true)),
		"the DAMAGE_STARTED def is REJECTED")
	var reason: String = String(v.get("reason", ""))
	_assert(reason != "",
		"the rejection carries a non-empty reason (got '%s')" % reason)
	_assert(reason.find("DAMAGE_STARTED") >= 0,
		"the reason names DAMAGE_STARTED (got '%s')" % reason)


func _test_damage_started_rejected_for_every_shape() -> void:
	print("[VG-3] the rejection holds for every def shape")
	# Different effect_kind.
	var d1 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED))
	d1.effect_kind = EffectKindScript.DAMAGE
	var v1: Dictionary = ReactionDefValidatorScript.validate_for_execution(d1)
	_assert(not bool(v1.get("ok", true)),
		"rejected with effect_kind = DAMAGE")
	# Different owner/target selector.
	var d2 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED))
	d2.owner_selector = ReactionDefScript.OWNER_EVENT_SOURCE
	d2.target_selector = ReactionDefScript.TARGET_EVENT_TARGET
	var v2: Dictionary = ReactionDefValidatorScript.validate_for_execution(d2)
	_assert(not bool(v2.get("ok", true)),
		"rejected with a different owner/target selector")
	# Zero chance (a legal value) must not change the verdict.
	var d3 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED))
	d3.trigger_chance = 0.0
	var v3: Dictionary = ReactionDefValidatorScript.validate_for_execution(d3)
	_assert(not bool(v3.get("ok", true)),
		"rejected with trigger_chance = 0.0")
	# A different id must not change the verdict.
	var d4 = _make_def(int(BattleEventTypeScript.DAMAGE_STARTED))
	d4.id = &"another_probe"
	var v4: Dictionary = ReactionDefValidatorScript.validate_for_execution(d4)
	_assert(not bool(v4.get("ok", true)),
		"rejected with a different def id")


func _test_damage_started_rejection_is_not_a_false_positive() -> void:
	print("[VG-4] the guard is specific, not a blanket rejection")
	# Every OTHER valid event type must still be accepted, so the
	# DAMAGE_STARTED guard cannot be masking a broken validator.
	var legal: Array = [
		int(BattleEventTypeScript.ATTACK_RESOLVED),
		int(BattleEventTypeScript.DAMAGE_APPLIED),
		int(BattleEventTypeScript.UNIT_MOVED),
		int(BattleEventTypeScript.STATUS_TICKED),
		int(BattleEventTypeScript.STATUS_EXPIRED),
	]
	for t in legal:
		var v: Dictionary = ReactionDefValidatorScript.validate_for_execution(
			_make_def(int(t)))
		_assert(bool(v.get("ok", false)),
			"event_type %d is still accepted (reason=%s)"
				% [int(t), String(v.get("reason", ""))])
