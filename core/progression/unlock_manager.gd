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
	profile.soul_currency = maxi(0, profile.soul_currency + amount)


static func is_unit_unlocked(profile: MetaProfile, unit_id: StringName) -> bool:
	return profile != null and unit_id in profile.unlocked_units