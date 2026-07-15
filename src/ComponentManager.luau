--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RedBlackTree = require(script.Parent.RedBlackTree)
local ReplicationCodec = require(script.Parent.ReplicationCodec)
local Signal = require(script.Parent.Parent.Signal)

local module = {}

-- Registered component types are addressed by a u16 id on the wire, so at most this many
-- distinct component modules can exist. See ReplicationCodec for the byte layout.
local MAX_COMPONENT_TYPES = 2 ^ 16

-- The folder of ObjectValues (one per registered component, name -> module, ComponentId
-- attribute) that tells clients how to map a replicated componentId back to its module.
-- The server creates it at require-time; clients WaitForChild it. This module is required
-- by CreateBaseComponent before any component registers, so the folder exists in time.
-- (It used to be static place-file content — creating it here makes the system self-contained.)
local COMPONENT_MODULE_OBJECT_VALUES_FOLDER_NAME = "ComponentModuleObjectValuesFolder"

local function ensureComponentModuleObjectValuesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(COMPONENT_MODULE_OBJECT_VALUES_FOLDER_NAME)
	if existing then return existing :: Folder end

	local folder = Instance.new("Folder")
	folder.Name = COMPONENT_MODULE_OBJECT_VALUES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local componentModuleObjectValuesFolder: Folder? = if RunService:IsServer() then ensureComponentModuleObjectValuesFolder() else nil

-- Fixed-name RemoteEvents in a dedicated folder. The server creates them at require-time; clients
-- WaitForChild them. Stable names (unlike deriving them from the script path) never change when the
-- package version bumps, and need no RemoteUtil dependency — ComponentManager frames its own buffers.
local REMOTES_FOLDER_NAME = "ReplicantRemotes"

local remotesFolder: Instance
if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing then
		remotesFolder = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = REMOTES_FOLDER_NAME
		folder.Parent = ReplicatedStorage
		remotesFolder = folder
	end
else
	remotesFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
end

local function getRemote(name: string): RemoteEvent
	if RunService:IsServer() then
		local existing = remotesFolder:FindFirstChild(name)
		if existing then return existing :: RemoteEvent end

		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotesFolder
		return remote
	end
	return remotesFolder:WaitForChild(name) :: RemoteEvent
end

local function fireForClients(remote: RemoteEvent, players: { Player }, data: any)
	for _, player in players do
		remote:FireClient(player, data)
	end
end

local setReady = getRemote("SetReady")
local replicateCurrentInstances = getRemote("ReplicateCurrentInstances")
local replicateComponentEvents = getRemote("ReplicateComponentEvents")
local replicateEventsFromClient = getRemote("ReplicateEventsFromClient")

local componentModuleToId = {}
local idToComponentModule = {}
local componentCache = {}

local eventsToSendServer: { any } = {}
local eventsToSendClient: { any } = {}
local eventsToSendToClientQueueType: "create" | "destroy" | nil = nil
local eventsReceivedFromClient: { any } = {}

local function getComponent(componentId: number): any
	if componentCache[componentId] then return componentCache[componentId] end

	local componentModule = idToComponentModule[componentId]
	if not componentModule then error("Component with id " .. componentId .. " not found") end

	componentCache[componentId] = require(componentModule) :: any
	return componentCache[componentId]
end

module.getReadyPlayers = function(): { Player }
	local playersReady: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("ComponentManagerReady") then table.insert(playersReady, player) end
	end
	return playersReady
end
module.playerReadied = Signal.new()

local function cantorPairing(a: number, b: number)
	return 0.5 * (a + b) * (a + b + 1) + b
end

local replicationOrderTree = RedBlackTree.new()
local replicationOrderToBigKey: { [number]: number } = {}
local bigKeyToComponentPair: { [number]: { componentId: number, instanceId: number } } = {}
local bigKeyToReplicationOrder: { [number]: number } = {}

function module.flushReplicationQueue()
	if next(eventsToSendServer) == nil then return end

	local playersReady: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("ComponentManagerReady") then table.insert(playersReady, player) end
	end

	if next(playersReady) then
		local tableResults: { any } = {}
		local records: { ReplicationCodec.IncrementalRecord } = {}

		-- Records the payload's side-channel table (if any) and returns the framing
		-- fields the codec needs: (payload, payloadLen, tablePosition).
		local function framePayload(payloadBuffer: buffer?, payloadTable: any): (buffer?, number, number)
			local payloadLen = if payloadBuffer then buffer.len(payloadBuffer) else 0
			assert(payloadLen < 2 ^ 16, "Buffer is too large to send")

			local tablePosition = 0
			if payloadTable ~= nil then
				table.insert(tableResults, payloadTable)
				tablePosition = #tableResults
			end

			return payloadBuffer, payloadLen, tablePosition
		end

		local totalBufferSize = 4

		for _, event in eventsToSendServer do
			local record: ReplicationCodec.IncrementalRecord
			if event.eventKind == "destroy" then
				record = {
					tag = ReplicationCodec.DESTROY,
					componentId = event.componentId,
					instanceId = event.instanceId,
				}
			elseif event.eventKind == "create" then
				local component = getComponent(event.componentId)
				local payload, payloadLen, tablePosition = framePayload(component.serializeReplicatedState(event.replicatedState))
				record = {
					tag = ReplicationCodec.CREATE,
					componentId = event.componentId,
					instanceId = event.instanceId,
					payload = payload,
					payloadLen = payloadLen,
					tablePosition = tablePosition,
				}
			elseif event.eventKind == "event" then
				local component = getComponent(event.componentId)
				local eventHandler = component.events[event.eventIndex]
				local payload, payloadLen, tablePosition = framePayload(eventHandler.serializeParams(event.params))
				record = {
					tag = ReplicationCodec.EVENT,
					componentId = event.componentId,
					eventIndex = event.eventIndex,
					instanceId = event.instanceId,
					payload = payload,
					payloadLen = payloadLen,
					tablePosition = tablePosition,
				}
			elseif event.eventKind == "signal" then
				local component = getComponent(event.componentId)
				local eventHandler = component.events[event.eventIndex]
				local payload, payloadLen, tablePosition = framePayload(eventHandler.serializeParams(event.params))
				record = {
					tag = ReplicationCodec.SIGNAL,
					componentId = event.componentId,
					eventIndex = event.eventIndex,
					payload = payload,
					payloadLen = payloadLen,
					tablePosition = tablePosition,
				}
			else
				continue
			end

			totalBufferSize += ReplicationCodec.sizeIncremental(record)
			table.insert(records, record)
		end

		local b = buffer.create(totalBufferSize)
		local offset = 0
		buffer.writeu32(b, offset, #records)
		offset += 4

		for _, record in records do
			offset = ReplicationCodec.writeIncremental(b, offset, record)
		end

		fireForClients(replicateComponentEvents, playersReady, {
			b = b,
			tableResults = tableResults,
		})
	end

	table.clear(eventsToSendServer)
	eventsToSendToClientQueueType = nil
end

function module.startServer()
	local playersWaitingToBeReady: { Player } = {}

	setReady.OnServerEvent:Connect(function(player)
		table.insert(playersWaitingToBeReady, player)
	end)

	replicateEventsFromClient.OnServerEvent:Connect(function(player, events)
		for _, event in events do
			if event.eventKind == "event" then
				table.insert(eventsReceivedFromClient, {
					player = player,
					eventKind = "event",
					componentId = event.componentId,
					instanceId = event.instanceId,
					eventIndex = event.eventIndex,
					params = event.params,
				})
			else
				warn("Unknown event kind: " .. event.eventKind)
				continue
			end
		end
	end)

	local staticInitCalled: { [number]: true } = {}

	RunService.Heartbeat:Connect(function(dt)
		for componentModule, componentId in pairs(componentModuleToId) do
			if not staticInitCalled[componentId :: number] then
				staticInitCalled[componentId :: number] = true
				local component = getComponent(componentId :: number)
				if component.staticInitServer then component.staticInitServer() end
			end
		end

		for componentModule, componentId in pairs(componentModuleToId) do
			local component = getComponent(componentId :: number)
			if component.heartbeatServer then
				debug.profilebegin(`{componentModule.Name}::heartbeatServer`)
				component.heartbeatServer(dt)
				debug.profileend()
			end
		end

		module.flushReplicationQueue()

		for i = #playersWaitingToBeReady, 1, -1 do
			local player = playersWaitingToBeReady[i]
			local userId = player.UserId
			if not Players:GetPlayerByUserId(userId) then table.remove(playersWaitingToBeReady, i) end
		end

		if next(playersWaitingToBeReady) then
			local tableResults: { any } = {}
			local records: { ReplicationCodec.SnapshotRecord } = {}

			local pairSequence = {}
			replicationOrderTree:inOrderTraversal(function(replicationOrder)
				local bigKey = replicationOrderToBigKey[replicationOrder]
				table.insert(pairSequence, bigKeyToComponentPair[bigKey])
			end)

			local totalBufferSize = 4
			for _, pair in pairSequence do
				local component = getComponent(pair.componentId)
				local replicatedState = component.getDataForReplication(pair.instanceId)

				local payloadBuffer, payloadTable = component.serializeReplicatedState(replicatedState)
				local payloadLen = if payloadBuffer then buffer.len(payloadBuffer) else 0
				assert(payloadLen < 2 ^ 16, "Buffer is too large to send")

				local tablePosition = 0
				if payloadTable ~= nil then
					table.insert(tableResults, payloadTable)
					tablePosition = #tableResults
				end

				local record: ReplicationCodec.SnapshotRecord = {
					componentId = pair.componentId,
					instanceId = pair.instanceId,
					payload = payloadBuffer,
					payloadLen = payloadLen,
					tablePosition = tablePosition,
				}
				totalBufferSize += ReplicationCodec.sizeSnapshot(record)
				table.insert(records, record)
			end

			local b = buffer.create(totalBufferSize)
			local offset = 0
			buffer.writeu32(b, offset, #records)
			offset += 4

			for _, record in records do
				offset = ReplicationCodec.writeSnapshot(b, offset, record)
			end

			fireForClients(replicateCurrentInstances, playersWaitingToBeReady, {
				b = b,
				tableResults = tableResults,
			})

			for _, player in playersWaitingToBeReady do
				player:SetAttribute("ComponentManagerReady", true)
				module.playerReadied:Fire(player)
			end

			table.clear(playersWaitingToBeReady)
		end

		if next(eventsReceivedFromClient) then
			for _, event in eventsReceivedFromClient do
				xpcall(function()
					local component = getComponent(event.componentId)
					if not component then
						error("Component with id " .. event.componentId .. " not found")
						return
					end

					component.handleEventFromClient(event.instanceId, event.eventIndex, event.params, event.player)
				end, warn :: any)
			end

			table.clear(eventsReceivedFromClient)
		end
	end)
end

function module.startClient()
	local function onChildAdded(objectValue: Instance)
		if objectValue:IsA("ObjectValue") then
			local componentModule = objectValue.Value :: ModuleScript
			local componentId = objectValue:GetAttribute("ComponentId") :: number
			componentModuleToId[componentModule] = componentId
			idToComponentModule[componentId] = componentModule
			local component = getComponent(componentId)
			component.setComponentId(componentId)
		end
	end
	local objectValuesFolder = ReplicatedStorage:WaitForChild(COMPONENT_MODULE_OBJECT_VALUES_FOLDER_NAME)
	for _, objectValue in objectValuesFolder:GetChildren() do
		onChildAdded(objectValue)
	end
	objectValuesFolder.ChildAdded:Connect(onChildAdded)

	-- No artificial delay before signalling ready: clientEntry only starts modules after
	-- game:IsLoaded(), by which point every component's ObjectValue (all registered at server
	-- boot) has replicated, so the id->module map built above is already complete.
	setReady:FireServer()

	replicateCurrentInstances.OnClientEvent:Connect(function(data)
		local b = data.b
		local tableResults = data.tableResults

		local offset = 0
		local count = buffer.readu32(b, offset)
		offset += 4

		local lateInitCallbacks: { () -> () } = {}

		for _ = 1, count do
			local record: ReplicationCodec.SnapshotRecord
			record, offset = ReplicationCodec.readSnapshot(b, offset)

			local t = tableResults[record.tablePosition] :: any?

			local component = getComponent(record.componentId)
			local replicatedState = component.deserializeReplicatedState(record.payload, t)
			xpcall(function()
				if component.validateReplication and not component.validateReplication(replicatedState) then return end

				local componentInstance = component.newClient(record.instanceId, replicatedState, record.componentId)

				if component.clientLateInit then
					table.insert(lateInitCallbacks, function()
						if component.clientInstances[record.instanceId] then component.clientLateInit(componentInstance) end
					end)
				end
			end, warn :: any)
		end

		for _, callback in lateInitCallbacks do
			xpcall(callback, warn :: any)
		end
	end)

	replicateComponentEvents.OnClientEvent:Connect(function(data)
		local b = data.b
		local tableResults = data.tableResults

		local offset = 0
		local count = buffer.readu32(b, offset)
		offset += 4

		-- Reuse one scratch record across the loop — this is the per-frame hot path, and each record
		-- is fully consumed before the next read, so there is zero per-record table allocation here.
		local record: ReplicationCodec.IncrementalRecord = {} :: any
		for _ = 1, count do
			record, offset = ReplicationCodec.readIncremental(b, offset, record)

			local component = getComponent(record.componentId)
			if record.tag == ReplicationCodec.DESTROY then
				component.cleanUpClient(record.instanceId)
			elseif record.tag == ReplicationCodec.CREATE then
				local t = tableResults[record.tablePosition] :: any?
				local replicatedState = component.deserializeReplicatedState(record.payload, t)
				xpcall(function()
					if component.validateReplication and not component.validateReplication(replicatedState) then return end

					local componentInstance = component.newClient(record.instanceId, replicatedState, record.componentId)
					local hasLateInitCallback = component.clientLateInit ~= nil
					if hasLateInitCallback then component.clientLateInit(componentInstance) end
				end, warn :: any)
			elseif record.tag == ReplicationCodec.EVENT then
				local t = tableResults[record.tablePosition] :: any?
				local eventHandler = component.events[record.eventIndex]
				local params = eventHandler.deserializeParams(record.payload, t)
				component.handleEventFromServer(record.instanceId, record.eventIndex, params)
			elseif record.tag == ReplicationCodec.SIGNAL then
				local t = tableResults[record.tablePosition] :: any?
				local eventHandler = component.events[record.eventIndex]
				local params = eventHandler.deserializeParams(record.payload, t)
				component.handleSignalFromServer(record.eventIndex, params)
			end
		end
	end)

	local staticInitClientCalled: { [number]: true } = {}

	RunService.Heartbeat:Connect(function(dt)
		for componentModule, componentId in componentModuleToId do
			if not staticInitClientCalled[componentId :: number] then
				staticInitClientCalled[componentId :: number] = true
				local component = getComponent(componentId :: number)
				if component.staticInitClient then component.staticInitClient() end
			end
		end

		for componentModule, componentId in componentModuleToId do
			local component = getComponent(componentId :: number)
			if component.heartbeatClient then
				debug.profilebegin(`{componentModule.Name}::heartbeatClient`)
				component.heartbeatClient(dt)
				debug.profileend()
			end
		end

		if next(eventsToSendClient) then
			replicateEventsFromClient:FireServer(eventsToSendClient)
			table.clear(eventsToSendClient)
		end
	end)
end

local nextComponentId = 1

function module.registerComponent(componentModule: ModuleScript)
	assert(RunService:IsServer(), "ComponentManager.registerComponent must be called on the server")
	assert(
		nextComponentId < MAX_COMPONENT_TYPES,
		`ComponentManager: too many component types registered (max {MAX_COMPONENT_TYPES - 1}); componentId is a u16 on the wire`
	)

	local objectValue = Instance.new("ObjectValue")
	objectValue.Value = componentModule
	objectValue:SetAttribute("ComponentId", nextComponentId)
	objectValue.Parent = componentModuleObjectValuesFolder

	local componentId = nextComponentId
	componentModuleToId[componentModule] = componentId
	idToComponentModule[componentId] = componentModule

	nextComponentId += 1

	return componentId
end

local nextReplicationOrder = 1
function module.queueDestroy(componentId, instanceId)
	assert(RunService:IsServer(), "ComponentManager.queueDestroy must be called on the server")

	local bigKey = cantorPairing(componentId, instanceId)
	local replicationOrder = bigKeyToReplicationOrder[bigKey]
	replicationOrderTree:delete(replicationOrder)
	replicationOrderToBigKey[replicationOrder] = nil
	bigKeyToComponentPair[bigKey] = nil
	bigKeyToReplicationOrder[bigKey] = nil

	if eventsToSendToClientQueueType == "create" then module.flushReplicationQueue() end

	eventsToSendToClientQueueType = "destroy"

	table.insert(eventsToSendServer, {
		eventKind = "destroy",
		componentId = componentId,
		instanceId = instanceId,
	})
end

function module.queueCreate(componentId, instanceId, replicatedState)
	assert(RunService:IsServer(), "ComponentManager.queueCreate must be called on the server")

	local bigKey = cantorPairing(componentId, instanceId)
	local replicationOrder = nextReplicationOrder
	nextReplicationOrder += 1
	replicationOrderTree:insert(replicationOrder)
	replicationOrderToBigKey[replicationOrder] = bigKey
	bigKeyToComponentPair[bigKey] = {
		componentId = componentId,
		instanceId = instanceId,
	}
	bigKeyToReplicationOrder[bigKey] = replicationOrder

	if eventsToSendToClientQueueType == "destroy" then module.flushReplicationQueue() end
	eventsToSendToClientQueueType = "create"

	table.insert(eventsToSendServer, {
		eventKind = "create",
		componentId = componentId,
		instanceId = instanceId,
		replicatedState = replicatedState,
	})
end

function module.queueEventServer(componentId, instanceId, eventIndex, params)
	assert(RunService:IsServer(), "ComponentManager.queueEventServer must be called on the server")

	table.insert(eventsToSendServer, {
		eventKind = "event",
		componentId = componentId,
		instanceId = instanceId,
		eventIndex = eventIndex,
		params = params,
	})
end

function module.queueSignalServer(componentId, eventIndex, params)
	assert(RunService:IsServer(), "ComponentManager.queueSignalServer must be called on the server")

	table.insert(eventsToSendServer, {
		eventKind = "signal",
		componentId = componentId,
		eventIndex = eventIndex,
		params = params,
	})
end

local destroying = 0
function module.raiseDestroying()
	assert(RunService:IsServer(), "ComponentManager.raiseDestroying must be called on the server")
	destroying += 1
end

function module.unraiseDestroying()
	assert(RunService:IsServer(), "ComponentManager.unraiseDestroying must be called on the server")
	assert(destroying > 0, "ComponentManager is not destroying")
	destroying -= 1
end

local creating = 0
function module.raiseCreating()
	assert(RunService:IsServer(), "ComponentManager.raiseCreating must be called on the server")
	creating += 1
end

function module.unraiseCreating()
	assert(RunService:IsServer(), "ComponentManager.unraiseCreating must be called on the server")
	assert(creating > 0, "ComponentManager is not creating")
	creating -= 1
end

function module.assertNotDestroying()
	assert(RunService:IsServer(), "ComponentManager.assertNotDestroying must be called on the server")
	assert(destroying == 0, "Cannot create while in the middle of destroying something.")
end

function module.assertNotCreating()
	assert(RunService:IsServer(), "ComponentManager.assertNotCreating must be called on the server")
	assert(creating == 0, "Cannot destroy while in the middle of creating something.")
end

function module.queueEventClient(componentId, instanceId, eventIndex, params)
	assert(RunService:IsClient(), "ComponentManager.queueEventClient must be called on the client")

	table.insert(eventsToSendClient, {
		eventKind = "event",
		componentId = componentId,
		instanceId = instanceId,
		eventIndex = eventIndex,
		params = params,
	})
end

function module.IsPlayerReady(player: Player)
	return player:GetAttribute("ComponentManagerReady")
end

return module
