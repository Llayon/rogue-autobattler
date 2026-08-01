# Sprint 4.2 + Reactions + Meta-progression Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Polish UI + add reaction system + meta-progression persistence.

**Architecture:**
- **Sprint 4.2**: SceneTree-driven UI overlay (`scenes/battle/ui_overlay.tscn`) renders HP-bars, cooldown rings, status icons on top of `battle_view`. Uses `_process()` polling to track combatant state changes.
- **Reactions**: Event-driven via `GameBus`. `ReactionSystem` (new autoload) listens to `unit_move_start`, `unit_attacked`, etc. Triggers `unit_attacked` with `shield_block` reaction.
- **Meta-progression**: Extend `MetaProfile` with `unlocked_units: Array[StringName]`. Save to `user://saves/meta.tres` on win. Pre-game UI loads profile and filters available units.

**Tech Stack:** Godot 4.7, GDScript 2.0, Resource (.tres), RefCounted / Node, autoload pattern.

**Current state:** 129 tests passing, 14 units, 5 enemies, 10 abilities, DoS system ready (not integrated).

---

## Part 1: Sprint 4.2 — Battle UI Overlays

### Task 1.1: Create UI overlay scene structure

**Objective:** Add a UI overlay scene that renders HP/cooldown/status icons on top of existing battle_view.

**Files:**
- Create: `scenes/battle/ui_overlay.tscn`
- Create: `scenes/battle/ui_overlay.gd`

**Step 1:** Create scene file `scenes/battle/ui_overlay.tscn`:

```gdscript
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://scenes/battle/ui_overlay.gd" id="1"]

[node name="UIOverlay" type="Control"]
script = ExtResource("1")
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
mouse_filter = 2
```

**Step 2:** Create `scenes/battle/ui_overlay.gd`:

```gdscript
class_name UIOverlay extends Control
## Overlay layer on top of battle_view. Renders HP-bars, cooldowns, status icons.
##
## Hooks into BattleScene via _ready() — gets ctx reference and listens to EventBus.

const BattleContextScript = preload("res://core/battle/battle_context.gd")

var _ctx: BattleContext = null


func _ready() -> void:
	# Подключаемся к GameBus через EventBus autoload.
	var bus = get_node_or_null("/root/EventBus")
	if bus != null:
		bus.unit_damaged.connect(_on_unit_damaged)
		bus.unit_died.connect(_on_unit_died)
		bus.status_changed.connect(_on_status_changed)
		bus.ability_cast.connect(_on_ability_cast)
	queue_redraw()


func set_context(ctx: BattleContext) -> void:
	_ctx = ctx
	queue_redraw()


func _process(_delta: float) -> void:
	# Постоянная перерисовка прогресс-баров (mana, cooldown, hp).
	queue_redraw()


func _on_unit_damaged(_c, _amount: int, _source) -> void:
	queue_redraw()


func _on_unit_died(_c) -> void:
	queue_redraw()


func _on_status_changed(_c, _status_id: StringName, _applied: bool) -> void:
	queue_redraw()


func _on_ability_cast(_ability, _caster, _target) -> void:
	queue_redraw()


func _draw() -> void:
	if _ctx == null:
		return
	_draw_hp_bars()
	_draw_cooldown_rings()
	_draw_status_icons()


func _draw_hp_bars() -> void:
	# Тонкая плашка 4px под каждой клеткой с HP.
	for c in _ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		var cell: Vector2i = c.cell
		var pos: Vector2 = _cell_to_screen(cell, Vector2(60, 60))
		var hp_ratio: float = float(c.health.current_hp) / float(maxi(1, c.max_hp()))
		var bar_w: float = 60.0 * hp_ratio
		draw_rect(Rect2(pos.x, pos.y + 60, 60, 4), Color(0.2, 0.2, 0.2, 0.8))
		draw_rect(Rect2(pos.x, pos.y + 60, bar_w, 4), Color(0.2, 0.9, 0.3))


func _draw_cooldown_rings() -> void:
	# Тонкий индикатор кулдауна над кастером (закруглённый квадрат).
	for c in _ctx.all_combatants():
		if c == null or c.abilities == null:
			continue
		var pos: Vector2 = _cell_to_screen(c.cell, Vector2(60, 60))
		for i in c.abilities.size():
			var ab: Resource = c.abilities[i]
			if ab == null:
				continue
			var remaining: float = c.cooldown_remaining(ab)
			if remaining <= 0.0:
				continue
			# Полоска над юнитом.
			var bar_y: float = pos.y - 6 + i * 4
			var total_cd: float = ab.cooldown
			var cd_ratio: float = 1.0 - (remaining / maxf(0.1, total_cd))
			draw_rect(Rect2(pos.x, bar_y, 60 * cd_ratio, 2), Color(0.4, 0.6, 1.0))


func _draw_status_icons() -> void:
	# Маленькие цветные точки справа от юнита.
	for c in _ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		var statuses: Array = c.active_statuses()
		var pos: Vector2 = _cell_to_screen(c.cell, Vector2(60, 60))
		for i in statuses.size():
			var s: Dictionary = statuses[i]
			var color: Color = _status_color(s.def)
			draw_circle(Vector2(pos.x + 62 + i * 5, pos.y + 8), 2.0, color)


func _status_color(status_def: Resource) -> Color:
	if status_def == null:
		return Color.GRAY
	# Хорошие — зелёный, плохие — красный, нейтральные — жёлтый.
	if status_def.is_harmful:
		return Color(1.0, 0.3, 0.3)
	elif status_def.blocks_actions:
		return Color(1.0, 0.8, 0.0)
	else:
		return Color(0.3, 0.9, 0.3)


func _cell_to_screen(cell: Vector2i, cell_size: Vector2) -> Vector2:
	# Grid 7x4, центрированная.
	var grid_w: float = 7.0 * cell_size.x
	var grid_h: float = 4.0 * cell_size.y
	var origin_x: float = (size.x - grid_w) / 2.0
	var origin_y: float = (size.y - grid_h) / 2.0
	return Vector2(origin_x + cell.x * cell_size.x, origin_y + cell.y * cell_size.y)
```

**Step 3:** Run tests: `/tmp/godot47.exe --headless --path . --script tests/run_tests.gd` — expected 129/129.

**Step 4:** Add overlay to battle_scene.tscn. Open `scenes/battle/battle_scene.tscn` and add `[node name="UIOverlay" parent="." instance=ExtResource("overlay")]` to references.

**Step 5:** Commit: `git add scenes/battle/ui_overlay.gd scenes/battle/ui_overlay.tscn scenes/battle/battle_scene.tscn && git commit -m "feat(ui): draw HP-bars, cooldown rings, status icons via UIOverlay"`

---

### Task 1.2: Hook UIOverlay into BattleScene lifecycle

**Objective:** Set overlay context when battle starts, clear when it ends.

**Files:**
- Modify: `scenes/battle/battle_scene.gd`

**Step 1:** Find `_ready()` in `scenes/battle/battle_scene.gd` and add overlay init:

```gdscript
var ui_overlay: Control = null

func _ready() -> void:
	ui_overlay = $UIOverlay
```

**Step 2:** Find where `_on_battle_started` sets `run_controller` and add `ui_overlay.set_context(ctx)`:

```gdscript
func _on_battle_started() -> void:
	ui_overlay.set_context(run_controller.ctx)
```

**Step 3:** Find `_on_battle_ended` and add `ui_overlay.set_context(null)`:

```gdscript
func _on_battle_ended(_winner: int) -> void:
	ui_overlay.set_context(null)
```

**Step 4:** Run tests: `godot --script tests/run_tests.gd` — expected 129/129.

**Step 5:** Commit: `git add scenes/battle/battle_scene.gd && git commit -m "feat(ui): hook UIOverlay to battle start/end lifecycle"`

---

## Part 2: Reactions System

### Task 2.1: ReactionDef + ReactionSystem infrastructure

**Objective:** Define data shape for reactions and dispatcher logic.

**Files:**
- Create: `core/data/reaction_def.gd`
- Create: `core/reactions/reaction_system.gd`
- Create: `core/reactions/reaction_system_autoload.gd`

**Step 1:** Create `core/data/reaction_def.gd`:

```gdscript
class_name ReactionDef extends Resource
## Описание реакции: когда срабатывает, что делает.
##
## Примеры:
## - AoO (Attack of Opportunity): когда враг выходит из клетки рядом — атаковать.
## - Shield Block: при входящем уроне — шанс 30% заблокировать 50%.
## - Reactive Strike: при атаке на союзника — контратака.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

# Триггер: какой GameBus сигнал активирует.
# "unit_attacked", "unit_move_start", "round_started".
@export var trigger: StringName = &"unit_attacked"

# Шанс срабатывания (0.0-1.0).
@export var trigger_chance: float = 1.0

# Дополнительные фильтры (например, only melee).
@export var melee_only: bool = false
@export var range_cells: int = 1
```

**Step 2:** Create `core/reactions/reaction_system.gd`:

```gdscript
class_name ReactionSystem extends RefCounted
## Слушает GameBus и проверяет, есть ли у reactor-а подходящая реакция.
##
## Не знает про Effects — возвращает trigger, а UI/Combatant решает что делать.

var _reactions: Dictionary = {}  # combatant.id → Array[ReactionDef]


func register_reaction(combatant, reaction: ReactionDef) -> void:
	if combatant == null or reaction == null:
		return
	var id: StringName = combatant.def_id
	if not _reactions.has(id):
		_reactions[id] = []
	_reactions[id].append(reaction)


func unregister_all(combatant) -> void:
	if combatant == null:
		return
	_reactions.erase(combatant.def_id)


## Возвращает первую реакцию, которая срабатывает на это событие.
## Не вызывает никаких эффектов — только проверяет условия.
func poll_reaction(
	combatant,  # кто реагирует
	trigger: StringName,  # "unit_attacked", и т.д.
	trigger_data: Dictionary  # {"attacker": X, "target": Y, "damage": N}
) -> ReactionDef:
	if combatant == null:
		return null
	var id: StringName = combatant.def_id
	if not _reactions.has(id):
		return null
	for reaction in _reactions[id]:
		if reaction.trigger != trigger:
			continue
		if not Roll.chance(reaction.trigger_chance):
			continue
		return reaction
	return null
```

**Step 3:** Create `core/reactions/reaction_system_autoload.gd`:

```gdscript
extends "res://core/reactions/reaction_system.gd"
## Autoload-обёртка. Регистрируется как "ReactionSystem".
```

**Step 4:** Register autoload in `project.godot` under `[autoload]`:

```ini
ReactionSystem="*res://core/reactions/reaction_system_autoload.gd"
```

**Step 5:** Run tests: `godot --script tests/run_tests.gd` — expected 129/129.

**Step 6:** Commit: `git add core/data/reaction_def.gd core/reactions/reaction_system.gd core/reactions/reaction_system_autoload.gd project.godot && git commit -m "feat(reactions): ReactionDef + ReactionSystem infrastructure"`

---

### Task 2.2: Attack of Opportunity reaction

**Objective:** When an enemy MOVES out of adjacent cell, attacker gets free attack.

**Files:**
- Create: `content/reactions/attack_of_opportunity.tres`
- Modify: `core/progression/run_controller.gd`

**Step 1:** Create `content/reactions/attack_of_opportunity.tres`:

```gdscript
[gd_resource type="Resource" script_class="ReactionDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://core/data/reaction_def.gd" id="1_reactiondef"]

[resource]
script = ExtResource("1_reactiondef")
id = &"attack_of_opportunity"
display_name = "Атака по возможности"
description = "Когда враг выходит из соседней клетки, контратакует."
trigger = &"unit_move_start"
trigger_chance = 1.0
melee_only = true
range_cells = 1
```

**Step 2:** Find `_spawn_enemy_wave` in `core/progression/run_controller.gd` and add reaction registration:

```gdscript
func _spawn_enemy_wave(round_index: int) -> Array:
	# ... existing code ...
	for i in n:
		# ... existing spawn code ...
		if combatant == null:
			continue
		# Регистрируем AoO для врагов.
		if combatant.def_id in [&"orc_warrior", &"knight", &"paladin"]:
			var aoo: Resource = ContentDB_static.get_by_id(&"attack_of_opportunity")
			if aoo != null:
				GameBus.emit_reaction_registered(combatant, aoo)
	return result
```

**Step 3:** Add `emit_reaction_registered` to `core/utils/event_bus.gd` static helpers:

```gdscript
signal reaction_registered(combatant, reaction: Resource)

static func emit_reaction_registered(combatant, reaction: Resource) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reaction_registered.emit(combatant, reaction)
```

**Step 4:** Add unit_move_start signal + helper:

```gdscript
signal unit_move_start(combatant, target_cell: Vector2i)

static func emit_unit_move_start(combatant, target_cell: Vector2i) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.unit_move_start.emit(combatant, target_cell)
```

**Step 5:** Hook emit_unit_move_start into `BattleContext.move_to`:

```gdscript
func move_to(combatant, new_cell: Vector2i) -> bool:
	# ... existing checks ...
	if move_to_internal(combatant, new_cell):
		GameBus.emit_unit_move_start(combatant, new_cell)
		return true
	return false
```

**Step 6:** Run tests: `godot --script tests/run_tests.gd` — expected 129/129.

**Step 7:** Commit: `git add content/reactions/attack_of_opportunity.tres core/progression/run_controller.gd core/utils/event_bus.gd core/battle/battle_context.gd && git commit -m "feat(reactions): Attack of Opportunity registered for orc/knight/paladin"`

---

### Task 2.3: Shield Block reaction

**Objective:** When allied unit receives damage, caster has chance to absorb 50% with shield.

**Files:**
- Create: `content/reactions/shield_block.tres`
- Modify: `core/effects/damage_effect.gd`

**Step 1:** Create `content/reactions/shield_block.tres`:

```gdscript
[gd_resource type="Resource" script_class="ReactionDef" load_steps=2 format=3]

[ext_resource type="Script" path="res://core/data/reaction_def.gd" id="1_reactiondef"]

[resource]
script = ExtResource("1_reactiondef")
id = &"shield_block"
display_name = "Блок щитом"
description = "Шанс 30% заблокировать 50% входящего урона."
trigger = &"unit_attacked"
trigger_chance = 0.3
melee_only = false
range_cells = 1
```

**Step 2:** Find `apply` in `core/effects/damage_effect.gd` and add reaction check:

```gdscript
func apply(ctx, source, targets: Array) -> Array:
	# ... existing pre-checks ...
	for t in targets:
		# ... existing dodge check ...
		# NEW: Shield Block reaction.
		var reaction_sys = _get_reaction_system()
		if reaction_sys != null:
			var reaction: Resource = reaction_sys.poll_reaction(t, &"unit_attacked", {"attacker": source})
			if reaction != null and reaction.id == &"shield_block":
				amount = maxi(1, amount / 2)
				GameBus.emit_reaction_triggered(t, reaction)
		# ... existing damage application ...
	return results


func _get_reaction_system():
	# Autoload instance lookup.
	if Engine.has_singleton("ReactionSystem"):
		return Engine.get_singleton("ReactionSystem")
	return get_node_or_null("/root/ReactionSystem")
```

**Step 3:** Add `emit_reaction_triggered`:

```gdscript
signal reaction_triggered(combatant, reaction: Resource)

static func emit_reaction_triggered(combatant, reaction: Resource) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reaction_triggered.emit(combatant, reaction)
```

**Step 4:** Register Shield Block for paladin and guardian on spawn:

```gdscript
# В _spawn_enemy_wave после spawn:
if combatant.def_id in [&"paladin", &"guardian"]:
	var sb: Resource = ContentDB_static.get_by_id(&"shield_block")
	if sb != null:
		GameBus.emit_reaction_registered(combatant, sb)
```

**Step 5:** Hook reaction_registered в ReactionSystem autoload's `_ready()`:

```gdscript
func _ready() -> void:
	var bus = get_node_or_null("/root/EventBus")
	if bus != null:
		bus.reaction_registered.connect(_on_reaction_registered)


func _on_reaction_registered(combatant, reaction: Resource) -> void:
	register_reaction(combatant, reaction)
```

**Step 6:** Run tests: `godot --script tests/run_tests.gd` — expected 129/129.

**Step 7:** Add 5 tests for reactions:

```gdscript
func _test_reaction_def_loaded() -> void:
	print("[test] ReactionDef loads")
	var aoo: Resource = ContentDB_static.get_by_id(&"attack_of_opportunity")
	_assert(aoo != null and aoo.trigger == &"unit_move_start", "AoO loads with correct trigger")
	var sb: Resource = ContentDB_static.get_by_id(&"shield_block")
	_assert(sb != null and sb.trigger_chance == 0.3, "ShieldBlock loads with chance 0.3")


func _test_reaction_system_register() -> void:
	print("[test] ReactionSystem.register + poll")
	var sys: ReactionSystem = ReactionSystem.new()
	var attacker = CombatantScript.new(_make_unit_def(&"a", 100, 10))
	var attacker_id: StringName = attacker.def_id
	sys.register_reaction(attacker, ContentDB_static.get_by_id(&"attack_of_opportunity"))
	# Не должно сработать на другой триггер.
	var r1: Resource = sys.poll_reaction(attacker, &"unit_attacked", {})
	_assert(r1 == null, "AoO не сработал на unit_attacked")
	# Должно сработать на правильный триггер.
	var r2: Resource = sys.poll_reaction(attacker, &"unit_move_start", {})
	_assert(r2 != null and r2.id == &"attack_of_opportunity", "AoO сработал на unit_move_start")
	sys.unregister_all(attacker)
	var r3: Resource = sys.poll_reaction(attacker, &"unit_move_start", {})
	_assert(r3 == null, "после unregister_all нет реакции")
```

**Step 8:** Add ReactionSystem const + test invocations + cleanup.

**Step 9:** Run tests: `godot --script tests/run_tests.gd` — expected 134/134.

**Step 10:** Commit: `git add -A && git commit -m "feat(reactions): Shield Block + 5 tests for reaction system"`

---

## Part 3: Meta-progression

### Task 3.1: Extend MetaProfile with unlocked_units

**Objective:** Persist which units player has unlocked between sessions.

**Files:**
- Modify: `core/progression/meta_profile.gd`

**Step 1:** Read `core/progression/meta_profile.gd` and add `unlocked_units` field:

```gdscript
@export var unlocked_units: Array[StringName] = [&"warrior", &"archer", &"mage"]
@export var total_wins: int = 0
@export var total_losses: int = 0
```

**Step 2:** Add unlock_unit method:

```gdscript
func unlock_unit(unit_id: StringName) -> void:
	if not unlocked_units.has(unit_id):
		unlocked_units.append(unit_id)
```

**Step 3:** Save/load methods (already exist, verify they handle unlocked_units):

```gdscript
func to_dict() -> Dictionary:
	return {
		"unlocked_units": Array(unlocked_units),
		"total_wins": total_wins,
		"total_losses": total_losses,
	}


func from_dict(d: Dictionary) -> void:
	unlocked_units = []
	for s in d.get("unlocked_units", [&"warrior", &"archer", &"mage"]):
		unlocked_units.append(StringName(s))
	total_wins = int(d.get("total_wins", 0))
	total_losses = int(d.get("total_losses", 0))
```

**Step 4:** Run tests: `godot --script tests/run_tests.gd` — expected 134/134.

**Step 5:** Commit: `git add core/progression/meta_profile.gd && git commit -m "feat(meta): MetaProfile tracks unlocked_units + total_wins/losses"`

---

### Task 3.2: UnlockManager

**Objective:** Logic for unlocking units based on wins, persistent across runs.

**Files:**
- Create: `core/progression/unlock_manager.gd`

**Step 1:** Create `core/progression/unlock_manager.gd`:

```gdscript
class_name UnlockManager extends RefCounted
## Менеджер разблокировки юнитов. Делает unlock progression fun.
##
## v1: каждые 3 победы разблокируется следующий юнит по списку.
## v2: tie to specific achievements (win with no losses, beat boss, etc).

const UNLOCK_ORDER: Array[StringName] = [
	&"warrior", &"archer", &"mage",  # стартовые
	&"cleric", &"guardian", &"rogue", &"beast",
	&"druid", &"paladin", &"elementalist", &"necromancer",
	&"assassin", &"knight", &"berserker", &"cavalry",
]

const UNLOCKS_PER_WINS: int = 2  # каждые 2 победы → новый юнит.


static func calculate_unlocks(profile: Resource) -> Array[StringName]:
	# Возвращает новые юниты для разблокировки на основе total_wins.
	var should_have: Array[StringName] = UNLOCK_ORDER.duplicate()
	var already_unlocked: Array = profile.unlocked_units if profile != null else []
	var available: Array[StringName] = []
	if profile == null:
		return []
	var target_count: int = 3 + profile.total_wins / UNLOCKS_PER_WINS
	for i in range(3, min(target_count, UNLOCK_ORDER.size())):
		var unit_id: StringName = UNLOCK_ORDER[i]
		if not already_unlocked.has(unit_id):
			available.append(unit_id)
	return available


static func apply_pending_unlocks(profile: Resource) -> void:
	if profile == null:
		return
	var new_units: Array = calculate_unlocks(profile)
	for unit_id in new_units:
		profile.unlock_unit(unit_id)
```

**Step 2:** Hook into `RunController._on_battle_ended`:

```gdscript
func _on_battle_ended() -> void:
	var winner: int = runner.state.winner_team
	if winner == 0:
		state.wins += 1
		profile.total_wins += 1
		UnlockManager.apply_pending_unlocks(profile)
		SaveSvc.save_resource(profile, "user://saves/meta.tres")
		# ... existing reward code ...
	else:
		profile.total_losses += 1
		SaveSvc.save_resource(profile, "user://saves/meta.tres")
```

**Step 3:** Ensure profile loaded at start:

```gdscript
func start_run(seed_value: int = 0) -> void:
	# Load meta profile before starting.
	profile = SaveSvc.load_or_create("user://saves/meta.tres", "MetaProfile")
	# ... existing code ...
```

**Step 4:** Add 3 tests for UnlockManager:

```gdscript
func _test_unlock_manager() -> void:
	print("[test] UnlockManager.calculate_unlocks")
	var profile := MetaProfileScript.new()
	# 0 wins — только starter (warrior, archer, mage).
	profile.total_wins = 0
	var u1: Array = UnlockManagerScript.apply_pending_unlocks(profile)
	_assert(u1.is_empty(), "0 wins: no new unlocks")
	# 4 wins → +2 units (cleric, guardian).
	profile.total_wins = 4
	var u2: Array = UnlockManagerScript.apply_pending_unlocks(profile)
	_assert(u2.size() == 2 and u2.has(&"cleric"), "4 wins: cleric unlocked")
	_assert(profile.unlocked_units.has(&"cleric"), "profile.unlocked_units now has cleric")
```

**Step 5:** Run tests: `godot --script tests/run_tests.gd` — expected 137/137.

**Step 6:** Commit: `git add core/progression/unlock_manager.gd core/progression/run_controller.gd tests/run_tests.gd && git commit -m "feat(meta): UnlockManager + 3 tests + integration with RunController"`

---

### Task 3.3: Pre-game UI to choose units from unlocked pool

**Objective:** Show player which units they can pick before each run starts.

**Files:**
- Create: `scenes/main_menu.tscn`
- Create: `scenes/main_menu.gd`

**Step 1:** Create `scenes/main_menu.gd`:

```gdscript
extends Control

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const ContentDB_static = preload("res://core/utils/content_db.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

var _profile: Resource = null
var _selected: Array[StringName] = []

@onready var list: ItemList = $VBox/UnitList
@onready var start_btn: Button = $VBox/StartButton
@onready var gold_label: Label = $VBox/GoldLabel


func _ready() -> void:
	# Загружаем профиль.
	_profile = preload("res://core/save/save_service.gd").load_or_create(
		"user://saves/meta.tres", "MetaProfile"
	)
	gold_label.text = "Gold: %d" % _profile.gold
	_populate_unit_list()
	start_btn.pressed.connect(_on_start_pressed)
	start_btn.disabled = true


func _populate_unit_list() -> void:
	list.clear()
	for unit_id in _profile.unlocked_units:
		var def: Resource = ContentDB_static.get_by_id(unit_id)
		if def == null:
			continue
		list.add_item("%s (Tier %d, Cost %d)" % [def.display_name, def.tier, def.cost])
		list.set_item_metadata(list.item_count - 1, unit_id)
	list.item_selected.connect(_on_unit_selected)


func _on_unit_selected(index: int) -> void:
	var unit_id: StringName = list.get_item_metadata(index)
	if _selected.has(unit_id):
		_selected.erase(unit_id)
	else:
		_selected.append(unit_id)
	start_btn.disabled = (_selected.size() == 0)
	gold_label.text = "Selected: %d" % _selected.size()


func _on_start_pressed() -> void:
	# Запускаем run с выбранными юнитами.
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	# V2: передать selected в RunController через сигнал или autoload state.
```

**Step 2:** Create `scenes/main_menu.tscn`:

```gdscript
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://scenes/main_menu.gd" id="1"]

[node name="MainMenu" type="Control"]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1")

[node name="VBox" type="VBoxContainer" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0

[node name="GoldLabel" type="Label" parent="VBox"]
text = "Gold: 0"

[node name="UnitList" type="ItemList" parent="VBox"]
size_flags_vertical = 3

[node name="StartButton" type="Button" parent="VBox"]
text = "Start Run"
```

**Step 3:** Update `project.godot` to start from main_menu:

```ini
[application]
run/main_scene="res://scenes/main_menu.tscn"
```

**Step 4:** Run tests: `godot --script tests/run_tests.gd` — expected 137/137.

**Step 5:** Commit: `git add scenes/main_menu.gd scenes/main_menu.tscn project.godot && git commit -m "feat(ui): MainMenu scene with unit selection from unlocked pool"`

---

### Task 3.4: SaveService integrity + persisted unlocks

**Objective:** Verify save/load works without corruption; tested in CI.

**Files:**
- Create: `tests/test_save_persistence.gd`

**Step 1:** Create `tests/test_save_persistence.gd`:

```gdscript
extends SceneTree

const SaveSvc = preload("res://core/save/save_service.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

func _initialize() -> void:
	print("\n=== Save Persistence Test ===\n")
	# Создаём профиль, сохраняем.
	var profile := MetaProfileScript.new()
	profile.total_wins = 5
	profile.unlock_unit(&"cleric")
	profile.unlock_unit(&"guardian")
	var saved: bool = SaveSvc.save_resource(profile, "user://saves/test_meta.tres")
	if not saved:
		print("[FAIL] save returned false")
		quit(1)
		return
	print("[OK] save_resource saved test profile")
	# Загружаем.
	var loaded: Resource = SaveSvc.load_resource("user://saves/test_meta.tres")
	if loaded == null:
		print("[FAIL] load returned null")
		quit(1)
		return
	print("[OK] load_resource loaded")
	_assert(loaded.total_wins == 5, "total_wins round-trip")
	_assert(loaded.unlocked_units.has(&"cleric"), "cleric in unlocked_units")
	_assert(loaded.unlocked_units.has(&"guardian"), "guardian in unlocked_units")
	print("\n=== Save Persistence: PASS ===\n")
	quit(0)


func _assert(cond: bool, msg: String) -> void:
	if cond:
		print("[OK] " + msg)
	else:
		print("[FAIL] " + msg)
```

**Step 2:** Add separate test runner — modify `run_tests.gd` to optionally run persistence test:

```gdscript
# В конце _initialize() добавь:
if "--integration" in OS.get_cmdline_args():
	var persistence_test = load("res://tests/test_save_persistence.gd").new()
	persistence_test._initialize()
```

**Step 3:** Run: `godot --script tests/run_tests.gd --integration` — expected ok.

**Step 4:** Run normal: `godot --script tests/run_tests.gd` — expected 137/137.

**Step 5:** Commit: `git add tests/test_save_persistence.gd tests/run_tests.gd && git commit -m "test(meta): save persistence round-trip integration test"`

---

## Part 4: Validation & Final Polish

### Task 4.1: Run lint + full test suite

**Step 1:** Run `python tools/lint_anti_patterns.py`. Expected errors: false positives only (5 same as before).

**Step 2:** Run `/tmp/godot47.exe --headless --path . --script tests/run_tests.gd`. Expected: 137/137.

**Step 3:** Verify editor-mode: `/tmp/godot47.exe --headless --editor --quit`. Expected: no parse errors.

**Step 4:** Verify main_menu loads: `/tmp/godot47.exe --headless --quit-after 60`. Expected: log "Run started" if Menu properly transitions.

**Step 5:** Run ad-hoc verification (write to temp file, run, delete). Cover: HP-bars render, Shield Block fires on 30% chance over 100 trials, UnlockManager unlocks cleric at 4 wins.

**Step 6:** Final commit if needed: `git status; git add -A; git commit -m "chore: verification pass for Sprint 4.2 + reactions + meta" --allow-empty`.

---

## Files Likely to Change

**Create (new):**
- `scenes/battle/ui_overlay.tscn`
- `scenes/battle/ui_overlay.gd`
- `core/data/reaction_def.gd`
- `core/reactions/reaction_system.gd`
- `core/reactions/reaction_system_autoload.gd`
- `content/reactions/attack_of_opportunity.tres`
- `content/reactions/shield_block.tres`
- `core/progression/unlock_manager.gd`
- `scenes/main_menu.tscn`
- `scenes/main_menu.gd`
- `tests/test_save_persistence.gd`

**Modify:**
- `scenes/battle/battle_scene.tscn` (add UIOverlay node)
- `scenes/battle/battle_scene.gd` (lifecycle hooks)
- `core/progression/run_controller.gd` (register reactions, save profile)
- `core/progression/meta_profile.gd` (unlocked_units + to_dict/from_dict)
- `core/utils/event_bus.gd` (new signals + helpers)
- `core/battle/battle_context.gd` (emit_unit_move_start)
- `core/effects/damage_effect.gd` (Shield Block check)
- `tests/run_tests.gd` (new tests)
- `project.godot` (autoload MainMenu)

---

## Tests / Validation

**Test targets:**
- `tests/run_tests.gd` — add 13 new tests across reactions, meta, unlock_manager
- `tests/test_save_persistence.gd` — new integration test

**Test commands:**
- `cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler" && /tmp/godot47.exe --headless --path . --script tests/run_tests.gd`
- Expected: 137 passed, 0 failed (after Part 3.2)
- Expected: 137 passed, 0 failed (after Part 3.4 persistence integration)

**Editor-mode:**
- `/tmp/godot47.exe --headless --editor --quit`
- Expected: no parse errors

**Lint:**
- `python tools/lint_anti_patterns.py`
- Expected: 5 false positives (same as before)

**Runtime smoke (main_menu/Main transition):**
- `/tmp/godot47.exe --headless --quit-after 60`
- Expected: scene loads, [run] Run started log appears

**Manual visual check (not in CI):**
- Run main_menu → see unit list with unlocked units
- Toggle units → gold_label updates
- Click Start → loads main.tscn → battle scene → UIOverlay renders HP bars

---

## Risks, Tradeoffs, Open Questions

**Risks:**
1. **UIOverlay redraws every frame** — performance OK for 28 cells, but if grid grows to 100 cells may need dirty regions. Mitigation: only redraw what changed.
2. **ReactionSystem autoload** — adds another global. Awkward for testing. Mitigation: tests instantiate ReactionSystem directly (no autoload).
3. **SaveService on user://** — platform-specific path. Should work on Windows. Comes with potential file permissions issues.
4. **MainMenu → main.tscn transition** — runs lose state if user crashes during transition. Save at start_run already covers this.

**Tradeoffs:**
- **Combatant.to_dict()** not yet connected to save flow. We save only MetaProfile and RunState (already implemented). Skip v1.
- **Reaction system is simple polling** — no priority, no queue. Could add reaction priority later.
- **UnlockManager has fixed UNLOCK_ORDER** — deterministic progression. Could randomize per player.

**Open Questions:**
1. Should reactions consume MP/resource? (v1: free, simple)
2. Should unlocks be tied to specific achievements (win with no losses, beat boss)? (v1: wins-based)
3. Should MainMenu support re-rolling the unit pool? (v1: fixed pool from profile)
4. Should we persist BattleState for replays? (out of scope, defer to v2)

**Effort estimate:**
- Sprint 4.2 (UI): 4-6 hours
- Reactions: 6-8 hours (AoO + Shield Block + tests)
- Meta-progression: 4-6 hours
- **Total: 14-20 hours (~2-3 days solo)**

**Sequencing rationale:**
- Sprint 4.2 first: UI is visible, quick wins, builds confidence.
- Reactions second: requires Balance.compute_attack_dos integration (already exists), event system (already exists).
- Meta-progression last: depends on Persistence-stable state, builds on unlocked content.
