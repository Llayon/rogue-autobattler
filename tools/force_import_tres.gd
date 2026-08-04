extends SceneTree
## Force generation of .import sidecar files for all .tres resources.
## Called via --headless --script tools/force_import_tres.gd in CI before build.
## Without .import files, Godot 4.7 Web build's pck contains .tres data
## but ResourceLoader.load() returns null at runtime.

const _ext := ".tres"
const _res := ".res"

func _init() -> void:
    print("=== force_import_tres: scanning project ===")
    var content_root: DirAccess = DirAccess.open("res://content/")
    if content_root == null:
        push_error("cannot open res://content/")
        quit(1)
        return

    var tres_paths: Array[String] = []
    _walk_dir("res://content/", tres_paths)
    print("Found ", tres_paths.size(), " .tres/.res files")

    var imported: int = 0
    var failed: int = 0
    for path in tres_paths:
        var res: Resource = load(path)
        if res == null:
            print("  [FAIL] load returned null: ", path)
            failed += 1
            continue
        # Save back to force Godot to write .import sidecar.
        var err: int = ResourceSaver.save(res, path)
        if err != OK:
            print("  [FAIL] ResourceSaver.save err=", err, " path=", path)
            failed += 1
        else:
            imported += 1
    print("=== Result: ", imported, " imported, ", failed, " failed ===")
    quit(0 if failed == 0 else 1)


func _walk_dir(dir_path: String, out: Array[String]) -> void:
    var dir: DirAccess = DirAccess.open(dir_path)
    if dir == null:
        return
    dir.list_dir_begin()
    var f: String = dir.get_next()
    while f != "":
        if f.begins_with("."):
            f = dir.get_next()
            continue
        var full: String = dir_path.path_join(f)
        if dir.current_is_dir():
            _walk_dir(full, out)
        else:
            if f.ends_with(_ext) or f.ends_with(_res):
                out.append(full)
        f = dir.get_next()
    dir.list_dir_end()