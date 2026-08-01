# Sprint 5.1: EncounterMap core (генерация графа энкаунтеров)

> **For Hermes:** TDD на каждый Task. Sprint 5.1 = ТОЛЬКО core-логика (без UI).
> Граф энкаунтеров как на скрине Slay the Spire — Combat/Elite/Heal/Treasure/Shrine/...
> Игрок выбирает следующий нод из 2-3 доступных после текущего.

**Goal:** Core-класс `EncounterMap` который:
- Генерирует DAG (directed acyclic graph) из ~10-15 нодов по `seed`
- Каждый нод имеет тип (Combat, Elite, Heal, Treasure, Merchant, Rest, Shrine, Boss)
- Из каждого нода 2-3 следующих (ветвление)
- Игрок может выбрать только из доступных (достижимых из текущей позиции)
- Детерминизм через `Rng.seed_run()` — тот же seed = та же карта

**Architecture:**
- `core/encounter/encounter_type.gd` — enum типов
- `core/encounter/encounter_node.gd` — RefCounted класс с id, type, depth, parent_ids, child_ids
- `core/encounter/encounter_map.gd` — генерирует граф по seed, хранит current_node_id, choose_next()
- `core/balance.gd` — константы типов и весов

**Tech Stack:** GDScript 2.0, Godot 4.7, TDD, no Node.

---

## Контекст

**Что есть сейчас:**
- `RunController` ведёт линейный `round_index: 1..MAX_ROUND`, каждый раунд — бой
- `RewardScreen` появляется ПОСЛЕ победы, выбор юнита
- `MetaProfile.current_run_seed` хранит активный ран

**Что меняется:**
- `round_index` остаётся как "номер шага в графе" (1..N)
- `current_encounter_id` — pointer на текущий нод графа
- После боя/награды → выбор следующего нода из children текущего
- НеCombat ноды (Heal, Treasure, Shop, Rest) дают ресурсы, не бой

**Что НЕ делаем в S5.1 (UI в S5.2):**
- Визуализация графа
- Click/drag по нодам
- Анимации перемещения между нодами
- Карта как scene

**Что НЕ делаем в S5.1 (отдельные спринты):**
- Реальная логика Heal ноды (S5.4 — encounter effects)
- Реальная логика Treasure/Merchant/Shrine (S5.4)
- Интеграция с RunController (S5.3)

---

## Архитектурные решения

### D1: DAG, а не дерево

**Выбор:** Направленный ациклический граф (DAG). Некоторые ноды могут иметь > 1 parent.

**Почему:**
- Дерево → каждый нод имеет 1 родителя (linear). Скучно.
- DAG → можно "сойтись" обратно к центральному пути. Как Slay the Spire.
- На скриншоте видна структура: 1 корень → 3 ветки → сходятся → следующий слой с 2-3 ветками.

### D2: Количество слоёв

**Выбор:** 10 слоёв (как MAX_ROUND=10), в каждом слое 2-4 ноды.

**Почему:**
- Совместимость с `state.round_index` (1..10)
- 10 слоёв даёт достаточно места для ветвления
- Boss фиксирован на слое 10

### D3: Типы энкаунтеров

**Выбор:** 7 типов:
- `COMBAT` — обычный бой (50% weight)
- `ELITE` — сложный бой (10% weight)
- `HEAL` — восстановление HP (8%)
- `TREASURE` — золото + reward unit (10%)
- `MERCHANT` — магазин (8%)
- `REST` — heal + upgrade (8%)
- `SHRINE` — random buff (6%)

Boss — отдельный тип, всегда на слое 10.

**Почему:**
- Разнообразие из скрина (Combat/Elite/Heal/Treasure/Rest/Merchant/Shrine)
- Веса дают ~50% combat (большинство нод) + остальные для variety
- Rest/heal ~16% даёт возможность восстановиться

### D4: Гарантия проходимости

**Выбор:** Всегда генерируем так, чтобы был path от root до boss.

**Почему:**
- Если граф disconnected, игрок застрял
- При генерации: каждый нод имеет хотя бы 1 child до слоя N-1
- Boss на слое 10 имеет ровно 0 children (терминальный)

### D5: Текущая позиция

**Выбор:** `EncounterMap.current_node_id: int`. Игрок может выбрать только из нодов, которые есть в `current.children`.

**Почему:**
- `current_node_id` — single source of truth для "где игрок"
- `available_next_ids()` — list дочерних нод
- `choose_next(id)` переходит к ноде, идемпотентно

### D6: Детерминизм

**Вы選択:** `EncounterMap.generate(seed)` использует `Rng.*` (тот же что RunController).

**Почему:**
- Уже seeded в `start_run(seed)` через `Rng.seed_run(seed)`
- EncounterMap создаётся ПОСЛЕ seed_run — продолжает последовательность
- Тот же seed рана = та же карта + те же бои (full replay)

---

## Step-by-Step Plan

### Task 1: EncounterType enum + EncounterNode class

**Files:**
- Create: `core/encounter/encounter_type.gd`
- Create: `core/encounter/encounter_node.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Тест (RED):
```gdscript
func _test_encounter_node_basic() -> void:
    print("[test] S5.1: EncounterNode — basic fields")
    var node = EncounterNodeScript.new(1, EncounterTypeScript.COMBAT, 1)
    _assert(node.id == 1, "id = 1")
    _assert(node.type == EncounterTypeScript.COMBAT, "type = COMBAT")
    _assert(node.depth == 1, "depth = 1 (round_index)")
    _assert(node.parent_ids.is_empty(), "parent_ids пуст (root)")
    _assert(node.child_ids.is_empty(), "child_ids пуст (leaf)")


func _test_encounter_type_enum_values() -> void:
    print("[test] S5.1: EncounterType enum имеет все 8 типов")
    var types: Array[int] = [
        EncounterTypeScript.COMBAT,
        EncounterTypeScript.ELITE,
        EncounterTypeScript.HEAL,
        EncounterTypeScript.TREASURE,
        EncounterTypeScript.MERCHANT,
        EncounterTypeScript.REST,
        EncounterTypeScript.SHRINE,
        EncounterTypeScript.BOSS,
    ]
    _assert(types.size() == 8, "8 типов (got %d)" % types.size())
    # Все должны быть разные int.
    for i in types.size():
        for j in range(i + 1, types.size()):
            _assert(types[i] != types[j],
                "типы уникальны (%d vs %d)" % [types[i], types[j]])
```

**Step 2:** `core/encounter/encounter_type.gd`:
```gdscript
class_name EncounterType extends RefCounted
## Типы энкаунтеров на карте. Каждый нод на карте — один из этих типов.

enum Kind {
    COMBAT,    # обычный бой
    ELITE,     # сложный бой (бонус reward)
    HEAL,      # восстановление HP
    TREASURE,  # золото + reward unit
    MERCHANT,  # магазин со скидками
    REST,      # heal + upgrade
    SHRINE,    # random buff/choice
    BOSS,      # финальный бой (всегда слой 10)
}


static func is_combat(kind: int) -> bool:
    return kind == Kind.COMBAT or kind == Kind.ELITE or kind == Kind.BOSS


static func display_name(kind: int) -> String:
    match kind:
        Kind.COMBAT: return "Combat"
        Kind.ELITE: return "Elite"
        Kind.HEAL: return "Heal"
        Kind.TREASURE: return "Treasure"
        Kind.MERCHANT: return "Merchant"
        Kind.REST: return "Rest"
        Kind.SHRINE: return "Shrine"
        Kind.BOSS: return "Boss"
        _: return "Unknown"
```

**Step 3:** `core/encounter/encounter_node.gd`:
```gdscript
class_name EncounterNode extends RefCounted
## Узел карты энкаунтеров. Содержит id, type, depth, parent/child связи.

var id: int
var type: int  # EncounterType.Kind
var depth: int  # 1..MAX_ROUND (1 = стартовый слой)
var parent_ids: Array[int] = []
var child_ids: Array[int] = []
## True если игрок уже посетил этот нод.
var visited: bool = false
## True если нод доступен из текущей позиции игрока.
var available: bool = false


func _init(p_id: int, p_type: int, p_depth: int) -> void:
    id = p_id
    type = p_type
    depth = p_depth


## Возвращает true если это combat-тип (бой с врагами).
func is_combat() -> bool:
    return EncounterType.is_combat(type)
```

**Step 4:** Прогнать — должно быть 229/229.

**Step 5:** Commit: `feat(s5.1): EncounterType enum + EncounterNode class`

---

### Task 2: EncounterMap.generate(seed) — DAG с ветвлением

**Files:**
- Create: `core/encounter/encounter_map.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Тест:
```gdscript
func _test_encounter_map_generate_structure() -> void:
    print("[test] S5.1: EncounterMap.generate(seed) создаёт валидный граф")
    Rng.seed_run(42)
    var map = EncounterMapScript.new()
    map.generate(42)
    var nodes: Array = map.get_all_nodes()
    _assert(nodes.size() >= 10, ">= 10 нодов (got %d)" % nodes.size())
    # Каждый слой depth=1..10 должен иметь хотя бы 1 нод.
    for d in 10:
        var has_at_depth: bool = false
        for n in nodes:
            if n.depth == d + 1:
                has_at_depth = true
                break
        _assert(has_at_depth, "слой %d имеет хотя бы 1 нод" % (d + 1))


func _test_encounter_map_determinism() -> void:
    print("[test] S5.1: тот же seed = та же карта (детерминизм)")
    Rng.seed_run(100)
    var m1 = EncounterMapScript.new()
    m1.generate(100)
    Rng.seed_run(100)
    var m2 = EncounterMapScript.new()
    m2.generate(100)
    var types1: Array = m1.get_layer_types()
    var types2: Array = m2.get_layer_types()
    _assert(types1 == types2,
        "детерминизм: тот же seed → те же типы (got %s vs %s)" % [str(types1), str(types2)])


func _test_encounter_map_boss_at_layer_10() -> void:
    print("[test] S5.1: Boss находится на слое 10")
    Rng.seed_run(777)
    var map = EncounterMapScript.new()
    map.generate(777)
    var boss_at_10: int = 0
    for n in map.get_all_nodes():
        if n.type == EncounterTypeScript.BOSS:
            _assert(n.depth == 10, "boss на depth=10 (got %d)" % n.depth)
            boss_at_10 += 1
    _assert(boss_at_10 >= 1, "хотя бы 1 boss (got %d)" % boss_at_10)


func _test_encounter_map_first_layer_is_combat() -> void:
    print("[test] S5.1: слой 1 — только combat (стартовый набор)")
    Rng.seed_run(42)
    var map = EncounterMapScript.new()
    map.generate(42)
    for n in map.get_layer_nodes(1):
        _assert(n.type == EncounterTypeScript.COMBAT,
            "слой 1 = COMBAT (got %s)" % EncounterTypeScript.display_name(n.type))
```

**Step 2:** `core/encounter/encounter_map.gd`:
```gdscript
class_name EncounterMap extends RefCounted
## Граф энкаунтеров для одного рана.
##
## Генерируется по seed: 10 слоёв, в каждом 2-4 нода.
## Слой 1: всегда COMBAT (стартовый бой). Слой 10: всегда BOSS.
## Из каждого нода 2-3 ребра к нодам следующего слоя.
##
## Детерминизм: тот же seed → та же карта.

const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const EncounterNodeScript = preload("res://core/encounter/encounter_node.gd")

const MAX_DEPTH: int = 10
const MIN_NODES_PER_LAYER: int = 2
const MAX_NODES_PER_LAYER: int = 4

var _nodes: Array = []  # Array[EncounterNode]
var _next_id: int = 0
var _current_node_id: int = -1  # -1 = карта ещё не начата


## Генерирует граф по seed. Использует Rng (нужно seed_run перед вызовом).
func generate(seed_value: int) -> void:
    _nodes.clear()
    _next_id = 0
    _current_node_id = -1
    # Слой 1: 2 combat-нода.
    var layer1_ids: Array[int] = []
    for i in 2:
        var n: EncounterNode = _make_node(EncounterTypeScript.Kind.COMBAT, 1)
        layer1_ids.append(n.id)
    # Слои 2..9: 2-4 нода, типы по весам.
    var prev_layer_ids: Array[int] = layer1_ids
    for depth in range(2, MAX_DEPTH):
        var layer_size: int = Rng.randi_range(MIN_NODES_PER_LAYER, MAX_NODES_PER_LAYER)
        var cur_layer_ids: Array[int] = []
        for i in layer_size:
            var kind: int = _pick_kind_for_layer(depth)
            var n: EncounterNode = _make_node(kind, depth)
            cur_layer_ids.append(n.id)
        # Связи: каждый prev_node даёт 1-2 ребра к cur_layer (random subset).
        for prev_id in prev_layer_ids:
            var prev_node: EncounterNode = _get_node(prev_id)
            if prev_node == null:
                continue
            var num_links: int = mini(cur_layer_ids.size(), Rng.randi_range(1, 2))
            for j in num_links:
                var child_id: int = cur_layer_ids[Rng.randi_range(0, cur_layer_ids.size() - 1)]
                if child_id not in prev_node.child_ids:
                    prev_node.child_ids.append(child_id)
                    var child: EncounterNode = _get_node(child_id)
                    if prev_id not in child.parent_ids:
                        child.parent_ids.append(prev_id)
        # Гарантия: если cur_layer ничей (не связан с prev), привязать случайно.
        var orphan_ids: Array[int] = []
        for cid in cur_layer_ids:
            var c: EncounterNode = _get_node(cid)
            if c.parent_ids.is_empty():
                orphan_ids.append(cid)
        for orphan_id in orphan_ids:
            var prev_id2: int = prev_layer_ids[Rng.randi_range(0, prev_layer_ids.size() - 1)]
            var prev: EncounterNode = _get_node(prev_id2)
            if prev != null and orphan_id not in prev.child_ids:
                prev.child_ids.append(orphan_id)
                var o: EncounterNode = _get_node(orphan_id)
                if prev_id2 not in o.parent_ids:
                    o.parent_ids.append(prev_id2)
        prev_layer_ids = cur_layer_ids
    # Слой 10: всегда 1 BOSS, связан со всеми prev_layer_ids.
    var boss: EncounterNode = _make_node(EncounterTypeScript.Kind.BOSS, MAX_DEPTH)
    for prev_id in prev_layer_ids:
        var prev: EncounterNode = _get_node(prev_id)
        if prev != null:
            prev.child_ids.append(boss.id)
            boss.parent_ids.append(prev.id)


## Создаёт EncounterNode с уникальным id, добавляет в _nodes.
func _make_node(kind: int, depth: int) -> EncounterNode:
    var n: EncounterNode = EncounterNodeScript.new(_next_id, kind, depth)
    _next_id += 1
    _nodes.append(n)
    return n


## Возвращает id encounter по весам для этого слоя.
func _pick_kind_for_layer(depth: int) -> int:
    var r: float = Rng.randf()
    var weights: Dictionary = {
        EncounterTypeScript.Kind.COMBAT: BalanceScript.MAP_COMBAT_WEIGHT,
        EncounterTypeScript.Kind.ELITE: BalanceScript.MAP_ELITE_WEIGHT,
        EncounterTypeScript.Kind.HEAL: BalanceScript.MAP_HEAL_WEIGHT,
        EncounterTypeScript.Kind.TREASURE: BalanceScript.MAP_TREASURE_WEIGHT,
        EncounterTypeScript.Kind.MERCHANT: BalanceScript.MAP_MERCHANT_WEIGHT,
        EncounterTypeScript.Kind.REST: BalanceScript.MAP_REST_WEIGHT,
        EncounterTypeScript.Kind.SHRINE: BalanceScript.MAP_SHRINE_WEIGHT,
    }
    var cumulative: float = 0.0
    for kind in weights:
        cumulative += weights[kind]
        if r <= cumulative:
            return kind
    return EncounterTypeScript.Kind.COMBAT


## Возвращает список всех EncounterNode.
func get_all_nodes() -> Array:
    return _nodes


## Возвращает все ноды на конкретном слое.
func get_layer_nodes(depth: int) -> Array:
    var result: Array = []
    for n in _nodes:
        if n.depth == depth:
            result.append(n)
    return result


## Возвращает массив типов (int) для каждого слоя 1..10 (для тестов).
func get_layer_types() -> Array:
    var result: Array = []
    for d in MAX_DEPTH:
        var types_in_layer: Array = []
        for n in _nodes:
            if n.depth == d + 1:
                types_in_layer.append(n.type)
        result.append(types_in_layer)
    return result


func get_node(id: int) -> EncounterNode:
    return _get_node(id)


func _get_node(id: int) -> EncounterNode:
    for n in _nodes:
        if n.id == id:
            return n
    return null


## ID текущего нода (где игрок сейчас).
func get_current_node_id() -> int:
    return _current_node_id


## ID нодов, доступных из текущего (для UI выбора).
func get_available_next_ids() -> Array[int]:
    if _current_node_id == -1:
        # Начало рана — доступны ноды слоя 1.
        return get_layer_nodes(1).map(func(n): return n.id)
    var cur: EncounterNode = _get_node(_current_node_id)
    if cur == null:
        return []
    return cur.child_ids.duplicate()


## Начать ран: помечает первый нод слоя 1 как current.
func start_run() -> int:
    var layer1: Array = get_layer_nodes(1)
    if layer1.is_empty():
        return -1
    _current_node_id = layer1[0].id
    var n: EncounterNode = _get_node(_current_node_id)
    n.visited = true
    return _current_node_id


## Игрок выбрал next_node_id. Возвращает true если переход успешен.
func choose_next(next_node_id: int) -> bool:
    var available: Array[int] = get_available_next_ids()
    if next_node_id not in available:
        return false
    var cur: EncounterNode = _get_node(_current_node_id)
    if cur != null:
        cur.available = false
    _current_node_id = next_node_id
    var next: EncounterNode = _get_node(next_node_id)
    if next != null:
        next.visited = true
    return true
```

**Step 3:** Прогнать — должно быть 234/234.

**Step 4:** Commit: `feat(s5.1): EncounterMap.generate(seed) — DAG с ветвлением`

---

### Task 3: choose_next() + доступные ноды

Уже реализовано в Task 2. Тесты:
```gdscript
func _test_encounter_map_choose_next_basic() -> void:
    print("[test] S5.1: EncounterMap.choose_next(id) переходит по графу")
    Rng.seed_run(123)
    var map = EncounterMapScript.new()
    map.generate(123)
    var first_id: int = map.start_run()
    _assert(first_id >= 0, "start_run вернул id")
    _assert(map.get_current_node_id() == first_id, "current = first_id")
    var available: Array = map.get_available_next_ids()
    _assert(not available.is_empty(), "есть available ноды")
    var next_id: int = available[0]
    var ok: bool = map.choose_next(next_id)
    _assert(ok, "choose_next вернул true")
    _assert(map.get_current_node_id() == next_id, "current обновился")


func _test_encounter_map_choose_invalid() -> void:
    print("[test] S5.1: choose_next(invalid_id) → false")
    Rng.seed_run(42)
    var map = EncounterMapScript.new()
    map.generate(42)
    map.start_run()
    var ok: bool = map.choose_next(99999)
    _assert(ok == false, "invalid_id → false")
```

**Step 1:** Добавить тесты в `_initialize()`.

**Step 2:** Commit: `test(s5.1): choose_next + invalid_id edge cases`

---

### Task 4: Balance constants

**Files:**
- Modify: `core/balance.gd`

**Step 1:** Добавить секцию "Encounter map (S5.1)":
```gdscript
# === Encounter map (S5.1) ===
# Веса для типов энкаунтеров при генерации графа.
# Сумма всех весов = 1.0 (для вероятностей).
const MAP_COMBAT_WEIGHT: float = 0.50
const MAP_ELITE_WEIGHT: float = 0.10
const MAP_HEAL_WEIGHT: float = 0.08
const MAP_TREASURE_WEIGHT: float = 0.10
const MAP_MERCHANT_WEIGHT: float = 0.08
const MAP_REST_WEIGHT: float = 0.08
const MAP_SHRINE_WEIGHT: float = 0.06
# Параметры графа.
const MAP_MIN_NODES_PER_LAYER: int = 2
const MAP_MAX_NODES_PER_LAYER: int = 4
const MAP_MAX_DEPTH: int = 10
```

**Step 2:** Commit: `chore(s5.1): encounter map balance constants`

---

### Task 5: Editor-mode + final commit

**Step 1:** `godot47 --headless --editor --quit` (class registry check).

**Step 2:** `godot47 --headless --path . --quit-after 30` (visual smoke).

---

## Файлы изменяются

| Файл | Тип | Строк |
|---|---|---|
| `core/encounter/encounter_type.gd` | create | ~35 |
| `core/encounter/encounter_node.gd` | create | ~30 |
| `core/encounter/encounter_map.gd` | create | ~130 |
| `core/balance.gd` | modify | +12 |
| `tests/run_tests.gd` | modify | +90 (4 теста) |

**Итого:** ~300 строк, 3 новых класса, 1 модифицированный.

---

## Тесты / Валидация

### Прогон после каждой задачи
```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --script tests/run_tests.gd
```

**Ожидаемая динамика:**
- Task 1: 229/229 (+2 теста)
- Task 2: 233/233 (+4 теста)
- Task 3: 235/235 (+2 теста)
- Task 4: 235/235 (только balance)
- Task 5: 235/235 (verify)

---

## Риски

| Риск | Митигация |
|---|---|
| R1: Граф disconnected (orphan слой) | `_pick_kind_for_layer` гарантирует связи через orphan_ids fallback |
| R2: Слишком много branching → игрок растерян | max_nodes_per_layer=4 даёт выбор 1-2, не больше |
| R3: Boss не на 10 слое | Task 2 hardcode: слой 10 всегда BOSS |
| R4: Карта одинаковая каждый ран | Rng используется ПОСЛЕ seed_run → разные seed рана → разные карты |

---

## Handoff

После S5.1:
- 235/235 тестов зелёные
- 4 коммита (Type, Node, Map+generate, choose_next tests, balance)
- EncounterMap.generate(seed) работает, тестируемо
- **Никакого UI** — это S5.2
- **Никакой интеграции с RunController** — это S5.3
- Чистый core, headless-тестируемый