class_name StatusList extends RefCounted
## Контейнер активных статусов. Управляет durations, stacks, тиками DOT/HOT.
##
## Массив внутри: [{def, remaining, stacks, source, tick_acc}, ...]
## Не зависит от Combatant — тестируется отдельно.

var _statuses: Array = []


## Накладывает статус. Если статус уже есть — обновляет duration/max_stacks.
func apply(def: Resource, duration: float, max_stacks: int, source) -> void:
	if def == null:
		return
	var existing = _find(def.id)
	if existing != null:
		if def.stackable and existing.stacks < max_stacks:
			existing.stacks += 1
			existing.remaining = maxi(existing.remaining, duration)
		else:
			existing.remaining = maxi(existing.remaining, duration)
		return
	_statuses.append({
		"def": def,
		"remaining": duration,
		"stacks": 1,
		"source": source,
		"tick_acc": 0.0,
	})


## Снимает статус по id. Возвращает true если найден и снят.
func remove(status_id: StringName) -> bool:
	for i in range(_statuses.size() - 1, -1, -1):
		var s: Dictionary = _statuses[i]
		if s.def != null and s.def.id == status_id:
			_statuses.remove_at(i)
			return true
	return false


func has(status_id: StringName) -> bool:
	return _find(status_id) != null


func active() -> Array:
	return _statuses.duplicate()


## Снимает до count статусов. harmful_only=true → дебаффы, иначе баффы.
## count=-1 = все подходящие.
func dispel(count: int, harmful_only: bool) -> Array:
	var removed: Array = []
	for i in range(_statuses.size() - 1, -1, -1):
		if count >= 0 and removed.size() >= count:
			break
		var s: Dictionary = _statuses[i]
		var def: Resource = s.def
		if def == null:
			continue
		if harmful_only and not def.is_harmful:
			continue
		if not harmful_only and def.is_harmful:
			continue
		removed.append(def.id)
		_statuses.remove_at(i)
	return removed


## Проверяет, есть ли статус с blocks_actions=true (stun, sleep, paralysis).
func has_blocking_action() -> bool:
	for s in _statuses:
		if s.def != null and s.def.blocks_actions:
			return true
	return false


## Тикает все статусы. Возвращает список произошедших эффектов:
##   [{kind: "dot"|"hot"|"expire", status: StringName, amount: int}, ...]
##
## on_dot(combatant, amount, source) — вызывается при DOT-уроне (если задан).
## on_hot(combatant, amount) — вызывается при HOT-хиле (если задан).
## on_expire(status_id) — вызывается при истечении статуса (если задан).
##
## Это позволяет Combatant/Save/UI реагировать без того, чтобы StatusList знал про Combatant.
func tick(dt: float, callbacks: Dictionary = {}) -> Array:
	var events: Array = []
	for i in range(_statuses.size() - 1, -1, -1):
		var s: Dictionary = _statuses[i]
		var def: Resource = s.def
		s.remaining -= dt
		# DOT/HOT только пока статус активен.
		if def != null and def.tick_interval > 0.0 and s.remaining > 0.0:
			s.tick_acc += dt
			while s.tick_acc >= def.tick_interval:
				s.tick_acc -= def.tick_interval
				if def.dot_damage != 0:
					var d: int = def.dot_damage * s.stacks
					events.append({"kind": "dot", "status": def.id, "amount": d, "source": s.source})
					if callbacks.has("on_dot"):
						callbacks.on_dot.call(d, s.source)
				if def.dot_heal != 0:
					var h: int = def.dot_heal * s.stacks
					events.append({"kind": "hot", "status": def.id, "amount": h})
					if callbacks.has("on_hot"):
						callbacks.on_hot.call(h)
		if s.remaining <= 0.0:
			var sid: StringName = def.id if def != null else &""
			_statuses.remove_at(i)
			events.append({"kind": "expire", "status": sid})
			if callbacks.has("on_expire"):
				callbacks.on_expire.call(sid)
	return events


func _find(status_id: StringName) -> Variant:
	for s in _statuses:
		if s.def != null and s.def.id == status_id:
			return s
	return null


func clear() -> void:
	_statuses.clear()


func to_dict() -> Array:
	var result: Array = []
	for s in _statuses:
		if s.def == null:
			continue
		result.append({
			"id": s.def.id,
			"remaining": s.remaining,
			"stacks": s.stacks,
		})
	return result


func from_dict(arr: Array, lookup: Callable) -> void:
	_statuses.clear()
	for entry in arr:
		var def: Resource = lookup.call(entry.get("id"))
		if def == null:
			continue
		_statuses.append({
			"def": def,
			"remaining": float(entry.get("remaining", 0.0)),
			"stacks": int(entry.get("stacks", 1)),
			"source": null,
			"tick_acc": 0.0,
		})