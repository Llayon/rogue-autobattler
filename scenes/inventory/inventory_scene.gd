extends Control
## S7.1: Inventory overlay scene.
## Показывается по нажатию I в BattleScene.
## Содержит список предметов в RunController.state.item_ids
## с кнопкой discard для каждого.

## Зависимости (loaded deferred).
const BalanceScript = preload("res://core/balance.gd")

var run_controller: Node = null
var _item_buttons: Array[Button] = []
var _close_button: Button = null
# Пагинация: показ window_size buttons за раз, чтобы инвентарь
# 12-слотов помещался на любом экране.
const WINDOW_SIZE: int = 6
var _scroll_offset: int = 0
# Phase 1 / T3G.1: equip UX. _picked_item_instance_id = "" = nothing picked.
# _is_pick_for_equip = true когда first-click на item эипленный = un-equip request.
# The picked item is identified by RunItem.instance_id, NOT by its
# position in `state.items`. The scene must not remember an item
# array index across events — any rebuild or removal would silently
# shift identity onto the wrong item.
var _picked_item_instance_id: String = ""
var _is_pick_for_equip: bool = false


## Phase 1 / T3G.1: public accessor for cross-scene queries
## (prep_scene uses this to decide whether to forward a board
## click into the equip path).
func is_item_picked() -> bool:
	return _picked_item_instance_id != ""


## Resolve the currently picked item's array index. Returns -1
## if no item is picked OR if the picked item is no longer in
## the domain. Scene code that needs the index for a single
## immediate operation (e.g. style label) may call this, but
## the returned index must NOT be stored across events.
func _current_picked_item_idx() -> int:
	if _picked_item_instance_id == "" or run_controller == null:
		return -1
	var items: Array = run_controller.state.items
	for i in items.size():
		if items[i].instance_id == _picked_item_instance_id:
			return i
	# Picked item was removed from the domain. Drop the stale pick.
	_picked_item_instance_id = ""
	_is_pick_for_equip = false
	return -1


func _ready() -> void:
	_build_background()
	_build_panel()
	if run_controller != null:
		_rebuild()


## Подключить RunController и перестроить UI под его state.
func set_run_controller(ctrl: Node) -> void:
	run_controller = ctrl
	if is_inside_tree():
		_rebuild()


func _build_background() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0.02, 0.04, 0.10, 0.78)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _build_panel() -> void:
	var center: CenterContainer = CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(820, 480)
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)
	# Title.
	var title: Label = Label.new()
	title.name = "Title"
	title.text = "INVENTORY (press I or Close)"
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	# Capacity counter.
	var counter: Label = Label.new()
	counter.name = "Counter"
	counter.text = "0 / 12 items"
	counter.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(counter)
	# Items list.
	var list_box: VBoxContainer = VBoxContainer.new()
	list_box.name = "ItemsList"
	list_box.add_theme_constant_override("separation", 6)
	vbox.add_child(list_box)
	# Empty hint (shown only when inventory is empty).
	var empty_hint: Label = Label.new()
	empty_hint.name = "EmptyHint"
	empty_hint.text = "(inventory is empty — defeat TREASURE nodes for items)"
	empty_hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.75))
	empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	list_box.add_child(empty_hint)
	# Pagination row + Close button.
	var bottom: HBoxContainer = HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 24)
	vbox.add_child(bottom)
	# Prev page button (visible if inventory >= WINDOW_SIZE).
	var prev_btn: Button = Button.new()
	prev_btn.name = "PrevButton"
	prev_btn.text = "< Prev"
	prev_btn.custom_minimum_size = Vector2(80, 40)
	prev_btn.pressed.connect(_on_prev_pressed)
	bottom.add_child(prev_btn)
	# Close.
	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "Close (ESC)"
	_close_button.custom_minimum_size = Vector2(160, 50)
	_close_button.add_theme_font_size_override("font_size", 18)
	_close_button.add_theme_stylebox_override("normal", _make_close_style(Color(0.40, 0.40, 0.50)))
	_close_button.pressed.connect(_on_close_pressed)
	bottom.add_child(_close_button)
	# Next page button.
	var next_btn: Button = Button.new()
	next_btn.name = "NextButton"
	next_btn.text = "Next >"
	next_btn.custom_minimum_size = Vector2(80, 40)
	next_btn.pressed.connect(_on_next_pressed)
	bottom.add_child(next_btn)
	# Apply system font.
	var font: SystemFont = SystemFont.new()
	font.font_names = PackedStringArray([
		"Noto Sans", "Noto Sans CJK", "DejaVu Sans", "Arial", "sans-serif",
	])
	font.allow_system_fallback = true
	for c in [title, counter, empty_hint, _close_button, prev_btn, next_btn]:
		if c is Label:
			c.add_theme_font_override("font", font)
		elif c is Button:
			c.add_theme_font_override("font", font)
	prev_btn.add_theme_font_override("font", font)
	next_btn.add_theme_font_override("font", font)


func _make_panel_style() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.18, 0.96)
	sb.border_color = Color(0.55, 0.65, 0.85, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	return sb


func _make_close_style(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(0.6, 0.6, 0.7, 0.7)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


## Перестраивает items + counter + pagination под текущий state.
func _rebuild() -> void:
	if run_controller == null:
		return
	_clear_item_buttons()
	_build_item_buttons()
	_update_counter()
	_update_pagination()


func _clear_item_buttons() -> void:
	for btn in _item_buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_item_buttons.clear()


func _build_item_buttons() -> void:
	var list: VBoxContainer = get_node_or_null("Center/Panel/VBox/ItemsList")
	if list == null:
		return
	var empty_hint: Label = get_node_or_null("Center/Panel/VBox/ItemsList/EmptyHint")
	var total: int = run_controller.inventory_count()
	if total == 0:
		if empty_hint != null:
			empty_hint.visible = true
		return
	# Hide empty hint.
	if empty_hint != null:
		empty_hint.visible = false
	# Build buttons for current page window.
	var end_idx: int = mini(_scroll_offset + WINDOW_SIZE, total)
	for i in range(_scroll_offset, end_idx):
		var def: Resource = run_controller.get_item_def_at(i)
		var btn: Button = _make_item_button(i, def)
		list.add_child(btn)
		_item_buttons.append(btn)


func _make_item_button(idx: int, def: Resource) -> Button:
	var btn: Button = Button.new()
	btn.name = "Item_%d" % idx
	btn.custom_minimum_size = Vector2(720, 56)
	if def != null:
		# Show name + bonuses + tier/cost + optional equip marker.
		var bonuses: Array = []
		if def.bonus_attack > 0:
			bonuses.append("+%d ATK" % def.bonus_attack)
		if def.bonus_defense > 0:
			bonuses.append("+%d DEF" % def.bonus_defense)
		if def.bonus_max_hp > 0:
			bonuses.append("+%d HP" % def.bonus_max_hp)
		var bonus_str: String = " ".join(bonuses) if not bonuses.is_empty() else "(passive)"
		var equipped_marker: String = ""
		if run_controller != null:
			var board_idx: int = run_controller.get_equipped_board_idx(idx)
			if board_idx >= 0:
				equipped_marker = "  [EQUIPPED: board %d]" % board_idx
		var picked_marker: String = ""
		if run_controller != null:
			var items_arr: Array = run_controller.state.items
			if idx >= 0 and idx < items_arr.size():
				if items_arr[idx].instance_id == _picked_item_instance_id:
					picked_marker = "  [PICKED]"
		var line1: String = "%s  [tier %d, cost %d]%s%s" % [def.display_name, def.tier, def.cost, equipped_marker, picked_marker]
		btn.text = line1 + "\n" + bonus_str + " — click to discard/equip"
	else:
		var id_str: String = str(run_controller.state.items[idx].definition_id)
		btn.text = "(" + id_str + ") — click to discard/equip"
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(_on_item_pressed.bind(idx))
	_apply_item_style(btn)
	return btn


func _apply_item_style(btn: Button) -> void:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.18, 0.22, 0.32)
	sb.border_color = Color(0.55, 0.55, 0.65, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	btn.add_theme_stylebox_override("normal", sb)


func _update_counter() -> void:
	var counter: Label = get_node_or_null("Center/Panel/VBox/Counter")
	if counter == null:
		return
	var total: int = run_controller.inventory_count()
	var max_inv: int = BalanceScript.MAX_INVENTORY
	counter.text = "%d / %d items" % [total, max_inv]


func _update_pagination() -> void:
	var prev: Button = get_node_or_null("Center/Panel/VBox/PrevButton")
	var next: Button = get_node_or_null("Center/Panel/VBox/NextButton")
	if prev == null or next == null:
		return
	var total: int = run_controller.inventory_count()
	prev.visible = (_scroll_offset > 0)
	next.visible = (_scroll_offset + WINDOW_SIZE < total)


func _on_item_pressed(idx: int) -> void:
	if run_controller == null:
		return
	if idx < 0 or idx >= run_controller.inventory_count():
		return
	# Phase 1 / T3G.1: resolve idx → instance_id immediately. The idx
	# itself is only valid for this single call.
	var items_arr: Array = run_controller.state.items
	if idx < 0 or idx >= items_arr.size():
		return
	var clicked_id: String = items_arr[idx].instance_id
	# 3-state click flow keyed on instance_id.
	# 1) Nothing picked: pick item.
	if _picked_item_instance_id == "":
		# Special case: item уже эипится → single click unequips (UX shortcut).
		var current_board: int = run_controller.get_equipped_board_idx(idx)
		if current_board >= 0:
			run_controller.unequip_item_by_id(clicked_id)
			_rebuild()
			return
		_picked_item_instance_id = clicked_id
		_is_pick_for_equip = true
		_rebuild()
		return
	# 2) Click same item = cancel pick.
	if _picked_item_instance_id == clicked_id:
		_picked_item_instance_id = ""
		_is_pick_for_equip = false
		_rebuild()
		return
	# 3) Click different item = replace pick.
	_picked_item_instance_id = clicked_id
	_rebuild()


## S7.2: вызывается из PREP scene когда игрок нажал board unit
## (только если в инвентаре есть _picked_item_instance_id).
## Возвращает true если equip сработал.
func try_equip_to_board(board_idx: int) -> bool:
	if run_controller == null:
		return false
	if _picked_item_instance_id == "" or not _is_pick_for_equip:
		return false
	# Translate the clicked board slot to its current RunUnit.instance_id.
	var board: Array[RunUnit] = run_controller.state.get_board_units()
	if board_idx < 0 or board_idx >= board.size():
		return false
	var target_unit_id: String = board[board_idx].instance_id
	var ok: bool = run_controller.equip_item_by_id(
		_picked_item_instance_id, target_unit_id)
	if ok:
		_picked_item_instance_id = ""
		_is_pick_for_equip = false
		_rebuild()
	return ok


func _on_close_pressed() -> void:
	visible = false


func _on_prev_pressed() -> void:
	_scroll_offset = maxi(0, _scroll_offset - WINDOW_SIZE)
	_rebuild()


func _on_next_pressed() -> void:
	if run_controller == null:
		return
	var total: int = run_controller.inventory_count()
	_scroll_offset = mini(_scroll_offset + WINDOW_SIZE, maxi(0, total - WINDOW_SIZE))
	_rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_I, KEY_ESCAPE:
				if visible:
					visible = false
					get_viewport().set_input_as_handled()
