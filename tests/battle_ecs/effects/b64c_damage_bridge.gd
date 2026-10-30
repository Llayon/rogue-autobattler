class_name B64cDamageBridge
extends RefCounted
##
## B6.4c — SHARED DAMAGE-BRIDGE ASSERTION HELPERS.
##
## The B6.4c pre-damage window inserted a DAMAGE_STARTED layer
## between the damage INTENT and the damage COMMIT. That changed
## the causal shape of every damage chain. There are THREE
## distinct origins, and each has its OWN shape:
##
##   A. PerformAttack origin (an attack opens a damage window):
##        ATTACK_RESOLVED
##        └ DAMAGE_STARTED    (intent)
##          └ DAMAGE_APPLIED (commit)
##            └ UNIT_DIED?    (only if lethal)
##
##   B. Periodic origin (a status tick opens a damage window):
##        STATUS_TICKED
##        └ DAMAGE_STARTED    (intent)
##          └ DAMAGE_APPLIED (commit)
##            └ UNIT_DIED?    (only if lethal)
##
##   C. Direct DamageEffect origin (no intent event at all):
##        DAMAGE_STARTED      (intent, ROOT)
##        └ DAMAGE_APPLIED   (commit)
##          └ UNIT_DIED?      (only if lethal)
##
## The PUBLIC helpers below reflect the ORIGIN's meaning, not just
## the graph shape. They all share one low-level helper
## (_assert_started_to_applied) that verifies the part that is
## common to all three:
##
##   DAMAGE_STARTED -> DAMAGE_APPLIED is a parent link
##   DAMAGE_APPLIED is a CHILD of DAMAGE_STARTED
##   the root_action_id is shared by the whole chain
##   the depth grows by exactly +1 per layer
##   the event ids are strictly increasing
##   the trace order matches the ancestry order
##
## The origin-specific helpers additionally verify the INTENT
## event's own contract (its parent, its tag, its depth).

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")

# Low-level: the DAMAGE_STARTED -> DAMAGE_APPLIED link.
static func assert_started_to_applied(
		p_events: Array,
		p_started,
		p_label: String,
		p_assert: Callable) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"applied": null,
		"started_index": -1,
		"applied_index": -1,
	}
	if p_started == null:
		p_assert.call(false, "%s: DAMAGE_STARTED missing" % p_label)
		return result
	# Locate the started event in the trace and find its child
	# DAMAGE_APPLIED by parent linkage.
	var started_index: int = -1
	for i in p_events.size():
		if int(p_events[i].event_id) == int(p_started.event_id):
			started_index = i
			break
	p_assert.call(started_index >= 0,
		"%s: DAMAGE_STARTED is in the public trace" % p_label)
	if started_index < 0:
		return result
	var applied = null
	var applied_index: int = -1
	for i in p_events.size():
		var e = p_events[i]
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.parent_event_id) == int(p_started.event_id):
			applied = e
			applied_index = i
			break
	p_assert.call(applied != null,
		"%s: DAMAGE_APPLIED is a CHILD of DAMAGE_STARTED" % p_label)
	if applied == null:
		return result
	# Root parity: the whole chain shares one causal family.
	p_assert.call(int(applied.root_action_id) == int(p_started.root_action_id),
		"%s: DAMAGE_APPLIED.root == DAMAGE_STARTED.root" % p_label)
	# Depth: exactly +1 per layer.
	p_assert.call(int(applied.chain_depth) == int(p_started.chain_depth) + 1,
		"%s: DAMAGE_APPLIED.depth == DAMAGE_STARTED.depth + 1" % p_label)
	# Trace order matches the ancestry order.
	p_assert.call(started_index < applied_index,
		"%s: DAMAGE_STARTED precedes DAMAGE_APPLIED in the trace" % p_label)
	# Event id monotonicity.
	p_assert.call(int(applied.event_id) > int(p_started.event_id),
		"%s: DAMAGE_APPLIED.event_id > DAMAGE_STARTED.event_id" % p_label)
	result["ok"] = true
	result["applied"] = applied
	result["started_index"] = started_index
	result["applied_index"] = applied_index
	return result


# A. PerformAttack origin.
static func assert_attack_damage_bridge(
		p_events: Array,
		p_attack,
		p_label: String,
		p_assert: Callable) -> Dictionary:
	var result: Dictionary = {"ok": false, "applied": null, "died": null}
	if p_attack == null:
		p_assert.call(false, "%s: ATTACK_RESOLVED missing" % p_label)
		return result
	# The intent event of this origin IS the ATTACK_RESOLVED.
	# The DAMAGE_STARTED must be its child.
	var started = null
	for e in p_events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
				and int(e.parent_event_id) == int(p_attack.event_id):
			started = e
			break
	p_assert.call(started != null,
		"%s: DAMAGE_STARTED is a CHILD of ATTACK_RESOLVED" % p_label)
	if started == null:
		return result
	# The attack and the window share the causal family, and the
	# window is one layer deeper.
	p_assert.call(int(started.root_action_id) == int(p_attack.root_action_id),
		"%s: DAMAGE_STARTED.root == ATTACK_RESOLVED.root" % p_label)
	p_assert.call(int(started.chain_depth) == int(p_attack.chain_depth) + 1,
		"%s: DAMAGE_STARTED.depth == ATTACK_RESOLVED.depth + 1" % p_label)
	var low: Dictionary = assert_started_to_applied(
		p_events, started, p_label, p_assert)
	result["ok"] = bool(low.get("ok", false))
	result["applied"] = low.get("applied", null)
	if low.get("applied", null) != null:
		var applied = low.get("applied")
		result["died"] = _find_died_child(
			p_events, applied, p_assert, p_label)
	return result


# B. Periodic origin (STATUS_TICKED -> DAMAGE_STARTED -> ...).
static func assert_periodic_damage_bridge(
		p_events: Array,
		p_status_tick,
		p_label: String,
		p_assert: Callable) -> Dictionary:
	var result: Dictionary = {"ok": false, "applied": null, "died": null}
	if p_status_tick == null:
		p_assert.call(false, "%s: STATUS_TICKED missing" % p_label)
		return result
	var started = null
	for e in p_events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED \
				and int(e.parent_event_id) == int(p_status_tick.event_id):
			started = e
			break
	p_assert.call(started != null,
		"%s: DAMAGE_STARTED is a CHILD of STATUS_TICKED" % p_label)
	if started == null:
		return result
	p_assert.call(int(started.root_action_id) == int(p_status_tick.root_action_id),
		"%s: DAMAGE_STARTED.root == STATUS_TICKED.root" % p_label)
	p_assert.call(int(started.chain_depth) == int(p_status_tick.chain_depth) + 1,
		"%s: DAMAGE_STARTED.depth == STATUS_TICKED.depth + 1" % p_label)
	var low: Dictionary = assert_started_to_applied(
		p_events, started, p_label, p_assert)
	result["ok"] = bool(low.get("ok", false))
	result["applied"] = low.get("applied", null)
	if low.get("applied", null) != null:
		var applied = low.get("applied")
		result["died"] = _find_died_child(
			p_events, applied, p_assert, p_label)
	return result


# C. Direct DamageEffect origin (DAMAGE_STARTED is a ROOT).
static func assert_direct_damage_bridge(
		p_events: Array,
		p_label: String,
		p_assert: Callable) -> Dictionary:
	var result: Dictionary = {"ok": false, "applied": null, "died": null}
	var started = null
	for e in p_events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_STARTED:
			started = e
			break
	p_assert.call(started != null,
		"%s: DAMAGE_STARTED present" % p_label)
	if started == null:
		return result
	# The direct origin has NO intent event: the window opens at
	# the ROOT of its own chain.
	p_assert.call(int(started.parent_event_id) <= 0,
		"%s: direct DAMAGE_STARTED is a ROOT (no parent)" % p_label)
	var low: Dictionary = assert_started_to_applied(
		p_events, started, p_label, p_assert)
	result["ok"] = bool(low.get("ok", false))
	result["applied"] = low.get("applied", null)
	if low.get("applied", null) != null:
		var applied = low.get("applied")
		result["died"] = _find_died_child(
			p_events, applied, p_assert, p_label)
	return result


# The optional UNIT_DIED segment: a CHILD of DAMAGE_APPLIED.
# It is OPTIONAL (only present when the damage was lethal), so the
# helper reports it without failing when absent. When present, the
# full contract is verified.
static func _find_died_child(
		p_events: Array,
		p_applied,
		p_assert: Callable,
		p_label: String):
	var died = null
	for e in p_events:
		if int(e.type) == BattleEventTypeScript.UNIT_DIED \
				and int(e.parent_event_id) == int(p_applied.event_id):
			died = e
			break
	if died == null:
		# Not lethal: no UNIT_DIED is expected. The caller
		# decides whether its scenario required one.
		return null
	p_assert.call(int(died.root_action_id) == int(p_applied.root_action_id),
		"%s: UNIT_DIED.root == DAMAGE_APPLIED.root" % p_label)
	p_assert.call(int(died.chain_depth) == int(p_applied.chain_depth) + 1,
		"%s: UNIT_DIED.depth == DAMAGE_APPLIED.depth + 1" % p_label)
	p_assert.call(int(died.event_id) > int(p_applied.event_id),
		"%s: UNIT_DIED.event_id > DAMAGE_APPLIED.event_id" % p_label)
	return died
