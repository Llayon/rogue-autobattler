extends RefCounted
## B6.4b / Damage Transaction / Commit Transaction Seam.
##
## This is a transaction-local value object that decouples
## DAMAGE AMOUNT CALCULATION from WORLD HP MUTATION. It is
## designed to be a stable seam for FUTURE pre-damage
## reactions (B6.4c) without exposing the underlying world
## mutation directly.
##
## It owns NO:
##   Node / scene / UI
##   RunDomain
##   RNG
##   emitter
##   dispatcher
##   global state
##
## Lifecycle:
##   setup(source, target, base_amount) -> void
##   set_pending_amount(value) -> bool  # rejects negative
##   commit(world) -> {ok, dealt, reason}
##   is_committed() -> bool
##   base_amount() -> int
##   pending_amount() -> int
##
## B6.4b contract:
##   - Inert until commit(): no world mutation, no RNG draw,
##     no event emission.
##   - commit() may be called exactly once. Subsequent calls
##     return {ok=false, dealt=0} as a no-op.
##   - commit() applies pending_amount to world.apply_damage
##     which HP-caps the deal. result.dealt = actual HP removed.
##   - If target is dead at commit time, fail-closed:
##     {ok=false, dealt=0}. Transaction remains uncommitted.
##   - Source liveness is NOT required. Status-source damage
##     (DOT, periodic) where the original source may have died
##     still commits successfully.

var _source: int = -1
var _target: int = -1
var _base: int = 0
var _pending: int = 0
var _committed: bool = false


## Initialize the transaction.
## base_amount: signed int but must be >= 0. Negative inputs
## are silently clamped to 0 (this is the construction-time
## default; runtime replacement via set_pending_amount is
## fail-closed and leaves state unchanged on rejection).
func setup(p_source: int, p_target: int, p_base_amount: int) -> void:
	_source = int(p_source)
	_target = int(p_target)
	_base = maxi(0, int(p_base_amount))
	_pending = _base
	_committed = false


## Replace the pending amount. Returns true on accept, false
## on reject. Negative values are rejected and previous pending
## is left unchanged. 0 is accepted.
func set_pending_amount(p_value: int) -> bool:
	if int(p_value) < 0:
		return false
	_pending = int(p_value)
	return true


## Whether commit() has already been called successfully.
func is_committed() -> bool:
	return _committed


## Original damage amount determined by the existing source of
## truth BEFORE any future modifier. Stable for the life of the
## transaction.
func base_amount() -> int:
	return _base


## Starts equal to base_amount. Future pre-damage modifiers
## may change this before commit. In B6.4b no production
## modifier exists yet.
func pending_amount() -> int:
	return _pending


## Apply the pending damage to the world.
## Returns Dictionary {ok: bool, dealt: int, reason: String}.
##   ok=true, dealt=N: commit succeeded, N HP removed.
##   ok=true, dealt=0: valid commit with pending=0 (target
##                     unchanged but transaction is now
##                     committed; future commits will no-op).
##   ok=false: target not alive at commit time, or
##             transaction already committed. No HP mutation.
##             If reason=="already_committed", pending amount
##             is preserved for inspection; otherwise the
##             transaction remains uncommitted.
func commit(p_world) -> Dictionary:
	if _committed:
		return {"ok": false, "dealt": 0, "reason": "already_committed"}
	if p_world == null:
		return {"ok": false, "dealt": 0, "reason": "no_world"}
	if not bool(p_world.is_alive(int(_target))):
		return {"ok": false, "dealt": 0, "reason": "target_dead"}
	# apply_damage HP-caps internally and returns the actual
	# amount of HP removed.
	var dealt: int = int(p_world.apply_damage(int(_target), int(_pending)))
	_committed = true
	return {"ok": true, "dealt": int(dealt), "reason": ""}