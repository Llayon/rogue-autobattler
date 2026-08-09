class_name RunSaveFileOps extends RefCounted
## Production filesystem adapter for the save layer. Single seam
## for every byte and directory operation; tests inject a fault
## variant via `tests/save_repository/support/run_save_file_ops_fault.gd`.
##
## All methods are deterministic and side-effect free from the
## caller's perspective: success returns true, any error returns
## false. No exceptions are raised.

## Returns true if a file (not a directory) exists at `path`.
func exists(path: String) -> bool:
	return FileAccess.file_exists(path)


## Reads the entire file as raw bytes. Returns an empty buffer if
## the file cannot be opened.
func read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


## Writes the given bytes atomically: opens the file, stores the
## buffer, flushes kernel buffers, closes. Returns true iff the
## file exists on disk afterwards.
func write_bytes_and_flush(path: String, bytes: PackedByteArray) -> bool:
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


## Same-directory rename. Returns true iff Godot reports OK.
func rename(from_path: String, to_path: String) -> bool:
	if not FileAccess.file_exists(from_path):
		return false
	var dir: DirAccess = DirAccess.open(from_path.get_base_dir())
	if dir == null:
		return false
	var err: int = dir.rename(from_path.get_file(), to_path.get_file())
	return err == OK


## Removes a single file. Returns true iff the file no longer
## exists afterwards.
func remove(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var dir: DirAccess = DirAccess.open(path.get_base_dir())
	if dir == null:
		return false
	var err: int = dir.remove(path.get_file())
	if err != OK:
		return false
	return not FileAccess.file_exists(path)


## Returns the SHA-256 hex digest of the file's bytes, or an empty
## string if the file cannot be read.
func sha256(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)