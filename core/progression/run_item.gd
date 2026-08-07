class_name RunItem extends RefCounted
## Run domain entity for inventory items. Instance identity is
## independent of the underlying item definition so the same
## `definition_id` can appear multiple times in the run.
##
## `owner_unit_id` is either a `RunUnit.instance_id` (when equipped) or
## the empty string (when in inventory). The validator enforces the
## bidirectional consistency with `RunUnit.equipped_item_ids`.

var instance_id: String = ""
var definition_id: StringName = &""
## `RunUnit.instance_id` of the equipped unit, or `""` if in inventory.
var owner_unit_id: String = ""


## Returns `true` if the item is currently equipped to a board unit.
func is_equipped() -> bool:
	return owner_unit_id != ""
