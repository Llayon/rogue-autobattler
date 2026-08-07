class_name RunUnit extends RefCounted
## Run domain entity with a stable instance identity.
##
## `instance_id` is unique per entity and never derived from a board
## position, bench position or definition id. `definition_id` is the
## class reference (e.g. "warrior"); the same definition can have
## many RunUnit instances on the board.
##
## `equipped_item_ids` lists `RunItem.instance_id` values; ownership
## is mirrored in `RunItem.owner_unit_id`. The two stay in sync
## through the validator and the migrator.

const LOCATION_BOARD: int = 0
const LOCATION_BENCH: int = 1

var instance_id: String = ""
var definition_id: StringName = &""
var current_hp: int = 0
var max_hp: int = 0
## `true` when the unit is removed from the active run (HP=0
## confirmed dead, or sentinel -1 healed-to-zero).
var dead: bool = false
## `LOCATION_BOARD` or `LOCATION_BENCH`. The location is part of the
## v4 DTO so the board/bench split survives migration; in memory the
## location lives on the unit, not on board or bench index.
var location: int = LOCATION_BOARD
## 0-based position within board or bench, in source order.
var order: int = 0
var equipped_item_ids: Array[String] = []


## Returns `true` if the unit is alive in the run (HP > 0 and not
## marked dead). Mirrors the legacy `RunUnitState.is_alive()`.
func is_alive() -> bool:
	if dead:
		return false
	return current_hp > 0
