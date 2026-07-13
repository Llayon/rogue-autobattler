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