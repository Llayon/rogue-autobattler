extends RefCounted
## Phase 2 / BattleSimulationType — enum-like integer constants
## for BattleEvent.type.
##
## Defined as a RefCounted with static const fields so it can be
## used without instantiation. Other classes reference these via
## class_name.

const UNIT_SPAWNED: int = 0
const UNIT_DIED: int = 1
const ATTACK_RESOLVED: int = 2
const DAMAGE_APPLIED: int = 3
const BATTLE_ENDED: int = 4
