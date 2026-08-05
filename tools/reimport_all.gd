extends SceneTree
## Force-reimport via EditorInterface singleton (editor only).

func _init() -> void:
    print("=== Reimport via EditorInterface ===")
    if not Engine.is_editor_hint():
        print("Must run in editor mode (--editor --script)")
        quit(1)
        return

    var efs: EditorFileSystem = EditorInterface.get_resource_filesystem()
    if efs == null:
        print("No EditorFileSystem from EditorInterface")
        quit(1)
        return
    efs.scan()
    print("EditorFileSystem scan complete")

    var paths: Array[String] = []
    _walk("res://content/", paths)
    print("Reimporting ", paths.size(), " resources...")

    for p in paths:
        efs.update_file(p)

    efs.save()
    print("=== Done ===")
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