# Legacy save schema shape (v1)

Actual current on-disk save format produced by the legacy save path
(`SaveService.save_*` / `SaveSvc.save_resource`). This document is the
input contract for the future `legacy_save_v1_to_v4_migrator.gd`.

## Terminology

- `RunState.SAVE_VERSION = 3` — internal class constant declared on
  `core/progression/run_state.gd`.
- `SaveSvc.SAVE_VERSION = 1` — the value that `SaveSvc.save_resource`
  writes into every saved resource via `res.set("version", SAVE_VERSION)`.
- All persisted `RunState` and `MetaProfile` files therefore carry
  `version = 1` on disk regardless of the internal constant.
- The migrator must read `version = 1` and accept the structural shape
  described below.

## RunState root fields

Captured from `fixtures/version_1/runs/*.tres` produced by
`SaveService.save_run()`:

| Field | Type | Notes |
|---|---|---|
| `version` | `int = 1` | Always overwritten by `SaveSvc`. |
| `seed` | `int` | Unique file name = `run_<seed>.tres`. |
| `round_index` | `int` | Defaults to `1`. |
| `gold` | `int` | Defaults to `10`. |
| `xp` | `int` | Defaults to `0`. |
| `level` | `int` | Defaults to `1`. |
| `lives` | `int` | Defaults to `1`. |
| `player_unit_ids` | `Array[StringName]` | Board order, source order. |
| `bench_unit_ids` | `Array[StringName]` | Bench order, source order. |
| `item_ids` | `Array[StringName]` | Item inventory order. |
| `item_equip_board_idx` | `Array[int]` | Parallel to `item_ids`. `-1` = inventory. `>= 0` = board slot index. |
| `just_visited_merchant` | `bool` | Defaults to `false`. |
| `wins` | `int` | Defaults to `0`. |
| `losses` | `int` | Defaults to `0`. |
| `units_killed` | `int` | Defaults to `0`. |
| `current_encounter_id` | `int` | Defaults to `-1`. |
| `encounter_visited_ids` | `Array[int]` | Encounter map traversal history. |
| `meta_modifiers` | `Dictionary` | Rest/shrine cumulative modifiers. |
| `unit_states` | `Array` (untyped, holds `RunUnitState` as embedded `Object(RefCounted,...)` blocks) | Parallel to `player_unit_ids + bench_unit_ids` ordering. |

`RunState.to_dict()` currently emits all of these; the on-disk file
includes only those that are non-default in the captured fixtures.

## RunUnitState fields

Embedded inside `unit_states` array. Captured from
`fixtures/version_1/runs/board_plus_bench.tres` and others:

| Field | Type | Notes |
|---|---|---|
| `unit_id` | `StringName` | Definition id. **Two different unit instances with the same `unit_id` are not distinguishable from `unit_id` alone**; position in `unit_states` carries identity. |
| `current_hp` | `int` | `-1` sentinel = "use max_hp". |
| `max_hp` | `int` | `-1` sentinel = "not initialized". |
| `bonus_attack` | `int` | From REST/SHRINE service effects. |

`RunUnitState.to_dict()` writes the same four fields; `from_dict()`
restores them. The embedded `Object(RefCounted,...)` form in legacy
`.tres` files is the canonical wire shape and must be round-trippable
through `to_dict()/from_dict()`.

## MetaProfile fields

Captured from `fixtures/version_1/meta.tres`:

| Field | Type | Notes |
|---|---|---|
| `version` | `int = 1` | Overwritten by `SaveSvc`. |
| `unlocked_units` | `Array[StringName]` | Defaults include warrior, archer, goblin. |
| `unlocked_enemies` | `Array[StringName]` | Defaults include goblin. |
| `total_runs` | `int` | |
| `total_wins` | `int` | |
| `best_round` | `int` | |
| `total_units_killed` | `int` | |
| `soul_currency` | `int` | |
| `current_run_seed` | `int` | `0` = no active run. |
| `battle_speed` | `float` | `1.0`, `2.0`, or `4.0`. |
| `show_damage_numbers` | `bool` | Defaults to `true`. |

## Array parallelism assumptions

- `player_unit_ids` and `unit_states` are **not length-equal by
  construction**: `unit_states` covers `player_unit_ids + bench_unit_ids`
  in source order. `RunController` relies on this when applying HP.
  See `board_plus_bench.tres`: `player_unit_ids.size()==2`,
  `bench_unit_ids.size()==2`, `unit_states.size()==4`.
- `item_ids` and `item_equip_board_idx` are equal length and parallel:
  `item_equip_board_idx[i]` describes `item_ids[i]`.

## `item_equip_board_idx` semantics

- `-1` = item is in inventory (not equipped).
- `>= 0` = board slot index into `player_unit_ids`. The value is the
  board **position**, not the unit instance — multiple items can equip
  to the same board slot.
- A stale index (pointing past the board) is not validated by
  `SaveSvc` and would survive migration only if structurally valid.

## Version overwrite behavior

`SaveSvc.save_resource()`:

```gdscript
if "version" in res:
    res.set("version", SAVE_VERSION)
```

Always writes `1`. Internal class constants
(`RunState.SAVE_VERSION = 3`, `MetaProfile.SAVE_VERSION = 1`,
`BattleState.SAVE_VERSION = 1`) are never reached. The legacy
schema does not preserve the intended version. The migrator must
treat every legacy file as `version = 1`.

## Nullable / missing field behavior

- `current_hp = -1` is a sentinel for "use max_hp"; the loaded object
  must keep the sentinel intact.
- `max_hp = -1` is a sentinel for "not initialized".
- `RunUnitState` objects can in principle be missing from the
  `unit_states` array even if a corresponding id exists in
  `player_unit_ids`; this would be a malformed save and is not
  currently produced by the live code.
- An unknown field in the source file is silently dropped on load.

## Unreliable / ambiguous fields

- `RunState.version` — always `1` on disk; the constant `3` is internal.
- `unit_id` collisions in `unit_states` cannot be resolved without
  sequence/position. v4 schema must introduce `instance_id`.
- `item_equip_board_idx` semantics depend on `player_unit_ids`
  ordering being stable. v4 must depend on `RunUnit.instance_id`
  for the same reason.
- `meta_modifiers` is a `Dictionary` — keys/values may change between
  game versions and have no schema history.

## Phase / transition state

The capture script also saved a `meta.tres` representing a "completed
or transition phase" state (multiple wins, current_run_seed set,
battle_speed customized). This is recorded as `meta.tres`. There is
no separate "phase state" save file — `RunController.Phase` is
runtime-only and not persisted. The fixture exercises `MetaProfile`
state, which is the closest persistence equivalent.

## Filesystem layout

- `user://saves/meta.tres` — `MetaProfile` (single file).
- `user://saves/runs/run_<seed>.tres` — one `RunState` per active run.

Naming convention is hard-coded in `SaveSvc.run_path()` and
`SaveSvc.meta_path()`. The fixture directory mirrors this:

```text
tests/legacy_save_fixtures/fixtures/version_1/
├── meta.tres
└── runs/
    ├── active_run_minimal.tres            # seed=9001
    ├── two_identical_definition_ids.tres   # seed=9002
    ├── board_plus_bench.tres              # seed=9003
    ├── items_equipped_and_unequipped.tres # seed=9004
    ├── partial_hp.tres                    # seed=9005
    ├── run_9001.tres                      # production filename copy
    ├── run_9002.tres
    ├── run_9003.tres
    ├── run_9004.tres
    └── run_9005.tres
```

Each fixture is **byte-faithful** to the file produced by
`SaveService.save_*()` against the live Godot `user://` directory at
capture time. The `script_class=` attribute and `[ext_resource]`
anchors are preserved.

## Loading checks

`tests/legacy_save_fixtures/loader_test.gd` loads every fixture via:

1. `SaveSvc.load_resource(path)` (low-level) for the meta fixture
   through a temp filename `meta_legacy_v1_test.tres` inside
   `user://saves/`, then deletes the temp file.
2. `SaveService.load_run(seed)` for each run fixture through the
   production filename `run_<seed>.tres`, then `delete_run(seed)`.
3. Independent low-level `load(path)` parsing check on every fixture.

All 60 assertions pass as of this commit.