class_name SaveService extends RefCounted
## Удобные обёртки над SaveManager для meta и runs.
##
## Хранит пути в одном месте — чтобы не дублировать строки в callers.
##
## Phase 1 / T3C adds the v4 persistence façade (`save_run_v4` /
## `load_run_v4`) that hands a v4 DTO to the hardened
## `RunSaveRepository`. The legacy Resource-based APIs
## (`save_run` / `load_run`) stay in place until T3D switches
## `RunController` over to the v4 pipeline.

const RunSaveRepositoryScript = preload(
	"res://core/save/run_save_repository.gd")


# --------------------------------------------------------------------
# Legacy Resource APIs (kept until T3D)
# --------------------------------------------------------------------


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



# --------------------------------------------------------------------
# Phase 1 / T3C — v4 persistence façade
# --------------------------------------------------------------------
#
# SaveService does NOT know about RunDomainState / RunUnit /
# RunItem. The mapper (RunStateV4Mapper) owns the boundary
# between the live domain and the v4 DTO; this façade owns only
# the persistence DTO shape and the call into RunSaveRepository.
#
# Returned objects are SaveLoadResult RefCounted instances. They
# preserve the typed status and diagnostics the hardened
# repository already produces. The façade NEVER collapses the
# result to a bool.

## Produces a fresh `RunSaveRepository` pointing at the default
## `SaveSvc.RUNS_DIR`. Used by the production `save_run_v4` /
## `load_run_v4` paths. Tests should NOT call this; they should
## pass their own repository into the `_with_repository` seam.
static func _run_repository() -> RefCounted:
	return RunSaveRepositoryScript.new(SaveSvc.RUNS_DIR)


## Saves a v4 DTO for `seed_value` through a fresh
## `RunSaveRepository`. The DTO shape must be valid v4; the
## repository validates it. Returns a `SaveLoadResult`.
static func save_run_v4(seed_value: int, dto: Dictionary) -> RefCounted:
	return _save_run_v4_with_repository(seed_value, dto, _run_repository())


## Loads a v4 DTO (or migrates legacy v1) for `seed_value`
## through a fresh `RunSaveRepository`. Returns a
## `SaveLoadResult` whose `data` is the canonical v4 DTO when the
## status is `OK`.
static func load_run_v4(seed_value: int) -> RefCounted:
	return _load_run_v4_with_repository(seed_value, _run_repository())


## Test-only seam. Production must use `save_run_v4` /
## `load_run_v4`. Tests pass a repository pointing at an isolated
## temp directory so they do not touch `user://saves/runs`.
static func _save_run_v4_with_repository(
		seed_value: int, dto: Dictionary,
		repository: RefCounted) -> RefCounted:
	return repository.save_run(seed_value, dto)


static func _load_run_v4_with_repository(
		seed_value: int,
		repository: RefCounted) -> RefCounted:
	return repository.load_run(seed_value)


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