extends SceneTree
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
func _initialize() -> void:
	var dir: String = "user://ri_probe4/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var dto: Dictionary = {
		"schema_version": 5, "game_build": "", "run_id": "run_777", "seed": 777,
		"round_index": 1, "phase": "prep", "gold": 0,
		"units": [{"instance_id": "unit_000001", "definition_id": &"warrior",
			"current_hp": 10, "max_hp": 10, "bonus_attack": 0, "dead": false,
			"location": 0, "order": 0, "equipped_item_ids": []}],
		"items": [{"instance_id": "item_000001", "definition_id": &"potion_strength",
			"owner_unit_id": "unit_000001"}],
		"next_unit_instance_seq": 2, "next_item_instance_seq": 2,
		"shop": {}, "map": {}, "rewards": {},
		"rng": {"seed": 777, "state": "1234567890123456789"},
		"wins": 0, "losses": 0, "units_killed": 0, "lives": 3, "xp": 0,
		"level": 1, "current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}
	var repo = RunSaveRepositoryScript.new(dir)
	var r: RefCounted = repo._save_canonical(777, dto, "v5")
	print("RESULT is_ok=", str(r.is_ok()), " status=", str(r.get("status")))
	var files: PackedStringArray = DirAccess.get_files_at(ProjectSettings.globalize_path(dir))
	print("RESULT files=", str(files.size()))
	for f in files:
		print("RESULT file: ", f)
	quit(0)
