extends RefCounted
## B6.1 — canonical attack execution path.
## BOTH BattleSimulation normal attacks and reaction
## PerformAttack requests route through this effect. There
## is exactly ONE production mutation path for attacks.
##
## Validation order (no mutation / event allocation before
## all checks pass):
##   1. req != null + req.validate_ancestry_shape() ok
##   2. source exists + alive
##   3. source is not blocks_actions() (real Stun)
##   4. target exists + alive
##   5. source != target
##   6. opposing teams
##   7. target is in attack range
## Failure returns EffectResult.failed(reason, [], false).
##
## Canonical event emission order for a successful ROOT attack:
##   [ATTACK_RESOLVED (depth=0, parent=-1, fresh root_action_id),
##    DAMAGE_APPLIED   (depth=1, parent=ATTACK_RESOLVED.event_id,
##                       same root_action_id),
##    UNIT_DIED        (depth=2, parent=DAMAGE_APPLIED.event_id) (only on kill)]
##
## Child attacks (counterattacks) inherit root_action_id and
## chain_depth from the dispatching trigger event. The dispatcher
## already admitted the child EffectRequest; the atomic
## DAMAGE_APPLIED / UNIT_DIED emitted HERE carry depth
## req.chain_depth + 1 and +2. Downstream reaction requests
## derived from these events are again subject to dispatcher
## depth / root-budget gates.
##
## IDENTITY: every emitted event preserves source_run_unit_id
## (attacker) and target_run_unit_id (defender).

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload(
	"res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const AttackMathScript = preload(
	"res://core/battle_ecs/effects/attack_math.gd")
const StatQueryScript = preload(
	"res://core/battle_ecs/status/stat_query.gd")


static func execute(ctx, req) -> RefCounted:
	# B6.1.1: PERFORM_ATTACK does NOT accept caller-defined raw
	# damage. Caller must leave amount=0; canonical damage is
	# derived inside this effect from live BattleWorld stats.
	# Future content cannot accidentally bypass AttackMath.
	if req == null:
		return EffectResultScript.failed(
			"perform_attack: null request", [], false)
	if int(req.amount) != 0:
		return EffectResultScript.failed(
			"perform_attack: amount must be 0 (got %d)"
			% int(req.amount), [], false)
	var p_world = ctx.world()
	var p_emitter = ctx.emitter()
	# B6.1.1: we no longer touch ctx.event_sink() directly —
	# sink publication goes through ctx.emit_through_sink so the
	# executor is the only authority. removed local var.

	# 0. Request null / bad ancestry shape.
	var av = req.validate_ancestry_shape()
	if not bool(av.get("ok", false)):
		return EffectResultScript.failed(
			"perform_attack: %s"
			% String(av.get("reason", "")), [], false)

	var src: int = int(req.source_entity)
	var tgt: int = int(req.target_entity)

	# 1. source alive
	if not p_world.is_alive(src):
		return EffectResultScript.failed(
			"perform_attack: source not alive", [], false)

	# 2. source not blocks_actions (real Stun)
	if StatQueryScript.blocks_actions(p_world, src):
		return EffectResultScript.failed(
			"perform_attack: source blocks_actions", [], false)

	# 3. target alive
	if not p_world.is_alive(tgt):
		return EffectResultScript.failed(
			"perform_attack: target not alive", [], false)

	# 4. distinct attacker
	if src == tgt:
		return EffectResultScript.failed(
			"perform_attack: source == target", [], false)

	# 5. opposing teams
	var src_team: int = int(p_world.team_of(src))
	var tgt_team: int = int(p_world.team_of(tgt))
	if src_team < 0 or tgt_team < 0:
		return EffectResultScript.failed(
			"perform_attack: team lookup failed", [], false)
	if src_team == tgt_team:
		return EffectResultScript.failed(
			"perform_attack: same team", [], false)

	# 6. range
	if not p_world.in_attack_range(src, tgt):
		return EffectResultScript.failed(
			"perform_attack: out of range", [], false)

	# === ALL CHECKS PASSED. Allocate events. ===

	var src_run: String = String(p_world.source_run_unit_id_of(src))
	var tgt_run: String = String(p_world.target_run_unit_id_of(tgt))

	# Canonical attack damage from the shared helper (single
	# source of truth).
	var raw_dmg: int = int(AttackMathScript.compute(
		int(p_world.attack_of(src)),
		int(p_world.defense_of(tgt))))

	# ROOT requests get a fresh root_action_id via
	# BattleEventEmitter.emit(); CHILD requests inherit.
	var ancestry_kind: String = String(av.get("kind", ""))
	var atk_parent_eid: int = -1
	var atk_root_id: int = -1
	var atk_depth: int = 0
	var atk_event = null
	if ancestry_kind == EffectRequestScript.ANCESTRY_CHILD:
		atk_parent_eid = int(req.parent_event_id)
		atk_root_id = int(req.root_action_id)
		atk_depth = int(req.chain_depth)
		# emit_child requires a parent depth >= 0; pass our
		# ancestor's depth (one less than our atomic depth).
		atk_event = p_emitter.emit_child(
			BattleEventTypeScript.ATTACK_RESOLVED,
			atk_parent_eid, atk_root_id,
			atk_depth - 1,
			src, tgt, src_run, tgt_run, raw_dmg, "",
			Vector2i(-1, -1), Vector2i(-1, -1))
	else:
		atk_event = p_emitter.emit(
			BattleEventTypeScript.ATTACK_RESOLVED,
			src, tgt, src_run, tgt_run, raw_dmg, "",
			Vector2i(-1, -1), Vector2i(-1, -1))

	if atk_event == null:
		return EffectResultScript.failed(
			"perform_attack: emitter refused ATTACK_RESOLVED",
			[], false)

	# Snapshot atom depth for child events.
	var dmg_depth: int = int(atk_event.chain_depth) + 1
	var dmg_root_id: int = int(atk_event.root_action_id)

	# Damage emit (deferred amount=0; patched after apply).
	var dmg_event = p_emitter.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(atk_event.event_id), dmg_root_id,
		int(atk_event.chain_depth),
		src, tgt, src_run, tgt_run, 0, "",
		Vector2i(-1, -1), Vector2i(-1, -1))
	if dmg_event == null:
		return EffectResultScript.failed(
			"perform_attack: emitter refused DAMAGE_APPLIED",
			[], false)

	# Apply damage. Returns actual amount applied (HP-capped).
	# world.apply_damage also marks dead when HP reaches 0.
	var dealt: int = int(p_world.apply_damage(tgt, raw_dmg))
	dmg_event.amount = int(dealt)
	# B6.1.1: single canonical sink publication API. Direct
	# sink.append is allowed but ctx.emit_through_sink is the
	# documented path; both end up in the same sink with no
	# semantic difference. We use ctx.emit_through_sink so the
	# executor is the only authority for sink mutation.
	ctx.emit_through_sink(atk_event)
	ctx.emit_through_sink(dmg_event)
	var result_events: Array = [atk_event, dmg_event]

	var continues_chain: bool = true
	if dealt > 0 and not p_world.is_alive(tgt):
		var died_event = p_emitter.emit_child(
			BattleEventTypeScript.UNIT_DIED,
			int(dmg_event.event_id), dmg_root_id,
			int(dmg_event.chain_depth),
			src, tgt, src_run, tgt_run, int(dmg_event.amount), "",
			Vector2i(-1, -1), Vector2i(-1, -1))
		if died_event != null:
			ctx.emit_through_sink(died_event)
			result_events.append(died_event)
		# Dead targets cannot continue a reaction chain.
		continues_chain = false

	return EffectResultScript.succeeded(result_events, continues_chain)
