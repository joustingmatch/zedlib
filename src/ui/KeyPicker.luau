--!strict
local ValueControl = require(script.Parent.ValueControl)
local Controls = require(script.Parent.Controls)
local ContextMenu = require(script.Parent.ContextMenu)
local Button = require(script.Parent.Button)
local Metrics = require(script.Parent.Metrics)
local KeyPicker = {}
local modes = { "Toggle", "Hold", "Press", "Always" }
local mouse = { MouseButton1 = true, MouseButton2 = true, MouseButton3 = true }
local readable =
    { MouseButton1 = "LMB", MouseButton2 = "RMB", MouseButton3 = "MMB", RightShift = "RShift", LeftShift = "LShift" }
local function valid(key: any): boolean
    if type(key) ~= "string" then
        return false
    end
    if key == "None" or mouse[key] then
        return true
    end
    local ok, item = pcall(function()
        return Enum.KeyCode[key]
    end)
    return ok and item ~= nil and key ~= "Unknown"
end
local function inputKey(input: InputObject): string?
    if input.UserInputType == Enum.UserInputType.Keyboard then
        return input.KeyCode.Name
    end
    if mouse[input.UserInputType.Name] then
        return input.UserInputType.Name
    end
    return nil
end
-- One dispatcher per host. Capture is library-wide and consumes the event
-- before any normal binding or window toggle can see it.
function KeyPicker.Manager(host: any): any
    if host.Keybinds then
        return host.Keybinds
    end
    local lib = host.Library
    local manager: any = { Items = {}, Changed = Controls.NewSignal(lib, host.Resources) }
    host.Keybinds = manager
    function manager:Reset()
        for _, picker in table.clone(self.Items) do
            picker._Down = false
            if picker.Mode == "Hold" then
                picker:SetActive(false)
            end
        end
        if lib.CapturingKey and lib.CapturingKey.Host == host then
            lib.CapturingKey:CancelCapture()
        end
    end
    lib:Connect(lib.Runtime.Input.InputBegan, function(input, processed)
        local key = inputKey(input)
        local capture = lib.CapturingKey
        if capture then
            if capture.Host ~= host then
                return
            end
            if key == "Escape" then
                capture:CancelCapture()
            elseif key and valid(key) then
                capture:CancelCapture()
                capture:SetValue(key)
            end
            return
        end
        if processed or lib.ActiveModal or lib.Runtime.Input:GetFocusedTextBox() then
            return
        end
        for _, picker in table.clone(manager.Items) do
            if
                not picker.Destroyed
                and not picker.Disabled
                and picker.Value == key
                and not picker._Down
                and (not picker.AddonOwner or not picker.AddonOwner.Disabled)
            then
                picker._Down = true
                if picker.Mode == "Toggle" then
                    picker:SetActive(not picker.Active)
                elseif picker.Mode == "Hold" then
                    picker:SetActive(true)
                elseif picker.Mode == "Press" then
                    picker.Activated:Fire(true)
                end
            end
        end
        if key == host.ToggleKey and host.Window and not host.Window.Destroyed then
            host.Window:Toggle()
        end
    end, host.Resources)
    lib:Connect(lib.Runtime.Input.InputEnded, function(input)
        local key = inputKey(input)
        for _, picker in table.clone(manager.Items) do
            if picker.Value == key then
                picker._Down = false
                if picker.Mode == "Hold" then
                    picker:SetActive(false)
                end
            end
        end
    end, host.Resources)
    lib:Connect(lib.Runtime.Input.WindowFocusReleased, function()
        manager:Reset()
    end, host.Resources)
    host.Resources:Add(function()
        manager:Reset()
        table.clear(manager.Items)
    end)
    return manager
end
function KeyPicker.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    assert(valid(config.Default or "None"), "Invalid binding")
    assert(table.find(modes, config.Mode or "Toggle"), "Invalid binding mode")
    local self = ValueControl.new(host, parent, config, scope, "KeyPicker")
    self.Value, self.Mode = config.Default or "None", config.Mode or "Toggle"
    self.Active, self.Capturing, self._Down = self.Mode == "Always", false, false
    self.Activated = Controls.NewSignal(host.Library, self.Resources)
    if config.OnActivated then
        self.Activated:Connect(config.OnActivated)
    end
    self.Label.Size = UDim2.new(1, -Metrics.Core.KeyWidth - Metrics.Spacing.S, 1, 0)
    self.Key = Button.new(host, self.Holder, { Text = "" }, self.Resources)
    self.Key.Holder.AnchorPoint = Vector2.new(1, 0.5)
    self.Key.Holder.Position = UDim2.new(1, 0, 0.5, 0)
    self.Key.Holder.Size = UDim2.fromOffset(Metrics.Core.KeyWidth, Metrics.Control.Height)
    self.Key.Holder.Position = UDim2.new(1, -Metrics.Core.KeyWidth, 0, 0)
    local manager = KeyPicker.Manager(host)
    table.insert(manager.Items, self)
    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        self.Key:SetText(if self.Capturing then "…" else readable[self.Value] or self.Value)
        self.Key:SetDisabled(self.Disabled)
    end
    function self:SetActive(flag)
        flag = if self.Mode == "Always" then true else flag == true
        if self.Active == flag then
            return
        end
        self.Active = flag
        self.Activated:Fire(flag)
        manager.Changed:Fire()
    end
    function self:SetValue(value)
        assert(not self.Destroyed and valid(value), "Invalid binding")
        if self.Value == value then
            return self
        end
        self.Value, self._Down = value, false
        self:SetActive(false)
        self:Refresh()
        self.Changed:Fire(value, self.Mode)
        manager.Changed:Fire()
        return self
    end
    function self:SetMode(mode)
        assert(not self.Destroyed and table.find(modes, mode), "Invalid binding mode")
        if self.Mode == mode then
            return self
        end
        self.Mode, self._Down = mode, false
        self:SetActive(mode == "Always")
        self.Changed:Fire(self.Value, mode)
        manager.Changed:Fire()
        return self
    end
    function self:Capture()
        if not self:CanInteract() then
            return
        end
        host:BeginInteraction()
        local old = host.Library.CapturingKey
        if old then
            old:CancelCapture()
        end
        manager:Reset()
        host.Library.CapturingKey, self.Capturing = self, true
        self:Refresh()
    end
    function self:CancelCapture()
        self.Capturing = false
        if host.Library.CapturingKey == self then
            host.Library.CapturingKey = nil
        end
        self:Refresh()
    end
    function self:OnActivated(callback)
        return self.Activated:Connect(callback)
    end
    self.Menu = ContextMenu.new(
        host,
        self.Key.Holder,
        { Width = Metrics.Core.KeyWidth, Height = #modes * Metrics.Control.Height },
        self.Resources
    )
    for index, mode in modes do
        local button = Button.new(host, self.Menu.Frame, {
            Text = mode,
            Callback = function()
                self:SetMode(mode)
                self.Menu:Close()
            end,
        }, self.Menu.Resources)
        button.Holder.Position = UDim2.fromOffset(0, (index - 1) * Metrics.Control.Height)
    end
    function self:Close()
        self.Menu:Close()
    end
    self.Key:OnClick(function()
        self:Capture()
    end)
    host.Library:Connect(self.Key.Holder.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 and self:CanInteract() then
            self.Menu:Toggle()
        end
    end, self.Resources)
    self.Resources:Add(function()
        if host.Library.CapturingKey == self then
            host.Library.CapturingKey = nil
        end
        local index = table.find(manager.Items, self)
        if index then
            table.remove(manager.Items, index)
        end
        manager.Changed:Fire()
    end)
    self:Refresh()
    manager.Changed:Fire()
    return self
end
return KeyPicker
