--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local STRING_BYTE_LIMIT = 512
local MAX_PACKET_BYTES = 65536
local MAX_POLLING_BUFFER = 1000
local MAX_NESTING_DEPTH = 32
local INSTANCE_ROOTS: { Instance } = {
	game:GetService("Workspace"),
	game:GetService("ReplicatedStorage"),
	game:GetService("Players"),
}

local scratchBuffer = buffer.create(MAX_PACKET_BYTES + 256)

export type direction = "toServer" | "toClient"
export type packetType =
    | "string" | "number" | "boolean" | "nil" | "buffer"
    | "instance" | "cframe" | "vector3" | "vector2" | "color3"
    | "brickColor" | "udim" | "udim2" | "enum" | "enumItem" | "unknown"
    | "function" | "thread" | "userdata" | "vector" | "variant"
export type structDef = {
	_kind: "struct",
	fields: { { key: string, type: fieldType } },
}
export type arrayDef = {
	_kind: "array",
	element: fieldType,
}
export type fieldType = packetType | structDef | arrayDef
export type connection = {
	disconnect: (self: connection) -> (),
	connected: boolean,
}
export type response<T...> = {
	await: (self: response<T...>) -> T...,
	andThen: (self: response<T...>, callback: (T...) -> ()) -> connection,
}
export type eventConfig = {
	schema: { fieldType },
	direction: direction,
	rateLimit: number?,
	debounce: number?,
	unreliable: boolean?,
	polling: boolean?,
}
export type requestConfig = {
	schema: { fieldType },
	returns: { fieldType },
	rateLimit: number?,
	debounce: number?,
	timeout: number?,
}
export type event<T...> = {
	fire: (self: event<T...>, T...) -> (),
	fireTo: (self: event<T...>, player: Player, T...) -> (),
	fireList: (self: event<T...>, players: { Player }, T...) -> (),
	on: (self: event<T...>, callback: (Player?, T...) -> ()) -> connection,
	iterate: (self: event<T...>) -> () -> (number, Player?, T...),
}
export type request<T..., R...> = {
	invoke: (self: request<T..., R...>, T...) -> response<R...>,
	on: (self: request<T..., R...>, callback: (Player, T...) -> R...) -> (),
}
type compiledType = {
	write: (targetBuffer: buffer, offset: number, value: any) -> number,
	read: (sourceBuffer: buffer, offset: number) -> (any, number),
	fixedSize: number?,
}
type compiledSchema = {
	write: (targetBuffer: buffer, offset: number, args: { any }) -> number,
	read: (sourceBuffer: buffer, offset: number) -> { any },
	fixedSize: number?,
}

local isServer: boolean = RunService:IsServer()
local context: "server" | "client" = if isServer then "server" else "client"
local obfuscationSeed: string = ""
local remoteFolder: Folder

local freeThreads: { thread } = {}

local function runCallbackInThread(callback: (...any) -> (), ...: any)
	callback(...)

	while true do
		table.insert(freeThreads, coroutine.running())
		local resumed = table.pack(coroutine.yield())

		callback = resumed[1] :: any
		callback(table.unpack(resumed, 2, resumed.n))
	end
end

local function spawnTask(callback: (...any) -> (), ...: any)
	if #freeThreads > 0 then
		local recycled = table.remove(freeThreads) :: thread
		coroutine.resume(recycled, callback, ...)
	else
		task.spawn(runCallbackInThread, callback, ...)
	end
end

local function isStructType(fieldDef: fieldType): boolean
	return type(fieldDef) == "table" and (fieldDef :: any)._kind == "struct"
end

local function isArrayType(fieldDef: fieldType): boolean
	return type(fieldDef) == "table" and (fieldDef :: any)._kind == "array"
end

local compileFieldType: (fieldDef: fieldType, depth: number) -> compiledType

local function compilePrimitive(primitiveType: packetType): compiledType
	if primitiveType == "number" then
		return {
			fixedSize = 8,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writef64(targetBuffer, offset, value)
				return offset + 8
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				return buffer.readf64(sourceBuffer, offset), offset + 8
			end,
		}
	end

	if primitiveType == "boolean" then
		return {
			fixedSize = 1,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writeu8(targetBuffer, offset, value and 1 or 0)
				return offset + 1
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				return buffer.readu8(sourceBuffer, offset) == 1, offset + 1
			end,
		}
	end

	if primitiveType == "vector3" then
		return {
			fixedSize = 12,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writef32(targetBuffer, offset, value.X)
				buffer.writef32(targetBuffer, offset + 4, value.Y)
				buffer.writef32(targetBuffer, offset + 8, value.Z)
				return offset + 12
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local x = buffer.readf32(sourceBuffer, offset)
				local y = buffer.readf32(sourceBuffer, offset + 4)
				local z = buffer.readf32(sourceBuffer, offset + 8)
				return Vector3.new(x, y, z), offset + 12
			end,
		}
	end

	if primitiveType == "vector2" then
		return {
			fixedSize = 8,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writef32(targetBuffer, offset, value.X)
				buffer.writef32(targetBuffer, offset + 4, value.Y)
				return offset + 8
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local x = buffer.readf32(sourceBuffer, offset)
				local y = buffer.readf32(sourceBuffer, offset + 4)
				return Vector2.new(x, y), offset + 8
			end,
		}
	end

	if primitiveType == "cframe" then
		return {
			fixedSize = 28,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				local axis, angle = value:ToAxisAngle()
				local halfAngle = angle * 0.5
				local sinHalfAngle = math.sin(halfAngle)

				buffer.writef32(targetBuffer, offset, value.X)
				buffer.writef32(targetBuffer, offset + 4, value.Y)
				buffer.writef32(targetBuffer, offset + 8, value.Z)
				buffer.writef32(targetBuffer, offset + 12, math.cos(halfAngle))
				buffer.writef32(targetBuffer, offset + 16, axis.X * sinHalfAngle)
				buffer.writef32(targetBuffer, offset + 20, axis.Y * sinHalfAngle)
				buffer.writef32(targetBuffer, offset + 24, axis.Z * sinHalfAngle)
				return offset + 28
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local positionX = buffer.readf32(sourceBuffer, offset)
				local positionY = buffer.readf32(sourceBuffer, offset + 4)
				local positionZ = buffer.readf32(sourceBuffer, offset + 8)
				local quaternionW = buffer.readf32(sourceBuffer, offset + 12)
				local quaternionX = buffer.readf32(sourceBuffer, offset + 16)
				local quaternionY = buffer.readf32(sourceBuffer, offset + 20)
				local quaternionZ = buffer.readf32(sourceBuffer, offset + 24)
				return CFrame.new(positionX, positionY, positionZ, quaternionW, quaternionX, quaternionY, quaternionZ), offset + 28
			end,
		}
	end

	if primitiveType == "color3" then
		return {
			fixedSize = 3,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writeu8(targetBuffer, offset, math.round(value.R * 255))
				buffer.writeu8(targetBuffer, offset + 1, math.round(value.G * 255))
				buffer.writeu8(targetBuffer, offset + 2, math.round(value.B * 255))
				return offset + 3
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local red = buffer.readu8(sourceBuffer, offset)
				local green = buffer.readu8(sourceBuffer, offset + 1)
				local blue = buffer.readu8(sourceBuffer, offset + 2)
				return Color3.fromRGB(red, green, blue), offset + 3
			end,
		}
	end

	if primitiveType == "brickColor" then
		return {
			fixedSize = 2,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writeu16(targetBuffer, offset, value.Number)
				return offset + 2
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local colorNumber = buffer.readu16(sourceBuffer, offset)
				return BrickColor.new(colorNumber), offset + 2
			end,
		}
	end

	if primitiveType == "udim" then
		return {
			fixedSize = 8,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writef32(targetBuffer, offset, value.Scale)
				buffer.writei32(targetBuffer, offset + 4, value.Offset)
				return offset + 8
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local scale = buffer.readf32(sourceBuffer, offset)
				local offsetValue = buffer.readi32(sourceBuffer, offset + 4)
				return UDim.new(scale, offsetValue), offset + 8
			end,
		}
	end

	if primitiveType == "udim2" then
		return {
			fixedSize = 16,

			write = function(targetBuffer: buffer, offset: number, value: any): number
				buffer.writef32(targetBuffer, offset, value.X.Scale)
				buffer.writei32(targetBuffer, offset + 4, value.X.Offset)
				buffer.writef32(targetBuffer, offset + 8, value.Y.Scale)
				buffer.writei32(targetBuffer, offset + 12, value.Y.Offset)
				return offset + 16
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local xScale = buffer.readf32(sourceBuffer, offset)
				local xOffset = buffer.readi32(sourceBuffer, offset + 4)
				local yScale = buffer.readf32(sourceBuffer, offset + 8)
				local yOffset = buffer.readi32(sourceBuffer, offset + 12)
				return UDim2.new(xScale, xOffset, yScale, yOffset), offset + 16
			end,
		}
	end

	if primitiveType == "string" then
		return {
			write = function(targetBuffer: buffer, offset: number, value: any): number
				local stringValue = value :: string
				buffer.writeu16(targetBuffer, offset, #stringValue)
				buffer.writestring(targetBuffer, offset + 2, stringValue)
				return offset + 2 + #stringValue
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local stringLength = buffer.readu16(sourceBuffer, offset)
				return buffer.readstring(sourceBuffer, offset + 2, stringLength), offset + 2 + stringLength
			end,
		}
	end

	if primitiveType == "buffer" then
		return {
			write = function(targetBuffer: buffer, offset: number, value: any): number
				local innerBuffer = value :: buffer
				local innerLength = buffer.len(innerBuffer)
				buffer.writeu32(targetBuffer, offset, innerLength)
				buffer.copy(targetBuffer, offset + 4, innerBuffer, 0, innerLength)
				return offset + 4 + innerLength
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local innerLength = buffer.readu32(sourceBuffer, offset)
				local innerBuffer = buffer.create(innerLength)
				buffer.copy(innerBuffer, 0, sourceBuffer, offset + 4, innerLength)
				return innerBuffer, offset + 4 + innerLength
			end,
		}
	end

	if primitiveType == "instance" then
		return {
			write = function(targetBuffer: buffer, offset: number, value: any): number
				local instancePath = (value :: Instance):GetFullName()
				buffer.writeu16(targetBuffer, offset, #instancePath)
				buffer.writestring(targetBuffer, offset + 2, instancePath)
				return offset + 2 + #instancePath
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local pathLength = buffer.readu16(sourceBuffer, offset)
				local instancePath = buffer.readstring(sourceBuffer, offset + 2, pathLength)
				local resolvedInstance: Instance? = game

				for _, pathPart in string.split(instancePath, ".") do
					if not resolvedInstance then
						break
					end

					resolvedInstance = resolvedInstance:FindFirstChild(pathPart)
				end

				if resolvedInstance and resolvedInstance ~= game then
					local isAllowed = false

					for _, allowedRoot in INSTANCE_ROOTS do
						if resolvedInstance:IsDescendantOf(allowedRoot) then
							isAllowed = true
							break
						end
					end

					if not isAllowed then
						warn(`[packet] instance '{instancePath}' is outside allowed roots; rejected`)
						return nil, offset + 2 + pathLength
					end
				end

				return resolvedInstance, offset + 2 + pathLength
			end,
		}
	end

	if primitiveType == "enum" then
		return {
			write = function(targetBuffer: buffer, offset: number, value: any): number
				local enumName = tostring(value):gsub("^Enum%.", "")
				buffer.writeu16(targetBuffer, offset, #enumName)
				buffer.writestring(targetBuffer, offset + 2, enumName)
				return offset + 2 + #enumName
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local nameLength = buffer.readu16(sourceBuffer, offset)
				local enumName = buffer.readstring(sourceBuffer, offset + 2, nameLength)
				return (Enum :: any)[enumName], offset + 2 + nameLength
			end,
		}
	end

	if primitiveType == "enumItem" then
		return {
			write = function(targetBuffer: buffer, offset: number, value: any): number
				local enumTypeName = tostring(value.EnumType):gsub("^Enum%.", "")
				buffer.writeu8(targetBuffer, offset, #enumTypeName)
				buffer.writestring(targetBuffer, offset + 1, enumTypeName)
				buffer.writeu16(targetBuffer, offset + 1 + #enumTypeName, value.Value)
				return offset + 1 + #enumTypeName + 2
			end,

			read = function(sourceBuffer: buffer, offset: number): (any, number)
				local typeNameLength = buffer.readu8(sourceBuffer, offset)
				local enumTypeName = buffer.readstring(sourceBuffer, offset + 1, typeNameLength)
				local enumValue = buffer.readu16(sourceBuffer, offset + 1 + typeNameLength)
				local resolvedOffset = offset + 1 + typeNameLength + 2
				local enumType = (Enum :: any)[enumTypeName]

				if enumType then
					local enumItem = enumType:FromValue(enumValue)

					if enumItem then
						return enumItem, resolvedOffset
					end
				end

				warn(`[packet] could not resolve EnumItem: {enumTypeName} value={enumValue}`)
				return nil, resolvedOffset
			end,
		}
	end

	if primitiveType == "nil" then
		return {
			fixedSize = 0,

			write = function(_targetBuffer: buffer, offset: number, _value: any): number
				return offset
			end,

			read = function(_sourceBuffer: buffer, offset: number): (any, number)
				return nil, offset
			end,
		}
	end

 	if primitiveType == "variant" then
        return {
            write = function(targetBuffer: buffer, offset: number, value: any): number
                local t = typeof(value)

                if value == nil then
                    buffer.writeu8(targetBuffer, offset, 0)  -- nil
                    return offset + 1
                elseif t == "number" then
                    buffer.writeu8(targetBuffer, offset, 1)
                    buffer.writef64(targetBuffer, offset + 1, value)
                    return offset + 1 + 8
                elseif t == "boolean" then
                    buffer.writeu8(targetBuffer, offset, 2)
                    buffer.writeu8(targetBuffer, offset + 1, value and 1 or 0)
                    return offset + 1 + 1
                elseif t == "string" then
                    local len = #value
                    if len > STRING_BYTE_LIMIT then
                        warn("[packet] variant string too long, truncated")
                        value = string.sub(value, 1, STRING_BYTE_LIMIT)
                        len = #value
                    end
                    buffer.writeu8(targetBuffer, offset, 3)
                    buffer.writeu16(targetBuffer, offset + 1, len)
                    buffer.writestring(targetBuffer, offset + 3, value)
                    return offset + 3 + len
                elseif t == "Vector3" then
                    buffer.writeu8(targetBuffer, offset, 4)
                    buffer.writef32(targetBuffer, offset + 1, value.X)
                    buffer.writef32(targetBuffer, offset + 5, value.Y)
                    buffer.writef32(targetBuffer, offset + 9, value.Z)
                    return offset + 1 + 12
                elseif t == "Vector2" then
                    buffer.writeu8(targetBuffer, offset, 5)
                    buffer.writef32(targetBuffer, offset + 1, value.X)
                    buffer.writef32(targetBuffer, offset + 5, value.Y)
                    return offset + 1 + 8
                elseif t == "CFrame" then
                    buffer.writeu8(targetBuffer, offset, 6)
                    local axis, angle = value:ToAxisAngle()
                    local half = angle * 0.5
                    local s = math.sin(half)
                    buffer.writef32(targetBuffer, offset + 1, value.X)
                    buffer.writef32(targetBuffer, offset + 5, value.Y)
                    buffer.writef32(targetBuffer, offset + 9, value.Z)
                    buffer.writef32(targetBuffer, offset + 13, math.cos(half))
                    buffer.writef32(targetBuffer, offset + 17, axis.X * s)
                    buffer.writef32(targetBuffer, offset + 21, axis.Y * s)
                    buffer.writef32(targetBuffer, offset + 25, axis.Z * s)
                    return offset + 1 + 28
                elseif t == "Color3" then
                    buffer.writeu8(targetBuffer, offset, 7)
                    buffer.writeu8(targetBuffer, offset + 1, math.round(value.R * 255))
                    buffer.writeu8(targetBuffer, offset + 2, math.round(value.G * 255))
                    buffer.writeu8(targetBuffer, offset + 3, math.round(value.B * 255))
                    return offset + 1 + 3
                elseif t == "Instance" then
                    buffer.writeu8(targetBuffer, offset, 10)

                    local instancePath = value:GetFullName()
                    local pathLen = #instancePath

                    if pathLen > STRING_BYTE_LIMIT then
                        warn("[packet] variant Instance path too long (>512 bytes)")
                        buffer.writeu8(targetBuffer, offset, 0)
                        return offset + 1
                    end

                    buffer.writeu16(targetBuffer, offset + 1, pathLen)
                    buffer.writestring(targetBuffer, offset + 3, instancePath)

                    return offset + 3 + pathLen
                elseif t == "buffer" then
                    local len = buffer.len(value)
                    buffer.writeu8(targetBuffer, offset, 8)
                    buffer.writeu32(targetBuffer, offset + 1, len)
                    buffer.copy(targetBuffer, offset + 5, value, 0, len)
                    return offset + 5 + len
                elseif t == "table" then
                    buffer.writeu8(targetBuffer, offset, 9)
                    local count = #value
                    buffer.writeu16(targetBuffer, offset + 1, count)
                    local newOffset = offset + 1 + 2
                    for i = 1, count do
                        local sub = compilePrimitive("variant")
                        newOffset = sub.write(targetBuffer, newOffset, value[i])
                    end
                    return newOffset

                else
                    warn(`[packet] variant: unsupported type '{t}' — sent as nil`)
                    buffer.writeu8(targetBuffer, offset, 0)
                    return offset + 1
                end
            end,

            read = function(sourceBuffer: buffer, offset: number): (any, number)
                local tag = buffer.readu8(sourceBuffer, offset)
                offset += 1

                if tag == 0 then return nil, offset end
                if tag == 1 then return buffer.readf64(sourceBuffer, offset), offset + 8 end
                if tag == 2 then return buffer.readu8(sourceBuffer, offset) == 1, offset + 1 end

                if tag == 3 then
                    local len = buffer.readu16(sourceBuffer, offset)
                    local str = buffer.readstring(sourceBuffer, offset + 2, len)
                    return str, offset + 2 + len
                end

                if tag == 4 then
                    local x = buffer.readf32(sourceBuffer, offset)
                    local y = buffer.readf32(sourceBuffer, offset + 4)
                    local z = buffer.readf32(sourceBuffer, offset + 8)
                    return Vector3.new(x, y, z), offset + 12
                end

                if tag == 5 then
                    local x = buffer.readf32(sourceBuffer, offset)
                    local y = buffer.readf32(sourceBuffer, offset + 4)
                    return Vector2.new(x, y), offset + 8
                end

                if tag == 6 then
                    local px = buffer.readf32(sourceBuffer, offset)
                    local py = buffer.readf32(sourceBuffer, offset + 4)
                    local pz = buffer.readf32(sourceBuffer, offset + 8)
                    local qw = buffer.readf32(sourceBuffer, offset + 12)
                    local qx = buffer.readf32(sourceBuffer, offset + 16)
                    local qy = buffer.readf32(sourceBuffer, offset + 20)
                    local qz = buffer.readf32(sourceBuffer, offset + 24)
                    return CFrame.new(px, py, pz, qw, qx, qy, qz), offset + 28
                end

                if tag == 7 then
                    local r = buffer.readu8(sourceBuffer, offset)
                    local g = buffer.readu8(sourceBuffer, offset + 1)
                    local b = buffer.readu8(sourceBuffer, offset + 2)
                    return Color3.fromRGB(r, g, b), offset + 3
                end

                if tag == 8 then
                    local len = buffer.readu32(sourceBuffer, offset)
                    local buf = buffer.create(len)
                    buffer.copy(buf, 0, sourceBuffer, offset + 4, len)
                    return buf, offset + 4 + len
                end

                if tag == 9 then
                    local count = buffer.readu16(sourceBuffer, offset)
                    offset += 2
                    local arr = table.create(count)
                    local sub = compilePrimitive("variant")
                    for i = 1, count do
                        arr[i], offset = sub.read(sourceBuffer, offset)
                    end
                    return arr, offset
                end

                if tag == 10 then
                    local pathLen = buffer.readu16(sourceBuffer, offset)
                    local instancePath = buffer.readstring(sourceBuffer, offset + 2, pathLen)
                    local resolved: Instance? = game

                    for _, part in string.split(instancePath, ".") do
                        if not resolved then break end
                        resolved = resolved:FindFirstChild(part)
                    end

                    if resolved and resolved ~= game then
                        local isAllowed = false
                        for _, root in INSTANCE_ROOTS do
                            if resolved:IsDescendantOf(root) then
                                isAllowed = true
                                break
                            end
                        end

                        if not isAllowed then
                            warn(`[packet] variant Instance path '{instancePath}' outside allowed roots — rejected as nil`)
                            return nil, offset + 2 + pathLen
                        end
                    end

                    return resolved, offset + 2 + pathLen
                end

                warn(`[packet] variant: unknown tag {tag} — returning nil`)
                return nil, offset
            end,
        }
    end

	return {
		fixedSize = 0,

		write = function(_targetBuffer: buffer, offset: number, _value: any): number
			return offset
		end,

		read = function(_sourceBuffer: buffer, offset: number): (any, number)
			return nil, offset
		end,
	}
end

local function compileStructDef(structDefinition: structDef, depth: number): compiledType
	type compiledField = { key: string, compiled: compiledType }

	local compiledFields: { compiledField } = {}
	local totalFixed = 0
	local allFixed = true

	for _, structField in structDefinition.fields do
		local fieldCompiled = compileFieldType(structField.type, depth + 1)
		table.insert(compiledFields, { key = structField.key, compiled = fieldCompiled })

		if fieldCompiled.fixedSize then
			totalFixed += fieldCompiled.fixedSize
		else
			allFixed = false
		end
	end

	return {
		fixedSize = if allFixed then totalFixed else nil,

		write = function(targetBuffer: buffer, offset: number, value: any): number
			for _, fieldEntry in compiledFields do
				offset = fieldEntry.compiled.write(targetBuffer, offset, (value :: { [string]: any })[fieldEntry.key])
			end
			return offset
		end,

		read = function(sourceBuffer: buffer, offset: number): (any, number)
			local obj: { [string]: any } = {}

			for _, fieldEntry in compiledFields do
				obj[fieldEntry.key], offset = fieldEntry.compiled.read(sourceBuffer, offset)
			end

			return obj, offset
		end,
	}
end

local function compileArrayDef(arrayDefinition: arrayDef, depth: number): compiledType
	local elementCompiled = compileFieldType(arrayDefinition.element, depth + 1)

	return {
		write = function(targetBuffer: buffer, offset: number, value: any): number
			local arrayValue = value :: { any }
			buffer.writeu32(targetBuffer, offset, #arrayValue)
			offset += 4

			for _, arrayElement in arrayValue do
				offset = elementCompiled.write(targetBuffer, offset, arrayElement)
			end

			return offset
		end,

		read = function(sourceBuffer: buffer, offset: number): (any, number)
			local elementCount = buffer.readu32(sourceBuffer, offset)
			offset += 4
			local arrayResult: { any } = table.create(elementCount)

			for elementIndex = 1, elementCount do
				arrayResult[elementIndex], offset = elementCompiled.read(sourceBuffer, offset)
			end

			return arrayResult, offset
		end,
	}
end

compileFieldType = function(fieldDef: fieldType, depth: number): compiledType
	if depth > MAX_NESTING_DEPTH then
		error(`[packet] schema nesting depth exceeded {MAX_NESTING_DEPTH} during compilation`)
	end

	if isStructType(fieldDef) then
		return compileStructDef(fieldDef :: structDef, depth)
	end

	if isArrayType(fieldDef) then
		return compileArrayDef(fieldDef :: arrayDef, depth)
	end

	return compilePrimitive(fieldDef :: packetType)
end

local function compileSchema(fieldSchema: { fieldType }): compiledSchema
	local compiledEntries: { compiledType } = {}
	local totalFixed = 0
	local allFixed = true

	for _, fieldDef in fieldSchema do
		local fieldCompiled = compileFieldType(fieldDef, 1)
		table.insert(compiledEntries, fieldCompiled)

		if fieldCompiled.fixedSize then
			totalFixed += fieldCompiled.fixedSize
		else
			allFixed = false
		end
	end

	return {
		fixedSize = if allFixed then totalFixed else nil,

		write = function(targetBuffer: buffer, offset: number, args: { any }): number
			for fieldIndex, compiledEntry in compiledEntries do
				offset = compiledEntry.write(targetBuffer, offset, args[fieldIndex])
			end
			return offset
		end,

		read = function(sourceBuffer: buffer, offset: number): { any }
			local args: { any } = {}

			for fieldIndex, compiledEntry in compiledEntries do
				args[fieldIndex], offset = compiledEntry.read(sourceBuffer, offset)
			end

			return args
		end,
	}
end


local function pack(schema: compiledSchema, args: { any }): buffer
	if schema.fixedSize then
		if schema.fixedSize > MAX_PACKET_BYTES then
			error(`[packet] pack: fixed schema size {schema.fixedSize} exceeds MAX_PACKET_BYTES ({MAX_PACKET_BYTES})`)
		end

		local resultBuffer = buffer.create(schema.fixedSize)
		schema.write(resultBuffer, 0, args)
		return resultBuffer
	end

	local finalOffset = schema.write(scratchBuffer, 0, args)

	if finalOffset > MAX_PACKET_BYTES then
		error(`[packet] pack: packet size {finalOffset} exceeds MAX_PACKET_BYTES ({MAX_PACKET_BYTES})`)
	end

	local resultBuffer = buffer.create(finalOffset)
	buffer.copy(resultBuffer, 0, scratchBuffer, 0, finalOffset)
	return resultBuffer
end

local function unpack(schema: compiledSchema, sourceBuffer: buffer): { any }
	return schema.read(sourceBuffer, 0)
end


local typeMapping: { [string]: packetType } = {
	string = "string", number = "number", boolean = "boolean",
	buffer = "buffer", Instance = "instance", CFrame = "cframe",
	Vector3 = "vector3", Vector2 = "vector2", Color3 = "color3",
	BrickColor = "brickColor", UDim = "udim", UDim2 = "udim2",
	EnumItem = "enumItem",
	["function"] = "function", ["nil"] = "nil", thread = "thread",
	userdata = "userdata", vector = "vector",
}

local function getValueType(value: any): packetType
	local luauTypeName = typeof(value)

	if typeMapping[luauTypeName] then
		return typeMapping[luauTypeName]
	end

	if luauTypeName == "userdata" and tostring(value):match("^Enum") then
		return "enum"
	end

	return luauTypeName :: packetType
end

local function isNaN(value: any): boolean
	return value ~= value
end


local function validateValue(
	eventName: string,
	fieldDef: fieldType,
	value: any,
	label: string,
	depth: number
): (boolean, string?)

	if depth > MAX_NESTING_DEPTH then
		return false, `[{eventName}] {label}: nesting depth exceeded {MAX_NESTING_DEPTH}`
	end

	if isStructType(fieldDef) then
		if type(value) ~= "table" then
			return false, `[{eventName}] {label}: expected struct (table), got {typeof(value)}`
		end

		for _, structField in (fieldDef :: structDef).fields do
			local isValid, validationError = validateValue(
				eventName,
				structField.type,
				(value :: any)[structField.key],
				`{label}.{structField.key}`,
				depth + 1
			)

			if not isValid then
				return false, validationError
			end
		end

		return true, nil
	end

	if isArrayType(fieldDef) then
		if type(value) ~= "table" then
			return false, `[{eventName}] {label}: expected array (table), got {typeof(value)}`
		end

		for elementIndex, arrayElement in (value :: { any }) do
			local isValid, validationError = validateValue(
				eventName,
				(fieldDef :: arrayDef).element,
				arrayElement,
				`{label}[{elementIndex}]`,
				depth + 1
			)

			if not isValid then
				return false, validationError
			end
		end

		return true, nil
	end

	local expectedType = fieldDef :: packetType
	if expectedType == "unknown" or expectedType == "variant" then
	    return true, nil
	end

	local actualType = getValueType(value)

	if expectedType == "string" and actualType == "string" then
		if #(value :: string) > STRING_BYTE_LIMIT then
			return false, `[{eventName}] {label}: string exceeds {STRING_BYTE_LIMIT} byte limit`
		end

		if utf8.len(value :: string) == nil then
			return false, `[{eventName}] {label}: string contains invalid UTF-8`
		end
	end

	if actualType == "number" and isNaN(value) then
		return false, `[{eventName}] {label}: NaN is not allowed`
	end

	if actualType == "vector3" then
		local vec3Value = value :: Vector3

		if isNaN(vec3Value.X) or isNaN(vec3Value.Y) or isNaN(vec3Value.Z) then
			return false, `[{eventName}] {label}: Vector3 contains NaN`
		end
	end

	if actualType == "vector2" then
		local vec2Value = value :: Vector2

		if isNaN(vec2Value.X) or isNaN(vec2Value.Y) then
			return false, `[{eventName}] {label}: Vector2 contains NaN`
		end
	end

	if actualType == "cframe" then
		local cframeValue = value :: CFrame

		if isNaN(cframeValue.X) or isNaN(cframeValue.Y) or isNaN(cframeValue.Z) then
			return false, `[{eventName}] {label}: CFrame contains NaN`
		end
	end

	if actualType == "color3" then
		local colorValue = value :: Color3

		if isNaN(colorValue.R) or isNaN(colorValue.G) or isNaN(colorValue.B) then
			return false, `[{eventName}] {label}: Color3 contains NaN`
		end
	end

	if actualType == "udim" then
		local udimValue = value :: UDim

		if isNaN(udimValue.Scale) or isNaN(udimValue.Offset) then
			return false, `[{eventName}] {label}: UDim contains NaN`
		end
	end

	if actualType == "udim2" then
		local udim2Value = value :: UDim2

		if isNaN(udim2Value.X.Scale) or isNaN(udim2Value.X.Offset) or isNaN(udim2Value.Y.Scale) or isNaN(udim2Value.Y.Offset) then
			return false, `[{eventName}] {label}: UDim2 contains NaN`
		end
	end

	if expectedType == "instance" and actualType == "instance" then
		return true, nil :: any
	end

	if actualType ~= expectedType then
		return false, `[{eventName}] {label}: expected {expectedType}, got {actualType}`
	end

	return true, nil :: any
end

local function validateSchema(
	eventName: string,
	fieldSchema: { fieldType },
	args: { any }
): (boolean, string?)

	if #args ~= #fieldSchema then
		return false, `[{eventName}] expected {#fieldSchema} args, got {#args}`
	end

	for argIndex, fieldDef in fieldSchema do
		local isValid, validationError = validateValue(eventName, fieldDef, args[argIndex], `arg {argIndex}`, 1)

		if not isValid then
			return false, validationError
		end
	end

	return true, nil
end


type rateLimitData = { tokens: number, lastRefill: number, lastCall: number }
type rateLimitChecker = (player: Player?) -> (boolean, string?)

local function createRateLimiter(rateLimit: number?, debounce: number?): rateLimitChecker
	if not rateLimit and not debounce then
		return function(_player: Player?): (boolean, string?)
			return true, nil
		end
	end

	local playerData: { [Player]: rateLimitData } = {}

	if isServer then
		Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
			playerData[leavingPlayer] = nil
		end)
	end

	return function(player: Player?): (boolean, string?)
		if not isServer then
			return true, nil
		end

		if not player then
			return false, "player required for rate limiting"
		end

		local currentTime = os.clock()
		local playerRateData = playerData[player]

		if not playerRateData then
			playerRateData = { tokens = rateLimit or 0, lastRefill = currentTime, lastCall = 0 }
			playerData[player] = playerRateData
		end

		if debounce and (currentTime - playerRateData.lastCall) < debounce then
			return false, `debounce: wait {string.format("%.2f", debounce - (currentTime - playerRateData.lastCall))}s`
		end

		if rateLimit then
			local elapsedTime = currentTime - playerRateData.lastRefill
			playerRateData.tokens = math.min(rateLimit, playerRateData.tokens + elapsedTime * rateLimit)
			playerRateData.lastRefill = currentTime

			if playerRateData.tokens < 1 then
				return false, "rate limit exceeded (token bucket)"
			end

			playerRateData.tokens -= 1
		end

		playerRateData.lastCall = currentTime
		return true, nil
	end
end


local function wrapConnection(robloxConnection: RBXScriptConnection): connection
	return {
		connected = true,

		disconnect = function(self: connection)
			self.connected = false
			robloxConnection:Disconnect()
		end,
	}
end


local function createResponse<T...>(
	invokeFunc: () -> T...,
	timeoutSeconds: number?
): response<T...>

	local resolved = false
	local timedOut = false
	local results: { any } = {}
	local waitingThreads: { thread } = {}

	local pendingCallbacks: { [number]: (...any) -> () } = {}
	local nextCallbackId = 0

	spawnTask(function()
		results = { invokeFunc() }
		resolved = true

		for _, waitingThread in waitingThreads do
			coroutine.resume(waitingThread, false, table.unpack(results))
		end

		for _, pendingCallback in pendingCallbacks do
			spawnTask(pendingCallback, table.unpack(results))
		end

		table.clear(pendingCallbacks)
	end)

	if timeoutSeconds then
		task.delay(timeoutSeconds, function()
			if resolved then
				return
			end

			timedOut = true

			for _, waitingThread in waitingThreads do
				coroutine.resume(waitingThread, true)
			end

			table.clear(waitingThreads)
			table.clear(pendingCallbacks)
		end)
	end

	return {
		await = function(_self: response<T...>): T...
			if resolved then
				return table.unpack(results)
			end

			if timedOut then
				error("[packet] response timed out")
			end

			table.insert(waitingThreads, coroutine.running())
			local isTimeout = coroutine.yield()

			if isTimeout then
				error("[packet] response timed out")
			end

			return table.unpack(results)
		end,

		andThen = function(_self: response<T...>, callback: (T...) -> ()): connection
			if resolved then
				spawnTask(callback, table.unpack(results))

				return {
					connected = false,

					disconnect = function(self: connection)
						self.connected = false
					end,
				}
			end

			nextCallbackId += 1
			local callbackId = nextCallbackId
			pendingCallbacks[callbackId] = callback :: (...any) -> ()

			return {
				connected = true,

				disconnect = function(self: connection)
					self.connected = false
					pendingCallbacks[callbackId] = nil
				end,
			}
		end :: any,
	}
end


type AnyRemote = RemoteEvent | UnreliableRemoteEvent

local function setupEventRemote(remoteName: string, useUnreliable: boolean): AnyRemote
	if isServer then
		local remoteInstance = Instance.new(if useUnreliable then "UnreliableRemoteEvent" else "RemoteEvent")
		remoteInstance.Name = remoteName
		remoteInstance.Parent = remoteFolder
		return remoteInstance :: any
	end

	return remoteFolder:WaitForChild(remoteName, 10) :: any
end

local function getSignal(remote: AnyRemote, side: "server" | "client"): RBXScriptSignal
	return (remote :: any)[if side == "server" then "OnServerEvent" else "OnClientEvent"]
end

local function fireRemote(remote: AnyRemote, target: "server" | "all" | Player, packetBuffer: buffer)
	if target == "server" then
		(remote :: any):FireServer(packetBuffer)

	elseif target == "all" then
		(remote :: any):FireAllClients(packetBuffer)

	else
		(remote :: any):FireClient(target :: Player, packetBuffer)
	end
end

local function receiveArgs(
	eventName: string,
	fieldSchema: { fieldType },
	argCompiled: compiledSchema,
	checkLimit: rateLimitChecker,
	packetBuffer: buffer,
	player: Player?
): { any }?

	local isAllowed, rateLimitError = checkLimit(player)

	if not isAllowed then
		warn(`[{eventName}] {if player then player.Name else "?"}: {rateLimitError}`)
		return nil
	end

	local unpackedArgs = unpack(argCompiled, packetBuffer)
	local isSchemaValid, schemaError = validateSchema(eventName, fieldSchema, unpackedArgs)

	if not isSchemaValid then
		warn(schemaError)
		return nil
	end

	return unpackedArgs
end


local function hashName(name: string): string
	if obfuscationSeed == "" then
		return name
	end

	local seedPlusName = obfuscationSeed .. name
	local hashValue = 5381

	for charIndex = 1, #seedPlusName do
		hashValue = bit32.band(hashValue * 33 + string.byte(seedPlusName, charIndex), 0xFFFFFFFF)
	end

	return string.format("%08X", hashValue)
end


type pollingEntry = { player: Player?, args: { any } }

type ringBuffer = {
	data: { pollingEntry? },
	head: number,
	tail: number,
	count: number,
	capacity: number,
}

local function createRingBuffer(capacity: number): ringBuffer
	return {
		data = table.create(capacity) :: { pollingEntry? },
		head = 1,
		tail = 0,
		count = 0,
		capacity = capacity,
	}
end

local function ringPush(pollingRingBuffer: ringBuffer, entry: pollingEntry)
	if pollingRingBuffer.count >= pollingRingBuffer.capacity then
		pollingRingBuffer.data[pollingRingBuffer.head] = nil
		pollingRingBuffer.head = (pollingRingBuffer.head % pollingRingBuffer.capacity) + 1
		pollingRingBuffer.count -= 1
	end

	pollingRingBuffer.tail = (pollingRingBuffer.tail % pollingRingBuffer.capacity) + 1
	pollingRingBuffer.data[pollingRingBuffer.tail] = entry
	pollingRingBuffer.count += 1
end

local function ringPop(pollingRingBuffer: ringBuffer): pollingEntry?
	if pollingRingBuffer.count == 0 then
		return nil
	end

	local ringEntry = pollingRingBuffer.data[pollingRingBuffer.head]
	pollingRingBuffer.data[pollingRingBuffer.head] = nil
	pollingRingBuffer.head = (pollingRingBuffer.head % pollingRingBuffer.capacity) + 1
	pollingRingBuffer.count -= 1
	return ringEntry
end


local function createEvent<T...>(name: string, config: eventConfig): event<T...>
	local fieldSchema = config.schema
	local direction = config.direction
	local usePolling = config.polling == true
	local remote = setupEventRemote(hashName(name), config.unreliable == true)
	local checkLimit = createRateLimiter(config.rateLimit, config.debounce)
	local eventCompiledSchema = compileSchema(fieldSchema)
	local eventPollingBuffer = createRingBuffer(MAX_POLLING_BUFFER)

	if usePolling then
		if direction == "toServer" and context == "server" then
			getSignal(remote, "server"):Connect(function(player: Player, packetBuffer: buffer)
				local unpackedArgs = receiveArgs(name, fieldSchema, eventCompiledSchema, checkLimit, packetBuffer, player)

				if unpackedArgs then
					ringPush(eventPollingBuffer, { player = player, args = unpackedArgs })
				end
			end)

		elseif direction == "toClient" and context == "client" then
			getSignal(remote, "client"):Connect(function(packetBuffer: buffer)
				local unpackedArgs = receiveArgs(name, fieldSchema, eventCompiledSchema, checkLimit, packetBuffer, nil)

				if unpackedArgs then
					ringPush(eventPollingBuffer, { player = nil, args = unpackedArgs })
				end
			end)
		end
	end

	return {
		fire = function(_self: event<T...>, ...: T...)
			if direction == "toServer" and context == "server" then
				warn(`[{name}] fire() called on a toServer event from the server; use fireTo or fireList`)
				return
			end

			if direction == "toClient" and context == "client" then
				warn(`[{name}] fire() called on a toClient event from the client; ignored`)
				return
			end

			local packetBuffer = pack(eventCompiledSchema, table.pack(... :: any))

			if context == "client" then
				fireRemote(remote, "server", packetBuffer)
			else
				fireRemote(remote, "all", packetBuffer)
			end
		end:: any,

		fireTo = function(_self: event<T...>, player: Player, ...: T...)
			if context ~= "server" then
				warn(`[{name}] fireTo() may only be called from the server`)
				return
			end

			fireRemote(remote, player, pack(eventCompiledSchema, table.pack(... :: any)))
		end,

		fireList = function(_self: event<T...>, players: { Player }, ...: T...)
			if context ~= "server" then
				warn(`[{name}] fireList() may only be called from the server`)
				return
			end

			local packetBuffer = pack(eventCompiledSchema, table.pack(... :: any))

			for _, player in players do
				fireRemote(remote, player, packetBuffer)
			end
		end,

		on = function(_self: event<T...>, callback: (Player?, T...) -> ()): connection
			if context == "server" then
				return wrapConnection(getSignal(remote, "server"):Connect(function(
					player: Player,
					packetBuffer: buffer
				)
					local unpackedArgs = receiveArgs(name, fieldSchema, eventCompiledSchema, checkLimit, packetBuffer, player)

					if unpackedArgs then
						spawnTask(callback :: (Player?, ...any) -> (), player, table.unpack(unpackedArgs))
					end
				end))
			end

			return wrapConnection(getSignal(remote, "client"):Connect(function(packetBuffer: buffer)
				local unpackedArgs = receiveArgs(name, fieldSchema, eventCompiledSchema, checkLimit, packetBuffer, nil)

				if unpackedArgs then
					spawnTask(callback :: (Player?, ...any) -> (), nil, table.unpack(unpackedArgs))
				end
			end))
		end,

		iterate = function(_self: event<T...>): () -> (number, Player?, T...)
			local iterationIndex = 0

			return function(): (number, Player?, T...)
				local ringEntry = ringPop(eventPollingBuffer)

				if not ringEntry then
					return nil :: any
				end

				iterationIndex += 1
				return iterationIndex, ringEntry.player, table.unpack(ringEntry.args)
			end
		end,
	}
end


local function createRequest<T..., R...>(name: string, config: requestConfig): request<T..., R...>
	local remote: RemoteFunction

	if isServer then
		remote = Instance.new("RemoteFunction")
		remote.Name = hashName(name)
		remote.Parent = remoteFolder
	else
		remote = remoteFolder:WaitForChild(hashName(name), 10) :: RemoteFunction

		if not remote then
			error(`[packet] request '{name}' not found`)
		end
	end

	local fieldSchema = config.schema
	local returnSchema = config.returns
	local timeoutSeconds = config.timeout
	local checkLimit = createRateLimiter(config.rateLimit, config.debounce)
	local compiledArgSchema = compileSchema(fieldSchema)
	local compiledReturnSchema = compileSchema(returnSchema)

	return {
		invoke = function(_self: request<T..., R...>, ...: T...): response<R...>
			local packedArguments = pack(compiledArgSchema, table.pack(... :: any))

			return createResponse(function(): R...
				local responseBuffer = remote:InvokeServer(packedArguments) :: buffer
				local returnedArguments = unpack(compiledReturnSchema, responseBuffer)

				local isSchemaValid, schemaError = validateSchema(name .. ":returns", returnSchema, returnedArguments)

				if not isSchemaValid then
					error(`[packet] invalid response from server: {schemaError}`)
				end

				return table.unpack(returnedArguments)
			end, timeoutSeconds)
		end:: any,

		on = function(_self: request<T..., R...>, callback: (Player, T...) -> R...)
			remote.OnServerInvoke = function(player: Player, packetBuffer: buffer)
				local unpackedArgs = receiveArgs(name, fieldSchema, compiledArgSchema, checkLimit, packetBuffer, player)

				if not unpackedArgs then
					return nil
				end

				local callbackReturnValues = table.pack(callback(player, table.unpack(unpackedArgs)) :: any)
				return pack(compiledReturnSchema, callbackReturnValues) :: any
			end
		end,
	}
end


local function createStruct(definition: { [string]: fieldType }): structDef
	local fields: { { key: string, type: fieldType } } = {}

	for fieldKey, fieldDef in definition do
		table.insert(fields, { key = fieldKey, type = fieldDef })
	end

	table.sort(fields :: any, function(fieldA: any, fieldB: any): boolean
		return (fieldA.key :: string) < (fieldB.key :: string)
	end)

	return { _kind = "struct", fields = fields }
end

local function createArray(element: fieldType): arrayDef
	return { _kind = "array", element = element }
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
	struct = createStruct,
	array = createArray,
	context = context,

	types = table.freeze({
		string = "string" :: packetType,
		number = "number" :: packetType,
		boolean = "boolean" :: packetType,
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
		["function"] = "function" :: packetType,
		["nil"] = "nil" :: packetType,
		thread = "thread" :: packetType,
		userdata = "userdata" :: packetType,
		vector = "vector" :: packetType,
	    variant = "variant" :: packetType,
	}),
})
