extends RefCounted
## Phase 2 + Phase 3 / BattleEventType — enum-like integer
## constants for BattleEvent.type.
##
## Defined as a RefCounted with static const fields so it can be
## used without instantiation. Other classes reference these via
## class_name BattleEventType.
##
## Values are FROZEN. Existing 0..5 are accepted Phase-2 contract.
## Phase-3 additions are 6..8. Do not renumber.

const UNIT_SPAWNED: int = 0
const UNIT_DIED: int = 1
const ATTACK_RESOLVED: int = 2
const DAMAGE_APPLIED: int = 3
const BATTLE_ENDED: int = 4
const UNIT_MOVED: int = 5

# Phase-3 additions. Frozen at 6..8.
const HEAL_APPLIED: int = 6
const STATUS_APPLIED: int = 7
const STATUS_REMOVED: int = 8

# Phase-3 B3 additions. Frozen at 9..10.
# STATUS_TICKED: logical root for one periodic status fire
# (decrement+effect). Carries source_entity (status source),
# target_entity (status owner), tag (status_id), amount (DOT/HOT
# magnitude). Children of this event are DAMAGE_APPLIED /
# HEAL_APPLIED for the actual periodic effect.
const STATUS_TICKED: int = 9
# STATUS_EXPIRED: emitted when a StatusInstance naturally expires
# (remaining reached 0 after decrement). Distinct from
# STATUS_REMOVED, which is explicit removal. Carries
# source_entity (status source), target_entity (status owner),
# tag (status_id), amount = 0.
const STATUS_EXPIRED: int = 10


## Returns a snapshot Array of all (name, value) pairs in
## declaration order. Used by tests to assert uniqueness and
## frozen values.
static func all_entries() -> Array:
	return [
		["UNIT_SPAWNED", UNIT_SPAWNED],
		["UNIT_DIED", UNIT_DIED],
		["ATTACK_RESOLVED", ATTACK_RESOLVED],
		["DAMAGE_APPLIED", DAMAGE_APPLIED],
		["BATTLE_ENDED", BATTLE_ENDED],
		["UNIT_MOVED", UNIT_MOVED],
		["HEAL_APPLIED", HEAL_APPLIED],
		["STATUS_APPLIED", STATUS_APPLIED],
		["STATUS_REMOVED", STATUS_REMOVED],
		["STATUS_TICKED", STATUS_TICKED],
		["STATUS_EXPIRED", STATUS_EXPIRED],
	]
