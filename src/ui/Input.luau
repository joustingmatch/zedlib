--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Element = require(script.Parent.Element)
local Controls = require(script.Parent.Controls)

local Input = {}
Input.__index = Input

export type Input = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Holder: Frame,
        LayoutHeight: number,

        Text: string,
        Value: string,
        Placeholder: string,

        Focused: boolean,
        Disabled: boolean,
        Visible: boolean,
        Hovered: boolean,

        Numeric: boolean,
        MaxLength: number?,
        FinishedOnly: boolean,

        Row: Controls.Row,
        Field: Materials.Surface,
        Box: TextBox,
        Changed: Controls.Signal,

        _Guard: boolean,
    },
    Input
))

export type Options = {
    Text: string?,
    Default: string?,
    Placeholder: string?,
    Numeric: boolean?,
    MaxLength: number?,
    FinishedOnly: boolean?,
    Disabled: boolean?,
    Visible: boolean?,
    LayoutOrder: number?,
    Callback: ((string) -> ())?,

    -- Presentation. A field is a bordered well by default; a caller that is
    -- already providing the surface -- a slider's value pill, for instance --
    -- overrides the kind, the radius and the padding rather than stacking a
    -- second plate inside the first.
    Kind: string?,
    Radius: number?,
    Align: Enum.TextXAlignment?,
    BodyHeight: number?,
    Padding: number?,
    Width: number?,
    Height: number?,

    -- A multi-line field: a recessed plate spanning the card's content width,
    -- with its own vertical padding and a height stated in lines rather than
    -- pixels, so it scales with the text role instead of drifting from it.
    MultiLine: boolean?,
    Lines: number?,
}

--// Text rules ---------------------------------------------------------------

-- Character-correct truncation. Byte slicing would cut a multi-byte sequence in
-- half and leave the field holding text the engine cannot render.
local function truncate(text: string, maximum: number): string
    local length = utf8.len(text)
    if length == nil or length <= maximum then
        return text
    end
    local offset = utf8.offset(text, maximum + 1)
    if offset == nil then
        return text
    end
    return string.sub(text, 1, offset - 1)
end

-- Keeps only what can still become a number: an optional leading sign, digits,
-- and at most one decimal point. "-" and "." on their own survive, because they
-- are what a half-typed number looks like.
local function numericFilter(text: string): string
    local result = {}
    local seenDot = false
    local index = 0
    for character in string.gmatch(text, ".") do
        index += 1
        if character == "-" then
            if index == 1 then
                table.insert(result, character)
            end
        elseif character == "." then
            if not seenDot then
                seenDot = true
                table.insert(result, character)
            end
        elseif string.match(character, "%d") then
            table.insert(result, character)
        end
    end
    return table.concat(result)
end

--// Construction -------------------------------------------------------------

-- `scope` is the owning container's scope. A control created through a groupbox
-- belongs to that groupbox: destroying the box destroys the field, and the field
-- can still be destroyed on its own without disturbing anything else.
function Input.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Input
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    local maxLength = config.MaxLength
    if maxLength ~= nil then
        assert(type(maxLength) == "number" and maxLength >= 1, "MaxLength must be a positive number")
        maxLength = math.floor(maxLength)
    end

    local self: Input = setmetatable({
        Type = "Input",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Holder = nil :: any,
        LayoutHeight = 0,

        Text = config.Text or "",
        Value = "",
        Placeholder = config.Placeholder or "",

        Focused = false,
        Disabled = config.Disabled == true,
        Visible = config.Visible ~= false,
        Hovered = false,

        Numeric = config.Numeric == true,
        MaxLength = maxLength,
        FinishedOnly = config.FinishedOnly ~= false,

        Row = nil :: any,
        Field = nil :: any,
        Box = nil :: any,
        Changed = Controls.NewSignal(library, resources),

        _Guard = false,
    }, Input)

    self:_Build(parent, config)
    -- The row is the whole flow footprint of this control, label included, and
    -- its height is fixed at construction. The groupbox reads exactly this.
    self.Holder = self.Row.Frame
    self.LayoutHeight = self.Row.Height

    if config.Callback then
        self.Changed:Connect(config.Callback)
    end

    if config.Default ~= nil then
        self.Value = self:_Sanitise(tostring(config.Default))
    end
    self:_Push(self.Value)
    self:_UpdateVisual(0)
    self.Row.Frame.Visible = self.Visible

    -- Runs before the instances are destroyed, so Unload cannot leave the
    -- keyboard attached to a TextBox that is about to stop existing.
    resources:Add(function()
        if self.Focused then
            self.Focused = false
            pcall(function()
                self.Box:ReleaseFocus()
            end)
        end
        if host.Focused == (self :: any) then
            host:SetFocused(nil)
        end
        self.Destroyed = true
    end)

    return self
end

function Input._Build(self: Input, parent: Instance, config: Options)
    local host = self.Host
    local library = host.Library
    local scope = self.Resources
    local geometry = Metrics.Input
    local area = Metrics.TextArea
    local multiLine = config.MultiLine == true
    local lines = math.clamp(config.Lines or area.MinLines, 1, area.MaxLines)
    local textLine = host.Typography:LineHeight(host.Typography.Roles.ControlValue)
    local bodyHeight = config.BodyHeight
        or (
            if multiLine then area.PaddingY * 2 + lines * textLine + (lines - 1) * area.LineSpacing else geometry.Height
        )
    local padding = config.Padding or (if multiLine then area.PaddingX else geometry.HorizontalPadding)

    local row = Controls.CreateRow(host, {
        Name = "Input",
        Text = if self.Text ~= "" and not multiLine then self.Text else nil,
        Parent = parent,
        Scope = scope,
        LayoutOrder = config.LayoutOrder,
        BodyHeight = bodyHeight,
        BodyWidth = if self.Text ~= "" and not multiLine then (config.Width or geometry.FieldWidth) else nil,
        Height = config.Height,
    })
    self.Row = row

    -- A labelled field is a row: label on the left, a recessed plate of a fixed
    -- width on the right. Without a label the plate takes the whole row, which
    -- is what a text area and a bare value pill both want.
    local labelled = self.Text ~= "" and not multiLine
    local fieldWidth = config.Width or geometry.FieldWidth
    local field = Materials.CreateSurface(host.Context, {
        Name = "Field",
        Kind = config.Kind or "Control",
        Parent = row.Frame,
        Scope = scope,
        AnchorPoint = if labelled then Vector2.new(1, 0) else Vector2.zero,
        Position = if labelled then UDim2.new(1, 0, 0, row.BodyOffset) else UDim2.fromOffset(0, row.BodyOffset),
        Size = if labelled then UDim2.fromOffset(fieldWidth, bodyHeight) else UDim2.new(1, 0, 0, bodyHeight),
        Radius = config.Radius or Metrics.Radius.Control,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    self.Field = field

    -- The text area is inset by real geometry, and stops short of both borders,
    -- so the caret and the selection highlight never touch the stroke.
    local box = host.Typography:CreateText("TextBox", "ControlValue", {
        Name = "Box",
        Text = "",
        PlaceholderText = self.Placeholder,
        PlaceholderToken = "Text.Placeholder",
        ClearTextOnFocus = false,
        MultiLine = multiLine,
        TextWrapped = multiLine,
        TextTruncate = if multiLine then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
        TextXAlignment = config.Align or Enum.TextXAlignment.Left,
        TextYAlignment = if multiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
        LineHeight = if multiLine then 1 + area.LineSpacing / textLine else 1,
        Position = UDim2.fromOffset(padding, if multiLine then area.PaddingY else 0),
        Size = UDim2.new(1, -padding * 2, 1, if multiLine then -area.PaddingY * 2 else 0),
        ZIndex = Materials.Z.Text,
        Parent = field.Instance,
    }, scope) :: TextBox
    self.Box = box

    library:Connect(field.Instance.MouseEnter, function()
        self.Hovered = true
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)
    library:Connect(field.Instance.MouseLeave, function()
        self.Hovered = false
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)

    library:Connect(box.Focused, function()
        if self.Disabled or not self.Visible then
            box:ReleaseFocus()
            return
        end
        -- Focusing a field is an interaction handover like any other: any open
        -- popup closes, and any previously focused field commits and releases.
        host:BeginInteraction(true, box)
        if host.Focused ~= nil and host.Focused ~= (self :: any) then
            host:ReleaseFocus()
        end
        self.Focused = true
        host:SetFocused(self :: any)
        self:_UpdateVisual(Metrics.Motion.Focus)
    end, scope)

    library:Connect(box.FocusLost, function(enterPressed: boolean)
        self.Focused = false
        if host.Focused == (self :: any) then
            host:SetFocused(nil)
        end
        self:_Commit()
        self:_UpdateVisual(Metrics.Motion.Focus)
        -- Enter and click-away are the same commit; only the cause differs.
        local _ = enterPressed
    end, scope)

    library:Connect(box:GetPropertyChangedSignal("Text"), function()
        if self._Guard then
            return
        end
        self:_OnTyped()
    end, scope)
end

--// Text handling ------------------------------------------------------------

-- Writes text into the box without the change handler treating it as typing.
function Input._Push(self: Input, text: string)
    if self.Box.Text == text then
        return
    end
    self._Guard = true
    self.Box.Text = text
    self._Guard = false
end

-- Applies the field's rules to live text. Deliberately permissive: this is what
-- the user is allowed to have on screen mid-edit, not what commits.
function Input._Sanitise(self: Input, text: string): string
    local result = text
    if self.Numeric then
        result = numericFilter(result)
    end
    local maximum = self.MaxLength
    if maximum then
        result = truncate(result, maximum)
    end
    return result
end

function Input._OnTyped(self: Input)
    local raw = self.Box.Text
    local sanitised = self:_Sanitise(raw)
    if sanitised ~= raw then
        self:_Push(sanitised)
    end
    if self.FinishedOnly then
        return
    end
    if sanitised == self.Value then
        return
    end
    self.Value = sanitised
    self.Changed:Fire(self.Value)
end

-- Commit validation, which is stricter than live entry: a numeric field that
-- holds only "-" or "." has nothing to commit, so it reverts rather than
-- publishing a value no callback could use.
function Input._Commit(self: Input)
    local candidate = self:_Sanitise(self.Box.Text)
    if self.Numeric and candidate ~= "" and tonumber(candidate) == nil then
        candidate = self.Value
    end
    self:_Push(candidate)
    if candidate == self.Value then
        return
    end
    self.Value = candidate
    self.Changed:Fire(self.Value)
end

--// Visual state -------------------------------------------------------------

function Input._UpdateVisual(self: Input, duration: number)
    if self.Destroyed then
        return
    end
    local context = self.Host.Context

    local fill = if self.Disabled
        then "Disabled"
        elseif self.Focused then "Active"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyState(context, self.Field, fill, duration)

    local border = if self.Disabled
        then "Disabled"
        elseif self.Focused then "Focused"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyBorderState(context, self.Field, border)

    self.Host.Typography:SetRole(
        self.Box,
        if self.Disabled then "ControlValueDisabled" else "ControlValue",
        self.Resources,
        { PlaceholderColor3 = if self.Disabled then "Text.Disabled" else "Text.Placeholder" }
    )
    self.Box.TextEditable = not self.Disabled
end

--// Public API ---------------------------------------------------------------

function Input.SetValue(self: Input, value: string?): Input
    assert(not self.Destroyed, "Input is destroyed")
    local text = self:_Sanitise(if value == nil then "" else tostring(value))
    self:_Push(text)
    if text == self.Value then
        return self
    end
    self.Value = text
    self.Changed:Fire(self.Value)
    return self
end

function Input.SetPlaceholder(self: Input, placeholder: string): Input
    assert(not self.Destroyed, "Input is destroyed")
    self.Placeholder = placeholder
    self.Box.PlaceholderText = placeholder
    return self
end

function Input.SetText(self: Input, text: string): Input
    assert(not self.Destroyed, "Input is destroyed")
    self.Text = text
    local label = self.Row.Label
    if label then
        label.Text = text
    end
    return self
end

function Input.SetDisabled(self: Input, disabled: boolean): Input
    assert(not self.Destroyed, "Input is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
        self:ReleaseFocus()
    end
    local label = self.Row.Label
    if label then
        self.Host.Typography:SetRole(label, if flag then "ControlLabelDisabled" else "ControlLabel", self.Resources)
    end
    self:_UpdateVisual(Metrics.Motion.Hover)
    return self
end

function Input.SetVisible(self: Input, visible: boolean): Input
    assert(not self.Destroyed, "Input is destroyed")
    -- Element.ApplyVisible releases focus through Deactivate below, drops the
    -- row out of the flow, and asks the groupbox to close the gap.
    Element.ApplyVisible(self, visible)
    return self
end

-- Everything transient this field owns. Called when it is hidden, when its
-- groupbox is hidden, and before it is destroyed.
function Input.Deactivate(self: Input)
    self.Hovered = false
    self:ReleaseFocus()
    -- ReleaseFocus only repaints when the field actually held focus, and a
    -- hovered field that is hidden has a hover state to give up either way.
    if not self.Destroyed then
        self:_UpdateVisual(0)
    end
end

function Input.Focus(self: Input): Input
    assert(not self.Destroyed, "Input is destroyed")
    if self.Disabled or not self.Visible then
        return self
    end
    self.Box:CaptureFocus()
    return self
end

-- Safe to call when the field does not have focus, is hidden, or is being torn
-- down: the engine's FocusLost is what actually clears state, and this never
-- assumes it ran.
function Input.ReleaseFocus(self: Input): Input
    if self.Box then
        pcall(function()
            self.Box:ReleaseFocus()
        end)
    end
    if self.Focused then
        self.Focused = false
        if self.Host.Focused == (self :: any) then
            self.Host:SetFocused(nil)
        end
        if not self.Destroyed then
            self:_UpdateVisual(0)
        end
    end
    return self
end

function Input.OnChanged(self: Input, callback: (string) -> ()): Types.Cleanup
    assert(not self.Destroyed, "Input is destroyed")
    return self.Changed:Connect(callback)
end

function Input.Destroy(self: Input)
    if self.Destroyed then
        return
    end
    -- Release before the instances go: a destroyed TextBox that still holds
    -- focus leaves the keyboard attached to nothing.
    self:ReleaseFocus()
    self.Destroyed = true
    if self.Host.Focused == (self :: any) then
        self.Host:SetFocused(nil)
    end
    Element.Release(self)
    self.Resources:Destroy()
end

return Input
