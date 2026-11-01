class_name ReactionDef extends Resource
## Описание реакции: когда срабатывает, что делает.
##
## Примеры:
## - AoO (Attack of Opportunity): когда враг выходит из клетки рядом — атаковать.
## - Shield Block: при входящем уроне — шанс 30% заблокировать 50%.
## - Reactive Strike: при атаке на союзника — контратака.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

# Триггер: какой GameBus сигнал активирует.
# "unit_attacked", "unit_move_start", "round_started".
@export var trigger: StringName = &"unit_attacked"

# Шанс срабатывания (0.0-1.0).
@export var trigger_chance: float = 1.0

# Дополнительные фильтры (spatial owner selector — must be
# explicitly enabled via ReactionDef.range_cells >= 1 for
# OWNER_ENEMY_LEAVING_RANGE).
@export var range_cells: int = 1

# === Phase 3 / B6.2a / Reaction execution schema (additive).
#
# Existing legacy resources (attack_of_opportunity.tres,
# shield_block.tres) leave these defaults intact. They
# remain Phase-3 INERT until a future authoring step opts
# them in by setting a real BattleEventType / EffectKind.
#
# B6.2a MUST NOT execute these fields yet. A real
# ContentReactionProvider will be added in a later stage.

# Sentinel = -1 means "no Phase-3 trigger". A positive
# BattleEventType constant means "react on this event type".
@export var event_type: int = -1

# Sentinel = -1 means "no Phase-3 output effect". A positive
# EffectKind constant means "execute this effect on fire".
@export var effect_kind: int = -1

# === Owner / target selector constants ===
## Which event entity becomes the REACTION OWNER (the entity
## whose perspective gates execution).
const OWNER_EVENT_SOURCE: int = 0
const OWNER_EVENT_TARGET: int = 1
## B6.3: spatial owner selector. Valid only for movement-intent
## events carrying from_cell and to_cell (e.g. UNIT_MOVE_STARTED).
## Discovers candidates by enumerating alive entities whose
## team differs from the mover and whose distance to the
## mover's from_cell is within ReactionDef.range_cells while
## distance to the planned to_cell is OUTSIDE that range (the
## "leaving range" pattern).
const OWNER_ENEMY_LEAVING_RANGE: int = 2

## Which entity becomes the EFFECT TARGET when the reaction
## fires.
const TARGET_EVENT_SOURCE: int = 0
const TARGET_EVENT_TARGET: int = 1
const TARGET_OWNER: int = 2

@export var owner_selector: int = OWNER_EVENT_TARGET
@export var target_selector: int = TARGET_EVENT_SOURCE

# === Phase 3 / B6.4d / Pre-damage percentage modifier schema (additive).
#
# A ReactionDef may declare a GENERIC pre-damage percentage
# modifier: the current pending damage is reduced to
# percent% of its CURRENT value (not of the immutable base).
#
#   pending_damage_percent = -1  -> sentinel: "not configured"
#   pending_damage_percent = 50  -> leave 50% of the CURRENT pending
#   pending_damage_minimum = 0   -> no floor
#   pending_damage_minimum = 1   -> a positive pending stays >= 1
#
# The rounding policy is floor(current * percent / 100) with the
# minimum applied ONLY when the current pending is > 0. A pending
# of 0 is NEVER resurrected to the minimum (composition safety
# with other pre-damage modifiers).
#
# These fields are meaningful ONLY for the pair
#   event_type == DAMAGE_STARTED
#   effect_kind == MODIFY_PENDING_DAMAGE
# The validator enforces that pairing fail-closed.
@export var pending_damage_percent: int = -1
@export var pending_damage_minimum: int = 0

# B6.4d / Which damage origins this pre-damage reaction covers.
#
# A bitmask over EffectRequest.DAMAGE_ORIGIN_*:
#   1 = PERFORM_ATTACK, 2 = DIRECT, 4 = PERIODIC.
#
# 0 means "not a pre-damage reaction" (the field is irrelevant
# for every other effect kind). Shield Block uses DIRECT only:
# the legacy Shield Block lived inside the shared legacy
# core/effects/damage_effect.gd (ability damage), while the
# legacy basic attack and the legacy Burn bypassed it.
@export var pending_damage_origins: int = 0

## Optional semantic metadata for B6.2b + later stages.
## Empty means "no tag filter" / "no exclusions".
@export var output_tag: StringName = &""
@export var excluded_trigger_tags: Array[StringName] = []
