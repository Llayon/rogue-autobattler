class_name SaveSvc extends RefCounted
## Сервис сохранения/загрузки с поддержкой миграций.
## В project.godot autoload-обёртка "SaveManager" (Node).
##
## Структура на диске:
##   user://saves/meta.tres
##   user://saves/runs/<seed>.tres

const SAVE_DIR: String = "user://saves/"
const META_SAVE_PATH: String = SAVE_DIR + "meta.tres"
const RUNS_DIR: String = SAVE_DIR + "runs/"

const SAVE_VERSION: int = 1


static func _static_init() -> void:
	_ensure_dirs()


static func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if not DirAccess.dir_exists_absolute(RUNS_DIR):
		DirAccess.make_dir_recursive_absolute(RUNS_DIR)


static func save_resource(res: Resource, path: String) -> bool:
	if "version" in res:
		res.set("version", SAVE_VERSION)
	_ensure_dirs()
	var err: int = ResourceSaver.save(res, path)
	if err != OK:
		GameLog.error("save", "Failed to save", {"path": path, "err": err})
		return false
	return true


static func load_resource(path: String) -> Resource:
	if not FileAccess.file_exists(path):
		return null
	var res: Resource = load(path)
	if res == null:
		GameLog.error("save", "Failed to load", {"path": path})
		return null
	if "version" in res:
		var v: int = int(res.get("version"))
		if v != SAVE_VERSION:
			res = _migrate(res, v)
	return res


static func _migrate(res: Resource, v_from: int) -> Resource:
	GameLog.info("save", "Migrating", {"from": v_from, "to": SAVE_VERSION})
	# Заготовка для будущих миграций:
	# if v_from < 2:
	#     res = _migrate_v1_to_v2(res)
	if "version" in res:
		res.set("version", SAVE_VERSION)
	return res


static func meta_path() -> String:
	return META_SAVE_PATH


static func run_path(seed_value: int) -> String:
	return RUNS_DIR + "run_%d.tres" % seed_value