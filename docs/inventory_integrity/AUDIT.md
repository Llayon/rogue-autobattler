# Inventory Integrity Gauntlet

## A. Baseline and isolation

- Exact committed baseline: `d6df480b5de4427858f37e4fa9d1f8ab75ad7287`.
- Branch: `feat/inventory-integrity`.
- Worktree: `C:/Users/user/Documents/GodotProjects/rogue-autobattler-inventory`.
- Primary initially: `phase3/effect-status-trigger-gauntlet`, with untracked files; no uncommitted files were copied.
- All edits, imports, tests and mutations ran in the sibling worktree. No branch switch/reset/rebase/force/push occurred.
- The primary agent continued committing independently. A changed primary HEAD is not evidence of an inventory-agent edit.

## B. Actual model and owners

`core/progression/run_item.gd`: `RunItem.instance_id` is a canonical positive sequence formatted as `item_%06d`, independent of `definition_id`. IDs are strings, not integer fields. `RunDomainState.items` contains ALL live instances. Inventory means empty `owner_unit_id`; equipped means owner names an existing RunUnit AND exactly that unit lists the instance once in `equipped_item_ids`.

`core/progression/run_domain_state.gd`: allocation, create_item, equip_item, unequip_item, remove_item own mutations. `get_inventory_items` and `get_equipped_items` project ownership in storage insertion order. No item order field, no named weapon/armor/trinket slots, no slot limit. `ItemDef` has bonuses, no slot/type restrictions. New equip is board-only; a unit moved to bench retains equipment and may unequip it.

`core/progression/run_controller.gd`: grant_item owns capacity/content checks; equip_item_by_id/unequip_item_by_id are stable UI commands. equip_item_at/unequip_item_at/remove_item_at are immediate compatibility coordinates resolved to instance identity at call time. Indices are not stable across reorder. buy_item, treasure and combat-drop grant through grant_item. Bonus consumers: get_unit_bonus_stats/start_battle and BattleSetupBuilder.build.

Transfer to another unit is legal and removes old owner reference; repeated same-owner equip is no-op success. Several items coexist on a unit; there is no replacement slot. Removing an equipped item implements contract B: detach and delete the exact instance, retaining allocator cursor. Unequip of an already loose, consistent item returns false without mutation (existing executable behavior, despite stale comments).

No production RunUnit removal command or units.remove/erase/clear mutation was found in core/scenes. Death retains the unit; moving between board/bench preserves equipment. A future removal contract cannot be inferred from these operations.

## C. Finding ledger

Source anchors use function names, which remain stable across the added guards. Baseline findings distinguish valid-state behavior from malformed live-state input.

| Invariant | Baseline status / severity | Executable source proof | Final runtime proof |
|---|---|---|---|
| INV-01 | PARTIAL / high | allocate_item_instance_id blindly increments public cursor; create_item appends; get_item returns first match | live gate rejects malformed/zero/duplicate IDs; inventory T1, allocator boundary, NC-I1 |
| INV-02 | PARTIAL / high | remove_item preserves cursor already; direct allocator accepted zero/stale and wrapped int64 | T2/T3/T4, allocator 7 assertions; NC-I2; existing cursor contract 15 assertions |
| INV-03 | PARTIAL / high | owner_unit_id + mirrored equipped_item_ids; equip trusted malformed prior state | is_inventory_valid checks both directions before commands; dangling/invalid-owner atomicity tests |
| INV-04 | ALREADY SAFE for valid input; PARTIAL for corruption / high | equip_item removes old owner then appends new; corrupt reverse listings not rejected | transfer and repeat tests, duplicate listing gate, NC-I3 |
| INV-05 | PARTIAL / high | unknown item command rejects; existing dangling equipped list was tolerated | dangling reference blocks commands atomically; battle boundary documents builder assumption |
| INV-06 | ALREADY SAFE board-only; PARTIAL definition resolution / medium | equip_item checks location; no named slots in ItemDef; controller previously accepted unknown definition | T6 + NC-I4 board compatibility; controller typed items lookup rejects unknown/non-item grants/equips |
| INV-07 | PARTIAL / high | missing target rejected; invalid previous ownership silently repaired/reassigned | snapshots and malformed input tests; NC-I7 |
| INV-08 | ALREADY SAFE / high consequence | unequip_item changes owner and references, never creates item | T9 object identity/cursor assertion; NC-I5 |
| INV-09 | ALREADY SAFE / high consequence | remove_item looks up instance, removes same object; remove_item_at resolves current coordinate | three identical definitions + reorder T12; NC-I6 |
| INV-10 | CONFIRMED contract B / medium | remove_item removes owner list entry then live object | T14 and existing domain equipped-removal tests |
| INV-11 | CONTRACT DECISION / medium | no unit removal command; move_unit preserves equipment and dead units retained | move-to-bench/unequip regression; future deletion rule remains explicitly undecided |
| INV-12 | PARTIAL / high | invalid definitions/corrupt ownership were accepted; grant ignored create rejection | snapshot assertions; controller 6 assertions; all invalid commands validate first |

## D. Implemented hardening

1. Pure live `is_inventory_valid()` checks canonical positive unique identities, a cursor above all live IDs, unique unit IDs, unique equipment listings, existing owners/items and bidirectional links. It does not read ContentDB or persistence DTOs.
2. create/equip/unequip/remove reject malformed live inventory before any mutation. No rollback framework. Empty definitions cannot consume an ID.
3. Public item allocation rejects invalid inventory and exhausted int64 cursor without mutation; create propagates failure. Maximum int64 is reserved as an exhausted cursor to prevent wrap.
4. Controller grant/equip resolve through ContentDB's typed `items` index; grant propagates domain failure. Compatibility equip delegates to the same by-ID command.
5. Existing transfer, multi-item, board-only, equipped removal and insertion-order contracts remain unchanged.

Public mutable domain fields still permit external code to inject corruption. Such injection is detected and rejected at mutation boundaries; this change does not make GDScript fields immutable or invent import/repair commands. Definition existence is a controller responsibility; the pure domain accepts any nonempty template key.

## E. Verification

See `evidence/gates.json` for exact suite assertion summaries, exit codes and script/parse error counts. `evidence/red.log`, `controller-red.log` and `allocator-red.log` preserve semantic RED evidence (17/5, 1/5 and 2/5 respectively; each rc=1 and no script/parse errors). Parser failure was never counted as RED.

Inventory suites: identity/ownership/atomicity/lifecycle 35; controller 6; allocator boundaries 7; independent negative probes 7; battle boundary 5. Total 60 assertions.

Protected gates include legacy run_tests, all run_domain suites, legacy characterization/save fixtures, v4 schema and determinism, save repository/file ops, progression unit and existing sequence cursor contract. Final runner: **94 suites executed, 94 GREEN, 8438 pass / 0 fail**, rc=0, zero script/parse errors (the repository runner also discovers protected non-ECS suites). Lint: rc=0, 0 errors, 5 pre-existing warnings in unchanged balance/main_menu files. Editor parse: rc=0, zero script/parse errors. A-H differential: rc=0, all 8 fixtures identical in projected traces/world/RNG/emitter/result against an archive of the exact committed baseline. The archive was inside this worktree; no primary files were used as a mutable baseline.

All listed inventory and protected standalone suites have rc=0 and zero script/parse errors. The RED logs are intentional failing characterization runs, not final regressions. One intermediate Windows wrapper hit console encoding errors after successful subprocesses; it was rerun with PYTHONUTF8=1, producing the final recorded GREEN results.

## F. Negative controls

`tests/inventory_integrity/run_negative_controls.py` is a reproducible sequential harness with finally-restore of original bytes. Every control runs a fresh independent production probe, requires nonzero rc + semantic FAIL + zero script/parse errors, then restores and requires GREEN. See `evidence/negative-controls.json`.

| Control | Deliberate semantic mutation | RED | Restored |
|---|---|---|---|
| NC-I1 | omit duplicate instance check | rc=1, semantic FAIL | rc=0 GREEN |
| NC-I2 | decrement cursor on remove | rc=1, semantic FAIL | rc=0 GREEN |
| NC-I3 | omit old-owner reference removal during legal transfer | rc=1, semantic FAIL | rc=0 GREEN |
| NC-I4 | omit board compatibility check (there are no named slots) | rc=1, semantic FAIL | rc=0 GREEN |
| NC-I5 | mint replacement identity during unequip | rc=1, semantic FAIL | rc=0 GREEN |
| NC-I6 | select removal victim by shared definition | rc=1, semantic FAIL | rc=0 GREEN |
| NC-I7 | change owner before reporting missing unit failure | rc=1, semantic FAIL | rc=0 GREEN |

All fourteen RED/GREEN subprocesses had zero script/parse errors. NC-I3 adapts the requested check to the actual transfer contract rather than banning transfer.

## G. Cross-system findings

### Persistence

No persistence, schema, mapper, validator, RNG serialization, checkpoint, resume_run or save_now code changed. Baseline RunDomainSemanticValidator.validate already uses `cursor >= 1 && cursor > max_live_id`; existing sequence_cursor_contract_test passes. No conflicting counter fix was duplicated. No BLOCKED BY RUN-INTEGRITY WORKSTREAM production fix is required by the confirmed inventory defects.

### Battle setup

BattleSetupBuilder.build reads ownership via get_equipped_items(unit.instance_id), then definition bonuses. It does not preserve item instance IDs in BattleUnitSetup. Valid transfer gives exactly one bonus to the current owner and none to the previous owner; build leaves domain state unchanged (boundary suite).

Known trust boundary: BattleSetup.validate validates setup rows, not inventory links. Injecting a dangling reverse equipped list is ignored by builder and can still yield a valid setup. Injecting two RunItem objects with the same ID but different owners can apply one logical ID to two units; new mutation gate rejects that live state, but builder itself does not call the gate. Invalid templates are skipped by builder (legacy controller bonus lookup can read wrong resource properties if callers bypass controller content validation). No battle semantics were changed. Follow-up: agree on fail-closed validation at battle launch if support for unvalidated external live-state writers is required.

### UI

scenes/inventory/inventory_scene.gd `_on_item_pressed` reads the clicked instance ID; try_equip_to_board resolves target unit identity and calls controller.equip_item_by_id; unequip calls controller.unequip_item_by_id. UI reads arrays for presentation and does not mutate equipment fields/arrays. No UI redesign or source-of-truth migration needed. Existing UI stable identity suite passes.

## H. Git and integration

Local commits only. Branch has no upstream, so upstream ahead/behind is N/A. Exact final commit and baseline distance are reported in the final response; commit cannot self-contain its own hash. Canonical refs and primary worktree were never written by this agent. The primary branch progressed independently during execution. No fetch/push was performed.

## I. Merge risk

Production overlap candidates: **core/progression/run_domain_state.gd** (item methods, live guard and item cursor limit) and **core/progression/run_controller.gd** (grant_item, equip_item_by_id, equip_item_at only). Review these against Agent A before integration. No other production files changed. New tests and docs are isolated under inventory_integrity. No GitHub Actions changes.

## J. Verdict

HOLD ? INV-11 future unit-removal ownership contract is not defined by existing production code/tests; CONTRACT DECISION REQUIRED. No removal gameplay command was invented. Domain fixes and integration evidence are reviewable independently of that decision.
