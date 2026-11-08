# LOCAL WEB SMOKE — the Phase 3 web build in a real browser

    The build:   Godot 4.7.stable.official.5b4e0cb0f
    The preset:  "Web (no threads)"
    The browser: Chrome 156.0.8078.80 (headless, CDP)
    The runtime: the REAL WebAssembly build, served over a local HTTP
                 server -- NOT the headless Godot runtime
    The source:  the integration candidate, exported from a CLEAN
                 checkout of the exact commit (tracked files only)

    LOCAL WEB SMOKE -- NOT a live Pages deployment. Nothing here was
    deployed. The Pages deployment is verified only by a real CI run
    on the real remote.

    How the evidence was produced: the production checkpoint was read
    from the browser's IndexedDB (the same file the game writes), the
    node positions were computed with the PRODUCTION layout formula
    from scenes/encounter/encounter_map_view.gd, and every click was
    a real mouse event on a real canvas button. No private method was
    called, and no debug cheat was added to the game.

## The scenarios

```
WEB-01  index.html loads successfully                    PASS
WEB-02  WASM initializes                                PASS
WEB-03  main menu is visible                           PASS
WEB-04  new run starts                                  PASS
WEB-05  first PREP battle starts legally                PASS
WEB-06  battle renders and progresses                   PASS
WEB-07  battle can end                                   PASS
WEB-08  reward flow works                               PASS
WEB-09  MAP renders                                     PASS
WEB-10  COMBAT node selection works                     PASS
WEB-11  MERCHANT opens                                  PASS
WEB-12  SPACE/ESC closes merchant without a battle      PASS
WEB-13  shop purchase updates the visible state         PASS
WEB-14  TREASURE works                                  PASS
WEB-15  settings                                        NOT VERIFIED
WEB-16  a new save -> reload -> Continue                PASS
WEB-17  an unsupported old save does not trap the app   PASS
WEB-18  no fatal JavaScript errors / missing assets     PASS
```

    17 of 18 PASS. The one exception is WEB-15, and it is NOT a
    defect of the build: the settings UI is UNREACHABLE in the
    shipping game -- see the note at the end.

## WEB-14 -- the TREASURE, in full

    The production rules, taken from the code and not invented:

```
core/balance.gd                  MAP_TREASURE_GOLD = 5
run_controller.gd:1832           _apply_treasure_effect()
  -> state.gold += 5
  -> UnlockManager.grant_random_unit(profile, round_index)
  -> _pick_random_item_id() then _grant_reward_item(item_id)
run_controller.gd:1739           the guard: if phase != Phase.MAP: return
```

    The route actually walked, read from the production checkpoint:

```
the route   0 (COMBAT) -> 4 (COMBAT) -> 6 (MERCHANT) -> 9 (HEAL)
            -> 13 (COMBAT) -> 15 (TREASURE)
```

    The absolute results:

```
gold_before            31
gold_after             36          (+5 == MAP_TREASURE_GOLD)
inventory_before       [amulet_vigor item_000001]
inventory_after        [amulet_vigor item_000001, amulet_vigor item_000002]
meta_unlocks_before    [warrior, archer, goblin]
meta_unlocks_after     [warrior, archer, goblin, cleric]
RNG before             seed 478065, state 7809480713656495048
RNG after              seed 478065, state 7809480713656495048
checkpoint phase       map
current encounter      15
visited                [4, 6, 9, 13, 15]
the treasure node      visited=true, available=false
```

    The effect was applied EXACTLY ONCE. The treasure node became
    visited and unavailable the moment it was taken.

    NO DUPLICATE REWARD: the treasure was re-selected afterwards --
    through the Continue button and by clicking the same node again --
    and the gold stayed at 36, the item count stayed at 2 and the
    unlock list did not change.

    PERSISTENCE ACROSS A RELOAD: the reload restored the gold, the
    items, the unlock list, the RNG state, the phase and the current
    encounter exactly.

## WEB-15 -- the settings: NOT VERIFIED, and why

    The finding is a REAL DEFECT in the shipping game, and it is NOT
    a regression of this series: it is present on master as well.

```
scenes/main_menu/main_menu.gd
  var _settings_button: Button = null      <- declared
  func _on_settings_pressed() -> void       <- the handler
  func _build_settings_panel() -> void      <- builds the panel
  _build_vbox() adds "New Run" and "Continue" -- and NOTHING else
```

    The button that would call the handler is never created, so the
    panel cannot be opened. The commit that introduced the feature
    (ebb304c "feat(s3): Settings panel with battle_speed toggle")
    wrote in its message that the Settings button opens the panel,
    and it never created that button. The same is true on master.

    The browser confirms it: the main menu carries only "New Run"
    (and "Continue" when a save exists), and clicking every plausible
    spot opens no "Battle Speed" panel.

    The panel is also never exercised by any test, which is why the
    defect survived.

    The persistence half of the feature is real and works:
    `_set_speed()` writes `MetaProfile.battle_speed` through
    `SaveService.save_meta()`, and `battle_scene.gd` reads
    `run_controller.profile.battle_speed` for the battle speed.

    So the setting is PERSISTED but NOT REACHABLE. Adding the missing
    button would be a UI feature change and is outside this closure.

## The clean checkout

    The build under test was exported from a checkout that contained
    ONLY the tracked files of the exact commit: no .godot/, no
    build/, no untracked .uid, no local cache.

```
the import              0 script errors, 0 parse errors, 0 missing
the export              the full artifact
the artifact validation PASS
index.html  5448   index.js  279815
index.wasm  39509339   index.pck  1893188
```

    index.html, index.js and index.wasm are BYTE-FOR-BYTE identical to
    the build of the working tree. index.pck differs, because it
    carries the import cache of the machine that produced it; its
    game content is the same.

    The clean build was then loaded in the same browser: the WASM
    initialized, the main menu appeared, a new run started, the PREP
    screen showed the two starting units, the battle ran and ended in
    a win (wins 1, gold 16), and the REWARD screen offered the three
    units.

## The .uid classification

    The claim being tested: the untracked .uid files are import
    artifacts, not a hidden dependency.

```
the tracked .uid files                  174
  without their source file               0   (no orphans)
the .gd sources without a tracked .uid    88
  of those, added by Phase 3               75
  of those, already missing on master      13
  where they are:  tests/ 63, core/battle_ecs/ 19, other core/ 6
the untracked .uid files in the working tree  88
  the SAME set as the 88 -- the comparison is empty in both
  directions
the master baseline                   114 .uid over 128 .gd
```

    Where the uid:// references actually live:

```
the .uid files themselves          174   (each carries its own uid)
icon.svg.import                       1   (the importer's identity for
                                         the icon texture)
the shipping content (.tres)         0   (every script is referenced
                                         by PATH, "script =
                                         ExtResource(...)")
```

    The clean checkout, which has NO untracked .uid at all, imported
    with zero errors and exported a complete artifact. So the .uid
    files are a by-product of the import, not a dependency of the
    build.

    The tracked .uid files ARE part of the repository, and the
    project's own convention keeps them: they are the stable identity
    of the scripts and the resources. The 88 missing ones are a gap
    in that convention, not a build dependency. Adding them is a
    separate, deliberate change and is not done here.

## What is NOT verified here

```
the live Pages deployment          NOT VERIFIED -- nothing was deployed
the Pages environment restrictions NOT VERIFIED -- only a real
                                     deployment can show them
the two browser scenarios that were
  not reached: WEB-15               NOT VERIFIED (see above)
the crash recovery and the atomic
  MetaProfile                      NOT VERIFIED -- that is A0
```

    The backward compatibility of the OLD user saves is not a claim of
    this document and not a requirement of the release: the project is
    pre-release, and a corrupt save is DROPPED rather than fatal.
