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
## != null). Reads req.amount as the new pending damage. Negative
## amounts are rejected. No Shield Block semantics, no percentages,
## no rounding policy. Future Shield Block migration uses this
## primitive.
const MODIFY_PENDING_DAMAGE: int = 6
