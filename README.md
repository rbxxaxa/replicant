# replicant

`rbxxaxa/replicant` — a **server-authoritative replicated component framework** for Roblox. Components
are OOP objects whose state automatically replicates server → client over a compact buffer-packed
protocol. Extracted from the studio-incubator-prototype / Ship Wars codebases (a shipped 1000+ CCU
game).

```toml
[dependencies]
Replicant = "rbxxaxa/replicant@0.4.0"
```

## The model

Each component has three state buckets and an optional instance binding table:

- **`replicatedState`** — shared state replicated to clients: primitives, tables, and Roblox values.
  Streamable instance references belong in `instanceHandles`, never this bucket.
- **`serverState`** — server-only (Signals, Troves, transient data). Never replicates.
- **`clientState`** — client-only.
- **`instanceHandles`** — an immutable, shared string-to-`InstanceHandle` mapping. The handle exists
  on both peers even when its target has not streamed to the client. Two-return constructors receive
  an empty mapping automatically.

`replicatedState` may **only** be mutated inside the `modifyReplicatedState` callback of a server-only
event; the same callback replays on the client so both sides stay consistent. Newly-joined clients
receive a full snapshot; connected clients receive incremental events — both framed by the pure
`ReplicationCodec`.

```lua
local Replicant = require(Packages.Replicant)

-- boot
Replicant.ReplicantManager.startServer() -- on the server
Replicant.ReplicantManager.startClient() -- on the client
```

Define a replicant type with `Replicant.defineReplicant{...}`, then `setNew` / `setNewClient`,
`createServerOnlyEvent` (mutates `replicatedState`), `createSendMessageToServerEvent` (client → server),
`createServerOnlySignal`, and `setHeartbeatServer/Client`. See the module source for the full contract.

## Streaming and instance handles

The framework supports `Workspace.StreamingEnabled` with **Atomic**, **Persistent**, and
**PersistentPerPlayer** models. Nonatomic model bindings are rejected while streaming is enabled.
The framework never changes a model's streaming policy for you. Configure it before constructing
the replicant. Atomic roots are sufficient; persistence is optional. Bind the root model once and
derive its children when it arrives. A direct part handle is also valid, but does not promise an
atomic subtree. Do not bind a Nonatomic model and assume its descendants arrived together.

```lua
local component, Server, Client = Replicant.defineReplicant({
	module = script,
	paramsType = {} :: { character: Model },
	replicatedStateType = {} :: { health: number },
	serverStateType = {},
	clientStateType = {} :: { character: Model? },
	instanceHandlesType = {} :: { character: InstanceHandle },
})
Server.__index = Server
Client.__index = Client

Server.new = component.setNew(function(params)
	params.character.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return { health = 100 }, {}, { character = InstanceHandle.new(params.character) }
end, function(bare)
	return setmetatable(bare, Server)
end)

Client.newClient = component.setNewClient(function(_state, _handles)
	return { character = nil }
end, function(bare)
	return setmetatable(bare, Client)
end)

function Client:handleStreamedIn(key: string, instance: Instance)
	if key ~= "character" then return end
	self.clientState.character = instance :: Model
	-- Derive Humanoid / HumanoidRootPart / Head here and apply the latest replicated state.
	instance:SetAttribute("DisplayedHealth", self.replicatedState.health)
end

function Client:handleStreamedOut(key: string, _instance: Instance)
	if key ~= "character" then return end
	self.clientState.character = nil
	-- Disconnect per-instance listeners, remove local effects, clear cached descendants.
end
```

Define stream hooks on the finalized client object's metatable. Both receive `(self, key, instance)`.
The first stream-in is deferred until after client construction; objects with absent targets are
still registered immediately and receive every state event. `InstanceHandle:Wait(60)` suspends one
observer per missing target and rearms after a timeout, avoiding infinite-yield warnings during
normal streaming absence. `AncestryChanged` detects loss of the target or an ancestor from the
DataModel and re-arms the observer for subsequent streaming cycles. Reparenting inside the DataModel
does not count as stream-out. The callbacks are client-only; the server can use `handle:Get()`.
The observer releases orphaned targets before retrying and waits 0.1 seconds between retries when
the handle still resolves an instance outside the DataModel.

Hooks **must not yield**. A yielding hook is cancelled and warned, preventing delayed writes to an
old streamed-out instance. `handleStreamedOut` also runs for any bound target during replicant
cleanup, before the ordinary cleanup callback. Pending waits and ancestry connections are cancelled
even if ordinary cleanup throws. Hooks should be safe if another handle is currently unavailable.

Keep visual updates in a helper called from both `handleStreamedIn` and relevant event handlers.
Event handlers always update replicated data; skip instance work while the cached instance is nil.
On return, rebuild presentation from current state instead of replaying obsolete cosmetic events.
The mapping is fixed for an object's lifetime; create a new replicant to replace its bindings.
`setValidateReplication` validates state, so it must not reject an otherwise valid replicant merely
because its physical target is absent.

Existing custom `serializeReplicatedState` / `deserializeReplicatedState` callbacks keep their
two-value signatures. The framework transports handles through a separate native RemoteEvent table
and adds a handle-table index to CREATE and snapshot records. Join snapshots and world subscription
bursts both carry the complete handle mapping. **Protocol 0.4 requires matching server/client
package versions**; old consumers using two-return constructors remain source-compatible.

Official API references: [InstanceHandle](https://create.roblox.com/docs/reference/engine/datatypes/InstanceHandle),
[native handle transport announcement](https://devforum.roblox.com/t/reference-instances-directly-with-attributes/4753441),
[model streaming behavior](https://create.roblox.com/docs/workspace/streaming).

## Security: validate the sender

`createSendMessageToServerEvent` handlers receive the sending `Player` as their **third argument**:

```lua
Component.RequestThing = component.createSendMessageToServerEvent({
	handleEventServer = function(self, params, player)
		if player ~= self.replicatedState.player then return end -- REQUIRED
		-- ...
	end,
})
```

The framework dispatches client messages by a **client-chosen instance id** and does **not** check
ownership for you — an unvalidated handler lets any client drive any instance. Only
`createSendMessageToServerEvent` handlers are reachable from clients; server-only events/signals are
not (enforced, not by convention).

## Limits

- ≤ 65535 component types (`componentId` is a `u16`), ≤ 256 events/signals per component, ≤ 65535-byte
  payloads per record.

## Development

```sh
rokit install
wally install
lune run tests/replication-codec.test   # pure wire-codec round-trip tests
lune run tests/redblacktree.test        # red-black tree invariant + differential stress tests
lune run tests/instance-handle-lifecycle.test # deterministic repeated-streaming/cancellation tests
```

`ReplicationCodec` and the injected `InstanceHandleLifecycle` state machine run under Lune.
`ReplicantManager`, the factory, and native handle transport require engine integration checks:

1. Enable streaming and create a remote Atomic model with a replicant. Join outside its streaming
   radius: confirm the client replicant and `instanceHandles` exist while `handle:Get()` is nil.
2. Send a state event while absent, approach it, and confirm a single stream-in applies that state.
3. Stream it out and back in twice: confirm balanced hooks, refreshed children and no duplicate
   listeners. Verify Persistent and PersistentPerPlayer model bindings too.
4. Destroy or unsubscribe while a handle is absent; stream the model in later and confirm no stale
   callbacks. Repeat cleanup while present, including a throwing ordinary cleanup callback.
5. Repeat with a custom buffer serializer and a private-world subscription burst; confirm state and
   handles reach only the intended subscriber and legacy two-return components still initialize.
