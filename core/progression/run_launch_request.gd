class_name RunLaunchRequest extends RefCounted
## The explicit intent behind a launch request.
##
## A run can be started in two ways, and they are DIFFERENT intents:
##
##   NEW_RUN  -> a fresh run with a new seed. The runtime starts
##               empty and every subsystem is regenerated.
##   CONTINUE -> the persisted run identified by `seed`. The runtime
##               is restored from the save; nothing is regenerated.
##
## The historical routing passed only a seed, so both intents looked
## identical and Continue silently started a new run.
##
## The seed is NOT the intent: a CONTINUE also carries a seed (the
## persisted run identity), and a NEW_RUN may be given any seed.

enum Mode {
	NEW_RUN,
	CONTINUE,
}


## The launch mode.
var mode: int = Mode.NEW_RUN

## The run seed. For NEW_RUN it is the requested seed; for CONTINUE it
## is the persisted run identity to restore.
var seed: int = 0


static func new_run(p_seed: int) -> RunLaunchRequest:
	var request := RunLaunchRequest.new()
	request.mode = Mode.NEW_RUN
	request.seed = p_seed
	return request


static func continue_run(p_seed: int) -> RunLaunchRequest:
	var request := RunLaunchRequest.new()
	request.mode = Mode.CONTINUE
	request.seed = p_seed
	return request


## True when this request starts a brand new run.
func is_new_run() -> bool:
	return mode == Mode.NEW_RUN


## True when this request restores a persisted run.
func is_continue() -> bool:
	return mode == Mode.CONTINUE


## A stable wire name for the mode, used in diagnostics and in the
## persisted checkpoint metadata.
func mode_name() -> String:
	return "new_run" if is_new_run() else "continue"
