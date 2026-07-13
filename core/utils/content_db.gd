class_name ContentDB_static extends RefCounted
## База данных контента. Статический загрузчик.
## В project.godot autoload-обёртка "ContentDB" для совместимости.
## Имя class_name отличается от autoload чтобы не было конфликта.

const CONTENT_DIRS: Dictionary = {
	"units": "res://content/units/",
	"enemies": "res://content/enemies/",
	"abilities": "res://content/abilities/",
	"effects": "res://content/effects/",
	"items": "res://content/items/",
}

static var _by_id: Dictionary = {}
static var _by_type: Dictionary = {}
static var _loaded: bool = false


## Загружает все .tres из CONTENT_DIRS. Вызывай на старте или перед первым доступом.
static func load_all() -> void:
	_by_id.clear()
	_by_type.clear()
	for type_name in CONTENT_DIRS.keys():
		_load_dir(type_name, CONTENT_DIRS[type_name])
	_loaded = true
	GameLog.info("content", "Loaded content", {
		"total_resources": _by_id.size(),
		"types": _by_type.keys(),
	})


static func _load_dir(type_name: String, dir_path: String) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		GameLog.warn("content", "Directory not found: %s" % dir_path)
		return
	var ids: Array = []
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and (file_name.ends_with(".tres") or file_name.ends_with(".res")):
			var full_path: String = dir_path.path_join(file_name)
			var res: Resource = load(full_path)
			if res == null:
				GameLog.warn("content", "Failed to load: %s" % full_path)
			else:
				var id: StringName = _extract_id(res, file_name)
				if id == &"":
					GameLog.warn("content", "Resource has no id, skipping", {"path": full_path})
				elif _by_id.has(id):
					GameLog.warn("content", "Duplicate id", {"id": id, "path": full_path})
				else:
					_by_id[id] = res
					ids.append(id)
		file_name = dir.get_next()
	dir.list_dir_end()
	_by_type[type_name] = ids


static func _extract_id(res: Resource, fallback_file: String) -> StringName:
	if "id" in res and res.get("id") != null and str(res.get("id")) != "":
		return StringName(String(res.get("id")))
	var stem: String = fallback_file.get_basename()
	return StringName(stem)


static func ensure_loaded() -> void:
	if not _loaded:
		load_all()


## Возвращает ресурс по id, или null если не найден.
static func get_by_id(id: StringName) -> Resource:
	ensure_loaded()
	return _by_id.get(id, null)


static func list_by_type(type_name: String) -> Array:
	ensure_loaded()
	return _by_type.get(type_name, [])


static func list_resources_by_type(type_name: String) -> Array:
	ensure_loaded()
	var result: Array = []
	for id in _by_type.get(type_name, []):
		var res: Resource = _by_id.get(id, null)
		if res != null:
			result.append(res)
	return result