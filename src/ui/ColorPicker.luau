--!strict
local ValueControl = require(script.Parent.ValueControl)
local ContextMenu = require(script.Parent.ContextMenu)
local Controls = require(script.Parent.Controls)
local Input = require(script.Parent.Input)
local Materials = require(script.Parent.Materials)
local Metrics = require(script.Parent.Metrics)
local ColorPicker = {}
local function hsv(color: Color3): (number, number, number)
    local high, low = math.max(color.R, color.G, color.B), math.min(color.R, color.G, color.B)
    local delta, hue = high - low, 0
    if delta > 0 then
        if high == color.R then
            hue = ((color.G - color.B) / delta) % 6
        elseif high == color.G then
            hue = (color.B - color.R) / delta + 2
        else
            hue = (color.R - color.G) / delta + 4
        end
    end
    return hue / 6, if high == 0 then 0 else delta / high, high
end
local function finite(n: any): boolean
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end
function ColorPicker.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    local initial = config.Default or Color3.new(1, 1, 1)
    assert(typeof(initial) == "Color3", "Expected Color3")
    assert(config.Transparency == nil or finite(config.Transparency), "Invalid transparency")
    local self = ValueControl.new(host, parent, config, scope, "ColorPicker")
    self.Value, self.Transparency = initial, math.clamp(config.Transparency or 0, 0, 1)
    self.Hue, self.Saturation, self.Brightness = hsv(initial)
    local lib = host.Library
    self.Label.Size = UDim2.new(1, -Metrics.Core.ColorWidth - Metrics.Spacing.M, 1, 0)
    self.Swatch = lib:Create("TextButton", {
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.fromOffset(Metrics.Core.ColorWidth, Metrics.Control.Height),
        Position = UDim2.new(1, 0, 0.5, 0),
        Parent = self.Holder,
    }, self.Resources)
    -- The swatch wears the shared control radius, so it lines up with the
    -- dropdown field and the key picker shell it sits beside in a mixed row.
    lib:Create("UICorner", { CornerRadius = UDim.new(0, Metrics.Radius.Control), Parent = self.Swatch }, self.Resources)
    self.Menu = ContextMenu.new(host, self.Swatch, {
        Width = Metrics.Core.PopupWidth,
        Height = Metrics.Core.ColorHeight,
        OnClose = function()
            if self._Drag then
                self._Drag:Destroy()
                self._Drag = nil
            end
            if self.Entry then
                self.Entry:ReleaseFocus()
            end
            self.IsOpen = false
        end,
    }, self.Resources)
    local frame, resources = self.Menu.Frame, self.Menu.Resources
    local pad, bar = Metrics.Spacing.S, Metrics.Core.TrackHeight
    local function area(name, y, height)
        return lib:Create("TextButton", {
            Name = name,
            Text = "",
            AutoButtonColor = false,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(pad, y),
            Size = UDim2.new(1, -pad * 2, 0, height),
            Parent = frame,
        }, resources)
    end
    self.SV = area("SaturationValue", pad, Metrics.Core.SVHeight)
    -- HSV gradients are color data, not UI chrome. White/black here define the
    -- color space; borders and selection markers still consume theme roles.
    local white = lib:Create(
        "Frame",
        { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), Parent = self.SV },
        resources
    )
    lib:Create("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = white }, resources)
    local black = lib:Create(
        "Frame",
        { BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0), Size = UDim2.fromScale(1, 1), Parent = self.SV },
        resources
    )
    lib:Create("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = black }, resources)
    self.HueBar = area("Hue", pad * 2 + Metrics.Core.SVHeight, bar)
    self.HueBar.BackgroundColor3 = Color3.new(1, 1, 1)
    local keys = {}
    for i = 0, 6 do
        table.insert(keys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1)))
    end
    lib:Create("UIGradient", { Color = ColorSequence.new(keys), Parent = self.HueBar }, resources)
    self.AlphaBar = area("Transparency", pad * 3 + Metrics.Core.SVHeight + bar, bar)
    lib:Create("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = self.AlphaBar }, resources)
    local function cursor(parentFrame)
        local marker = lib:Create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(Metrics.Core.Cursor, Metrics.Core.Cursor),
            BorderSizePixel = 1,
            ZIndex = Materials.Z.Text,
            Parent = parentFrame,
        }, resources)
        lib:RegisterProperty(marker, { BackgroundColor3 = "Text.Primary", BorderColor3 = "Surface.Canvas" }, resources)
        return marker
    end
    self.SVCursor, self.HueCursor, self.AlphaCursor = cursor(self.SV), cursor(self.HueBar), cursor(self.AlphaBar)
    self.Entry = Input.new(host, frame, { Placeholder = "#RRGGBB", FinishedOnly = true }, resources)
    self.Entry.Holder.Position = UDim2.fromOffset(pad, pad * 4 + Metrics.Core.SVHeight + bar * 2)
    self.Entry.Holder.Size = UDim2.new(1, -pad * 2, 0, Metrics.Control.Height)
    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        self.Swatch.BackgroundColor3, self.Swatch.BackgroundTransparency = self.Value, self.Transparency
        self.SV.BackgroundColor3 = Color3.fromHSV(self.Hue, 1, 1)
        self.AlphaBar.BackgroundColor3 = self.Value
        self.SVCursor.Position = UDim2.fromScale(self.Saturation, 1 - self.Brightness)
        self.HueCursor.Position = UDim2.fromScale(self.Hue, 0.5)
        self.AlphaCursor.Position = UDim2.fromScale(self.Transparency, 0.5)
        if not self.Entry.Focused then
            self.Entry:_Push(
                string.format(
                    "#%02X%02X%02X",
                    math.round(self.Value.R * 255),
                    math.round(self.Value.G * 255),
                    math.round(self.Value.B * 255)
                )
            )
        end
    end
    function self:_Commit(color, transparency, preserveHSV)
        local changed = self.Value ~= color or self.Transparency ~= transparency
        self.Value, self.Transparency = color, transparency
        if not preserveHSV then
            local h, s, v = hsv(color)
            if s > 0 then
                self.Hue = h
            end
            self.Saturation, self.Brightness = s, v
        end
        self:Refresh()
        if changed then
            self.Changed:Fire(color, transparency)
        end
        return self
    end
    function self:SetValue(color)
        assert(not self.Destroyed and typeof(color) == "Color3", "Expected Color3")
        assert(finite(color.R) and finite(color.G) and finite(color.B), "Invalid color")
        return self:_Commit(
            Color3.new(math.clamp(color.R, 0, 1), math.clamp(color.G, 0, 1), math.clamp(color.B, 0, 1)),
            self.Transparency,
            false
        )
    end
    self.SetValueRGB = self.SetValue
    function self:SetTransparency(value)
        assert(not self.Destroyed and finite(value), "Invalid transparency")
        return self:_Commit(self.Value, math.clamp(value, 0, 1), true)
    end
    function self:Open()
        if self:CanInteract() then
            self.Menu:Open()
            self.IsOpen = self.Menu.IsOpen
        end
    end
    function self:Close()
        self.Menu:Close()
        self.IsOpen = false
    end
    function self:Toggle()
        if self.IsOpen then
            self:Close()
        else
            self:Open()
        end
    end
    self:BindFace(self.Swatch, function()
        self:Toggle()
    end)
    -- The hue and alpha bars are fourteen pixels tall, which is fine to look at
    -- and impossible to hit with a thumb. On touch the drag begins from a pad
    -- over the bar; the drag itself still measures against the bar, so the
    -- colour a finger lands on is the colour under it.
    local function bind(target, update)
        local grip = Controls.TouchTarget(host, target, resources) or target
        lib:Connect(grip.InputBegan, function(input)
            if self:CanInteract() then
                self:Drag(target, input, function(x, y)
                    update(x, y)
                    self:_Commit(Color3.fromHSV(self.Hue, self.Saturation, self.Brightness), self.Transparency, true)
                end)
            end
        end, resources)
    end
    bind(self.SV, function(x, y)
        self.Saturation, self.Brightness = x, 1 - y
    end)
    bind(self.HueBar, function(x)
        self.Hue = x
    end)
    local alphaGrip = Controls.TouchTarget(host, self.AlphaBar, resources) or self.AlphaBar
    lib:Connect(alphaGrip.InputBegan, function(input)
        if self:CanInteract() then
            self:Drag(self.AlphaBar, input, function(x)
                self:SetTransparency(x)
            end)
        end
    end, resources)
    self.Entry:OnChanged(function(text)
        local hex = string.match(text, "^#?(%x%x%x%x%x%x)$")
        if hex then
            self:SetValue(
                Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
            )
        end
        self:Refresh()
    end)
    lib:Connect(self.Entry.Box.FocusLost, function()
        self:Refresh()
    end, resources)
    self:Refresh()
    return self
end
return ColorPicker
