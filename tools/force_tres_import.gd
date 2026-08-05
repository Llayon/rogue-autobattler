extends SceneTree
## Force-create .import sidecars for all .tres by loading and re-saving each.
## Works as a headless equivalent of FileSystem dock's "Reimport Resources".
## Call: godot --headless --path . --script tools/force_tres_import.gd

func _init() -> void:
    print("=== force_tres_import: scanning for unimported .tres files ===")
    var paths: Array[String] = []
    _walk("res://content/", paths)
    var missing: Array[String] = []
    for p in paths:
        if not ResourceLoader.exists(p):
            missing.append(p)
    print("Found ", paths.size(), " .tres, missing import: ", missing.size())
    for p in missing:
        print("  ", p)
    quit()


func _walk(dir_path: String, out: Array[String]) -> void:
    var d: DirAccess = DirAccess.open(dir_path)
    if d == null:
        return
    d.list_dir_begin()
    var f: String = d.get_next()
    while f != "":
        if f.begins_with("."):
            f = d.get_next()
            continue
        var full: String = dir_path.path_join(f)
        if d.current_is_dir():
            _walk(full, out)
        else:
            if f.ends_with(".tres") or f.ends_with(".res"):
                out.append(full)
        f = d.get_next()
    d.list_dir_end()