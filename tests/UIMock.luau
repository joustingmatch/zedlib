local nativeTypeof = typeof
local function typeof(value)
    return if type(value) == "table" and value._type then value._type else nativeTypeof(value)
end

local warnings = {}
local function warn(message)
    table.insert(warnings, message)
end

local shared = {}

--// Scheduler: deterministic, never resumed. A delayed callback is a thread the
-- test can inspect or cancel, so a double-click window cannot expire mid-test.
local scheduled = {}
local task = {
    delay = function(seconds, callback)
        local thread = coroutine.create(callback)
        table.insert(scheduled, { Seconds = seconds, Thread = thread })
        return thread
    end,
    cancel = function(thread)
        coroutine.close(thread)
    end,
    spawn = function(callback, ...)
        local thread = coroutine.create(callback)
        coroutine.resume(thread, ...)
        return thread
    end,
}

local function runScheduled()
    local pending = table.clone(scheduled)
    table.clear(scheduled)
    for _, entry in pending do
        if coroutine.status(entry.Thread) == "suspended" then
            coroutine.resume(entry.Thread)
        end
    end
end

--// Enums. Auto-vivified: a mock that has to list every EnumItem the library
-- might name is a mock that breaks every time a property is added.
local Enum = setmetatable({}, {
    __index = function(self, family)
        local items = setmetatable({}, {
            __index = function(inner, name)
                local item = { Name = name, Value = 0, _type = "EnumItem", Family = family }
                rawset(inner, name, item)
                return item
            end,
        })
        rawset(self, family, items)
        return items
    end,
})

--// Value types
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
    fromHSV = function(h, sat, value)
        local sector = (h % 1) * 6
        local offset = sector % 1
        local p, q, t = value * (1 - sat), value * (1 - sat * offset), value * (1 - sat * (1 - offset))
        local index = math.floor(sector) % 6
        if index == 0 then
            return colorNew(value, t, p)
        end
        if index == 1 then
            return colorNew(q, value, p)
        end
        if index == 2 then
            return colorNew(p, value, t)
        end
        if index == 3 then
            return colorNew(p, q, value)
        end
        if index == 4 then
            return colorNew(t, p, value)
        end
        return colorNew(value, p, q)
    end,
}

local vectorNew, vectorMt = valueType("Vector2", { "X", "Y" })
vectorMt.__add = function(a, b)
    return vectorNew(a.X + b.X, a.Y + b.Y)
end
vectorMt.__sub = function(a, b)
    return vectorNew(a.X - b.X, a.Y - b.Y)
end
vectorMt.__mul = function(a, n)
    return if type(n) == "number" then vectorNew(a.X * n, a.Y * n) else vectorNew(a.X * n.X, a.Y * n.Y)
end
vectorMt.__div = function(a, n)
    return if type(n) == "number" then vectorNew(a.X / n, a.Y / n) else vectorNew(a.X / n.X, a.Y / n.Y)
end
local Vector2 = { new = vectorNew, zero = vectorNew(0, 0) }

local udimNew = valueType("UDim", { "Scale", "Offset" })
local UDim = { new = udimNew }

local dim2New = valueType("UDim2", { "X", "Y" })
local function udim2(xs, xo, ys, yo)
    return dim2New(udimNew(xs, xo), udimNew(ys, yo))
end
local UDim2 = {
    new = udim2,
    fromScale = function(x, y)
        return udim2(x, 0, y, 0)
    end,
    fromOffset = function(x, y)
        return udim2(0, x, 0, y)
    end,
}

local NumberSequence = {
    new = function(...)
        return { ... }
    end,
}
local ColorSequence = {
    new = function(...)
        return { ... }
    end,
}
local ColorSequenceKeypoint = {
    new = function(...)
        return { ... }
    end,
}
local Font = {
    new = function(family, weight, style)
        return { _type = "Font", Family = family, Weight = weight, Style = style }
    end,
    fromEnum = function(item)
        return { _type = "Font", Family = tostring(item.Name), Weight = Enum.FontWeight.Regular }
    end,
}

--// Text measurement. Deterministic and proportional: a character is 0.5 em
-- wide and a line is 1.25 em tall, so wrapping arithmetic is exercised with
-- numbers a test can predict exactly.
local CHAR_WIDTH = 0.5
local LINE_HEIGHT = 1.25

local function measure(text, size, width)
    local characters = utf8.len(text) or #text
    local single = characters * size * CHAR_WIDTH
    if width == nil or width <= 0 or single <= width then
        return vectorNew(single, math.ceil(size * LINE_HEIGHT))
    end
    local lines = math.ceil(single / width)
    return vectorNew(width, math.ceil(size * LINE_HEIGHT) * lines)
end

--// Signals
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
        for connection, callback in table.clone(connections) do
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

local SIGNAL_NAMES = {
    Activated = true,
    SelectionGained = true,
    SelectionLost = true,
    Destroying = true,
    MouseEnter = true,
    MouseLeave = true,
    InputBegan = true,
    InputEnded = true,
    InputChanged = true,
    Focused = true,
    FocusLost = true,
    Event = true,
}

local DEFAULTS = {
    Name = true,
    Text = "",
    PlaceholderText = "",
    Visible = true,
    LayoutOrder = 1,
    ZIndex = 1,
    TextSize = 12,
    TextEditable = true,
    ClassName = true,
}

local allInstances = {}
local Instance = {}

function Instance.new(className)
    local data = {
        ClassName = className,
        Name = className,
        _type = "Instance",
        Text = "",
        PlaceholderText = "",
        Visible = true,
        LayoutOrder = 1,
        ZIndex = 1,
        TextSize = 12,
        TextWrapped = false,
        AbsolutePosition = vectorNew(0, 0),
        AbsoluteSize = vectorNew(0, 0),
        Size = udim2(0, 0, 0, 0),
        Position = udim2(0, 0, 0, 0),
    }
    local children, signals, propertySignals = {}, {}, {}
    local object
    local methods = {}

    local function signalFor(name)
        local existing = signals[name]
        if not existing then
            existing = signal()
            signals[name] = existing
        end
        return existing
    end

    function methods:Destroy()
        if data._destroyed or data._destroying then
            return
        end
        data._destroying = true
        signalFor("Destroying"):Fire()
        for child in table.clone(children) do
            child:Destroy()
        end
        if data.Parent then
            data.Parent._children[object] = nil
            data.Parent = nil
        end
        data._destroyed = true
        for _, each in signals do
            each:DisconnectAll()
        end
    end

    function methods:GetPropertyChangedSignal(property)
        local existing = propertySignals[property]
        if not existing then
            existing = signal()
            propertySignals[property] = existing
        end
        return existing
    end

    function methods:IsA(class)
        if class == "GuiObject" then
            return className == "Frame"
                or className == "ScrollingFrame"
                or className == "TextLabel"
                or className == "TextBox"
                or className == "ScreenGui"
        end
        return className == class
    end

    function methods:GetChildren()
        local result = {}
        for child in children do
            table.insert(result, child)
        end
        return result
    end

    function methods:FindFirstChildOfClass(class)
        for child in children do
            if child.ClassName == class then
                return child
            end
        end
        return nil
    end

    function methods:SetAttribute(key, value)
        data["@" .. key] = value
    end

    function methods:GetAttribute(key)
        return data["@" .. key]
    end

    function methods:CaptureFocus()
        signalFor("Focused"):Fire()
    end

    function methods:ReleaseFocus(enterPressed)
        signalFor("FocusLost"):Fire(enterPressed == true)
    end

    function methods:Fire(...)
        signalFor("Event"):Fire(...)
    end

    object = setmetatable({}, {
        __index = function(_, key)
            if key == "_children" then
                return children
            end
            if SIGNAL_NAMES[key] then
                return signalFor(key)
            end
            if key == "TextBounds" then
                local constraint = if data.TextWrapped then data.Size.X.Offset else nil
                return measure(data.Text, data.TextSize, constraint)
            end
            return methods[key] or data[key]
        end,
        __newindex = function(_, key, value)
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
            local changed = propertySignals[key]
            if changed then
                changed:Fire()
            end
        end,
    })

    table.insert(allInstances, object)
    return object
end

local playerGui = Instance.new("PlayerGui")

local inputService = {
    GetFocusedTextBox = function()
        return nil
    end,
    TouchEnabled = false,
    MouseEnabled = true,
    KeyboardEnabled = true,
    InputBegan = signal(),
    InputEnded = signal(),
    InputChanged = signal(),
    WindowFocusReleased = signal(),
    WindowFocused = signal(),
    GetPlatform = function()
        return { Name = "Windows" }
    end,
    IsWindowFocused = function()
        return true
    end,
}

local textService = {
    GetTextBoundsAsync = function(_, params)
        return measure(params.Text, params.Size, params.Width)
    end,
}

local guiService = {
    GetGuiInset = function()
        return vectorNew(0, 36)
    end,
}

local tweenService = {
    Create = function(_, instance, _info, properties)
        local tween = { _type = "Tween", Instance = instance, Properties = properties }
        function tween:Play()
            -- Applied immediately: the suite asserts settled state, and a mock
            -- that interpolated would only be testing the mock.
            for property, value in properties do
                instance[property] = value
            end
        end
        function tween:Cancel() end
        function tween:Destroy() end
        return tween
    end,
}

local TweenInfo = {
    new = function(...)
        return { _type = "TweenInfo", Arguments = { ... } }
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

local SERVICES = {
    Players = playersService,
    UserInputService = inputService,
    RunService = runService,
    TextService = textService,
    GuiService = guiService,
    TweenService = tweenService,
    HttpService = jsonService,
}

local game = {
    GetService = function(_, name)
        return SERVICES[name]
    end,
}
