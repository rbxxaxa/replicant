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

-- Fixed-name RemoteEvents in a dedicated folder. The server creates them on demand; clients
-- WaitForChild them. Stable names (unlike deriving them from the script path) never change when the
-- package version bumps, and need no RemoteUtil dependency — ReplicantManager frames its own buffers.
--
-- ⚠ RESOLVED LAZILY, AND THAT IS A HARD REQUIREMENT: REQUIRING THIS MODULE MUST NEVER YIELD.
-- The folder and the four remotes used to be looked up at module scope, where the client's
-- `WaitForChild` blocks until the server creates them. In a running game that is invisible, because
-- the server always gets there first. Everywhere else it hangs forever:
--
--   * Story/component browsers (UILabs and friends) require a component to render it, the component
--     requires this module, and edit mode has no server — so the require never returns and Studio
--     prints "Infinite yield possible on ReplicatedStorage:WaitForChild("ReplicantRemotes")".
--   * Any tool that loads game modules outside a running session hits the same wall.
--
-- Deferring the lookup to first USE costs one table check per call and moves the wait to
-- startClient(), which is where waiting for the server is the correct behaviour. The server side
-- also becomes lazy, which is safe: nothing reads a remote before startServer() connects to it.
local REMOTES_FOLDER_NAME = "ReplicantRemotes"

local remotesFolder: Instance? = nil
local function getRemotesFolder(): Instance
	local cached = remotesFolder
	if cached ~= nil then return cached end

	local resolved: Instance
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
		if existing then
			resolved = existing
		else
			local folder = Instance.new("Folder")
			folder.Name = REMOTES_FOLDER_NAME
			folder.Parent = ReplicatedStorage
			resolved = folder
		end
	else
		resolved = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
	end
	remotesFolder = resolved
	return resolved
end

-- Optional VALUE type, not just an optional lookup: Luau treats `{ [string]: RemoteEvent }` as
-- always-populated and rejects the nil comparison below outright.
local remoteCache: { [string]: RemoteEvent? } = {}
local function getRemote(name: string): RemoteEvent
	local cached = remoteCache[name]
	if cached ~= nil then return cached end

	local folder = getRemotesFolder()
	local resolved: RemoteEvent
	if RunService:IsServer() then
		local existing = folder:FindFirstChild(name)
		if existing then
			resolved = existing :: RemoteEvent
		else
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
			resolved = remote
		end
	else
		resolved = folder:WaitForChild(name) :: RemoteEvent
	end
	remoteCache[name] = resolved
	return resolved
end

local function fireForClients(remote: RemoteEvent, players: { Player }, data: any)
	for _, player in players do
		remote:FireClient(player, data)
	end
end

-- Accessors, not values. Each memoises through getRemote, so the cost after the first call is a
-- table lookup — but the FIRST call is what may yield, and it must happen inside start*(), never at
-- require time.
local function setReady(): RemoteEvent
	return getRemote("SetReady")
end
local function replicateCurrentInstances(): RemoteEvent
	return getRemote("ReplicateCurrentInstances")
end
local function replicateComponentEvents(): RemoteEvent
	return getRemote("ReplicateComponentEvents")
end
local function replicateEventsFromClient(): RemoteEvent
	return getRemote("ReplicateEventsFromClient")
end

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
		if player:GetAttribute("ReplicantManagerReady") then table.insert(playersReady, player) end
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

-- ── WORLDS ──────────────────────────────────────────────────────────────────────────────────────
--
-- A WORLD is a replication scope: a set of instances plus the set of players allowed to see them.
-- Without this, `replicatedState` fans out to EVERY ready client, so anything per-player is
-- quadratic in players and every game of that shape ends up hand-rolling a private RemoteEvent
-- beside the framework.
--
-- ⚠ WORLDS ARE A PURELY SERVER-SIDE CONCEPT, AND THAT IS THE WHOLE DESIGN. The client has no notion
-- of a world, no world id, and no new message type: subscribing sends it CREATEs and unsubscribing
-- sends it DESTROYs, which are messages it already handles. So every existing client component keeps
-- working untouched, and there is no second component system to maintain — the alternative (a nested
-- manager whose transport is a world component's own events) means a parallel factory and a second
-- id space for the same result.
--
-- ⚠ `DEFAULT_WORLD_ID` IS THE EXISTING BEHAVIOUR, PRESERVED EXACTLY. Anything created outside a
-- world scope lands there, and world 0's subscriber set is "every ready player". So a codebase that
-- never calls `createWorld` behaves precisely as it did before worlds existed.
local DEFAULT_WORLD_ID = 0

type World = {
	id: number,
	subscribers: { [Player]: true },
	destroyed: boolean,
}

local worlds: { [number]: World } = {
	[DEFAULT_WORLD_ID] = { id = DEFAULT_WORLD_ID, subscribers = {}, destroyed = false },
}
local nextWorldId = 1

-- bigKey -> worldId. Every replicated instance belongs to exactly one world.
local bigKeyToWorldId: { [number]: number } = {}

-- Creation scope. `Component.new()` does not take a world, so the world it lands in is ambient —
-- pushed around the construction. A STACK rather than a single value because construction nests:
-- a component's `new` routinely creates its children, and those must land in the same world.
--
-- ⚠ PER COROUTINE, NOT MODULE-WIDE. A single shared stack is wrong the moment anything yields: if
-- `withWorld(w, fn)` yields inside `fn` — a `task.wait`, a DataStore call, anything — the scheduler
-- runs other threads while `w` is still pushed, and every replicant THEY create silently lands in
-- somebody else's private world. `pcall` does not help; it propagates yields. Keying by coroutine
-- makes the scope follow the thread that pushed it, which is the only correct scoping.
--
-- WEAK KEYS, because a thread that dies inside `withWorld` and never resumes — `task.cancel`, a
-- `WaitForChild` that never fires — would otherwise strand its stack entry here forever. The normal
-- path removes entries explicitly; the weak table is the backstop for threads that never get there.
local worldScopeByThread: { [thread]: { number } } = setmetatable({}, { __mode = "k" }) :: any

local function currentWorldId(): number
	local stack = worldScopeByThread[coroutine.running()]
	if stack == nil then return DEFAULT_WORLD_ID end

	local depth = #stack
	if depth == 0 then return DEFAULT_WORLD_ID end

	return stack[depth]
end

local function isPlayerReady(player: Player): boolean
	return player:GetAttribute("ReplicantManagerReady") == true
end

-- Who may see this world right now. World 0 is every ready player; a child world is its explicit
-- subscriber set, still filtered by readiness — a player mid-handshake has no client-side component
-- map yet, so sending them a CREATE would reference a componentId they cannot resolve.
local function subscribersOf(worldId: number): { Player }
	local result: { Player } = {}

	if worldId == DEFAULT_WORLD_ID then
		for _, player in Players:GetPlayers() do
			if isPlayerReady(player) then table.insert(result, player) end
		end

		return result
	end

	local world = worlds[worldId]
	if world == nil then return result end

	for player in world.subscribers do
		-- A player who left is dropped lazily here as well as eagerly in PlayerRemoving, because a
		-- disconnect can land between the two and `FireClient` on a stale Player is an error.
		if player.Parent ~= nil and isPlayerReady(player) then table.insert(result, player) end
	end

	return result
end

-- An event with its payload ALREADY SERIALISED, plus the world it belongs to.
--
-- ⚠ SERIALISE ONCE, ASSEMBLE MANY. A frame's events may go to several different audiences, and
-- `serializeReplicatedState` / `serializeParams` are the expensive part. Preparing up front means
-- grouping costs only buffer assembly — writing the same bytes into a second buffer — never a second
-- serialisation. `payloadTable` is kept out of the record because its INDEX differs per audience:
-- each buffer carries only the side-channel tables for the events it actually contains.
type PreparedEvent = {
	tag: number,
	componentId: number,
	instanceId: number?,
	eventIndex: number?,
	payload: buffer?,
	payloadLen: number,
	payloadTable: any,
	instanceHandles: any?,
	worldId: number,
}

-- The world an event belongs to. Instance-scoped events (create/destroy/event) take their
-- instance's world; a `signal` has no instance and is component-wide, so it stays global.
--
-- ⚠ SIGNALS ARE NOT WORLD-SCOPED, deliberately. A signal is a broadcast about a component TYPE, not
-- about one object, so there is no instance to derive a scope from. If you need a scoped broadcast,
-- fire an event on an instance that lives in the world.
local function worldIdForEvent(event: any): number
	if event.eventKind == "signal" then return DEFAULT_WORLD_ID end

	-- ⚠ THE STAMP WINS. All three instance-scoped kinds record their world at enqueue time, and an
	-- instance never migrates worlds, so stamp and map can never disagree while both exist — but the
	-- MAP is cleared by `queueDestroy` before the flush runs, so consulting it first would resolve a
	-- destroyed instance's events to world 0 and broadcast them. The map remains as a fallback only
	-- for records predating the stamp.
	local bigKey = cantorPairing(event.componentId, event.instanceId)
	return event.worldId or bigKeyToWorldId[bigKey] or DEFAULT_WORLD_ID
end

-- Serialises one queued event. Returns nil for an unrecognised eventKind, which the caller skips —
-- matching the old inline `else continue`.
local function prepareEvent(event: any): PreparedEvent?
	local worldId = worldIdForEvent(event)

	if event.eventKind == "destroy" then
		return {
			tag = ReplicationCodec.DESTROY,
			componentId = event.componentId,
			instanceId = event.instanceId,
			payload = nil,
			payloadLen = 0,
			payloadTable = nil,
			worldId = worldId,
		}
	elseif event.eventKind == "create" then
		local component = getComponent(event.componentId)
		local payload, payloadTable, instanceHandles = component.serializeReplicatedState(event.replicatedState, event.instanceHandles)
		local payloadLen = if payload then buffer.len(payload) else 0
		assert(payloadLen < 2 ^ 16, "Buffer is too large to send")

		return {
			tag = ReplicationCodec.CREATE,
			componentId = event.componentId,
			instanceId = event.instanceId,
			payload = payload,
			payloadLen = payloadLen,
			payloadTable = payloadTable,
			instanceHandles = instanceHandles,
			worldId = worldId,
		}
	elseif event.eventKind == "event" or event.eventKind == "signal" then
		local component = getComponent(event.componentId)
		local eventHandler = component.events[event.eventIndex]
		local payload, payloadTable = eventHandler.serializeParams(event.params)
		local payloadLen = if payload then buffer.len(payload) else 0
		assert(payloadLen < 2 ^ 16, "Buffer is too large to send")

		return {
			tag = if event.eventKind == "event" then ReplicationCodec.EVENT else ReplicationCodec.SIGNAL,
			componentId = event.componentId,
			-- A SIGNAL has no instance; the codec does not write one for that tag.
			instanceId = event.instanceId,
			eventIndex = event.eventIndex,
			payload = payload,
			payloadLen = payloadLen,
			payloadTable = payloadTable,
			worldId = worldId,
		}
	end

	return nil
end

-- Assembles ONE buffer from the prepared events this audience can see, and sends it to them.
--
-- `visibleWorlds` nil means "everything in `prepared`" — used by the subscribe/unsubscribe bursts,
-- which are already scoped to a single world by their caller.
function module._sendPreparedToPlayers(playersReady: { Player }, prepared: { PreparedEvent }, visibleWorlds: { [number]: boolean }?)
	if next(playersReady) == nil then return end

	local tableResults: { any } = {}
	local instanceHandlesResults: { any } = {}
	local records: { ReplicationCodec.IncrementalRecord } = {}
	local totalBufferSize = 4

	for _, entry in prepared do
		if visibleWorlds ~= nil and not visibleWorlds[entry.worldId] then continue end

		-- ⚠ `tablePosition` IS PER-BUFFER. It indexes this audience's `tableResults`, so it must be
		-- recomputed here rather than carried on the prepared event — a position captured against a
		-- different audience's table would decode to the wrong side-channel value on the client.
		local tablePosition = 0
		if entry.payloadTable ~= nil then
			table.insert(tableResults, entry.payloadTable)
			tablePosition = #tableResults
		end
		local handlesPosition = 0
		if entry.instanceHandles ~= nil and next(entry.instanceHandles) ~= nil then
			table.insert(instanceHandlesResults, entry.instanceHandles)
			handlesPosition = #instanceHandlesResults
		end
		assert(tablePosition < 2 ^ 16 and handlesPosition < 2 ^ 16, "Too many side-channel tables in a replication packet")

		local record: ReplicationCodec.IncrementalRecord = {
			tag = entry.tag,
			componentId = entry.componentId,
			instanceId = entry.instanceId,
			eventIndex = entry.eventIndex,
			payload = entry.payload,
			payloadLen = entry.payloadLen,
			tablePosition = tablePosition,
			handlesPosition = handlesPosition,
		}

		totalBufferSize += ReplicationCodec.sizeIncremental(record)
		table.insert(records, record)
	end

	if #records == 0 then return end

	local b = buffer.create(totalBufferSize)
	local offset = 0
	buffer.writeu32(b, offset, #records)
	offset += 4

	for _, record in records do
		offset = ReplicationCodec.writeIncremental(b, offset, record)
	end

	fireForClients(replicateComponentEvents(), playersReady, {
		b = b,
		tableResults = tableResults,
		instanceHandlesResults = instanceHandlesResults,
	})
end

-- Convenience wrapper for the subscribe/unsubscribe bursts, which hand over raw events rather than
-- prepared ones.
function module._flushEventsToPlayers(playersReady: { Player }, events: { any })
	local prepared: { PreparedEvent } = {}
	for _, event in events do
		local entry = prepareEvent(event)
		if entry ~= nil then table.insert(prepared, entry) end
	end

	module._sendPreparedToPlayers(playersReady, prepared, nil)
end

function module.flushReplicationQueue()
	if next(eventsToSendServer) == nil then return end

	-- ⚠ NOBODY READY, NOBODY PAYS. The old flush wrapped ALL serialization in "are any players
	-- ready"; the audience rewrite briefly lost that, which meant an empty or still-handshaking
	-- server fully serialized every frame's queue just to throw it away — and newly invoked consumer
	-- serializer callbacks (including their asserts) in a state where they had never run before.
	-- Restore the gate before the prepare pass, not after.
	local anyReady = false
	for _, player in Players:GetPlayers() do
		if isPlayerReady(player) then
			anyReady = true
			break
		end
	end
	if not anyReady then
		table.clear(eventsToSendServer)
		eventsToSendToClientQueueType = nil
		return
	end

	-- ⚠ ONE BUFFER PER AUDIENCE, NOT PER WORLD AND NOT PER RUN. Two constraints have to hold at once
	-- and only this shape satisfies both:
	--
	--   ORDERING. A player subscribed to several worlds must observe events in the order the server
	--   caused them. Grouping by world emits all of world 0 then all of world 1, so A(w0) B(w1)
	--   C(w0) arrives as A, C, B — an invariant that existed before worlds and would have been
	--   silently removed.
	--
	--   PACKING. Buffers are COMPRESSED on the wire, so fragmenting one frame into several small
	--   buffers costs real bandwidth. Splitting into runs at every world change preserves order but
	--   is the worst possible answer for compression — it maximises fragmentation exactly when a
	--   frame is busiest.
	--
	-- So group by AUDIENCE: players who can see the same set of worlds receive an identical stream,
	-- so they share ONE buffer holding every event they are entitled to, in queue order. Ordering is
	-- trivially preserved (it is a single ordered buffer) and packing is optimal (a player's whole
	-- frame is one buffer, which is the most the compressor can be given).
	--
	-- ⚠ THIS IS ALSO WHY WORLD-0-ONLY CONSUMERS ARE UNAFFECTED. If nothing calls `createWorld` every
	-- player has the same audience signature, collapses into one group, and gets exactly the one
	-- buffer the old code built.
	--
	-- Payloads are serialised ONCE up front and then referenced by every group that includes them, so
	-- grouping costs buffer assembly, never re-serialisation.
	local prepared: { PreparedEvent } = {}
	local worldsPresent: { number } = {}
	local worldSeen: { [number]: boolean } = {}

	for _, event in eventsToSendServer do
		local entry = prepareEvent(event)
		if entry == nil then continue end

		table.insert(prepared, entry)
		if not worldSeen[entry.worldId] then
			worldSeen[entry.worldId] = true
			table.insert(worldsPresent, entry.worldId)
		end
	end

	if #prepared == 0 then
		table.clear(eventsToSendServer)
		eventsToSendToClientQueueType = nil
		return
	end

	-- Audience signature: one character per world involved in THIS frame, so the signature space is
	-- bounded by what actually happened rather than by how many worlds exist.
	local groups: { [string]: { players: { Player }, sees: { [number]: boolean } } } = {}

	for _, player in Players:GetPlayers() do
		if not isPlayerReady(player) then continue end

		local sees: { [number]: boolean } = {}
		local signature = table.create(#worldsPresent)
		local anyVisible = false

		for index, worldId in worldsPresent do
			local visible = false
			if worldId == DEFAULT_WORLD_ID then
				visible = true
			else
				local world = worlds[worldId]
				visible = world ~= nil and world.subscribers[player] == true
			end

			sees[worldId] = visible
			signature[index] = if visible then "1" else "0"
			anyVisible = anyVisible or visible
		end

		-- A player who can see nothing this frame gets no packet at all.
		if not anyVisible then continue end

		local key = table.concat(signature)
		local group = groups[key]
		if group == nil then
			group = { players = {}, sees = sees }
			groups[key] = group
		end
		table.insert(group.players, player)
	end

	for _, group in groups do
		module._sendPreparedToPlayers(group.players, prepared, group.sees)
	end

	table.clear(eventsToSendServer)
	eventsToSendToClientQueueType = nil
end

-- Walks every live instance in ONE world, in replication order.
--
-- ⚠ REPLICATION ORDER IS LOAD-BEARING. The red-black tree exists so instances arrive in creation
-- order, because a component's `newClient` may reference an earlier one. Every world-scoped bulk
-- operation goes through here so none of them can accidentally reorder.
local function forEachInstanceInWorlds(visibleWorlds: { [number]: boolean }, visit: (componentId: number, instanceId: number) -> ())
	replicationOrderTree:inOrderTraversal(function(replicationOrder)
		local bigKey = replicationOrderToBigKey[replicationOrder]
		if bigKey == nil then return end
		if not visibleWorlds[bigKeyToWorldId[bigKey] or DEFAULT_WORLD_ID] then return end

		local pair = bigKeyToComponentPair[bigKey]
		if pair == nil then return end

		visit(pair.componentId, pair.instanceId)
	end)
end

local function forEachInstanceInWorld(worldId: number, visit: (componentId: number, instanceId: number) -> ())
	forEachInstanceInWorlds({ [worldId] = true }, visit)
end

-- Every world a player should currently see: world 0 plus anything they were subscribed to. Used to
-- build the join snapshot, so a subscription made BEFORE the player was ready is delivered rather
-- than silently lost.
local function visibleWorldsFor(player: Player): { [number]: boolean }
	local visible: { [number]: boolean } = { [DEFAULT_WORLD_ID] = true }
	for worldId, world in worlds do
		if world.subscribers[player] then visible[worldId] = true end
	end

	return visible
end

-- Builds a full CREATE snapshot of every live instance in ONE world, in replication order.
--
-- Shared by the two moments a client needs a bulk catch-up: finishing the join handshake (world 0)
-- and being subscribed to a world mid-session. They were one code path before worlds existed, and
-- keeping them one is what guarantees a subscriber sees exactly what a joiner would.
--
-- ⚠ REPLICATION ORDER IS PRESERVED. The red-black tree exists so instances arrive in creation order,
-- because a component's `newClient` may reference an earlier one. Filtering by world must not
-- reorder — hence an in-order traversal with a predicate, not a gather-then-sort.
local function buildSnapshotForWorlds(visibleWorlds: { [number]: boolean }): (buffer, { any }, { any })
	local tableResults: { any } = {}
	local instanceHandlesResults: { any } = {}
	local records: { ReplicationCodec.SnapshotRecord } = {}

	-- ONE traversal across all visible worlds, so instances arrive in global creation order even when
	-- the player can see several. Building per world and concatenating would interleave them wrongly
	-- and could hand the client a child before its parent.
	local pairSequence = {}
	forEachInstanceInWorlds(visibleWorlds, function(componentId: number, instanceId: number)
		table.insert(pairSequence, { componentId = componentId, instanceId = instanceId })
	end)

	local totalBufferSize = 4
	for _, pair in pairSequence do
		local component = getComponent(pair.componentId)
		local replicatedState, handles = component.getDataForReplication(pair.instanceId)

		local payloadBuffer, payloadTable, instanceHandles = component.serializeReplicatedState(replicatedState, handles)
		local payloadLen = if payloadBuffer then buffer.len(payloadBuffer) else 0
		assert(payloadLen < 2 ^ 16, "Buffer is too large to send")

		local tablePosition = 0
		if payloadTable ~= nil then
			table.insert(tableResults, payloadTable)
			tablePosition = #tableResults
		end
		local handlesPosition = 0
		if instanceHandles ~= nil and next(instanceHandles) ~= nil then
			table.insert(instanceHandlesResults, instanceHandles)
			handlesPosition = #instanceHandlesResults
		end
		assert(tablePosition < 2 ^ 16 and handlesPosition < 2 ^ 16, "Too many side-channel tables in a replication snapshot")

		local record: ReplicationCodec.SnapshotRecord = {
			componentId = pair.componentId,
			instanceId = pair.instanceId,
			payload = payloadBuffer,
			payloadLen = payloadLen,
			tablePosition = tablePosition,
			handlesPosition = handlesPosition,
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

	return b, tableResults, instanceHandlesResults
end

function module.startServer()
	-- ⚠ CREATE ALL FOUR REMOTES NOW, not when each is first used. Creation never yields on the
	-- server, but a client's `getRemote` is a WaitForChild — so any remote the server has not made
	-- yet is a remote a joining client BLOCKS on. Two of these are only touched when the server
	-- first FIRES them, which for `ReplicateCurrentInstances` means "when something first needs
	-- replicating": the client would sit in startClient waiting on a RemoteEvent that did not exist
	-- yet, log an infinite-yield warning at five seconds, and hold up the rest of client startup
	-- behind it. Listing them here is what makes the client's waits resolve instantly.
	setReady()
	replicateCurrentInstances()
	replicateComponentEvents()
	replicateEventsFromClient()

	local playersWaitingToBeReady: { Player } = {}

	setReady().OnServerEvent:Connect(function(player)
		table.insert(playersWaitingToBeReady, player)
	end)

	-- A departed player must not linger in any subscriber set. Two reasons, and the second is the one
	-- that bites: the set keeps a strong reference to a destroyed Player, and — because the set is
	-- also the input ACL — a rejoining player object could otherwise inherit a stale subscription.
	Players.PlayerRemoving:Connect(function(player: Player)
		for _, world in worlds do
			world.subscribers[player] = nil
		end
	end)

	replicateEventsFromClient().OnServerEvent:Connect(function(player, events)
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
			-- ⚠ WORLD 0 PLUS ANY WORLD THIS PLAYER WAS ALREADY SUBSCRIBED TO. Subscribing a player
			-- before they finish the handshake is legitimate and normal — a PlayerAdded handler that
			-- builds their board and subscribes them runs many frames before the client sends
			-- SetReady — so the join snapshot has to carry those worlds or they are never delivered
			-- at all.
			--
			-- Per player, because their subscriptions differ. Grouped by identical world sets so the
			-- common case (everyone sees only world 0) still builds and sends exactly one buffer.
			local snapshotGroups: { [string]: { players: { Player }, visible: { [number]: boolean } } } = {}

			for _, player in playersWaitingToBeReady do
				local visible = visibleWorldsFor(player)

				local ids: { number } = {}
				for worldId in visible do
					table.insert(ids, worldId)
				end
				table.sort(ids)
				local key = table.concat(ids, ",")

				local group = snapshotGroups[key]
				if group == nil then
					group = { players = {}, visible = visible }
					snapshotGroups[key] = group
				end
				table.insert(group.players, player)
			end

			for _, group in snapshotGroups do
				local b, tableResults, instanceHandlesResults = buildSnapshotForWorlds(group.visible)
				fireForClients(replicateCurrentInstances(), group.players, {
					b = b,
					tableResults = tableResults,
					instanceHandlesResults = instanceHandlesResults,
				})
			end

			for _, player in playersWaitingToBeReady do
				player:SetAttribute("ReplicantManagerReady", true)
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

					-- ⚠ THE OWNERSHIP CHECK, DONE ONCE, BY THE FRAMEWORK.
					--
					-- The client chooses the instanceId it names, and this dispatcher used to trust it
					-- — so every `handleEventServer` had to re-derive "is this player allowed to touch
					-- this object", and a single forgotten guard let any client drive any instance.
					--
					-- Worlds make it structural: an instance lives in exactly one world, and a player
					-- may only reach instances in worlds they are subscribed to. World 0 stays open to
					-- every ready player, which is precisely the old behaviour for shared objects, so
					-- nothing that worked before stops working.
					--
					-- ⚠ THIS IS NOT A SUBSTITUTE FOR VALIDATING PARAMETERS. It answers "may this
					-- player talk to this object at all", never "is this a legal thing to ask".
					local bigKey = cantorPairing(event.componentId, event.instanceId)
					local instanceWorldId = bigKeyToWorldId[bigKey]

					-- ⚠ NO MAPPING MEANS NO INSTANCE, SO DROP IT — do not fall back to world 0.
					-- `queueCreate` stamps every replicated instance and `queueDestroy` clears it, so a
					-- missing entry is either a destroyed instance (the client raced the destroy) or an
					-- id that never existed (a forged one). Defaulting to world 0 would skip the ACL for
					-- exactly the ids that deserve it most, and route them into the not-found path,
					-- which in Studio ERRORS — handing any client a way to spam the server's log.
					if instanceWorldId == nil then return end

					if instanceWorldId ~= DEFAULT_WORLD_ID then
						local world = worlds[instanceWorldId]
						if world == nil or not world.subscribers[event.player] then return end
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
	setReady():FireServer()

	replicateCurrentInstances().OnClientEvent:Connect(function(data)
		local b = data.b
		local tableResults = data.tableResults
		local instanceHandlesResults = data.instanceHandlesResults or {}

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

				local componentInstance =
					component.newClient(record.instanceId, replicatedState, record.componentId, instanceHandlesResults[record.handlesPosition])

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

	replicateComponentEvents().OnClientEvent:Connect(function(data)
		local b = data.b
		local tableResults = data.tableResults
		local instanceHandlesResults = data.instanceHandlesResults or {}

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

					local componentInstance =
						component.newClient(record.instanceId, replicatedState, record.componentId, instanceHandlesResults[record.handlesPosition])
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
			replicateEventsFromClient():FireServer(eventsToSendClient)
			table.clear(eventsToSendClient)
		end
	end)
end

local nextComponentId = 1

function module.registerComponent(componentModule: ModuleScript)
	assert(RunService:IsServer(), "ReplicantManager.registerComponent must be called on the server")
	assert(
		nextComponentId < MAX_COMPONENT_TYPES,
		`ReplicantManager: too many component types registered (max {MAX_COMPONENT_TYPES - 1}); componentId is a u16 on the wire`
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
	assert(RunService:IsServer(), "ReplicantManager.queueDestroy must be called on the server")

	local bigKey = cantorPairing(componentId, instanceId)
	local replicationOrder = bigKeyToReplicationOrder[bigKey]
	replicationOrderTree:delete(replicationOrder)
	replicationOrderToBigKey[replicationOrder] = nil
	bigKeyToComponentPair[bigKey] = nil
	bigKeyToReplicationOrder[bigKey] = nil

	-- ⚠ CAPTURED BEFORE THE MAP ENTRY IS CLEARED, and carried on the event. The destroy still has to
	-- reach exactly the players who were told this instance exists, and by flush time its world
	-- mapping is gone — without the stamp the destroy would fall back to world 0 and either leak to
	-- everyone or, worse, never reach the world's actual subscribers, leaving a ghost on their screen
	-- forever.
	local worldId = bigKeyToWorldId[bigKey] or DEFAULT_WORLD_ID
	bigKeyToWorldId[bigKey] = nil

	if eventsToSendToClientQueueType == "create" then module.flushReplicationQueue() end

	eventsToSendToClientQueueType = "destroy"

	table.insert(eventsToSendServer, {
		eventKind = "destroy",
		componentId = componentId,
		instanceId = instanceId,
		worldId = worldId,
	})
end

function module.queueCreate(componentId, instanceId, replicatedState, instanceHandles)
	assert(RunService:IsServer(), "ReplicantManager.queueCreate must be called on the server")

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
	-- The world is AMBIENT at construction — see `worldScopeStack`. Stamped once, here, and never
	-- changed: an instance does not migrate between worlds, because a client that has been told an
	-- object exists has no message meaning "it is now somebody else's".
	local worldId = currentWorldId()
	bigKeyToWorldId[bigKey] = worldId

	if eventsToSendToClientQueueType == "destroy" then module.flushReplicationQueue() end
	eventsToSendToClientQueueType = "create"

	table.insert(eventsToSendServer, {
		eventKind = "create",
		componentId = componentId,
		instanceId = instanceId,
		replicatedState = replicatedState,
		instanceHandles = instanceHandles,
		worldId = worldId,
	})
end

function module.queueEventServer(componentId, instanceId, eventIndex, params)
	assert(RunService:IsServer(), "ReplicantManager.queueEventServer must be called on the server")

	-- ⚠ STAMPED AT ENQUEUE, LIKE create AND destroy. Without this the world is resolved at FLUSH time
	-- from `bigKeyToWorldId` — and if the instance is destroyed later in the same frame, `queueDestroy`
	-- has already cleared that entry, so the event falls back to world 0 and its payload is broadcast
	-- to EVERY ready player. "Fire a death event, then destroy the instance" is the ordinary shape of
	-- that bug, not a contrived one.
	--
	-- Read from the map rather than `currentWorldId()`: events are fired from gameplay code outside
	-- any `withWorld` scope, so the ambient stack is empty and would wrongly yield 0.
	local bigKey = cantorPairing(componentId, instanceId)

	table.insert(eventsToSendServer, {
		eventKind = "event",
		componentId = componentId,
		instanceId = instanceId,
		eventIndex = eventIndex,
		params = params,
		worldId = bigKeyToWorldId[bigKey] or DEFAULT_WORLD_ID,
	})
end

function module.queueSignalServer(componentId, eventIndex, params)
	assert(RunService:IsServer(), "ReplicantManager.queueSignalServer must be called on the server")

	table.insert(eventsToSendServer, {
		eventKind = "signal",
		componentId = componentId,
		eventIndex = eventIndex,
		params = params,
	})
end

local destroying = 0
function module.raiseDestroying()
	assert(RunService:IsServer(), "ReplicantManager.raiseDestroying must be called on the server")
	destroying += 1
end

function module.unraiseDestroying()
	assert(RunService:IsServer(), "ReplicantManager.unraiseDestroying must be called on the server")
	assert(destroying > 0, "ReplicantManager is not destroying")
	destroying -= 1
end

local creating = 0
function module.raiseCreating()
	assert(RunService:IsServer(), "ReplicantManager.raiseCreating must be called on the server")
	creating += 1
end

function module.unraiseCreating()
	assert(RunService:IsServer(), "ReplicantManager.unraiseCreating must be called on the server")
	assert(creating > 0, "ReplicantManager is not creating")
	creating -= 1
end

function module.assertNotDestroying()
	assert(RunService:IsServer(), "ReplicantManager.assertNotDestroying must be called on the server")
	assert(destroying == 0, "Cannot create while in the middle of destroying something.")
end

function module.assertNotCreating()
	assert(RunService:IsServer(), "ReplicantManager.assertNotCreating must be called on the server")
	assert(creating == 0, "Cannot destroy while in the middle of creating something.")
end

function module.queueEventClient(componentId, instanceId, eventIndex, params)
	assert(RunService:IsClient(), "ReplicantManager.queueEventClient must be called on the client")

	table.insert(eventsToSendClient, {
		eventKind = "event",
		componentId = componentId,
		instanceId = instanceId,
		eventIndex = eventIndex,
		params = params,
	})
end

-- ── WORLDS: PUBLIC API ──────────────────────────────────────────────────────────────────────────

module.DEFAULT_WORLD_ID = DEFAULT_WORLD_ID

-- A fresh, empty replication scope. Nobody sees it until somebody is subscribed.
function module.createWorld(): number
	assert(RunService:IsServer(), "ReplicantManager.createWorld must be called on the server")

	local id = nextWorldId
	nextWorldId += 1
	worlds[id] = { id = id, subscribers = {}, destroyed = false }

	return id
end

-- Runs `fn` with `worldId` as the ambient creation scope, so every replicant constructed inside it
-- lands in that world. Restores the previous scope even if `fn` throws — a leaked scope would send
-- every later instance in the whole game into somebody's private world.
--
-- ⚠ TWO CONSEQUENCES OF PER-THREAD SCOPING, deliberate and worth knowing:
--
--   * `task.spawn` / `task.defer` inside `fn` runs on a NEW thread, which does NOT inherit the
--     scope — anything it creates lands in world 0, the safe default. A caller who spawns on
--     purpose must capture `getCurrentWorldId()` and re-enter `withWorld` inside the new thread.
--
--   * `fn` should be SYNCHRONOUS. Yielding inside it no longer poisons other threads' scope (that
--     is the point of per-thread stacks), but the Heartbeat can flush mid-yield and ship a
--     half-constructed world to its subscribers. Build the world, then yield.
function module.withWorld<T>(worldId: number, fn: () -> T): T
	assert(RunService:IsServer(), "ReplicantManager.withWorld must be called on the server")
	assert(worlds[worldId] ~= nil, `ReplicantManager: world {worldId} does not exist`)

	local thread = coroutine.running()
	local stack = worldScopeByThread[thread]
	if stack == nil then
		stack = {}
		worldScopeByThread[thread] = stack
	end

	table.insert(stack, worldId)
	local depth = #stack

	local ok, result = pcall(fn)

	-- Position-checked, not a bare pop: within one thread push/pop is LIFO by construction, so a
	-- mismatch here means scope bookkeeping is corrupted and every later create is suspect — the
	-- kind of thing to fail loudly on rather than quietly mis-scope.
	assert(#stack == depth and stack[depth] == worldId, "ReplicantManager: world scope stack corrupted")
	table.remove(stack)

	-- Drop the entry when the thread leaves its last scope, so a long-lived server never accumulates
	-- one table per coroutine that ever created a replicant.
	if #stack == 0 then worldScopeByThread[thread] = nil end

	if not ok then error(result, 2) end

	return result :: any
end

function module.getCurrentWorldId(): number
	return currentWorldId()
end

-- Subscribing sends the player a full snapshot of the world, as CREATEs. The client has no idea a
-- world was involved — it just sees objects appear, exactly as it does at join.
function module.subscribeToWorld(player: Player, worldId: number)
	assert(RunService:IsServer(), "ReplicantManager.subscribeToWorld must be called on the server")
	assert(worldId ~= DEFAULT_WORLD_ID, "ReplicantManager: every ready player is implicitly in world 0")

	local world = worlds[worldId]
	assert(world ~= nil, `ReplicantManager: world {worldId} does not exist`)
	if world.subscribers[player] then return end

	-- ⚠ FLUSH BEFORE JOINING THE SUBSCRIBER SET, NOT AFTER — THE ORDER IS THE WHOLE BUG.
	--
	-- Recipients are resolved at flush time from the live subscriber set. Adding the player first
	-- means any world-`w` CREATE still queued this frame is routed to them by the flush, AND then
	-- sent again by the burst below (the flush clears only the event queue; the instance registry the
	-- burst reads is untouched). The client is not idempotent about CREATE — `newClient` runs twice
	-- and the first object is orphaned with its parts and connections, never to receive
	-- `cleanUpClient`. Flushing first drains those creates to the players who were already
	-- subscribed, leaving the burst as the single delivery to this one.
	module.flushReplicationQueue()

	world.subscribers[player] = true

	-- ⚠ A NOT-YET-READY PLAYER IS SUBSCRIBED BUT NOT SENT ANYTHING HERE, and the JOIN SNAPSHOT is
	-- what delivers this world to them — see the ready block in `startServer`, which builds from
	-- world 0 plus every world they are already subscribed to.
	--
	-- Sending now would be wrong: they have not mapped the component ObjectValues yet, so a CREATE
	-- would name a componentId they cannot resolve. An earlier version returned here believing the
	-- contents would arrive "from the same code path once ready" — no such path existed, so the
	-- player became a permanent subscriber to a world that was never delivered, and every later event
	-- for it hit a client with no matching instance.
	if not isPlayerReady(player) then return end

	-- ⚠ SENT AS CREATE EVENTS ON THE INCREMENTAL REMOTE, not as a snapshot on the join remote.
	--
	-- Roblox guarantees ordering only WITHIN one RemoteEvent. A snapshot delivered on
	-- `ReplicateCurrentInstances` races every subsequent event on `ReplicateComponentEvents`, so a
	-- client could receive an event for an instance whose CREATE has not landed and error with
	-- "instance not found". Emitting the burst as ordinary CREATEs on the same remote as everything
	-- else makes that unrepresentable. It is also symmetric with unsubscribe, which sends DESTROYs.
	--
	-- The join path still uses the real snapshot remote: it fires BEFORE the player is marked ready,
	-- and no event can target them until they are, so it has no race to lose.
	local creates: { any } = {}
	forEachInstanceInWorld(worldId, function(componentId: number, instanceId: number)
		local component = getComponent(componentId)
		local replicatedState, instanceHandles = component.getDataForReplication(instanceId)
		table.insert(creates, {
			eventKind = "create",
			componentId = componentId,
			instanceId = instanceId,
			replicatedState = replicatedState,
			instanceHandles = instanceHandles,
		})
	end)

	module._flushEventsToPlayers({ player }, creates)
end

-- Unsubscribing tears the world down on that client by sending a DESTROY per instance — again, a
-- message the client already handles, so there is no world-aware client code anywhere.
function module.unsubscribeFromWorld(player: Player, worldId: number)
	assert(RunService:IsServer(), "ReplicantManager.unsubscribeFromWorld must be called on the server")

	local world = worlds[worldId]
	if world == nil or not world.subscribers[player] then return end

	-- ⚠ FLUSH BEFORE DROPPING THE SUBSCRIPTION, not after. Pending events for this world are routed
	-- by the subscriber set at flush time, so removing the player first would silently discard
	-- updates they are still entitled to — including, in the worst case, the DESTROY of an object
	-- that then lingers on their screen.
	module.flushReplicationQueue()
	world.subscribers[player] = nil

	if not isPlayerReady(player) then return end

	local destroys: { any } = {}
	forEachInstanceInWorld(worldId, function(componentId: number, instanceId: number)
		table.insert(destroys, {
			eventKind = "destroy",
			componentId = componentId,
			instanceId = instanceId,
		})
	end)

	module._flushEventsToPlayers({ player }, destroys)
end

function module.getWorldSubscribers(worldId: number): { Player }
	return subscribersOf(worldId)
end

function module.isSubscribedToWorld(player: Player, worldId: number): boolean
	if worldId == DEFAULT_WORLD_ID then return isPlayerReady(player) end

	local world = worlds[worldId]
	return world ~= nil and world.subscribers[player] == true
end

-- Drops the scope itself. Does NOT destroy the instances inside it — their owner does that, and
-- destroying them here would double-destroy from the caller's point of view.
function module.destroyWorld(worldId: number)
	assert(RunService:IsServer(), "ReplicantManager.destroyWorld must be called on the server")
	assert(worldId ~= DEFAULT_WORLD_ID, "ReplicantManager: the default world cannot be destroyed")

	local world = worlds[worldId]
	if world == nil then return end

	for player in world.subscribers do
		module.unsubscribeFromWorld(player, worldId)
	end

	world.destroyed = true
	worlds[worldId] = nil
end

function module.IsPlayerReady(player: Player)
	return player:GetAttribute("ReplicantManagerReady")
end

return module
