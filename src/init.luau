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
-- WORLDS (replication scopes):
--   ReplicantManager.createWorld() -> worldId          a fresh, private scope
--   ReplicantManager.withWorld(id, fn)                 everything constructed inside `fn` lands there
--   ReplicantManager.subscribeToWorld(player, id)      player starts seeing it (full snapshot)
--   ReplicantManager.unsubscribeFromWorld(player, id)  player stops seeing it (destroys)
--
-- `replicatedState` used to fan out to EVERY ready client, which made anything per-player quadratic
-- and forced games to hand-roll a private RemoteEvent alongside the framework. A world is a set of
-- instances plus the players allowed to see them. World 0 is the default and behaves exactly as
-- before, so existing code is unaffected.
--
-- ⚠ WORLDS ARE SERVER-SIDE ONLY. The client has no world id and no new message type: subscribing
-- sends CREATEs, unsubscribing sends DESTROYs. Client components need no changes.
--
-- NOTE (security): worlds now enforce the ACL the framework used to leave to you — a client can only
-- reach instances in worlds it is subscribed to. That answers "may this player talk to this object
-- at all". It does NOT validate parameters: every client->server handler must still check that what
-- it was asked to do is legal. For an instance in world 0 (shared by everyone) the old rule stands
-- in full — validate the 3rd `player` argument against the target's owner.

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
