--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Typography = require(script.Parent.Typography)
local Popup = require(script.Parent.Popup)

local Controls = {}

--// Host ---------------------------------------------------------------------

export type Focusable = {
    Destroyed: boolean,
    ReleaseFocus: (any) -> (),
}

export type Host = {
    Library: any,
    Resources: Types.Scope,
    Context: Materials.Context,
    Typography: Typography.Typography,
    Popups: Popup.Manager,
    Focused: Focusable?,
    ReleaseFocus: (Host) -> (),
    SetFocused: (Host, Focusable?) -> (),
    -- Called before any control takes over interaction: opening a dropdown or
    -- focusing a field is a single, consistent handover.
    BeginInteraction: (Host, keepFocus: boolean?, source: GuiObject?) -> (),
}

function Controls.NewHost(library: any, scope: Types.Scope, typography: Typography.Typography): Host
    local host: Host

    host = {
        Library = library,
        Resources = scope,
        Context = Materials.NewContext(library, scope),
        Typography = typography,
        Popups = Popup.new(library, scope),
        Focused = nil,

        SetFocused = function(self: Host, control: Focusable?)
            self.Focused = control
            self.Library.FocusedControl = control :: any
        end,

        -- Releasing focus goes through the control, so its own committed-value
        -- and visual-state logic runs instead of being bypassed.
        ReleaseFocus = function(self: Host)
            local control = self.Focused
            if not control then
                return
            end
            self.Focused = nil
            if self.Library.FocusedControl == control then
                self.Library.FocusedControl = nil
            end
            if not control.Destroyed then
                self.Library:SafeCallback(control.ReleaseFocus, control)
            end
        end,

        -- One rule for the whole library: taking interaction closes any open
        -- popup and, unless the caller is the field itself, releases keyboard
        -- focus. Nothing can end up typing into a covered or invisible field.
        BeginInteraction = function(self: Host, keepFocus: boolean?, source: GuiObject?)
            local dynamic: any = self
            if dynamic.Library.CapturingKey then
                dynamic.Library.CapturingKey:CancelCapture()
            end
            local active: any = self.Popups.Active
            local surface = active and (active.Frame or (active._Popup and active._Popup.Instance))
            local current: Instance? = source
            local inside = false
            while current do
                if current == surface then
                    inside = true
                    break
                end
                current = current.Parent
            end
            if not inside then
                self.Popups:CloseActive()
            end
            if not keepFocus then
                self:ReleaseFocus()
            end
        end,
    }

    scope:Add(function()
        host.Focused = nil
        if library.FocusedControl ~= nil then
            library.FocusedControl = nil
        end
    end)

    return host
end

--// Callback lists -----------------------------------------------------------
-- Insertion-ordered, safe against a listener that disconnects during dispatch,
-- and cleared with the control's scope.

export type Signal = {
    Connect: (Signal, callback: (...any) -> ()) -> Types.Cleanup,
    Fire: (Signal, ...any) -> (),
}

function Controls.NewSignal(library: any, scope: Types.Scope): Signal
    local listeners: { (...any) -> () } = {}
    local signal: Signal
    signal = {
        Connect = function(_self: Signal, callback: (...any) -> ()): Types.Cleanup
            assert(type(callback) == "function", "Listener must be a function")
            table.insert(listeners, callback)
            return function()
                local index = table.find(listeners, callback)
                if index then
                    table.remove(listeners, index)
                end
            end
        end,
        Fire = function(_self: Signal, ...: any)
            -- Snapshot: a listener may disconnect itself or another listener.
            for _, callback in table.clone(listeners) do
                library:SafeCallback(callback, ...)
            end
        end,
    }
    scope:Add(function()
        table.clear(listeners)
    end)
    return signal
end

--// Rows ---------------------------------------------------------------------
-- A control row is a label on the left and a fixed-height body on the right,
-- both centred on the row's own centre line; or just the body, filling the row,
-- when there is no label.
--
-- Every row-shaped control in the library goes through here, which is what makes
-- a dropdown field, a text input and an action button land on the same baseline
-- inside the same card and share one row height. A control does not decide how
-- tall its row is -- Metrics.Row does.

export type Row = {
    Frame: Frame,
    Label: TextLabel?,
    BodyOffset: number,
    BodyWidth: number,
    Height: number,
}

function Controls.CreateRow(
    host: Host,
    params: {
        Name: string,
        Text: string?,
        Parent: Instance?,
        Scope: Types.Scope,
        LayoutOrder: number?,
        BodyHeight: number?,
        -- The width the body reserves at the right of the row. The label takes the
        -- rest, less one gap, so the two can never overlap.
        BodyWidth: number?,
        -- A row that owns its own height rather than taking the shared one: a text
        -- area, a colour picker's canvas, anything taller than a single line.
        Height: number?,
    }
): Row
    local library = host.Library
    local typography = host.Typography
    local bodyHeight = params.BodyHeight or Metrics.Control.Height

    local hasLabel = params.Text ~= nil and params.Text ~= ""
    -- A labelled row takes the shared row height so it sits on the card's
    -- rhythm; an unlabelled one is exactly its body.
    local height = params.Height or (if hasLabel then math.max(Metrics.Row.Height, bodyHeight) else bodyHeight)
    local bodyWidth = params.BodyWidth or 0

    local frame = library:Create("Frame", {
        Name = params.Name,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height),
        LayoutOrder = params.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
    }, params.Scope) :: Frame

    local label: TextLabel? = nil
    if hasLabel then
        local line = typography:LineHeight(typography.Roles.ControlLabel)
        label = typography:Create("ControlLabel", {
            Name = "Label",
            Text = params.Text,
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = UDim2.new(1, -(bodyWidth + Metrics.Control.LabelGap), 0, line),
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = Materials.Z.Text,
            Parent = frame,
        }, params.Scope)
    end

    if params.Parent then
        frame.Parent = params.Parent
    end

    -- The body's vertical origin: centred in the row, so a 28 tall field and a
    -- 24 tall action button in adjacent rows share a centre line.
    local bodyOffset = math.floor((height - bodyHeight) / 2)

    return {
        Frame = frame,
        Label = label,
        BodyOffset = bodyOffset,
        BodyWidth = bodyWidth,
        Height = height,
    }
end

--// Chevron ------------------------------------------------------------------
-- Two thin bars meeting at a point. Drawn rather than typed, so it is exactly
-- the configured size at every scale instead of whatever a glyph happens to be,
-- and rotating the container is the whole open/closed animation.

export type Chevron = { Frame: Frame, Bars: { Frame } }

function Controls.CreateChevron(
    host: Host,
    params: {
        Parent: Instance,
        Scope: Types.Scope,
        Token: Types.ThemeRole?,
        -- A chevron centred in its parent and turned a quarter turn is the action
        -- button's glyph. It is the same object as the dropdown's indicator, so the
        -- two are the same weight and the same size wherever they appear together.
        Centred: boolean?,
        Rotation: number?,
    }
): Chevron
    local library = host.Library
    local size = Metrics.Dropdown.ChevronSize
    local thickness = Metrics.Dropdown.ChevronThickness
    local token = params.Token or "Text.Muted"
    local centred = params.Centred == true

    local frame = library:Create("Frame", {
        Name = "Chevron",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Rotation = params.Rotation or 0,
        AnchorPoint = if centred then Vector2.new(0.5, 0.5) else Vector2.new(1, 0.5),
        Position = if centred
            then UDim2.fromScale(0.5, 0.5)
            else UDim2.new(1, -Metrics.Dropdown.ChevronPadding, 0.5, 0),
        Size = UDim2.fromOffset(size, size),
        ZIndex = Materials.Z.Text,
        ClipsDescendants = false,
        Parent = params.Parent,
    }, params.Scope) :: Frame

    local bars: { Frame } = {}
    for index, definition in
        {
            { Name = "Left", X = 0.305, Rotation = 45 },
            { Name = "Right", X = 0.695, Rotation = -45 },
        }
    do
        local bar = library:Create("Frame", {
            Name = definition.Name,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(definition.X, 0.57),
            Size = UDim2.fromOffset(math.round(size * 0.75), thickness),
            Rotation = definition.Rotation,
            ZIndex = Materials.Z.Text,
            Parent = frame,
        }, params.Scope) :: Frame
        library:RegisterProperty(bar, { BackgroundColor3 = token }, params.Scope)
        bars[index] = bar
    end

    return { Frame = frame, Bars = bars }
end

function Controls.SetChevronToken(host: Host, chevron: Chevron, token: Types.ThemeRole, scope: Types.Scope)
    for _, bar in chevron.Bars do
        Materials.BindToken(host.Library, bar, "BackgroundColor3", token, scope)
    end
end

--// Touch targets ------------------------------------------------------------

-- An invisible interaction area over a control that is too thin to hit, returned
-- as the thing to bind input to instead of the visible one.
--
-- It is a child of the target and is full width, so the horizontal arithmetic a
-- drag does against it is identical to the arithmetic against the target. Only
-- the height differs, and the extra height overflows the row rather than
-- displacing anything, because rows do not clip and layout heights are declared
-- by the control rather than measured from its descendants.
--
-- This used to return nil for a mouse, on the reasoning that a mouse can hit
-- fourteen pixels. It can -- but the slider track is FOUR, and a four pixel
-- target is why the sliders felt unresponsive: most of the presses aimed at one
-- landed on the row behind it and did nothing at all. A pointer gets a smaller
-- pad than a finger, not no pad.
--
-- `minimum` overrides the platform floor for a control that knows its own.
function Controls.TouchTarget(host: Host, target: GuiObject, scope: Types.Scope, minimum: number?): GuiObject?
    local library = host.Library
    local floor = minimum or (if library.IsMobile then Metrics.Touch.MinTarget else Metrics.Touch.MinPointerTarget)
    local height = target.Size.Y.Offset
    if height >= floor then
        return nil
    end
    local overhang = (floor - height) / 2
    return library:Create("TextButton", {
        Name = "PointerTarget",
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, -overhang),
        Size = UDim2.new(1, 0, 1, overhang * 2),
        ZIndex = (target.ZIndex or Materials.Z.Structure) + 1,
        Parent = target,
    }, scope) :: GuiObject
end

return Controls
