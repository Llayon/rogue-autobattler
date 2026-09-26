extends RefCounted
## B6.2b / ReactionDef execution validator.
##
## Pure helper. No world, RNG, emitter, mutation, or ContentDB
## writes. Validates an ACTIVE Phase-3 ReactionDef is safe to
## execute via the canonical PerformAttack pipeline.
##
## In B6.2b the only supported Phase-3 output is
## EffectKind.PERFORM_ATTACK. Other kinds (DAMAGE, HEAL,
## APPLY_STATUS, REMOVE_STATUS, MOVE) are explicitly rejected
## until those pipelines are designed.
##
## B5 provider discovery remains RNG-pure. Therefore an active
## ReactionDef must declare trigger_chance == 1.0. Anything else
## is unsupported and rejected fail-closed (no RNG draws,
## no reinterpretation).

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const ReactionDefScript = preload(
	"res://core/data/reaction_def.gd")


## Returns Dictionary {ok: bool, reason: String}.
## ok=true means the ReactionDef is safe to execute in B6.2b.
## ok=false means rejected (validation failure); reason is a
## human-readable diagnostic, NEVER empty when ok=false.
static func validate_for_execution(p_def: Resource) -> Dictionary:
	if p_def == null:
		return {"ok": false, "reason": "def is null"}
	# event_type must be a currently-valid BattleEventType.
	# Use the script's authoritative all_entries() so we
	# accept exactly what the engine actually defines today.
	var valid_event_types: Array = []
	for entry in BattleEventTypeScript.all_entries():
		valid_event_types.append(int(entry[1]))
	if int(p_def.event_type) == -1:
		return {"ok": false,
			"reason": "event_type is -1 (Phase-3 inert sentinel)"}
	if not valid_event_types.has(int(p_def.event_type)):
		return {"ok": false,
			"reason": "event_type=%d is not a valid BattleEventType"
				% int(p_def.event_type)}
	# effect_kind: only PERFORM_ATTACK is supported in B6.2b.
	if int(p_def.effect_kind) == -1:
		return {"ok": false,
			"reason": "effect_kind is -1 (Phase-3 inert sentinel)"}
	if int(p_def.effect_kind) != int(EffectKindScript.PERFORM_ATTACK):
		return {"ok": false,
			"reason": "effect_kind=%d is not supported in B6.2b (only PERFORM_ATTACK)"
				% int(p_def.effect_kind)}
	# owner_selector must be OWNER_EVENT_SOURCE or OWNER_EVENT_TARGET.
	var valid_owner: Array = [
		int(ReactionDefScript.OWNER_EVENT_SOURCE),
		int(ReactionDefScript.OWNER_EVENT_TARGET),
	]
	if not valid_owner.has(int(p_def.owner_selector)):
		return {"ok": false,
			"reason": "owner_selector=%d is invalid (must be OWNER_EVENT_SOURCE or OWNER_EVENT_TARGET)"
				% int(p_def.owner_selector)}
	# target_selector must be TARGET_EVENT_SOURCE,
	# TARGET_EVENT_TARGET, or TARGET_OWNER.
	var valid_target: Array = [
		int(ReactionDefScript.TARGET_EVENT_SOURCE),
		int(ReactionDefScript.TARGET_EVENT_TARGET),
		int(ReactionDefScript.TARGET_OWNER),
	]
	if not valid_target.has(int(p_def.target_selector)):
		return {"ok": false,
			"reason": "target_selector=%d is invalid (must be TARGET_EVENT_SOURCE, TARGET_EVENT_TARGET, or TARGET_OWNER)"
				% int(p_def.target_selector)}
	# trigger_chance must be exactly 1.0. RNG-based chance is
	# intentionally not supported in B6.2b.
	var chance: float = float(p_def.trigger_chance)
	if chance != 1.0:
		return {"ok": false,
			"reason": "trigger_chance=%s is not supported in B6.2b (must be exactly 1.0)"
				% str(chance)}
	return {"ok": true, "reason": ""}
