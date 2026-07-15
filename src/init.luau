--!strict
-- rbxxaxa/replicant — a server-authoritative replicated object framework for Roblox.
--
-- "Replicants" are OOP objects whose state auto-replicates server -> client. Each has three state
-- buckets — `replicatedState` (replicated to all clients, the only bucket clients read),
-- `serverState` (server-only), and `clientState` (client-only) — plus a lifecycle (new/newClient/
-- destroy), heartbeats, server-only events (the only place replicatedState may mutate), validated
-- client->server messages, and server-only signals. State is buffer-packed over one reliable
-- RemoteEvent per frame. Extracted from the studio-incubator-prototype / Ship Wars codebases.
--
-- Public surface:
--   Replicant.defineReplicant{...} -> (base, serverType, clientType)   define a replicant type
--   Replicant.ReplicantManager                                          startServer()/startClient(), …
--   Replicant.ReplicationCodec                                          the pure wire codec (mostly internal)
--
-- NOTE (security): every client->server message handler MUST validate its 3rd `player` argument
-- against the target instance's owner — the framework routes by client-chosen instance id and does
-- not check ownership for you.

local ReplicantManager = require(script.ReplicantManager)
local ReplicationCodec = require(script.ReplicationCodec)
local defineReplicantModule = require(script.defineReplicant)

export type ServerOnlySignal<EventParams> = defineReplicantModule.ServerOnlySignal<EventParams>
export type Replicant<InitParams, ReplicatedState, ServerState, ClientState> = defineReplicantModule.Replicant<
	InitParams,
	ReplicatedState,
	ServerState,
	ClientState
>

return {
	defineReplicant = defineReplicantModule.defineReplicant,
	ReplicantManager = ReplicantManager,
	ReplicationCodec = ReplicationCodec,
}
