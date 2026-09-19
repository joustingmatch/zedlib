--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Element = require(script.Parent.Element)
local Controls = require(script.Parent.Controls)

local Label = {}
Label.__index = Label

export type Label = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Text: string,
        Wrap: boolean,
        Secondary: boolean,
        Disabled: boolean,
        Visible: boolean,

        Holder: Frame,
        Instance: TextLabel,
        LayoutHeight: number,

        _Width: number,
    },
    Label
))

export type Options = {
    Text: string?,
    Wrap: boolean?,
    Secondary: boolean?,
    Disabled: boolean?,
    Visible: boolean?,
    LayoutOrder: number?,
    Id: string?,
}

-- AddLabel("text") and AddLabel({ Text = "text" }) are the same call.
function Label.Normalise(options: (string | Options)?): Options
    if type(options) == "string" then
        return { Text = options }
    end
    return if options then table.clone(options :: Options) else {}
end

function Label.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Label
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    local holder = library:Create("Frame", {
        Name = "Label",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = config.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
    }, resources) :: Frame

    local self: Label = setmetatable({
        Type = "Label",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Text = config.Text or "",
        Wrap = config.Wrap == true,
        Secondary = config.Secondary == true,
        Disabled = config.Disabled == true,
        Visible = config.Visible ~= false,

        Holder = holder,
        Instance = nil :: any,
        LayoutHeight = 0,

        _Width = 0,
    }, Label)

    self.Instance = host.Typography:Create(self:_Role(), {
        Name = "Text",
        Text = self.Text,
        Size = UDim2.fromScale(1, 1),
        TextWrapped = self.Wrap,
        TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = if self.Wrap then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = holder,
    }, resources)

    holder.Visible = self.Visible
    holder.Parent = parent
    self:_Measure()

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

function Label._Role(self: Label): string
    if self.Disabled then
        return "LabelDisabled"
    end
    return if self.Secondary then "LabelSecondary" else "Label"
end

-- One measurement path. An unwrapped label is exactly one measured line; a
-- wrapped one is whatever the text needs at the current width, and never less
-- than one line, so an empty string still holds its row open predictably.
function Label._Measure(self: Label)
    if self.Destroyed then
        return
    end
    local typography = self.Host.Typography
    local role = typography.Roles[self:_Role()]
    local line = typography:LineHeight(role)

    local height = line
    if self.Wrap and self._Width > 0 and self.Text ~= "" then
        local measured = typography:Measure(self.Text, role, self._Width).Y
        height = math.max(line, math.ceil(measured) + Metrics.Label.LineGap)
    end
    -- A label is a row in the card, not a bare line of text dropped into one.
    -- Measured at exactly its line height it sits flush against whatever is
    -- above and below it, and two adjacent labels read as one overlapping
    -- string. The padding is inside the row, so the text stays vertically
    -- centred and the hairline between rows still lands at the boundary.
    Element.SetHeight(self, height + Metrics.Label.PaddingY * 2)
end

function Label._OnWidth(self: Label, width: number)
    if self._Width == width then
        return
    end
    self._Width = width
    if self.Wrap then
        self:_Measure()
    end
end

--// Public API ---------------------------------------------------------------

function Label.SetText(self: Label, text: string): Label
    assert(not self.Destroyed, "Label is destroyed")
    local value = tostring(text)
    self.Text = value
    self.Instance.Text = value
    self:_Measure()
    return self
end

function Label.SetWrap(self: Label, wrap: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    local flag = wrap == true
    if self.Wrap == flag then
        return self
    end
    self.Wrap = flag
    self.Instance.TextWrapped = flag
    self.Instance.TextTruncate = if flag then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd
    self:_Measure()
    return self
end

-- A label has no interaction, so "disabled" here means exactly one thing: it is
-- drawn in the disabled text colour. It exists because a label describing a
-- disabled control should be able to dim along with it.
function Label.SetDisabled(self: Label, disabled: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    self.Host.Typography:SetRole(self.Instance, self:_Role(), self.Resources)
    return self
end

-- Moves the label between the primary and secondary text levels. Like
-- SetDisabled this is a rebinding, not a repaint: the role changes, and the
-- registry supplies whatever colour that role resolves to under the current
-- theme. Geometry cannot move, because the two roles share a size and a weight.
function Label.SetSecondary(self: Label, secondary: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    local flag = secondary == true
    if self.Secondary == flag then
        return self
    end
    self.Secondary = flag
    self.Host.Typography:SetRole(self.Instance, self:_Role(), self.Resources)
    return self
end

function Label.SetVisible(self: Label, visible: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    Element.ApplyVisible(self, visible)
    return self
end

function Label.Destroy(self: Label)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    Element.Release(self)
    self.Resources:Destroy()
end

return Label
