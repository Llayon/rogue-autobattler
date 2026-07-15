class_name SaveService extends RefCounted
## Удобные обёртки над SaveManager для meta и runs.
##
## Хранит пути в одном месте — чтобы не дублировать строки в callers.


static func save_meta(profile: MetaProfile) -> bool:
	if profile == null:
		return false
	return SaveSvc.save_resource(profile, SaveSvc.meta_path())


static func load_meta() -> MetaProfile:
	var res: Resource = SaveSvc.load_resource(SaveSvc.meta_path())
	if res == null:
		return MetaProfile.new()
	if res is MetaProfile:
		return res
	GameLog.warn("save", "Meta resource has unexpected type, returning default", {"type": res.get_class()})
	return MetaProfile.new()


static func save_run(run: RunState) -> bool:
	if run == null:
		return false
	return SaveSvc.save_resource(run, SaveSvc.run_path(run.seed))


static func load_run(seed_value: int) -> RunState:
	var res: Resource = SaveSvc.load_resource(SaveSvc.run_path(seed_value))
	if res == null:
		return null
	if res is RunState:
		return res
	return null


# === S3.3: Save/Load в середине рана ===

## Проверяет, существует ли файл сохранения для этого seed.
static func has_run(seed_value: int) -> bool:
	if seed_value == 0:
		return false
	return FileAccess.file_exists(SaveSvc.run_path(seed_value))


## Удаляет файл сохранения. Возвращает true если файл был удалён.
static func delete_run(seed_value: int) -> bool:
	if seed_value == 0:
		return false
	var path: String = SaveSvc.run_path(seed_value)
	if not FileAccess.file_exists(path):
		return false
	var dir: DirAccess = DirAccess.open(SaveSvc.RUNS_DIR)
	if dir == null:
		GameLog.warn("save", "delete_run: cannot open runs dir", {"path": SaveSvc.RUNS_DIR})
		return false
	var err: int = dir.remove(path.get_file())
	if err != OK:
		GameLog.warn("save", "delete_run failed", {"seed": seed_value, "err": err})
		return false
	return true


## Возвращает seed активного рана из MetaProfile (0 если нет).
static func get_current_run_seed(profile: MetaProfile) -> int:
	if profile == null:
		return 0
	return profile.current_run_seed


## Проверяет, есть ли активный ран и существует ли файл для него.
## Используется UI для кнопки "Continue".
static func has_active_run(profile: MetaProfile) -> bool:
	if profile == null or profile.current_run_seed == 0:
		return false
	return has_run(profile.current_run_seed)


## S3.3: список всех сохранённых ранов (по seed). Используется для UI browse.
## Возвращает Array[int] — seed'ы найденных run_<N>.tres файлов.
static func list_runs() -> Array[int]:
	var result: Array[int] = []
	var dir: DirAccess = DirAccess.open(SaveSvc.RUNS_DIR)
	if dir == null:
		return result
	for fname in dir.get_files():
		if not fname.begins_with("run_") or not fname.ends_with(".tres"):
			continue
		# run_<seed>.tres → seed (4 = "run_", .length()-9 = "-X.tres")
		var seed_str: String = fname.substr(4, fname.length() - 9)
		if seed_str.is_valid_int():
			result.append(int(seed_str))
	return result