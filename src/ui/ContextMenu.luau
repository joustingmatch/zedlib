--!strict
local Popup = require(script.Parent.Popup)
local Materials = require(script.Parent.Materials)
local Metrics = require(script.Parent.Metrics)
local ContextMenu = {}
ContextMenu.__index = ContextMenu
function ContextMenu.new(host: any, trigger: GuiObject, options: any, parentScope: any): any
    local config = options or {}
    local scope = host.Library:CreateScope(parentScope or host.Resources)
    local self: any = setmetatable({
        Host = host,
        Trigger = trigger,
        Resources = scope,
        Width = config.Width or Metrics.Core.PopupWidth,
        Height = config.Height or Metrics.Control.Height,
        IsOpen = false,
        Destroyed = false,
        OnClose = config.OnClose,
    }, ContextMenu)
    self.Surface = Materials.CreateSurface(host.Context, {
        Name = "ContextMenu",
        Kind = "Popup",
        Parent = host.Library.Overlay,
        Scope = scope,
        Size = UDim2.fromOffset(self.Width, self.Height),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
    })
    self.Frame = self.Surface.Instance
    self.Frame.Visible = false
    self.Frame.ClipsDescendants = true
    scope:Add(function()
        self:Close()
        self.Destroyed = true
    end)
    return self
end
function ContextMenu.Reposition(self: any)
    if not self.IsOpen then
        return
    end
    if not Popup.IsDisplayed(self.Trigger) then
        self:Close()
        return
    end
    local placement = Popup.Place(self.Host.Library, self.Trigger, self.Height, self.Width)
    if placement then
        self.Frame.Position, self.Frame.Size = placement.Position, placement.Size
    end
end
function ContextMenu.Open(self: any)
    if self.Destroyed or self.IsOpen or self.Host.Library.ActiveModal or not Popup.IsDisplayed(self.Trigger) then
        return
    end
    self.Host:BeginInteraction()
    self.IsOpen, self.Frame.Visible = true, true
    local lib = self.Host.Library
    lib.OpenedFrames[self.Frame] = true
    local scope = lib:CreateScope(self.Resources)
    self.OpenScope = scope
    for _, prop in { "AbsolutePosition", "AbsoluteSize", "Visible" } do
        lib:Connect(self.Trigger:GetPropertyChangedSignal(prop), function()
            self:Reposition()
        end, scope)
    end
    lib:Connect(lib.ScreenGui:GetPropertyChangedSignal("AbsoluteSize"), function()
        self:Reposition()
    end, scope)
    self:Reposition()
    if self.IsOpen then
        self.Host.Popups:Open(self)
    end
end
function ContextMenu.Close(self: any)
    local wasOpen = self.IsOpen
    self.IsOpen = false
    self.Frame.Visible = false
    self.Host.Library.OpenedFrames[self.Frame] = nil
    self.Host.Popups:Release(self)
    if self.OpenScope then
        self.OpenScope:Destroy()
        self.OpenScope = nil
    end
    if wasOpen and self.OnClose then
        self.Host.Library:SafeCallback(self.OnClose)
    end
end
function ContextMenu.Toggle(self: any)
    if self.IsOpen then
        self:Close()
    else
        self:Open()
    end
end
function ContextMenu.ContainsPoint(self: any, point: Vector2): boolean
    return Popup.Contains(self.Frame, point) or Popup.Contains(self.Trigger, point)
end
function ContextMenu.SetSize(self: any, width: number, height: number)
    assert(width > 0 and height > 0 and width < math.huge and height < math.huge, "Invalid menu size")
    self.Width, self.Height = width, height
    self:Reposition()
end
function ContextMenu.Destroy(self: any)
    if self.Destroyed then
        return
    end
    self:Close()
    self.Destroyed = true
    self.Resources:Destroy()
end
return ContextMenu
