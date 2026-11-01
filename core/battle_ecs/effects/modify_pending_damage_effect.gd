class_name ModifyPendingDamageEffect extends RefCounted
##
## Generic pre-damage modifier. Operates ONLY when an active
## damage window exists (ctx.damage_window != null). Outside a
## window: fail closed. Negative amounts: fail closed.
##
## TWO modes:
##
##   ABSOLUTE (B6.4c contract, unchanged):
##     no percent payload -> req.amount is the new pending damage
##
##   PERCENTAGE (B6.4d):
##     percent payload present -> read handle.pending_amount()
##     NOW, apply floor(current * percent / 100) with the
##     configured minimum floor, write the result back. The
##     immutable base amount is NEVER the source, so the modifier
##     composes correctly with other pre-damage modifiers.
##
## No Shield Block semantics are hardcoded here: the percentage
## and the floor are generic configuration carried on the
## request payload.

const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")

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

	# PERCENTAGE mode: the request carries a percent payload.
	if req != null and req.payload != null:
		var raw_percent = req.payload.get(
			EffectRequestScript.PAYLOAD_PENDING_DAMAGE_PERCENT, null)
		if raw_percent != null:
			return _execute_percentage(handle, req, int(raw_percent))

	# ABSOLUTE mode: req.amount is the new pending damage.
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


## Percentage mode. Reads the CURRENT pending (never the base),
## applies floor(current * percent / 100), and applies the
## minimum floor ONLY when the current pending is positive.
static func _execute_percentage(handle, req, p_percent: int) -> RefCounted:
	if p_percent < 0 or p_percent > 100:
		return EffectResultScript.failed(
			"modify_pending_damage: percent out of domain (%d)"
				% int(p_percent), [], false)
	var minimum: int = 0
	if req.payload != null:
		minimum = int(req.payload.get(
			EffectRequestScript.PAYLOAD_PENDING_DAMAGE_MINIMUM, 0))
	if minimum < 0:
		return EffectResultScript.failed(
			"modify_pending_damage: negative minimum rejected", [], false)
	var current: int = int(handle.pending_amount())
	if current < 0:
		return EffectResultScript.failed(
			"modify_pending_damage: negative pending rejected", [], false)
	# floor(current * percent / 100) — integer division floors
	# for non-negative operands.
	var remaining: int = (int(current) * int(p_percent)) / 100
	# The floor applies ONLY to a positive pending. A pending of
	# 0 stays 0 — it is never resurrected, so Shield Block
	# composes safely with other pre-damage modifiers.
	if int(current) > 0:
		remaining = maxi(int(minimum), int(remaining))
		# B6.4d / MONOTONIC reducer contract.
		#
		# A pre-damage modifier may only REDUCE the pending
		# damage. Without this clamp a configured minimum larger
		# than the current pending would AMPLIFY it (current=1,
		# percent=50, minimum=5 -> 5), which is absurd for a
		# reducer and would let a "protective" reaction make the
		# target take MORE damage.
		remaining = mini(int(current), int(remaining))
	var ok: bool = bool(handle.set_pending_amount(int(remaining)))
	if not ok:
		return EffectResultScript.failed(
			"modify_pending_damage: window not active", [], false)
	return EffectResultScript.succeeded([], false)