--!strict
-- A heartbeat step that throws must skip only its own instance, frame after frame.
local HeartbeatDispatch = require("../src/HeartbeatDispatch")

local passed = 0
local function check(message: string, condition: boolean)
	assert(condition, message)
	passed += 1
end

type Instance = { id: number, steps: number, broken: boolean }

local instances: { [number]: Instance } = {}
for id = 1, 5 do
	instances[id] = { id = id, steps = 0, broken = id == 3 }
end
local errors: { string } = {}
local function onError(message: any)
	table.insert(errors, tostring(message))
end
local function step(instance: Instance, dt: number)
	if instance.broken then error(`instance {instance.id} has no PrimaryPart`) end
	instance.steps += 1
	assert(dt == 1 / 60, "Each step receives the frame's dt")
end

for _ = 1, 3 do
	HeartbeatDispatch.stepAll(instances, nil, step, 1 / 60, onError)
end
for id, instance in instances do
	if id ~= 3 then check(`instance {id} steps every frame beside a broken sibling`, instance.steps == 3) end
end
check("the broken instance never completes a step", instances[3].steps == 0)
check("each frame reports the broken step once", #errors == 3)
check("the report carries the step's own error", string.find(errors[1], "instance 3 has no PrimaryPart", 1, true) ~= nil)

-- Instances created this frame wait for the next one.
table.clear(errors)
local createdThisFrame: { [number]: true } = { [1] = true, [2] = true }
HeartbeatDispatch.stepAll(instances, createdThisFrame, step, 1 / 60, onError)
check("a skipped instance does not step", instances[1].steps == 3 and instances[2].steps == 3)
check("unskipped instances still step", instances[4].steps == 4 and instances[5].steps == 4)

-- A step may destroy its own instance mid-frame, as a dying replicant does, and the rest still step.
instances[3].broken = false
local function destroyingStep(instance: Instance, dt: number)
	if instance.id == 2 then
		instances[2] = nil
		error("destroyed mid-step")
	end
	step(instance, dt)
end
HeartbeatDispatch.stepAll(instances, nil, destroyingStep, 1 / 60, onError)
check("a self-destroying instance leaves the table", instances[2] == nil)
check("the others step after it", instances[1].steps == 4 and instances[3].steps == 1 and instances[4].steps == 5 and instances[5].steps == 5)

print(`heartbeat-dispatch: {passed} checks passed`)
