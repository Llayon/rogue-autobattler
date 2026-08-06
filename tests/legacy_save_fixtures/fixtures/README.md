# Legacy v1 save fixtures

Byte-faithful copies of files produced by the current production save
path (`SaveService.save_*`) when invoked from the live Godot
`user://` directory at capture time.

These fixtures are **the current on-disk schema**, not a desired
schema. The future `legacy_save_v1_to_v4_migrator.gd` must accept
these bytes verbatim.

## Layout

```text
fixtures/version_1/
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

The `script_class=` attribute and `[ext_resource]` anchors are
preserved. This is intentional: the byte-faithful copy is the input
contract for the migrator.

## Loader test

`../loader_test.gd` exercises each fixture through:

1. `SaveSvc.load_resource(path)` (low-level parser path) for the meta
   fixture through a temp filename `meta_legacy_v1_test.tres` inside
   `user://saves/` (so the user's existing `meta.tres` is never
   overwritten), then deletes the temp file.
2. `SaveService.load_run(seed)` for each run fixture through the
   production filename `run_<seed>.tres`, then `delete_run(seed)`.
3. Independent low-level `load(path)` parsing check on every fixture.

Result: 60/60 assertions pass.

## Update policy

Update is explicit only. Do not auto-rewrite fixtures in CI. When
intentionally changing the production save shape, regenerate the
captures manually, copy them into `fixtures/version_1/`, and
re-run the loader test.

To regenerate the bytes:

1. Run the live Godot game with a new run, then save via
   `SaveService.save_run()` and `SaveService.save_meta()`.
2. Locate the saved files in
   `%APPDATA%\Godot\app_userdata\Rogue AutoBattler\saves\` (or the
   equivalent `user://` path for the current OS).
3. Copy them into this directory.
4. Re-run the loader test.

If you do not have a live game handy, the canonical byte content is
already captured here and does not need regenerating.

## Renaming

If the schema version on disk ever changes again, create a sibling
directory `fixtures/version_N/` rather than mutating the v1 files in
place. v1 fixtures remain the migration source of truth until the
migrator is proven to retire them.