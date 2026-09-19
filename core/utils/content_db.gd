class_name ContentDB_static extends RefCounted
## База данных контента. Статический загрузчик.
## В project.godot autoload-обёртка "ContentDB" для совместимости.
## Имя class_name отличается от autoload чтобы не было конфликта.
##
## B3.1: cross-type content ids (e.g. &"regen" in BOTH
## abilities and effects) must coexist. We now maintain:
##   - _by_id (legacy global): first-loaded wins.
##   - _by_id_by_type (typed index): per-type id -> Resource map.
##     Both type variants of the same id coexist here.
## Typed code (e.g. StatusDefResolver) MUST use
## get_by_id_for_type(type_name, id). The global get_by_id() is
## retained for backward compatibility but is no longer the
## source of truth for typed consumers.

const CONTENT_DIRS: Dictionary = {
	"units": "res://content/units/",
	"enemies": "res://content/enemies/",
	"abilities": "res://content/abilities/",
	"effects": "res://content/effects/",
	"items": "res://content/items/",
}

## Legacy global id -> Resource index. For backward compatibility.
## When two same-type resources share an id, the FIRST loaded
## wins; subsequent same-type duplicates are rejected.
static var _by_id: Dictionary = {}
## Per-type id -> Resource index. Keys are type_name strings
## (e.g. "effects"). Values are Dictionary<StringName, Resource>.
## Cross-type duplicate ids are kept in their own per-type maps.
static var _by_id_by_type: Dictionary = {}
## Per-type list of ids in load order. Preserved for legacy
## consumers that rely on the load-order array.
static var _by_type: Dictionary = {}
static var _loaded: bool = false


## Загружает все .tres из CONTENT_DIRS. Вызывай на старте или перед первым доступом.
static func load_all() -> void:
	_by_id.clear()
	_by_id_by_type.clear()
	_by_type.clear()
	for type_name in CONTENT_DIRS.keys():
		_load_dir(type_name, CONTENT_DIRS[type_name])
	_loaded = true
	GameLog.info("content", "Loaded content", {
		"total_resources": _by_id.size(),
		"types": _by_type.keys(),
	})


## Load one type directory into the type-scoped index.
## Same-type duplicates still get rejected (first wins,
## second is logged + skipped). Cross-type duplicates are
## allowed and stored in their respective typed maps.
static func _load_dir(type_name: String, dir_path: String) -> void:
	var ids: Array = []
	var typed: Dictionary = {}
	# ResourceLoader.list_directory() works on both editor AND web builds
	# (DirAccess.open() fails in Web because res:// paths aren't real FS).
	var files: PackedStringArray = ResourceLoader.list_directory(dir_path)
	if files.is_empty():
		GameLog.warn("content", "Directory not found or empty: %s" % dir_path)
		_by_type[type_name] = ids
		_by_id_by_type[type_name] = typed
		return
	for file_name in files:
		if file_name.ends_with(".tres") or file_name.ends_with(".res"):
			var full_path: String = dir_path.path_join(file_name)
			var res: Resource = load(full_path)
			if res == null:
				GameLog.warn("content", "Failed to load: %s" % full_path)
			else:
				var id: StringName = _extract_id(res, file_name)
				if id == &"":
					GameLog.warn("content", "Resource has no id, skipping", {"path": full_path})
				elif typed.has(id):
					# Same-type duplicate: REJECT.
					GameLog.warn("content", "Duplicate id in %s, skipping" % type_name, {
						"id": id, "path": full_path})
				else:
					typed[id] = res
					if not _by_id.has(id):
						# Legacy global index: first across all types
						# wins (preserves current behavior for any
						# legacy consumer that still calls
						# get_by_id()).
						_by_id[id] = res
					ids.append(id)
	_by_type[type_name] = ids
	_by_id_by_type[type_name] = typed


static func _extract_id(res: Resource, fallback_file: String) -> StringName:
	if "id" in res and res.get("id") != null and str(res.get("id")) != "":
		return StringName(String(res.get("id")))
	var stem: String = fallback_file.get_basename()
	return StringName(stem)


static func ensure_loaded() -> void:
	if not _loaded:
		load_all()


## Legacy global lookup. Returns first-loaded resource for id
## across all types. Preserves prior behavior for compatibility
## but typed consumers MUST use get_by_id_for_type() instead.
static func get_by_id(id: StringName) -> Resource:
	ensure_loaded()
	return _by_id.get(id, null)


## B3.1: typed lookup. Returns the Resource registered under
## (type_name, id), or null if either is unknown.
## Same-type duplicates still rejected during load, so this is
## deterministic. Cross-type duplicates are independently stored.
static func get_by_id_for_type(type_name: String, id: StringName) -> Resource:
	ensure_loaded()
	if not _by_id_by_type.has(type_name):
		return null
	var typed: Dictionary = _by_id_by_type[type_name]
	return typed.get(id, null)


## B3.1: returns the array of StringName ids for the given type
## IN LOAD ORDER. Cross-type collisions must NOT remove ids
## from a type's index — both &"regen" in abilities and in
## effects will appear in their respective get_all_ids_for_type().
static func get_all_ids_for_type(type_name: String) -> Array:
	ensure_loaded()
	return _by_type.get(type_name, [])


static func list_by_type(type_name: String) -> Array:
	ensure_loaded()
	return _by_type.get(type_name, [])


## B3.1: returns Resources for the given type IN LOAD ORDER.
## Pulls directly from the per-type id map (not the legacy
## global _by_id) so cross-type duplicates do not
## cross-substitute.
static func list_resources_by_type(type_name: String) -> Array:
	ensure_loaded()
	var result: Array = []
	var typed: Dictionary = _by_id_by_type.get(type_name, {})
	for id in typed.keys():
		var res: Resource = typed[id]
		if res != null:
			result.append(res)
	return result
