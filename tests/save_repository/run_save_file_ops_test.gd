extends SceneTree

## Tests for the production filesystem adapter and the
## fault-injection adapter. The fault-injection adapter lives in
## `tests/save_repository/support/run_save_file_ops_fault.gd` and
## has NO global `class_name`.

const ProductionOps = preload("res://core/save/run_save_file_ops.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== run save file ops tests ===\n")
	_test_production_exists_true_when_file_present()
	_test_production_exists_false_when_file_absent()
	_test_production_read_bytes_round_trips()
	_test_production_write_bytes_and_flush_writes_exact_bytes()
	_test_production_rename_returns_false_when_source_missing()
	_test_production_remove_deletes_file()
	_test_production_remove_returns_false_when_missing()
	_test_production_sha256_matches_known_vector()
	_test_fault_adapter_can_disable_write_bytes_and_flush()
	_test_fault_adapter_can_disable_rename()
	_test_fault_adapter_can_disable_remove()
	_test_fault_adapter_does_not_register_a_global_class_name()
	print("\n=== run save file ops: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		print("  [OK]   %s" % message)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % message)


# ---------------------------------------------------------------------------
# Production adapter tests (in a temp dir under user://)
# ---------------------------------------------------------------------------

func _isolated_root() -> String:
	_test_counter += 1
	var p: String = "user://run_save_file_ops_test_%d/" % _test_counter
	DirAccess.make_dir_recursive_absolute(p)
	return p

var _test_counter: int = 0

func _cleanup_root(p: String) -> void:
	var d: DirAccess = DirAccess.open(p)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		var sd: DirAccess = DirAccess.open(p + sub + "/")
		if sd != null:
			for f2 in sd.get_files():
				sd.remove(f2)
		d.remove(sub)


func _test_production_exists_true_when_file_present() -> void:
	print("[production] exists returns true when file present")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	var p: String = root + "alpha.bin"
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	f.store_line("hello")
	f.close()
	_assert(ops.exists(p) == true, "exists()=true for present file")
	_cleanup_root(root)


func _test_production_exists_false_when_file_absent() -> void:
	print("[production] exists returns false when file absent")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	_assert(ops.exists(root + "missing.bin") == false, "exists()=false for absent file")
	_cleanup_root(root)


func _test_production_read_bytes_round_trips() -> void:
	print("[production] read_bytes round-trips")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	var p: String = root + "rt.bin"
	var payload: PackedByteArray = "abc\u0001\u0002".to_utf8_buffer()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(payload)
	f.close()
	var got: PackedByteArray = ops.read_bytes(p)
	_assert(got == payload, "read_bytes returns the same bytes that were written")
	_cleanup_root(root)


func _test_production_write_bytes_and_flush_writes_exact_bytes() -> void:
	print("[production] write_bytes_and_flush writes exact bytes")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	var p: String = root + "wf.bin"
	var payload: PackedByteArray = "exact bytes".to_utf8_buffer()
	_assert(ops.write_bytes_and_flush(p, payload) == true, "write_bytes_and_flush returns true")
	var got: PackedByteArray = ops.read_bytes(p)
	_assert(got == payload, "on-disk bytes equal input bytes")
	_cleanup_root(root)


func _test_production_rename_returns_false_when_source_missing() -> void:
	print("[production] rename returns false when source missing")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	var src: String = root + "no_such.bin"
	var dst: String = root + "dst.bin"
	_assert(ops.rename(src, dst) == false, "rename returns false when source does not exist")
	_cleanup_root(root)


func _test_production_remove_deletes_file() -> void:
	print("[production] remove deletes a file")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	var p: String = root + "del.bin"
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	f.store_line("x")
	f.close()
	_assert(ops.remove(p) == true, "remove returns true for an existing file")
	_assert(ops.exists(p) == false, "file no longer exists after remove")
	_cleanup_root(root)


func _test_production_remove_returns_false_when_missing() -> void:
	print("[production] remove returns false when file missing")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	_assert(ops.remove(root + "absent.bin") == false, "remove returns false when missing")
	_cleanup_root(root)


func _test_production_sha256_matches_known_vector() -> void:
	print("[production] sha256 matches the known vector for exact 3-byte 'abc'")
	var ops: RefCounted = ProductionOps.new()
	var root: String = _isolated_root()
	var p: String = root + "abc.bin"
	# Use store_buffer to write exactly three bytes 'a','b','c' (no
	# trailing newline). SHA-256("abc") =
	# ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
	var payload: PackedByteArray = "abc".to_utf8_buffer()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(payload)
	f.close()
	var expected: String = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	var got: String = ops.sha256(p)
	_assert(got == expected, "sha256('abc') matches the published vector")
	_cleanup_root(root)


# ---------------------------------------------------------------------------
# Fault-injection adapter tests
# ---------------------------------------------------------------------------

func _test_fault_adapter_can_disable_write_bytes_and_flush() -> void:
	print("[fault] can disable write_bytes_and_flush")
	var root: String = _isolated_root()
	var fault: RefCounted = FaultOps.new()
	fault.fail_methods["write_bytes_and_flush"] = true
	var p: String = root + "no_write.bin"
	_assert(fault.write_bytes_and_flush(p, "x".to_utf8_buffer()) == false,
		"fault.write_bytes_and_flush returns false when disabled")
	_assert(fault.exists(p) == false, "no file is created when fault is engaged")
	_cleanup_root(root)


func _test_fault_adapter_can_disable_rename() -> void:
	print("[fault] can disable rename")
	var root: String = _isolated_root()
	var fault: RefCounted = FaultOps.new()
	fault.fail_methods["rename"] = true
	# Pre-create a source file so production rename would otherwise succeed.
	var src: String = root + "src.bin"
	var dst: String = root + "dst.bin"
	var f: FileAccess = FileAccess.open(src, FileAccess.WRITE)
	f.store_line("x")
	f.close()
	_assert(fault.rename(src, dst) == false, "fault.rename returns false when disabled")
	# The source is untouched because the production path is bypassed.
	_assert(fault.exists(src) == true, "source untouched when rename fault engaged")
	_cleanup_root(root)


func _test_fault_adapter_can_disable_remove() -> void:
	print("[fault] can disable remove")
	var root: String = _isolated_root()
	var fault: RefCounted = FaultOps.new()
	fault.fail_methods["remove"] = true
	var p: String = root + "del.bin"
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	f.store_line("x")
	f.close()
	_assert(fault.remove(p) == false, "fault.remove returns false when disabled")
	_assert(fault.exists(p) == true, "file still exists when remove fault engaged")
	_cleanup_root(root)


func _test_fault_adapter_does_not_register_a_global_class_name() -> void:
	print("[fault] the test helper has no global class_name line")
	var text: String = FileAccess.get_file_as_string("res://tests/save_repository/support/run_save_file_ops_fault.gd")
	var first_line: String = text.substr(0, text.find("\n") if text.find("\n") >= 0 else text.length())
	_assert(not first_line.begins_with("class_name"),
		"first line of fault adapter is NOT 'class_name ...': got '%s'" % first_line)