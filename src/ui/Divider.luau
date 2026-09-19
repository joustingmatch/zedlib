--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Element = require(script.Parent.Element)
local Controls = require(script.Parent.Controls)

local Divider = {}
Divider.__index = Divider

export type Divider = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Text: string,
        Visible: boolean,

        Holder: Frame,
        Rule: Frame,
        Instance: TextLabel?,
        LayoutHeight: number,

        _Width: number,
    },
    Divider
))

export type Options = { Text: string?, Visible: boolean?, LayoutOrder: number? }

function Divider.Normalise(options: (string | Options)?): Options
    if type(options) == "string" then
        return { Text = options }
    end
    return if options then table.clone(options :: Options) else {}
end

function Divider.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Divider
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)
    local geometry = Metrics.Divider

    local holder = library:Create("Frame", {
        Name = "Divider",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = config.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
    }, resources) :: Frame

    local self: Divider = setmetatable({
        Type = "Divider",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Text = config.Text or "",
        Visible = config.Visible ~= false,

        Holder = holder,
        Rule = nil :: any,
        Instance = nil,
        LayoutHeight = 0,

        _Width = 0,
    }, Divider)

    -- Anchored to the right edge: a caption grows from the left, and the rule
    -- gives up exactly the width the caption took.
    local rule = library:Create("Frame", {
        Name = "Rule",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, geometry.Thickness),
        ZIndex = Materials.Z.Edge,
        Parent = holder,
    }, resources) :: Frame
    library:RegisterProperty(rule, { BackgroundColor3 = "Border.Divider" }, resources)
    self.Rule = rule

    if self.Text ~= "" then
        self.Instance = host.Typography:Create("DividerText", {
            Name = "Caption",
            Text = self.Text,
            Size = UDim2.new(0, 0, 1, 0),
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = Materials.Z.Text,
            Parent = holder,
        }, resources)
    end

    holder.Visible = self.Visible
    holder.Parent = parent
    self:_Layout()

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

-- A captioned divider is a caption followed by the rule filling what is left.
-- The caption's width is measured, not estimated, so the rule starts exactly
-- where the text ends however long the text is.
function Divider._Layout(self: Divider)
    if self.Destroyed then
        return
    end
    local typography = self.Host.Typography
    local geometry = Metrics.Divider
    local caption = self.Instance

    if not caption then
        self.Rule.Size = UDim2.new(1, 0, 0, geometry.Thickness)
        Element.SetHeight(self, geometry.Thickness + geometry.MarginTop + geometry.MarginBottom)
        return
    end

    local role = typography.Roles.DividerText
    local line = typography:LineHeight(role)
    local available = math.max(0, self._Width - geometry.TextGap)
    local width = math.ceil(typography:Measure(self.Text, role).X)
    if available > 0 then
        width = math.min(width, available)
    end

    caption.Size = UDim2.new(0, width, 1, 0)
    self.Rule.Size = UDim2.new(1, -(width + geometry.TextGap), 0, geometry.Thickness)
    Element.SetHeight(self, line + geometry.MarginTop + geometry.MarginBottom)
end

function Divider._OnWidth(self: Divider, width: number)
    if self._Width == width then
        return
    end
    self._Width = width
    if self.Instance then
        self:_Layout()
    end
end

function Divider.SetText(self: Divider, text: string): Divider
    assert(not self.Destroyed, "Divider is destroyed")
    -- A divider created without a caption stays without one: building the label
    -- lazily would mean a second construction path for one rare case.
    local caption = self.Instance
    if caption then
        self.Text = tostring(text)
        caption.Text = self.Text
        self:_Layout()
    end
    return self
end

function Divider.SetVisible(self: Divider, visible: boolean): Divider
    assert(not self.Destroyed, "Divider is destroyed")
    Element.ApplyVisible(self, visible)
    return self
end

function Divider.Destroy(self: Divider)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    Element.Release(self)
    self.Resources:Destroy()
end

return Divider
