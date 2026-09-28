--!strict
local RunService = game:GetService("RunService")

local InstanceHandleLifecycle = require(script.Parent.InstanceHandleLifecycle)
local ReplicantManager = require(script.Parent.ReplicantManager)
local Signal = require(script.Parent.Parent.Signal)

-- Deep-copies a replicatedState (plain data: primitives, tables, Roblox instances — no cycles, no
-- metatables per the component contract). Tables are copied recursively; everything else (including
-- Instances and buffers) passes through by reference. Bundled so the package needs no Sift dependency.
local function deepCopy(value: any): any
	if type(value) ~= "table" then return value end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function prepareHandles(handles: any): InstanceHandles
	local result: InstanceHandles = {}
	if handles == nil then return table.freeze(result) end
	assert(type(handles) == "table", "instanceHandles must be a string-to-InstanceHandle table")
	for key, handle in handles do
		assert(type(key) == "string" and typeof(handle) == "InstanceHandle", "instanceHandles must map string keys to InstanceHandles")
		local instance = handle:Get()
		if instance and instance:IsA("Model") and workspace.StreamingEnabled then
			local mode = instance.ModelStreamingMode
			assert(
				mode == Enum.ModelStreamingMode.Atomic or mode == Enum.ModelStreamingMode.Persistent or mode == Enum.ModelStreamingMode.PersistentPerPlayer,
				`Replicant handle '{key}' requires an Atomic or Persistent model; Nonatomic models are unsupported`
			)
		end
		result[key] = handle
	end
	return table.freeze(result)
end

local function callStreamHook(instance: any, method: string, key: string, target: Instance)
	local callback = instance[method]
	if callback then
		-- Hooks mutate presentation immediately. Yielding would let an old stream-in resume
		-- after stream-out/cleanup and reconnect listeners to a stale instance.
		local thread = coroutine.create(callback)
		local ok, failure = coroutine.resume(thread, instance, key, target)
		if not ok then warn(failure) end
		if coroutine.status(thread) ~= "dead" then
			task.cancel(thread)
			warn(`Replicant {method} must not yield (handle '{key}')`)
		end
	end
end

export type ServerOnlySignal<EventParams> = {
	FireAllClients: (params: EventParams) -> (),
	Event: Signal.Signal<EventParams>,
}

-- This file is a typing abomination sorry...
export type InstanceHandles = { [string]: InstanceHandle }

export type Replicant<InitParams, ReplicatedState, ServerState, ClientState, Handles = InstanceHandles> = {
	getById: (id: number?) -> any,
	createServerOnlyEvent: <EventParams>(options: any) -> (any, number),
	createSendMessageToServerEvent: <EventParams>(options: any) -> (any, number),

	setNew: (
		(params: InitParams) -> (ReplicatedState, ServerState, Handles?),
		((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				instanceHandles: Handles,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			}
		) -> any) | ((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				instanceHandles: Handles,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			},
			params: InitParams
		) -> any)
	) -> (params: InitParams) -> any,

	setNewClient: (
		(replicatedState: ReplicatedState, instanceHandles: Handles) -> ClientState,
		(
			clientBare: {
				id: number,
				replicatedState: ReplicatedState,
				instanceHandles: Handles,
				clientState: ClientState,
				isClient: boolean,
				isServer: boolean,
				uniqueId: number,
			}
		) -> any
	) -> (id: number, replicatedState: ReplicatedState, componentId: number?, instanceHandles: Handles?) -> any,

	setClientLateInit: ((clientComponent: any) -> ()) -> (clientComponent: any) -> (),

	setStaticInitCallbackServer: (callback: () -> ()) -> () -> (),
	setStaticInitCallbackClient: (callback: () -> ()) -> () -> (),
	setValidateReplication: (callback: (replicatedState: ReplicatedState) -> boolean) -> (),
	setDestroyCallback: ((t: any) -> ()) -> (t: any) -> (),
	setCleanUpClientCallback: ((t: any) -> ()) -> (t: any) -> (),
	handleEventFromServer: ((id: number, eventIndex: number, params: any) -> ())?,
	handleEventFromClient: ((id: number, eventIndex: number, params: any, player: Player?) -> ())?,
	handleSignalFromServer: ((params: any) -> ())?,
	setComponentId: (id: number) -> (),
	setHeartbeatServer: ((t: any, dt: number) -> (), interval: number?) -> (dt: number) -> (),
	setHeartbeatClient: ((t: any, dt: number) -> ()) -> (dt: number) -> (),
	getAllInstances: () -> { [number]: any },
	created: Signal.Signal<any>,
	destroyed: Signal.Signal<any>,
	createServerOnlySignal: <EventParams>(options: {
		serializeParams: any,
		deserializeParams: any,
	}) -> ServerOnlySignal<EventParams>,
}

local function errorInstanceNotFound(moduleName: string, id: number)
	if RunService:IsStudio() then
		error(`{moduleName}: Instance with id {id} not found`)
	else
		error(`{moduleName}: Instance not found`)
	end
end

local function defineReplicant<InitParams, ReplicatedState, ServerState, ClientState, Handles>(options: {
	module: ModuleScript,
	paramsType: InitParams,
	replicatedStateType: ReplicatedState,
	serverStateType: ServerState,
	clientStateType: ClientState,
	instanceHandlesType: Handles?,
	serializeReplicatedState: ((any) -> (buffer?, any))?,
	deserializeReplicatedState: ((buffer?, any) -> any)?,
})
	local nextId = 1

	type ServerType = typeof(setmetatable(
		{} :: {
			id: number,
			replicatedState: ReplicatedState,
			instanceHandles: Handles,
			serverState: ServerState,
			isServer: boolean,
			isClient: boolean,
			uniqueId: number,
		},
		{}
	))

	type ClientType = typeof(setmetatable(
		{} :: {
			id: number,
			replicatedState: ReplicatedState,
			instanceHandles: Handles,
			clientState: ClientState,
			isServer: boolean,
			isClient: boolean,
			uniqueId: number,
		},
		{}
	))

	local componentId: number?
	if RunService:IsServer() then componentId = ReplicantManager.registerComponent(options.module) end

	local moduleName = options.module.Name

	local mt = {
		serverInstances = {} :: { [number]: ServerType },
		clientInstances = {} :: { [number]: ClientType },
		created = Signal.new(),
		destroyed = Signal.new(),
	}
	local clientHandleCleanup: { [number]: () -> () } = {}

	local createdThisFrame: { [number]: true } = {}
	mt.setNew = function(
		constructCallback: (params: InitParams) -> (ReplicatedState, ServerState, Handles?),
		finalizeCallback: ((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				instanceHandles: Handles,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			}
		) -> any) | ((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				instanceHandles: Handles,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			},
			params: InitParams
		) -> any)
	)
		return function(params: InitParams)
			assert(RunService:IsServer(), "This function can only be called on the server")
			ReplicantManager.assertNotDestroying()

			ReplicantManager.raiseCreating()

			local id = nextId
			nextId += 1

			local constructOk, replicatedState, serverState, handles = pcall(constructCallback, params)
			if not constructOk then
				ReplicantManager.unraiseCreating()
				error(replicatedState, 2)
			end
			local handlesOk, instanceHandles = pcall(prepareHandles, handles)
			if not handlesOk then
				ReplicantManager.unraiseCreating()
				error(instanceHandles, 2)
			end
			local uniqueId = (componentId :: number) * 2 ^ 32 + id

			ReplicantManager.queueCreate(componentId :: number, id, deepCopy(replicatedState), instanceHandles)

			local value = {
				id = id,
				uniqueId = uniqueId,
				replicatedState = replicatedState,
				instanceHandles = instanceHandles,
				serverState = serverState,
				isClient = false,
				isServer = true,
			}

			-- ⚠ REGISTERED BEFORE FINALIZE, matching setNewClient (which registers before its own
			-- finalize). `queueCreate` above already made this instance visible to the replication
			-- registry — world-scoped walks like `subscribeToWorld`'s snapshot burst can reach it —
			-- so `getDataForReplication` must be able to resolve it DURING finalize, not only after.
			-- Registering late made "subscribe the owner from the finalize callback" error with
			-- "instance not found". `finalizeCallback` setmetatables `value` in place, so storing the
			-- bare table early hands out the same reference the caller ends up with.
			mt.serverInstances[id] = value :: any

			-- ⚠ THE CREATING COUNTER MUST UNWIND EVEN IF FINALIZE THROWS. `raiseCreating` fired above;
			-- an error in a consumer's finalize callback that escapes without `unraiseCreating` pins
			-- the module-global counter, after which EVERY replicant destroy in the entire game fails
			-- "Cannot destroy while in the middle of creating something". A typo in one component's
			-- constructor must not brick the framework for every other component.
			local finalizeOk, final = pcall(finalizeCallback :: any, value, params)
			if not finalizeOk then
				-- Roll back what this constructor registered, so the failed instance is not left as a
				-- ghost the replication registry keeps shipping. The queued destroy pairs with the
				-- queued create; a client that already received the create receives the destroy.
				mt.serverInstances[id] = nil
				ReplicantManager.queueDestroy(componentId :: number, id)
				ReplicantManager.unraiseCreating()
				error(final, 2)
			end

			createdThisFrame[id] = true

			ReplicantManager.unraiseCreating()

			mt.created:Fire(final)

			return final
		end
	end

	mt.setNewClient = function(
		constructCallback: (replicatedState: ReplicatedState, instanceHandles: Handles) -> ClientState,
		finalizeCallback: (
			clientBare: {
				id: number,
				replicatedState: ReplicatedState,
				instanceHandles: Handles,
				clientState: ClientState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			}
		) -> any
	)
		return function(id: number, replicatedState: ReplicatedState, replicatedComponentId: number?, handles: Handles?)
			assert(RunService:IsClient(), "This function can only be called on the client")

			local instanceHandles = prepareHandles(handles)
			local clientState = constructCallback(replicatedState, instanceHandles :: any)
			local value = {
				id = id,
				uniqueId = if replicatedComponentId then replicatedComponentId * 2 ^ 32 + id else 0,
				replicatedState = replicatedState,
				instanceHandles = instanceHandles,
				clientState = clientState,
				isServer = false,
				isClient = true,
			}
			mt.clientInstances[id] = value :: any

			local ok, final = pcall(finalizeCallback :: any, value)
			if not ok then
				mt.clientInstances[id] = nil
				error(final, 2)
			end

			clientHandleCleanup[id] = InstanceHandleLifecycle.observe(instanceHandles, function(key, target)
				callStreamHook(final, "handleStreamedIn", key, target)
			end, function(key, target)
				callStreamHook(final, "handleStreamedOut", key, target)
			end, function(target)
				return target:IsDescendantOf(game)
			end, task :: any)

			mt.created:Fire(final)

			return final
		end
	end

	mt.setClientLateInit = function(callback: (clientComponent: any) -> ())
		return function(clientComponent: any)
			callback(clientComponent)
		end
	end

	if options.serializeReplicatedState then
		assert(options.deserializeReplicatedState, "serializeReplicatedState and deserializeReplicatedState must be provided together")
	end

	if options.deserializeReplicatedState then
		assert(options.serializeReplicatedState, "deserializeReplicatedState and serializeReplicatedState must be provided together")
	end

	mt.serializeReplicatedState = function(replicatedState: ReplicatedState, instanceHandles: Handles?): (buffer?, any, Handles?)
		if not options.serializeReplicatedState then return nil, replicatedState, instanceHandles end

		local b, serializedTable = options.serializeReplicatedState(replicatedState)
		return b, serializedTable, instanceHandles
	end

	mt.deserializeReplicatedState = function(b: buffer?, serializedTable: any): ReplicatedState
		if not options.deserializeReplicatedState then return serializedTable end

		return options.deserializeReplicatedState(b, serializedTable)
	end

	mt.getDataForReplication = function(id)
		local instance = mt.serverInstances[id]
		if not instance then errorInstanceNotFound(moduleName, id) end

		return instance.replicatedState, instance.instanceHandles
	end

	local nextEventIndex = 0
	local events: { [number]: any } = {}
	mt.events = events

	local function validateServerOnlyEvent(options: { [string]: any })
		for k, v in options do
			if typeof(v) ~= "function" then error(`{moduleName}: {k} must be a function`) end
			if typeof(k) ~= "string" then error(`{moduleName}: {k} must be a string`) end
			if
				k ~= "modifyReplicatedState"
				and k ~= "handleEventClient"
				and k ~= "handleEventServer"
				and k ~= "serializeParams"
				and k ~= "deserializeParams"
			then
				error(`{moduleName}: Invalid option: {k}`)
			end
		end
	end
	mt.createServerOnlyEvent = function<EventParams>(options: {
		modifyReplicatedState: (t: any, params: EventParams) -> (),
		handleEventClient: (t: any, params: EventParams) -> (),
		handleEventServer: (t: any, params: EventParams) -> (),
		serializeParams: ((EventParams) -> (buffer?, any))?,
		deserializeParams: ((buffer?, any) -> EventParams)?,
	})
		validateServerOnlyEvent(options :: { [string]: any })

		local eventIndex = nextEventIndex
		nextEventIndex += 1

		if options.serializeParams then assert(options.deserializeParams, "serializeParams and deserializeParams must be provided together") end

		if options.deserializeParams then assert(options.serializeParams, "deserializeParams and serializeParams must be provided together") end

		local eventHandler = {
			modifyReplicatedState = function(t: any, params: EventParams)
				if not options.modifyReplicatedState then return end

				options.modifyReplicatedState(t, params)
			end,
			handleEventClient = function(t: any, params: EventParams)
				if not options.handleEventClient then return end

				options.handleEventClient(t, params)
			end,
			handleEventServer = function(t: any, params: EventParams)
				if not options.handleEventServer then return end

				options.handleEventServer(t, params)
			end,
			serializeParams = function(params: EventParams)
				if not options.serializeParams then return nil, params end

				local b, serializedParams = options.serializeParams(params)
				return b :: any, serializedParams :: any
			end,
			deserializeParams = function(b: buffer?, t: any)
				if not options.deserializeParams then return t end

				return options.deserializeParams(b, t)
			end,
		}
		events[eventIndex] = eventHandler

		if RunService:IsServer() then
			local callback = function(t: any, params: EventParams)
				if t._destroying then
					warn(`This instance of {moduleName} is being destroyed`)
					return
				end
				assert(typeof(params) == "table", `{moduleName}: params is not a table`)

				ReplicantManager.queueEventServer(componentId, t.id, eventIndex, params)
				eventHandler.modifyReplicatedState(t, params)
				eventHandler.handleEventServer(t, params)
			end

			return callback
		else
			local callback = function(t: any, params: EventParams)
				error(`{moduleName}: This function can only be called on the server`)

				return
			end

			return callback
		end
	end

	local eventIndexToSignal: { [number]: Signal.Signal<any> } = {}
	mt.createServerOnlySignal = function<EventParams>(options: {
		serializeParams: ((EventParams) -> (buffer?, any))?,
		deserializeParams: ((buffer?, any) -> EventParams)?,
	})
		validateServerOnlyEvent(options :: { [string]: any })

		local eventIndex = nextEventIndex
		nextEventIndex += 1

		if options.serializeParams then assert(options.deserializeParams, "serializeParams and deserializeParams must be provided together") end

		if options.deserializeParams then assert(options.serializeParams, "deserializeParams and serializeParams must be provided together") end

		local eventHandler = {
			serializeParams = function(params: EventParams)
				if not options.serializeParams then return nil, params end

				local b, serializedParams = options.serializeParams(params)
				return b :: any, serializedParams :: any
			end,
			deserializeParams = function(b: buffer?, t: any)
				if not options.deserializeParams then return t end

				return options.deserializeParams(b, t)
			end,
		}
		events[eventIndex] = eventHandler
		eventIndexToSignal[eventIndex] = Signal.new()

		if RunService:IsServer() then
			return {
				FireAllClients = function(params: EventParams)
					assert(typeof(params) == "table", `{moduleName}: params is not a table`)

					ReplicantManager.queueSignalServer(componentId, eventIndex, params)
				end,
				Event = eventIndexToSignal[eventIndex],
			}
		else
			return {
				FireAllClients = function(params: EventParams)
					error(`{moduleName}: This function can only be called on the server`)
				end,
				Event = eventIndexToSignal[eventIndex],
			}
		end
	end

	local function validateSendMessageToServerEvent(options: { [string]: any })
		for k, v in options do
			if typeof(v) ~= "function" then error(`{moduleName}: {k} must be a function`) end
			if typeof(k) ~= "string" then error(`{moduleName}: {k} must be a string`) end
			if k ~= "handleEventServer" then error(`{moduleName}: Invalid option: {k}`) end
		end
	end

	mt.createSendMessageToServerEvent = function<EventParams>(
		options: {
			-- `player` is the client that sent this message. Handlers MUST validate it against the
			-- target instance's owner — the framework does not (the client picks the target id), so
			-- an unchecked handler lets any client drive any instance. See the Components CLAUDE.md.
			handleEventServer: (t: any, params: EventParams, player: Player?) -> (),
		}
	)
		validateSendMessageToServerEvent(options :: { [string]: any })

		local eventIndex = nextEventIndex
		nextEventIndex += 1

		local eventHandler = {
			-- Marks this event index as reachable from the client. handleEventFromClient rejects any
			-- index NOT so marked — a server-only event/signal shares this same `events` table and
			-- must never be invocable by a crafted client message (its handleEventServer does no
			-- sender validation). This is a security boundary, not a convention.
			acceptsClientMessage = true,
			handleEventServer = function(t: any, params: EventParams, player: Player?)
				options.handleEventServer(t, params, player)
			end,
		}
		events[eventIndex] = eventHandler

		if RunService:IsServer() then
			local callback = function(t: any, params: EventParams)
				error(`{moduleName}: This function can only be called on the client`)

				return
			end

			return callback
		else
			local callback = function(t: any, params: EventParams)
				assert(typeof(params) == "table", `{moduleName}: params is not a table`)
				ReplicantManager.queueEventClient(componentId, t.id, eventIndex, params)
			end

			return callback
		end
	end

	mt.handleEventFromServer = function(id: number, eventIndex: number, params: any)
		assert(RunService:IsClient(), "This function can only be called on the client")
		xpcall(function()
			local instance = mt.clientInstances[id]
			if not instance then errorInstanceNotFound(moduleName, id) end

			local eventHandler = events[eventIndex]
			if not eventHandler then error(`{moduleName}: Event with index {eventIndex} not found`) end

			eventHandler.modifyReplicatedState(instance, params)
			eventHandler.handleEventClient(instance, params)
		end, warn :: any)
	end

	mt.handleSignalFromServer = function(eventIndex: number, params: any)
		local signal = eventIndexToSignal[eventIndex]
		if not signal then error(`{moduleName}: Signal with index {eventIndex} not found`) end
		signal:Fire(params)
	end

	mt.handleEventFromClient = function(id: number, eventIndex: number, params: any, player: Player?)
		assert(RunService:IsServer(), "This function can only be called on the server")

		local instance = mt.serverInstances[id]
		if not instance then
			if RunService:IsStudio() then
				errorInstanceNotFound(moduleName, id)
			else
				-- Suppress in a live game, since this is expected to happen many times.
				return
			end
		end

		local eventHandler = events[eventIndex]
		if not eventHandler then error(`{moduleName}: Event with index {eventIndex} not found`) end

		-- Security boundary: only createSendMessageToServerEvent handlers may be driven by a client.
		-- The `events` table also holds server-only events/signals (shared eventIndex space); routing
		-- a crafted client eventIndex to one of those would invoke a server-authoritative handler
		-- (which performs no sender validation) on an attacker-chosen instance.
		if not eventHandler.acceptsClientMessage then
			if RunService:IsStudio() then error(`{moduleName}: event index {eventIndex} is not a client-sendable message`) end
			-- Suppress in a live game — an exploiter can spam invalid indices.
			return
		end

		-- Untrusted client payload: drop anything that isn't a table before handing it to a handler.
		if typeof(params) ~= "table" then return end

		eventHandler.handleEventServer(instance, params, player)
	end

	mt.getById = function(id: number?): any
		if id == nil then return nil end

		if RunService:IsServer() then
			return mt.serverInstances[id]
		else
			return mt.clientInstances[id]
		end
	end

	mt.setComponentId = function(id: number)
		componentId = id
	end

	mt.setDestroyCallback = function(callback: (t: any) -> nil)
		return function(t: any)
			assert(RunService:IsServer(), "This function can only be called on the server")
			ReplicantManager.assertNotCreating()
			if t._destroying == true then return end

			ReplicantManager.raiseDestroying();

			(t :: any)._destroying = true
			ReplicantManager.queueDestroy(componentId :: number, t.id)
			xpcall(function()
				callback(t)
			end, warn :: any)
			mt.serverInstances[t.id] = nil

			ReplicantManager.unraiseDestroying()

			mt.destroyed:Fire(t)
		end
	end

	mt.setCleanUpClientCallback = function(callback: (t: any) -> nil)
		return function(id: number)
			assert(RunService:IsClient(), "This function can only be called on the client")
			local instance = mt.clientInstances[id]
			if not instance then return end
			mt.clientInstances[id] = nil
			local cleanup = clientHandleCleanup[id]
			clientHandleCleanup[id] = nil
			if cleanup then cleanup() end
			xpcall(callback, warn :: any, instance)
			mt.destroyed:Fire(instance)
		end
	end

	local heartbeatAccumulator: number = 0
	mt.setHeartbeatServer = function(callback: (t: any, dt: number) -> nil, interval: number?)
		local intervalNumber: number = if interval == nil then 0 else interval
		return function(dt: number)
			assert(RunService:IsServer(), "This function can only be called on the server")

			heartbeatAccumulator += dt

			if intervalNumber == 0 then
				for id, instance in mt.serverInstances do
					if not createdThisFrame[id] then callback(instance, dt) end
				end
				createdThisFrame = {}
			else
				while heartbeatAccumulator >= intervalNumber do
					for id, instance in mt.serverInstances do
						if not createdThisFrame[id] then callback(instance, intervalNumber) end
					end
					heartbeatAccumulator -= intervalNumber
				end
				createdThisFrame = {}
			end
		end
	end

	mt.setHeartbeatClient = function(callback: (t: any, dt: number) -> nil)
		return function(dt: number)
			assert(RunService:IsClient(), "This function can only be called on the client")
			for _, instance in mt.clientInstances do
				callback(instance, dt)
			end
		end
	end

	mt.setStaticInitCallbackServer = function(callback: () -> ())
		mt.staticInitServer = callback
		return function() end
	end

	mt.setStaticInitCallbackClient = function(callback: () -> ())
		mt.staticInitClient = callback
		return function() end
	end

	mt.setValidateReplication = function(callback: (replicatedState: ReplicatedState) -> boolean)
		mt.validateReplication = callback
	end

	mt.getAllInstances = function()
		if RunService:IsServer() then
			return mt.serverInstances :: any
		else
			return mt.clientInstances :: any
		end
	end

	return (mt :: any) :: Replicant<InitParams, ReplicatedState, ServerState, ClientState, Handles>, ({} :: any) :: ServerType, ({} :: any) :: ClientType
end

return {
	defineReplicant = defineReplicant,
}
