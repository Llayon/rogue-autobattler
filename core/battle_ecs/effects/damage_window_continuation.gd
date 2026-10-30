class_name DamageWindowContinuation extends RefCounted
##
## Owns the metadata required to finalize one pre-damage
## window. Created by the damage-origin effect AFTER computing
## the base damage and the DAMAGE_STARTED event but BEFORE
## committing. finalize() runs in the work-pump context
## (TriggerDispatcher.process_work) and emits the actual
## DAMAGE_APPLIED (and UNIT_DIED if lethal) into the canonical
## sink.
##
## Does NOT pre-allocate DAMAGE_APPLIED or UNIT_DIED. These are
## allocated at finalize() time so that public event IDs remain
## in monotonic order and DAMAGE_APPLIED is always a child of
## DAMAGE_STARTED regardless of how many pre-damage reactions
## ran.
##
## B6.4c: tag parity contract.
##   final_event_tag -> DAMAGE_APPLIED and UNIT_DIED.
## Origin-aware:
##   Direct DamageEffect / Burn: final_event_tag = "" (legacy).
##   PerformAttack:               final_event_tag = sem_tag (legacy parity).
## This keeps Counterattack/AoO DAMAGE_APPLIED.tag = "counterattack"
## / "attack_of_opportunity" exactly as on a5dd87d.
##
## The DAMAGE_STARTED intent event carries its OWN tag (it is
## materialised at allocation time by the damage-origin
## effect), so the continuation does NOT need to keep it. That
## removes the risk of the intent tag leaking into the
## committed events.

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

var tx = null
var handle = null
var event: BattleEvent  # the DAMAGE_STARTED itself
var source_entity: int = -1
var target_entity: int = -1
var source_run_unit_id: String = ""
var target_run_unit_id: String = ""
## B6.4c: tag carried on the DAMAGE_APPLIED event.
## Origin-aware. Empty for DamageEffect / Burn (legacy).
## Inherited from sem_tag for PerformAttack.
var final_event_tag: StringName = &""
## B6.4c: tag carried on the UNIT_DIED event. Origin-aware:
##   DamageEffect  -> "" (legacy default argument)
##   PerformAttack -> sem_tag (legacy passed it explicitly)
var died_event_tag: StringName = &""
## B6.4c: whether UNIT_DIED carries the dealt amount.
##   DamageEffect  -> false (legacy default argument: amount 0)
##   PerformAttack -> true  (legacy passed dmg_event.amount)
var died_amount_is_dealt: bool = false


## Finalize the window. Revalidate target, commit transaction,
## allocate DAMAGE_APPLIED as a child of DAMAGE_STARTED. If lethal,
## allocate UNIT_DIED as a child of DAMAGE_APPLIED. Close the
## handle. Append all emitted events to `p_sink` and return them
## via FinalizeResult.
##
## On failure (target dead, transaction commit failure), emit
## nothing, close the handle, return empty emitted list.
func finalize(world, p_sink: Array, emitter) -> RefCounted:
	if not bool(world.is_alive(int(target_entity))):
		if handle != null:
			handle.close()
		return FinalizeResult.new([])

	var commit_result: Dictionary = tx.commit(world)
	if not bool(commit_result.get("ok", false)):
		if handle != null:
			handle.close()
		return FinalizeResult.new([])

	var dealt: int = int(commit_result.get("dealt", 0))
	# DAMAGE_APPLIED as a CHILD of DAMAGE_STARTED. Allocated
	# here, NOT pre-allocated, so the event id lands in correct
	# public-emission order. tag uses final_event_tag — the
	# direct DamageEffect / Burn origin sets it to "" for
	# legacy parity, PerformAttack sets it to the reaction's
	# semantic tag.
	var dmg_event = emitter.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(event.event_id), int(event.root_action_id),
		int(event.chain_depth),
		int(source_entity), int(target_entity),
		String(source_run_unit_id), String(target_run_unit_id),
		int(dealt), String(final_event_tag),
		Vector2i(-1, -1), Vector2i(-1, -1))
	p_sink.append(dmg_event)

	var emitted: Array = [dmg_event]

	# UNIT_DIED as child of DAMAGE_APPLIED if lethal.
	#
	# B6.4c LEGACY TAG/AMOUNT PARITY (origin-aware).
	#
	# On a5dd87d the two damage origins emitted UNIT_DIED
	# differently:
	#   DamageEffect:   emit_child(UNIT_DIED, ..., src, tgt)
	#                   -> amount = 0 (default), tag = "" (default)
	#   PerformAttack:  emit_child(UNIT_DIED, ..., src, tgt,
	#                                 dmg_event.amount, sem_tag)
	#                   -> amount = dealt, tag = sem_tag
	#
	# The continuation serves BOTH origins, so it must carry the
	# two policies separately. `died_event_tag` and
	# `died_event_amount_are_dealt` encode the origin choice.
	#
	# DAMAGE_APPLIED keeps `final_event_tag` and amount = dealt
	# in BOTH origins (legacy parity, verified by the semantic
	# differential).
	if dealt > 0 and not bool(world.is_alive(int(target_entity))):
		var died_amount: int = int(dealt) if bool(died_amount_is_dealt) else 0
		var died_event = emitter.emit_child(
			BattleEventTypeScript.UNIT_DIED,
			int(dmg_event.event_id), int(dmg_event.root_action_id),
			int(dmg_event.chain_depth),
			int(source_entity), int(target_entity),
			String(source_run_unit_id), String(target_run_unit_id),
			int(died_amount), String(died_event_tag),
			Vector2i(-1, -1), Vector2i(-1, -1))
		p_sink.append(died_event)
		emitted.append(died_event)

	if handle != null:
		handle.close()

	return FinalizeResult.new(emitted)