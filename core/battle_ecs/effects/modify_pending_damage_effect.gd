class_name ModifyPendingDamageEffect extends RefCounted
##
## Generic pre-damage modifier. Reads req.amount as the new
## pending damage. Operates ONLY when an active damage window
## exists (ctx.damage_window != null). Outside a window: fail
## closed. Negative amounts: fail closed.
##
## No Shield Block semantics. No percentages. No rounding. No
## stacking. Future Shield Block migration will synthesize
## EffectRequests with this kind, governed by future
## ReactionDefValidator allow-list.

const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")

static func execute(ctx, req) -> RefCounted:
	# Fail closed if no active damage window.
	# NOTE: ctx.damage_window is a METHOD, not a property. Reading
	# ctx.damage_window yields a Callable, so it must be CALLED.
	var handle = null
	if ctx != null and ctx.has_method("damage_window"):
		handle = ctx.damage_window()
	if handle == null:
		return EffectResultScript.failed(
			"modify_pending_damage: no active damage window", [], false)

	# Fail closed on negative amount.
	if int(req.amount) < 0:
		return EffectResultScript.failed(
			"modify_pending_damage: negative amount rejected", [], false)

	# Apply.
	var ok: bool = bool(handle.set_pending_amount(int(req.amount)))
	if not ok:
		# Window already closed (race or stale context). Fail
		# closed.
		return EffectResultScript.failed(
			"modify_pending_damage: window not active", [], false)

	# Success: no public events, no chain, no further dispatch.
	return EffectResultScript.succeeded([], false)