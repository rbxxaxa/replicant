--!strict
-- ReplicationCodec: the wire framing for the component replication protocol.
--
-- This module is PURE — it depends only on the `buffer` library, never on Roblox
-- services — so it is the single source of truth for the byte layout AND can be
-- unit-tested under Lune (see lune/replication-codec.test.luau).
--
-- Two streams share these record framings; each stream is prefixed by a u32 record
-- count written by the caller (ComponentManager), not by this module:
--
--   * the initial snapshot sent to a newly-ready client — a flat list of
--     SnapshotRecords (no tag byte; every record is a "current instance").
--   * the incremental stream sent every frame — a list of IncrementalRecords, each
--     led by a u8 tag (DESTROY / CREATE / EVENT / SIGNAL).
--
-- Field widths (little-endian, matching the `buffer` library):
--   tag           u8   (incremental only)
--   componentId   u16  -> up to 65535 registered component types
--   instanceId    u32
--   eventIndex    u8   -> up to 256 events/signals per component
--   payloadLen    u16  -> opaque payload up to 65535 bytes
--   <payload>     payloadLen bytes (the component's own serializeReplicatedState /
--                 serializeParams output; opaque to this codec)
--   tablePosition u16  -> 1-based index into the side-channel table array (0 = none)
--
-- NOTE: componentId was historically a u8 in some paths and, in the event/signal
-- paths, written with writeu32 while only one byte was reserved/read — correct only
-- by accident of little-endianness and componentId < 256. Centralising the layout
-- here makes it a real u16 everywhere and removes that whole class of drift.

local ReplicationCodec = {}

-- Incremental record tags (the leading u8 of each incremental record).
local DESTROY = 0
local CREATE = 1
local EVENT = 2
local SIGNAL = 3

ReplicationCodec.DESTROY = DESTROY
ReplicationCodec.CREATE = CREATE
ReplicationCodec.EVENT = EVENT
ReplicationCodec.SIGNAL = SIGNAL

-- Fixed field widths, named so the size math reads like the layout comment above.
local TAG_SIZE = 1
local COMPONENT_ID_SIZE = 2
local INSTANCE_ID_SIZE = 4
local EVENT_INDEX_SIZE = 1
local PAYLOAD_LEN_SIZE = 2
local TABLE_POSITION_SIZE = 2

export type IncrementalRecord = {
	tag: number,
	componentId: number,
	instanceId: number?, -- DESTROY, CREATE, EVENT (absent for SIGNAL)
	eventIndex: number?, -- EVENT, SIGNAL
	payload: buffer?, -- CREATE, EVENT, SIGNAL (nil when payloadLen == 0)
	payloadLen: number?, -- byte length of payload (0 when none)
	tablePosition: number?, -- CREATE, EVENT, SIGNAL (0 when none)
}

export type SnapshotRecord = {
	componentId: number,
	instanceId: number,
	payload: buffer?,
	payloadLen: number,
	tablePosition: number,
}

-- The trailing "<payloadLen><payload?><tablePosition>" shared by every record that
-- carries a payload (CREATE / EVENT / SIGNAL / snapshot).
local function writePayloadTail(b: buffer, offset: number, payload: buffer?, payloadLen: number, tablePosition: number): number
	buffer.writeu16(b, offset, payloadLen)
	offset += PAYLOAD_LEN_SIZE
	if payload ~= nil and payloadLen > 0 then
		buffer.copy(b, offset, payload, 0, payloadLen)
		offset += payloadLen
	end
	buffer.writeu16(b, offset, tablePosition)
	offset += TABLE_POSITION_SIZE
	return offset
end

-- Returns: payload (nil when empty), payloadLen, tablePosition, newOffset.
local function readPayloadTail(b: buffer, offset: number): (buffer?, number, number, number)
	local payloadLen = buffer.readu16(b, offset)
	offset += PAYLOAD_LEN_SIZE
	local payload: buffer? = nil
	if payloadLen > 0 then
		payload = buffer.create(payloadLen)
		buffer.copy(payload :: buffer, 0, b, offset, payloadLen)
		offset += payloadLen
	end
	local tablePosition = buffer.readu16(b, offset)
	offset += TABLE_POSITION_SIZE
	return payload, payloadLen, tablePosition, offset
end

-- Byte size this record will occupy in an incremental stream.
function ReplicationCodec.sizeIncremental(record: IncrementalRecord): number
	local tag = record.tag
	local payloadLen = record.payloadLen or 0
	if tag == DESTROY then
		return TAG_SIZE + COMPONENT_ID_SIZE + INSTANCE_ID_SIZE
	elseif tag == CREATE then
		return TAG_SIZE + COMPONENT_ID_SIZE + INSTANCE_ID_SIZE + PAYLOAD_LEN_SIZE + payloadLen + TABLE_POSITION_SIZE
	elseif tag == EVENT then
		return TAG_SIZE + COMPONENT_ID_SIZE + EVENT_INDEX_SIZE + INSTANCE_ID_SIZE + PAYLOAD_LEN_SIZE + payloadLen + TABLE_POSITION_SIZE
	elseif tag == SIGNAL then
		return TAG_SIZE + COMPONENT_ID_SIZE + EVENT_INDEX_SIZE + PAYLOAD_LEN_SIZE + payloadLen + TABLE_POSITION_SIZE
	end
	error(`ReplicationCodec: unknown incremental record tag {tag}`)
end

-- Writes the record at `offset`; returns the offset just past it.
function ReplicationCodec.writeIncremental(b: buffer, offset: number, record: IncrementalRecord): number
	local tag = record.tag
	buffer.writeu8(b, offset, tag)
	offset += TAG_SIZE

	if tag == DESTROY then
		buffer.writeu16(b, offset, record.componentId)
		offset += COMPONENT_ID_SIZE
		buffer.writeu32(b, offset, record.instanceId :: number)
		offset += INSTANCE_ID_SIZE
	elseif tag == CREATE then
		buffer.writeu16(b, offset, record.componentId)
		offset += COMPONENT_ID_SIZE
		buffer.writeu32(b, offset, record.instanceId :: number)
		offset += INSTANCE_ID_SIZE
		offset = writePayloadTail(b, offset, record.payload, record.payloadLen or 0, record.tablePosition or 0)
	elseif tag == EVENT then
		buffer.writeu16(b, offset, record.componentId)
		offset += COMPONENT_ID_SIZE
		buffer.writeu8(b, offset, record.eventIndex :: number)
		offset += EVENT_INDEX_SIZE
		buffer.writeu32(b, offset, record.instanceId :: number)
		offset += INSTANCE_ID_SIZE
		offset = writePayloadTail(b, offset, record.payload, record.payloadLen or 0, record.tablePosition or 0)
	elseif tag == SIGNAL then
		buffer.writeu16(b, offset, record.componentId)
		offset += COMPONENT_ID_SIZE
		buffer.writeu8(b, offset, record.eventIndex :: number)
		offset += EVENT_INDEX_SIZE
		offset = writePayloadTail(b, offset, record.payload, record.payloadLen or 0, record.tablePosition or 0)
	else
		error(`ReplicationCodec: unknown incremental record tag {tag}`)
	end

	return offset
end

-- Reads one incremental record at `offset`; returns (record, newOffset).
--
-- Pass `out` to decode into an existing table instead of allocating a fresh one — the client's
-- per-frame decode loop reuses a single scratch record this way, for zero per-record allocation on
-- the hot path. Every field is written on every call (nil for fields a given tag doesn't carry), so
-- a reused table never leaks stale fields into the next record. Only reuse `out` when the previous
-- record is fully consumed before the next read — true for the incremental loop, but NOT the
-- snapshot loop, which captures the record in deferred lateInit closures (so it allocates fresh).
function ReplicationCodec.readIncremental(b: buffer, offset: number, out: IncrementalRecord?): (IncrementalRecord, number)
	local record: IncrementalRecord = (out or {}) :: any

	local tag = buffer.readu8(b, offset)
	offset += TAG_SIZE
	record.tag = tag
	-- componentId immediately follows the tag for every record kind.
	record.componentId = buffer.readu16(b, offset)
	offset += COMPONENT_ID_SIZE

	if tag == DESTROY then
		record.instanceId = buffer.readu32(b, offset)
		offset += INSTANCE_ID_SIZE
		record.eventIndex = nil
		record.payload = nil
		record.payloadLen = nil
		record.tablePosition = nil
	elseif tag == CREATE then
		record.instanceId = buffer.readu32(b, offset)
		offset += INSTANCE_ID_SIZE
		record.eventIndex = nil
		local payload, payloadLen, tablePosition, newOffset = readPayloadTail(b, offset)
		record.payload = payload
		record.payloadLen = payloadLen
		record.tablePosition = tablePosition
		offset = newOffset
	elseif tag == EVENT then
		record.eventIndex = buffer.readu8(b, offset)
		offset += EVENT_INDEX_SIZE
		record.instanceId = buffer.readu32(b, offset)
		offset += INSTANCE_ID_SIZE
		local payload, payloadLen, tablePosition, newOffset = readPayloadTail(b, offset)
		record.payload = payload
		record.payloadLen = payloadLen
		record.tablePosition = tablePosition
		offset = newOffset
	elseif tag == SIGNAL then
		record.eventIndex = buffer.readu8(b, offset)
		offset += EVENT_INDEX_SIZE
		record.instanceId = nil
		local payload, payloadLen, tablePosition, newOffset = readPayloadTail(b, offset)
		record.payload = payload
		record.payloadLen = payloadLen
		record.tablePosition = tablePosition
		offset = newOffset
	else
		error(`ReplicationCodec: unknown incremental record tag {tag}`)
	end

	return record, offset
end

-- Byte size this record will occupy in a snapshot stream.
function ReplicationCodec.sizeSnapshot(record: SnapshotRecord): number
	return COMPONENT_ID_SIZE + INSTANCE_ID_SIZE + PAYLOAD_LEN_SIZE + record.payloadLen + TABLE_POSITION_SIZE
end

-- Writes the snapshot record at `offset`; returns the offset just past it.
function ReplicationCodec.writeSnapshot(b: buffer, offset: number, record: SnapshotRecord): number
	buffer.writeu16(b, offset, record.componentId)
	offset += COMPONENT_ID_SIZE
	buffer.writeu32(b, offset, record.instanceId)
	offset += INSTANCE_ID_SIZE
	offset = writePayloadTail(b, offset, record.payload, record.payloadLen, record.tablePosition)
	return offset
end

-- Reads one snapshot record at `offset`; returns (record, newOffset).
function ReplicationCodec.readSnapshot(b: buffer, offset: number): (SnapshotRecord, number)
	local componentId = buffer.readu16(b, offset)
	offset += COMPONENT_ID_SIZE
	local instanceId = buffer.readu32(b, offset)
	offset += INSTANCE_ID_SIZE
	local payload, payloadLen, tablePosition, newOffset = readPayloadTail(b, offset)
	return {
		componentId = componentId,
		instanceId = instanceId,
		payload = payload,
		payloadLen = payloadLen,
		tablePosition = tablePosition,
	},
		newOffset
end

return ReplicationCodec
