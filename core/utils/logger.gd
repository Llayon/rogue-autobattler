class_name GameLog extends RefCounted
## Глобальный логгер. Статические методы через class_name.

const TAG_WIDTH: int = 12

static var _level: int = 1  # INFO


static func set_level(level: int) -> void:
	_level = level


static func debug(tag: String, msg: String, ctx: Dictionary = {}) -> void:
	_log(0, tag, msg, ctx)


static func info(tag: String, msg: String, ctx: Dictionary = {}) -> void:
	_log(1, tag, msg, ctx)


static func warn(tag: String, msg: String, ctx: Dictionary = {}) -> void:
	_log(2, tag, msg, ctx)


static func error(tag: String, msg: String, ctx: Dictionary = {}) -> void:
	_log(3, tag, msg, ctx)


static func _log(level: int, tag: String, msg: String, ctx: Dictionary) -> void:
	if level < _level:
		return
	var level_str: String = _level_name(level)
	var tag_str: String = tag.lpad(TAG_WIDTH, " ")
	var line: String = "[%s] [%s] %s" % [level_str, tag_str, msg]
	if not ctx.is_empty():
		line += " " + str(ctx)
	if level >= 3:
		printerr(line)
	else:
		print(line)


static func _level_name(level: int) -> String:
	if level == 0: return "DEBUG"
	if level == 1: return "INFO "
	if level == 2: return "WARN "
	if level == 3: return "ERROR"
	return "????"