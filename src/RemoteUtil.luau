--!strict
local RunService = game:GetService("RunService")

local isServer = RunService:IsServer()
local isEdit = not RunService:IsRunning()

type Event<T...> = {
	Connect: (self: Event<T...>, handler: (T...) -> ()) -> RBXScriptConnection,
	Once: (self: Event<T...>, handler: (T...) -> ()) -> RBXScriptConnection,
	Wait: (self: Event<T...>) -> T...,
}

export type HasToClientSerializer<self, T...> = {
	AddToClientSerializer: (self: self, serializer: (T...) -> any, deserializer: (any) -> T...) -> (),
}

export type HasToServerSerializer<self, U...> = {
	AddToServerSerializer: (self: self, serializer: (U...) -> any, deserializer: (any) -> U...) -> (),
}

export type HasToServerValidator<self, T...> = {
	AddToServerValidator: (self: self, validator: (Player, T...) -> boolean) -> (),
}

export type HasToClientMiddleware<self, T...> = {
	AddToClientMiddleware: (self: self, middleware: (T...) -> ()) -> (),
}

export type HasToServerMiddleware<self, T...> = {
	AddToServerMiddleware: (self: self, middleware: (T...) -> ()) -> (),
}

export type BidirectionalRemoteEvent<T..., U...> =
	HasToClientSerializer<BidirectionalRemoteEvent<T..., U...>, T...>
	& HasToServerSerializer<BidirectionalRemoteEvent<T..., U...>, U...>
	& HasToServerValidator<BidirectionalRemoteEvent<T..., U...>, U...>
	& HasToClientMiddleware<BidirectionalRemoteEvent<T..., U...>, T...>
	& HasToServerMiddleware<BidirectionalRemoteEvent<T..., U...>, U...>
	& {
		FireServer: (self: BidirectionalRemoteEvent<T..., U...>, U...) -> (),
		FireClient: (self: BidirectionalRemoteEvent<T..., U...>, player: Player, T...) -> (),
		FireAllClients: (self: BidirectionalRemoteEvent<T..., U...>, T...) -> (),
		FireForClients: (self: BidirectionalRemoteEvent<T..., U...>, players: { Player }, T...) -> (),
		OnClientEvent: Event<T...>,
		OnServerEvent: Event<(Player, U...)>,
		Destroy: () -> (),
	}

export type ToClientRemoteEvent<T...> = HasToClientSerializer<ToClientRemoteEvent<T...>, T...> & HasToClientMiddleware<ToClientRemoteEvent<T...>, T...> & {
	FireClient: (self: ToClientRemoteEvent<T...>, player: Player, T...) -> (),
	FireAllClients: (self: ToClientRemoteEvent<T...>, T...) -> (),
	FireForClients: (self: ToClientRemoteEvent<T...>, players: { Player }, T...) -> (),
	OnClientEvent: Event<(T...)>,
	Destroy: () -> (),
}

export type ToServerRemoteEvent<T...> =
	HasToServerSerializer<ToServerRemoteEvent<T...>, T...>
	& HasToServerValidator<ToServerRemoteEvent<T...>, T...>
	& HasToServerMiddleware<ToServerRemoteEvent<T...>, T...>
	& {
		FireServer: (self: ToServerRemoteEvent<T...>, T...) -> (),
		OnServerEvent: Event<(Player, T...)>,
		Destroy: () -> (),
	}

export type ToServerRemoteFunction<T..., U...> = HasToServerSerializer<ToServerRemoteFunction<T..., U...>, T...> & {
	InvokeServer: (self: ToServerRemoteFunction<T..., U...>, T...) -> U...,
	OnServerInvoke: (player: Player, T...) -> U...,
	Destroy: () -> (),
}

export type ToClientRemoteFunction<T..., U...> = HasToClientSerializer<ToClientRemoteFunction<T..., U...>, T...> & {
	InvokeClient: (self: ToClientRemoteFunction<T..., U...>, T...) -> U...,
	OnClientInvoke: (T...) -> U...,
	Destroy: () -> (),
}

local function wrapAndStartRemoteEvent(remoteEvent: RemoteEvent)
	local wrapped = {
		toClientSerializer = nil :: any,
		toClientDeserializer = nil :: any,
		toServerSerializer = nil :: any,
		toServerDeserializer = nil :: any,
		toServerValidator = nil :: any,
		toServerMiddlewares = {} :: { (...any) -> () },
		toClientMiddlewares = {} :: { (...any) -> () },
	}

	wrapped.FireServer = function(self, ...)
		if self.toServerSerializer then
			remoteEvent:FireServer((self.toServerSerializer :: any)(...))
		else
			remoteEvent:FireServer(...)
		end
	end

	wrapped.FireClient = function(self, player, ...)
		if self.toClientSerializer then
			remoteEvent:FireClient(player, (self.toClientSerializer :: any)(...))
		else
			remoteEvent:FireClient(player, ...)
		end
	end

	wrapped.FireAllClients = function(self, ...)
		if self.toClientSerializer then
			remoteEvent:FireAllClients((self.toClientSerializer :: any)(...))
		else
			remoteEvent:FireAllClients(...)
		end
	end

	wrapped.FireForClients = function(self, players: { Player }, ...)
		if self.toClientSerializer then
			local serialized = table.pack((self.toClientSerializer :: any)(...))
			for _, player in ipairs(players) do
				remoteEvent:FireClient(player, table.unpack(serialized))
			end
		else
			for _, player in ipairs(players) do
				remoteEvent:FireClient(player, ...)
			end
		end
	end

	local onClientEvent = Instance.new("BindableEvent")
	local onServerEvent = Instance.new("BindableEvent")

	wrapped.OnClientEvent = onClientEvent.Event
	wrapped.OnServerEvent = onServerEvent.Event

	if RunService:IsServer() then
		remoteEvent.OnServerEvent:Connect(function(player, ...)
			local isValid = true
			if wrapped.toServerValidator then isValid = wrapped.toServerValidator(player, ...) end

			if not isValid then return end

			local dataReceived
			if wrapped.toServerDeserializer then
				dataReceived = table.pack((wrapped.toServerDeserializer :: any)(...))
			else
				dataReceived = table.pack(...)
			end

			for _, middleware in ipairs(wrapped.toServerMiddlewares) do
				middleware(...)
			end
			onServerEvent:Fire(player, table.unpack(dataReceived))
		end)
	else
		remoteEvent.OnClientEvent:Connect(function(...)
			local dataReceived
			if wrapped.toClientDeserializer then
				dataReceived = table.pack((wrapped.toClientDeserializer :: any)(...))
			else
				dataReceived = table.pack(...)
			end

			for _, middleware in ipairs(wrapped.toClientMiddlewares) do
				middleware(...)
			end

			onClientEvent:Fire(table.unpack(dataReceived))
		end)
	end

	wrapped.AddToClientSerializer = function(self, serializer, deserializer)
		assert(serializer and deserializer, "serializer and deserializer are required")
		wrapped.toClientSerializer = serializer
		wrapped.toClientDeserializer = deserializer
	end

	wrapped.AddToServerSerializer = function(self, serializer, deserializer)
		assert(serializer and deserializer, "serializer and deserializer are required")
		wrapped.toServerSerializer = serializer
		wrapped.toServerDeserializer = deserializer
	end

	wrapped.AddToServerValidator = function(self, validator)
		assert(validator, "validator is required")
		wrapped.toServerValidator = validator
	end

	wrapped.AddToServerMiddleware = function(self, middleware: (...any) -> ())
		assert(middleware, "middleware is required")
		wrapped.toServerMiddlewares[#wrapped.toServerMiddlewares + 1] = middleware
	end

	wrapped.AddToClientMiddleware = function(self, middleware: (...any) -> ())
		assert(middleware, "middleware is required")
		wrapped.toClientMiddlewares[#wrapped.toClientMiddlewares + 1] = middleware
	end

	wrapped.Destroy = function(self)
		remoteEvent:Destroy()
	end

	return wrapped
end

local function getRemoteEvent(folder: Instance?, nameExtension: string?, isUnreliable: boolean?): any
	isUnreliable = isUnreliable or false
	local sourceIdentifierString, lineNumber = debug.info(2, "sl")
	local name = string.format("%s_%d_RemoteEvent%s_%s", sourceIdentifierString, lineNumber, isUnreliable and "Unreliable" or "Reliable", nameExtension or "")
	if not folder or isEdit then
		local dummyRemoteEvent: any = if isUnreliable then Instance.new("UnreliableRemoteEvent") else Instance.new("RemoteEvent")
		dummyRemoteEvent.Name = name
		return wrapAndStartRemoteEvent(dummyRemoteEvent :: any)
	end

	if isServer then
		local remoteEvent = folder:FindFirstChild(name)
		if not remoteEvent then
			remoteEvent = if isUnreliable then Instance.new("UnreliableRemoteEvent") else Instance.new("RemoteEvent")
			assert(remoteEvent)
			remoteEvent.Name = name
			remoteEvent.Parent = folder
		end

		return wrapAndStartRemoteEvent(remoteEvent :: RemoteEvent)
	else
		local remoteEvent = folder:WaitForChild(name) :: RemoteEvent
		return wrapAndStartRemoteEvent(remoteEvent)
	end
end

local function getRemoteFunction(folder: Instance)
	local sourceIdentifierString, lineNumber = debug.info(2, "sl")
	local name = string.format("%s_%d_RemoteFunction", sourceIdentifierString, lineNumber)
	if not folder or isEdit then
		local dummyRemoteFunction = Instance.new("RemoteFunction")
		dummyRemoteFunction.Name = name
		return dummyRemoteFunction
	end

	if isServer then
		local remoteFunction = folder:FindFirstChild(name) :: RemoteFunction?
		if not remoteFunction then
			local newRemoteFunction = Instance.new("RemoteFunction")
			newRemoteFunction.Name = name
			newRemoteFunction.Parent = folder

			remoteFunction = newRemoteFunction
		end
		return remoteFunction :: RemoteFunction
	else
		return folder:WaitForChild(name) :: RemoteFunction
	end
end

return {
	getRemoteEvent = getRemoteEvent,
	getRemoteFunction = getRemoteFunction,
}
