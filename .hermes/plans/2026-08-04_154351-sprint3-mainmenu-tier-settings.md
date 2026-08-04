# Sprint 3: MainMenu + Tier metadata + Settings Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Build MainMenu scene as entry point (instead of auto-loading BattleScene), add tier metadata to all unit .tres files for proper UnlockManager tier-weighted unlocks, and add Settings UI for battle_speed toggle.

**Architecture:** MainMenu scene is the new root. It loads MetaProfile from SaveService on entry, shows stats panel, and dispatches to BattleScene via Main (existing pattern). Tier field is added to all unit .tres (defaults + explicit tiers 1/2/3). Settings panel is a child of MainMenu with battle_speed toggle persisted to MetaProfile.

**Tech Stack:** Godot 4.7, GDScript 2.0 (static typing), `MetaProfile`/`UnlockManager`/`UnitsMeta` already exist in core/, SaveService.save_meta/load_meta already wired.

---

## Current context

- **Existing**: `core/progression/meta_profile.gd` (44 lines, Resource with all fields), `core/progression/unlock_manager.gd` (92 lines, static helpers), `core/data/units_meta.gd` (30 lines, hardcoded UNIT_IDS list), `core/save/save_service.gd` (save_meta/load_meta exist).
- **Existing**: `scenes/main.gd` (10 lines, currently auto-loads BattleScene), `core/progression/run_controller.gd` (calls UnlockManager.grant_random_unit on _end_run).
- **Missing**: MainMenu scene, tier field in .tres, settings UI.
- **Tier bug**: `UnitsMeta.ids_by_tier(tier)` returns empty because no .tres has `tier` exported; everything defaults to tier=1. UnlockManager.grant_random_unit is tier-weighted but pool is effectively flat.

## Acceptance criteria

1. Game launches into MainMenu (not BattleScene).
2. MainMenu shows: title, stats (total_runs/total_wins/best_round/soul_currency), New Run button, Continue button (visible only if `profile.current_run_seed != 0`).
3. New Run starts run_controller (battle scene).
4. Continue resumes from `profile.current_run_seed`.
5. Tier=1 for 4 starter units (warrior, archer, mage, cleric).
6. Tier=2 for 8 mid units (guardian, assassin, druid, berserker, beast, cavalry, warrior_v2, knight).
7. Tier=3 for 3 late units (paladin, necromancer, elementalist).
8. Settings panel toggles `battle_speed` between 1x/2x/4x, persisted in MetaProfile.
9. All 471 existing tests still pass.
10. New tests: MainMenu creates, New Run dispatches, Continue only shown when seed != 0.

---

## Part A: MainMenu scene

### Task A.1: Create MainMenu scene file (Control)

**Objective:** Create minimal MainMenu scene with title Label and placeholder buttons.

**Files:**
- Create: `scenes/main_menu/main_menu.gd` (~80 lines)
- Create: `scenes/main_menu/main_menu.tscn` (~15 lines)

**Step 1: Write main_menu.gd**

```gdscript
extends Control
## Главное меню: stats panel + start/continue buttons.
##
## Загружает MetaProfile через SaveService на _ready.
## При нажатии "New Run" вызывает run_controller.start_run с новым seed.
## При нажатии "Continue" вызывает run_controller.resume_run с сохранённым seed.

const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveSvc = preload("res://core/utils/save_manager.gd")

var _profile: MetaProfileScript = null
var _new_run_button: Button = null
var _continue_button: Button = null
var _stats_label: Label = null
var _title_label: Label = null


func _ready() -> void:
    _profile = SaveSvc.load_meta()
    if _profile == null:
        _profile = MetaProfileScript.new()
    _build_layout()
    _refresh()


func _build_layout() -> void:
    var bg: ColorRect = ColorRect.new()
    bg.color = Color(0.04, 0.06, 0.12, 1.0)
    bg.set_anchors_preset(Control.PRESET_FULL_RECT)
    bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(bg)
    var center: CenterContainer = CenterContainer.new()
    center.set_anchors_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(center)
    var vbox: VBoxContainer = vbox_for_menu()
    center.add_child(vbox)


func vbox_for_menu() -> VBoxContainer:
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 18)
    vbox.alignment = BoxContainer.ALIGNMENT_CENTER
    _title_label = Label.new()
    _title_label.text = "ROGUE AUTOBATTLER"
    _title_label.add_theme_font_size_override("font_size", 36)
    _title_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
    _title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(_title_label)
    _stats_label = Label.new()
    _stats_label.add_theme_font_size_override("font_size", 16)
    _stats_label.add_theme_color_override("font_color", Color(0.85, 0.90, 1.0))
    _stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(_stats_label)
    var spacer: Control = Control.new()
    spacer.custom_minimum_size = Vector2(0, 20)
    vbox.add_child(spacer)
    _new_run_button = _make_button("New Run", _on_new_run_pressed, Color(0.30, 0.50, 0.30))
    vbox.add_child(_new_run_button)
    _continue_button = _make_button("Continue", _on_continue_pressed, Color(0.20, 0.40, 0.55))
    vbox.add_child(_continue_button)
    return vbox


func _make_button(text: String, callback: Callable, color: Color) -> Button:
    var btn: Button = Button.new()
    btn.text = text
    btn.custom_minimum_size = Vector2(280, 60)
    btn.add_theme_font_size_override("font_size", 22)
    var normal: StyleBoxFlat = StyleBoxFlat.new()
    normal.bg_color = color
    normal.border_color = Color(0.6, 0.6, 0.8, 0.6)
    normal.set_border_width_all(2)
    normal.set_corner_radius_all(8)
    btn.add_theme_stylebox_override("normal", normal)
    var hover: StyleBoxFlat = normal.duplicate()
    hover.bg_color = color.lightened(0.2)
    btn.add_theme_stylebox_override("hover", hover)
    btn.pressed.connect(callback)
    return btn


func _refresh() -> void:
    if _profile == null:
        return
    if _stats_label != null:
        _stats_label.text = "Runs: %d  Wins: %d  Best round: %d  Souls: %d" % [
            _profile.total_runs, _profile.total_wins, _profile.best_round, _profile.soul_currency
        ]
    if _continue_button != null:
        _continue_button.visible = (_profile.current_run_seed != 0)


func _on_new_run_pressed() -> void:
    var tree: SceneTree = Engine.get_main_loop() as SceneTree
    if tree == null:
        return
    var rng_seed: int = (randi() % 999999) + 1 if true else 1  # Используем Rng
    # Реальная версия:
    rng_seed = preload("res://core/utils/rng_service.gd").randi_range(1, 999999)
    _start_battle_scene(rng_seed)


func _on_continue_pressed() -> void:
    if _profile == null or _profile.current_run_seed == 0:
        return
    _start_battle_scene(_profile.current_run_seed)


func _start_battle_scene(seed: int) -> void:
    var tree: SceneTree = Engine.get_main_loop() as SceneTree
    if tree == null:
        return
    var packed: PackedScene = load("res://scenes/battle/battle_scene.tscn") as PackedScene
    if packed == null:
        return
    # Передаём seed через metadata — BattleScene прочитает в _ready.
    packed.set_meta("initial_seed", seed)
    var inst: Node = packed.instantiate()
    var root: Node = tree.root
    # Удаляем все дети root кроме autoload.
    for child in root.get_children():
        if not child.name.begins_with("@"):
            child.queue_free()
    root.add_child(inst)
```

**Step 2: Write main_menu.tscn**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scenes/main_menu/main_menu.gd" id="1"]

[node name="MainMenu" type="Control"]
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1")
```

**Step 3: Verify file parses**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --editor --quit 2>&1 | grep -iE "error|parse" | head -3`
Expected: empty (clean parse).

**Step 4: Commit**

```bash
git add scenes/main_menu/main_menu.gd scenes/main_menu/main_menu.tscn
git commit -m "feat(s3): MainMenu scene with title, stats, new/continue buttons"
```

---

### Task A.2: Update main.gd to show MainMenu

**Objective:** Replace auto-load of BattleScene with MainMenu.

**Files:**
- Modify: `scenes/main.gd` (entire file, ~10 lines)

**Step 1: Write new main.gd**

```gdscript
extends Node
## Корневой узел. Загружает MainMenu — игрок выбирает New Run или Continue.

func _ready() -> void:
    var scene: PackedScene = load("res://scenes/main_menu/main_menu.tscn") as PackedScene
    if scene == null:
        push_error("Failed to load main_menu scene")
        return
    var inst: Node = scene.instantiate()
    add_child(inst)
```

**Step 2: Verify**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --editor --quit 2>&1 | grep -iE "error|parse" | head -3`
Expected: clean parse.

**Step 3: Run tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 471 passed, 0 failed ===` (no regression).

**Step 4: Commit**

```bash
git add scenes/main.gd
git commit -m "feat(s3): main.gd загружает MainMenu вместо BattleScene"
```

---

### Task A.3: Update BattleScene to read initial_seed metadata

**Objective:** When BattleScene loads from MainMenu, read `packed.get_meta("initial_seed")` and pass to run_controller.

**Files:**
- Modify: `scenes/battle/battle_scene.gd:110` (replace `run_controller.start_run(42)`)

**Step 1: Find current line**

Run: `grep -n "start_run(42)" "C:/Users/user/Documents/GodotProjects/RogueAutoBattler/scenes/battle/battle_scene.gd"`

**Step 2: Replace line 110**

Find: `run_controller.start_run(42)`
Replace:
```gdscript
var initial_seed: int = 0
if has_meta("initial_seed"):
    initial_seed = int(get_meta("initial_seed"))
if initial_seed == 0:
    initial_seed = Rng.randi_range(1, 999999)
run_controller.start_run(initial_seed)
```

Note: replace literal `42` with this 6-line block.

**Step 3: Run tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 471 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add scenes/battle/battle_scene.gd
git commit -m "feat(s3): BattleScene reads initial_seed metadata"
```

---

### Task A.4: Add MainMenu tests

**Objective:** Test MainMenu creates buttons, dispatches New Run, shows/hides Continue.

**Files:**
- Modify: `tests/run_tests.gd` (append new test functions)

**Step 1: Add const + test invocations**

In `tests/run_tests.gd` near the existing const block (around line 77), add:
```gdscript
const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")
```

In the `_run_all_tests()` function, add 3 new test calls:
```gdscript
_test_main_menu_creates_buttons()
_test_main_menu_continue_hidden_when_no_seed()
_test_main_menu_continue_visible_after_save()
```

**Step 2: Write the test functions** (append at end of file)

```gdscript
func _test_main_menu_creates_buttons() -> void:
    print("[test] Sprint 3: MainMenu creates title and buttons")
    var menu: Control = MainMenuScript.new()
    get_root().add_child(menu)
    _assert(menu._new_run_button != null, "New Run button created")
    _assert(menu._continue_button != null, "Continue button created")
    _assert(menu._stats_label != null, "Stats label created")
    _assert(menu._profile != null, "Profile loaded (or fresh) on _ready")


func _test_main_menu_continue_hidden_when_no_seed() -> void:
    print("[test] Sprint 3: MainMenu hides Continue when current_run_seed=0")
    # Use fresh profile (no saved run).
    var fresh: MetaProfile = MetaProfileScript.new()
    fresh.current_run_seed = 0
    SaveService.save_meta(fresh)
    var menu: Control = MainMenuScript.new()
    get_root().add_child(menu)
    _assert(not menu._continue_button.visible, "Continue hidden when seed=0")


func _test_main_menu_continue_visible_after_save() -> void:
    print("[test] Sprint 3: MainMenu shows Continue when current_run_seed!=0")
    var profile: MetaProfile = MetaProfileScript.new()
    profile.current_run_seed = 12345
    SaveService.save_meta(profile)
    var menu: Control = MainMenuScript.new()
    get_root().add_child(menu)
    _assert(menu._continue_button.visible, "Continue visible when seed=12345")
```

**Step 3: Run new tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 474 passed, 0 failed ===` (471 + 3 new).

**Step 4: Commit**

```bash
git add tests/run_tests.gd
git commit -m "test(s3): MainMenu creates buttons, continue visibility"
```

---

## Part B: Tier metadata в .tres

### Task B.1: Add tier=1 to starter units

**Objective:** Add `tier = 1` field to warrior, archer, mage, cleric .tres files.

**Files:**
- Modify: `content/units/warrior.tres` (add tier line)
- Modify: `content/units/archer.tres`
- Modify: `content/units/mage.tres`
- Modify: `content/units/cleric.tres`

**Step 1: Read one .tres to understand format**

Run: `head -30 "C:/Users/user/Documents/GodotProjects/RogueAutoBattler/content/units/warrior.tres"`

**Step 2: Add tier=1 to each file**

For each of the 4 files:
1. Read full file
2. Find `tier = 0` or no tier line
3. Add or modify to `tier = 1`

**Step 3: Verify tier loaded**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 474 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add content/units/warrior.tres content/units/archer.tres content/units/mage.tres content/units/cleric.tres
git commit -m "chore(content): tier=1 for starter units (warrior, archer, mage, cleric)"
```

---

### Task B.2: Add tier=2 to mid units

**Objective:** Add `tier = 2` to guardian, assassin, druid, berserker, beast, cavalry, warrior_v2, knight.

**Files:**
- Modify: `content/units/{guardian,assassin,druid,berserker,beast,cavalry,warrior_v2,knight}.tres` (8 files)

**Step 1: Read first .tres to understand**

Same as B.1 step 1.

**Step 2: Add tier=2 to each**

Same pattern as B.1, but tier=2.

**Step 3: Verify**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 474 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add content/units/{guardian,assassin,druid,berserker,beast,cavalry,warrior_v2,knight}.tres
git commit -m "chore(content): tier=2 for 8 mid-tier units"
```

---

### Task B.3: Add tier=3 to late units

**Objective:** Add `tier = 3` to paladin, necromancer, elementalist.

**Files:**
- Modify: `content/units/{paladin,necromancer,elementalist}.tres` (3 files)

**Step 1: Add tier=3**

Same pattern as B.1/B.2.

**Step 2: Verify**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 474 passed, 0 failed ===`.

**Step 3: Commit**

```bash
git add content/units/{paladin,necromancer,elementalist}.tres
git commit -m "chore(content): tier=3 for 3 late units (paladin, necromancer, elementalist)"
```

---

### Task B.4: Add UnitsMeta tier tests

**Objective:** Test that `UnitsMeta.ids_by_tier(tier)` returns correct pools.

**Files:**
- Modify: `tests/run_tests.gd` (append 1 test function)

**Step 1: Add test invocation**

In `_run_all_tests()`, add:
```gdscript
_test_units_meta_tier_pools()
```

**Step 2: Write test function**

```gdscript
func _test_units_meta_tier_pools() -> void:
    print("[test] Sprint 3: UnitsMeta.ids_by_tier returns expected pools")
    ContentDB_static.load_all()
    var tier1: Array = UnitsMeta.ids_by_tier(1)
    var tier2: Array = UnitsMeta.ids_by_tier(2)
    var tier3: Array = UnitsMeta.ids_by_tier(3)
    _assert(tier1.size() == 4, "tier 1 has 4 units (got %d)" % tier1.size())
    _assert(tier2.size() == 8, "tier 2 has 8 units (got %d)" % tier2.size())
    _assert(tier3.size() == 3, "tier 3 has 3 units (got %d)" % tier3.size())
    # Проверяем что starter unitы в tier=1.
    _assert(&"warrior" in tier1, "warrior is tier 1")
    _assert(&"archer" in tier1, "archer is tier 1")
    # Paladin в tier=3.
    _assert(&"paladin" in tier3, "paladin is tier 3")
```

**Step 3: Run tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 475 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add tests/run_tests.gd
git commit -m "test(s3): UnitsMeta tier pools (4/8/3 units)"
```

---

## Part C: Settings UI

### Task C.1: Add Settings button + battle_speed toggle to MainMenu

**Objective:** Add Settings button on MainMenu that opens a panel with battle_speed (1x/2x/4x) toggle, persisted to MetaProfile.

**Files:**
- Modify: `scenes/main_menu/main_menu.gd` (extend with Settings)
- Modify: `scenes/main_menu/main_menu.gd` (add `_build_settings_panel()` + handlers)

**Step 1: Extend main_menu.gd with Settings**

Add after `_continue_button` block in `vbox_for_menu()`:

```gdscript
var _settings_button: Button = null
var _settings_panel: PanelContainer = null
var _speed_1_button: Button = null
var _speed_2_button: Button = null
var _speed_4_button: Button = null

# В vbox_for_menu() после _continue_button.add_child:
_settings_button = _make_button("Settings", _on_settings_pressed, Color(0.20, 0.30, 0.40))
vbox.add_child(_settings_button)
```

Add new method after `_make_button`:
```gdscript
func _on_settings_pressed() -> void:
    _toggle_settings_panel()


func _toggle_settings_panel() -> void:
    if _settings_panel == null:
        _build_settings_panel()
    _settings_panel.visible = not _settings_panel.visible
    if _settings_panel.visible:
        _refresh_speed_buttons()


func _build_settings_panel() -> void:
    _settings_panel = PanelContainer.new()
    _settings_panel.visible = false
    var sb: StyleBoxFlat = StyleBoxFlat.new()
    sb.bg_color = Color(0.10, 0.14, 0.22, 0.96)
    sb.border_color = Color(0.55, 0.65, 0.85, 0.9)
    sb.set_border_width_all(2)
    sb.set_corner_radius_all(12)
    _settings_panel.add_theme_stylebox_override("panel", sb)
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 12)
    _settings_panel.add_child(vbox)
    var title: Label = Label.new()
    title.text = "Battle Speed"
    title.add_theme_font_size_override("font_size", 20)
    title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
    vbox.add_child(title)
    var hbox: HBoxContainer = HBoxContainer.new()
    hbox.add_theme_constant_override("separation", 8)
    hbox.alignment = BoxContainer.ALIGNMENT_CENTER
    _speed_1_button = _make_small_button("1x", _on_speed_1_pressed)
    _speed_2_button = _make_small_button("2x", _on_speed_2_pressed)
    _speed_4_button = _make_small_button("4x", _on_speed_4_pressed)
    hbox.add_child(_speed_1_button)
    hbox.add_child(_speed_2_button)
    hbox.add_child(_speed_4_button)
    vbox.add_child(hbox)
    _settings_panel.set_anchors_preset(Control.PRESET_CENTER)
    add_child(_settings_panel)


func _make_small_button(text: String, callback: Callable) -> Button:
    var btn: Button = Button.new()
    btn.text = text
    btn.custom_minimum_size = Vector2(60, 40)
    btn.add_theme_font_size_override("font_size", 16)
    btn.pressed.connect(callback)
    return btn


func _on_speed_1_pressed() -> void:
    _set_speed(1.0)


func _on_speed_2_pressed() -> void:
    _set_speed(2.0)


func _on_speed_4_pressed() -> void:
    _set_speed(4.0)


func _set_speed(s: float) -> void:
    if _profile == null:
        return
    _profile.battle_speed = s
    SaveService.save_meta(_profile)
    _refresh_speed_buttons()


func _refresh_speed_buttons() -> void:
    if _profile == null:
        return
    var current: float = _profile.battle_speed
    for btn in [_speed_1_button, _speed_2_button, _speed_4_button]:
        if btn == null:
            continue
        var is_current: bool = (
            (btn == _speed_1_button and current == 1.0)
            or (btn == _speed_2_button and current == 2.0)
            or (btn == _speed_4_button and current == 4.0)
        )
        var sb: StyleBoxFlat = StyleBoxFlat.new()
        sb.bg_color = Color(0.40, 0.55, 0.40) if is_current else Color(0.30, 0.30, 0.40)
        sb.set_corner_radius_all(6)
        btn.add_theme_stylebox_override("normal", sb)
```

**Step 2: Verify parse**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --editor --quit 2>&1 | grep -iE "error|parse" | head -3`
Expected: clean.

**Step 3: Run tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 475 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add scenes/main_menu/main_menu.gd
git commit -m "feat(s3): Settings panel with battle_speed toggle"
```

---

### Task C.2: Apply battle_speed to BattleScene

**Objective:** When BattleScene starts, read `profile.battle_speed` and apply as initial `speed` value.

**Files:**
- Modify: `scenes/battle/battle_scene.gd` (find `var speed = 1.0` declaration, apply from profile)

**Step 1: Find current speed init**

Run: `grep -n "^var speed\|var speed = " "C:/Users/user/Documents/GodotProjects/RogueAutoBattler/scenes/battle/battle_scene.gd" | head -5`

Expected: `var speed = 1.0` somewhere in early declaration.

**Step 2: After _ready() main run_controller setup**

Find the section where `run_controller.start_run()` is called. After that line, add:
```gdscript
if run_controller != null and run_controller.profile != null:
    speed = run_controller.profile.battle_speed
```

**Step 3: Run tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 475 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add scenes/battle/battle_scene.gd
git commit -m "feat(s3): BattleScene respects profile.battle_speed"
```

---

### Task C.3: Add Settings persistence test

**Objective:** Test that speed button saves to MetaProfile.

**Files:**
- Modify: `tests/run_tests.gd` (append 1 test)

**Step 1: Add test invocation**

In `_run_all_tests()`, add:
```gdscript
_test_settings_persists_battle_speed()
```

**Step 2: Write test function**

```gdscript
func _test_settings_persists_battle_speed() -> void:
    print("[test] Sprint 3: Settings persists battle_speed to MetaProfile")
    var profile: MetaProfile = MetaProfileScript.new()
    profile.battle_speed = 4.0
    SaveService.save_meta(profile)
    var loaded: MetaProfile = SaveService.load_meta()
    _assert(loaded != null, "profile reloaded")
    _assert(loaded.battle_speed == 4.0, "battle_speed persisted (got %s)" % str(loaded.battle_speed))
```

**Step 3: Run tests**

Run: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
Expected: `=== Result: 476 passed, 0 failed ===`.

**Step 4: Commit**

```bash
git add tests/run_tests.gd
git commit -m "test(s3): battle_speed persists to MetaProfile"
```

---

## Part D: Deployment

### Task D.1: Push to GitHub and verify deployment

**Objective:** Push changes to GitHub, GitHub Actions builds and deploys.

**Files:** none (git operation)

**Step 1: Push**

```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
gh auth switch --user Llayon  # if not active
git push
```

Expected: `To https://github.com/Llayon/rogue-autobattler2.git ... master -> master`

**Step 2: Wait for workflow**

```bash
for i in 1 2 3 4 5 6 7 8; do
    sleep 30
    LATEST=$(curl -s --max-time 10 -H "Authorization: token $(gh auth token)" "https://api.github.com/repos/Llayon/rogue-autobattler2/actions/runs?per_page=1" | python -c "import json,sys; d=json.loads(sys.stdin.read()); r=d['workflow_runs'][0]; print(f\"#{r['run_number']} {r['status']} {r['conclusion']}\")")
    echo "$i*30s: $LATEST"
    if echo "$LATEST" | grep -q "success"; then break; fi
done
```

Expected: latest run = success.

**Step 3: Verify site accessible**

```bash
curl -s -o /dev/null -w "%{http_code}" "https://llayon.github.io/rogue-autobattler2/"
```

Expected: `200`.

**Step 4: No commit (just verification)**

---

## Files likely to change

**New**:
- `scenes/main_menu/main_menu.gd` (~140 lines with Settings)
- `scenes/main_menu/main_menu.tscn` (~15 lines)

**Modified**:
- `scenes/main.gd` (10 lines, swap to MainMenu)
- `scenes/battle/battle_scene.gd` (2-3 lines: read metadata + apply speed)
- `content/units/warrior.tres`, `archer.tres`, `mage.tres`, `cleric.tres` (tier=1, ~1 line each)
- `content/units/guardian.tres`, `assassin.tres`, `druid.tres`, `berserker.tres`, `beast.tres`, `cavalry.tres`, `warrior_v2.tres`, `knight.tres` (tier=2, ~1 line each)
- `content/units/paladin.tres`, `necromancer.tres`, `elementalist.tres` (tier=3, ~1 line each)
- `tests/run_tests.gd` (~80 lines added: 5 new test functions)

**Total**: 18 files changed, 11 commits.

---

## Tests / validation

- **Suite check after each task**: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | grep -E "Result" | tail -1`
- **Editor-mode check**: `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --editor --quit 2>&1 | grep -iE "error|parse" | head -3`
- **Live site check**: `curl -s -o /dev/null -w "%{http_code}" "https://llayon.github.io/rogue-autobattler2/"`

**Final expected**: 476/476 tests passing, editor clean, site = 200, MainMenu visible.

---

## Risks, tradeoffs, open questions

1. **Tier field default**: `@export var tier: int = 1` is default. Existing tests assume specific behavior. Adding tier to .tres shouldn't break anything but **verify tests pass** after each batch.

2. **`current_run_seed` persists forever**: If player loses mid-run with seed=12345, then opens game, profile.current_run_seed=12345. Continue button → resume. But if 30 days passed, want to start fresh? Out of scope for v1.

3. **`SaveService.save_meta` on every speed click**: Could batch. Out of scope (low frequency).

4. **Settings persistence path**: `user://profile.json` on Windows. Web export uses IndexedDB-equivalent (Godot's virtual FS). Save tests use `dir_access` so may need adjustment. **Verify tests pass** on disk and trust it works in Web (proven in previous sprint).

5. **BattleScene transition**: Current plan uses `queue_free` + `add_child` which clears all children including autoloads. Autoloads have names starting with "@" so they're spared. But this is fragile — **consider cleaner approach if transition has issues**.

6. **No settings for sound yet**: Sound toggle out of scope. Profile already has `show_damage_numbers` field; could add similar UI for it in future sprint.

7. **No tier for goblin_archer, orc_warrior etc**: Enemies are tier-agnostic (always enemy pool). Only player-facing units need tiers. Tier field is on UnitDef (which enemies also use). Could add tier to enemy .tres for completeness but not strictly required.

---

## Execution handoff

Plan complete. 11 tasks, ~3-4 hours of focused work, all bite-sized (2-5 min each), TDD-driven where code changes.

**Ready to execute using subagent-driven-development skill** — each task dispatched to fresh subagent with two-stage review (spec compliance then code quality). Shall I proceed?