local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

export type direction = "toServer" | "toClient"

export type packetType =
	| "string"
	| "number"
	| "boolean"
	| "table"
	| "function"
	| "nil"
	| "thread"
	| "userdata"
	| "vector"
	| "buffer"
	| "instance"
	| "cframe"
	| "vector3"
	| "vector2"
	| "color3"
	| "brickColor"
	| "udim"
	| "udim2"
	| "enum"
	| "enumItem"
	| "unknown"

export type connection = {
	disconnect: (self: connection) -> (),
	connected: boolean,
}

export type response<T...> = {
	await: (self: response<T...>) -> T...,
	andThen: (self: response<T...>, callback: (T...) -> ()) -> connection,
}

export type eventConfig = {
	schema: { packetType },
	direction: direction,
	rateLimit: number?,
	debounce: number?,
	unreliable: boolean?,
}

export type requestConfig = {
	schema: { packetType },
	returns: { packetType },
	direction: direction,
	rateLimit: number?,
	debounce: number?,
}

export type event<T...> = {
	send: (self: event<T...>, T...) -> (),
	listen: (self: event<T...>, callback: (Player, T...) -> ()) -> connection,

	sendTo: (self: event<T...>, player: Player, T...) -> (),
	sendToList: (self: event<T...>, players: { Player }, T...) -> (),
	broadcast: (self: event<T...>, T...) -> (),
	onReceive: (self: event<T...>, callback: (T...) -> ()) -> connection,
}

export type request<T..., R...> = {
	send: (self: request<T..., R...>, T...) -> response<R...>,
	handle: (self: request<T..., R...>, callback: (Player, T...) -> R...) -> (),

	sendTo: (self: request<T..., R...>, player: Player, T...) -> response<R...>,
	onRequest: (self: request<T..., R...>, callback: (T...) -> R...) -> (),
}

type rateLimitData = {
	count: number,
	resetTime: number,
	lastCall: number,
}

local isServer: boolean = RunService:IsServer()
local context: "server" | "client" = if isServer then "server" else "client"

local obfuscationSeed: string = ""

local types = table.freeze({
	string = "string" :: packetType,
	number = "number" :: packetType,
	boolean = "boolean" :: packetType,
	table = "table" :: packetType,
	["function"] = "function" :: packetType,
	["nil"] = "nil" :: packetType,
	thread = "thread" :: packetType,
	userdata = "userdata" :: packetType,
	vector = "vector" :: packetType,
	buffer = "buffer" :: packetType,
	instance = "instance" :: packetType,
	cframe = "cframe" :: packetType,
	vector3 = "vector3" :: packetType,
	vector2 = "vector2" :: packetType,
	color3 = "color3" :: packetType,
	brickColor = "brickColor" :: packetType,
	udim = "udim" :: packetType,
	udim2 = "udim2" :: packetType,
	enum = "enum" :: packetType,
	enumItem = "enumItem" :: packetType,
	unknown = "unknown" :: packetType,
})

local typeMapping: { [string]: packetType } = {
	["string"] = "string",
	["number"] = "number",
	["boolean"] = "boolean",
	["table"] = "table",
	["function"] = "function",
	["nil"] = "nil",
	["thread"] = "thread",
	["userdata"] = "userdata",
	["vector"] = "vector",
	["buffer"] = "buffer",
	["Instance"] = "instance",
	["CFrame"] = "cframe",
	["Vector3"] = "vector3",
	["Vector2"] = "vector2",
	["Color3"] = "color3",
	["BrickColor"] = "brickColor",
	["UDim"] = "udim",
	["UDim2"] = "udim2",
	["EnumItem"] = "enumItem",
}

local remoteFolder: Folder

local function hashName(name: string): string
	if obfuscationSeed == "" then
		return name
	end

	local combined: string = obfuscationSeed .. name
	local hash: number = 5381

	for i = 1, #combined do
		local char: number = string.byte(combined, i)
		hash = bit32.band(hash * 33 + char, 0xFFFFFFFF)
	end

	return string.format("%08X", hash)
end

local function getValueType(value: any): packetType
    local luaType: string = typeof(value)

    if typeMapping[luaType] then
        return typeMapping[luaType]
    end

    if luaType == "userdata" and tostring(value):match("^Enum") then
        return "enum"
    end

    return luaType :: packetType
end

local function validateSchema(name: string, schema: {packetType}, args: {any}): (boolean, string?)
    if #args ~= #schema then
        return false, `[{name}] expected {#schema} arguments, got {#args}`
    end

    for i: number, expectedType: packetType in schema do
        if expectedType == "unknown" then
            continue
        end

        local actualType: packetType = getValueType(args[i])

        if expectedType == "instance" and typeof(args[i]) == "Instance" then
            continue
        end

        if actualType ~= expectedType then
            return false, `[{name}] argument {i}: expected {expectedType}, got {actualType}`
        end
    end

    return true, nil
end

type rateLimitChecker = (player: Player?) -> (boolean, string?)

local function createRateLimiter(rateLimit: number?, debounce: number?): rateLimitChecker
    local playerData: {[Player]: rateLimitData} = {}

    if isServer then
        Players.PlayerRemoving:Connect(function(player: Player)
            playerData[player] = nil
        end)
    end

    return function(player: Player?): (boolean, string?)
        if not rateLimit and not debounce then
            return true, nil
        end

        if not isServer then
            return true, nil
        end

        if not player then
            return false, "player required for rate limiting"
        end

        local now: number = os.clock()
        local data: rateLimitData = playerData[player] or {
            count = 0,
            resetTime = now + 1,
            lastCall = 0,
        }
        playerData[player] = data

        if debounce and (now - data.lastCall) < debounce then
            local remaining: number = debounce - (now - data.lastCall)
            return false, `debounce: wait {string.format("%.2f", remaining)}s`
        end

        if rateLimit then
            if now >= data.resetTime then
                data.count = 0
                data.resetTime = now + 1
            end

            if data.count >= rateLimit then
                return false, `rate limit exceeded: {data.count}/{rateLimit} per second`
            end

            data.count += 1
        end

        data.lastCall = now
        return true, nil
    end
end

local function wrapConnection(rbxConnection: RBXScriptConnection): connection
    return {
        connected = true,
        disconnect = function(self: connection)
            self.connected = false
            rbxConnection:Disconnect()
        end,
    }
end

local function createResponse<T...>(invokeFunc: () -> T...): response<T...>
    local resolved: boolean = false
    local results: {any} = {}
    local waiting: {thread} = {}
    local callbacks: {(...any) -> ()} = {}

    task.spawn(function()
        results = {invokeFunc()}
        resolved = true

        for _: number, waitingThread: thread in waiting do
            task.spawn(waitingThread, table.unpack(results))
        end

        for _: number, callback: (...any) -> () in callbacks do
            task.spawn(callback, table.unpack(results))
        end
    end)

    return {
        await = function(_self: response<T...>): T...
            if resolved then
                return table.unpack(results)
            end

            local currentThread: thread = coroutine.running()
            table.insert(waiting, currentThread)
            return coroutine.yield()
        end,

        andThen = function(_self: response<T...>, callback: (T...) -> ()): connection
            if resolved then
                task.spawn(callback, table.unpack(results))
                return { connected = false, disconnect = function(_self: connection) end }
            end

            table.insert(callbacks, callback :: (...any) -> ())
            local index: number = #callbacks

            return {
                connected = true,
                disconnect = function(self: connection)
                    self.connected = false
                    callbacks[index] = nil :: any
                end,
            }
        end,
    }
end

local function createEvent<T...>(name: string, config: eventConfig): event<T...>
	local direction: direction = config.direction
	local useUnreliable: boolean = config.unreliable == true
	local remoteName: string = hashName(name)

	local reliableRemote: RemoteEvent?
	local unreliableRemote: UnreliableRemoteEvent?

	if isServer then
		if useUnreliable then
			local remote = Instance.new("UnreliableRemoteEvent")
			remote.Name = remoteName
			remote.Parent = remoteFolder
			unreliableRemote = remote
		else
			local remote = Instance.new("RemoteEvent")
			remote.Name = remoteName
			remote.Parent = remoteFolder
			reliableRemote = remote
		end
	else
		local remote = remoteFolder:WaitForChild(remoteName, 10)
		if not remote then
			error(`[packet] event '{name}' not found (remote: {remoteName})`)
		end
		if useUnreliable then
			unreliableRemote = remote :: UnreliableRemoteEvent
		else
			reliableRemote = remote :: RemoteEvent
		end
	end

	local schema: { packetType } = config.schema
	local checkLimit: rateLimitChecker = createRateLimiter(config.rateLimit, config.debounce)

	local function fireServer(...: any)
		if reliableRemote then
			reliableRemote:FireServer(...)
		elseif unreliableRemote then
			unreliableRemote:FireServer(...)
		end
	end

	local function fireClient(player: Player, ...: any)
		if reliableRemote then
			reliableRemote:FireClient(player, ...)
		elseif unreliableRemote then
			unreliableRemote:FireClient(player, ...)
		end
	end

	local function fireAllClients(...: any)
		if reliableRemote then
			reliableRemote:FireAllClients(...)
		elseif unreliableRemote then
			unreliableRemote:FireAllClients(...)
		end
	end

	local function getServerSignal(): RBXScriptSignal
		if reliableRemote then
			return reliableRemote.OnServerEvent
		end
		return (unreliableRemote :: UnreliableRemoteEvent).OnServerEvent
	end

	local function getClientSignal(): RBXScriptSignal
		if reliableRemote then
			return reliableRemote.OnClientEvent
		end
		return (unreliableRemote :: UnreliableRemoteEvent).OnClientEvent
	end

	return {
		send = function(_self: event<T...>, ...: T...)
			assert(context == "client", `[{name}] send() can only be called from the client`)
			assert(direction == "toServer", `[{name}] send() requires direction = "toServer"`)

			local args: { any } = table.pack(...)
			local valid: boolean, err: string? = validateSchema(name, schema, args)
			if not valid then
				error(err)
			end

			fireServer(...)
		end,

		listen = function(_self: event<T...>, callback: (Player, T...) -> ()): connection
			assert(context == "server", `[{name}] listen() can only be called from the server`)
			assert(direction == "toServer", `[{name}] listen() requires direction = "toServer"`)

			local rbxConnection: RBXScriptConnection = getServerSignal():Connect(function(player: Player, ...: any)
				local args: { any } = table.pack(...)

				local allowed: boolean, limitErr: string? = checkLimit(player)
				if not allowed then
					warn(`[{name}] {player.Name}: {limitErr or "rate limited"}`)
					return
				end

				local valid: boolean, schemaErr: string? = validateSchema(name, schema, args)
				if not valid then
					warn(schemaErr)
					return
				end

				callback(player, ...)
			end)

			return wrapConnection(rbxConnection)
		end,

		sendTo = function(_self: event<T...>, player: Player, ...: T...)
			assert(context == "server", `[{name}] sendTo() can only be called from the server`)
			assert(direction == "toClient", `[{name}] sendTo() requires direction = "toClient"`)

			local args: { any } = table.pack(...)
			local valid: boolean, err: string? = validateSchema(name, schema, args)
			if not valid then
				error(err)
			end

			fireClient(player, ...)
		end,

		sendToList = function(_self: event<T...>, players: { Player }, ...: T...)
			assert(context == "server", `[{name}] sendToList() can only be called from the server`)
			assert(direction == "toClient", `[{name}] sendToList() requires direction = "toClient"`)

			local args: { any } = table.pack(...)
			local valid: boolean, err: string? = validateSchema(name, schema, args)
			if not valid then
				error(err)
			end

			for _: number, player: Player in players do
				fireClient(player, ...)
			end
		end,

		broadcast = function(_self: event<T...>, ...: T...)
			assert(context == "server", `[{name}] broadcast() can only be called from the server`)
			assert(direction == "toClient", `[{name}] broadcast() requires direction = "toClient"`)

			local args: { any } = table.pack(...)
			local valid: boolean, err: string? = validateSchema(name, schema, args)
			if not valid then
				error(err)
			end

			fireAllClients(...)
		end,

		onReceive = function(_self: event<T...>, callback: (T...) -> ()): connection
			assert(context == "client", `[{name}] onReceive() can only be called from the client`)
			assert(direction == "toClient", `[{name}] onReceive() requires direction = "toClient"`)

			local rbxConnection: RBXScriptConnection = getClientSignal():Connect(function(...: any)
				local args: { any } = table.pack(...)
				local valid: boolean, err: string? = validateSchema(name, schema, args)
				if not valid then
					warn(err)
					return
				end

				callback(...)
			end)

			return wrapConnection(rbxConnection)
		end,
	}
end

local function createRequest<T..., R...>(name: string, config: requestConfig): request<T..., R...>
	local direction: direction = config.direction
	local remoteName: string = hashName(name)
	local remote: RemoteFunction

	if isServer then
		remote = Instance.new("RemoteFunction")
		remote.Name = remoteName
		remote.Parent = remoteFolder
	else
		remote = remoteFolder:WaitForChild(remoteName, 10) :: RemoteFunction
		if not remote then
			error(`[packet] request '{name}' not found (remote: {remoteName})`)
		end
	end

	local schema: { packetType } = config.schema
	local checkLimit: rateLimitChecker = createRateLimiter(config.rateLimit, config.debounce)

	return {
		send = function(_self: request<T..., R...>, ...: T...): response<R...>
			assert(context == "client", `[{name}] send() can only be called from the client`)
			assert(direction == "toServer", `[{name}] send() requires direction = "toServer"`)

			local args: { any } = table.pack(...)
			local valid: boolean, err: string? = validateSchema(name, schema, args)
			if not valid then
				error(err)
			end

			return createResponse(function(): R...
				return remote:InvokeServer(table.unpack(args))
			end)
		end,

		handle = function(_self: request<T..., R...>, callback: (Player, T...) -> R...)
			assert(context == "server", `[{name}] handle() can only be called from the server`)
			assert(direction == "toServer", `[{name}] handle() requires direction = "toServer"`)

			remote.OnServerInvoke = function(player: Player, ...: any)
				local args: { any } = table.pack(...)

				local allowed: boolean, limitErr: string? = checkLimit(player)
				if not allowed then
					warn(`[{name}] {player.Name}: {limitErr or "rate limited"}`)
					return nil
				end

				local valid: boolean, schemaErr: string? = validateSchema(name, schema, args)
				if not valid then
					warn(schemaErr)
					return nil
				end

				return callback(player, ...)
			end
		end,

		sendTo = function(_self: request<T..., R...>, player: Player, ...: T...): response<R...>
			assert(context == "server", `[{name}] sendTo() can only be called from the server`)
			assert(direction == "toClient", `[{name}] sendTo() requires direction = "toClient"`)

			local args: { any } = table.pack(...)
			local valid: boolean, err: string? = validateSchema(name, schema, args)
			if not valid then
				error(err)
			end

			return createResponse(function(): R...
				return remote:InvokeClient(player, table.unpack(args))
			end)
		end,

		onRequest = function(_self: request<T..., R...>, callback: (T...) -> R...)
			assert(context == "client", `[{name}] onRequest() can only be called from the client`)
			assert(direction == "toClient", `[{name}] onRequest() requires direction = "toClient"`)

			remote.OnClientInvoke = function(...: any)
				local args: { any } = table.pack(...)
				local valid: boolean, err: string? = validateSchema(name, schema, args)
				if not valid then
					warn(err)
					return nil
				end

				return callback(...)
			end
		end,
	}
end

if isServer then
    remoteFolder = Instance.new("Folder")
    remoteFolder.Name = "_packet"
    remoteFolder.Parent = ReplicatedStorage

    obfuscationSeed = HttpService:GenerateGUID(false)
    local seedValue = Instance.new("StringValue")
    seedValue.Name = "_seed"
    seedValue.Value = obfuscationSeed
    seedValue.Parent = remoteFolder
else
    remoteFolder = ReplicatedStorage:WaitForChild("_packet", 10) :: Folder
    if not remoteFolder then
        error("[packet] failed to initialize: remote folder not found")
    end

    local seedValue = remoteFolder:WaitForChild("_seed", 10) :: StringValue
    if seedValue then
        obfuscationSeed = seedValue.Value
    end
end

return table.freeze({
    event = createEvent,
    request = createRequest,
    types = types,
    context = context,
})
