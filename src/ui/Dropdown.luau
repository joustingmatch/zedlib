--!strict
local Types = require(script.Parent.Parent.Types)
local Theme = require(script.Parent.Parent.core.Theme)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Element = require(script.Parent.Element)
local Controls = require(script.Parent.Controls)
local Popup = require(script.Parent.Popup)

local Dropdown = {}
Dropdown.__index = Dropdown

type Item = {
    Value: string,
    Surface: Materials.Surface,
    Label: TextLabel,
    Marker: Frame,
    Scope: Types.Scope,
    Hovered: boolean,
    Disabled: boolean,
    Visible: boolean,
}

export type Dropdown = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Holder: Frame,
        LayoutHeight: number,

        Text: string,
        Placeholder: string,
        Values: { string },
        DisabledValues: { [string]: boolean },
        Value: any,

        Multi: boolean,
        AllowNull: boolean,
        Searchable: boolean,
        MaxDisplay: number,

        IsOpen: boolean,
        Disabled: boolean,
        Visible: boolean,
        Hovered: boolean,

        Row: Controls.Row,
        Trigger: Materials.Surface,
        ValueLabel: TextLabel,
        Chevron: Controls.Chevron,

        Changed: Controls.Signal,

        _Selected: { [string]: boolean },
        _Items: { Item },
        _ItemScope: Types.Scope?,
        _Popup: Materials.Surface?,
        _Scroll: ScrollingFrame?,
        _List: Frame?,
        _Search: TextBox?,
        _Empty: TextLabel?,
        _Filter: string,
        _VisibleCount: number,
        _Dirty: boolean,
        _OpenScope: Types.Scope?,
        _PopupHovered: (() -> boolean)?,
    },
    Dropdown
))

export type Options = {
    Width: number?,
    Text: string?,
    Placeholder: string?,
    Values: { string }?,
    Default: any?,
    DisabledValues: { [string]: boolean }?,
    Multi: boolean?,
    AllowNull: boolean?,
    Searchable: boolean?,
    MaxDisplay: number?,
    Disabled: boolean?,
    Visible: boolean?,
    LayoutOrder: number?,
    Callback: ((any) -> ())?,
}

--// Helpers ------------------------------------------------------------------

local function copyValues(values: { string }?): { string }
    local result: { string } = {}
    if values then
        for _, value in values do
            if type(value) == "string" then
                table.insert(result, value)
            end
        end
    end
    return result
end

local function contains(values: { string }, value: string): boolean
    return table.find(values, value) ~= nil
end

--// Construction -------------------------------------------------------------

-- `scope` is the owning container's scope. The trigger belongs to the groupbox;
-- the popup does not, and never will. See _EnsurePopup: the popup is built in
-- the library's overlay layer, and the groupbox owns the dropdown object rather
-- than the popup's instances.
function Dropdown.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Dropdown
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    local self: Dropdown = setmetatable({
        Type = "Dropdown",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Holder = nil :: any,
        LayoutHeight = 0,

        Text = config.Text or "",
        Placeholder = config.Placeholder or "None",
        Values = copyValues(config.Values),
        DisabledValues = if config.DisabledValues then table.clone(config.DisabledValues) else {},
        Value = if config.Multi then {} else nil,

        Multi = config.Multi == true,
        AllowNull = config.AllowNull == true,
        Searchable = config.Searchable == true,
        MaxDisplay = math.max(1, config.MaxDisplay or 2),

        IsOpen = false,
        Disabled = config.Disabled == true,
        Visible = config.Visible ~= false,
        Hovered = false,

        Row = nil :: any,
        Trigger = nil :: any,
        ValueLabel = nil :: any,
        Chevron = nil :: any,

        Changed = Controls.NewSignal(library, resources),

        _Selected = {},
        _Items = {},
        _ItemScope = nil,
        _Popup = nil,
        _Scroll = nil,
        _List = nil,
        _Search = nil,
        _Empty = nil,
        _Filter = "",
        _VisibleCount = 0,
        _Dirty = true,
        _OpenScope = nil,
        _PopupHovered = nil,
    }, Dropdown)

    self:_Build(parent, config)
    -- The trigger row is the dropdown's entire flow footprint. Opening the
    -- popup does not change it, because the popup is not in the flow at all.
    self.Holder = self.Row.Frame
    self.LayoutHeight = self.Row.Height

    if config.Callback then
        self.Changed:Connect(config.Callback)
    end

    -- Default selection is applied through the same validation path as any later
    -- assignment, so an invalid default cannot create an impossible state.
    if config.Default ~= nil then
        self:_Assign(config.Default, true)
    elseif not self.Multi and not self.AllowNull then
        self:_Assign(self:_FirstSelectable(), false)
    end

    self:_UpdateDisplay()
    self:_UpdateVisual(0)
    self.Row.Frame.Visible = self.Visible

    -- Runs before the instances are destroyed. Destroy() does this explicitly,
    -- but a scope teardown (Unload, a destroyed tab, a destroyed groupbox) does
    -- not go through Destroy, and an open dropdown must not leave its popup
    -- registered in OpenedFrames or owned by the popup manager either way.
    resources:Add(function()
        self.Destroyed = true
        local popup = self._Popup
        if popup then
            library.OpenedFrames[popup.Instance] = nil
        end
        self.IsOpen = false
        host.Popups:Release(self :: any)
    end)

    return self
end

function Dropdown._Build(self: Dropdown, parent: Instance, config: Options)
    local host = self.Host
    local scope = self.Resources

    local row = Controls.CreateRow(host, {
        Name = "Dropdown",
        Text = if self.Text ~= "" then self.Text else nil,
        Parent = parent,
        Scope = scope,
        LayoutOrder = config.LayoutOrder,
        BodyHeight = Metrics.Dropdown.Height,
        BodyWidth = if self.Text ~= "" then (config.Width or Metrics.Dropdown.FieldWidth) else nil,
    })
    self.Row = row

    -- The field is a recessed plate at the right of the row when the dropdown
    -- carries a label, and the full row when it does not.
    local labelled = self.Text ~= ""
    local trigger = Materials.CreateSurface(host.Context, {
        Name = "Trigger",
        Kind = "Field",
        Parent = row.Frame,
        Scope = scope,
        AnchorPoint = if labelled then Vector2.new(1, 0) else Vector2.zero,
        Position = if labelled then UDim2.new(1, 0, 0, row.BodyOffset) else UDim2.fromOffset(0, row.BodyOffset),
        Size = if labelled
            then UDim2.fromOffset(row.BodyWidth, Metrics.Dropdown.Height)
            else UDim2.new(1, 0, 0, Metrics.Dropdown.Height),
        Radius = Metrics.Radius.Control,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    trigger.Instance.Active = true
    self.Trigger = trigger

    -- The value label's right edge stops short of the chevron's reserved column,
    -- so a long value truncates instead of running under the indicator.
    local chevronColumn = Metrics.Dropdown.ChevronPadding + Metrics.Dropdown.ChevronSize + 6
    self.ValueLabel = host.Typography:Create("ControlValue", {
        Name = "Value",
        Text = "",
        Position = UDim2.fromOffset(Metrics.Dropdown.HorizontalPadding, 0),
        Size = UDim2.new(1, -(Metrics.Dropdown.HorizontalPadding + chevronColumn), 1, 0),
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = trigger.Instance,
    }, scope)

    self.Chevron = Controls.CreateChevron(host, {
        Parent = trigger.Instance,
        Scope = scope,
    })

    self:_BindTrigger()
end

function Dropdown._BindTrigger(self: Dropdown)
    local library = self.Host.Library
    local scope = self.Resources
    local frame = self.Trigger.Instance

    library:Connect(frame.MouseEnter, function()
        self.Hovered = true
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)

    library:Connect(frame.MouseLeave, function()
        self.Hovered = false
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)

    library:Connect(frame.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if self.Disabled or not self.Visible then
            return
        end
        -- Read the open state before the handover: BeginInteraction closes the
        -- active popup, which may be this one, and a toggle must not reopen it.
        local wasOpen = self.IsOpen
        self.Host:BeginInteraction()
        if not wasOpen then
            self:Open()
        end
    end, scope)
end

--// Selection ----------------------------------------------------------------

function Dropdown._IsValueDisabled(self: Dropdown, value: string): boolean
    return self.DisabledValues[value] == true
end

function Dropdown._FirstSelectable(self: Dropdown): string?
    for _, value in self.Values do
        if not self:_IsValueDisabled(value) then
            return value
        end
    end
    return nil
end

function Dropdown.IsSelected(self: Dropdown, value: string): boolean
    return self._Selected[value] == true
end

-- Rebuilds the ordered public Value from the selection set. Order follows Values,
-- so the array is deterministic no matter what order items were clicked in.
function Dropdown._SyncValue(self: Dropdown)
    if not self.Multi then
        return
    end
    local ordered: { string } = {}
    for _, value in self.Values do
        if self._Selected[value] then
            table.insert(ordered, value)
        end
    end
    self.Value = ordered
end

local function sameSelection(a: { [string]: boolean }, b: { [string]: boolean }): boolean
    for key, value in a do
        if value and not b[key] then
            return false
        end
    end
    for key, value in b do
        if value and not a[key] then
            return false
        end
    end
    return true
end

-- The one write path for selection. Returns true when the selection changed.
-- `report` controls whether a rejected assignment is warned about; internal
-- revalidation after SetValues is expected to drop values and stays quiet.
function Dropdown._Assign(self: Dropdown, value: any, report: boolean): boolean
    local library = self.Host.Library
    local previous = table.clone(self._Selected)
    local proposed: { [string]: boolean } = {}

    if self.Multi then
        if value == nil then
            -- An empty multi selection is always representable.
        elseif type(value) == "table" then
            local source: { [string]: boolean } = {}
            -- Accept both an array of values and a set of value -> boolean.
            local list = value :: { any }
            if #list > 0 then
                for _, entry in list do
                    if type(entry) == "string" then
                        source[entry] = true
                    end
                end
            end
            for key, flag in value :: { [string]: any } do
                if type(key) == "string" and flag == true then
                    source[key] = true
                end
            end
            for entry in source do
                if contains(self.Values, entry) and not self:_IsValueDisabled(entry) then
                    proposed[entry] = true
                elseif report then
                    library:_Report("Dropdown: rejected value " .. entry)
                end
            end
        else
            if report then
                library:_Report("Dropdown: multi-select value must be a table or nil")
            end
            return false
        end
    else
        if value == nil then
            if not self.AllowNull then
                if report then
                    library:_Report("Dropdown: cannot clear a dropdown without AllowNull")
                end
                return false
            end
        elseif type(value) ~= "string" then
            if report then
                library:_Report("Dropdown: value must be a string or nil")
            end
            return false
        elseif not contains(self.Values, value) or self:_IsValueDisabled(value) then
            if report then
                library:_Report("Dropdown: rejected value " .. value)
            end
            return false
        else
            proposed[value] = true
        end
    end

    if sameSelection(previous, proposed) then
        return false
    end

    self._Selected = proposed
    if self.Multi then
        self:_SyncValue()
    else
        local selected: string? = nil
        for entry in proposed do
            selected = entry
        end
        self.Value = selected
    end
    return true
end

-- Applies a selection change and publishes it. Display, item visuals and the
-- callback all hang off this one call, so no path can update two of the three.
function Dropdown._Commit(self: Dropdown, value: any, report: boolean): boolean
    if not self:_Assign(value, report) then
        return false
    end
    self:_UpdateDisplay()
    self:_UpdateItems(Metrics.Motion.Hover)
    self.Changed:Fire(self.Value)
    return true
end

--// Display ------------------------------------------------------------------

-- Deterministic trigger text. A long value list can never grow the trigger: past
-- MaxDisplay entries the tail collapses into a count.
function Dropdown._Display(self: Dropdown): (string, boolean)
    if self.Multi then
        local selected = self.Value :: { string }
        local count = #selected
        if count == 0 then
            return self.Placeholder, true
        end
        if count <= self.MaxDisplay then
            return table.concat(selected, ", "), false
        end
        local shown = {}
        for index = 1, self.MaxDisplay do
            table.insert(shown, selected[index])
        end
        return table.concat(shown, ", ") .. ", +" .. tostring(count - self.MaxDisplay), false
    end

    local value = self.Value :: string?
    if value == nil or value == "" then
        return self.Placeholder, true
    end
    return value, false
end

function Dropdown._UpdateDisplay(self: Dropdown)
    local text, isPlaceholder = self:_Display()
    self.ValueLabel.Text = text
    local role = if self.Disabled
        then "ControlValueDisabled"
        elseif isPlaceholder then "ControlValueMuted"
        else "ControlValue"
    self.Host.Typography:SetRole(self.ValueLabel, role, self.Resources)
end

--// Visual state -------------------------------------------------------------

function Dropdown._UpdateVisual(self: Dropdown, duration: number)
    if self.Destroyed then
        return
    end
    local context = self.Host.Context
    local trigger = self.Trigger

    local fill = if self.Disabled
        then "Disabled"
        elseif self.IsOpen then "Active"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyState(context, trigger, fill, duration)

    local border = if self.Disabled
        then "Disabled"
        elseif self.IsOpen then "Open"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyBorderState(context, trigger, border)

    Controls.SetChevronToken(
        self.Host,
        self.Chevron,
        if self.Disabled then "Text.Disabled" elseif self.IsOpen then "Text.Primary" else "Text.Muted",
        self.Resources
    )
    Materials.Animate(
        context.Animator,
        self.Chevron.Frame,
        { Rotation = if self.IsOpen then 180 else 0 },
        if duration > 0 then Metrics.Motion.Chevron else 0,
        "Travel"
    )
end

--// Items --------------------------------------------------------------------

function Dropdown._ItemState(self: Dropdown, item: Item): string
    if item.Disabled then
        return "Disabled"
    end
    if item.Hovered then
        return "Hover"
    end
    if self:IsSelected(item.Value) then
        return "Selected"
    end
    return "Rest"
end

function Dropdown._UpdateItems(self: Dropdown, duration: number)
    for _, item in self._Items do
        local selected = self:IsSelected(item.Value)
        Materials.ApplyState(self.Host.Context, item.Surface, self:_ItemState(item), duration)
        Materials.Animate(
            self.Host.Context.Animator,
            item.Marker,
            { BackgroundTransparency = if selected then 0 else 1 },
            duration
        )
        local role = if item.Disabled then "ItemDisabled" elseif selected then "ItemSelected" else "Item"
        self.Host.Typography:SetRole(item.Label, role, item.Scope)
    end
end

function Dropdown._CreateItem(self: Dropdown, value: string, index: number, parent: Instance, scope: Types.Scope): Item
    local host = self.Host
    local library = host.Library
    local config = Metrics.Dropdown

    local surface = Materials.CreateSurface(host.Context, {
        Name = "Item",
        Kind = "Interactive",
        Parent = parent,
        Scope = scope,
        Size = UDim2.new(1, 0, 0, config.ItemHeight),
        Radius = Metrics.Radius.Small,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    surface.Instance.LayoutOrder = index
    surface.Instance.Active = true

    -- The marker sits in its own reserved column, left of where text begins, and
    -- is only ever faded. Selecting a row cannot move its label.
    local marker = library:Create("Frame", {
        Name = "Marker",
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, config.MarkerInset, 0.5, 0),
        Size = UDim2.fromOffset(config.MarkerWidth, config.ItemHeight - config.MarkerVerticalInset * 2),
        ZIndex = Materials.Z.Edge,
        Parent = surface.Instance,
    }, scope) :: Frame
    library:RegisterProperty(marker, { BackgroundColor3 = "Accent.Base" }, scope)

    local label = host.Typography:Create("Item", {
        Name = "Label",
        Text = value,
        Position = UDim2.fromOffset(config.ItemPaddingX, 0),
        Size = UDim2.new(1, -config.ItemPaddingX * 2, 1, 0),
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = surface.Instance,
    }, scope)

    local item: Item = {
        Value = value,
        Surface = surface,
        Label = label,
        Marker = marker,
        Scope = scope,
        Hovered = false,
        Disabled = self:_IsValueDisabled(value),
        Visible = true,
    }

    local frame = surface.Instance
    library:Connect(frame.MouseEnter, function()
        item.Hovered = true
        Materials.ApplyState(host.Context, surface, self:_ItemState(item), Metrics.Motion.Hover)
    end, scope)
    library:Connect(frame.MouseLeave, function()
        item.Hovered = false
        Materials.ApplyState(host.Context, surface, self:_ItemState(item), Metrics.Motion.Hover)
    end, scope)
    library:Connect(frame.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        self:_Choose(item)
    end, scope)

    return item
end

-- Row selection. The popup's own hit test already told the outside-click handler
-- that this click was inside, so nothing can have closed the popup underneath
-- this call.
function Dropdown._Choose(self: Dropdown, item: Item)
    if self.Destroyed or self.Disabled or item.Disabled then
        return
    end
    if self.Multi then
        local selection = table.clone(self._Selected)
        if selection[item.Value] then
            selection[item.Value] = nil
        else
            selection[item.Value] = true
        end
        self:_Commit(selection, false)
        -- Multi-select stays open: a selection is one of several.
        return
    end

    if self:IsSelected(item.Value) and self.AllowNull then
        self:_Commit(nil, false)
    else
        self:_Commit(item.Value, false)
    end
    self:Close()
end

-- One item instance per value, built once per value set. Filtering toggles
-- Visible on these rows rather than rebuilding them, so typing in the search
-- field never reconstructs the control tree.
function Dropdown._RebuildItems(self: Dropdown)
    local list = self._List
    if not list then
        return
    end

    local previous = self._ItemScope
    self._ItemScope = nil
    table.clear(self._Items)
    if previous then
        previous:Destroy()
    end

    local scope = self.Host.Library:CreateScope(self.Resources)
    self._ItemScope = scope
    scope:Add(function()
        if self._ItemScope == scope then
            self._ItemScope = nil
        end
    end)

    for index, value in self.Values do
        local itemScope = self.Host.Library:CreateScope(scope)
        local item = self:_CreateItem(value, index, list, itemScope)
        table.insert(self._Items, item)
    end

    self._Dirty = false
    self:_ApplyFilter()
    self:_UpdateItems(0)
end

--// Search and filtering -----------------------------------------------------

function Dropdown._Matches(self: Dropdown, value: string): boolean
    if self._Filter == "" then
        return true
    end
    return string.find(string.lower(value), self._Filter, 1, true) ~= nil
end

function Dropdown._ApplyFilter(self: Dropdown)
    local visible = 0
    for _, item in self._Items do
        local shown = self:_Matches(item.Value)
        item.Visible = shown
        item.Surface.Instance.Visible = shown
        if shown then
            visible += 1
        else
            -- A hidden row must not keep a hover state it can never clear.
            if item.Hovered then
                item.Hovered = false
                Materials.ApplyState(self.Host.Context, item.Surface, self:_ItemState(item), 0)
            end
        end
    end
    self._VisibleCount = visible

    local empty = self._Empty
    if empty then
        empty.Visible = visible == 0
        -- An empty value list and a search that matched nothing are different
        -- situations, and the popup says which one it is.
        empty.Text = if #self.Values == 0 then "No values" else "No results"
    end
    local scroll = self._Scroll
    if scroll then
        scroll.Visible = visible > 0
        scroll.CanvasSize = UDim2.fromOffset(0, Metrics:DropdownCanvasHeight(visible))
        if visible == 0 then
            scroll.CanvasPosition = Vector2.zero
        end
    end
end

--// Popup --------------------------------------------------------------------

function Dropdown._PopupHeight(self: Dropdown): number
    local count = if self._VisibleCount > 0 then self._VisibleCount else 1
    return Metrics:DropdownPopupHeight(count, self.Searchable)
end

function Dropdown._EnsurePopup(self: Dropdown): boolean
    if self._Popup then
        return true
    end
    local host = self.Host
    local library = host.Library
    local overlay = library.Overlay
    if not overlay then
        return false
    end
    local scope = self.Resources
    local config = Metrics.Dropdown

    local popup = Materials.CreateSurface(host.Context, {
        Name = "DropdownPopup",
        Kind = "Popup",
        Parent = overlay,
        Scope = scope,
        Size = UDim2.fromOffset(config.PopupMinWidth, config.ItemHeight),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
        Visible = false,
    })
    popup.Instance.Active = true
    self._Popup = popup
    -- See Popup.TrackHover: the rectangle test alone loses the click that lands
    -- in the frame after a reposition or a filter reflow.
    self._PopupHovered = Popup.TrackHover(library, popup.Instance, scope)

    local listTop = config.PopupPadding
    if self.Searchable then
        local search = Materials.CreateSurface(host.Context, {
            Name = "Search",
            Kind = "Control",
            Parent = popup.Instance,
            Scope = scope,
            Position = UDim2.fromOffset(config.PopupPadding, config.PopupPadding),
            Size = UDim2.new(1, -config.PopupPadding * 2, 0, config.SearchHeight),
            Radius = Metrics.Radius.Small,
            ZIndex = Materials.Z.Structure,
        })

        local box = host.Typography:CreateText("TextBox", "ControlValue", {
            Name = "Input",
            Text = "",
            PlaceholderText = "Search",
            PlaceholderToken = "Text.Placeholder",
            ClearTextOnFocus = false,
            Position = UDim2.fromOffset(config.ItemPaddingX, 0),
            Size = UDim2.new(1, -config.ItemPaddingX * 2, 1, 0),
            ZIndex = Materials.Z.Text,
            Parent = search.Instance,
        }, scope) :: TextBox
        self._Search = box

        library:Connect(box:GetPropertyChangedSignal("Text"), function()
            local filter = string.lower(box.Text)
            if filter == self._Filter then
                return
            end
            self._Filter = filter
            self:_ApplyFilter()
            self:_Reposition()
        end, scope)

        listTop += config.SearchHeight + config.SearchGap
    end

    local scroll = library:Create("ScrollingFrame", {
        Name = "Items",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(config.PopupPadding, listTop),
        Size = UDim2.new(1, -config.PopupPadding * 2, 1, -(listTop + config.PopupPadding)),
        CanvasSize = UDim2.fromOffset(0, 0),
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = config.ScrollBarThickness,
        ScrollBarImageTransparency = Theme.Alpha.ScrollBarPopup,
        VerticalScrollBarInset = Enum.ScrollBarInset.None,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ClipsDescendants = true,
        ZIndex = Materials.Z.Structure,
        Parent = popup.Instance,
    }, scope) :: ScrollingFrame
    library:RegisterProperty(scroll, { ScrollBarImageColor3 = "Overlay.ScrollBar" }, scope)
    self._Scroll = scroll
    self._List = scroll :: any

    library:Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, config.ItemSpacing),
        Parent = scroll,
    }, scope)

    self._Empty = host.Typography:Create("ItemEmpty", {
        Name = "Empty",
        Text = "No results",
        Position = UDim2.fromOffset(config.PopupPadding + config.ItemPaddingX, listTop),
        Size = UDim2.new(1, -(config.PopupPadding * 2 + config.ItemPaddingX * 2), 0, config.ItemHeight),
        Visible = false,
        ZIndex = Materials.Z.Text,
        Parent = popup.Instance,
    }, scope)

    self:_RebuildItems()
    return true
end

function Dropdown._Reposition(self: Dropdown)
    if self.Destroyed or not self.IsOpen then
        return
    end
    local popup = self._Popup
    if not popup then
        return
    end
    local trigger = self.Trigger.Instance
    -- A trigger on a hidden page is not somewhere a popup can stay attached to.
    if not Popup.IsDisplayed(trigger) then
        self:Close()
        return
    end
    local placement = Popup.Place(self.Host.Library, trigger, self:_PopupHeight())
    if not placement then
        self:Close()
        return
    end
    popup.Instance.Position = placement.Position
    popup.Instance.Size = placement.Size
end

--// Open / close -------------------------------------------------------------

function Dropdown.Open(self: Dropdown)
    if self.Destroyed or self.IsOpen or self.Disabled or not self.Visible then
        return
    end
    if not self:_EnsurePopup() then
        return
    end
    if self._Dirty then
        self:_RebuildItems()
    end
    local popup = self._Popup :: Materials.Surface
    local library = self.Host.Library

    self.IsOpen = true
    popup.Instance.Visible = true
    library.OpenedFrames[popup.Instance] = true

    -- Live geometry tracking: the popup follows its trigger through window drags,
    -- resizes, page scrolling and DPI changes instead of detaching from it.
    local scope = library:CreateScope(self.Resources)
    self._OpenScope = scope
    scope:Add(function()
        if self._OpenScope == scope then
            self._OpenScope = nil
        end
    end)

    local trigger = self.Trigger.Instance
    library:Connect(trigger:GetPropertyChangedSignal("AbsolutePosition"), function()
        self:_Reposition()
    end, scope)
    library:Connect(trigger:GetPropertyChangedSignal("AbsoluteSize"), function()
        self:_Reposition()
    end, scope)
    local gui = library.ScreenGui
    if gui then
        library:Connect(gui:GetPropertyChangedSignal("AbsoluteSize"), function()
            self:_Reposition()
        end, scope)
    end

    self:_Reposition()
    -- Placement can fail: a trigger on a page that is not displayed, or a
    -- viewport with no room for the popup, and _Reposition closes the dropdown
    -- rather than leaving it somewhere it cannot be seen. Claiming popup
    -- ownership after that would leave ActivePopup pointing at a closed
    -- control, which suppresses tooltips and misroutes the next outside click.
    if not self.IsOpen then
        return
    end
    self:_UpdateVisual(Metrics.Motion.Popup)
    self.Host.Popups:Open(self :: any)
end

function Dropdown.Close(self: Dropdown)
    if not self.IsOpen then
        return
    end
    self.IsOpen = false

    local scope = self._OpenScope
    self._OpenScope = nil
    if scope then
        scope:Destroy()
    end

    local popup = self._Popup
    if popup then
        popup.Instance.Visible = false
        self.Host.Library.OpenedFrames[popup.Instance] = nil
    end

    -- Search is a transient view of the values, not part of the selection.
    local search = self._Search
    if search then
        search:ReleaseFocus()
        if search.Text ~= "" then
            search.Text = ""
        end
    end
    self._Filter = ""
    self:_ApplyFilter()

    self.Host.Popups:Release(self :: any)
    if not self.Destroyed then
        self:_UpdateVisual(Metrics.Motion.Popup)
    end
end

function Dropdown.Toggle(self: Dropdown)
    if self.IsOpen then
        self:Close()
    else
        self.Host:BeginInteraction()
        self:Open()
    end
end

-- The popup manager's outside-click test. The trigger and the popup are one
-- interaction surface even though they are in different parts of the hierarchy.
function Dropdown.ContainsPoint(self: Dropdown, point: Vector2): boolean
    if self.Destroyed then
        return false
    end
    if Popup.Contains(self.Trigger.Instance, point) then
        return true
    end
    local hovered = self._PopupHovered
    if hovered and hovered() then
        return true
    end
    local popup = self._Popup
    return popup ~= nil and Popup.Contains(popup.Instance, point)
end

--// Public API ---------------------------------------------------------------

function Dropdown.GetValue(self: Dropdown): any
    return self.Value
end

function Dropdown.SetValue(self: Dropdown, value: any): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self:_Commit(value, true)
    return self
end

-- Replaces the value list. Old item instances and their connections are
-- destroyed with their scope; the current selection survives if it is still
-- valid, and is resolved deliberately if it is not.
function Dropdown.SetValues(self: Dropdown, values: { string }): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self.Values = copyValues(values)
    self._Dirty = true

    local before = table.clone(self._Selected)
    local survivors: { [string]: boolean } = {}
    for value in before do
        if contains(self.Values, value) and not self:_IsValueDisabled(value) then
            survivors[value] = true
        end
    end

    local changed = false
    if not sameSelection(before, survivors) then
        self._Selected = survivors
        if self.Multi then
            self:_SyncValue()
        else
            local selected: string? = nil
            for entry in survivors do
                selected = entry
            end
            self.Value = selected
        end
        changed = true
    end

    -- A single-select dropdown that cannot be empty falls back to the first
    -- selectable value rather than sitting in an impossible state.
    if not self.Multi and self.Value == nil and not self.AllowNull then
        local fallback = self:_FirstSelectable()
        if fallback and self:_Assign(fallback, false) then
            changed = true
        end
    end

    if self._Popup then
        self:_RebuildItems()
    end
    self:_UpdateDisplay()

    if self.IsOpen then
        self:_Reposition()
    end
    if changed then
        self.Changed:Fire(self.Value)
    end
    return self
end

function Dropdown.SetDisabledValues(self: Dropdown, disabled: { [string]: boolean }?): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self.DisabledValues = if disabled then table.clone(disabled) else {}
    for _, item in self._Items do
        item.Disabled = self:_IsValueDisabled(item.Value)
    end
    -- A value that just became disabled cannot remain selected.
    local survivors: { [string]: boolean } = {}
    for value in self._Selected do
        if not self:_IsValueDisabled(value) then
            survivors[value] = true
        end
    end
    local changed = not sameSelection(self._Selected, survivors)
    if changed then
        self._Selected = survivors
        if self.Multi then
            self:_SyncValue()
        else
            local selected: string? = nil
            for entry in survivors do
                selected = entry
            end
            self.Value = selected
        end
        self:_UpdateDisplay()
    end
    self:_UpdateItems(0)
    if changed then
        self.Changed:Fire(self.Value)
    end
    return self
end

function Dropdown.SetText(self: Dropdown, text: string): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self.Text = text
    local label = self.Row.Label
    if label then
        label.Text = text
    end
    return self
end

function Dropdown.SetDisabled(self: Dropdown, disabled: boolean): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
        self:Close()
    end
    local label = self.Row.Label
    if label then
        self.Host.Typography:SetRole(label, if flag then "ControlLabelDisabled" else "ControlLabel", self.Resources)
    end
    self:_UpdateDisplay()
    self:_UpdateVisual(Metrics.Motion.Hover)
    return self
end

function Dropdown.SetVisible(self: Dropdown, visible: boolean): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    -- Element.ApplyVisible closes the popup through Deactivate below, drops the
    -- trigger row out of the flow, and asks the groupbox to close the gap. A
    -- hidden dropdown can never leave an orphan popup on the overlay.
    Element.ApplyVisible(self, visible)
    return self
end

-- Everything transient this control owns. Called when it is hidden, when its
-- groupbox is hidden, and before it is destroyed.
function Dropdown.Deactivate(self: Dropdown)
    self.Hovered = false
    self:Close()
end

function Dropdown.OnChanged(self: Dropdown, callback: (any) -> ()): Types.Cleanup
    assert(not self.Destroyed, "Dropdown is destroyed")
    return self.Changed:Connect(callback)
end

function Dropdown.Destroy(self: Dropdown)
    if self.Destroyed then
        return
    end
    -- Close first, so the popup manager never holds a reference to a dead owner.
    self:Close()
    self.Destroyed = true
    self.Host.Popups:Release(self :: any)
    table.clear(self._Items)
    table.clear(self._Selected)
    self._Popup = nil
    self._Scroll = nil
    self._List = nil
    self._Search = nil
    self._Empty = nil
    self._ItemScope = nil
    Element.Release(self)
    self.Resources:Destroy()
end

return Dropdown
