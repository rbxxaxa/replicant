--!strict
-- One observer per handle, independent of the replicated object's lifetime. Dependencies are
-- injected so the streaming state machine can be exercised outside the engine.
local InstanceHandleLifecycle = {}
local WAIT_TIMEOUT = 60
local STALE_RETRY_DELAY = 0.1

export type Scheduler = {
	defer: (() -> ()) -> thread,
	cancel: (thread) -> (),
	wait: (number?) -> (),
}

function InstanceHandleLifecycle.observe(
	handles: { [string]: any },
	onIn: (string, any) -> (),
	onOut: (string, any) -> (),
	isAvailable: (any) -> boolean,
	scheduler: Scheduler
): () -> ()
	local stopped = false
	local observers: { any } = {}

	for key, handle in handles do
		local observer: any = { current = nil, connection = nil, worker = nil }
		table.insert(observers, observer)

		local function disconnect()
			if observer.connection then
				observer.connection:Disconnect()
				observer.connection = nil
			end
		end

		local queueWait: () -> ()
		local function detach()
			local previous = observer.current
			if previous == nil then return end
			observer.current = nil
			disconnect()
			onOut(key, previous)
			if not stopped then queueWait() end
		end

		queueWait = function()
			if stopped then return end
			observer.worker = scheduler.defer(function()
				while not stopped do
					-- Missing streamed targets are normal. A finite wait avoids the engine's
					-- infinite-yield warning while retaining one cancelable worker per handle.
					local instance = handle:Wait(WAIT_TIMEOUT)
					if stopped then return end
					-- Handles can still resolve an orphan held by Lua after stream-out. Release
					-- it before yielding, and back off rather than retrying once per frame.
					if instance == nil or not isAvailable(instance) then
						instance = nil
						scheduler.wait(STALE_RETRY_DELAY)
						continue
					end

					observer.current = instance
					observer.connection = instance.AncestryChanged:Connect(function()
						if stopped or observer.current ~= instance then return end
						if not isAvailable(instance) then detach() end
					end)
					-- Connect first, then recheck: never publish an instance that disappeared
					-- between Wait returning and the ancestry listener being installed.
					if not isAvailable(instance) then
						observer.current = nil
						disconnect()
						instance = nil
						scheduler.wait(STALE_RETRY_DELAY)
						continue
					end
					observer.worker = nil
					onIn(key, instance)
					return
				end
			end)
		end

		observer.stop = function()
			if observer.worker then
				-- Cleanup can be called reentrantly by a hook. Never cancel that same thread.
				if observer.worker ~= coroutine.running() then scheduler.cancel(observer.worker) end
				observer.worker = nil
			end
			disconnect()
			local previous = observer.current
			observer.current = nil
			if previous ~= nil then onOut(key, previous) end
		end
		queueWait()
	end

	return function()
		if stopped then return end
		stopped = true
		for _, observer in observers do
			observer.stop()
		end
		table.clear(observers)
	end
end

return InstanceHandleLifecycle
