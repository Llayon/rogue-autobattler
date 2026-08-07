# Save Schema v4 migration

Pure, in-memory migration from the legacy on-disk v1 run shape to
schema v4. No production save path is wired in this step; see
`tests/legacy_save_fixtures/loader_test.gd` for the legacy loader
verification and `docs/LEGACY_V1_TO_V4_MAPPING.md` for the field
mapping contract.

## Files

Production code:

- `core/progression/run_unit.gd` — `RunUnit` (pure data class, stable
  `instance_id`).
- `core/progression/run_item.gd` — `RunItem` (pure data class,
  owner is `RunUnit.instance_id` or empty string).
- `core/save/save_schema_v4.gd` — v4 DTO contract and `TOP_LEVEL_KEYS`
  order; `is_v4_dto()` and `empty_dto()`.
- `core/save/migration_diagnostic.gd` — diagnostic record.
- `core/save/migration_result.gd` — `MigrationResult` shape.
- `core/save/legacy_save_v1_to_v4_migrator.gd` — `migrate_run`,
  `serialize`, `deserialize`, `canonicalize`, `validate`.
- `core/save/save_serializer_v4.gd`, `save_deserializer_v4.gd`,
  `save_validator_v4.gd` are folded into the migrator file
  because they share the same `TOP_LEVEL_KEYS` contract and are
  only a few lines each.

Tests:

- `tests/save_schema_v4/save_schema_v4_test.gd` — migration
  contract, fixtures round-trip, validator rules.
- `tests/save_schema_v4/byte_for_byte_determinism_test.gd` —
  repeated-migration canonical hash stability.

## Diagnostics policy

The migrator never throws for expected validation failures. Every
diagnostic carries a stable `code`, a `severity` (`info`, `warning`,
`error`), a human-readable `detail`, and a stable `context` string.

- `unit_states_count_mismatch` (warning) — emitted when
  `player_unit_ids + bench_unit_ids` length differs from
  `unit_states` length. The migrator proceeds; remaining legacy
  states are matched by occurrence order, and missing slots
  resolve to default HP values.
- `item_equip_board_idx_out_of_range` (warning) — the equipped
  index points past the board. The item is unequipped and
  recorded as in inventory; the original index is captured in
  `context`.
- `item_equip_board_idx_not_int` (warning) — the slot is not an
  integer. The item is unequipped.
- `item_equip_board_idx_negative` (warning) — treated as
  inventory; no diagnostic emitted (negative is the in-inventory
  sentinel).
- `not_v4_dto`, `duplicate_unit_instance_id`,
  `duplicate_item_instance_id`, `unknown_item_owner`,
  `inconsistent_equip`, `empty_unit_instance_id`,
  `empty_item_instance_id`, `hp_out_of_range`,
  `next_unit_instance_seq_too_small`,
  `next_item_instance_seq_too_small`, `source_not_legacy_v1` —
  validator errors. The validator never mutates the input; the
  migrator never throws on these.

## Source detection

A source is treated as legacy v1 when:

- it is a `Resource` whose class extends `Resource` and has the
  expected legacy field names (`player_unit_ids`, `unit_states`,
  `item_ids`); or
- it is a `Dictionary` that structurally matches the same
  fields.

The internal class constant `RunState.SAVE_VERSION = 3` is
irrelevant to the wire format because `SaveSvc.save_resource`
overwrites `version` to `1` on every save.

## Instance ID rules

- `unit_000001`, `unit_000002`, … allocated in board order then
  bench order.
- `item_000001`, `item_000002`, … allocated in `item_ids` source
  order.
- The migrator persists `next_unit_instance_seq` and
  `next_item_instance_seq` so the next `RunController` step can
  allocate further IDs without colliding.

## Round-trip

- `serialize(data)` produces a canonical Dictionary with all
  `SaveSchemaV4.TOP_LEVEL_KEYS` present in fixed order.
- `deserialize(serialized)` accepts any key order and produces the
  same canonical form.
- `canonicalize(data) == serialize(data)`.

## Out of scope for this step

- Wiring the migrator into `SaveService.load_run` (deferred to
  P1-T2 in the plan).
- Atomic replace of legacy `.tres` files (deferred).
- `MetaProfile` migration (not in this run migrator; if the
  future `MetaProfile` schema migration is required, it is a
  separate file).