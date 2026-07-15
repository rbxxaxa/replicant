--!strict
local RunService = game:GetService("RunService")

local ComponentManager = require(script.Parent.ComponentManager)
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

export type ServerOnlySignal<EventParams> = {
	FireAllClients: (params: EventParams) -> (),
	Event: Signal.Signal<EventParams>,
}

-- This file is a typing abomination sorry...
export type BaseComponent<InitParams, ReplicatedState, ServerState, ClientState> = {
	getById: (id: number?) -> any,
	createServerOnlyEvent: <EventParams>(options: any) -> (any, number),
	createSendMessageToServerEvent: <EventParams>(options: any) -> (any, number),

	setNew: (
		(params: InitParams) -> (ReplicatedState, ServerState),
		((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			}
		) -> any) | ((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			},
			params: InitParams
		) -> any)
	) -> (params: InitParams) -> any,

	setNewClient: (
		(replicatedState: ReplicatedState) -> ClientState,
		(
			clientBare: {
				id: number,
				replicatedState: ReplicatedState,
				clientState: ClientState,
				isClient: boolean,
				isServer: boolean,
				uniqueId: number,
			}
		) -> any
	) -> (id: number, replicatedState: ReplicatedState) -> any,

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

local function createBaseComponent<InitParams, ReplicatedState, ServerState, ClientState>(options: {
	module: ModuleScript,
	paramsType: InitParams,
	replicatedStateType: ReplicatedState,
	serverStateType: ServerState,
	clientStateType: ClientState,
	serializeReplicatedState: ((any) -> (buffer?, any))?,
	deserializeReplicatedState: ((buffer?, any) -> any)?,
})
	local nextId = 1

	type ServerType = typeof(setmetatable(
		{} :: {
			id: number,
			replicatedState: ReplicatedState,
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
			clientState: ClientState,
			isServer: boolean,
			isClient: boolean,
			uniqueId: number,
		},
		{}
	))

	local componentId: number?
	if RunService:IsServer() then componentId = ComponentManager.registerComponent(options.module) end

	local moduleName = options.module.Name

	local mt = {
		serverInstances = {} :: { [number]: ServerType },
		clientInstances = {} :: { [number]: ClientType },
		created = Signal.new(),
		destroyed = Signal.new(),
	}

	local createdThisFrame: { [number]: true } = {}
	mt.setNew = function(
		constructCallback: (params: InitParams) -> (ReplicatedState, ServerState),
		finalizeCallback: ((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
				serverState: ServerState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			}
		) -> any) | ((
			serverBare: {
				id: number,
				replicatedState: ReplicatedState,
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
			ComponentManager.assertNotDestroying()

			ComponentManager.raiseCreating()

			local id = nextId
			nextId += 1

			local replicatedState, serverState = constructCallback(params)
			local uniqueId = (componentId :: number) * 2 ^ 32 + id

			ComponentManager.queueCreate(componentId :: number, id, deepCopy(replicatedState))

			local value = {
				id = id,
				uniqueId = uniqueId,
				replicatedState = replicatedState,
				serverState = serverState,
				isClient = false,
				isServer = true,
			}

			local final = (finalizeCallback :: any)(value, params)

			mt.serverInstances[id] = value :: any
			createdThisFrame[id] = true

			ComponentManager.unraiseCreating()

			mt.created:Fire(final)

			return final
		end
	end

	mt.setNewClient = function(
		constructCallback: (replicatedState: ReplicatedState) -> ClientState,
		finalizeCallback: (
			clientBare: {
				id: number,
				replicatedState: ReplicatedState,
				clientState: ClientState,
				isServer: boolean,
				isClient: boolean,
				uniqueId: number,
			}
		) -> any
	)
		return function(id: number, replicatedState: ReplicatedState, replicatedComponentId: number?)
			assert(RunService:IsClient(), "This function can only be called on the client")

			local clientState = constructCallback(replicatedState)
			local value = {
				id = id,
				uniqueId = if replicatedComponentId then replicatedComponentId * 2 ^ 32 + id else 0,
				replicatedState = replicatedState,
				clientState = clientState,
				isServer = false,
				isClient = true,
			}
			mt.clientInstances[id] = value :: any

			local final = finalizeCallback(value)

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

	mt.serializeReplicatedState = function(replicatedState: ReplicatedState): (buffer?, any)
		if not options.serializeReplicatedState then return nil, replicatedState end

		local b, serializedTable = options.serializeReplicatedState(replicatedState)
		return b, serializedTable
	end

	mt.deserializeReplicatedState = function(b: buffer?, serializedTable: any): ReplicatedState
		if not options.deserializeReplicatedState then return serializedTable end

		return options.deserializeReplicatedState(b, serializedTable)
	end

	mt.getDataForReplication = function(id)
		local instance = mt.serverInstances[id]
		if not instance then errorInstanceNotFound(moduleName, id) end

		return instance.replicatedState
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

				ComponentManager.queueEventServer(componentId, t.id, eventIndex, params)
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

					ComponentManager.queueSignalServer(componentId, eventIndex, params)
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
				ComponentManager.queueEventClient(componentId, t.id, eventIndex, params)
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
			ComponentManager.assertNotCreating()
			if t._destroying == true then return end

			ComponentManager.raiseDestroying();

			(t :: any)._destroying = true
			ComponentManager.queueDestroy(componentId :: number, t.id)
			xpcall(function()
				callback(t)
			end, warn :: any)
			mt.serverInstances[t.id] = nil

			ComponentManager.unraiseDestroying()

			mt.destroyed:Fire(t)
		end
	end

	mt.setCleanUpClientCallback = function(callback: (t: any) -> nil)
		return function(id: number)
			assert(RunService:IsClient(), "This function can only be called on the client")
			xpcall(function()
				local instance = mt.clientInstances[id]
				if not instance then errorInstanceNotFound(moduleName, id) end

				callback(mt.clientInstances[id])
				mt.clientInstances[id] = nil

				mt.destroyed:Fire(instance)
			end, warn :: any)
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

	return (mt :: any) :: BaseComponent<InitParams, ReplicatedState, ServerState, ClientState>, ({} :: any) :: ServerType, ({} :: any) :: ClientType
end

return {
	createBaseComponent = createBaseComponent,
}
