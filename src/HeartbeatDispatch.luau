--!strict
-- Runs heartbeats so that one that throws cannot stall the rest of the frame. Each replicant
-- instance steps in its own protected call: an instance whose step throws skips only that step,
-- while its siblings, the other replicant types and the replication flush after them still run.
-- Unprotected, a replicant that throws every frame stopped replication for the whole server. A
-- protected call costs roughly 35 ns more than a plain one, far below any real heartbeat body.
local HeartbeatDispatch = {}

-- Raises the error again on its own thread with the failed step's traceback, so it still reaches
-- the output and ScriptContext.Error without stopping the caller.
function HeartbeatDispatch.report(message: any)
	task.spawn(error, debug.traceback(tostring(message), 2), 0)
end

-- Steps every instance whose id is not in skip, handing any error to onError.
function HeartbeatDispatch.stepAll<T>(
	instances: { [number]: T },
	skip: { [number]: true }?,
	callback: (T, number) -> (),
	dt: number,
	onError: (message: any) -> ()
)
	for id, instance in instances do
		if skip == nil or not skip[id] then xpcall(callback, onError, instance, dt) end
	end
end

return HeartbeatDispatch
