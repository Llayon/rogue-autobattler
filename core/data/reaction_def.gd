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

# Дополнительные фильтры (например, only melee).
@export var melee_only: bool = false
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

## Which entity becomes the EFFECT TARGET when the reaction
## fires.
const TARGET_EVENT_SOURCE: int = 0
const TARGET_EVENT_TARGET: int = 1
const TARGET_OWNER: int = 2

@export var owner_selector: int = OWNER_EVENT_TARGET
@export var target_selector: int = TARGET_EVENT_SOURCE

## Optional semantic metadata for B6.2b + later stages.
## Empty means "no tag filter" / "no exclusions".
@export var output_tag: StringName = &""
@export var excluded_trigger_tags: Array[StringName] = []
