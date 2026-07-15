# replicant

`rbxxaxa/replicant` — a **server-authoritative replicated component framework** for Roblox. Components
are OOP objects whose state automatically replicates server → client over a compact buffer-packed
protocol. Extracted from the studio-incubator-prototype / Ship Wars codebases (a shipped 1000+ CCU
game).

```toml
[dependencies]
Replicant = "rbxxaxa/replicant@0.1.1"
```

## The model

Each component has three state buckets:

- **`replicatedState`** — replicates to all clients. Only primitives, tables, and Roblox instances.
  The only bucket clients can read.
- **`serverState`** — server-only (Signals, Troves, transient data). Never replicates.
- **`clientState`** — client-only.

`replicatedState` may **only** be mutated inside the `modifyReplicatedState` callback of a server-only
event; the same callback replays on the client so both sides stay consistent. Newly-joined clients
receive a full snapshot; connected clients receive incremental events — both framed by the pure
`ReplicationCodec`.

```lua
local Replicant = require(Packages.Replicant)
local createBaseComponent = Replicant.CreateBaseComponent.createBaseComponent
local ComponentManager = Replicant.ComponentManager

-- boot
ComponentManager.startServer() -- on the server
ComponentManager.startClient() -- on the client
```

Define a component with `createBaseComponent`, then `setNew` / `setNewClient`, `createServerOnlyEvent`
(mutates `replicatedState`), `createSendMessageToServerEvent` (client → server), `createServerOnlySignal`,
and `setHeartbeatServer/Client`. See the module source for the full contract.

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
```

`ReplicationCodec` is pure (buffer-only) and unit-tested under Lune; `ComponentManager` and
`CreateBaseComponent` depend on Roblox APIs and are exercised in-engine by the consuming game.
