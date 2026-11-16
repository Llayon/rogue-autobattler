class_name MetaStore extends RefCounted
## The ATOMIC writer of the MetaProfile.
##
## The baseline wrote the profile DIRECTLY to `meta.tres` through
## `ResourceSaver.save()`. A crash during that write left the file
## truncated, and the loader then returned a DEFAULT profile: the
## statistics, the unlocks, the currency and the settings were
## silently gone.
##
## This store applies the SAME crash-recoverable commit protocol the
## checkpoint repository uses, but ONLY for the profile. It is a
## separate, small mechanism on purpose: the checkpoint repository
## owns the run-file format, and the profile has its own lifecycle
## (it is written at a different frequency and it is read by the menu
## without a run).
##
## The write protocol:
##
##   1. serialize the profile into a scratch `.tres` file
##   2. copy its BYTES into `<target>.tmp` through the file seam
##   3. VERIFY the temp: it must load and it must be a MetaProfile
##   4. if the target exists: rename `target` -> `target.commit-old`
##   5. rename `tmp` -> `target`          (the swap)
##   6. VERIFY the target
##   7. remove `target.commit-old`
##
## The recovery protocol (run before EVERY read and EVERY write):
##
##   target valid                     -> the target is authoritative
##   target missing, commit-old valid -> restore the commit-old
##   target invalid, commit-old valid -> restore the commit-old
##   both invalid                     -> an EXPLICIT failure; nothing
##                                       is destroyed
##
## The recovery is IDEMPOTENT: a second run over the same state
## changes nothing.
##
## WHY THE SCRATCH FILE: `ResourceSaver` picks the format from the
## file's EXTENSION, and `ResourceLoader` picks the loader the same
## way. A `.tmp` (or `.commit-old`) file therefore cannot be saved or
## loaded as a resource. The profile is serialized into a scratch file
## with a `.tres` extension, and its BYTES are what the seam writes
## and what the verification reads. The scratch file is removed right
## after it is used, and a stale one is cleaned by the recovery.
##
## THE CACHE: `ResourceLoader` caches resources, so a validation that
## calls `load(path)` can return the CACHED object and prove nothing
## about the bytes that were just written. Every load here passes
## `CACHE_MODE_IGNORE`, and the verification loads the BYTES through a
## scratch path, so it always reads the disk.

const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const RunSaveFileOpsScript = preload("res://core/save/run_save_file_ops.gd")

const META_FILE_NAME: String = "meta.tres"
const TEMP_SUFFIX: String = ".tmp"
const COMMIT_OLD_SUFFIX: String = ".commit-old"
const SCRATCH_PREFIX: String = "meta.serialize."
const VERIFY_PREFIX: String = "meta.verify."
const SCRATCH_SUFFIX: String = ".tmp.tres"

## A0.1: the scratch and verify files are UNIQUE per store instance.
## A fixed name would let two stores over the SAME directory overwrite
## each other's scratch file, so a concurrent operation could verify
## the OTHER operation's bytes.
var _instance_token: String = ""

## The scratch path used to serialize the profile.
func scratch_path() -> String:
	return meta_dir + SCRATCH_PREFIX + _instance_token + SCRATCH_SUFFIX


## The scratch path used to verify a file's bytes.
func verify_path() -> String:
	return meta_dir + VERIFY_PREFIX + _instance_token + SCRATCH_SUFFIX

## The directory the profile lives in.
var meta_dir: String = ""

## The filesystem adapter. Tests inject a fault variant.
var ops: Object = null

## The last error's detail (empty when the last operation succeeded).
var last_error: String = ""

## A0.1: whether a profile FILE was on the disk during the last load.
## It separates "the file never existed" (the first run) from "the
## file existed" (it was read, or it was damaged).
var last_load_existed: bool = false


func _init(p_dir: String = "user://saves/") -> void:
	meta_dir = p_dir
	if ops == null:
		ops = RunSaveFileOpsScript.new()
	# A0.1: the scratch files are unique per instance, so two stores
	# over the same directory never collide.
	_instance_token = str(get_instance_id()) + "_" + str(Time.get_ticks_usec())


## The profile's path.
func meta_path() -> String:
	return meta_dir + META_FILE_NAME


## The temp file's path.
func temp_path() -> String:
	return meta_path() + TEMP_SUFFIX


## The previous generation's path.
func commit_old_path() -> String:
	return meta_path() + COMMIT_OLD_SUFFIX




## Writes the profile atomically.
##
## Returns true iff the profile is on the disk afterwards. On failure
## the LAST GOOD profile is still there: the previous generation is
## only removed after the new one is verified.
func save_meta(profile: Object) -> bool:
	last_error = ""
	if profile == null:
		last_error = "the profile is null"
		return false
	if not _ensure_dir():
		return false
	# The recovery runs FIRST: a new write never starts while an
	# unfinished previous operation is still on the disk.
	#
	# A0.1: if the recovery could NOT restore the slot (both
	# generations are damaged), the write is ABORTED. Overwriting a
	# fully damaged slot would destroy BOTH generations -- including
	# the data a manual repair might still recover.
	if not _recover():
		# The recovery's own reason is the informative one.
		if last_error == "":
			last_error = "the profile slot could not be recovered"
		return false
	var theTemp: String = temp_path()
	var theTarget: String = meta_path()
	var theCommitOld: String = commit_old_path()
	# 1. serialize into the scratch file.
	var theBytes: PackedByteArray = _serialize(profile)
	if theBytes.is_empty():
		return false
	# 2. the bytes go into the temp file through the seam.
	if not ops.write_bytes_and_flush(theTemp, theBytes):
		_safe_remove(scratch_path())
		last_error = "the temp profile could not be written"
		return false
	_safe_remove(scratch_path())
	# 3. verify the temp: it must LOAD and be a MetaProfile.
	if not _verify_file(theTemp):
		_safe_remove(theTemp)
		last_error = "the temp profile failed the verification"
		return false
	# 4. preserve the previous generation.
	var theHadTarget: bool = ops.exists(theTarget)
	if theHadTarget:
		if not ops.rename(theTarget, theCommitOld):
			_safe_remove(theTemp)
			last_error = "the previous generation could not be preserved"
			return false
	# 5. the swap.
	if not ops.rename(theTemp, theTarget):
		# The rollback: the previous generation goes back.
		if theHadTarget:
			ops.rename(theCommitOld, theTarget)
		_safe_remove(theTemp)
		last_error = "the swap failed"
		return false
	# 6. verify the result.
	if not _verify_file(theTarget):
		# The new file is not usable: restore the previous one.
		if theHadTarget and ops.exists(theCommitOld):
			ops.rename(theTarget, theTarget + ".invalid")
			ops.rename(theCommitOld, theTarget)
		last_error = "the written profile failed the verification"
		return false
	# 7. the previous generation is no longer needed.
	#
	# A0.1: a failed cleanup does NOT make the write a failure: the
	# new profile IS verified and on the disk. The leftover is a
	# recovery obligation, and the recovery removes it on the next
	# load. Reporting a failure here would tell the caller that the
	# profile was NOT saved while it actually IS.
	if theHadTarget and ops.exists(theCommitOld):
		if not ops.remove(theCommitOld):
			last_error = "the previous generation could not be removed"
	return true


## Loads the profile.
##
## The THREE outcomes, and they must not be confused:
##
##   the file NEVER existed   -> a NEW default profile (the first run)
##   the file is valid        -> the profile
##   the file is DAMAGED      -> null, and `last_error` says why
##
## The damaged case is NOT a default profile: the data is still on the
## disk, and silently replacing it with a default would destroy the
## player's progress. The caller must report the failure.
func load_meta() -> Object:
	last_error = ""
	last_load_existed = false
	if not _ensure_dir():
		return null
	if not _recover():
		# Both generations are damaged: an EXPLICIT failure. The
		# caller must not treat this as "no profile" -- the data is
		# still on the disk, and replacing it with a default would
		# destroy it.
		return null
	if not ops.exists(meta_path()):
		# The file never existed: the FIRST run. A new profile is
		# the correct answer, not a failure.
		return MetaProfileScript.new()
	last_load_existed = true
	var theProfile: Object = _load_from_disk(meta_path())
	if theProfile == null:
		last_error = "the profile could not be loaded"
		return null
	return theProfile


## Recovers the slot: restores the previous generation when the
## target is missing or damaged, and removes a stale commit-old.
##
## Returns false only when BOTH generations are damaged -- then
## nothing is destroyed and the caller must report the failure.
func _recover() -> bool:
	# A stale scratch file from an interrupted serialization is not a
	# generation: it is removed. The PROTOCOL's temp file is stale
	# too: a new write rewrites it, but a stale one must not linger.
	if ops.exists(scratch_path()):
		_safe_remove(scratch_path())
	if ops.exists(verify_path()):
		_safe_remove(verify_path())
	if ops.exists(temp_path()):
		_safe_remove(temp_path())
	var theTarget: String = meta_path()
	var theCommitOld: String = commit_old_path()
	var theTargetValid: bool = ops.exists(theTarget) and _verify_file(theTarget)
	var theCommitValid: bool = ops.exists(theCommitOld) and _verify_file(theCommitOld)
	if theTargetValid:
		# The target is authoritative. A stale commit-old is removed.
		if theCommitValid:
			if not ops.remove(theCommitOld):
				last_error = "the stale previous generation could not be removed"
		return true
	if theCommitValid:
		# The target is missing or damaged: restore the previous one.
		if ops.exists(theTarget):
			ops.rename(theTarget, theTarget + ".invalid")
		if not ops.rename(theCommitOld, theTarget):
			last_error = "the previous generation could not be restored"
			return false
		return true
	# Neither generation is usable.
	if ops.exists(theTarget) or ops.exists(theCommitOld):
		last_error = "the profile and its previous generation are damaged"
		return false
	return true


## Serializes the profile into the scratch file and returns its bytes.
func _serialize(profile: Object) -> PackedByteArray:
	var theScratch: String = scratch_path()
	_safe_remove(theScratch)
	var theErr: int = ResourceSaver.save(profile, theScratch)
	if theErr != OK:
		last_error = "the profile could not be serialized"
		return PackedByteArray()
	var theBytes: PackedByteArray = ops.read_bytes(theScratch)
	if theBytes.is_empty():
		last_error = "the serialized profile is empty"
		return PackedByteArray()
	return theBytes


## Verifies that the file holds a loadable MetaProfile.
##
## The verification reads the file's BYTES from the disk and loads
## them through a scratch path with a `.tres` extension (the loader
## picks its parser from the extension), with the cache bypassed.
func _verify_file(thePath: String) -> bool:
	if not ops.exists(thePath):
		return false
	var theBytes: PackedByteArray = ops.read_bytes(thePath)
	if theBytes.is_empty():
		return false
	# A0.1: the structural check comes FIRST. If the bytes are not
	# even shaped like a Godot resource, the verification fails
	# WITHOUT handing the garbage to the loader: the loader would log
	# a Parse Error, and a damaged file is a NORMAL condition of the
	# failure model, not a project error.
	if not _looks_like_resource(theBytes):
		return false
	var theVerify: String = verify_path()
	_safe_remove(theVerify)
	if not ops.write_bytes_and_flush(theVerify, theBytes):
		_safe_remove(theVerify)
		return false
	var theProfile: Object = _load_from_disk(theVerify)
	_safe_remove(theVerify)
	return theProfile != null


## Whether the bytes are shaped like a Godot resource.
##
## The check is a HEADER check: a Godot text resource starts with
## `[gd_resource` and ends with the resource's properties. The bytes
## that do not match are rejected WITHOUT the loader, so the
## deliberately damaged files of the failure model never reach the
## parser (and never turn into a logged Parse Error).
func _looks_like_resource(theBytes: PackedByteArray) -> bool:
	if theBytes.size() < 16:
		return false
	var theHead: String = theBytes.slice(0, 12).get_string_from_utf8()
	if not theHead.begins_with("[gd_resource"):
		return false
	# The header must be complete: a truncated file ends without the
	# closing bracket.
	var theText: String = theBytes.get_string_from_utf8()
	return theText.find("]") > 0 and theText.find("type=") > 0


## Loads the profile from the disk, bypassing the cache.
func _load_from_disk(thePath: String) -> Object:
	if not ops.exists(thePath):
		return null
	# The bytes go through a scratch `.tres`, because the loader picks
	# its parser from the extension.
	var theBytes: PackedByteArray = ops.read_bytes(thePath)
	if theBytes.is_empty():
		return null
	var theVerify: String = verify_path()
	_safe_remove(theVerify)
	if not ops.write_bytes_and_flush(theVerify, theBytes):
		_safe_remove(theVerify)
		return null
	# `CACHE_MODE_IGNORE` is the documented way to bypass the
	# ResourceLoader's cache: a cached object would prove nothing
	# about the bytes that are on the disk.
	var theResource: Resource = ResourceLoader.load(
		theVerify, "", ResourceLoader.CACHE_MODE_IGNORE)
	_safe_remove(theVerify)
	if theResource == null:
		return null
	if not (theResource is MetaProfileScript):
		return null
	# The profile must be USABLE: the loader must see the fields.
	if not ("total_runs" in theResource):
		return null
	return theResource


## Creates the directory when it is missing.
func _ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(meta_dir)):
		return true
	var theErr: int = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(meta_dir))
	if theErr != OK and not DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(meta_dir)):
		last_error = "the save directory could not be created"
		return false
	return true


## Removes a file, ignoring the failure.
func _safe_remove(thePath: String) -> void:
	ops.remove(thePath)
