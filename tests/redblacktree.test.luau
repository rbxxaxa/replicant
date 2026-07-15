--!nonstrict
-- Validation + stress test for RedBlackTree under Lune (it is pure Lua, no Roblox deps):
--
--     lune run tests/redblacktree.test
--
-- RedBlackTree carries a "Written by ChatGPT" header and is load-bearing (ComponentManager uses it
-- to keep replicated instances in creation order). This test proves it by, after EVERY operation:
--   1. checking the red-black invariants top-down (BST order, root black, no red-red, equal
--      black-height on all root->leaf paths, and child->parent pointer consistency), and
--   2. differentially checking inOrderTraversal against an independent set model (order + membership).
-- Plus balance (height <= 2*log2(n+1)), the monotonic-insert-with-deletes pattern ComponentManager
-- actually uses, and search correctness. Exit code is non-zero on any failure so it can gate CI.

local RedBlackTree = require("../src/RedBlackTree")

local RED, BLACK = true, false
-- The sentinel is shared across all trees; a fresh empty tree's root IS it.
local NIL = RedBlackTree.new().root

local passed, failed = 0, 0
local function check(name: string, ok: boolean, detail: string?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`  FAIL: {name}{if detail then " — " .. detail else ""}`)
	end
end

-- Deterministic LCG so any failure reproduces exactly.
local rngState = 0x2545F491
local function randInt(n: number): number
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	return (rngState % n) + 1
end

-- Full red-black invariant validation, top-down. Sets `ok=false` + a message on the first violation.
local function validate(label: string, tree)
	local root = tree.root
	if root == NIL then
		check(`{label}: empty tree valid`, true)
		return
	end

	local ok = true
	local err: string? = nil
	local function fail(msg: string)
		if ok then
			ok = false
			err = msg
		end
	end

	if root.color ~= BLACK then fail("root is not black") end

	-- Returns black-height (counting black nodes on any path, including the NIL leaf).
	local function blackHeight(node, minV, maxV): number
		if node == NIL then
			return 1 -- NIL is black
		end
		if node.value == nil then
			fail("real node has nil value")
			return 0
		end
		if minV ~= nil and node.value <= minV then fail(`BST order violated (value {node.value} <= min {minV})`) end
		if maxV ~= nil and node.value >= maxV then fail(`BST order violated (value {node.value} >= max {maxV})`) end
		if node.color ~= RED and node.color ~= BLACK then fail(`node {node.value} has a non-boolean color`) end
		if node.color == RED then
			if (node.left ~= NIL and node.left.color == RED) or (node.right ~= NIL and node.right.color == RED) then
				fail(`red node {node.value} has a red child`)
			end
		end
		-- Parent pointers for REAL children must point back (we never touch the shared NIL's parent).
		if node.left ~= NIL and node.left.parent ~= node then fail(`left child of {node.value} has wrong parent pointer`) end
		if node.right ~= NIL and node.right.parent ~= node then fail(`right child of {node.value} has wrong parent pointer`) end

		local lh = blackHeight(node.left, minV, node.value)
		local rh = blackHeight(node.right, node.value, maxV)
		if lh ~= rh then fail(`black-height mismatch at {node.value}: left {lh} vs right {rh}`) end
		return lh + (node.color == BLACK and 1 or 0)
	end

	blackHeight(root, nil, nil)
	check(label, ok, err)
end

local function height(node): number
	if node == NIL then return 0 end
	return 1 + math.max(height(node.left), height(node.right))
end

local function inorder(tree): { number }
	local out = {}
	tree:inOrderTraversal(function(v)
		table.insert(out, v)
	end)
	return out
end

local function sortedKeys(model): { number }
	local keys = {}
	for k in model do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function arraysEqual(a: { number }, b: { number }): boolean
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- 1. Empty tree.
do
	local t = RedBlackTree.new()
	validate("empty", t)
	check("empty inorder is []", #inorder(t) == 0)
	check("empty search returns NIL", t:search(5) == NIL)
	local okDelete = pcall(function()
		t:delete(5) -- delete from empty must not crash
	end)
	check("delete from empty does not crash", okDelete)
	validate("empty after no-op delete", t)
end

-- 2. Single element lifecycle.
do
	local t = RedBlackTree.new()
	t:insert(42)
	validate("single insert", t)
	check("single inorder", arraysEqual(inorder(t), { 42 }))
	check("single search hit", t:search(42) ~= NIL)
	check("single search miss", t:search(43) == NIL)
	t:delete(42)
	validate("single delete", t)
	check("empty after single delete", #inorder(t) == 0)
end

-- 3 & 4. Ascending and descending inserts (worst cases for an unbalanced BST).
for _, mode in { "ascending", "descending" } do
	local t = RedBlackTree.new()
	local N = 2000
	if mode == "ascending" then
		for i = 1, N do
			t:insert(i)
		end
	else
		for i = N, 1, -1 do
			t:insert(i)
		end
	end
	validate(`{mode} inserts`, t)
	local expected = {}
	for i = 1, N do
		expected[i] = i
	end
	check(`{mode} inorder sorted`, arraysEqual(inorder(t), expected))
	-- Balance: RB height is bounded by 2*log2(n+1).
	local h = height(t.root)
	local bound = 2 * (math.log(N + 1) / math.log(2))
	check(`{mode} height {h} within RB bound {string.format("%.1f", bound)}`, h <= bound)
end

-- 5. Delete of a non-existent value is a no-op.
do
	local t = RedBlackTree.new()
	for _, v in { 10, 20, 30 } do
		t:insert(v)
	end
	t:delete(25)
	validate("delete non-existent", t)
	check("delete non-existent preserves set", arraysEqual(inorder(t), { 10, 20, 30 }))
end

-- 6. Differential random churn — validate + compare to the model after EVERY op.
do
	local t = RedBlackTree.new()
	local model = {}
	local range = 200
	local mismatches = 0
	for _ = 1, 4000 do
		local v = randInt(range)
		if model[v] then
			t:delete(v)
			model[v] = nil
		else
			t:insert(v)
			model[v] = true
		end
		validate("churn-small", t)
		if not arraysEqual(inorder(t), sortedKeys(model)) then
			mismatches += 1
		end
	end
	check("small churn: inorder always == sorted model", mismatches == 0, `{mismatches} mismatches`)
end

-- 7. Large-tree stress — validate periodically + at the end (bigger trees exercise deeper fixups).
do
	local t = RedBlackTree.new()
	local model = {}
	local range = 5000
	local mismatches = 0
	for step = 1, 40000 do
		local v = randInt(range)
		if model[v] then
			t:delete(v)
			model[v] = nil
		else
			t:insert(v)
			model[v] = true
		end
		if step % 250 == 0 then
			validate("churn-large", t)
			if not arraysEqual(inorder(t), sortedKeys(model)) then
				mismatches += 1
			end
		end
	end
	validate("churn-large final", t)
	check("large churn: inorder == sorted model at checkpoints", mismatches == 0, `{mismatches} mismatches`)
	check("large churn final inorder == model", arraysEqual(inorder(t), sortedKeys(model)))
end

-- 8. ComponentManager's actual pattern: strictly-increasing unique keys inserted, with random
--    deletes of live keys interspersed (a component destroyed => its replicationOrder removed).
do
	local t = RedBlackTree.new()
	local live = {} -- set of currently-inserted keys
	local nextKey = 1
	for _ = 1, 20000 do
		if next(live) ~= nil and randInt(3) == 1 then
			-- delete a random live key
			local keys = sortedKeys(live)
			local victim = keys[randInt(#keys)]
			t:delete(victim)
			live[victim] = nil
		else
			t:insert(nextKey)
			live[nextKey] = true
			nextKey += 1
		end
	end
	validate("monotonic-with-deletes", t)
	check("monotonic pattern: inorder == sorted live set", arraysEqual(inorder(t), sortedKeys(live)))
	-- The keys must come out strictly ascending (this is the property ComponentManager depends on).
	local ord = inorder(t)
	local ascending = true
	for i = 2, #ord do
		if ord[i] <= ord[i - 1] then ascending = false end
	end
	check("monotonic pattern: traversal strictly ascending", ascending)
end

-- 9. Search correctness on a populated tree.
do
	local t = RedBlackTree.new()
	local present = {}
	for _ = 1, 1000 do
		local v = randInt(3000)
		t:insert(v)
		present[v] = true
	end
	local searchOk = true
	for v = 1, 3000 do
		local found = t:search(v) ~= NIL
		if found ~= (present[v] == true) then searchOk = false end
	end
	check("search matches membership for all probed values", searchOk)
end

-- 10. Delete every element one at a time, validating after each, ending empty.
do
	local t = RedBlackTree.new()
	local vals = {}
	for i = 1, 500 do
		local v = randInt(100000)
		if not vals[v] then
			vals[v] = true
			t:insert(v)
		end
	end
	local drainOk = true
	for v in vals do
		t:delete(v)
		local root = t.root
		if root ~= NIL then
			-- cheap per-delete structural check
			if root.color ~= BLACK then drainOk = false end
		end
	end
	validate("fully drained", t)
	check("draining every element ends empty", #inorder(t) == 0)
	check("draining kept root black throughout", drainOk)
end

print(`RedBlackTree: {passed} passed, {failed} failed`)
if failed > 0 then error(`RedBlackTree tests failed ({failed} failures)`, 0) end
