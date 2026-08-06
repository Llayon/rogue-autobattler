# Legacy Save v1 → Schema v4 mapping

Source format: legacy on-disk save schema version 1 (see
`docs/LEGACY_SAVE_V1_SHAPE.md`).

Target format: schema v4 (int).

This document is the contract for the future
`legacy_save_v1_to_v4_migrator.gd`. It does not introduce v4 fields
yet; it pins the decisions required before the migrator is written.

## Detection

Source is identified by:

- `RunState.version == 1` AND `unit_states` field present; OR
- `MetaProfile.version == 1` with `current_run_seed` field present.

`RunState.SAVE_VERSION = 3` is irrelevant at the wire level — every
saved file is overwritten to `1` by `SaveSvc.save_resource`.

The migrator **must not** rely on the generic legacy `_migrate()`
hook. Invocation is explicit through the new
`SaveRepository` / `load` pipeline introduced in P1-T2.

## `RunState` mapping

| Legacy field | Target field | Decision |
|---|---|---|
| `version = 1` | `schema_version = 4` | Always emitted by migrator. |
| `seed` | `seed` | Preserved. |
| `player_unit_ids` (board, source order) | `board_units` (in the migrator's **source order**, then each gets a deterministic `instance_id`) | Order is preserved. Each id receives a sequential `instance_id` from `next_unit_instance_seq`. |
| `bench_unit_ids` (bench, source order) | `bench_units` (source order, then `instance_id`) | Same as board. |
| `unit_states` array | `unit_state_records` keyed by `instance_id` | The migrator walks `player_unit_ids + bench_unit_ids` in source order, allocates `instance_id`s, and writes `unit_state_records[instance_id] = legacy_unit_state.to_dict()`. The `instance_id` is the only stable handle; `unit_id` is the definition only. |
| `item_ids` + `item_equip_board_idx` parallel arrays | `item_records` keyed by `instance_id` AND `board_instance_id` map | Each item receives a sequential `instance_id` from `next_item_instance_seq`. `equip` becomes `owner_unit_instance_id` resolved via `board_units[board_index].instance_id`. Items with `equip_board_idx == -1` have `owner_unit_instance_id = ""`. |
| `current_encounter_id` | `current_encounter_id` | Preserved. |
| `encounter_visited_ids` | `encounter_visited_ids` | Preserved. |
| `meta_modifiers` | `meta_modifiers` | Preserved as opaque `Dictionary`; migrator does not migrate inner keys. |
| `gold`, `xp`, `level`, `lives`, `wins`, `losses`, `units_killed`, `just_visited_merchant` | Preserved with same names | Int/bool values, no transformation. |
| `round_index` | `round_index` | Preserved. |

Fields not present in the source but added by v4 are documented in
P1-T2 (not in this commit).

## `RunUnitState` mapping

| Legacy field | Target field | Decision |
|---|---|---|
| `unit_id` | `definition_id` | Definition only; identity comes from `instance_id` allocated by the migrator. |
| `current_hp` (with `-1` sentinel) | `current_hp` | Migrator preserves the sentinel. v4 loader resolves `-1` to `max_hp` after the migration is complete. |
| `max_hp` (with `-1` sentinel) | `max_hp` | Preserved. |
| `bonus_attack` | `bonus_attack` | Preserved. |
| (none) | `instance_id` | Allocated by the migrator as `migrate_unit_id(legacy_index)`. |

## `MetaProfile` mapping

| Legacy field | Target field | Decision |
|---|---|---|
| `version = 1` | `schema_version = 4` | Always emitted. |
| `unlocked_units`, `unlocked_enemies` | `unlocked_units`, `unlocked_enemies` | Preserved. |
| `total_runs`, `total_wins`, `best_round`, `total_units_killed`, `soul_currency`, `battle_speed`, `show_damage_numbers` | Preserved with same names | No transformation. |
| `current_run_seed` | `current_run_seed` | Preserved; v4 active-run pointer is unchanged. |

## Allocation order (canonical)

```text
board_units in source order (player_unit_ids order)
→ bench_units in source order (bench_unit_ids order)
→ items in source order (item_ids order)
```

The migrator persists two monotonic counters alongside the v4
record:

```text
next_unit_instance_seq
next_item_instance_seq
```

These let the next combat / shop / reward allocate additional
`instance_id`s without colliding with migrated ones.

## Collision rules

- A legacy `unit_id` collision (two board entries with the same
  `unit_id`) is **expected** and produces **two distinct
  `instance_id`s**. The migrator must never collapse same-`unit_id`
  entries into one record.
- A legacy `item_id` collision is the same: two distinct
  `instance_id`s.

## Nullability

- `current_hp == -1` (sentinel) is preserved.
- `max_hp == -1` (sentinel) is preserved.
- `item_equip_board_idx[i] == -1` maps to
  `owner_unit_instance_id == ""` (item in inventory).
- `item_equip_board_idx[i] >= 0` is resolved via `board_units[i].instance_id`.

## Ambiguities that remain open

- Whether `meta_modifiers` Dictionary shape changes between
  legacy game versions is unknown. The migrator treats it as opaque.
- Whether a partial `unit_states` array (missing entries relative
  to `player_unit_ids + bench_unit_ids`) can exist in legacy saves
  produced by past sprints. Not observed in current captures; the
  migrator asserts length equality and reports a diagnostic error
  otherwise.
- `current_encounter_id == -1` is treated as "no encounter map
  active" and is preserved verbatim.

## Out of scope for this commit

This document does **not** introduce `RunUnit.instance_id`,
`RunItem.instance_id`, the v4 schema class definitions, the v4
serializer/deserializer, or the production migrator. Those are
deferred to subsequent tasks in Phase 1, each requiring its own
approval.