extends RefCounted
## B6.4b.1 / Damage Transaction / Commit Transaction Seam
## (LIFECYCLE-HARDENED).
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
## Lifecycle state machine (B6.4b.1):
##   UNINITIALIZED
##       |
##       | setup(valid)
##       v
##   PENDING
##       |
##       | commit(success)
##       v
##   COMMITTED  (terminal)
##
## No backward transitions. No public reset. One object
## represents one transaction lifetime. A new damage
## application must create a new object.
##
## B6.4b.1 contract:
##   - setup(source, target, base_amount) -> bool.
##     Accepts ONLY from STATE_UNINITIALIZED. Rejects
##     STATE_PENDING or STATE_COMMITTED (no resurrection).
##     Rejects negative base_amount (no silent clamp).
##   - set_pending_amount(value) -> bool.
##     Accepts ONLY from STATE_PENDING. Rejects COMMITTED
##     or UNINITIALIZED. Rejects negative.
##   - commit(world) -> {ok, dealt, reason}.
##     Rejects UNINITIALIZED / COMMITTED / no_world / target_dead
##     without mutating world state. On success, mutates
##     world once and transitions to STATE_COMMITTED.
##   - is_committed() derived from state.
##   - base_amount() / pending_amount() return the immutable
##     base and the current pending (may equal base or be
##     replaced via set_pending_amount). 0 is valid; negative
##     is never valid.

const STATE_UNINITIALIZED: int = 0
const STATE_PENDING: int = 1
const STATE_COMMITTED: int = 2

var _state: int = STATE_UNINITIALIZED
var _source: int = -1
var _target: int = -1
var _base: int = 0
var _pending: int = 0


## Initialize the transaction. Accepts ONLY from
## STATE_UNINITIALIZED. Returns true on success, false on
## rejection (without mutating any field).
##
## base_amount must be a non-negative integer. 0 is valid.
## Negative inputs are REJECTED. NO silent clamp to 0.
##
## Target existence/liveness remains commit-time world
## validation. setup does not validate target identity
## beyond the caller's contract.
func setup(p_source: int, p_target: int, p_base_amount: int) -> bool:
	if int(_state) != int(STATE_UNINITIALIZED):
		return false
	if int(p_base_amount) < 0:
		return false
	_source = int(p_source)
	_target = int(p_target)
	_base = int(p_base_amount)
	_pending = int(p_base_amount)
	_state = int(STATE_PENDING)
	return true


## Replace the pending amount. Accepts ONLY from STATE_PENDING
## with a non-negative value. Returns true on accept, false on
## reject (no mutation). 0 is valid. Values > base are valid
## (amplification allowed).
func set_pending_amount(p_value: int) -> bool:
	if int(_state) != int(STATE_PENDING):
		return false
	if int(p_value) < 0:
		return false
	_pending = int(p_value)
	return true


## Whether the transaction has reached STATE_COMMITTED.
func is_committed() -> bool:
	return int(_state) == int(STATE_COMMITTED)


## Original damage amount determined by the existing source
## of truth BEFORE any future damage modifier. Stable for
## the life of the transaction.
func base_amount() -> int:
	return _base


## Starts equal to base_amount. Future pre-damage modifiers
## may change this before commit. In B6.4b.1 no production
## modifier exists; pending equals base in shipping paths.
func pending_amount() -> int:
	return _pending


## Apply the pending damage to the world.
## Returns Dictionary {ok: bool, dealt: int, reason: String}.
##   ok=true, dealt=N: commit succeeded, N HP removed.
##   ok=true, dealt=0: valid commit with pending=0 (target
##                     unchanged but transaction is now
##                     committed; future commits will no-op).
##   ok=false: precondition not met. No HP mutation. The
##             transaction remains in its current non-terminal
##             state (PENDING stays PENDING on target_dead /
##             no_world; UNINITIALIZED stays UNINITIALIZED on
##             not_initialized; COMMITTED stays COMMITTED on
##             already_committed).
func commit(p_world) -> Dictionary:
	if int(_state) == int(STATE_UNINITIALIZED):
		return {"ok": false, "dealt": 0, "reason": "not_initialized"}
	if int(_state) == int(STATE_COMMITTED):
		return {"ok": false, "dealt": 0, "reason": "already_committed"}
	if p_world == null:
		return {"ok": false, "dealt": 0, "reason": "no_world"}
	if not bool(p_world.is_alive(int(_target))):
		return {"ok": false, "dealt": 0, "reason": "target_dead"}
	# All preconditions met. Mutate world exactly once.
	var dealt: int = int(p_world.apply_damage(
		int(_target), int(_pending)))
	_state = int(STATE_COMMITTED)
	return {"ok": true, "dealt": int(dealt), "reason": ""}