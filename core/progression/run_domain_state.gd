class_name RunDomainState extends RefCounted
## Canonical live state for a single run (player progression from
## start to death). This is NOT a serialisable Resource on purpose:
## the live domain object lives in memory; persistence goes through
## RunStateV4Mapper -> Save Schema v4 -> RunSaveRepository in a
## later task. The legacy `RunState` (core/progression/run_state.gd)
## is frozen and remains the on-disk wire-format that the legacy v1
## migrator reads.
##
## Phase 1 / T1: dumb data container only. No gameplay orchestration,
## no save serialisation, no ContentDB lookups. Allocation helpers,
## save mapping, queries, RNG wiring live in later tasks.

## Run seed (also used as the slot identifier by the save layer).
## 0 is the placeholder before start_run().
var seed: int = 0

## Run progression scalars.
var round_index: int = 1
var gold: int = 10
var xp: int = 0
var level: int = 1
## Lives left before the run ends. Default 1 (standard roguelike).
var lives: int = 1

## Entity collections. The ONLY mutable collections that hold
## entity references in the live domain. Board/bench/equipment
## positions are derived from `RunUnit.location + order` and
## `RunItem.owner_unit_id`; no separate parallel arrays.
var units: Array[RunUnit] = []
var items: Array[RunItem] = []

## Sequence counters. Per Phase 1 contract, counters start at 1
## and represent the FIRST UNUSED sequence (max_used + 1). The
## identity allocator (T2) reads/writes these; nothing else does.
var next_unit_instance_seq: int = 1
var next_item_instance_seq: int = 1

## Allocates the next free unit instance id and advances the
## counter. ID is `"unit_%06d" % counter"` with minimum width 6, no
## maximum. IDs are unique within a single run, never derived from
## board position, definition id, hash, time or RNG. The allocator
## is monotonic and never reuses or wraps a consumed id.
##
## After 999999 the format still produces a unique id (e.g.
## `"unit_1000000"`); overflow is not the allocator's concern — the
## v4 mapper/validator owns the canonical invariant
## `next_*_seq == first unused`.
func allocate_unit_instance_id() -> String:
	var id: String = "unit_%06d" % next_unit_instance_seq
	next_unit_instance_seq += 1
	return id


## Allocates the next free item instance id and advances the
## counter. Mirrors `allocate_unit_instance_id`. Unit and item
## counters are independent streams.
func allocate_item_instance_id() -> String:
	var id: String = "item_%06d" % next_item_instance_seq
	next_item_instance_seq += 1
	return id


## Creates a new `RunUnit` from a definition, appends it to
## `units` and returns it. The instance id is minted by
## `allocate_unit_instance_id`. The unit's `order` is the current
## count at `location`, so `create_unit` is naturally an append.
##
## `max_hp` is required from the caller; the domain does NOT look
## up `definition_id` in ContentDB. Controller code resolves
## `max_hp` from `UnitDef` and passes it in.
##
## `current_hp = -1` is the canonical sentinel meaning "use
## max_hp" (see `RunUnit.is_alive`). It is set here so the new
## unit is alive by default.
func create_unit(definition_id: StringName, max_hp: int,
		location: int) -> RunUnit:
	if location != RunUnit.LOCATION_BOARD \
			and location != RunUnit.LOCATION_BENCH:
		# Invalid location is rejected without mutating state.
		# Callers must pass one of the two constants; the domain
		# never invents a third location.
		return null
	var unit: RunUnit = RunUnit.new()
	unit.instance_id = allocate_unit_instance_id()
	unit.definition_id = definition_id
	unit.max_hp = max_hp
	unit.current_hp = -1
	unit.dead = false
	unit.location = location
	unit.order = _count_units_at(location)
	units.append(unit)
	return unit


## Looks up a unit by its instance id. Returns `null` if the id is
## unknown. This is the only legal way to fetch a unit; identity is
## always the instance id, never a definition id or array index.
func get_unit(instance_id: String) -> RunUnit:
	if instance_id == "":
		return null
	for u in units:
		if u.instance_id == instance_id:
			return u
	return null


## Returns all board units sorted by `order` ascending. The
## underlying `units` array is not assumed to be in board order;
## the projection is recomputed here.
func get_board_units() -> Array[RunUnit]:
	return _units_at_location_sorted(RunUnit.LOCATION_BOARD)


## Returns all bench units sorted by `order` ascending.
func get_bench_units() -> Array[RunUnit]:
	return _units_at_location_sorted(RunUnit.LOCATION_BENCH)


## Creates a new `RunItem` with a fresh instance id and appends it
## to `items`. Ownership defaults to `""` (inventory). Returns the
## new item so the caller can attach it to a `RunUnit` afterwards.
##
## The domain does NOT look up `definition_id` in ContentDB. The
## caller is responsible for setting `item.owner_unit_id` and
## the corresponding `unit.equipped_item_ids` entry.
func create_item(definition_id: StringName) -> RunItem:
	var item: RunItem = RunItem.new()
	item.instance_id = allocate_item_instance_id()
	item.definition_id = definition_id
	item.owner_unit_id = ""
	items.append(item)
	return item


## Looks up an item by its instance id. Returns `null` if the id is
## unknown.
func get_item(instance_id: String) -> RunItem:
	if instance_id == "":
		return null
	for it in items:
		if it.instance_id == instance_id:
			return it
	return null


## Returns all items whose `owner_unit_id == ""` — the inventory.
## Order is `items[]` insertion order. No implicit reordering.
func get_inventory_items() -> Array[RunItem]:
	var out: Array[RunItem] = [] as Array[RunItem]
	for it in items:
		if String(it.owner_unit_id) == "":
			out.append(it)
	return out


## Returns all items currently equipped to a specific unit,
## ordered by `items[]` insertion order. Returns an empty list if
## the unit is unknown — this method never returns null.
func get_equipped_items(unit_instance_id: String) -> Array[RunItem]:
	var out: Array[RunItem] = [] as Array[RunItem]
	if unit_instance_id == "":
		return out
	for it in items:
		if String(it.owner_unit_id) == unit_instance_id:
			out.append(it)
	return out


## Equips an item to a unit. The canonical invariant
## `item.owner_unit_id == unit.instance_id` and
## `item.instance_id in unit.equipped_item_ids` is maintained in a
## single mutation: when the item is already equipped to a
## DIFFERENT unit, the link is moved atomically (the old owner's
## `equipped_item_ids` is updated AND the new owner's
## `equipped_item_ids` is updated AND `item.owner_unit_id` is
## rewritten in the same call). No intermediate externally-visible
## inconsistent state.
##
## Equip is only legal onto a BOARD unit. Equip onto a BENCH unit
## is rejected without mutating state. Equip of an unknown item
## or onto an unknown unit is rejected without mutating state.
## Returns `true` on success, `false` otherwise (state untouched
## on failure).
func equip_item(item_instance_id: String,
		unit_instance_id: String) -> bool:
	var it: RunItem = get_item(item_instance_id)
	if it == null:
		return false
	var u: RunUnit = get_unit(unit_instance_id)
	if u == null:
		return false
	if int(u.location) != int(RunUnit.LOCATION_BOARD):
		# Phase 1 keeps the legacy gameplay rule: equipping is
		# board-only. A unit on the bench cannot accept new items
		# here. (Existing equipment on a unit is preserved when
		# the unit moves to the bench — see move_unit()'s
		# contract below.)
		return false
	var old_owner_id: String = String(it.owner_unit_id)
	if old_owner_id == unit_instance_id:
		# Already equipped to this unit. Treat as success but do
		# not duplicate the entry.
		if not u.equipped_item_ids.has(item_instance_id):
			u.equipped_item_ids.append(item_instance_id)
		return true
	# Remove from the previous owner's equipped list, if any.
	if old_owner_id != "":
		var old_owner: RunUnit = get_unit(old_owner_id)
		if old_owner != null:
			var idx: int = old_owner.equipped_item_ids.find(item_instance_id)
			if idx >= 0:
				old_owner.equipped_item_ids.remove_at(idx)
	# Add to the new owner's equipped list.
	if not u.equipped_item_ids.has(item_instance_id):
		u.equipped_item_ids.append(item_instance_id)
	it.owner_unit_id = unit_instance_id
	return true


## Unequips an item from whatever unit it is currently equipped
## to. The canonical invariant is undone atomically: the item's
## `owner_unit_id` becomes `""` AND the old owner's
## `equipped_item_ids` entry is removed in the same call.
## Returns `true` on success, `false` if the item is unknown or
## already unequipped (state untouched on failure).
func unequip_item(item_instance_id: String) -> bool:
	var it: RunItem = get_item(item_instance_id)
	if it == null:
		return false
	var old_owner_id: String = String(it.owner_unit_id)
	if old_owner_id == "":
		# Already in inventory. Treat as success but make sure
		# no stale equipped list still references the id.
		return _purge_equipped_references(item_instance_id)
	it.owner_unit_id = ""
	_purge_equipped_references(item_instance_id)
	return true


## Removes an item entirely. If the item is equipped, the old
## owner's `equipped_item_ids` entry is removed too in the same
## call. Returns `true` on success, `false` if the item is
## unknown (state untouched on failure).
##
## Sequence counter does NOT decrement. The id is gone forever;
## the allocator's next call continues past it.
func remove_item(item_instance_id: String) -> bool:
	var it: RunItem = get_item(item_instance_id)
	if it == null:
		return false
	var old_owner_id: String = String(it.owner_unit_id)
	if old_owner_id != "":
		var old_owner: RunUnit = get_unit(old_owner_id)
		if old_owner != null:
			var idx: int = old_owner.equipped_item_ids.find(item_instance_id)
			if idx >= 0:
				old_owner.equipped_item_ids.remove_at(idx)
	# Remove the item itself from the items array.
	var pos: int = items.find(it)
	if pos >= 0:
		items.remove_at(pos)
	return true


## Removes every stale reference to `item_instance_id` from
## every unit's `equipped_item_ids`. Called by `unequip_item` and
## `remove_item`. Phase 1 keeps this as defensive cleanup — the
## canonical mapper / validator is responsible for the live
## invariant; this is best-effort cleanup if the on-disk state
## arrived inconsistent.
func _purge_equipped_references(item_instance_id: String) -> bool:
	var any: bool = false
	for u in units:
		var idx: int = u.equipped_item_ids.find(item_instance_id)
		if idx >= 0:
			u.equipped_item_ids.remove_at(idx)
			any = true
	return any


## Moves a unit identified by instance id to a new location, with
## an optional explicit `new_order` slot.
##
## `new_order == -1` means "append at the end of destination"
## (i.e. `count_at(new_location)` at the moment of move). Identity
## is preserved; only `location` and `order` change. The source
## side is normalised (0..N-1, no holes) and the destination side
## is normalised after the move.
##
## Returns `true` on success, `false` if the instance id is
## unknown or the location is invalid. State is never mutated on
## failure.
func move_unit(instance_id: String, new_location: int,
		new_order: int = -1) -> bool:
	if new_location != RunUnit.LOCATION_BOARD \
			and new_location != RunUnit.LOCATION_BENCH:
		return false
	var u: RunUnit = get_unit(instance_id)
	if u == null:
		return false
	var old_location: int = u.location
	if old_location == new_location and new_order == u.order:
		return true
	u.location = new_location
	if new_order < 0:
		u.order = _count_units_at_excluding(new_location, instance_id)
	else:
		u.order = new_order
	# After changing the destination, every other unit in the
	# destination location with `order >= u.order` must shift up
	# by one to keep contiguous ordering.
	_shift_orders_up_from(new_location, u.order, instance_id)
	# Source side: remove the gap left by the unit.
	_normalise_orders(old_location, instance_id)
	# Destination side: keep contiguous orders even when new_order
	# was an explicit middle insertion.
	_normalise_orders(new_location, "")
	return true


## Swaps two units identified by instance ids. Swap is only legal
## when both units exist and currently share the same location.
## Identity, definition, hp, equipment are unchanged; only `order`
## is exchanged. Returns `false` (without mutating state) on
## unknown id, mixed locations, or same id twice.
func swap_units(first_instance_id: String,
		second_instance_id: String) -> bool:
	if first_instance_id == "" or second_instance_id == "":
		return false
	if first_instance_id == second_instance_id:
		return false
	var a: RunUnit = get_unit(first_instance_id)
	var b: RunUnit = get_unit(second_instance_id)
	if a == null or b == null:
		return false
	if a.location != b.location:
		return false
	var tmp: int = a.order
	a.order = b.order
	b.order = tmp
	return true


## Counts units currently at `location`. Used to assign `order` on
## `create_unit` and to compute append-target on `move_unit`.
func _count_units_at(location: int) -> int:
	var n: int = 0
	for u in units:
		if u.location == location:
			n += 1
	return n


## Counts units at `location`, optionally excluding one instance
## id. Used by `move_unit` to compute the append-target on
## destination after the unit is conceptually already there (so it
## must not be double-counted).
func _count_units_at_excluding(location: int,
		excluded_instance_id: String) -> int:
	var n: int = 0
	for u in units:
		if u.location == location and u.instance_id != excluded_instance_id:
			n += 1
	return n


## Projects `units` to those at `location`, sorted by `order`
## ascending. Returns a fresh `Array[RunUnit]`.
func _units_at_location_sorted(location: int) -> Array[RunUnit]:
	var out: Array[RunUnit] = [] as Array[RunUnit]
	for u in units:
		if u.location == location:
			out.append(u)
	# Insertion sort: collection sizes are small (board is bounded
	# by MAX_BOARD_UNITS, bench similarly), so O(N^2) is fine and
	# keeps the implementation pure GDScript without allocating a
	# callable.
	for i in range(1, out.size()):
		var j: int = i
		while j > 0 and out[j - 1].order > out[j].order:
			var tmp: RunUnit = out[j - 1]
			out[j - 1] = out[j]
			out[j] = tmp
			j -= 1
	return out


## After a structural change, rewrites `order` on every unit at
## `location` to be the dense 0..N-1 sequence. `excluded_instance_id`
## (empty string = no exclusion) skips the unit currently being
## inserted so it keeps its explicit `order`.
func _normalise_orders(location: int,
		excluded_instance_id: String) -> void:
	var sorted: Array[RunUnit] = _units_at_location_sorted(location)
	var next_order: int = 0
	for u in sorted:
		if u.instance_id == excluded_instance_id:
			continue
		u.order = next_order
		next_order += 1


## When `move_unit` inserts at an explicit `new_order`, every other
## unit at the destination with `order >= new_order` must shift up
## by one. The moving unit itself (`excluded_instance_id`) is
## skipped (its order has already been set).
func _shift_orders_up_from(location: int, from_order: int,
		excluded_instance_id: String) -> void:
	for u in units:
		if u.location == location and u.instance_id != excluded_instance_id \
				and u.order >= from_order:
			u.order += 1

## Run stats.
var wins: int = 0
var losses: int = 0
var units_killed: int = 0

## Encounter map tracking.
## -1 means the map has not started yet.
var current_encounter_id: int = -1
var encounter_visited_ids: Array[int] = []

## Run-level flags / meta-progression overlay.
var just_visited_merchant: bool = false
var meta_modifiers: Dictionary = {}


func _init() -> void:
	# Mutable defaults MUST be freshly allocated per instance. If
	# we declared them with `= []` or `= {}` at the class level,
	# Godot would share those defaults between every
	# RunDomainState.new(). The phase 1 acceptance suite includes
	# a "two instances do not share state" check; this constructor
	# is the contract.
	units = [] as Array[RunUnit]
	items = [] as Array[RunItem]
	encounter_visited_ids = [] as Array[int]
	meta_modifiers = {}