# Legacy Save v1 → Schema v4 mapping

Source format: legacy on-disk save schema version 1 (see
`docs/LEGACY_SAVE_V1_SHAPE.md`).

Target format: schema v4 (int).

This document is the source of truth for the
`legacy_save_v1_to_v4_migrator.gd` and the `RunSaveRepository`
wire format. The v4 DTO is an explicit Dictionary; no Godot object
graph is persisted.

## Detection

Source is identified by:

- `RunState` resource with `[gd_resource]` header AND
  `player_unit_ids` AND `unit_states` present AND
  `schema_version` absent; OR
- `MetaProfile` resource.

`RunState.SAVE_VERSION = 3` is irrelevant at the wire level — every
saved file is overwritten to `1` by `SaveSvc.save_resource`.

The migrator **must not** rely on the generic legacy `_migrate()`
hook. Invocation is explicit through the `RunSaveRepository`
pipeline.

## Wire format

```
# v4 save
{schema_version: 4, ...canonical JSON...}
```

The marker `# v4 save` is the first line. The JSON body is produced
with `JSON.stringify(data, "", true)` (key sort). Canonical arrays
(`units`, `items`, `encounter_visited_ids`, `equipped_item_ids`)
keep their semantic order.

## `RunState` → Schema v4 field mapping

| Legacy field | Target field | Decision |
|---|---|---|
| `version = 1` | `schema_version = 4` | Always emitted by migrator. |
| `seed` | `seed` | Preserved. |
| `player_unit_ids` (board, source order) | `units[]` filtered by `location == 0` (board) | Order is preserved. Each definition receives a sequential `instance_id` from `next_unit_instance_seq`. |
| `bench_unit_ids` (bench, source order) | `units[]` filtered by `location == 1` (bench) | Same as board. |
| `unit_states` array | `units[].current_hp`, `units[].max_hp`, `units[].bonus_attack` | The migrator walks `player_unit_ids + bench_unit_ids` in source order, allocates `instance_id`s, and assigns each unit's legacy `unit_state` to the unit at the same index. The `instance_id` is the only stable handle; `unit_id` is the definition only. |
| `unit.location` (0 / 1) | board vs bench | 0 = board, 1 = bench. |
| `unit.order` (0-based) | source-order position within location | 0-based within board or bench. |
| `item_ids` | `items[].definition_id` | Each id is preserved verbatim. |
| `item_equip_board_idx` parallel array | `items[].owner_unit_id` | `equip_board_idx == -1` → `owner_unit_id = ""`. `equip_board_idx == N` → `owner_unit_id = units[board][N].instance_id`. Invalid index → diagnostic `item_equip_board_idx_out_of_range`, item is unequipped. |
| `current_encounter_id` | `current_encounter_id` | Preserved. |
| `encounter_visited_ids` | `encounter_visited_ids` | Preserved. |
| `meta_modifiers` | `meta_modifiers` | Preserved as opaque `Dictionary`; the migrator does not migrate inner keys. |
| `gold`, `xp`, `level`, `lives`, `wins`, `losses`, `units_killed`, `just_visited_merchant` | same names | Int/bool values, no transformation. |
| `round_index` | `round_index` | Preserved. |

## Instance ID rules

`unit_000001`, `unit_000002`, … allocated in board order then bench order.
`item_000001`, `item_000002`, … allocated in `item_ids` source order.
Format: `<prefix>_<6-digit zero-padded>`. No UUID, no time, no random.

`next_unit_instance_seq` and `next_item_instance_seq` are the FIRST
UNUSED sequence after migration (i.e. `max_used + 1`). The v4
validator requires them to be exactly `max_used + 1`.

## `unit_states` matching policy

1. `expected_definitions` = `player_unit_ids` source order, then
   `bench_unit_ids` source order.
2. Match legacy `unit_states` by `definition_id` and occurrence
   order. Each legacy state is consumed at most once.
3. If a particular expected unit has no recoverable state, the
   migrated unit uses content-independent sentinel defaults:

   ```text
   current_hp    = -1
   max_hp        = -1
   bonus_attack  = 0
   dead          = false
   ```

   plus a warning diagnostic `unit_state_defaulted_to_sentinel`.
4. The migrator NEVER queries `ContentDB` or `UnitDef` to discover
   `max_hp`. Reconstruction from gameplay content is the production
   consumer's responsibility.
5. If all `unit_states` are absent while expected non-empty, return
   migration failure with diagnostic `unit_states_completely_missing`.
6. If expected empty but `unit_states` non-empty, ignore extra states
   with diagnostic `ignored_legacy_state`.

## Equipment consistency invariants

The v4 validator enforces bidirectional invariants:

```
item.owner_unit_id == unit.instance_id
  iff
unit.equipped_item_ids contains item.instance_id
```

Invalid cases:

| Case | Diagnostic |
|---|---|
| item.owner = unit_X but unit_X.equipped_item_ids does not contain item | `inconsistent_equip` |
| unit_X lists item but item.owner = "" | `inconsistent_equip` |
| same item id listed by two units | `inconsistent_equip` |
| unit references unknown item id | `unknown_item_in_equipped_list` |
| duplicate id inside one unit's equipped_item_ids | `duplicate_in_unit_equipped` |
| `current_hp < -1` | `current_hp_below_sentinel` |

## Required v4 validator checks

The validator must reject:

- non-Dictionary input,
- missing top-level keys,
- top-level type mismatches (post-wire-normalization),
- duplicate unit / item instance_id,
- unknown item owner,
- inconsistent equipment (above),
- invalid location (not 0 or 1),
- duplicate order in one location,
- HP out of `[0, max_hp]` range,
- current_hp < -1,
- next_*_instance_seq != `max_used + 1`.

## Out of scope for the v4 migrator

- `ContentDB` lookups,
- `BattleSetup` / `BattleSimulation` / `BattleWorld`,
- `EffectEngine` / `Effect` execution,
- `RunController.save_now()` / `resume_run()` wiring,
- `MetaProfile` schema migration,
- the `.tres` save filename.

These are deferred to later phases.