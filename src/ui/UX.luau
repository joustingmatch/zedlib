--!strict
local ContextMenu = require(script.Parent.ContextMenu)
local Materials = require(script.Parent.Materials)
local Metrics = require(script.Parent.Metrics)
local Button = require(script.Parent.Button)
local Input = require(script.Parent.Input)
local Popup = require(script.Parent.Popup)
local UX = {}

function UX.Tooltip(control: any, text: string): any
    if control.Tooltip then
        control.Tooltip:Destroy()
    end
    local host, lib = control.Host, control.Host.Library
    local trigger = if typeof(control.Holder) == "Instance" then control.Holder else control.Holder.Instance
    local menu = ContextMenu.new(host, trigger, { Width = Metrics.Core.PopupWidth }, control.Resources)
    local label = host.Typography:Create("ControlLabel", {
        Text = text,
        TextWrapped = true,
        Position = UDim2.fromOffset(Metrics.Spacing.S, Metrics.Spacing.S),
        Size = UDim2.new(1, -Metrics.Spacing.S * 2, 1, -Metrics.Spacing.S * 2),
        Parent = menu.Frame,
    }, menu.Resources)
    local height = host.Typography:Measure(
        text,
        host.Typography.Roles.ControlLabel,
        Metrics.Core.PopupWidth - Metrics.Spacing.S * 2
    ).Y + Metrics.Spacing.S * 2
    menu:SetSize(Metrics.Core.PopupWidth, height)
    local cancel: any = nil
    local function close()
        if cancel then
            cancel()
            cancel = nil
        end
        menu:Close()
    end
    local function schedule()
        close()
        local thread = task.delay(Metrics.Core.TooltipDelay, function()
            cancel = nil
            if
                not control.Destroyed
                and Popup.IsDisplayed(trigger)
                and not lib.ActivePopup
                and not lib.ActiveModal
                and not host.Focused
            then
                menu:Open()
            end
        end)
        cancel = lib:TrackTask(thread, menu.Resources)
    end
    lib:Connect(trigger.MouseEnter, schedule, menu.Resources)
    lib:Connect(trigger.MouseLeave, close, menu.Resources)
    lib:Connect(trigger.SelectionGained, schedule, menu.Resources)
    lib:Connect(trigger.SelectionLost, close, menu.Resources)
    lib:Connect(trigger.InputBegan, close, menu.Resources)
    menu.Resources:Add(close)
    menu.Label = label
    control.Tooltip = menu
    return menu
end

function UX.Notify(host: any, options: any): any
    local config = if type(options) == "string" then { Description = options } else options or {}
    local lib = host.Library
    if not host.Notifications then
        host.Notifications = lib:Create("Frame", {
            Name = "Notifications",
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -Metrics.Spacing.L, 0, Metrics.Spacing.L),
            Size = UDim2.new(0, Metrics.Core.ToastWidth, 1, -Metrics.Spacing.L * 2),
            ZIndex = Materials.Z.Overlay + 2,
            Parent = lib.Overlay,
        }, host.Resources)
        lib:Create("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, Metrics.Popup.ToastGap),
            Parent = host.Notifications,
        }, host.Resources)
    end
    local scope = lib:CreateScope(host.Resources)
    local self: any = { Resources = scope, Destroyed = false }
    self.Surface = Materials.CreateSurface(host.Context, {
        Name = "Notification",
        Kind = "Popup",
        Parent = host.Notifications,
        Scope = scope,
        Size = UDim2.fromOffset(Metrics.Core.ToastWidth, 0),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
    })
    local title = tostring(config.Title or "Notice")
    local description = tostring(config.Description or "")
    local padX, padY = Metrics.Popup.ToastPaddingX, Metrics.Popup.ToastPaddingY
    local width = Metrics.Core.ToastWidth - padX * 2
    local titleHeight =
        host.Typography:Measure(title, host.Typography.Roles.ControlLabel, width - Metrics.Control.Height).Y
    local descHeight = host.Typography:Measure(description, host.Typography.Roles.ControlDescription, width).Y
    self.Surface.Instance.Size =
        UDim2.fromOffset(Metrics.Core.ToastWidth, titleHeight + Metrics.Row.DescriptionGap + descHeight + padY * 2)
    host.Typography:Create("ControlLabel", {
        Text = title,
        TextWrapped = true,
        Position = UDim2.fromOffset(padX, padY),
        Size = UDim2.fromOffset(width - Metrics.Control.Height, titleHeight),
        Parent = self.Surface.Instance,
    }, scope)
    host.Typography:Create("ControlDescription", {
        Text = description,
        TextWrapped = true,
        Position = UDim2.fromOffset(padX, padY + titleHeight + Metrics.Row.DescriptionGap),
        Size = UDim2.fromOffset(width, descHeight),
        Parent = self.Surface.Instance,
    }, scope)
    function self:Destroy()
        if self.Destroyed then
            return
        end
        self.Destroyed = true
        scope:Destroy()
    end
    self.Close = self.Destroy
    local close = Button.new(host, self.Surface.Instance, {
        Text = "×",
        Callback = function()
            self:Destroy()
        end,
    }, scope)
    close.Holder.Position = UDim2.new(1, -Metrics.Control.Height, 0, 0)
    close.Holder.Size = UDim2.fromOffset(Metrics.Control.Height, Metrics.Control.Height)
    scope:Add(function()
        self.Destroyed = true
    end)
    local duration = config.Time or 4
    if config.Persistent ~= true and duration > 0 then
        lib:TrackTask(
            task.delay(duration, function()
                if not self.Destroyed then
                    self:Destroy()
                end
            end),
            scope
        )
    end
    return self
end

function UX.Dialog(window: any, id: string, options: any): any
    window.Dialogs = window.Dialogs or {}
    assert(type(id) == "string" and id ~= "" and not window.Dialogs[id], "Duplicate or empty dialog id")
    local config = options or {}
    local host, lib = window.Host, window.Library
    local scope = lib:CreateScope(window.Resources)
    local self: any = { Resources = scope, Destroyed = false, IsOpen = false }
    self.Blocker = lib:Create("TextButton", {
        Name = "ModalBlocker",
        Text = "",
        AutoButtonColor = false,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 0.35,
        Visible = false,
        Modal = true,
        ZIndex = Materials.Z.Overlay + 5,
        Parent = lib.Overlay,
    }, scope)
    lib:RegisterProperty(self.Blocker, { BackgroundColor3 = "Overlay.Shadow" }, scope)
    self.Surface = Materials.CreateSurface(host.Context, {
        Name = "Dialog",
        Kind = "Popup",
        Parent = self.Blocker,
        Scope = scope,
        Size = UDim2.fromOffset(Metrics.Core.DialogWidth, 0),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
    })
    self.Surface.Instance.AnchorPoint = Vector2.new(0.5, 0.5)
    self.Surface.Instance.Position = UDim2.fromScale(0.5, 0.5)
    local text = tostring(config.Title or "") .. "\n\n" .. tostring(config.Description or "")
    local label = host.Typography:Create("ControlLabel", {
        Text = text,
        TextWrapped = true,
        Position = UDim2.fromOffset(Metrics.Popup.DialogPaddingX, Metrics.Popup.DialogPaddingY),
        Parent = self.Surface.Instance,
    }, scope)
    local buttons = {}
    function self:Close()
        self.IsOpen, self.Blocker.Visible = false, false
        if self.OpenScope then
            self.OpenScope:Destroy()
            self.OpenScope = nil
        end
        if lib.ActiveModal == self then
            lib.ActiveModal = nil
        end
    end
    function self:Open()
        if self.Destroyed or self.IsOpen or not window.HostFrame.Visible then
            return
        end
        host:BeginInteraction()
        if lib.ActiveModal then
            lib.ActiveModal:Close()
        end
        lib.ActiveModal = self
        self.IsOpen, self.Blocker.Visible = true, true
        local openScope = lib:CreateScope(scope)
        self.OpenScope = openScope
        lib:Connect(lib.Runtime.Input.InputBegan, function(input)
            if config.EscapeDismiss ~= false and input.KeyCode == Enum.KeyCode.Escape then
                self:Close()
            end
        end, openScope)
        if config.Time and config.Time > 0 then
            lib:TrackTask(
                task.delay(config.Time, function()
                    self:Close()
                end),
                openScope
            )
        end
    end
    function self:Destroy()
        if self.Destroyed then
            return
        end
        self:Close()
        self.Destroyed = true
        window.Dialogs[id] = nil
        scope:Destroy()
    end
    local definitions = config.FooterButtons or { { Title = "Close" } }
    local ordered = {}
    for key, definition in definitions do
        table.insert(ordered, { Key = key, Definition = definition })
    end
    table.sort(ordered, function(a, b)
        local ao, bo = a.Definition.Order or 0, b.Definition.Order or 0
        return if ao == bo then tostring(a.Key) < tostring(b.Key) else ao < bo
    end)
    for _, entry in ordered do
        local definition = entry.Definition
        local button = Button.new(host, self.Surface.Instance, {
            Text = definition.Title or tostring(entry.Key),
            Risky = definition.Variant == "Destructive",
            Callback = function()
                if definition.Close ~= false then
                    self:Close()
                end
                lib:SafeCallback(definition.Callback)
            end,
        }, scope)
        table.insert(buttons, button)
    end
    -- The footer splits the dialog's inner width at whole pixels, with the
    -- remainder given to the last button, so the row always spans exactly the
    -- content width however many buttons there are.
    local function layout()
        local popup = Metrics.Popup
        local padX, padY, gap = popup.DialogPaddingX, popup.DialogPaddingY, popup.DialogButtonGap
        local available = lib.ScreenGui.AbsoluteSize / lib.DPIScale
        local width = math.max(1, math.min(Metrics.Core.DialogWidth, available.X - padX * 2))
        local inner = math.max(1, width - padX * 2)
        local height = host.Typography:Measure(text, host.Typography.Roles.ControlLabel, inner).Y
        label.Size = UDim2.new(1, -padX * 2, 0, height)
        self.Surface.Instance.Size = UDim2.fromOffset(width, height + padY * 3 + Metrics.Button.Height)

        local count = math.max(1, #buttons)
        local span = inner - gap * (count - 1)
        local each = math.floor(span / count)
        local offset = padX
        for index, button in buttons do
            local w = if index == count then inner - (offset - padX) else each
            button.Holder.Position = UDim2.fromOffset(offset, height + padY * 2)
            button.Holder.Size = UDim2.fromOffset(w, Metrics.Button.Height)
            offset += w + gap
        end
    end
    lib:Connect(lib.ScreenGui:GetPropertyChangedSignal("AbsoluteSize"), layout, scope)
    lib:Connect(self.Blocker.Activated, function(input)
        if
            config.OutsideDismiss == true
            and input
            and not Popup.Contains(self.Surface.Instance, Popup.PointerPoint(input))
        then
            self:Close()
        end
    end, scope)
    scope:Add(function()
        self:Close()
        self.Destroyed = true
        window.Dialogs[id] = nil
    end)
    window.Dialogs[id] = self
    layout()
    return self
end

-- Search walks the navigation as it actually is: sections, then the pages in
-- them, then the cards on a page and the controls in a card. A result's path
-- names every level it needed, and navigating to one opens the section AND the
-- page before it scrolls -- a result on a page that is not open is otherwise a
-- result the user cannot see.
--
-- The page segment is dropped from the path when the section has only the one
-- implicit page, because "Visuals / Visuals / Fields / Live" says nothing the
-- first word did not.
function UX.Search(window: any, query: string): any
    local results = {}
    local needle = string.lower(query)
    if needle == "" then
        return results
    end
    local function walk(container, path, ancestors, tab, page)
        for _, control in container.Elements do
            local label = control.Text or control.Name or ""
            local full = path .. " / " .. label
            local nextAncestors = table.clone(ancestors)
            if control.Elements then
                table.insert(nextAncestors, control)
            end
            if label ~= "" and string.find(string.lower(full), needle, 1, true) then
                local result: any = { Text = full, Control = control, Tab = tab, SubTab = page }
                function result:Navigate()
                    if control.Destroyed or page.Destroyed then
                        return false
                    end
                    window:SelectTab(tab.Name)
                    tab:SelectSubTab(page.Name)
                    for _, ancestor in ancestors do
                        if ancestor.Type == "SubTab" then
                            ancestor:Select()
                        end
                        if ancestor.DependencySatisfied == false or ancestor.RequestedVisible == false then
                            return false
                        end
                    end
                    if not control.Visible then
                        return false
                    end
                    local holder = if typeof(control.Holder) == "Instance"
                        then control.Holder
                        else control.Holder.Instance
                    local view = page.Content
                    local y = (holder.AbsolutePosition.Y - view.AbsolutePosition.Y) / window.Library.DPIScale
                        + view.CanvasPosition.Y
                    view.CanvasPosition = Vector2.new(0, math.max(0, y))
                    return true
                end
                table.insert(results, result)
            end
            if control.Elements then
                walk(control, full, nextAncestors, tab, page)
            end
        end
    end
    for _, tab in window.Tabs do
        for _, page in tab.SubTabs do
            local prefix = if page.Implicit then tab.Name else tab.Name .. " / " .. page.Name
            for _, box in page.Groupboxes do
                walk(box, prefix .. " / " .. box.Name, {}, tab, page)
            end
        end
    end
    return results
end
function UX.SearchBox(window: any, parent: any): any
    local input = parent:AddInput("__search", { Text = "Find controls", FinishedOnly = false })
    local menu = ContextMenu.new(window.Host, input.Holder, {}, input.Resources)
    local resultScope: any = nil
    input:OnChanged(function(query)
        if resultScope then
            resultScope:Destroy()
        end
        resultScope = window.Library:CreateScope(menu.Resources)
        local results = UX.Search(window, query)
        if #results == 0 then
            menu:Close()
            return
        end
        menu:SetSize(Metrics.Core.PopupWidth, math.min(#results, 8) * Metrics.Control.Height)
        for index = 1, math.min(#results, 8) do
            local result = results[index]
            local button = Button.new(window.Host, menu.Frame, {
                Text = result.Text,
                Callback = function()
                    menu:Close()
                    result:Navigate()
                end,
            }, resultScope)
            button.Holder.Position = UDim2.fromOffset(0, (index - 1) * Metrics.Control.Height)
        end
        -- Do not steal typing focus just to display search results.
        menu.IsOpen, menu.Frame.Visible = true, true
        menu:Reposition()
        window.Host.Popups:Open(menu)
    end)
    return input
end
return UX
