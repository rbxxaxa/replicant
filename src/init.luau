--!strict
-- rbxxaxa/replicant — a server-authoritative replicated component framework for Roblox.
--
-- Components are OOP objects whose state auto-replicates server -> client. Each has three state
-- buckets — `replicatedState` (replicated to all clients, the only bucket clients read),
-- `serverState` (server-only), and `clientState` (client-only) — plus a lifecycle (new/newClient/
-- destroy), heartbeats, server-only events (the only place replicatedState may mutate), validated
-- client->server messages, and server-only signals. State is buffer-packed over one reliable
-- RemoteEvent per frame. Extracted from the studio-incubator-prototype / Ship Wars codebases.
--
-- Public surface:
--   Replicant.CreateBaseComponent.createBaseComponent{...} -> build a component type
--   Replicant.ComponentManager                             -> startServer()/startClient(), etc.
--   Replicant.ReplicationCodec                             -> the pure wire codec (mostly internal)
--
-- See each submodule for the detailed contract. NOTE (security): every client->server message
-- handler MUST validate its 3rd `player` argument against the target instance's owner — the
-- framework routes by client-chosen instance id and does not check ownership for you.

local ComponentManager = require(script.ComponentManager)
local CreateBaseComponent = require(script.CreateBaseComponent)
local ReplicationCodec = require(script.ReplicationCodec)

export type ServerOnlySignal<EventParams> = CreateBaseComponent.ServerOnlySignal<EventParams>
export type BaseComponent<InitParams, ReplicatedState, ServerState, ClientState> = CreateBaseComponent.BaseComponent<
	InitParams,
	ReplicatedState,
	ServerState,
	ClientState
>

return {
	CreateBaseComponent = CreateBaseComponent,
	ComponentManager = ComponentManager,
	ReplicationCodec = ReplicationCodec,
}
