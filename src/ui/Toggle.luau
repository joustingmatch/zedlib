--!strict
local ValueControl = require(script.Parent.ValueControl)
local Materials = require(script.Parent.Materials)
local Metrics = require(script.Parent.Metrics)
local Element = require(script.Parent.Element)
local Toggle = {}

function Toggle.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    local self = ValueControl.new(host, parent, config, scope, "Toggle")
    self.Value = config.Default == true
    self.Presentation = config.Presentation or "Switch"
    self.Description = config.Description or ""

    local geometry = Metrics.Toggle
    local switch = self.Presentation == "Switch"
    local width = if switch then geometry.TrackWidth else geometry.TrackHeight
    local height = geometry.TrackHeight
    local knob = geometry.KnobSize
    local inset = geometry.KnobInset

    local surface = Materials.CreateSurface(host.Context, {
        Name = "Track",
        Kind = "Field",
        Parent = self.Holder,
        Scope = self.Resources,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(width, height),
        Radius = if switch then Metrics.Radius.Pill else Metrics.Radius.Small,
        ZIndex = Materials.Z.Structure,
    })
    self.Surface = surface
    self.TrackWidth = width

    self.Mark = host.Library:Create("Frame", {
        Name = "Knob",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.fromOffset(knob, knob),
        Position = UDim2.new(0, inset, 0.5, 0),
        ZIndex = Materials.Z.Edge,
        Parent = surface.Instance,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, if switch then math.floor(knob / 2) else Metrics.Radius.Small),
        Parent = self.Mark,
    }, self.Resources)
    host.Library:RegisterProperty(self.Mark, { BackgroundColor3 = "Text.Primary" }, self.Resources)

    -- The secondary line, when there is one. It is created up front so that
    -- setting a description later never has to rebuild the row.
    self.Descriptor = host.Typography:Create("ControlDescription", {
        Name = "Description",
        Text = self.Description,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Visible = self.Description ~= "",
        ZIndex = Materials.Z.Text,
        Parent = self.Holder,
    }, self.Resources)

    self.Hit = host.Library:Create("TextButton", {
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Text + 1,
        Parent = self.Holder,
    }, self.Resources)

    self.IndicatorWidth = width

    -- The label block is centred as a unit: one line sits on the row's centre
    -- line, two lines straddle it. That is what keeps a row with a description
    -- and a row without one reading as the same rhythm rather than two.
    function self:LayoutText()
        local typography = self.Host.Typography
        local labelLine = typography:LineHeight(typography.Roles.ControlLabel)
        local descLine = typography:LineHeight(typography.Roles.ControlDescription)
        local described = self.Description ~= ""
        local block = labelLine + (if described then Metrics.Row.DescriptionGap + descLine else 0)
        local rowHeight = self.Holder.Size.Y.Offset
        local top = math.floor((rowHeight - block) / 2)

        self.Label.Position = UDim2.fromOffset(0, top)
        self.Label.Size = UDim2.new(1, -self._Reserve, 0, labelLine)
        self.Descriptor.Visible = described
        self.Descriptor.Position = UDim2.fromOffset(0, top + labelLine + Metrics.Row.DescriptionGap)
        self.Descriptor.Size = UDim2.new(1, -self._Reserve, 0, descLine)
    end

    function self:LayoutAddons()
        local reserve = width + Metrics.Spacing.M
        for index = #self.Addons, 1, -1 do
            local addon = self.Addons[index]
            if addon.Visible and not addon.Destroyed then
                local w = if addon.Type == "KeyPicker" then Metrics.Core.KeyWidth else Metrics.Core.ColorWidth
                reserve += w
                addon.Holder.Position = UDim2.new(1, -reserve, 0.5, -Metrics.Control.Height / 2)
                addon.Holder.Size = UDim2.fromOffset(w, Metrics.Control.Height)
                reserve += Metrics.Spacing.S
            end
        end
        self._Reserve = reserve
        self.Hit.Size = UDim2.new(1, 0, 1, 0)
        self:LayoutText()
    end

    function self:SetDescription(text: string)
        assert(not self.Destroyed, "Toggle is destroyed")
        self.Description = tostring(text)
        self.Descriptor.Text = self.Description
        self:_ApplyHeight()
        self:LayoutText()
        return self
    end

    -- A described row is taller by exactly one description line, and the height
    -- is published through Element so the card's arithmetic stays exact.
    function self:_ApplyHeight()
        local typography = self.Host.Typography
        local extra = if self.Description ~= ""
            then Metrics.Row.DescriptionGap + typography:LineHeight(typography.Roles.ControlDescription)
            else 0
        Element.SetHeight(self, Metrics.Row.Height + extra)
    end

    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        local on = self.Value
        self.Mark.Visible = on or self.Presentation == "Switch"
        Materials.Animate(
            self.Host.Context.Animator,
            self.Mark,
            { Position = UDim2.new(0, if switch and on then width - knob - inset else inset, 0.5, 0) },
            Metrics.Motion.Knob,
            -- The knob is an object being pushed from one end of the track to
            -- the other, not a value being reported. It arrives with a trace of
            -- momentum, which is the whole difference between a switch that
            -- feels flicked and one that feels faded.
            "Travel"
        )
        -- The knob is light against a dark track when off, and dark against the
        -- accent when on, so it stays a distinct object in both states.
        self.Host.Library:UnregisterProperty(self.Mark)
        self.Host.Library:RegisterProperty(self.Mark, {
            BackgroundColor3 = if self.Disabled
                then "Text.Disabled"
                elseif on then "Text.OnAccent"
                else "Text.Secondary",
        }, self.Resources)
        self.Host.Library:UnregisterProperty(self.Surface.Instance)
        self.Host.Library:RegisterProperty(self.Surface.Instance, {
            BackgroundColor3 = if on and not self.Disabled then "Accent.Base" else "Surface.Sunken",
        }, self.Resources)
        self.Surface.Instance.BackgroundTransparency = if self.Disabled then 0.5 else 0

        self.Host.Typography:SetRole(
            self.Descriptor,
            if self.Disabled then "ControlDescriptionDisabled" else "ControlDescription",
            self.Resources
        )
    end

    function self:SetValue(value)
        assert(not self.Destroyed, "Toggle is destroyed")
        assert(type(value) == "boolean", "Toggle value must be boolean")
        if value == self.Value then
            return self
        end
        self.Value = value
        self:Refresh()
        self.Changed:Fire(value)
        return self
    end

    self._Reserve = width + Metrics.Spacing.M
    self:BindFace(self.Hit, function()
        host:BeginInteraction()
        self:SetValue(not self.Value)
    end)
    self:_ApplyHeight()
    self:LayoutAddons()
    self:Refresh()
    return self
end

return Toggle
