--!strict
local ValueControl = require(script.Parent.ValueControl)
local Controls = require(script.Parent.Controls)
local Input = require(script.Parent.Input)
local Element = require(script.Parent.Element)
local Materials = require(script.Parent.Materials)
local Metrics = require(script.Parent.Metrics)
local Slider = {}
local function finite(value: any): boolean
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function Slider.Normalize(value: number, minimum: number, maximum: number, rounding: number): number
    assert(finite(value), "Slider value must be finite")
    local factor = 10 ^ rounding
    return math.clamp(math.round(math.clamp(value, minimum, maximum) * factor) / factor, minimum, maximum)
end
function Slider.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    local minimum, maximum = config.Min or 0, config.Max or 100
    local rounding = config.Rounding or 0
    assert(finite(minimum) and finite(maximum) and minimum <= maximum, "Invalid slider range")
    assert(finite(rounding) and rounding >= 0 and rounding <= 6 and rounding % 1 == 0, "Rounding must be 0..6")
    local initial = Slider.Normalize(config.Default or minimum, minimum, maximum, rounding)
    local self = ValueControl.new(host, parent, config, scope, "Slider")
    self.Min, self.Max, self.Rounding, self.Value = minimum, maximum, rounding, initial
    self.Prefix, self.Suffix = config.Prefix or "", config.Suffix or ""
    local geometry = Metrics.Slider
    local labelLine = host.Typography:LineHeight(host.Typography.Roles.ControlLabel)
    -- The label line is the row's top band; the track sits under it. Both are
    -- placed from the same two numbers, so the row reads as one object rather
    -- than a label with a bar underneath.
    local labelTop = math.floor((Metrics.Row.TallHeight - (labelLine + geometry.LabelGap + geometry.ThumbSize)) / 2)
    local trackY = labelTop + labelLine + geometry.LabelGap + math.floor(geometry.ThumbSize / 2)

    self.Label.Position = UDim2.fromOffset(0, labelTop)
    self.Label.Size = UDim2.new(1, -(geometry.ValuePillWidth + Metrics.Spacing.M), 0, labelLine)

    -- A compact readout pill rather than an editable field on the row. The entry
    -- is still a real text input -- clicking the pill focuses it -- so the
    -- control keeps the typed-value path it already had.
    local pill = Materials.CreateSurface(host.Context, {
        Name = "Value",
        Kind = "Field",
        Parent = self.Holder,
        Scope = self.Resources,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, labelTop + math.floor((labelLine - geometry.ValuePillHeight) / 2)),
        Size = UDim2.fromOffset(geometry.ValuePillWidth, geometry.ValuePillHeight),
        Radius = Metrics.Radius.Small,
        ZIndex = Materials.Z.Structure,
    })
    self.ValuePill = pill

    self.Entry = Input.new(host, pill.Instance, {
        Default = tostring(initial),
        FinishedOnly = true,
        Bare = true,
        Align = Enum.TextXAlignment.Center,
    }, self.Resources)
    self.Entry.Holder.Position = UDim2.fromScale(0, 0)
    self.Entry.Holder.Size = UDim2.fromScale(1, 1)

    self.Track = host.Library:Create("TextButton", {
        Name = "Track",
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0, trackY),
        Size = UDim2.new(1, 0, 0, geometry.TrackThickness),
        ZIndex = Materials.Z.Structure,
        Parent = self.Holder,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(geometry.TrackThickness / 2)),
        Parent = self.Track,
    }, self.Resources)
    host.Library:RegisterProperty(self.Track, { BackgroundColor3 = "Surface.Sunken" }, self.Resources)

    self.Fill = host.Library:Create("Frame", {
        Name = "Fill",
        BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1),
        ZIndex = Materials.Z.Interaction,
        Parent = self.Track,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(geometry.TrackThickness / 2)),
        Parent = self.Fill,
    }, self.Resources)
    host.Library:RegisterProperty(self.Fill, { BackgroundColor3 = "Accent.Base" }, self.Resources)

    -- The thumb rides the fill's right edge. It is anchored on its own centre,
    -- so it stays centred on the track at both ends instead of hanging off them.
    self.Thumb = host.Library:Create("Frame", {
        Name = "Thumb",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(geometry.ThumbSize, geometry.ThumbSize),
        ZIndex = Materials.Z.Edge,
        Parent = self.Track,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(geometry.ThumbSize / 2)),
        Parent = self.Thumb,
    }, self.Resources)
    host.Library:RegisterProperty(self.Thumb, { BackgroundColor3 = "Accent.Base" }, self.Resources)

    Element.SetHeight(self, Metrics.Row.TallHeight)
    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        local alpha = if self.Max == self.Min then 0 else (self.Value - self.Min) / (self.Max - self.Min)
        self.Fill.Size = UDim2.fromScale(alpha, 1)
        self.Fill.BackgroundTransparency = if self.Disabled then 0.6 else 0
        self.Thumb.Position = UDim2.fromScale(alpha, 0.5)
        self.Thumb.BackgroundTransparency = if self.Disabled then 0.6 else 0
        self.Entry:SetDisabled(self.Disabled)
        if not self.Entry.Focused then
            self.Entry:_Push(self.Prefix .. string.format("%." .. self.Rounding .. "f", self.Value) .. self.Suffix)
        end
    end
    function self:SetValue(value)
        assert(not self.Destroyed, "Slider is destroyed")
        local nextValue = Slider.Normalize(value, self.Min, self.Max, self.Rounding)
        local changed = self.Value ~= nextValue
        self.Value = nextValue
        self:Refresh()
        if changed then
            self.Changed:Fire(nextValue)
        end
        return self
    end
    function self:SetMin(value)
        assert(finite(value) and value <= self.Max, "Invalid minimum")
        self.Min = value
        return self:SetValue(self.Value)
    end
    function self:SetMax(value)
        assert(finite(value) and value >= self.Min, "Invalid maximum")
        self.Max = value
        return self:SetValue(self.Value)
    end
    self.Entry:OnChanged(function(text)
        local value = tonumber(text)
        if finite(value) then
            self:SetValue(value)
        else
            self:Refresh()
        end
    end)
    host.Library:Connect(self.Entry.Box.Focused, function()
        self.Entry:_Push(tostring(self.Value))
    end, self.Resources)
    host.Library:Connect(self.Entry.Box.FocusLost, function()
        self:Refresh()
    end, self.Resources)
    -- On a touch device the drag starts from an invisible pad taller than the
    -- track. It is full width, so the position arithmetic is unchanged; only
    -- the region that accepts a finger is larger.
    self.TouchTarget = Controls.TouchTarget(host, self.Track, self.Resources)
    local grip = self.TouchTarget or self.Track
    host.Library:Connect(grip.InputBegan, function(input)
        if self:CanInteract() and host.Library:IsPrimaryPointer(input) then
            host:BeginInteraction()
            self:Drag(self.Track, input, function(x)
                self:SetValue(self.Min + x * (self.Max - self.Min))
            end)
        end
    end, self.Resources)
    host.Library:Connect(self.Track.InputBegan, function(input)
        if not self:CanInteract() then
            return
        end
        local direction = if input.KeyCode == Enum.KeyCode.Left
            then -1
            elseif input.KeyCode == Enum.KeyCode.Right then 1
            else 0
        if direction ~= 0 then
            self:SetValue(self.Value + direction * 10 ^ -self.Rounding)
        end
    end, self.Resources)
    self:Refresh()
    return self
end
return Slider
