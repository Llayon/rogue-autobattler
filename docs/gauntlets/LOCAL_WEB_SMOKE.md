# LOCAL WEB SMOKE — the Phase 3 web build in a real browser

    The build:   Godot 4.7.stable.official.5b4e0cb0f
    The preset:  "Web (no threads)"
    The browser: Chrome 156.0.8078.80 (headless=new, CDP)
    The server:  python -m http.server 8099 (127.0.0.1)
    The scope:   LOCAL WEB SMOKE — NOT a live Pages deployment

## The scenarios

| ID | Scenario | Verdict | Evidence |
|---|---|---|---|
| WEB-01 | index.html loads | PASS | title "Rogue AutoBattler", HTTP 200, 5448 bytes |
| WEB-02 | WASM initializes | PASS | canvas 762x484, the engine renders |
| WEB-03 | the main menu is visible | PASS | "Runs: 0 Wins: 0", the "New Run" button |
| WEB-04 | a new run starts | PASS | the PREP screen of round 1 |
| WEB-05 | the first PREP battle starts legally | PASS | SPACE on the PREP screen starts the battle |
| WEB-06 | the battle renders and progresses | PASS | the battle screen with the two units |
| WEB-07 | the battle can end | PASS | the battle resolves to the REWARD screen |
| WEB-08 | the reward flow works | PASS | three unit cards, the pick is accepted |
| WEB-09 | the MAP renders | PASS | ten layers, the B/C/M/T/H/R/E legend |
| WEB-10 | the node selection works | PASS | a click on the orange node opens the PREP screen |
| WEB-11 | the MERCHANT opens | PASS | "SHOP (50% off!)", the gold counter, three items |
| WEB-12 | SPACE/ESC closes the merchant without a battle | PASS | SPACE returned to the MAP, no battle started |
| WEB-13 | the shop purchase updates the visible state | PASS | the gold 23 -> 22, the BUY button went grey |
| WEB-14 | TREASURE and the item reward work | NOT REACHED | the TREASURE nodes were not reachable in this seed |
| WEB-15 | the settings interaction works | NOT REACHED | no settings control was reachable from the menu |
| WEB-16 | a new save -> reload -> Continue | PASS | the reload offered "Continue", the restored map kept the node position |
| WEB-17 | an unsupported old save does not trap the app | PASS | the corrupt save was dropped, the menu loaded, 0 page errors |
| WEB-18 | no fatal JavaScript errors / missing assets | PASS | all 5 resources loaded, the engine alive, 0 page errors |

    The two NOT REACHED scenarios are a coverage gap of THIS seed and
    this browser session, not a proven defect: the run in this session
    never routed through a TREASURE, and the main menu exposes no
    settings control that the automation could reach. Neither is
    claimed as working.

## What the smoke PROVED beyond the checklist

1. **The battle-entry guard holds in the real web runtime.** The
   merchant SPACE path was exercised through the browser's own key
   pipeline: the shop closed and NO battle started. This is the
   RUN-ENTRY-02 contract, confirmed in the WebAssembly runtime rather
   than in the headless Godot runtime.

2. **The save survives a real browser restart.** The run was written
   into IndexedDB (the Godot web build keeps `user://` in the
   `/userfs` database, store `FILE_DATA`), and after a full page
   reload the menu offered "Continue" and the restored map stood on the
   SAME node.

3. **A corrupt save is dropped, not fatal.** The `meta.tres` and the
   run file were overwritten with garbage in IndexedDB; after the
   reload the application loaded normally, the "Continue" button was
   GONE (the save was discarded) and "New Run" still worked. There was
   no crash loop, no endless loading and no JavaScript error. That is
   the controlled reset the pre-release save policy allows.

4. **A real defect was found by the local build, not by the CI.** The
   export path in the workflow was relative. On Linux the CI Godot
   resolves it; on Windows the export fails with "the target folder
   does not exist or is not accessible". The workflow now exports to
   an ABSOLUTE path.

## Not verified locally

- the LIVE PAGES deployment (there is no deployment in this gauntlet)
- the GitHub Pages environment restrictions
- the real deployment URL
