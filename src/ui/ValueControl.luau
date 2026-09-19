--!strict
local Controls = require(script.Parent.Controls)
local Element = require(script.Parent.Element)
local Materials = require(script.Parent.Materials)
local Metrics = require(script.Parent.Metrics)
local Popup = require(script.Parent.Popup)
local ValueControl = {}

function ValueControl.new(host: any, parent: Instance, config: any, scope: any, kind: string): any
    local resources = host.Library:CreateScope(scope or host.Resources)
    -- Every value control is a row on the card's rhythm. The control paints its
    -- own body inside that row; it does not decide how tall the row is, which is
    -- what keeps a toggle, a key picker and a colour picker on one grid.
    local row = Controls.CreateRow(host, {
        Name = kind,
        Parent = parent,
        Scope = resources,
        LayoutOrder = config.LayoutOrder,
        BodyHeight = Metrics.Control.Height,
        Height = Metrics.Row.Height,
    })
    local self: any = {
        Type = kind,
        Host = host,
        Resources = resources,
        Holder = row.Frame,
        LayoutHeight = row.Height,
        Visible = config.Visible ~= false,
        Disabled = config.Disabled == true,
        Destroyed = false,
        Text = config.Text or "",
        Addons = {},
        Hovered = false,
        Pressed = false,
    }
    self.Changed = Controls.NewSignal(host.Library, resources)
    self.Destroying = Controls.NewSignal(host.Library, resources)
    for name, method in ValueControl do
        if name ~= "new" then
            self[name] = method
        end
    end
    self.Label = host.Typography:Create("ControlLabel", {
        Text = self.Text,
        Size = UDim2.fromScale(1, 1),
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        ZIndex = Materials.Z.Text,
        Parent = row.Frame,
    }, resources)
    row.Frame.Visible = self.Visible
    if config.Callback then
        self.Changed:Connect(config.Callback)
    end
    resources:Add(function()
        if not self.Destroyed then
            self:Destroy()
        end
    end)
    return self
end

function ValueControl.OnChanged(self: any, callback: any): any
    return self.Changed:Connect(callback)
end
function ValueControl.SetText(self: any, text: string): any
    assert(not self.Destroyed, "Control is destroyed")
    self.Text = tostring(text)
    self.Label.Text = self.Text
    return self
end
function ValueControl.SetVisible(self: any, flag: boolean): any
    if not self.Destroyed then
        Element.ApplyVisible(self, flag)
    end
    if self.AddonOwner then
        self.AddonOwner:LayoutAddons()
    end
    return self
end
function ValueControl.SetDisabled(self: any, flag: boolean): any
    if self.Destroyed then
        return self
    end
    self.Disabled = flag == true
    if self.Disabled then
        self:Deactivate()
    end
    self:Refresh()
    return self
end
function ValueControl.CanInteract(self: any): boolean
    return not self.Destroyed
        and not self.Disabled
        and self.Visible
        and Popup.IsDisplayed(self.Holder)
        and self.Host.Library.ActiveModal == nil
        and (not self.AddonOwner or self.AddonOwner:CanInteract())
end
function ValueControl.Deactivate(self: any)
    self.Pressed, self.Hovered = false, false
    if self._Drag then
        self._Drag:Destroy()
        self._Drag = nil
    end
    if self.Close then
        self:Close()
    end
    if self.CancelCapture then
        self:CancelCapture()
    end
    if self.Entry then
        self.Entry:ReleaseFocus()
    end
    for _, addon in self.Addons do
        addon:Deactivate()
    end
    if self.Tooltip then
        self.Tooltip:Close()
    end
end
function ValueControl.Refresh(self: any)
    if self.Destroyed then
        return
    end
    self.Host.Typography:SetRole(
        self.Label,
        if self.Disabled then "ControlLabelDisabled" else "ControlLabel",
        self.Resources
    )
    if self.Surface then
        Materials.ApplyState(
            self.Host.Context,
            self.Surface,
            if self.Disabled
                then "Disabled"
                elseif self.Pressed then "Pressed"
                elseif self.Hovered then "Hover"
                else "Rest",
            0
        )
        Materials.ApplyBorderState(
            self.Host.Context,
            self.Surface,
            if self.Disabled then "Disabled" elseif self.Hovered then "Hover" else "Rest"
        )
    end
end
function ValueControl.Destroy(self: any)
    if self.Destroyed then
        return
    end
    self:Deactivate()
    self.Destroying:Fire()
    self.Destroyed = true
    for _, addon in table.clone(self.Addons) do
        addon:Destroy()
    end
    table.clear(self.Addons)
    if self.AddonOwner then
        local owner = self.AddonOwner
        local index = table.find(owner.Addons, self)
        if index then
            table.remove(owner.Addons, index)
        end
        self.AddonOwner = nil
        if owner.LayoutAddons then
            owner:LayoutAddons()
        end
    end
    Element.Release(self)
    self.Resources:Destroy()
end

function ValueControl.BindFace(self: any, frame: GuiObject, activate: any)
    local lib = self.Host.Library
    lib:Connect(frame.MouseEnter, function()
        self.Hovered = true
        self:Refresh()
    end, self.Resources)
    lib:Connect(frame.MouseLeave, function()
        self.Hovered = false
        self.Pressed = false
        self:Refresh()
    end, self.Resources)
    lib:Connect(frame.InputBegan, function(input)
        if self:CanInteract() and lib:IsPrimaryPointer(input) then
            self.Pressed = true
            self:Refresh()
        end
    end, self.Resources)
    lib:Connect(frame.InputEnded, function()
        self.Pressed = false
        self:Refresh()
    end, self.Resources)
    lib:Connect((frame :: any).Activated, function()
        if self:CanInteract() then
            self.Pressed = false
            activate()
            self:Refresh()
        end
    end, self.Resources)
end

-- Pointer sessions exist only during a drag. Absolute rectangles are read for
-- every update, so moving a window or changing DPI cannot stale the math.
function ValueControl.Drag(self: any, frame: GuiObject, input: InputObject, update: any)
    local lib = self.Host.Library
    if not self:CanInteract() or not lib:IsPrimaryPointer(input) then
        return
    end
    if self._Drag then
        self._Drag:Destroy()
    end
    local scope = lib:CreateScope(self.Resources)
    self._Drag = scope
    scope:Add(function()
        if self._Drag == scope then
            self._Drag = nil
        end
    end)
    local function move(event)
        local point = Popup.PointerPoint(event) - frame.AbsolutePosition
        local size = frame.AbsoluteSize
        if size.X > 0 and size.Y > 0 then
            update(math.clamp(point.X / size.X, 0, 1), math.clamp(point.Y / size.Y, 0, 1))
        end
    end
    local runtime = lib.Runtime.Input
    lib:Connect(runtime.InputChanged, function(event)
        if
            (input.UserInputType == Enum.UserInputType.Touch and event == input)
            or (
                input.UserInputType ~= Enum.UserInputType.Touch
                and event.UserInputType == Enum.UserInputType.MouseMovement
            )
        then
            move(event)
        end
    end, scope)
    lib:Connect(runtime.InputEnded, function(event)
        if
            event == input
            or (input.UserInputType ~= Enum.UserInputType.Touch and event.UserInputType == input.UserInputType)
        then
            scope:Destroy()
        end
    end, scope)
    lib:Connect(runtime.WindowFocusReleased, function()
        scope:Destroy()
    end, scope)
    move(input)
end
return ValueControl
