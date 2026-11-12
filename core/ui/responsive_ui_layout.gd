extends RefCounted

## Единая адаптация интерфейса под размер экрана.
##
## ## Зачем
##
## Базовый viewport игры — 1280x720, а `project.godot` использует
## `canvas_items + expand`. При `expand` viewport сохраняет базовую
## ШИРИНУ (1280), а высота следует за соотношением сторон окна, и весь
## viewport затем масштабируется в канвас множителем
## `canvas.width / 1280`.
##
## На телефоне 390x844 этот множитель равен 0.305, поэтому весь
## интерфейс — включая шрифты — уменьшается в 3.3 раза: `font_size=14`
## даёт 4.3 CSS px, кнопка 120x50 даёт 37x15 CSS px. Интерфейс
## присутствует, но нечитаем и непригоден для касания.
##
## ## Правило
##
## Игровая область может масштабироваться. Интерфейс — нет: он должен
## иметь читаемый физический размер. Поэтому:
##
## - `scale` — множитель, который СЕЙЧАС применяет движок к viewport'у.
## - На десктопе `scale == 1` (1280x720 -> канвас 1280x720), поэтому
##   существующие размеры остаются как есть, и регресс невозможен по
##   построению.
## - На телефоне `scale < 1`; интерфейс рисуется в base-space, но его
##   корневой узел получает `scale = 1 / scale`, то есть возвращает
##   себе исходный физический размер. Базовые координаты остаются
##   теми же — меняется только множитель.
##
## Итог: базовые координаты сцен не меняются, движок по-прежнему
## сжимает их в канвас, а UI-слой компенсирует это своим собственным
## масштабом. На десктопе компенсация равна 1 и ничего не меняется.

## Минимальный размер интерактивной области в физических (CSS) пикселях.
const MIN_TOUCH_PX: float = 44.0

## Минимальный читаемый размер шрифта в физических (CSS) пикселях.
const MIN_FONT_PX: int = 14

## Базовая ширина viewport'а: 1280 (project.godot).
const BASE_WIDTH: float = 1280.0

## Базовая высота viewport'а: 720 (project.godot).
const BASE_HEIGHT: float = 720.0

## Режим отображения.
enum Mode {
	DESKTOP, ## Базовый viewport помещается: компенсация не нужна.
	MOBILE,  ## Интерфейс меньше базового: UI масштабируется обратно.
}

var mode: int = Mode.DESKTOP

## Множитель, который движок применяет к viewport'у (canvas.width/1280).
var engine_scale: float = 1.0

## Множитель, который UI-слой применяет к себе, чтобы вернуть
## физический размер: 1.0 на десктопе, 1/engine_scale на телефоне.
var ui_scale: float = 1.0

## Доступная ширина интерфейса в физических (CSS) пикселях.
var view_width: float = BASE_WIDTH

## Доступная высота интерфейса в физических (CSS) пикселях.
var view_height: float = BASE_HEIGHT


## Вычисляет режим по размеру окна.
##
## `window_size` — размер канваса в физических пикселях.
static func from_window(window_size: Vector2) -> RefCounted:
	var layout = new()
	layout.mode = Mode.DESKTOP if window_size.x >= BASE_WIDTH else Mode.MOBILE
	# Движок с `canvas_items + expand` масштабирует viewport по ширине.
	layout.engine_scale = window_size.x / BASE_WIDTH
	if layout.engine_scale <= 0.0:
		layout.engine_scale = 1.0
	layout.ui_scale = 1.0 if layout.mode == Mode.DESKTOP else (1.0 / layout.engine_scale)
	layout.view_width = window_size.x
	layout.view_height = window_size.y
	return layout


## Применяет компенсацию к корневому UI-узлу.
##
## Узел должен быть растянут на весь viewport (`PRESET_FULL_RECT`).
## Его `scale` становится `ui_scale`, а `pivot_offset` — центром, чтобы
## компенсация не смещала содержимое.
func apply_to(root: Control) -> void:
	if root == null:
		return
	# The root's scale stays 1: scaling it would push its anchored
	# edges off-screen (a PRESET_TOP_WIDE bar would start at -445
	# physical px on a 390-wide phone). The compensation lives in the
	# SIZES instead: a physical size P is expressed in the base space
	# as P / engine_scale.
	root.scale = Vector2.ONE
	root.pivot_offset = Vector2.ZERO


## Возвращает размер панели, который помещается в экран.
##
## `desired` — желаемый размер в base-space. Результат — тот же размер,
## ограниченный доступным местом с учётом компенсации.
func fit(desired: Vector2, margin: float = 0.0) -> Vector2:
	if mode == Mode.DESKTOP:
		return desired
	# On a phone the panel FILLS the available space: the base space is
	# the physical space divided by the engine's scale, so the whole
	# width in the base space is view_width / engine_scale.
	var theMaxW: float = maxf(120.0, (view_width - margin * 2.0) / engine_scale)
	var theMaxH: float = maxf(120.0, (view_height - margin * 2.0) / engine_scale)
	return Vector2(theMaxW, theMaxH)


## Физический (CSS) размер элемента с заданным base-space размером.
func physical(base_size: Vector2) -> Vector2:
	return base_size * engine_scale


## Переводит физический размер в base-space.
##
## Это ОБРАТНАЯ операция к `physical`: физический размер P становится
## base-space числом P / engine_scale, чтобы после движкового
## масштабирования он снова занимал P физических пикселей.
##
## Ею переводятся separations, margins, offsets и любые другие длины:
## на десктопе engine_scale == 1 и ничего не меняется.
func px(physical_px: float) -> float:
	if mode == Mode.DESKTOP:
		return physical_px
	return physical_px / engine_scale


## То же для целых чисел (separation, margins).
func px_i(physical_px: int) -> int:
	return int(round(px(float(physical_px))))


## Физический размер шрифта: base-size, приведённый к читаемому.
##
## На десктопе возвращает base-size без изменений. На телефоне
## возвращает максимум из масштабированного и `MIN_FONT_PX`, чтобы
## текст оставался читаемым даже при сильном уменьшении.
func font_px(base_px: int) -> int:
	if mode == Mode.DESKTOP:
		return base_px
	# The engine shrinks the viewport by `engine_scale`, so the base
	# size has to be DIVIDED by it to keep the physical size. (The
	# `ui_scale` is its inverse, so dividing by that would multiply.)
	return maxi(MIN_FONT_PX, int(round(float(base_px) / engine_scale)))


## Физический размер интерактивной области с заданным base-space размером.
##
## Гарантирует не меньше `MIN_TOUCH_PX` по обеим сторонам, чтобы
## палец попадал в кнопку.
func touch_px(base_size: Vector2) -> Vector2:
	if mode == Mode.DESKTOP:
		return base_size
	# The base-space size is DIVIDED by the engine's scale, so the
	# element keeps its physical size -- and then raised to the touch
	# floor.
	var theW: float = maxf(base_size.x / engine_scale, MIN_TOUCH_PX)
	var theH: float = maxf(base_size.y / engine_scale, MIN_TOUCH_PX)
	return Vector2(theW, theH)


## Признак мобильного режима.
func is_mobile() -> bool:
	return mode == Mode.MOBILE


## Признак десктопного режима.
func is_desktop() -> bool:
	return mode == Mode.DESKTOP
