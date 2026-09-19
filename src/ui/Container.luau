--!strict
local Element = require(script.Parent.Element)
local Metrics = require(script.Parent.Metrics)
local Button = require(script.Parent.Button)
local Container = {}
Container.__index = Container
function Container.new(parent: any, kind: string, base: any): any
    local host = parent.Host
    local resources = host.Library:CreateScope(parent.Resources)
    local self: any = setmetatable({
        Host = host,
        Resources = resources,
        Type = kind,
        Elements = {},
        ContentWidth = parent.ContentWidth,
        LayoutHeight = 0,
        Visible = true,
        RequestedVisible = true,
        Destroyed = false,
        Disabled = false,
        _Order = 0,
        Base = base,
        Dependencies = {},
    }, Container)
    for name, method in base do
        self[name] = method
    end
    self.Holder = host.Library:Create("Frame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = parent:_Next(),
        Parent = parent.Container,
    }, resources)
    self.Container = self.Holder
    host.Library:Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, Metrics.Groupbox.ElementSpacing),
        Parent = self.Container,
    }, resources)
    resources:Add(function()
        if not self.Destroyed then
            self:Destroy()
        end
    end)
    return self
end
function Container.Resize(self: any)
    if self.Destroyed or self._Resizing then
        return
    end
    self._Resizing = true
    local height, count = 0, 0
    for _, element in self.Elements do
        if not element.Destroyed and element.Visible then
            Element.ApplyWidth(element, self.ContentWidth)
            height += element.LayoutHeight
            count += 1
        end
    end
    height += math.max(0, count - 1) * Metrics.Groupbox.ElementSpacing
    self._Resizing = false
    Element.SetHeight(self, height)
end
function Container._OnWidth(self: any, width: number)
    self.ContentWidth = width
    self:Resize()
end
function Container.Deactivate(self: any)
    for _, element in self.Elements do
        Element.Deactivate(element)
    end
end
function Container.SetVisible(self: any, visible: boolean): any
    self.RequestedVisible = visible ~= false
    self:Evaluate()
    if self.Tabbox then
        self.Tabbox:EnsureSelection()
    end
    return self
end
function Container.SetDisabled(self: any, disabled: boolean): any
    self.Disabled = disabled == true
    if self.Tabbox then
        self.Tabbox:EnsureSelection()
    end
    return self
end
function Container.Evaluate(self: any)
    if self.Destroyed or self.Resources.Destroyed then
        return
    end
    local enabled = true
    for _, dependency in self.Dependencies do
        local control, expected = dependency[1], dependency[2]
        if control.Destroyed then
            enabled = false
            break
        end
        if type(expected) == "function" then
            local ok, result = pcall(expected, control.Value)
            if not ok or not result then
                enabled = false
                break
            end
        elseif control.Value ~= expected then
            enabled = false
            break
        end
    end
    self.DependencySatisfied = enabled
    Element.ApplyVisible(self, self.RequestedVisible and enabled and (not self.Tabbox or self.Tabbox.ActiveTab == self))
end
function Container.SetupDependencies(self: any, dependencies: any): any
    assert(not self.Destroyed, "Container destroyed")
    for _, dependency in dependencies do
        assert(type(dependency[1].OnChanged) == "function", "Dependency must be a value control")
    end
    if self.DependencyScope then
        self.DependencyScope:Destroy()
    end
    local scope = self.Host.Library:CreateScope(self.Resources)
    self.DependencyScope = scope
    self.Dependencies = {}
    for _, dependency in dependencies do
        table.insert(self.Dependencies, table.clone(dependency))
        scope:Add(dependency[1]:OnChanged(function()
            self:Evaluate()
        end))
        scope:Add(dependency[1].Resources:Add(function()
            self:Evaluate()
        end))
    end
    self:Evaluate()
    return self
end
function Container.Select(self: any)
    if self.Tabbox then
        self.Tabbox:SelectTab(self)
    end
    return self
end
function Container.Destroy(self: any)
    if self.Destroyed then
        return
    end
    self:Deactivate()
    self.Destroyed = true
    for _, element in table.clone(self.Elements) do
        element:Destroy()
    end
    table.clear(self.Elements)
    local tabbox = self.Tabbox
    if tabbox then
        local index = table.find(tabbox.Tabs, self)
        if index then
            table.remove(tabbox.Tabs, index)
        end
        if self.HeaderButton then
            self.HeaderButton:Destroy()
        end
    end
    Element.Release(self)
    self.Resources:Destroy()
    if tabbox and not tabbox.Destroyed then
        tabbox:EnsureSelection()
    end
end

function Container.NewTabbox(parent: any, name: string, base: any): any
    local self = Container.new(parent, "Tabbox", base)
    self.Name, self.Tabs, self.ActiveTab = name, {}, nil
    -- Replace the simple vertical list with a header and active-page slot.
    self.Container = self.Host.Library:Create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, Metrics.Tabs.Height + Metrics.Spacing.S),
        Size = UDim2.new(1, 0, 1, -(Metrics.Tabs.Height + Metrics.Spacing.S)),
        Parent = self.Holder,
    }, self.Resources)
    -- Tabbox holder is manually laid out; no list may reposition its two slots.
    for _, child in self.Holder:GetChildren() do
        if child:IsA("UIListLayout") then
            child:Destroy()
        end
    end
    function self:Resize()
        if self.Destroyed or self._Resizing then
            return
        end
        self._Resizing = true
        local active = self.ActiveTab
        if active then
            Element.ApplyWidth(active, self.ContentWidth)
        end
        local height = Metrics.Tabs.Height + Metrics.Spacing.S + (if active then active.LayoutHeight else 0)
        for index, tab in self.Tabs do
            local width = self.ContentWidth / math.max(1, #self.Tabs)
            tab.HeaderButton.Holder.Position = UDim2.fromOffset((index - 1) * width, 0)
            tab.HeaderButton.Holder.Size = UDim2.fromOffset(width, Metrics.Tabs.Height)
            tab.HeaderButton:SetDisabled(tab.Disabled)
            tab.HeaderButton.Holder.Visible = tab.RequestedVisible
        end
        self._Resizing = false
        Element.SetHeight(self, height)
    end
    function self:SelectTab(tab)
        if type(tab) == "string" then
            local found = nil
            for _, candidate in self.Tabs do
                if candidate.Name == tab then
                    found = candidate
                    break
                end
            end
            tab = found
        end
        if not tab or tab.Destroyed or tab.Disabled or not tab.RequestedVisible then
            return nil
        end
        if self.ActiveTab ~= tab then
            self:Deactivate()
            self.Host:BeginInteraction()
            self.ActiveTab = tab
            for _, page in self.Tabs do
                page:Evaluate()
            end
            self:Resize()
        end
        return tab
    end
    function self:EnsureSelection()
        local active = self.ActiveTab
        if active and not active.Destroyed and active.RequestedVisible and not active.Disabled then
            self:Resize()
            return
        end
        self.ActiveTab = nil
        for _, tab in self.Tabs do
            if tab.RequestedVisible and not tab.Disabled and not tab.Destroyed then
                self:SelectTab(tab)
                return
            end
        end
        for _, tab in self.Tabs do
            tab:Evaluate()
        end
        self:Resize()
    end
    function self:AddTab(text)
        assert(not self.Destroyed, "Tabbox destroyed")
        local page = Container.new(self, "SubTab", base)
        page.Name, page.Tabbox = text, self
        page.HeaderButton = Button.new(self.Host, self.Holder, {
            Text = text,
            Callback = function()
                self:SelectTab(page)
            end,
        }, page.Resources)
        self:_Adopt(page)
        table.insert(self.Tabs, page)
        page:Evaluate()
        self:EnsureSelection()
        return page
    end
    self:Resize()
    return self
end
return Container
