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

## A0.1: the number of CALLS that still succeed before the method
## starts failing. Zero means "fail from the first call". It is the
## knob for "the first rename succeeds, the second fails" -- the
## window between the two renames of the commit protocol.
var fail_after: int = 0

## A0.1: the write SUCCEEDS but the bytes that land are garbage.
## This is the "the write was interrupted" case that a plain failure
## cannot express: the operation reports success and the file is
## corrupt.
var corrupt_write: bool = false

## The call counters of the injected methods.
var _calls: Dictionary = {}


func _should_fail(theMethod: StringName) -> bool:
	var theCount: int = int(_calls.get(theMethod, 0))
	_calls[theMethod] = theCount + 1
	if not fail_methods.get(theMethod, false):
		return false
	return theCount >= fail_after


func exists(path: String) -> bool:
	if _should_fail(&"exists"):
		return false
	return FileAccess.file_exists(path)


func read_bytes(path: String) -> PackedByteArray:
	if _should_fail(&"read_bytes"):
		return PackedByteArray()
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


func write_bytes_and_flush(path: String, bytes: PackedByteArray) -> bool:
	if _should_fail(&"write_bytes_and_flush"):
		return false
	var dir_path: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	if corrupt_write:
		# The write "succeeds", but what lands is not the profile.
		f.store_string("[gd_resource type=\"Resource\" format=3 uid=\"uid://a01corrupt\"]\n\n[resource]\nresource_name = \"corrupt\"\n")
	else:
		f.store_buffer(bytes)
	f.flush()
	f.close()
	return FileAccess.file_exists(path)


func rename(from_path: String, to_path: String) -> bool:
	if _should_fail(&"rename"):
		return false
	if not FileAccess.file_exists(from_path):
		return false
	var dir: DirAccess = DirAccess.open(from_path.get_base_dir())
	if dir == null:
		return false
	var err: int = dir.rename(from_path.get_file(), to_path.get_file())
	return err == OK


func remove(path: String) -> bool:
	if _should_fail(&"remove"):
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
	if _should_fail(&"sha256"):
		return ""
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)