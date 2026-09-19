-- Minimal deterministic engine substitute. Real engine layout/permissions need a Roblox client.
local nativeTypeof = typeof
local function typeof(value)
    return if type(value) == "table" and value._type then value._type else nativeTypeof(value)
end
local warnings = {}
local function warn(message)
    table.insert(warnings, message)
end
local shared = {}
local task = {
    cancel = function(thread)
        coroutine.close(thread)
    end,
}
local function enum(names)
    local result = {}
    for _, name in names do
        result[name] = { Name = name }
    end
    return result
end
local Enum = {
    UserInputType = enum({ "MouseButton1", "MouseMovement", "Touch", "Keyboard" }),
    UserInputState = enum({ "Begin", "End", "Change" }),
    KeyCode = enum({ "A", "Unknown" }),
    Font = enum({ "SourceSans", "BuilderSans", "Code" }),
}
local function valueType(tag, fields)
    local mt = {
        __eq = function(a, b)
            for _, field in fields do
                if a[field] ~= b[field] then
                    return false
                end
            end
            return true
        end,
    }
    return function(...)
        local value = { _type = tag }
        for index, field in fields do
            value[field] = select(index, ...)
        end
        return setmetatable(value, mt)
    end,
        mt
end
local colorNew = valueType("Color3", { "R", "G", "B" })
local Color3 = {
    new = colorNew,
    fromRGB = function(r, g, b)
        return colorNew(r / 255, g / 255, b / 255)
    end,
}
local fontNew = valueType("Font", { "Family", "Weight", "Style" })
local Font = {
    new = fontNew,
    fromEnum = function(value)
        return fontNew(value.Name)
    end,
}
local vectorNew, vectorMt = valueType("Vector2", { "X", "Y" })
local Vector2 = { new = vectorNew }
vectorMt.__div = function(v, n)
    return vectorNew(v.X / n, v.Y / n)
end
local dimNew = valueType("UDim2", { "XS", "XO", "YS", "YO" })
local UDim2 = {
    fromScale = function(x, y)
        return dimNew(x, 0, y, 0)
    end,
    fromOffset = function(x, y)
        return dimNew(0, x, 0, y)
    end,
}
local allConnections = {}
local function signal()
    local connections = {}
    local result = {}
    function result:Connect(callback)
        local connection = { Connected = true, _type = "RBXScriptConnection" }
        function connection:Disconnect()
            self.Connected = false
            connections[self] = nil
        end
        connections[connection] = callback
        table.insert(allConnections, connection)
        return connection
    end
    function result:Fire(...)
        local snapshot = table.clone(connections)
        for connection, callback in snapshot do
            if connection.Connected then
                callback(...)
            end
        end
    end
    function result:DisconnectAll()
        for connection in table.clone(connections) do
            connection:Disconnect()
        end
    end
    return result
end
local allInstances = {}
local Instance = {}
local allowed = {
    Name = true,
    Parent = true,
    ResetOnSpawn = true,
    BackgroundTransparency = true,
    BorderSizePixel = true,
    Size = true,
    Scale = true,
    ZIndex = true,
    BackgroundColor3 = true,
}
function Instance.new(className)
    assert(
        ({ ScreenGui = true, Frame = true, UIScale = true, BindableEvent = true, PlayerGui = true })[className],
        "Unknown class"
    )
    local data = { ClassName = className, Name = className, _type = "Instance", Destroying = signal() }
    local attributes, children = {}, {}
    local object
    local methods = {}
    function methods:Destroy()
        if data._destroyed or data._destroying then
            return
        end
        data._destroying = true
        data.Destroying:Fire()
        for child in table.clone(children) do
            child:Destroy()
        end
        self.Parent = nil
        data._destroyed = true
        data.Destroying:DisconnectAll()
        if data.Event then
            data.Event:DisconnectAll()
        end
    end
    function methods:SetAttribute(key, value)
        attributes[key] = value
    end
    function methods:GetAttribute(key)
        return attributes[key]
    end
    function methods:GetChildren()
        local result = {}
        for child in children do
            table.insert(result, child)
        end
        return result
    end
    function methods:Fire(...)
        data.Event:Fire(...)
    end
    if className == "BindableEvent" then
        data.Event = signal()
    end
    object = setmetatable({}, {
        __index = function(_, key)
            if key == "_children" then
                return children
            end
            return methods[key] or data[key]
        end,
        __newindex = function(_, key, value)
            assert(allowed[key], "Invalid property " .. key)
            assert(not data._destroyed, "Instance destroyed")
            if key == "Parent" then
                assert(value == nil or typeof(value) == "Instance", "Invalid parent")
                assert(not value or not value._destroyed, "Parent destroyed")
                if data.Parent then
                    data.Parent._children[object] = nil
                end
                if value then
                    value._children[object] = true
                end
            end
            data[key] = value
        end,
    })
    table.insert(allInstances, object)
    return object
end
local playerGui = Instance.new("PlayerGui")
local inputService = {
    TouchEnabled = false,
    MouseEnabled = true,
    KeyboardEnabled = true,
    InputBegan = signal(),
    InputEnded = signal(),
    WindowFocusReleased = signal(),
    WindowFocused = signal(),
    GetPlatform = function()
        return { Name = "Windows" }
    end,
    IsWindowFocused = function()
        return true
    end,
}
local playersService = { LocalPlayer = {
    FindFirstChildOfClass = function()
        return playerGui
    end,
} }
local runService = {
    IsClient = function()
        return true
    end,
}
local game = {
    GetService = function(_, name)
        return ({ Players = playersService, UserInputService = inputService, RunService = runService })[name]
    end,
}
