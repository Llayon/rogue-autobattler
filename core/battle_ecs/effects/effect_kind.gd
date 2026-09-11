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
