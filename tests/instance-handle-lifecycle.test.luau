--!strict
-- Deterministic scheduler/handle doubles exercise the shipping streaming state machine.
-- Native InstanceHandle transport still requires the Studio integration check in README.md.
local Lifecycle = require("../src/InstanceHandleLifecycle")

local passed = 0
local function check(message: string, condition: boolean)
	assert(condition, message)
	passed += 1
end

local function fixture()
	local ready: { thread } = {}
	local cancelled: { [thread]: boolean } = {}
	local sleeping: { [thread]: number } = {}
	local handles = {}
	local now = 0
	local scheduler: any = {}
	scheduler.defer = function(callback)
		local worker = coroutine.create(callback)
		table.insert(ready, worker)
		return worker
	end
	scheduler.cancel = function(worker)
		cancelled[worker] = true
		sleeping[worker] = nil
		coroutine.close(worker)
	end
	scheduler.wait = function(seconds)
		if seconds and seconds > 0 then
			sleeping[coroutine.running()] = now + seconds
			coroutine.yield("sleep")
		else
			coroutine.yield("tick")
		end
	end
	local function step()
		local batch = ready
		ready = {}
		for _, worker in batch do
			if cancelled[worker] or coroutine.status(worker) == "dead" then continue end
			local ok, reason = coroutine.resume(worker)
			assert(ok, tostring(reason))
			if reason == "tick" then table.insert(ready, worker) end
		end
	end
	local function makeInstance(name)
		local callbacks = {}
		local instance: any = { Name = name, available = true }
		instance.AncestryChanged = {
			Connect = function(_, callback)
				callbacks[callback] = true
				return {
					Disconnect = function()
						callbacks[callback] = nil
					end,
				}
			end,
		}
		function instance:changeAncestry(available)
			self.available = available
			local copy = table.clone(callbacks)
			for callback in copy do
				callback(self, if available then {} else nil)
			end
		end
		function instance:connections()
			local count = 0
			for _ in callbacks do
				count += 1
			end
			return count
		end
		return instance
	end
	local function makeHandle()
		local handle: any = { value = nil, waitCalls = 0, waiters = {}, timeouts = {} }
		table.insert(handles, handle)
		function handle:Wait(timeout)
			self.waitCalls += 1
			assert(type(timeout) == "number" and timeout > 0 and timeout < math.huge, "Streaming observer must use a finite timeout")
			table.insert(self.timeouts, timeout)
			if self.value then return self.value end
			self.waiters[coroutine.running()] = now + timeout
			coroutine.yield("handle")
			return self.value
		end
		function handle:set(value)
			self.value = value
			if value then
				for worker in self.waiters do
					table.insert(ready, worker)
				end
				table.clear(self.waiters)
			end
		end
		return handle
	end
	local function advance(seconds)
		now += seconds
		for worker, deadline in sleeping do
			if now >= deadline then
				sleeping[worker] = nil
				table.insert(ready, worker)
			end
		end
		for _, handle in handles do
			for worker, deadline in handle.waiters do
				if now >= deadline then
					handle.waiters[worker] = nil
					table.insert(ready, worker)
				end
			end
		end
	end
	return scheduler, step, makeInstance, makeHandle, advance
end

local function isAvailable(instance)
	return instance.available
end

do
	local scheduler, step, makeInstance, makeHandle = fixture()
	local character = makeHandle()
	local hull = makeHandle()
	local state = { health = 100 }
	local bound = {}
	local trace = {}
	local cleanup = Lifecycle.observe({ character = character, hull = hull }, function(key, instance)
		bound[key] = instance
		instance.health = state.health
		table.insert(trace, `in:{key}:{instance.Name}`)
	end, function(key, instance)
		bound[key] = nil
		table.insert(trace, `out:{key}:{instance.Name}`)
	end, isAvailable, scheduler)
	step()
	check("missing targets do not block object construction or invoke hooks", #trace == 0)
	check("one suspended Wait per missing target", character.waitCalls == 1 and hull.waitCalls == 1)
	state.health = 40 -- replicated events continue while no physical instance exists
	local first = makeInstance("first")
	character:set(first)
	step()
	check("stream-in replays latest state", first.health == 40 and bound.character == first)
	check("other handles remain independent", bound.hull == nil and hull.waitCalls == 1)
	first:changeAncestry(true)
	check("reparent inside DataModel does not detach", #trace == 1 and first:connections() == 1)
	character:set(nil)
	first:changeAncestry(false)
	check("stream-out clears binding and disconnects ancestry listener", bound.character == nil and first:connections() == 0)
	step()
	state.health = 15
	local second = makeInstance("second")
	character:set(second)
	step()
	check("second streaming cycle binds new identity and latest state", bound.character == second and second.health == 15)
	check("balanced lifecycle ordering", table.concat(trace, ",") == "in:character:first,out:character:first,in:character:second")
	cleanup()
	cleanup()
	check("cleanup detaches once and disconnects active listener", #trace == 4 and second:connections() == 0)
	hull:set(makeInstance("late hull"))
	step()
	check("cancelled Wait cannot deliver after cleanup", #trace == 4)
end

do
	local scheduler, step, makeInstance, makeHandle = fixture()
	local handle = makeHandle()
	local calls = 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		calls += 1
	end, function()
		calls += 1
	end, isAvailable, scheduler)
	cleanup() -- cancellation before deferred worker has even started
	handle:set(makeInstance("early"))
	step()
	check("cleanup before scheduler starts prevents callbacks", calls == 0 and handle.waitCalls == 0)
end

do
	local scheduler, step, makeInstance, makeHandle, advance = fixture()
	local handle = makeHandle()
	local instance = makeInstance("stale")
	instance.available = false
	handle:set(instance) -- Wait can briefly return a parentless identity during stream-out
	local calls = 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		calls += 1
	end, function()
		calls += 1
	end, isAvailable, scheduler)
	step()
	check("stale handle does not publish parentless instance or spin", calls == 0 and handle.waitCalls == 1)
	advance(0.05)
	step()
	check("orphan retry waits instead of polling every scheduler frame", handle.waitCalls == 1)
	handle:set(nil)
	advance(0.05)
	step()
	check("stale handle transitions into suspended Wait", handle.waitCalls == 2)
	cleanup()
	instance.available = true
	handle:set(instance)
	step()
	check("stale retry is cancel safe", calls == 0)
end

do
	local scheduler, step, makeInstance, makeHandle = fixture()
	local handle = makeHandle()
	local instance = makeInstance("reentrant")
	handle:set(instance)
	local incoming, outgoing = 0, 0
	local cleanup: () -> () = function()
		error("not assigned")
	end
	cleanup = Lifecycle.observe({ model = handle }, function()
		incoming += 1
		cleanup()
	end, function()
		outgoing += 1
	end, isAvailable, scheduler)
	step()
	check("cleanup during stream-in balances hooks without cancelling the callback", incoming == 1 and outgoing == 1 and instance:connections() == 0)
	step()
	check("reentrant cleanup does not queue another watcher", handle.waitCalls == 1)
end

do
	local scheduler, step, makeInstance, makeHandle, advance = fixture()
	local handle = makeHandle()
	local orphan = makeInstance("externally retained orphan")
	orphan.available = false
	handle:set(orphan)
	local incoming, outgoing = 0, 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		incoming += 1
	end, function()
		outgoing += 1
	end, isAvailable, scheduler)
	step()
	for _ = 1, 3 do
		advance(0.1)
		step()
		step() -- multiple scheduler turns at the same time must not poll again
	end
	check("externally retained orphan retries only after each backoff", handle.waitCalls == 4 and incoming == 0 and orphan:connections() == 0)
	local replacement = makeInstance("replacement after orphan")
	handle:set(replacement)
	advance(0.1)
	step()
	check("replacement identity binds after orphan retry", incoming == 1 and replacement:connections() == 1)
	cleanup()
	check("replacement lifecycle remains balanced", outgoing == 1 and replacement:connections() == 0)
end

do
	local scheduler, step, makeInstance, makeHandle, advance = fixture()
	local handle = makeHandle()
	local orphan = makeInstance("cancel orphan retry")
	orphan.available = false
	handle:set(orphan)
	local calls = 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		calls += 1
	end, function()
		calls += 1
	end, isAvailable, scheduler)
	step()
	cleanup()
	handle:set(makeInstance("cancelled replacement"))
	advance(0.1)
	step()
	check("cleanup cancels a delayed orphan retry", calls == 0 and handle.waitCalls == 1)
end

do
	local scheduler, step, makeInstance, makeHandle = fixture()
	local handle = makeHandle()
	local instance = makeInstance("connect race")
	handle:set(instance)
	local originalConnect = instance.AncestryChanged.Connect
	instance.AncestryChanged.Connect = function(self, callback)
		local connection = originalConnect(self, callback)
		instance.available = false -- disappearance while the listener was being installed
		return connection
	end
	local calls = 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		calls += 1
	end, function()
		calls += 1
	end, isAvailable, scheduler)
	step()
	check("disappearance during connection does not emit unmatched hooks", calls == 0 and instance:connections() == 0)
	cleanup()
end

do
	local scheduler, step, makeInstance, makeHandle, advance = fixture()
	local handle = makeHandle()
	local incoming, outgoing = 0, 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		incoming += 1
	end, function()
		outgoing += 1
	end, isAvailable, scheduler)
	step()
	advance(59)
	step()
	check("missing target remains suspended before bounded timeout", handle.waitCalls == 1 and incoming == 0)
	advance(1)
	step()
	check("timeout alone never emits stream hooks", incoming == 0 and outgoing == 0)
	advance(0.1)
	step()
	check("bounded timeout rearms one wait for a still absent target", handle.waitCalls == 2 and handle.timeouts[1] == 60 and handle.timeouts[2] == 60)
	local target = makeInstance("after timeout")
	handle:set(target)
	step()
	check("target arriving after timeout binds once", incoming == 1 and target:connections() == 1)
	cleanup()
	check("target bound after retry cleans up once", outgoing == 1 and target:connections() == 0)
end

do
	local scheduler, step, makeInstance, makeHandle, advance = fixture()
	local handle = makeHandle()
	local calls = 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		calls += 1
	end, function()
		calls += 1
	end, isAvailable, scheduler)
	step()
	advance(60)
	step() -- timeout returned nil, next-step retry is queued
	cleanup()
	step()
	advance(60)
	handle:set(makeInstance("after timeout cancellation"))
	step()
	check("cleanup between timeout and retry cancels the queued worker", calls == 0 and handle.waitCalls == 1)
end

do
	local scheduler, step, makeInstance, makeHandle, advance = fixture()
	local handle = makeHandle()
	local calls = 0
	local cleanup = Lifecycle.observe({ model = handle }, function()
		calls += 1
	end, function()
		calls += 1
	end, isAvailable, scheduler)
	step()
	advance(60)
	step()
	advance(0.1)
	step() -- second bounded wait is now suspended
	cleanup()
	advance(60)
	handle:set(makeInstance("after rearmed cancellation"))
	step()
	check("cleanup cancels a rearmed wait before its next expiry", calls == 0 and handle.waitCalls == 2)
end

print(`InstanceHandleLifecycle: {passed} passed`)
