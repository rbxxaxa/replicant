--!strict
-- Round-trip tests for ReplicationCodec, runnable outside Roblox under Lune:
--
--     lune run tests/replication-codec.test
--
-- ReplicationCodec is pure (buffer-only), so this exercises the exact shipping wire framing.
-- The headline cases use componentId > 255 to lock in the two fixes that motivated the codec:
--   * componentId is a real u16 everywhere (previously u8 in several paths -> 255-type ceiling)
--   * the event/signal paths no longer writeu32-into-one-byte (previously correct only by
--     little-endian luck and componentId < 256)
-- Exit code is non-zero on any failure so this can gate CI.

local ReplicationCodec = require("../src/ReplicationCodec")

local passed = 0
local failed = 0

local function check(name: string, ok: boolean, detail: string?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`  FAIL: {name}{if detail then " — " .. detail else ""}`)
	end
end

local function makePayload(bytes: { number }?): buffer?
	if bytes == nil then return nil end
	local b = buffer.create(#bytes)
	for i, v in bytes do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

local function buffersEqual(a: buffer?, b: buffer?): boolean
	if a == nil and b == nil then return true end
	if a == nil or b == nil then
		-- Treat nil and a zero-length buffer as equivalent (the codec returns nil for empty payloads).
		local present = if a ~= nil then a else b :: buffer
		return buffer.len(present) == 0
	end
	if buffer.len(a) ~= buffer.len(b) then return false end
	return buffer.tostring(a) == buffer.tostring(b)
end

-- The full set of componentId values we care about: boundaries + values that used to overflow u8.
local COMPONENT_IDS = { 1, 2, 127, 255, 256, 300, 1000, 65535 }
local INSTANCE_IDS = { 0, 1, 255, 65535, 100000, 4294967295 }
local EVENT_INDICES = { 0, 1, 127, 255 }
local PAYLOADS: { { number }? } = { nil, {}, { 0 }, { 255, 0, 42 }, { 1, 2, 3, 4, 5, 6, 7, 8 } }

-- Encode one incremental record on its own and read it straight back.
local function roundtripIncremental(record: ReplicationCodec.IncrementalRecord): ReplicationCodec.IncrementalRecord
	local size = ReplicationCodec.sizeIncremental(record)
	local b = buffer.create(size)
	local writeEnd = ReplicationCodec.writeIncremental(b, 0, record)
	check(`sizeIncremental matches writeIncremental (tag {record.tag}, cid {record.componentId})`, writeEnd == size, `wrote {writeEnd}, size said {size}`)

	local decoded, readEnd = ReplicationCodec.readIncremental(b, 0)
	check(`readIncremental consumes all bytes (tag {record.tag}, cid {record.componentId})`, readEnd == size, `read {readEnd}, size said {size}`)
	return decoded
end

local function roundtripSnapshot(record: ReplicationCodec.SnapshotRecord): ReplicationCodec.SnapshotRecord
	local size = ReplicationCodec.sizeSnapshot(record)
	local b = buffer.create(size)
	local writeEnd = ReplicationCodec.writeSnapshot(b, 0, record)
	check(`sizeSnapshot matches writeSnapshot (cid {record.componentId})`, writeEnd == size, `wrote {writeEnd}, size said {size}`)

	local decoded, readEnd = ReplicationCodec.readSnapshot(b, 0)
	check(`readSnapshot consumes all bytes (cid {record.componentId})`, readEnd == size, `read {readEnd}, size said {size}`)
	return decoded
end

-- DESTROY records (no payload, no tablePosition).
for _, componentId in COMPONENT_IDS do
	for _, instanceId in INSTANCE_IDS do
		local decoded = roundtripIncremental({
			tag = ReplicationCodec.DESTROY,
			componentId = componentId,
			instanceId = instanceId,
		})
		check(`destroy cid preserved ({componentId})`, decoded.componentId == componentId, tostring(decoded.componentId))
		check(`destroy instanceId preserved ({instanceId})`, decoded.instanceId == instanceId, tostring(decoded.instanceId))
	end
end

-- CREATE records (componentId, instanceId, payload, tablePosition).
for _, componentId in COMPONENT_IDS do
	for payloadIndex, payloadBytes in PAYLOADS do
		local payload = makePayload(payloadBytes)
		local payloadLen = if payload then buffer.len(payload) else 0
		local tablePosition = payloadIndex -- exercise a range of non-zero and zero-ish values
		local decoded = roundtripIncremental({
			tag = ReplicationCodec.CREATE,
			componentId = componentId,
			instanceId = 123456,
			payload = payload,
			payloadLen = payloadLen,
			tablePosition = tablePosition,
		})
		check(`create cid preserved ({componentId})`, decoded.componentId == componentId, tostring(decoded.componentId))
		check(`create instanceId preserved`, decoded.instanceId == 123456)
		check(`create payload preserved (cid {componentId}, len {payloadLen})`, buffersEqual(decoded.payload, payload))
		check(`create payloadLen preserved`, decoded.payloadLen == payloadLen)
		check(`create tablePosition preserved`, decoded.tablePosition == tablePosition)
	end
end

-- EVENT records (componentId, eventIndex, instanceId, payload, tablePosition).
-- This is where the old writeu32-into-one-byte bug lived; the >255 componentIds prove it's gone.
for _, componentId in COMPONENT_IDS do
	for _, eventIndex in EVENT_INDICES do
		local payload = makePayload({ 9, 8, 7 })
		local decoded = roundtripIncremental({
			tag = ReplicationCodec.EVENT,
			componentId = componentId,
			eventIndex = eventIndex,
			instanceId = 777,
			payload = payload,
			payloadLen = 3,
			tablePosition = 0,
		})
		check(`event cid preserved ({componentId})`, decoded.componentId == componentId, tostring(decoded.componentId))
		check(`event eventIndex preserved ({eventIndex})`, decoded.eventIndex == eventIndex, tostring(decoded.eventIndex))
		check(`event instanceId preserved`, decoded.instanceId == 777)
		check(`event payload preserved`, buffersEqual(decoded.payload, payload))
		check(`event tablePosition 0 -> no table`, decoded.tablePosition == 0)
	end
end

-- SIGNAL records (componentId, eventIndex, payload, tablePosition; no instanceId).
for _, componentId in COMPONENT_IDS do
	for _, eventIndex in EVENT_INDICES do
		local decoded = roundtripIncremental({
			tag = ReplicationCodec.SIGNAL,
			componentId = componentId,
			eventIndex = eventIndex,
			payload = nil,
			payloadLen = 0,
			tablePosition = 5,
		})
		check(`signal cid preserved ({componentId})`, decoded.componentId == componentId, tostring(decoded.componentId))
		check(`signal eventIndex preserved ({eventIndex})`, decoded.eventIndex == eventIndex, tostring(decoded.eventIndex))
		check(`signal empty payload -> nil`, decoded.payload == nil)
		check(`signal tablePosition preserved`, decoded.tablePosition == 5)
	end
end

-- SNAPSHOT records.
for _, componentId in COMPONENT_IDS do
	for payloadIndex, payloadBytes in PAYLOADS do
		local payload = makePayload(payloadBytes)
		local payloadLen = if payload then buffer.len(payload) else 0
		local decoded = roundtripSnapshot({
			componentId = componentId,
			instanceId = 42,
			payload = payload,
			payloadLen = payloadLen,
			tablePosition = payloadIndex - 1,
		})
		check(`snapshot cid preserved ({componentId})`, decoded.componentId == componentId, tostring(decoded.componentId))
		check(`snapshot payload preserved (len {payloadLen})`, buffersEqual(decoded.payload, payload))
		check(`snapshot tablePosition preserved`, decoded.tablePosition == (payloadIndex - 1))
	end
end

-- Mixed stream: exactly how ComponentManager packs a frame — a u32 count then N records of
-- assorted kinds back-to-back — must round-trip with offsets chaining perfectly.
do
	local records: { ReplicationCodec.IncrementalRecord } = {
		{ tag = ReplicationCodec.CREATE, componentId = 300, instanceId = 1, payload = makePayload({ 1, 2 }), payloadLen = 2, tablePosition = 1 },
		{ tag = ReplicationCodec.DESTROY, componentId = 65535, instanceId = 2 },
		{ tag = ReplicationCodec.EVENT, componentId = 256, eventIndex = 200, instanceId = 3, payload = nil, payloadLen = 0, tablePosition = 0 },
		{ tag = ReplicationCodec.SIGNAL, componentId = 7, eventIndex = 1, payload = makePayload({ 255, 254, 253, 252 }), payloadLen = 4, tablePosition = 2 },
	}

	local total = 4
	for _, record in records do
		total += ReplicationCodec.sizeIncremental(record)
	end

	local b = buffer.create(total)
	local offset = 0
	buffer.writeu32(b, offset, #records)
	offset += 4
	for _, record in records do
		offset = ReplicationCodec.writeIncremental(b, offset, record)
	end
	check("mixed stream fills the buffer exactly", offset == total, `wrote {offset}, allocated {total}`)

	offset = 0
	local count = buffer.readu32(b, offset)
	offset += 4
	check("mixed stream count round-trips", count == #records, `{count} vs {#records}`)

	for i = 1, count do
		local decoded: ReplicationCodec.IncrementalRecord
		decoded, offset = ReplicationCodec.readIncremental(b, offset)
		local expected = records[i]
		check(`mixed record {i} tag`, decoded.tag == expected.tag)
		check(`mixed record {i} componentId ({expected.componentId})`, decoded.componentId == expected.componentId, tostring(decoded.componentId))
		check(`mixed record {i} payload`, buffersEqual(decoded.payload, expected.payload))
	end
	check("mixed stream fully consumed", offset == total, `ended at {offset}, expected {total}`)
end

-- Scratch reuse (the client hot-path optimization): decoding into a shared `out` record must
-- (a) return that same table, (b) preserve every field of the current record, and (c) never leak a
-- field from a prior record of a different kind.
do
	local records: { ReplicationCodec.IncrementalRecord } = {
		{ tag = ReplicationCodec.EVENT, componentId = 5, eventIndex = 42, instanceId = 99, payload = makePayload({ 1 }), payloadLen = 1, tablePosition = 3 },
		{ tag = ReplicationCodec.DESTROY, componentId = 6, instanceId = 100 },
		{ tag = ReplicationCodec.SIGNAL, componentId = 7, eventIndex = 8, payload = nil, payloadLen = 0, tablePosition = 0 },
	}

	local total = 4
	for _, record in records do
		total += ReplicationCodec.sizeIncremental(record)
	end
	local b = buffer.create(total)
	local offset = 0
	buffer.writeu32(b, offset, #records)
	offset += 4
	for _, record in records do
		offset = ReplicationCodec.writeIncremental(b, offset, record)
	end

	offset = 4
	local scratch: ReplicationCodec.IncrementalRecord = {} :: any

	local r1
	r1, offset = ReplicationCodec.readIncremental(b, offset, scratch)
	check("scratch reuse returns the same table", r1 == scratch)
	check("scratch event eventIndex preserved", r1.eventIndex == 42)
	check("scratch event instanceId preserved", r1.instanceId == 99)

	local r2
	r2, offset = ReplicationCodec.readIncremental(b, offset, scratch)
	check("scratch destroy reuses same table", r2 == scratch)
	check("scratch destroy componentId", r2.componentId == 6)
	check("scratch destroy instanceId", r2.instanceId == 100)
	-- The prior EVENT record set eventIndex/payload/tablePosition; DESTROY must clear them.
	check("scratch destroy clears stale eventIndex", r2.eventIndex == nil)
	check("scratch destroy clears stale payload", r2.payload == nil)
	check("scratch destroy clears stale tablePosition", r2.tablePosition == nil)

	local r3
	r3, offset = ReplicationCodec.readIncremental(b, offset, scratch)
	check("scratch signal eventIndex", r3.eventIndex == 8)
	-- SIGNAL carries no instanceId; the prior DESTROY set instanceId=100, which must be cleared.
	check("scratch signal clears stale instanceId", r3.instanceId == nil)
	check("scratch signal fully consumed", offset == total, `ended at {offset}, expected {total}`)
end

print(`ReplicationCodec: {passed} passed, {failed} failed`)
if failed > 0 then error(`ReplicationCodec tests failed ({failed} failures)`, 0) end
