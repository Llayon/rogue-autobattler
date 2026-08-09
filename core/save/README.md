# Save Schema v4 — Pure Migration, Repository, and Hardening

This directory contains the pure in-memory migration from the legacy
on-disk v1 run shape to schema v4, the production save repository,
and the Phase 1H hardening layer.

The production `RunSaveRepository` is wired through its own public
API; the legacy `SaveService` path is unchanged and remains
operational. The repository has not yet been connected to
`RunController.save_now()` / `resume_run()`.

## Files

Production code:

- `core/progression/run_unit.gd` — `RunUnit` (pure data class, stable
  `instance_id`; `is_alive()` honours the `current_hp == -1`
  sentinel).
- `core/progression/run_item.gd` — `RunItem` (pure data class, owner
  is `RunUnit.instance_id` or empty string).
- `core/save/save_schema_v4.gd` — v4 DTO contract and `TOP_LEVEL_KEYS`
  canonical order; `is_v4_dto()` bool API, `validate_shape()` returns
  `{success, diagnostics}`; wire helpers `_wire_int`, `_wire_bool`,
  `_wire_string`, `_wire_array`, `_wire_dict`.
- `core/save/migration_diagnostic.gd` — diagnostic record
  (`severity` / `code` / `detail` / `context`).
- `core/save/migration_result.gd` — `MigrationResult` shape.
- `core/save/legacy_save_v1_to_v4_migrator.gd` — `migrate_run`,
  `serialize`, `deserialize`, `canonicalize`, `validate`,
  `serialize_canonical_bytes`. Type-defensive validator.
- `core/save/save_load_result.gd` — `SaveLoadResult` typed result
  for repository calls; `OK` plus 14 `ERROR_*` codes.
- `core/save/run_save_file_ops.gd` — production filesystem adapter
  (`exists`, `read_bytes`, `write_bytes_and_flush`, `rename`,
  `remove`, `sha256`).
- `core/save/run_save_repository.gd` — `RunSaveRepository` with
  format detection, single recovery state machine, and the
  crash-recoverable commit protocol.

Tests:

- `tests/save_repository/save_repository_test.gd` — production
  repository contract, recovery matrix, backup protocol,
  equipment invariants, format detection, seed / run_id
  consistency.
- `tests/save_repository/run_save_file_ops_test.gd` — filesystem
  adapter contract (production + fault-injection).
- `tests/save_repository/support/run_save_file_ops_fault.gd` —
  test-only fault-injection adapter (no global `class_name`).
- `tests/save_schema_v4/save_schema_v4_test.gd` — migration
  contract, fixtures round-trip, validator rules, equipment
  invariants, sentinel semantics.
- `tests/save_schema_v4/byte_for_byte_determinism_test.gd` —
  serialized-byte determinism across repeated migrations.
- `tests/progression/run_unit_test.gd` — `is_alive()` sentinel
  semantics.
- `tests/legacy_save_fixtures/` — byte-faithful v1 fixtures.

## Wire format

```
# v4 save
{schema_version: 4, ...canonical JSON sorted by key...}
```

The first line is the marker `# v4 save`. The body is
`JSON.stringify(data, "", true)` — key sort applied. Canonical
arrays (`units`, `items`, `encounter_visited_ids`, `equipped_item_ids`)
keep their semantic order.

## Source detection

A file is detected as:

| marker / content | classification |
|---|---|
| `# v4 save` + JSON parse OK + `schema_version == 4` (int) | v4 |
| `# v4 save` + JSON parse fails | `corrupt_v4` (never legacy fallback) |
| `# v4 save` + `schema_version` missing / wrong type | `corrupt_v4` |
| `# v4 save` + `schema_version` is int but != 4 | `unsupported_schema` (never legacy fallback) |
| `[gd_resource` + `player_unit_ids` + `unit_states` keys | `legacy_v1_candidate` |
| otherwise | `unknown` |

The `schema_version` on the wire is wire-classified by
`SaveSchemaV4._wire_int`: integral floats accepted, non-integral
floats / strings / bools / nulls / NaN / Infinity rejected.

## Recovery state machine

A single `_recover_startup_state` runs at the top of both `load_run`
and `save_run`. The postcondition after a successful recovery is
**commit-old MUST NOT exist when a new commit begins**.

| `target` | `commit-old` | Action | Resulting state |
|---|---|---|---|
| valid | none | no-op | target valid, no commit-old |
| missing | valid (v4 or legacy) | restore commit-old → target | target valid, no commit-old |
| valid | valid (stale) | target authoritative; remove stale | target valid, no commit-old |
| valid | invalid (stale) | target authoritative; remove stale | target valid, no commit-old |
| invalid | valid | preserve invalid target; restore commit-old | target valid, no commit-old |
| invalid | invalid | controlled error; destroy nothing | files preserved unchanged |
| missing | invalid | controlled error; destroy nothing | files preserved unchanged |
| missing | none | (downstream returns missing) | (no file) |

The immutable `.legacy-v1.bak` is NEVER touched by recovery.

## Commit protocol

The crash-recoverable commit uses only `DirAccess.rename`. There is
no `target → WRITE` byte-copy fallback. Fresh save is a single
rename. Existing save is `target → commit-old → temp → target` with
rollback on every step. Post-commit validate re-reads the file and
verifies `seed` and `schema_version`; on failure, preserve the
invalid target as `<target>.invalid.<timestamp>` and restore
commit-old.

## Backup protocol

Path: `<save>.legacy-v1.bak`. Created exactly once per run file via
temp-write + sha256-verify + rename + post-create re-verification.
Existing-but-corrupt backup → `ERROR_BACKUP_INVALID` (migrator
refuses, no overwrite). Existing-but-different backup →
`ERROR_BACKUP_CONFLICT` (migrator refuses). The immutable backup
is NEVER auto-repaired or auto-overwritten.

## Instance ID rules

`unit_000001`, `unit_000002`, … allocated in board order then bench
order. `item_000001`, `item_000002`, … allocated in `item_ids`
source order. Format: `<prefix>_<6-digit zero-padded>`. No UUID, no
time, no random.

`next_unit_instance_seq` and `next_item_instance_seq` are the FIRST
UNUSED sequence after migration (i.e. `max_used + 1`). The validator
requires them to be exactly `max_used + 1`.

## `unit_states` matching policy

1. `expected_definitions` = `player_unit_ids` source order, then
   `bench_unit_ids` source order.
2. Match legacy `unit_states` by `definition_id` and occurrence
   order. Each legacy state is consumed at most once.
3. If a particular expected unit has no recoverable state, the
   migrated unit uses content-independent sentinel defaults:
   `current_hp = -1`, `max_hp = -1`, `bonus_attack = 0`,
   `dead = false`. Plus a warning diagnostic
   `unit_state_defaulted_to_sentinel`.
4. The migrator NEVER queries `ContentDB` or `UnitDef`.
5. If all `unit_states` are absent while expected non-empty, return
   migration failure with diagnostic
   `unit_states_completely_missing`.
6. If expected empty but `unit_states` non-empty, ignore extra states
   with diagnostic `ignored_legacy_state`.

## Equipment consistency invariants

The validator enforces bidirectional invariants:

```
item.owner_unit_id == unit.instance_id
  iff
unit.equipped_item_ids contains item.instance_id
```

Invalid cases (all rejected with diagnostics):

| Case | Diagnostic |
|---|---|
| A: item.owner = unit_X but unit_X.equipped_item_ids does not contain item | `inconsistent_equip` |
| B: unit_X lists item but item.owner = "" | `inconsistent_equip` |
| C: same item id listed by two units | `item_listed_by_multiple_units` |
| D: unit references unknown item id | `unknown_item_in_equipped_list` |
| E: duplicate id inside one unit's equipped_item_ids | `duplicate_in_unit_equipped` |

## Validator contract

The `validate(data)` function is type-defensive: malformed input
produces diagnostics, never `SCRIPT ERROR` or runtime type errors.
Each field access uses safe coercion helpers (`_safe_str`,
`_safe_int`, `_safe_bool`).

Required v4 DTO checks (all produce diagnostics on failure):

- non-Dictionary input (`not_v4_dto`)
- missing or wrong-type top-level keys (`missing_top_level_key`,
  `top_level_type_mismatch`)
- duplicate unit / item instance_id
- empty unit / item definition_id
- unknown item owner
- inconsistent equipment (above)
- invalid location (not 0 or 1) → `unit_location_invalid`
- negative order → `unit_order_negative`
- duplicate order in one location → `duplicate_unit_order_in_location`
- HP out of range → `hp_out_of_range`
- `current_hp < -1` → `current_hp_below_sentinel`
- `next_*_instance_seq != max_used + 1` →
  `next_*_instance_seq_invalid`

## Out of scope for this directory

- `RunController.save_now()` / `resume_run()` wiring (deferred to
  P1-T2 in the migration plan).
- `BattleSetup` / `BattleSimulation` / `BattleWorld` / `Effect Engine`.
- Simulation RNG contract.
- `MetaProfile` schema migration.
- Renaming the `.tres` save filename.