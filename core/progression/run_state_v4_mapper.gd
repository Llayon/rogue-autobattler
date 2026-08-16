class_name RunStateV4Mapper extends RefCounted
## Pure mapping between `RunDomainState` (the live canonical state)
## and the v4 Save Schema DTO (the on-disk wire format).
##
## Phase 1 / T3B.
##
## This class has NO side effects: no filesystem, no repository,
## no log writes. It only translates between two already-typed
## in-memory shapes. `RunController` will later wrap this behind a
## `SaveService` facade, and that facade will hand the DTO to
## `RunSaveRepository` (T3C).
##
## Identity contract (whole reason this mapper exists):
##   - `RunUnit.instance_id` and `RunItem.instance_id` survive the
##     round-trip verbatim. The DTO is the persistence format; it
##     must not mint or rewrite ids.
##   - `next_unit_instance_seq` / `next_item_instance_seq` survive
##     the round-trip. The mapper does NOT auto-bump them on load.
##   - `equipped_item_ids` on a unit and `owner_unit_id` on an item
##     are both written / both read so equipment link survives
##     round-trip without manual re-wiring.
##   - Board / bench distinction is preserved via `unit.location`
##     and `unit.order`. No board-index projection; the canonical
##     location+order pair is the source of truth.
##
## DTO-level fields that are NOT yet first-class on
## `RunDomainState` (`phase`, `game_build`, `shop`, `map`,
## `rewards`) are filled with canonical defaults here. They will
## migrate to the live domain in later tasks. The mapper does NOT
## silently invent business state for them.

const SaveSchemaV4Script = preload("res://core/save/save_schema_v4.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")
const RunItemScript = preload("res://core/progression/run_item.gd")


## Builds a v4 DTO from a `RunDomainState`. Returns a fresh
## Dictionary; the input state is not mutated.
##
## Each `RunUnit` and `RunItem` is converted via `to_v4_unit_dto`
## and `to_v4_item_dto`. Instance ids are preserved verbatim.
static func to_v4_dto(state: RunDomainState) -> Dictionary:
	var units: Array = []
	for u in state.units:
		units.append(to_v4_unit_dto(u))
	var items: Array = []
	for it in state.items:
		items.append(to_v4_item_dto(it))
	var run_id: String = "run_%d" % state.seed
	return {
		"schema_version": SaveSchemaV4Script.SCHEMA_VERSION,
		"game_build": "",
		"run_id": run_id,
		"seed": state.seed,
		"round_index": state.round_index,
		"phase": "prep",
		"gold": state.gold,
		"units": units,
		"items": items,
		"next_unit_instance_seq": state.next_unit_instance_seq,
		"next_item_instance_seq": state.next_item_instance_seq,
		"shop": {} as Dictionary,
		"map": {} as Dictionary,
		"rewards": {} as Dictionary,
		"wins": state.wins,
		"losses": state.losses,
		"units_killed": state.units_killed,
		"lives": state.lives,
		"xp": state.xp,
		"level": state.level,
		"current_encounter_id": state.current_encounter_id,
		"encounter_visited_ids": state.encounter_visited_ids.duplicate(),
		"meta_modifiers": state.meta_modifiers.duplicate(),
		"just_visited_merchant": state.just_visited_merchant,
	}


## Builds a fresh `RunDomainState` from a v4 DTO. Returns a new
## `RunDomainState`; the DTO is not mutated.
##
## Each DTO unit / item is converted via `from_v4_unit_dto` /
## `from_v4_item_dto`. Instance ids and sequence counters are
## restored from the DTO exactly; the mapper does NOT auto-bump
## them, and does NOT allocate new ones.
static func from_v4_dto(dto: Dictionary):
	var state = RunDomainState.new()
	state.seed = int(dto.get("seed", 0))
	state.round_index = int(dto.get("round_index", 1))
	state.gold = int(dto.get("gold", 0))
	state.xp = int(dto.get("xp", 0))
	state.level = int(dto.get("level", 0))
	state.lives = int(dto.get("lives", 0))
	state.wins = int(dto.get("wins", 0))
	state.losses = int(dto.get("losses", 0))
	state.units_killed = int(dto.get("units_killed", 0))
	state.current_encounter_id = int(dto.get("current_encounter_id", -1))
	state.just_visited_merchant = bool(dto.get("just_visited_merchant", false))
	state.next_unit_instance_seq = int(dto.get("next_unit_instance_seq", 1))
	state.next_item_instance_seq = int(dto.get("next_item_instance_seq", 1))
	var ev: Array = (dto.get("encounter_visited_ids", []) as Array).duplicate()
	var ev_i: Array[int] = [] as Array[int]
	for v in ev:
		ev_i.append(int(v))
	state.encounter_visited_ids = ev_i
	state.meta_modifiers = (dto.get("meta_modifiers", {}) as Dictionary).duplicate()
	var units_value: Variant = dto.get("units", [])
	if units_value is Array:
		for u_dto in units_value:
			if u_dto is Dictionary:
				state.units.append(from_v4_unit_dto(u_dto))
	var items_value: Variant = dto.get("items", [])
	if items_value is Array:
		for it_dto in items_value:
			if it_dto is Dictionary:
				state.items.append(from_v4_item_dto(it_dto))
	return state


## v4 unit DTO. Preserves `instance_id`, `definition_id`,
## `current_hp`, `max_hp`, `bonus_attack` (kept at 0 for now —
## the live domain does not yet track it as a primary field; the
## v4 wire reserves it), `dead`, `location`, `order`,
## `equipped_item_ids` (a fresh Array copy).
static func to_v4_unit_dto(unit: RunUnit) -> Dictionary:
	return {
		"instance_id": String(unit.instance_id),
		"definition_id": StringName(unit.definition_id),
		"current_hp": int(unit.current_hp),
		"max_hp": int(unit.max_hp),
		"bonus_attack": 0,
		"dead": bool(unit.dead),
		"location": int(unit.location),
		"order": int(unit.order),
		"equipped_item_ids": (unit.equipped_item_ids as Array).duplicate(),
	}


## v4 item DTO. Preserves `instance_id`, `definition_id`,
## `owner_unit_id`.
static func to_v4_item_dto(item: RunItem) -> Dictionary:
	return {
		"instance_id": String(item.instance_id),
		"definition_id": StringName(item.definition_id),
		"owner_unit_id": String(item.owner_unit_id),
	}


## Inverse of `to_v4_unit_dto`. Returns a fresh `RunUnit`; the DTO
## is not mutated. The instance id comes from the DTO; the mapper
## does NOT mint a new one.
static func from_v4_unit_dto(d: Dictionary) -> RunUnit:
	var u: RunUnit = RunUnitScript.new()
	u.instance_id = String(d.get("instance_id", ""))
	u.definition_id = StringName(String(d.get("definition_id", "")))
	u.current_hp = int(d.get("current_hp", -1))
	u.max_hp = int(d.get("max_hp", 0))
	u.bonus_attack = int(d.get("bonus_attack", 0))
	u.dead = bool(d.get("dead", false))
	u.location = int(d.get("location", RunUnitScript.LOCATION_BOARD))
	u.order = int(d.get("order", 0))
	var equipped: Variant = d.get("equipped_item_ids", [])
	u.equipped_item_ids = []
	if equipped is Array:
		for eid in equipped:
			u.equipped_item_ids.append(String(eid))
	return u


## Inverse of `to_v4_item_dto`. Returns a fresh `RunItem`.
static func from_v4_item_dto(d: Dictionary) -> RunItem:
	var it: RunItem = RunItemScript.new()
	it.instance_id = String(d.get("instance_id", ""))
	it.definition_id = StringName(String(d.get("definition_id", "")))
	it.owner_unit_id = String(d.get("owner_unit_id", ""))
	return it