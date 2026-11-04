extends SceneTree
## B6.4c — PERIODIC STATUS CURSOR STALE-INSTANCE REGRESSION.
##
## The lazy periodic cursor snapshots the entity's StatusInstances
## when the entity is loaded:
##
##   _statuses = container.all()
##
## StatusContainer.all() returns a NEW Array but the SAME object
## references. Between two next_step() calls the simulation fully
## drains the previous step's events / window work / reactions, so
## a status that has not reached its turn yet can be removed, or
## removed and re-applied under the same status_id.
##
## The cursor then ticked the stale snapshot entry without
## checking that it is still the live instance:
##
##   var inst = _statuses[idx]
##   var expired: bool = inst.tick(1)
##
## That violates the frozen B6.4c contract: every periodic step
## must reflect the live world state after the previous step's
## drain.
##
## THE INVARIANT UNDER TEST:
##
##   A snapshot instance may execute IFF the exact same object is
##   still the current live StatusInstance for that status_id in
##   that entity's current StatusContainer.
##
##   live_inst == snapshot_inst -> execute
##   live_inst == null           -> stale removed  -> skip
##   live_inst != snapshot_inst -> stale replaced -> skip
##
## Checking only status_id membership is NOT enough: after a
## remove + re-apply the id is present again, but it is a DIFFERENT
## object.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_removed_status_does_not_tick()
	_test_removed_status_does_not_expire_or_heal()
	_test_remove_and_reapply_same_id_skips_old_instance()
	_test_old_expiring_instance_cannot_delete_new_same_id()
	_test_new_replacement_ticks_next_phase()
	_test_live_instance_still_ticks()
	_test_in_place_refresh_still_ticks()
	_test_step_tick_reaction_removal_skips_stale_regen()
	print("\n=== B6.4c periodic cursor stale-instance regression: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


# --- helpers ---

## Builds a world with ONE player entity (id 0) that has room to
## heal, and returns the fixture.
func _make_world(p_max_hp: int = 100) -> Dictionary:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var players: Array = [
		B.new("p0", &"warrior", 0, Vector2i(0, 0), p_max_hp, p_max_hp, 20, 5, 1)]
	var enemies: Array = [
		B.new("e0", &"orc", 1, Vector2i(0, 3), p_max_hp, p_max_hp, 20, 5, 1)]
	var s = S.new(42, players, enemies, 1, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	return {"world": w, "emitter": em, "rng": rng}


## Creates a container on entity 0 with regen FIRST and burn
## SECOND. The cursor visits statuses in REVERSE insertion order,
## so burn is processed first and regen second.
func _make_container(p_world, p_duration: int = 100) -> Dictionary:
	var container = p_world.get_status_container(0)
	if container == null:
		container = p_world.create_status_container(0)
	var regen = StatusInstanceScript.new(
		&"regen", 0, 0, 1, p_duration, 0)
	container.add(regen, "stackable", 99)
	# The burn's SOURCE must differ from its target: DamageEffect
	# rejects a self-targeted damage request (src == tgt). The
	# b3_burn_regen_test seeds burn with source_entity 0 on entity
	# 1 for the same reason.
	var burn = StatusInstanceScript.new(
		&"burn", 1, 0, 1, p_duration, 0)
	container.add(burn, "stackable", 99)
	return {"container": container, "regen": regen, "burn": burn}


## Counts events of a given type with a given tag.
func _count_tagged(p_events: Array, p_type: int, p_tag: String) -> int:
	var n: int = 0
	for e in p_events:
		if int(e.type) != p_type:
			continue
		if String(e.tag) == p_tag:
			n += 1
	return n


## Counts events of a given type (any tag).
func _count_type(p_events: Array, p_type: int) -> int:
	var n: int = 0
	for e in p_events:
		if int(e.type) == p_type:
			n += 1
	return n


func _all_events(p_steps: Array) -> Array:
	var out: Array = []
	for step in p_steps:
		if step == null:
			continue
		for e in step.events:
			out.append(e)
	return out


# --- tests ---

## TEST 1 — a status removed between two cursor steps must not
## tick from the stale snapshot.
func _test_removed_status_does_not_tick() -> void:
	print("[STALE-1] a removed status must not tick from the snapshot")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var container = ids["container"]
	var old_regen = ids["regen"]
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	_assert(cursor.has_next(),
		"STALE-1: the cursor has a next step")

	# The FIRST step is burn (reverse insertion order).
	var step1 = cursor.next_step()
	_assert(step1 != null, "STALE-1: the first step exists")
	var evs1: Array = []
	if step1 != null:
		evs1 = step1.events
	_assert(_count_tagged(evs1, BattleEventTypeScript.STATUS_TICKED, "burn") == 1,
		"STALE-1: the first step is the burn tick")

	# Remove regen while the cursor is between steps.
	var remaining_before: int = int(old_regen.remaining)
	container.remove(&"regen")
	_assert(not container.has_status(&"regen"),
		"STALE-1: the container no longer has regen")
	var rng_draws_before: int = int(fx["rng"].draw_count)
	var hp_before: int = int(fx["world"].current_hp_of(0))

	# Resume the cursor.
	var step2 = cursor.next_step()
	_assert(step2 != null, "STALE-1: the second step object exists")
	var evs2: Array = []
	if step2 != null:
		evs2 = step2.events
	_assert(_count_tagged(evs2, BattleEventTypeScript.STATUS_TICKED, "regen") == 0,
		"STALE-1: the removed regen produced NO STATUS_TICKED")
	_assert(_count_type(evs2, BattleEventTypeScript.HEAL_APPLIED) == 0,
		"STALE-1: the removed regen produced NO HEAL_APPLIED")
	_assert(int(old_regen.remaining) == remaining_before,
		"STALE-1: the stale regen instance was not ticked (remaining %d -> %d)"
			% [remaining_before, int(old_regen.remaining)])
	_assert(not container.has_status(&"regen"),
		"STALE-1: the container still has no regen")
	_assert(int(fx["rng"].draw_count) == rng_draws_before,
		"STALE-1: the stale skip consumed no RNG (%d -> %d)"
			% [rng_draws_before, int(fx["rng"].draw_count)])
	_assert(int(fx["world"].current_hp_of(0)) == hp_before,
		"STALE-1: the stale regen did not heal (hp %d -> %d)"
			% [hp_before, int(fx["world"].current_hp_of(0))])


## TEST 2 — a removed status must not expire from the snapshot
## either, and must not emit STATUS_EXPIRED.
func _test_removed_status_does_not_expire_or_heal() -> void:
	print("[STALE-2] a removed status must not expire from the snapshot")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var container = ids["container"]
	var old_regen = ids["regen"]
	# Make the OLD regen one tick away from expiry: after the burn
	# step it would expire and the cursor would try to remove the
	# status id from the container.
	old_regen.remaining = 1
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var step1 = cursor.next_step()
	_assert(step1 != null, "STALE-2: the first step exists")
	container.remove(&"regen")
	var step2 = cursor.next_step()
	var evs2: Array = []
	if step2 != null:
		evs2 = step2.events
	_assert(_count_type(evs2, BattleEventTypeScript.STATUS_EXPIRED) == 0,
		"STALE-2: the removed regen produced NO STATUS_EXPIRED")
	_assert(_count_tagged(evs2, BattleEventTypeScript.STATUS_TICKED, "regen") == 0,
		"STALE-2: the removed regen produced NO STATUS_TICKED")
	_assert(not container.has_status(&"regen"),
		"STALE-2: the container still has no regen")


## TEST 3 — remove AND re-apply the same status id: the OLD
## snapshot instance must be skipped even though the id IS live.
func _test_remove_and_reapply_same_id_skips_old_instance() -> void:
	print("[STALE-3] remove + reapply the same id skips the old instance")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var container = ids["container"]
	var old_regen = ids["regen"]
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var step1 = cursor.next_step()
	_assert(step1 != null, "STALE-3: the first step exists")

	container.remove(&"regen")
	var new_regen = StatusInstanceScript.new(
		&"regen", 0, 0, 1, 100, 0)
	container.add(new_regen, "stackable", 99)
	_assert(old_regen != new_regen,
		"STALE-3: the old and the new instance are different objects")
	_assert(container.get_status(&"regen") == new_regen,
		"STALE-3: the container now holds the NEW regen")
	var new_remaining_before: int = int(new_regen.remaining)
	var old_remaining_before: int = int(old_regen.remaining)
	var hp_before: int = int(fx["world"].current_hp_of(0))

	var step2 = cursor.next_step()
	var evs2: Array = []
	if step2 != null:
		evs2 = step2.events
	_assert(_count_tagged(evs2, BattleEventTypeScript.STATUS_TICKED, "regen") == 0,
		"STALE-3: the OLD regen did not tick")
	_assert(_count_type(evs2, BattleEventTypeScript.HEAL_APPLIED) == 0,
		"STALE-3: the OLD regen did not heal")
	_assert(int(old_regen.remaining) == old_remaining_before,
		"STALE-3: the OLD instance was not ticked")
	_assert(int(new_regen.remaining) == new_remaining_before,
		"STALE-3: the NEW instance did not tick in this phase (%d -> %d)"
			% [new_remaining_before, int(new_regen.remaining)])
	_assert(container.get_status(&"regen") == new_regen,
		"STALE-3: the container still holds the NEW regen")
	_assert(int(fx["world"].current_hp_of(0)) == hp_before,
		"STALE-3: no heal was applied (hp %d -> %d)"
			% [hp_before, int(fx["world"].current_hp_of(0))])


## TEST 4 — the strongest detector: the OLD instance is one tick
## from expiry and a NEW instance with the same id exists. The old
## instance must NOT expire and must NOT delete the new one.
func _test_old_expiring_instance_cannot_delete_new_same_id() -> void:
	print("[STALE-4] an old expiring instance cannot delete the new one")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var container = ids["container"]
	var old_regen = ids["regen"]
	old_regen.remaining = 1
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var step1 = cursor.next_step()
	_assert(step1 != null, "STALE-4: the first step exists")

	container.remove(&"regen")
	var new_regen = StatusInstanceScript.new(
		&"regen", 0, 0, 1, 10, 0)
	container.add(new_regen, "stackable", 99)
	var new_remaining_before: int = int(new_regen.remaining)

	var step2 = cursor.next_step()
	var evs2: Array = []
	if step2 != null:
		evs2 = step2.events
	_assert(_count_type(evs2, BattleEventTypeScript.STATUS_EXPIRED) == 0,
		"STALE-4: the OLD instance produced NO STATUS_EXPIRED")
	_assert(container.has_status(&"regen"),
		"STALE-4: the NEW regen still exists in the container")
	_assert(container.get_status(&"regen") == new_regen,
		"STALE-4: the container still holds the NEW regen object")
	_assert(int(new_regen.remaining) == new_remaining_before,
		"STALE-4: the NEW instance was not touched (%d -> %d)"
			% [new_remaining_before, int(new_regen.remaining)])


## TEST 5 — the replacement joins the NEXT periodic phase.
func _test_new_replacement_ticks_next_phase() -> void:
	print("[STALE-5] the replacement ticks in the NEXT periodic phase")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var container = ids["container"]
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var step1 = cursor.next_step()
	_assert(step1 != null, "STALE-5: the first step exists")
	container.remove(&"regen")
	var new_regen = StatusInstanceScript.new(
		&"regen", 0, 0, 1, 100, 0)
	container.add(new_regen, "stackable", 99)
	var new_remaining_before: int = int(new_regen.remaining)
	var cursor2 = cursor
	var step2 = cursor2.next_step()
	var evs2: Array = []
	if step2 != null:
		evs2 = step2.events
	_assert(_count_tagged(evs2, BattleEventTypeScript.STATUS_TICKED, "regen") == 0,
		"STALE-5: the replacement did NOT tick in the current phase")

	# A NEW phase (a fresh cursor) must pick the replacement up.
	var cursor3 = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var steps3: Array = []
	while cursor3.has_next():
		var st = cursor3.next_step()
		if st == null:
			break
		steps3.append(st)
		if steps3.size() > 20:
			break
	var evs3: Array = _all_events(steps3)
	_assert(_count_tagged(evs3, BattleEventTypeScript.STATUS_TICKED, "regen") == 1,
		"STALE-5: the replacement ticks exactly once in the next phase")
	_assert(int(new_regen.remaining) == new_remaining_before - 1,
		"STALE-5: the replacement's remaining decremented exactly once (%d -> %d)"
			% [new_remaining_before, int(new_regen.remaining)])


## TEST 6 — POSITIVE CONTROL: a status that was NOT removed must
## still tick normally. The fix must not skip valid statuses.
func _test_live_instance_still_ticks() -> void:
	print("[STALE-6] a live instance still ticks normally")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var regen = ids["regen"]
	var remaining_before: int = int(regen.remaining)
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var steps: Array = []
	while cursor.has_next():
		var st = cursor.next_step()
		if st == null:
			break
		steps.append(st)
		if steps.size() > 20:
			break
	var evs: Array = _all_events(steps)
	_assert(_count_tagged(evs, BattleEventTypeScript.STATUS_TICKED, "regen") == 1,
		"STALE-6: the live regen ticks exactly once")
	_assert(_count_tagged(evs, BattleEventTypeScript.STATUS_TICKED, "burn") == 1,
		"STALE-6: the live burn ticks exactly once")
	_assert(int(regen.remaining) == remaining_before - 1,
		"STALE-6: the live regen's remaining decremented (%d -> %d)"
			% [remaining_before, int(regen.remaining)])


## TEST 7 — an IN-PLACE refresh keeps the SAME object, so the
## cursor must still process it normally.
func _test_in_place_refresh_still_ticks() -> void:
	print("[STALE-7] an in-place refresh of the same object still ticks")
	var fx = _make_world()
	var ids = _make_container(fx["world"])
	var container = ids["container"]
	var regen = ids["regen"]
	var cursor = PeriodicStatusProcessorScript.new().begin_tick(
		fx["world"], fx["rng"], fx["emitter"])
	var step1 = cursor.next_step()
	_assert(step1 != null, "STALE-7: the first step exists")
	# A refresh through container.add() updates the SAME object.
	var refreshed = StatusInstanceScript.new(
		&"regen", 0, 0, 3, 50, 0)
	container.add(refreshed, "stackable", 99)
	_assert(container.get_status(&"regen") == regen,
		"STALE-7: the refresh kept the SAME live instance object")
	var remaining_before: int = int(regen.remaining)
	var stacks_before: int = int(regen.stacks)
	var step2 = cursor.next_step()
	var evs2: Array = []
	if step2 != null:
		evs2 = step2.events
	_assert(_count_tagged(evs2, BattleEventTypeScript.STATUS_TICKED, "regen") == 1,
		"STALE-7: the refreshed live regen still ticks")
	_assert(int(regen.remaining) == remaining_before - 1,
		"STALE-7: the refreshed regen's remaining decremented (%d -> %d)"
			% [remaining_before, int(regen.remaining)])
	_assert(int(regen.stacks) == stacks_before,
		"STALE-7: the refreshed regen's stacks are the live value (%d)"
			% int(regen.stacks))

# --- TEST 8 — the FULL production path -------------------------------
#
# The direct cursor test drives the cursor by hand. This test uses
# the REAL BattleSimulation.step_tick() pipeline:
#
#   Periodic cursor
#   -> Burn STATUS_TICKED
#   -> DAMAGE_STARTED
#   -> DamageWindowWorkItem
#   -> finalize
#   -> DAMAGE_APPLIED
#   -> TriggerDispatcher
#   -> synthetic REMOVE_STATUS(regen)
#   -> EffectExecutor
#   -> StatusContainer.remove(regen)
#   -> STATUS_REMOVED
#   -> cursor resumes
#
# The provider is TEST-ONLY: it returns a REMOVE_STATUS reaction
# when it sees the burn's committed DAMAGE_APPLIED. No shipping
# ReactionDef is involved and the ReactionDefValidator is not
# touched.

## Synthetic provider: removes the regen when the burn's damage
## is committed. Test-only; never shipped.
class _RemoveRegenProvider extends TriggerProviderScript:
	var target_status: StringName = &"regen"
	var remove_target: int = 0
	var removed: bool = false
	var chance_draws: int = 0

	func discover(p_world, p_event, p_rng) -> Array:
		# The burn's DAMAGE_STARTED carries the semantic tag
		# "burn". The COMMITTED DAMAGE_APPLIED carries an EMPTY
		# tag for Burn (legacy parity: final_event_tag = "" for a
		# direct DamageEffect / Burn), so the intent event is the
		# only tagged signal.
		if int(p_event.type) != int(BattleEventTypeScript.DAMAGE_STARTED):
			return []
		if String(p_event.tag) != "burn":
			return []
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(remove_target)
		tr.kind = "test_remove_regen"
		tr.trigger_chance = 1.0
		var req = EffectRequestScript.root(
			EffectKindScript.REMOVE_STATUS,
			int(remove_target), int(remove_target), 0)
		if req == null:
			return []
		if req.payload == null:
			req.payload = {}
		req.payload["status_id"] = String(target_status)
		tr.request = req
		return [tr]


func _test_step_tick_reaction_removal_skips_stale_regen() -> void:
	print("[STALE-8] step_tick: a reaction removal skips the stale regen")
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var players: Array = [
		B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)]
	var enemies: Array = [
		B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)]
	var sim = BattleSimulationScript.new()
	sim.initialize(S.new(42, players, enemies, 1, 4))
	var world = sim.world()
	var container = world.get_status_container(0)
	if container == null:
		container = world.create_status_container(0)
	var old_regen = StatusInstanceScript.new(&"regen", 0, 0, 1, 100, 0)
	container.add(old_regen, "stackable", 99)
	var burn = StatusInstanceScript.new(&"burn", 1, 0, 1, 100, 0)
	container.add(burn, "stackable", 99)
	var old_remaining_before: int = int(old_regen.remaining)
	var hp_before: int = int(world.current_hp_of(0))

	# Install the synthetic provider. The battle simulation must
	# expose a provider setter; if it does not, the test reports
	# that instead of silently passing.
	var provider = _RemoveRegenProvider.new()
	provider.remove_target = 0
	provider.target_status = &"regen"
	var has_setter: bool = sim.has_method("set_trigger_provider")
	_assert(has_setter,
		"STALE-8: the simulation exposes a trigger provider setter")
	if not has_setter:
		return
	sim.set_trigger_provider(provider)

	var events: Array = sim.step_tick()
	_assert(_count_tagged(events, BattleEventTypeScript.STATUS_TICKED, "burn") == 1,
		"STALE-8: the burn produced a STATUS_TICKED")
	_assert(_count_type(events, BattleEventTypeScript.DAMAGE_APPLIED) >= 1,
		"STALE-8: the burn damage produced a DAMAGE_APPLIED")
	_assert(_count_tagged(events, BattleEventTypeScript.STATUS_REMOVED, "regen") == 1,
		"STALE-8: the reaction removed the regen (STATUS_REMOVED)")
	_assert(not container.has_status(&"regen"),
		"STALE-8: the container no longer has regen")
	_assert(_count_tagged(events, BattleEventTypeScript.STATUS_TICKED, "regen") == 0,
		"STALE-8: the removed regen produced NO STATUS_TICKED")
	_assert(_count_tagged(events, BattleEventTypeScript.HEAL_APPLIED, "regen") == 0,
		"STALE-8: the removed regen produced NO HEAL_APPLIED")
	_assert(int(old_regen.remaining) == old_remaining_before,
		"STALE-8: the stale regen instance was not ticked (%d -> %d)"
			% [old_remaining_before, int(old_regen.remaining)])
	_assert(int(world.current_hp_of(0)) == hp_before - 5,
		"STALE-8: the HP reflects the burn and no stale regen heal "
			+ "(hp %d -> %d)" % [hp_before, int(world.current_hp_of(0))])

	# --- event ORDERING -----------------------------------------
	# The removal must be driven by the burn's committed damage:
	#   burn STATUS_TICKED
	#     before DAMAGE_STARTED
	#     before DAMAGE_APPLIED
	#     before STATUS_REMOVED(regen)
	# and there must be NO regen STATUS_TICKED after the removal.
	var i_burn_tick: int = _index_of_tagged(events,
		BattleEventTypeScript.STATUS_TICKED, "burn")
	var i_dmg_started: int = _index_of_tagged(events,
		BattleEventTypeScript.DAMAGE_STARTED, "burn")
	var i_dmg_applied: int = _index_of_type(events,
		BattleEventTypeScript.DAMAGE_APPLIED)
	var i_removed: int = _index_of_tagged(events,
		BattleEventTypeScript.STATUS_REMOVED, "regen")
	_assert(i_burn_tick >= 0, "STALE-8: the burn STATUS_TICKED is in the trace")
	_assert(i_dmg_started >= 0, "STALE-8: the burn DAMAGE_STARTED is in the trace")
	_assert(i_dmg_applied >= 0, "STALE-8: a DAMAGE_APPLIED is in the trace")
	_assert(i_removed >= 0, "STALE-8: the STATUS_REMOVED is in the trace")
	if i_burn_tick < 0 or i_dmg_started < 0 or i_dmg_applied < 0 or i_removed < 0:
		return
	_assert(i_burn_tick < i_dmg_started,
		"STALE-8: the burn STATUS_TICKED precedes its DAMAGE_STARTED "
			+ "(%d < %d)" % [i_burn_tick, i_dmg_started])
	_assert(i_dmg_started < i_dmg_applied,
		"STALE-8: the DAMAGE_STARTED precedes its DAMAGE_APPLIED "
			+ "(%d < %d)" % [i_dmg_started, i_dmg_applied])
	# The removal is a PRE-DAMAGE reaction: it fires on the burn's
	# DAMAGE_STARTED intent, so STATUS_REMOVED precedes the
	# DAMAGE_APPLIED commit. That is the B6.4c pre-damage
	# contract, not an ordering defect.
	_assert(i_dmg_started < i_removed,
		"STALE-8: the DAMAGE_STARTED intent precedes the STATUS_REMOVED "
			+ "(%d < %d)" % [i_dmg_started, i_removed])
	_assert(i_removed < i_dmg_applied,
		"STALE-8: the pre-damage STATUS_REMOVED precedes the DAMAGE_APPLIED "
			+ "commit (%d < %d)" % [i_removed, i_dmg_applied])

	# No regen STATUS_TICKED may appear AFTER the removal.
	var regen_after: int = 0
	for i in range(i_removed, events.size()):
		var e = events[i]
		if int(e.type) == int(BattleEventTypeScript.STATUS_TICKED) \
				and String(e.tag) == "regen":
			regen_after += 1
	_assert(regen_after == 0,
		"STALE-8: no regen STATUS_TICKED after the removal (got %d)"
			% regen_after)

## Index of the first event with this type and tag, or -1.
func _index_of_tagged(p_events: Array, p_type: int, p_tag: String) -> int:
	for i in p_events.size():
		var e = p_events[i]
		if int(e.type) != p_type:
			continue
		if String(e.tag) == p_tag:
			return i
	return -1


## Index of the first event with this type, or -1.
func _index_of_type(p_events: Array, p_type: int) -> int:
	for i in p_events.size():
		if int(p_events[i].type) == p_type:
			return i
	return -1
