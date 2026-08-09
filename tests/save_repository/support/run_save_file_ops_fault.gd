# Test-only filesystem fault-injection adapter. Has NO global
# `class_name` so it cannot be referenced by production code. Tests
# preload it directly:
#
#   const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")
#
# `fail_methods` is a `Dictionary[StringName, bool]`. When a method's
# key is present and true, that method short-circuits to a failing
# value (false or empty). Otherwise it delegates to the Godot
# production path the same way `RunSaveFileOps` does.
extends RefCounted

var fail_methods: Dictionary = {}


func exists(path: String) -> bool:
	if fail_methods.get(&"exists", false):
		return false
	return FileAccess.file_exists(path)


func read_bytes(path: String) -> PackedByteArray:
	if fail_methods.get(&"read_bytes", false):
		return PackedByteArray()
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


func write_bytes_and_flush(path: String, bytes: PackedByteArray) -> bool:
	if fail_methods.get(&"write_bytes_and_flush", false):
		return false
	var dir_path: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.flush()
	f.close()
	return FileAccess.file_exists(path)


func rename(from_path: String, to_path: String) -> bool:
	if fail_methods.get(&"rename", false):
		return false
	if not FileAccess.file_exists(from_path):
		return false
	var dir: DirAccess = DirAccess.open(from_path.get_base_dir())
	if dir == null:
		return false
	var err: int = dir.rename(from_path.get_file(), to_path.get_file())
	return err == OK


func remove(path: String) -> bool:
	if fail_methods.get(&"remove", false):
		return false
	if not FileAccess.file_exists(path):
		return false
	var dir: DirAccess = DirAccess.open(path.get_base_dir())
	if dir == null:
		return false
	var err: int = dir.remove(path.get_file())
	if err != OK:
		return false
	return not FileAccess.file_exists(path)


func sha256(path: String) -> String:
	if fail_methods.get(&"sha256", false):
		return ""
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)