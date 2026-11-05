class_name EncounterMap extends RefCounted
## Граф энкаунтеров для одного рана (S5.1).
##
## Генерирует DAG (directed acyclic graph) из ~10-30 нодов по seed.
## 10 слоёв (depth=1..10), в каждом 2-4 нода. Слой 1: COMBAT. Слой 10: BOSS.
## Из каждого нода 1-2 ребра к нодам следующего слоя.
##
## Детерминизм: использует Rng (нужно seed_run перед вызовом generate).
## Тот же seed рана = та же карта.

const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const EncounterNodeScript = preload("res://core/encounter/encounter_node.gd")

var _nodes: Array = []  # Array[EncounterNode]
var _next_id: int = 0
var _current_node_id: int = -1  # -1 = карта ещё не начата


## Генерирует граф по seed_value. Использует Rng.randf_range и т.п.
## ВАЖНО: вызывай ПОСЛЕ Rng.seed_run(seed_value) для детерминизма.
func generate(seed_value: int) -> void:
	_nodes.clear()
	_next_id = 0
	_current_node_id = -1
	# Слой 1: 2 combat-нода (стартовые).
	var layer1_ids: Array[int] = []
	for i in 2:
		var n: EncounterNode = _make_node(EncounterTypeScript.Kind.COMBAT, 1)
		layer1_ids.append(n.id)
	# Слои 2..9: 2-4 нода, типы по весам.
	var prev_layer_ids: Array[int] = layer1_ids.duplicate()
	for depth in range(2, 10):  # depth 2..9
		var layer_size: int = Rng.randi_range(
			Balance.MAP_MIN_NODES_PER_LAYER,
			Balance.MAP_MAX_NODES_PER_LAYER,
		)
		var cur_layer_ids: Array[int] = []
		for i in layer_size:
			var kind: int = _pick_kind_for_layer()
			var n: EncounterNode = _make_node(kind, depth)
			cur_layer_ids.append(n.id)
		# Связи: каждый prev_node даёт 1-2 ребра к cur_layer (random subset).
		_link_layer(prev_layer_ids, cur_layer_ids)
		prev_layer_ids = cur_layer_ids.duplicate()
	# Слой 10: 1 BOSS, связан со всеми prev_layer_ids.
	_make_boss_layer(prev_layer_ids)


## Создаёт EncounterNode с уникальным id, добавляет в _nodes.
func _make_node(kind: int, depth: int) -> EncounterNode:
	var n: EncounterNode = EncounterNodeScript.new(_next_id, kind, depth)
	_next_id += 1
	_nodes.append(n)
	return n


## Связывает prev_layer с cur_layer (1-2 случайных ребра от каждого prev_node).
func _link_layer(prev_layer_ids: Array, cur_layer_ids: Array) -> void:
	for prev_id in prev_layer_ids:
		var prev_node: EncounterNode = _get_node(prev_id)
		if prev_node == null or cur_layer_ids.is_empty():
			continue
		var num_links: int = mini(cur_layer_ids.size(), Rng.randi_range(1, 2))
		# Случайно выбираем num_links разных child_ids.
		var available: Array[int] = cur_layer_ids.duplicate()
		# S5.1: Fisher-Yates через Rng.randf (детерминировано через seeded Rng).
		for i in range(available.size() - 1, 0, -1):
			var j: int = int(Rng.randf() * float(i + 1))
			var tmp: int = available[i]
			available[i] = available[j]
			available[j] = tmp
		for j in mini(num_links, available.size()):
			var child_id: int = available[j]
			if child_id not in prev_node.child_ids:
				prev_node.child_ids.append(child_id)
				var child: EncounterNode = _get_node(child_id)
				if child != null and prev_id not in child.parent_ids:
					child.parent_ids.append(prev_id)
	# Гарантия: orphan'ы получают parent.
	_attach_orphans(prev_layer_ids, cur_layer_ids)


## Если cur_layer нод не получил parent, привязать к случайному prev.
func _attach_orphans(prev_layer_ids: Array, cur_layer_ids: Array) -> void:
	for cid in cur_layer_ids:
		var c: EncounterNode = _get_node(cid)
		if c == null or not c.parent_ids.is_empty():
			continue
		# Orphan — привязать.
		if prev_layer_ids.is_empty():
			continue
		var prev_id: int = prev_layer_ids[Rng.randi_range(0, prev_layer_ids.size() - 1)]
		var prev: EncounterNode = _get_node(prev_id)
		if prev != null and cid not in prev.child_ids:
			prev.child_ids.append(cid)
			c.parent_ids.append(prev_id)


## Слой 10: 1 BOSS связан со всеми prev_layer_ids.
func _make_boss_layer(prev_layer_ids: Array) -> void:
	var boss: EncounterNode = _make_node(EncounterTypeScript.Kind.BOSS, 10)
	for prev_id in prev_layer_ids:
		var prev: EncounterNode = _get_node(prev_id)
		if prev != null:
			prev.child_ids.append(boss.id)
			boss.parent_ids.append(prev_id)


## Возвращает kind encounter по весам из Balance.
## Использует Rng.randf() (детерминировано если seed_run).
func _pick_kind_for_layer() -> int:
	var r: float = Rng.randf()
	var cumulative: float = 0.0
	cumulative += Balance.MAP_COMBAT_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.COMBAT
	cumulative += Balance.MAP_ELITE_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.ELITE
	cumulative += Balance.MAP_HEAL_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.HEAL
	cumulative += Balance.MAP_TREASURE_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.TREASURE
	cumulative += Balance.MAP_MERCHANT_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.MERCHANT
	cumulative += Balance.MAP_REST_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.REST
	cumulative += Balance.MAP_SHRINE_WEIGHT
	if r <= cumulative:
		return EncounterTypeScript.Kind.SHRINE
	return EncounterTypeScript.Kind.COMBAT


## Возвращает все EncounterNode в графе.
func get_all_nodes() -> Array:
	return _nodes


## Возвращает ноды на конкретном слое.
func get_layer_nodes(depth: int) -> Array:
	var result: Array = []
	for n in _nodes:
		if n.depth == depth:
			result.append(n)
	return result


## Возвращает типы (int) для каждого слоя 1..10 (для тестов и debug).
func get_layer_types() -> Array:
	var result: Array = []
	for d in 10:
		var types_in_layer: Array = []
		for n in _nodes:
			if n.depth == d + 1:
				types_in_layer.append(n.type)
		result.append(types_in_layer)
	return result


## Возвращает чистый снимок графа для сохранения.
##
## The snapshot is a plain Dictionary of primitives — no Godot object
## graph is serialized. It carries everything needed to reproduce the
## map EXACTLY:
##
##   nodes          : [{id, type, depth, parent_ids, child_ids, visited, available}]
##   next_id        : the id allocator position
##   current_node_id: where the player is (-1 = the run has not started)
##
## The node list is emitted in ascending id order, so two
## semantically identical maps serialize identically.
func snapshot() -> Dictionary:
	var nodes: Array = []
	var sorted_nodes: Array = _nodes.duplicate()
	sorted_nodes.sort_custom(func(a, b) -> bool: return int(a.id) < int(b.id))
	for n in sorted_nodes:
		nodes.append({
			"id": int(n.id),
			"type": int(n.type),
			"depth": int(n.depth),
			"parent_ids": _sorted_ints(n.parent_ids),
			"child_ids": _sorted_ints(n.child_ids),
			"visited": bool(n.visited),
			"available": bool(n.available),
		})
	return {
		"nodes": nodes,
		"next_id": int(_next_id),
		"current_node_id": int(_current_node_id),
	}


## Восстанавливает граф из снимка.
##
## The restore is ATOMIC: the whole snapshot is validated first and the
## live map is only replaced when every check passed. A bad snapshot
## leaves the map untouched.
##
## Validation covers:
##   - the shape of the snapshot
##   - integer node ids, unique
##   - integer type / depth, valid arrays
##   - every parent / child reference resolves to a known node
##   - the current node exists (or is -1)
##
## Returns true on success.
func restore_snapshot(data: Dictionary) -> bool:
	var validated: Dictionary = _validate_snapshot(data)
	if not bool(validated.get("valid", false)):
		return false

	# Build the new graph in a temporary list first.
	var new_nodes: Array = []
	for entry in validated.get("nodes", []) as Array:
		var node: EncounterNode = EncounterNodeScript.new(
			int((entry as Dictionary)["id"]),
			int((entry as Dictionary)["type"]),
			int((entry as Dictionary)["depth"]))
		node.parent_ids = _int_array((entry as Dictionary)["parent_ids"])
		node.child_ids = _int_array((entry as Dictionary)["child_ids"])
		node.visited = bool((entry as Dictionary)["visited"])
		node.available = bool((entry as Dictionary)["available"])
		new_nodes.append(node)

	# Only now the live map is replaced.
	_nodes = new_nodes
	_next_id = int(validated.get("next_id", 0))
	_current_node_id = int(validated.get("current_node_id", -1))
	return true


## Validates a snapshot without touching the live map.
func _validate_snapshot(data: Dictionary) -> Dictionary:
	if not data.has("nodes") or not data.has("next_id") 			or not data.has("current_node_id"):
		return {"valid": false, "reason": "missing_field"}
	var raw_nodes: Variant = data["nodes"]
	if not (raw_nodes is Array):
		return {"valid": false, "reason": "nodes_not_an_array"}
	var raw_next: Variant = data["next_id"]
	var raw_current: Variant = data["current_node_id"]
	if not (raw_next is int) and not (raw_next is float):
		return {"valid": false, "reason": "next_id_not_an_integer"}
	if not (raw_current is int) and not (raw_current is float):
		return {"valid": false, "reason": "current_node_id_not_an_integer"}
	var nodes: Array = raw_nodes as Array
	var seen_ids: Dictionary = {}
	var ids: Array[int] = []
	for entry in nodes:
		if not (entry is Dictionary):
			return {"valid": false, "reason": "node_not_a_dictionary"}
		var d: Dictionary = entry
		for key in ["id", "type", "depth"]:
			if not d.has(key):
				return {"valid": false, "reason": "node_missing_%s" % key}
			var v: Variant = d[key]
			if not (v is int) and not (v is float):
				return {"valid": false, "reason": "node_%s_not_an_integer" % key}
		var node_id: int = int(d["id"])
		if seen_ids.has(node_id):
			return {"valid": false, "reason": "duplicate_node_id"}
		seen_ids[node_id] = true
		ids.append(node_id)
		for key in ["parent_ids", "child_ids"]:
			if not d.has(key):
				return {"valid": false, "reason": "node_missing_%s" % key}
			var arr: Variant = d[key]
			if not (arr is Array):
				return {"valid": false, "reason": "node_%s_not_an_array" % key}
			for v in arr as Array:
				if not (v is int) and not (v is float):
					return {"valid": false, "reason": "node_%s_not_an_integer" % key}
		for key in ["visited", "available"]:
			if not d.has(key):
				return {"valid": false, "reason": "node_missing_%s" % key}
			if not (d[key] is bool):
				return {"valid": false, "reason": "node_%s_not_a_bool" % key}

	# Every reference must resolve.
	for entry in nodes:
		var d: Dictionary = entry
		for key in ["parent_ids", "child_ids"]:
			for v in d[key] as Array:
				if not seen_ids.has(int(v)):
					return {"valid": false, "reason": "dangling_%s" % key}

	var current: int = int(data["current_node_id"])
	if current != -1 and not seen_ids.has(current):
		return {"valid": false, "reason": "current_node_not_found"}

	return {
		"valid": true,
		"nodes": nodes,
		"next_id": int(data["next_id"]),
		"current_node_id": current,
	}


## Returns a sorted copy of an int array, so the snapshot is stable.
func _sorted_ints(source: Array) -> Array:
	var copy: Array = []
	for v in source:
		copy.append(int(v))
	copy.sort()
	return copy


## Returns an Array[int] from a wire array.
func _int_array(source: Array) -> Array[int]:
	var result: Array[int] = []
	for v in source:
		result.append(int(v))
	return result


## Возвращает EncounterNode по id, или null.
func get_node(node_id: int) -> EncounterNode:
	return _get_node(node_id)


func _get_node(node_id: int) -> EncounterNode:
	for n in _nodes:
		if n.id == node_id:
			return n
	return null


## ID текущего нода (где игрок сейчас). -1 если ран не начат.
func get_current_node_id() -> int:
	return _current_node_id


## ID нодов, доступных из текущего (для UI выбора).
## Если ран не начат — возвращает все ноды слоя 1.
func get_available_next_ids() -> Array[int]:
	if _current_node_id == -1:
		var result: Array[int] = []
		for n in get_layer_nodes(1):
			result.append(n.id)
		return result
	var cur: EncounterNode = _get_node(_current_node_id)
	if cur == null:
		return []
	return cur.child_ids.duplicate()


## Начать ран: помечает первый нод слоя 1 как current.
## Возвращает id текущего нода, или -1 если нет нодов.
func start_run() -> int:
	var layer1: Array = get_layer_nodes(1)
	if layer1.is_empty():
		return -1
	_current_node_id = layer1[0].id
	layer1[0].visited = true
	return _current_node_id


## Marks the given nodes as visited.
##
## The walked path is NOT reproducible from the seed: the graph is, but
## which nodes the run actually walked is not. `goto_node` marks only
## the current node, so a migrated checkpoint would render the nodes
## the run had already walked as unvisited.
##
## The authoritative list of the walked nodes is
## `RunDomainState.encounter_visited_ids`; this applies it to the
## graph. Unknown ids are ignored: the graph is the seed's, and a node
## that is not in it was never part of this run.
func mark_visited(node_ids: Array) -> void:
	for value in node_ids:
		var node = _get_node(int(value))
		if node != null:
			node.visited = true


## S5.4: установить current_node_id напрямую (для restore из save).
## НЕ вызывает choose_next, не проверяет visited. Private-логика для recovery.
## Только для восстановления состояния после resume_run.
func goto_node(node_id: int) -> bool:
	var n = _get_node(node_id)
	if n == null:
		return false
	_current_node_id = node_id
	n.visited = true
	return true


## Игрок выбрал next_node_id. Возвращает true если переход успешен.
## next_node_id должен быть в available_next_ids.
func choose_next(next_node_id: int) -> bool:
	var available: Array[int] = get_available_next_ids()
	if not next_node_id in available:
		return false
	var cur: EncounterNode = _get_node(_current_node_id)
	if cur != null:
		cur.available = false
	_current_node_id = next_node_id
	var next: EncounterNode = _get_node(next_node_id)
	if next != null:
		next.visited = true
	return true


## Возвращает EncounterNode по current_node_id.
func get_current_node() -> EncounterNode:
	if _current_node_id == -1:
		return null
	return _get_node(_current_node_id)


## Проверяет что граф валиден: каждый не-root нод имеет parent, boss на слое 10.
func is_valid() -> bool:
	var boss_count: int = 0
	for n in _nodes:
		if n.type == EncounterTypeScript.Kind.BOSS:
			boss_count += 1
			if n.depth != 10:
				return false
		elif n.depth > 1 and n.parent_ids.is_empty():
			return false  # Orphan
		elif n.depth < 10 and n.child_ids.is_empty():
			return false  # Dead end (не boss)
	return boss_count >= 1


## Возвращает количество нодов (для тестов).
func size() -> int:
	return _nodes.size()