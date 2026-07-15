-- Written by ChatGPT
-- Constants for node colors
local RED = true
local BLACK = false

-- Sentinel NIL node shared by all leaves
local NIL = {
	color = BLACK,
	left = nil,
	right = nil,
	parent = nil,
	value = nil,
}

-- Create a new node with NIL children
local function createNode(value)
	return {
		value = value,
		color = RED,
		left = NIL,
		right = NIL,
		parent = nil,
	}
end

-- Red-Black Tree definition
local RBTree: RedBlackTree = {}
RBTree.__index = RBTree

type RedBlackTreeImpl = {
	__index: RedBlackTreeImpl,
	new: () -> RedBlackTree,
	insert: (RedBlackTree, number) -> nil,
	delete: (RedBlackTree, number) -> nil,
	search: (RedBlackTree, number) -> any,
	inOrderTraversal: (RedBlackTree, (number) -> ()) -> nil,
}

export type RedBlackTree = typeof(setmetatable(
	{} :: {
		root: typeof(NIL),
	},
	{} :: RedBlackTreeImpl
))

function RBTree.new()
	return setmetatable({
		root = NIL,
	}, RBTree) :: RedBlackTree
end

-- Helper functions
local function minimum(node)
	while node.left ~= NIL do
		node = node.left
	end
	return node
end

-- Rotations
function RBTree:leftRotate(x)
	local y = x.right
	x.right = y.left
	if y.left ~= NIL then y.left.parent = x end
	y.parent = x.parent
	if x.parent == NIL then
		self.root = y
	elseif x == x.parent.left then
		x.parent.left = y
	else
		x.parent.right = y
	end
	y.left = x
	x.parent = y
end

function RBTree:rightRotate(x)
	local y = x.left
	x.left = y.right
	if y.right ~= NIL then y.right.parent = x end
	y.parent = x.parent
	if x.parent == NIL then
		self.root = y
	elseif x == x.parent.right then
		x.parent.right = y
	else
		x.parent.left = y
	end
	y.right = x
	x.parent = y
end

-- Insertion
function RBTree:fixInsert(z)
	while z.parent.color == RED do
		local gp = z.parent.parent
		if z.parent == gp.left then
			local y = gp.right
			if y.color == RED then
				z.parent.color = BLACK
				y.color = BLACK
				gp.color = RED
				z = gp
			else
				if z == z.parent.right then
					z = z.parent
					self:leftRotate(z)
				end
				z.parent.color = BLACK
				gp.color = RED
				self:rightRotate(gp)
			end
		else
			local y = gp.left
			if y.color == RED then
				z.parent.color = BLACK
				y.color = BLACK
				gp.color = RED
				z = gp
			else
				if z == z.parent.left then
					z = z.parent
					self:rightRotate(z)
				end
				z.parent.color = BLACK
				gp.color = RED
				self:leftRotate(gp)
			end
		end
	end
	self.root.color = BLACK
end

function RBTree:insert(value)
	local z = createNode(value)
	local y = NIL
	local x = self.root

	while x ~= NIL do
		y = x
		if z.value < x.value then
			x = x.left
		else
			x = x.right
		end
	end

	z.parent = y
	if y == NIL then
		self.root = z
	elseif z.value < y.value then
		y.left = z
	else
		y.right = z
	end

	z.left = NIL
	z.right = NIL
	z.color = RED

	self:fixInsert(z)
end

-- Deletion
function RBTree:transplant(u, v)
	if u.parent == NIL then
		self.root = v
	elseif u == u.parent.left then
		u.parent.left = v
	else
		u.parent.right = v
	end
	v.parent = u.parent
end

function RBTree:fixDelete(x)
	while x ~= self.root and x.color == BLACK do
		if x == x.parent.left then
			local w = x.parent.right
			if w.color == RED then
				w.color = BLACK
				x.parent.color = RED
				self:leftRotate(x.parent)
				w = x.parent.right
			end
			if w.left.color == BLACK and w.right.color == BLACK then
				w.color = RED
				x = x.parent
			else
				if w.right.color == BLACK then
					w.left.color = BLACK
					w.color = RED
					self:rightRotate(w)
					w = x.parent.right
				end
				w.color = x.parent.color
				x.parent.color = BLACK
				w.right.color = BLACK
				self:leftRotate(x.parent)
				x = self.root
			end
		else
			local w = x.parent.left
			if w.color == RED then
				w.color = BLACK
				x.parent.color = RED
				self:rightRotate(x.parent)
				w = x.parent.left
			end
			if w.right.color == BLACK and w.left.color == BLACK then
				w.color = RED
				x = x.parent
			else
				if w.left.color == BLACK then
					w.right.color = BLACK
					w.color = RED
					self:leftRotate(w)
					w = x.parent.left
				end
				w.color = x.parent.color
				x.parent.color = BLACK
				w.left.color = BLACK
				self:rightRotate(x.parent)
				x = self.root
			end
		end
	end
	x.color = BLACK
end

function RBTree:search(value)
	local node = self.root
	while node ~= NIL and node.value ~= value do
		if value < node.value then
			node = node.left
		else
			node = node.right
		end
	end
	return node
end

function RBTree:delete(value)
	local z = self:search(value)
	if z == NIL then return end

	local y = z
	local yOriginalColor = y.color
	local x

	if z.left == NIL then
		x = z.right
		self:transplant(z, z.right)
	elseif z.right == NIL then
		x = z.left
		self:transplant(z, z.left)
	else
		y = minimum(z.right)
		yOriginalColor = y.color
		x = y.right
		if y.parent == z then
			x.parent = y
		else
			self:transplant(y, y.right)
			y.right = z.right
			y.right.parent = y
		end
		self:transplant(z, y)
		y.left = z.left
		y.left.parent = y
		y.color = z.color
	end

	if yOriginalColor == BLACK then self:fixDelete(x) end
end

-- In-order traversal
function RBTree:inOrderTraversal(callback)
	local function traverse(node)
		if node ~= NIL then
			traverse(node.left)
			callback(node.value)
			traverse(node.right)
		end
	end
	traverse(self.root)
end

return RBTree
