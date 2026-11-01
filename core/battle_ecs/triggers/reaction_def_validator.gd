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
## Validates that the active Phase-3 ReactionDef satisfies the
## domain for B6.4a chance admission. Other Phase-3 reaction
## validation is unchanged. This validator does NOT consume RNG;
## chance admission is performed later by TriggerDispatcher.
##
## B6.4a chance domain: 0 <= trigger_chance <= 1.
## NaN and +/-INF are rejected fail-closed.
##
## B6.2b/B6.3 contract: provider is RNG-pure and remains so.
## Chance admission is owned by the dispatcher, not the
## provider. The provider copies ReactionDef.trigger_chance
## into TriggerReaction.trigger_chance without consuming RNG.

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const ReactionDefScript = preload(
	"res://core/data/reaction_def.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")


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
	# B6.4d: DAMAGE_STARTED (12) is no longer blanket-prohibited.
	# The pre-damage reaction schema is OPENED, but only for the
	# single allowed pair:
	#   event_type  == DAMAGE_STARTED
	#   effect_kind == MODIFY_PENDING_DAMAGE
	# and only with a valid pre-damage percentage configuration.
	# Every other effect kind on DAMAGE_STARTED stays fail-closed.
	# The pairing is symmetric: MODIFY_PENDING_DAMAGE on any
	# OTHER event type is rejected too.
	var def_is_damage_started: bool = int(p_def.event_type) == 12
	var def_is_modify_pending: bool = int(p_def.effect_kind) == \
		int(EffectKindScript.MODIFY_PENDING_DAMAGE)
	if def_is_modify_pending and not def_is_damage_started:
		return {"ok": false,
			"reason": "effect_kind=MODIFY_PENDING_DAMAGE requires "
				+ "event_type=DAMAGE_STARTED (got %d)"
				% int(p_def.event_type)}
	# effect_kind: PERFORM_ATTACK (B6.2b) and
	# MODIFY_PENDING_DAMAGE (B6.4d) are the supported kinds.
	if int(p_def.effect_kind) == -1:
		return {"ok": false,
			"reason": "effect_kind is -1 (Phase-3 inert sentinel)"}
	if int(p_def.effect_kind) != int(EffectKindScript.PERFORM_ATTACK) \
			and not def_is_modify_pending:
		return {"ok": false,
			"reason": "effect_kind=%d is not supported (only PERFORM_ATTACK and MODIFY_PENDING_DAMAGE)"
				% int(p_def.effect_kind)}
	# B6.4d: on DAMAGE_STARTED the ONLY allowed effect kind is
	# MODIFY_PENDING_DAMAGE. DAMAGE_STARTED + PERFORM_ATTACK (and
	# every other kind) stays fail-closed.
	if def_is_damage_started and not def_is_modify_pending:
		return {"ok": false,
			"reason": "event_type=DAMAGE_STARTED only allows "
				+ "effect_kind=MODIFY_PENDING_DAMAGE (got %d)"
				% int(p_def.effect_kind)}
	# B6.4d: pre-damage percentage configuration domain.
	# The percent must be EXPLICITLY configured (sentinel -1 is
	# "not configured" and is rejected for this pair), within
	# [0, 100]. Amplification above 100 is NOT opened for
	# shipping content in this gauntlet. The minimum must be >= 0.
	if def_is_damage_started:
		var percent: int = int(p_def.pending_damage_percent)
		if percent < 0:
			return {"ok": false,
				"reason": "event_type=DAMAGE_STARTED requires an explicit pending_damage_percent in [0,100] (got %d)" % [percent]}
		if percent > 100:
			return {"ok": false,
				"reason": "pending_damage_percent=%d is outside [0,100]" % [percent]}
		var minimum: int = int(p_def.pending_damage_minimum)
		if minimum < 0:
			return {"ok": false,
				"reason": "pending_damage_minimum=%d is negative"
					% minimum}
		# B6.4d: origin mask domain.
		#
		# The mask must name at least one legal damage origin, and
		# it may only contain legal bits. An empty mask means the
		# reaction would never fire on any origin, which is a
		# content authoring error rather than a valid "applies to
		# everything" (that is expressed by naming all bits).
		var origins: int = int(p_def.pending_damage_origins)
		if origins == 0:
			return {"ok": false,
				"reason": "event_type=DAMAGE_STARTED requires a "
					+ "non-empty pending_damage_origins mask"}
		var legal_bits: int = int(EffectRequestScript.DAMAGE_ORIGIN_ALL_BITS)
		if (origins & ~legal_bits) != 0:
			return {"ok": false,
				"reason": "pending_damage_origins=%d contains unknown origin bits" % [origins]}
	# owner_selector must be OWNER_EVENT_SOURCE,
	# OWNER_EVENT_TARGET, or OWNER_ENEMY_LEAVING_RANGE (B6.3).
	var valid_owner: Array = [
		int(ReactionDefScript.OWNER_EVENT_SOURCE),
		int(ReactionDefScript.OWNER_EVENT_TARGET),
		int(ReactionDefScript.OWNER_ENEMY_LEAVING_RANGE),
	]
	if not valid_owner.has(int(p_def.owner_selector)):
		return {"ok": false,
			"reason": "owner_selector=%d is invalid (must be OWNER_EVENT_SOURCE, OWNER_EVENT_TARGET, or OWNER_ENEMY_LEAVING_RANGE)"
				% int(p_def.owner_selector)}
	# B6.3: spatial owner selector requires range_cells >= 1.
	if int(p_def.owner_selector) == int(
			ReactionDefScript.OWNER_ENEMY_LEAVING_RANGE):
		if int(p_def.range_cells) < 1:
			return {"ok": false,
				"reason": "OWNER_ENEMY_LEAVING_RANGE requires range_cells >= 1 (got %d)"
					% int(p_def.range_cells)}
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
	# B6.4a: trigger_chance must be in [0,1]. NaN and +/-INF
	# rejected fail-closed.
	var chance: float = float(p_def.trigger_chance)
	if is_nan(chance) or is_inf(chance) \
			or chance < 0.0 or chance > 1.0:
		return {"ok": false,
			"reason": "trigger_chance=%s is not in [0,1] (B6.4a)"
				% str(chance)}
	return {"ok": true, "reason": ""}
