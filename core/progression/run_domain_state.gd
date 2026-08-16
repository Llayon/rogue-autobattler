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