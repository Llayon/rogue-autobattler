class_name DoS extends RefCounted
## Degrees of Success (Pathfinder 2e style).
##
## Классификация броска d20 + модификатор против DC:
##   - CRIT_SUCCESS:  result >= DC + 10
##   - SUCCESS:       result >= DC
##   - FAILURE:       result < DC (но не crit fail)
##   - CRIT_FAILURE:  d20 == 1 (natural 1) ИЛИ result <= DC - 10
##
## Используется в compute_attack, apply_status, save throws и т.д.
##
## ВНИМАНИЕ: класс для data, не для state. classify() — pure function.

const CRIT_SUCCESS: int = 3
const SUCCESS: int = 2
const FAILURE: int = 1
const CRIT_FAILURE: int = 0

const OUTCOME_NAMES: Dictionary = {
	CRIT_FAILURE: "crit_failure",
	FAILURE: "failure",
	SUCCESS: "success",
	CRIT_SUCCESS: "crit_success",
}


## Классифицирует бросок. Pure function.
## - d20_roll: 1..20 (натуральный бросок).
## - modifier: модификатор (attack bonus, save bonus, и т.д.).
## - dc: difficulty class (target's defense, DC, и т.д.).
## Возвращает один из OUTCOME_* констант.
static func classify(d20_roll: int, modifier: int, dc: int) -> int:
	var total: int = d20_roll + modifier
	# Natural 20 = всегда crit success (Pathfinder правило).
	if d20_roll == 20:
		return CRIT_SUCCESS
	# Natural 1 = всегда crit failure.
	if d20_roll == 1:
		return CRIT_FAILURE
	if total >= dc + 10:
		return CRIT_SUCCESS
	if total >= dc:
		return SUCCESS
	if total <= dc - 10:
		return CRIT_FAILURE
	return FAILURE


## Множитель damage по outcome.
## CRIT_SUCCESS: 2x, SUCCESS: 1x, FAILURE: 0.5x (половина), CRIT_FAILURE: 0x.
static func damage_multiplier(outcome: int) -> float:
	match outcome:
		CRIT_SUCCESS: return 2.0
		SUCCESS: return 1.0
		FAILURE: return 0.5
		CRIT_FAILURE: return 0.0
		_: return 1.0


## Применять ли status эффект при данном outcome?
## CRIT_SUCCESS и SUCCESS — да. FAILURE и CRIT_FAILURE — нет.
## Также CRIT_SUCCESS удваивает stacks/duration (см. apply_status с doubled=true).
static func status_should_apply(outcome: int) -> bool:
	return outcome == CRIT_SUCCESS or outcome == SUCCESS


## Возвращает множитель для stacks/duration на status эффектах.
## CRIT_SUCCESS → 2, остальные → 1.
static func status_amplifier(outcome: int) -> int:
	if outcome == CRIT_SUCCESS:
		return 2
	return 1


## Человекочитаемое имя outcome.
static func name_of(outcome: int) -> StringName:
	return OUTCOME_NAMES.get(outcome, &"unknown")


## Описание outcome для логирования.
static func describe(outcome: int) -> String:
	match outcome:
		CRIT_SUCCESS: return "Critical Success"
		SUCCESS: return "Success"
		FAILURE: return "Failure"
		CRIT_FAILURE: return "Critical Failure"
		_: return "Unknown"