class_name UnlockManager extends RefCounted
## Управляет разблокировками и мета-валютой.
##
## Использование:
##   var profile: MetaProfile = SaveSvc.load_meta()
##   UnlockManager.grant_unit(profile, &"mage")
##   SaveSvc.save_meta(profile)


static func grant_unit(profile: MetaProfile, unit_id: StringName) -> bool:
	if profile == null or unit_id == &"":
		return false
	if unit_id in profile.unlocked_units:
		return false
	profile.unlocked_units.append(unit_id)
	GameLog.info("unlock", "Granted unit", {"id": unit_id})
	return true


static func grant_enemy(profile: MetaProfile, enemy_id: StringName) -> bool:
	if profile == null or enemy_id == &"":
		return false
	if enemy_id in profile.unlocked_enemies:
		return false
	profile.unlocked_enemies.append(enemy_id)
	return true


static func award_souls(profile: MetaProfile, amount: int) -> void:
	if profile == null or amount == 0:
		return
	profile.soul_currency = clampi(profile.soul_currency + amount, 0, 99999)


static func is_unit_unlocked(profile: MetaProfile, unit_id: StringName) -> bool:
	return profile != null and unit_id in profile.unlocked_units


# === S3.2: meta progression unlocks ===

## Выдаёт случайного юнита из тех, кого ещё нет в profile.unlocked_units.
## Tier-weighted по round_index (как в RewardScreen, для консистентности):
## 60% target_tier, 30% target-1, 10% target+1.
## Возвращает id нового юнита, или &"" если все уже unlocked.
## Детерминировано через Rng (тот же seed = тот же unlock sequence).
static func grant_random_unit(profile: MetaProfile, round_index: int) -> StringName:
	if profile == null:
		return &""
	var target_tier: int = clampi(round_index / 3, 1, 3)
	# Try 50 attempts: pick tier, pick unit, skip if already unlocked.
	for _i in 50:
		var tier: int = _pick_unlock_tier(target_tier)
		var tier_pool: Array[StringName] = _unlocked_candidates_by_tier(profile, tier)
		if tier_pool.is_empty():
			continue
		var pick: StringName = tier_pool[Rng.randi_range(0, tier_pool.size() - 1)]
		if pick not in profile.unlocked_units:
			profile.unlocked_units.append(pick)
			GameLog.info("unlock", "Meta unit granted", {"id": pick, "round": round_index, "tier": tier})
			return pick
	# Fallback: target tier не дал результата — ищем по всем tiers.
	for tier in [1, 2, 3]:
		var pool: Array[StringName] = _unlocked_candidates_by_tier(profile, tier)
		if not pool.is_empty():
			var fallback_pick: StringName = pool[Rng.randi_range(0, pool.size() - 1)]
			profile.unlocked_units.append(fallback_pick)
			GameLog.info("unlock", "Meta unit granted (fallback)", {"id": fallback_pick, "round": round_index, "tier": tier})
			return fallback_pick
	# Ничего не нашли — все unlocked.
	GameLog.debug("unlock", "No units to unlock", {"round": round_index})
	return &""


## Возвращает юнитов tier=tier из UnitsMeta, которых ещё нет в profile.
static func _unlocked_candidates_by_tier(profile: MetaProfile, tier: int) -> Array[StringName]:
	var all_tier: Array[StringName] = UnitsMeta.ids_by_tier(tier)
	var result: Array[StringName] = []
	for id in all_tier:
		if id not in profile.unlocked_units:
			result.append(id)
	return result


## Tier-вeс для unlock: 60% target, 30% target-1, 10% target+1.
## Идентично логике в RewardScreen._pick_tier — консистентность reward/meta.
static func _pick_unlock_tier(target: int) -> int:
	var r: float = Rng.randf()
	if r < 0.6:
		return target
	elif r < 0.9:
		return maxi(1, target - 1)
	else:
		return mini(3, target + 1)