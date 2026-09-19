--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Element = require(script.Parent.Element)
local Controls = require(script.Parent.Controls)

local Button = {}
Button.__index = Button

local Sub = {}
Sub.__index = Sub

-- The interactive part of a button: a surface, a label, and the state that
-- decides how they look. A row holds one or two of these.
type Face = {
    Owner: any,
    Name: string,
    Scope: Types.Scope,

    Text: string,
    ConfirmText: string,
    Disabled: boolean,
    Risky: boolean,
    DoubleClick: boolean,

    Hovered: boolean,
    Pressed: boolean,
    Armed: boolean,

    Surface: Materials.Surface,
    Label: TextLabel,
    Glyph: Controls.Chevron?,
    Changed: Controls.Signal,
    _Disarm: Types.Cleanup?,
}

export type Options = {
    -- When set, the button becomes an action row: this label on the left, and a
    -- compact glyph trigger on the right, rather than a full-width bar.
    Label: string?,
    Text: string?,
    Callback: (() -> ())?,
    Disabled: boolean?,
    Visible: boolean?,
    Risky: boolean?,
    DoubleClick: boolean?,
    ConfirmText: string?,
    LayoutOrder: number?,
    Id: string?,
}

export type SubButton = typeof(setmetatable({} :: { Owner: any, Face: Face }, Sub))

export type Button = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Visible: boolean,
        Holder: Frame,
        Body: Frame,
        Action: boolean,
        Row: Controls.Row?,
        LayoutHeight: number,

        Main: Face,
        Sub: SubButton?,

        _Width: number,
    },
    Button
))

--// Faces --------------------------------------------------------------------

local function faceRole(face: Face): string
    if face.Disabled then
        return "ButtonDisabled"
    end
    return if face.Risky then "ButtonRisky" else "Button"
end

local function faceRefresh(face: Face, duration: number)
    local button = face.Owner :: Button
    if button.Destroyed then
        return
    end
    local context = button.Host.Context

    -- A disabled button has no hover and no pressed state at all: showing one
    -- would promise an interaction that is not going to happen.
    local fill = if face.Disabled
        then "Disabled"
        elseif face.Pressed then "Pressed"
        elseif face.Hovered then "Hover"
        else "Rest"
    Materials.ApplyState(context, face.Surface, fill, duration)

    local border = if face.Disabled
        then "Disabled"
        elseif face.Risky and (face.Hovered or face.Armed) then "Risky"
        elseif face.Hovered or face.Pressed then "Hover"
        else "Rest"
    Materials.ApplyBorderState(context, face.Surface, border)

    button.Host.Typography:SetRole(face.Label, faceRole(face), face.Scope)
end

local function faceDisarm(face: Face, duration: number)
    local dispose = face._Disarm
    face._Disarm = nil
    if dispose then
        dispose()
    end
    if not face.Armed then
        return
    end
    face.Armed = false
    face.Label.Text = face.Text
    faceRefresh(face, duration)
end

-- Arming is bounded in time. A button that was clicked once a minute ago is not
-- half-confirmed; it has forgotten, and says so by returning to its own text.
local function faceArm(face: Face)
    local button = face.Owner :: Button
    local library = button.Host.Library
    faceDisarm(face, 0)
    face.Armed = true
    face.Label.Text = face.ConfirmText
    faceRefresh(face, Metrics.Motion.Hover)

    local thread = task.delay(Metrics.Button.DoubleClickWindow, function()
        if not button.Destroyed and not face.Scope.Destroyed then
            faceDisarm(face, Metrics.Motion.Hover)
        end
    end)
    face._Disarm = library:TrackTask(thread, face.Scope)
end

-- The one activation path. Everything that can press a button ends up here.
local function faceActivate(face: Face)
    local button = face.Owner :: Button
    if button.Destroyed or face.Disabled or not button.Visible then
        return
    end
    if face.DoubleClick and not face.Armed then
        faceArm(face)
        return
    end
    faceDisarm(face, 0)
    -- The button finishes its own state transition before the callback runs, so
    -- a callback that throws cannot leave it armed, pressed or half-hovered.
    face.Changed:Fire()
end

local function createFace(
    button: Button,
    params: {
        Name: string,
        Position: UDim2,
        Size: UDim2,
        Options: Options,
    }
): Face
    local host = button.Host
    local library = host.Library
    local scope = library:CreateScope(button.Resources)
    local config = params.Options

    local action = button.Action
    local surface = Materials.CreateSurface(host.Context, {
        Name = params.Name,
        Kind = if action then "Action" else "Button",
        Parent = button.Body,
        Scope = scope,
        Position = params.Position,
        Size = params.Size,
        Radius = Metrics.Radius.Control,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    surface.Instance.Active = true

    local face: Face = {
        Owner = button,
        Name = params.Name,
        Scope = scope,

        Text = config.Text or "",
        ConfirmText = config.ConfirmText or "Are you sure?",
        Disabled = config.Disabled == true,
        Risky = config.Risky == true,
        DoubleClick = config.DoubleClick == true,

        Hovered = false,
        Pressed = false,
        Armed = false,

        Surface = surface,
        Label = nil :: any,
        Glyph = nil,
        Changed = Controls.NewSignal(library, scope),
        _Disarm = nil,
    }

    -- Centred on both axes, at the shared control text size. A button's label is
    -- not a different typographic class from a dropdown's value.
    face.Label = host.Typography:Create("Button", {
        Name = "Text",
        Text = face.Text,
        Position = UDim2.fromOffset(Metrics.Button.HorizontalPadding, 0),
        Size = UDim2.new(1, -Metrics.Button.HorizontalPadding * 2, 1, 0),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Visible = not action,
        ZIndex = Materials.Z.Text,
        Parent = surface.Instance,
    }, scope)

    -- An action trigger carries a glyph rather than a word: it is 34 wide, and
    -- the row's label to its left already says what it does.
    if action then
        face.Glyph = Controls.CreateChevron(host, {
            Parent = surface.Instance,
            Scope = scope,
            Centred = true,
            Rotation = -90,
            Token = "Text.Primary",
        })
    end

    if config.Callback then
        face.Changed:Connect(config.Callback)
    end

    local frame = surface.Instance
    library:Connect(frame.MouseEnter, function()
        if face.Disabled then
            return
        end
        face.Hovered = true
        faceRefresh(face, Metrics.Motion.Hover)
    end, scope)

    -- Leaving cancels the press. A pointer released outside the control is not
    -- an activation, and the control must not be left looking held down.
    library:Connect(frame.MouseLeave, function()
        face.Hovered = false
        face.Pressed = false
        faceRefresh(face, Metrics.Motion.Hover)
    end, scope)

    library:Connect(frame.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if face.Disabled or not button.Visible then
            return
        end
        -- Pressing a button is an interaction handover like any other: an open
        -- popup closes and a focused field commits before anything happens.
        host:BeginInteraction(false, frame)
        face.Pressed = true
        faceRefresh(face, 0)
    end, scope)

    library:Connect(frame.InputEnded, function(input: InputObject)
        if not library:IsPrimaryPointer(input) then
            return
        end
        local wasPressed = face.Pressed
        face.Pressed = false
        faceRefresh(face, Metrics.Motion.Hover)
        if wasPressed then
            faceActivate(face)
        end
    end, scope)

    faceRefresh(face, 0)
    return face
end

local function faceSetDisabled(face: Face, disabled: boolean)
    local flag = disabled == true
    if face.Disabled == flag then
        return
    end
    face.Disabled = flag
    if flag then
        face.Hovered = false
        face.Pressed = false
        faceDisarm(face, 0)
    end
    faceRefresh(face, Metrics.Motion.Hover)
end

local function faceSetText(face: Face, text: string)
    face.Text = tostring(text)
    -- An armed button is showing its confirmation prompt; the new text becomes
    -- visible when it disarms rather than overwriting the prompt mid-decision.
    if not face.Armed then
        face.Label.Text = face.Text
    end
end

--// Construction -------------------------------------------------------------

function Button.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Button
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    -- Two shapes, one object. Without a label the button is a full-width bar in
    -- its own frame; with one it is a labelled row whose body is a compact
    -- trigger at the right. The faces below are built into Body either way, so
    -- nothing downstream has to know which shape it got.
    local action = config.Label ~= nil and config.Label ~= ""
    local geometry = Metrics.Button
    local holder: Frame
    local body: Frame
    local row: Controls.Row? = nil
    local layoutHeight: number

    if action then
        local created = Controls.CreateRow(host, {
            Name = "Action",
            Text = config.Label,
            Scope = resources,
            LayoutOrder = config.LayoutOrder,
            BodyHeight = geometry.ActionHeight,
            BodyWidth = geometry.ActionWidth,
        })
        row = created
        holder = created.Frame
        layoutHeight = created.Height
        body = library:Create("Frame", {
            Name = "Body",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, 0, 0, created.BodyOffset),
            Size = UDim2.fromOffset(geometry.ActionWidth, geometry.ActionHeight),
            ZIndex = Materials.Z.Structure,
            ClipsDescendants = false,
            Parent = holder,
        }, resources) :: Frame
    else
        holder = library:Create("Frame", {
            Name = "Button",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, geometry.Height),
            LayoutOrder = config.LayoutOrder or 1,
            ZIndex = Materials.Z.Structure,
            ClipsDescendants = false,
        }, resources) :: Frame
        body = holder
        layoutHeight = geometry.Height
    end

    local self: Button = setmetatable({
        Type = "Button",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Visible = config.Visible ~= false,
        Holder = holder,
        Body = body,
        Action = action,
        Row = row,
        LayoutHeight = layoutHeight,

        Main = nil :: any,
        Sub = nil,

        _Width = 0,
    }, Button)

    -- A lone button fills the row: its bounds are the groupbox's content bounds,
    -- so it aligns with every field above and below it without arithmetic.
    self.Main = createFace(self, {
        Name = "Main",
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Options = config,
    })

    holder.Visible = self.Visible
    holder.Parent = parent

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

--// Row layout ---------------------------------------------------------------

-- Two faces split the row at whole pixels, with the remainder given to the main
-- button, so the pair always spans exactly the available width: no 1px seam on
-- odd widths, and no face a pixel wider than its partner by accident.
function Button._Layout(self: Button)
    if self.Destroyed then
        return
    end
    local sub = self.Sub
    if not sub or not sub.Face.Surface.Instance.Visible then
        self.Main.Surface.Instance.Size = UDim2.new(1, 0, 1, 0)
        return
    end

    local gap = Metrics.Button.SubGap
    local width = self._Width
    if width <= 0 then
        -- Width is not known yet (the groupbox publishes it on its first
        -- resize). A scale split is correct to within a pixel until then.
        self.Main.Surface.Instance.Size = UDim2.new(0.5, -gap / 2, 1, 0)
        sub.Face.Surface.Instance.Size = UDim2.new(0.5, -gap / 2, 1, 0)
        return
    end

    local usable = math.max(0, width - gap)
    local subWidth = math.floor(usable / 2)
    local mainWidth = usable - subWidth
    self.Main.Surface.Instance.Size = UDim2.new(0, mainWidth, 1, 0)
    sub.Face.Surface.Instance.Size = UDim2.new(0, subWidth, 1, 0)
end

function Button._OnWidth(self: Button, width: number)
    if self._Width == width then
        return
    end
    self._Width = width
    self:_Layout()
end

--// Public API ---------------------------------------------------------------

function Button.AddButton(self: Button, options: Options?): SubButton
    assert(not self.Destroyed, "Button is destroyed")
    assert(self.Sub == nil, "A button can carry one sub-button")
    local config: Options = if options then table.clone(options) else {}

    local face = createFace(self, {
        Name = "Sub",
        Position = UDim2.new(1, 0, 0, 0),
        Size = UDim2.new(0.5, -Metrics.Button.SubGap / 2, 1, 0),
        Options = config,
    })
    face.Surface.Instance.AnchorPoint = Vector2.new(1, 0)

    local sub: SubButton = setmetatable({ Owner = self, Face = face }, Sub)
    self.Sub = sub
    self:_Layout()
    return sub
end

function Button.SetText(self: Button, text: string): Button
    assert(not self.Destroyed, "Button is destroyed")
    faceSetText(self.Main, text)
    return self
end

function Button.SetDisabled(self: Button, disabled: boolean): Button
    assert(not self.Destroyed, "Button is destroyed")
    faceSetDisabled(self.Main, disabled)
    return self
end

function Button.SetVisible(self: Button, visible: boolean): Button
    assert(not self.Destroyed, "Button is destroyed")
    Element.ApplyVisible(self, visible)
    return self
end

-- Programmatic activation takes exactly the path a click takes, including the
-- disabled check and the double-click state machine.
function Button.Press(self: Button): Button
    assert(not self.Destroyed, "Button is destroyed")
    faceActivate(self.Main)
    return self
end

function Button.OnClick(self: Button, callback: () -> ()): Types.Cleanup
    assert(not self.Destroyed, "Button is destroyed")
    return self.Main.Changed:Connect(callback)
end

-- Hiding, collapsing or destroying the button gives up everything transient it
-- was holding: the hover it will never be told it lost, and any armed prompt.
function Button.Deactivate(self: Button)
    local faces: { Face } = { self.Main }
    local sub = self.Sub
    if sub then
        table.insert(faces, sub.Face)
    end
    for _, face in faces do
        face.Hovered = false
        face.Pressed = false
        faceDisarm(face, 0)
        if not self.Destroyed then
            faceRefresh(face, 0)
        end
    end
end

function Button.Destroy(self: Button)
    if self.Destroyed then
        return
    end
    self:Deactivate()
    self.Destroyed = true
    self.Sub = nil
    Element.Release(self)
    self.Resources:Destroy()
end

--// Sub-buttons --------------------------------------------------------------
-- The same control, sharing the row. It is not an element in its own right: the
-- groupbox owns the row, and the row owns both faces.

function Sub.SetText(self: SubButton, text: string): SubButton
    faceSetText(self.Face, text)
    return self
end

function Sub.SetDisabled(self: SubButton, disabled: boolean): SubButton
    faceSetDisabled(self.Face, disabled)
    return self
end

function Sub.SetVisible(self: SubButton, visible: boolean): SubButton
    local flag = visible ~= false
    self.Face.Surface.Instance.Visible = flag
    if not flag then
        self.Face.Hovered = false
        self.Face.Pressed = false
        faceDisarm(self.Face, 0)
    end -- The main button reclaims the whole row rather than leaving a gap where -- the sub-button used to be.
    (self.Owner :: Button):_Layout()
    return self
end

function Sub.Press(self: SubButton): SubButton
    faceActivate(self.Face)
    return self
end

function Sub.OnClick(self: SubButton, callback: () -> ()): Types.Cleanup
    return self.Face.Changed:Connect(callback)
end

function Sub.Destroy(self: SubButton)
    local owner = self.Owner :: Button
    if owner.Sub == self then
        owner.Sub = nil
    end
    faceDisarm(self.Face, 0)
    self.Face.Scope:Destroy()
    if not owner.Destroyed then
        owner:_Layout()
    end
end

return Button
