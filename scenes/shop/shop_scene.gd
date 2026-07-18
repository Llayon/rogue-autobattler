extends Control
## S7.4: Shop overlay (MERCHANT encounter).
## Показывается на phase=PREP когда пришли с MERCHANT.
## 3 items по discounted price + Close button.

var run_controller: Node = null
var _item_buttons: Array[Button] = []
var _close_button: Button = null


func _ready() -> void:
	_build_background()
	_build_panel()
	if run_controller != null:
		_rebuild()


func set_run_controller(ctrl: Node) -> void:
	run_controller = ctrl
	if is_inside_tree():
		_rebuild()


func _build_background() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0.06, 0.04, 0.10, 0.82)
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
	title.text = "SHOP (50% off!) — press SPACE/ESC to leave"
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.65))
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	# Gold counter.
	var counter: Label = Label.new()
	counter.name = "Counter"
	counter.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(counter)
	# Items list.
	var list_box: VBoxContainer = VBoxContainer.new()
	list_box.name = "ItemsList"
	list_box.add_theme_constant_override("separation", 8)
	vbox.add_child(list_box)
	# Close row.
	var bottom: HBoxContainer = HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 16)
	vbox.add_child(bottom)
	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "Leave Shop"
	_close_button.custom_minimum_size = Vector2(160, 50)
	_close_button.add_theme_font_size_override("font_size", 18)
	_close_button.add_theme_stylebox_override("normal",
		_make_btn_style(Color(0.55, 0.50, 0.30)))
	_close_button.pressed.connect(_on_close_pressed)
	bottom.add_child(_close_button)
	# Apply system font.
	var font: SystemFont = SystemFont.new()
	font.font_names = PackedStringArray([
		"Noto Sans", "Noto Sans CJK", "DejaVu Sans", "Arial", "sans-serif",
	])
	font.allow_system_fallback = true
	for c in [title, counter, _close_button]:
		if c is Label:
			c.add_theme_font_override("font", font)
		elif c is Button:
			c.add_theme_font_override("font", font)


func _make_panel_style() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.10, 0.06, 0.96)
	sb.border_color = Color(1.0, 0.85, 0.4, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	return sb


func _make_btn_style(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(1.0, 0.85, 0.4, 0.7)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _rebuild() -> void:
	_clear_item_buttons()
	_build_item_buttons()
	_update_counter()


func _clear_item_buttons() -> void:
	for btn in _item_buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_item_buttons.clear()


func _build_item_buttons() -> void:
	var list: VBoxContainer = get_node_or_null("Center/Panel/VBox/ItemsList")
	if list == null:
		return
	var offered: int = run_controller.shop.get_offered_count()
	for i in offered:
		var def: Resource = run_controller.shop.get_item_def(i)
		var price: int = run_controller.shop.get_discounted_price(i)
		# Row: name + bonuses | Buy button.
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		list.add_child(row)
		var info: Label = Label.new()
		info.custom_minimum_size = Vector2(540, 50)
		if def != null:
			var bonuses: Array = []
			if def.bonus_attack > 0:
				bonuses.append("+%d ATK" % def.bonus_attack)
			if def.bonus_defense > 0:
				bonuses.append("+%d DEF" % def.bonus_defense)
			if def.bonus_max_hp > 0:
				bonuses.append("+%d HP" % def.bonus_max_hp)
			var bonus_str: String = " ".join(bonuses) if not bonuses.is_empty() else "(passive)"
			var line1: String = "%s  [tier %d, was %d g]" % [def.display_name, def.tier, def.cost]
			info.text = line1 + "\n" + bonus_str + "  —  now %d g (50 percent off)" % price
		else:
			info.text = "(unknown item slot %d)" % i
		info.add_theme_font_size_override("font_size", 14)
		info.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(info)
		var buy_btn: Button = Button.new()
		buy_btn.name = "BuyItem_%d" % i
		buy_btn.text = "BUY\n%d g" % price
		buy_btn.custom_minimum_size = Vector2(120, 50)
		buy_btn.add_theme_font_size_override("font_size", 14)
		buy_btn.add_theme_stylebox_override("normal",
			_make_btn_style(Color(0.40, 0.55, 0.30)))
		buy_btn.pressed.connect(_on_buy_pressed.bind(i))
		row.add_child(buy_btn)
		_item_buttons.append(buy_btn)


func _update_counter() -> void:
	var counter: Label = get_node_or_null("Center/Panel/VBox/Counter")
	if counter != null:
		counter.text = "Your gold: %d" % run_controller.state.gold


func _on_buy_pressed(slot: int) -> void:
	if run_controller == null:
		return
	if run_controller.buy_item(slot):
		_update_counter()
		# Light rebuild (item is consumed — leave slot empty but keep number).
		# Actually slot stays valid, just decrements gold.
		# Re-check if we can still afford remaining items by re-rendering buttons.
		for btn in _item_buttons:
			var i: int = btn.name.trim_prefix("BuyItem_").to_int()
			var price: int = run_controller.shop.get_discounted_price(i)
			btn.disabled = run_controller.state.gold < price or run_controller.inventory_count() >= 12


func _on_close_pressed() -> void:
	if run_controller != null:
		run_controller.exit_shop_to_map()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE, KEY_SPACE:
				if visible:
					_on_close_pressed()
					get_viewport().set_input_as_handled()
