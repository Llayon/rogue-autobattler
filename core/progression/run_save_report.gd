class_name RunSaveReport extends RefCounted
## The structured result of a checkpoint attempt.
##
## H-08: a checkpoint commit and a meta pointer commit are TWO
## separate writes, so they are reported separately. A checkpoint
## that landed while the meta pointer failed is a PARTIAL SUCCESS:
## the checkpoint stays valid, but the caller must know that the
## pointer that makes Continue discoverable was not published.
##
## The report is immutable: the values are fixed at construction.

## The run file landed on the disk.
var checkpoint_committed: bool = false

## The meta pointer landed.
var meta_committed: bool = false

## The seed of the run the report is about.
var seed_value: int = 0

## The status code of the failed part, 0 when everything landed.
var checkpoint_status: int = 0
var meta_status: int = 0

## A human readable detail of the failed part.
var detail: String = ""


static func complete(p_seed: int) -> RefCounted:
	var r: RefCounted = (load("res://core/progression/run_save_report.gd") as GDScript).new()
	r.checkpoint_committed = true
	r.meta_committed = true
	r.seed_value = p_seed
	return r


static func checkpoint_only(p_seed: int, p_status: int, p_detail: String) -> RefCounted:
	var r: RefCounted = (load("res://core/progression/run_save_report.gd") as GDScript).new()
	r.checkpoint_committed = true
	r.meta_committed = false
	r.seed_value = p_seed
	r.checkpoint_status = p_status
	r.detail = p_detail
	return r


static func meta_only(p_seed: int, p_status: int, p_detail: String) -> RefCounted:
	var r: RefCounted = (load("res://core/progression/run_save_report.gd") as GDScript).new()
	r.checkpoint_committed = false
	r.meta_committed = true
	r.seed_value = p_seed
	r.meta_status = p_status
	r.detail = p_detail
	return r


static func failed(p_seed: int, p_status: int, p_detail: String) -> RefCounted:
	var r: RefCounted = (load("res://core/progression/run_save_report.gd") as GDScript).new()
	r.checkpoint_committed = false
	r.meta_committed = false
	r.seed_value = p_seed
	r.checkpoint_status = p_status
	r.detail = p_detail
	return r


## Everything landed.
func is_complete() -> bool:
	return checkpoint_committed and meta_committed


## The checkpoint landed, but the meta pointer did not: the run is on
## the disk and only the POINTER publication is missing.
func is_partial() -> bool:
	return checkpoint_committed and not meta_committed


## Nothing landed.
func is_failed() -> bool:
	return not checkpoint_committed and not meta_committed
