class_name StatQuery extends RefCounted
## Phase 3 / B1 / StatQuery — pure stat aggregation using
## StatusDef content for modifier semantics.
##
## B1.1 aggregation rule (single round after combining):
##   effective_stat = round_half_away_from_zero(
##       base * (1 + sum_pct) + sum_flat
##   )
## where:
##   sum_pct  = sum over all relevant statuses of
##              (stacks * modifier_amount) for statuses with
##              is_percent_modifier == true
##   sum_flat = sum over all relevant statuses of
##              (stacks * modifier_amount) for statuses with
##              is_percent_modifier == false
##
## The round is applied ONCE after combining all modifiers. This
## avoids status-order-dependent rounding.
##
## "round_half_away_from_zero" = ties go to whichever integer is
## farther from zero (positive: floor(x+0.5); negative: ceil(x-0.5)).
## Examples: 31.5 -> 32, 34.5 -> 35, -1.5 -> -2.
##
## Phase 3 minimum: effective_attack(), effective_defense(),
## is_stunned().
##
## Does NOT mutate stored base stats.

const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")

var _world = null


func _init(p_world) -> void:
	_world = p_world


## Returns effective attack for entity_id.
## Reads each StatusDef's attack_modifier + is_percent_modifier and
## applies the aggregation rule.
func effective_attack(entity_id: int) -> int:
	var base: int = int(_world.attack_of(entity_id))
	return _aggregate_stat(entity_id, base, "attack_modifier")


## Returns effective defense (mirror of effective_attack).
func effective_defense(entity_id: int) -> int:
	var base: int = int(_world.defense_of(entity_id))
	return _aggregate_stat(entity_id, base, "defense_modifier")


## True iff the entity is currently stunned (has &"stun" status
## with remaining > 0 or indefinite).
func is_stunned(entity_id: int) -> bool:
	var container = _world.get_status_container(entity_id)
	if container == null:
		return false
	var inst = container.get_status(&"stun")
	if inst == null:
		return false
	# Indefinite remaining (-1) OR remaining > 0.
	return int(inst.remaining) != 0


## Internal: aggregate one stat field (attack_modifier or
## defense_modifier) across all of the entity's statuses using
## StatusDef semantics.
func _aggregate_stat(entity_id: int, base: int, def_field: String) -> int:
	var container = _world.get_status_container(entity_id)
	if container == null:
		return base
	var sum_pct: float = 0.0
	var sum_flat: float = 0.0
	for inst in container.all():
		var def: Resource = StatusDefResolverScript.resolve(inst.status_id)
		if def == null:
			continue
		# Read the requested modifier field from the StatusDef.
		# Default to 0.0 if missing.
		var amount: float = 0.0
		if def.get(def_field) != null:
			amount = float(def.get(def_field))
		var stacks: int = int(inst.stacks)
		var contribution: float = amount * float(stacks)
		if bool(def.is_percent_modifier):
			sum_pct += contribution
		else:
			sum_flat += contribution
	# Aggregation: base * (1 + sum_pct) + sum_flat, rounded ONCE.
	# round_half_away_from_zero: positive ties go up, negative ties
	# go down (further from zero).
	var result: float = float(base) * (1.0 + sum_pct) + sum_flat
	if result >= 0.0:
		return int(floor(result + 0.5))
	else:
		return int(ceil(result - 0.5))
