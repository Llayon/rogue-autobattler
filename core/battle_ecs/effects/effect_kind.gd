extends RefCounted
## Phase 3 / EffectKind — enum-like integer constants for Effect
## request kinds.
##
## Effects are routed by kind in EffectExecutor.execute().

const DAMAGE: int = 0
const HEAL: int = 1
const APPLY_STATUS: int = 2
const REMOVE_STATUS: int = 3
const MOVE: int = 4
const PERFORM_ATTACK: int = 5

## Phase-3 B6.4c addition. Frozen at 6.
## MODIFY_PENDING_DAMAGE: generic pre-damage modifier effect.
## Operates ONLY inside an active damage window (ctx.damage_window
## != null). Negative amounts are rejected.
##
## B6.4d added a second, generic mode. The mode is selected by
## the request payload:
##   - no percent payload  -> ABSOLUTE: req.amount is the new
##     pending damage (the B6.4c contract, unchanged).
##   - percent payload     -> PERCENTAGE: the CURRENT pending
##     amount is reduced to floor(current * percent / 100). A
##     positive pending is then clamped to at least the
##     configured minimum, and to at most the current pending, so
##     the modifier is MONOTONIC and can never amplify damage.
##     A pending of 0 stays 0.
## There is no Shield Block semantics here: the percentage and
## the minimum are generic configuration carried by the reaction
## definition.
const MODIFY_PENDING_DAMAGE: int = 6
