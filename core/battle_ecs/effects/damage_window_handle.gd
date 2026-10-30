class_name DamageWindowHandle extends RefCounted
##
## Battle-domain object. One handle per active pre-damage
## window. Carries a reference to the live DamageTransaction.
##
## Passed through EffectContext.damage_window ONLY for effects
## executed during the pre-damage reaction dispatch. Outside a
## window, ctx.damage_window == null and the handle is not
## available.
##
## Owns NO:
##   RNG
##   emitter
##   dispatcher
##   global state
##   Node / scene / UI
##
## Lifecycle:
##   active=true   while the window is open.
##   close()       called on EVERY terminal window outcome
##                 (commit success, target_dead, no_world, etc.).
##   After close:  set_pending_amount(...) returns false even
##                 if the underlying transaction remains PENDING.

var _tx = null
var _active: bool = false


## Initialize the handle around a transaction.
func setup(p_tx) -> void:
	_tx = p_tx
	_active = true


## Returns the immutable base damage. Stable for the life of the
## window.
func base_amount() -> int:
	if _tx == null:
		return 0
	return int(_tx.base_amount())


## Returns the current pending damage (may equal base or be
## replaced by a modifier).
func pending_amount() -> int:
	if _tx == null:
		return 0
	return int(_tx.pending_amount())


## Replace the pending damage. Accepts ONLY while the window is
## active. After close(), returns false. Negative values are
## rejected (the underlying transaction's contract). 0 is valid.
## Values greater than base are valid (amplification).
func set_pending_amount(p_value: int) -> bool:
	if not _active:
		return false
	if _tx == null:
		return false
	return bool(_tx.set_pending_amount(int(p_value)))


## Returns true while the window is open.
func is_active() -> bool:
	return _active


## Close the window. Subsequent set_pending_amount() returns false.
## Idempotent.
func close() -> void:
	_active = false