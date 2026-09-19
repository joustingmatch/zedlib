--!strict
local Types = require(script.Parent.Parent.Types)
local Theme = require(script.Parent.Parent.core.Theme)
local Metrics = require(script.Parent.Metrics)
local Tokens = require(script.Parent.Tokens)
local Typography = require(script.Parent.Typography)
local Materials = require(script.Parent.Materials)
local Controls = require(script.Parent.Controls)
local Popup = require(script.Parent.Popup)
local Groupbox = require(script.Parent.Groupbox)
local KeyPicker = require(script.Parent.KeyPicker)
local UX = require(script.Parent.UX)

local Shell = {}
Shell.__index = Shell

local Tab = {}
Tab.__index = Tab

local SubTab = {}
SubTab.__index = SubTab

-- A page inside a section. It owns the scroll frame, the two columns and the
-- groupboxes in them, plus its own label in the parent tab's strip.
export type SubTab = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Shell: any,
        Tab: any,
        Name: string,
        Order: number,
        Visible: boolean,
        Disabled: boolean,
        Active: boolean,
        Hovered: boolean,
        -- True for the page a tab is given when it never asked for one. It is
        -- real in every respect except that it does not put a label in the
        -- strip: a section with one page has nothing to navigate between.
        Implicit: boolean,

        -- Strip presentation: a text label with an underline beneath it, both
        -- sized to the measured label width.
        Label: TextLabel,
        HeaderButton: TextButton,
        Underline: Frame,
        HeaderWidth: number,

        Page: Frame,
        Content: ScrollingFrame,
        Columns: Frame,
        Left: Frame,
        Right: Frame,
        Groupboxes: { Groupbox.Groupbox },
        Scope: Types.Scope,
        _LeftOrder: number,
        _RightOrder: number,
    },
    SubTab
))

export type Tab = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Shell: any,
        Name: string,
        Subtitle: string,
        Order: number,
        Visible: boolean,
        Disabled: boolean,
        Active: boolean,
        Hovered: boolean,
        -- Dock presentation: an accent-filled rounded container behind the
        -- glyph, plus a narrow pill against the dock's left inner edge. Both
        -- exist for every tab and are only ever faded, so selecting a tab can
        -- never reflow the stack.
        Surface: Materials.Surface,
        Icon: GuiObject,
        Indicator: Frame,
        DockHit: TextButton,

        -- This section's own sub-tab strip. One frame per tab, all parented to
        -- the shared header; the active tab's is the only visible one, so
        -- switching sections swaps strips instead of rebuilding labels.
        Strip: Frame,
        SubTabs: { SubTab },
        ActiveSub: SubTab?,

        -- The union of every sub-tab's groupboxes, in creation order. The
        -- library's diagnostics, validation and search all walk tabs looking
        -- for cards, and they should not have to know that a section is now a
        -- stack of pages.
        Groupboxes: { Groupbox.Groupbox },
        Scope: Types.Scope,
        _SubOrder: number,
    },
    Tab
))

export type Shell = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Resources: Types.Scope,
        Library: any,
        Metrics: typeof(Metrics),
        Tokens: typeof(Tokens),
        Typography: Typography.Typography,
        Host: Controls.Host,
        Context: Materials.Context,
        HostFrame: Frame,
        Window: Materials.Surface,
        Dock: Materials.Surface,
        Content: Materials.Surface,
        Body: Frame,
        Header: Frame,
        HeaderRule: Frame,
        TabList: Frame?,
        PageArea: Frame,
        DockStack: Frame,
        ShowHeaderTabs: boolean,
        Tabs: { Tab },
        Active: Tab?,
        LogicalSize: Vector2,
        _Order: number,
        _DragScope: Types.Scope?,
        _HeaderHeight: number,
    },
    Shell
))

-- Icon is an image asset for the dock glyph. When it is absent the dock falls
-- back to a monogram taken from the tab name, which keeps the stack's geometry
-- and its active treatment intact without shipping a placeholder asset that
-- pretends to be an icon.
export type TabDefinition = {
    Name: string,
    Subtitle: string?,
    Icon: string?,
    -- Declaring a section's pages up front. Omitting this gives the section one
    -- implicit page and no strip.
    SubTabs: { string | SubTabDefinition }?,
}
export type SubTabDefinition = { Name: string, Order: number?, Visible: boolean?, Disabled: boolean? }
export type Options = {
    Tabs: { TabDefinition }?,
    Title: string?,
    Subtitle: string?,
    Mascot: string?,
    HeaderTabs: boolean?,
}

-- The default sections, and the pages inside the two that have more than one.
-- Home and Settings declare pages; Visuals and Players do not, and so show no
-- strip at all -- which is the point of the implicit page: a section only pays
-- for secondary navigation when it has something to navigate.
local DEFAULT_TABS: { TabDefinition } = {
    { Name = "Home", Subtitle = "Overview and status", SubTabs = { "General", "Movement", "Actions" } },
    { Name = "Visuals", Subtitle = "Rendering and appearance" },
    { Name = "Players", Subtitle = "Per-player controls" },
    { Name = "Settings", Subtitle = "Library configuration", SubTabs = { "General" } },
}

--// Window interaction -------------------------------------------------------

-- Converts a scale-anchored window to an offset position in logical units, so
-- dragging is arithmetic on one coordinate space rather than a mix of two.
local function logicalCentre(self: Shell): Vector2
    local frame = self.HostFrame
    local root = self.Library.Root
    local scale = self.Library.DPIScale
    if not root or scale <= 0 then
        return Vector2.zero
    end
    local absolute = frame.AbsolutePosition - root.AbsolutePosition + frame.AbsoluteSize / 2
    return absolute / scale
end

local function viewportLogical(self: Shell): Vector2
    local gui = self.Library.ScreenGui
    local scale = self.Library.DPIScale
    if not gui or scale <= 0 then
        return Vector2.new(Metrics.Window.Width, Metrics.Window.Height)
    end
    return gui.AbsoluteSize / scale
end

-- Keeps a recoverable amount of the window on screen. Unobtrusive: it only
-- engages once an edge has already left the viewport.
local function clampCentre(self: Shell, centre: Vector2, size: Vector2): Vector2
    local viewport = viewportLogical(self)
    local margin = Metrics.Window.ClampMargin
    local halfWidth = size.X / 2
    local halfHeight = size.Y / 2
    local minX = -halfWidth + math.min(margin, size.X)
    local maxX = viewport.X + halfWidth - math.min(margin, size.X)
    -- The drag strips live along the top edge, so that edge never goes under the
    -- topbar: the window always stays grabbable. The layer ignores the GUI inset,
    -- so the inset has to be honoured here instead.
    local minY = halfHeight + Popup.GuiInset().Y / math.max(self.Library.DPIScale, 0.0001)
    local maxY = viewport.Y + halfHeight - math.min(margin, size.Y)
    return Vector2.new(
        math.clamp(centre.X, math.min(minX, maxX), math.max(minX, maxX)),
        math.clamp(centre.Y, math.min(minY, maxY), math.max(minY, maxY))
    )
end

local function setCentre(self: Shell, centre: Vector2)
    self.HostFrame.Position = UDim2.fromOffset(math.round(centre.X), math.round(centre.Y))
end

-- One pointer session at a time, tracked through a scope. There is no per-frame
-- connection and nothing survives losing window focus mid-drag.
function Shell._BeginPointerSession(self: Shell, input: InputObject, step: (delta: Vector2) -> ())
    local library = self.Library
    local runtime = library.Runtime
    if not runtime or self._DragScope then
        return
    end
    local scale = library.DPIScale
    if scale <= 0 then
        return
    end

    local origin = Vector2.new(input.Position.X, input.Position.Y)
    local scope = library:CreateScope(self.Resources)
    self._DragScope = scope
    scope:Add(function()
        if self._DragScope == scope then
            self._DragScope = nil
        end
    end)

    local function finish()
        scope:Destroy()
    end

    library:Connect(runtime.Input.InputChanged, function(moved: InputObject)
        if not library:IsPointerMovement(moved) then
            return
        end
        local current = Vector2.new(moved.Position.X, moved.Position.Y)
        step((current - origin) / scale)
    end, scope)

    library:Connect(runtime.Input.InputEnded, function(ended: InputObject)
        if ended == input or library:IsPrimaryPointer(ended) then
            finish()
        end
    end, scope)

    -- Alt-tabbing away mid-drag must not leave the window following the cursor.
    library:Connect(runtime.Input.WindowFocusReleased, finish, scope)
end

function Shell._BindDrag(self: Shell, handle: GuiObject)
    local library = self.Library
    library:Connect(handle.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        -- Starting a drag is an interaction handover: a popup that was open is
        -- attached to a window that is about to move.
        self.Host:BeginInteraction()
        local startCentre = logicalCentre(self)
        setCentre(self, startCentre)
        local size = self.HostFrame.AbsoluteSize / library.DPIScale
        self:_BeginPointerSession(input, function(delta)
            setCentre(self, clampCentre(self, startCentre + delta, size))
        end)
    end, self.Resources)
end

function Shell._BindResize(self: Shell, handle: GuiObject)
    local library = self.Library
    local window = Metrics.Window
    library:Connect(handle.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        self.Host:BeginInteraction()
        local startCentre = logicalCentre(self)
        setCentre(self, startCentre)
        local startSize = self.HostFrame.AbsoluteSize / library.DPIScale
        self:_BeginPointerSession(input, function(delta)
            local width = math.clamp(math.round(startSize.X + delta.X), window.MinWidth, window.MaxWidth)
            local height = math.clamp(math.round(startSize.Y + delta.Y), window.MinHeight, window.MaxHeight)
            local size = Vector2.new(width, height)
            self.LogicalSize = size
            self.HostFrame.Size = UDim2.fromOffset(width, height)
            -- Columns follow the window inside the same step, so the content
            -- never trails the frame it is inside.
            self:_ApplyContentWidth()
            -- Anchored at its centre, so growing from the bottom-right corner
            -- means moving the centre by half the growth to pin the top-left.
            setCentre(self, clampCentre(self, startCentre + (size - startSize) / 2, size))
        end)
    end, self.Resources)
end

--// Sub-tabs -----------------------------------------------------------------
-- A sub-tab is a page. It owns a scroll frame, two columns and the groupboxes
-- stacked in them, and it contributes one label to its parent tab's strip.

-- Selection is a colour on the label and a transparency on the underline. Both
-- instances already exist at their final size, so activating a page cannot
-- shift the strip by a subpixel.
function SubTab._Refresh(self: SubTab, duration: number)
    if self.Destroyed then
        return
    end
    local shell = self.Shell :: Shell

    local role = if self.Disabled
        then "HeaderTabDisabled"
        elseif self.Active then "HeaderTabActive"
        elseif self.Hovered then "HeaderTabActive"
        else "HeaderTab"
    shell.Typography:SetRole(self.Label, role, self.Scope)

    Materials.Animate(
        shell.Context.Animator,
        self.Underline,
        { BackgroundTransparency = if self.Active then 0 else 1 },
        duration
    )
end

function SubTab.Select(self: SubTab): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    local tab = self.Tab :: Tab
    (self.Shell :: Shell):SelectTab(tab.Name)
    tab:SelectSubTab(self.Name)
    return self
end

function SubTab.SetVisible(self: SubTab, visible: boolean): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    local flag = visible ~= false
    if self.Visible == flag then
        return self
    end
    self.Visible = flag
    self.Hovered = false
    -- A hidden page contributes neither a label to the strip nor content to the
    -- canvas. Both go at once, so nothing hidden can be measured.
    self.HeaderButton.Visible = flag and not self.Implicit
    if not flag then
        self.Active = false
        self.Page.Visible = false
        self:_Refresh(0)
    end
    (self.Tab :: Tab):_EnsureValidSub(self)
    return self
end

function SubTab.Show(self: SubTab): SubTab
    return self:SetVisible(true)
end

function SubTab.Hide(self: SubTab): SubTab
    return self:SetVisible(false)
end

function SubTab.SetDisabled(self: SubTab, disabled: boolean): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
    end
    self:_Refresh(Metrics.Motion.Hover);
    (self.Tab :: Tab):_EnsureValidSub(self)
    return self
end

function SubTab.SetOrder(self: SubTab, order: number): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    self.Order = order
    self.HeaderButton.LayoutOrder = order
    return self
end

--// Groupboxes ---------------------------------------------------------------
-- A page hosts two columns and nothing else. It does not position groupboxes;
-- it appends one to a column, hands it that column's width, and lets the
-- column's list layout stack it.

function SubTab.AddGroupbox(self: SubTab, options: Groupbox.Options?): Groupbox.Groupbox
    assert(not self.Destroyed, "SubTab is destroyed")
    local shell = self.Shell :: Shell
    local config: Groupbox.Options = if options then table.clone(options) else {}

    local side: Groupbox.Side = if config.Side == "Right" then "Right" else "Left"
    local column = if side == "Right" then self.Right else self.Left

    if config.LayoutOrder == nil then
        if side == "Right" then
            self._RightOrder += 1
            config.LayoutOrder = self._RightOrder
        else
            self._LeftOrder += 1
            config.LayoutOrder = self._LeftOrder
        end
    end
    config.Width = config.Width or math.round(column.Size.X.Offset)

    local groupbox = Groupbox.new(shell.Host, {
        Tab = self,
        Parent = column,
        Side = side,
        Options = config,
        Scope = self.Scope,
    })
    table.insert(self.Groupboxes, groupbox)
    -- The section keeps a flat view of every card under it, so the library's
    -- diagnostics, validation and search do not have to walk two levels.
    table.insert((self.Tab :: Tab).Groupboxes, groupbox)
    return groupbox
end

-- Convenience, not a second implementation: both call the constructor above.
function SubTab.AddLeftGroupbox(self: SubTab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Left" })
end

function SubTab.AddRightGroupbox(self: SubTab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Right" })
end

function SubTab.GetGroupboxes(self: SubTab): { Groupbox.Groupbox }
    return table.clone(self.Groupboxes)
end

-- Column geometry is computed once, from the window's logical width, and handed
-- down. Both columns come out of the same subtraction and the remainder goes to
-- the left one, so the two can never disagree by a pixel.
function SubTab._ApplyWidth(self: SubTab, available: number)
    if self.Destroyed then
        return
    end
    local gap = Metrics.Columns.Gap
    local usable = math.max(Metrics.Columns.MinWidth * 2 + gap, math.floor(available))
    local right = math.floor((usable - gap) / 2)
    local left = usable - gap - right

    self.Columns.Size = UDim2.new(0, usable, 0, 0)
    self.Left.Position = UDim2.fromOffset(0, 0)
    self.Left.Size = UDim2.new(0, left, 0, 0)
    self.Right.Position = UDim2.fromOffset(left + gap, 0)
    self.Right.Size = UDim2.new(0, right, 0, 0)

    for _, groupbox in self.Groupboxes do
        if not groupbox.Destroyed then
            groupbox:SetWidth(if groupbox.Side == "Right" then right else left)
        end
    end
end

function SubTab.Destroy(self: SubTab)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    local tab = self.Tab :: Tab
    local index = table.find(tab.SubTabs, self)
    if index then
        table.remove(tab.SubTabs, index)
    end
    for _, groupbox in self.Groupboxes do
        local at = table.find(tab.Groupboxes, groupbox)
        if at then
            table.remove(tab.Groupboxes, at)
        end
    end
    local wasActive = tab.ActiveSub == self
    if wasActive then
        tab.ActiveSub = nil
    end
    self.Scope:Destroy()
    if not tab.Destroyed then
        tab:_LayoutHeader()
        if wasActive then
            tab:_SelectFirstValidSub()
        end
    end
end

--// Tabs ---------------------------------------------------------------------

-- A tab's selection is expressed in three places at once -- the dock
-- container's fill, the dock pill and the glyph's colour -- and every one of
-- them is a transparency or a colour change on an instance that already exists
-- at its final size. Nothing is created, destroyed, moved or resized here,
-- which is why a section change cannot shift the dock stack by a subpixel.
--
-- The header strip is deliberately not touched from here. It is not a second
-- presentation of this tab; it is the navigation of the page set underneath it,
-- and it is swapped wholesale when the active section changes.
function Tab._Refresh(self: Tab, duration: number)
    if self.Destroyed then
        return
    end
    local shell = self.Shell :: Shell
    local animator = shell.Context.Animator

    -- The active container is painted accent; an inactive one shows nothing but
    -- the dock behind it, and picks up only a hover tint.
    local container = if self.Active then 0 elseif self.Disabled then 1 elseif self.Hovered then 0.88 else 1
    Materials.Animate(animator, self.Surface.Instance, { BackgroundTransparency = container }, duration)

    Materials.Animate(animator, self.Indicator, { BackgroundTransparency = if self.Active then 0 else 1 }, duration)

    -- The glyph reads against whatever is behind it: the accent fill when
    -- active, the dock surface otherwise.
    local icon = self.Icon
    if icon:IsA("ImageLabel") then
        local token: Types.ThemeRole = if self.Active
            then "Text.OnAccent"
            elseif self.Disabled then "Text.Disabled"
            elseif self.Hovered then "Text.Primary"
            else "Text.Muted"
        -- A binding is replaced, not stacked: the registry holds one entry per
        -- instance, exactly as SetRole does for a label.
        shell.Library:UnregisterProperty(icon)
        shell.Library:RegisterProperty(icon, { ImageColor3 = token }, self.Scope)
    else
        shell.Typography:SetRole(
            icon,
            if self.Disabled
                then "DockGlyphDisabled"
                elseif self.Active then "DockGlyphActive"
                elseif self.Hovered then "DockGlyphHover"
                else "DockGlyph",
            self.Scope
        )
    end
end

function Tab.Select(self: Tab): Tab
    assert(not self.Destroyed, "Tab is destroyed");
    (self.Shell :: Shell):SelectTab(self.Name)
    return self
end

function Tab.SetVisible(self: Tab, visible: boolean): Tab
    assert(not self.Destroyed, "Tab is destroyed")
    local flag = visible ~= false
    if self.Visible == flag then
        return self
    end
    self.Visible = flag
    self.Hovered = false
    self:_ApplyPresence()
    if not flag then
        self:_Refresh(0)
    end -- The dock places items by centre, so it is re-laid out explicitly.
    (self.Shell :: Shell):_LayoutDock();
    (self.Shell :: Shell):_EnsureValidSelection(self)
    return self
end

-- The three instances that make up a tab's dock presentation are shown and
-- hidden together, along with the strip it owns. They are listed once, here,
-- rather than at each call site.
function Tab._ApplyPresence(self: Tab)
    local flag = self.Visible
    self.Surface.Instance.Visible = flag
    self.Indicator.Visible = flag
    self.DockHit.Visible = flag
    if not flag then
        self.Strip.Visible = false
    end
end

-- Places this tab's dock container, pill and hit area on a given centre line.
function Tab._PlaceDock(self: Tab, centre: number)
    local dock = Metrics.Dock
    self.Surface.Instance.Position = UDim2.new(0.5, 0, 0, centre)
    self.Indicator.Position = UDim2.new(0, dock.IndicatorInset, 0, centre)
    self.DockHit.Position = UDim2.new(0.5, 0, 0, centre)
end

function Tab.Show(self: Tab): Tab
    return self:SetVisible(true)
end

function Tab.Hide(self: Tab): Tab
    return self:SetVisible(false)
end

function Tab.SetDisabled(self: Tab, disabled: boolean): Tab
    assert(not self.Destroyed, "Tab is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
    end
    self:_Refresh(Metrics.Motion.Hover);
    (self.Shell :: Shell):_EnsureValidSelection(self)
    return self
end

function Tab.SetOrder(self: Tab, order: number): Tab
    assert(not self.Destroyed, "Tab is destroyed")
    self.Order = order
    self.Strip.LayoutOrder = order;
    (self.Shell :: Shell):_LayoutDock()
    return self
end

--// Sub-tab ownership --------------------------------------------------------

-- Whether this section has anything to navigate between. A section with one
-- page has no strip: a single label under no heading is decoration, not
-- navigation, and the page gets the vertical space back instead.
function Tab.ShowsStrip(self: Tab): boolean
    if not (self.Shell :: Shell).ShowHeaderTabs then
        return false
    end
    for _, sub in self.SubTabs do
        if not sub.Destroyed and sub.Visible and not sub.Implicit then
            return true
        end
    end
    return false
end

-- Reconciles the strip with the pages behind it, then tells the shell how much
-- vertical space the header now needs. One call, from every path that can
-- change either answer.
function Tab._LayoutHeader(self: Tab)
    if self.Destroyed then
        return
    end
    for _, sub in self.SubTabs do
        if not sub.Destroyed then
            sub.HeaderButton.Visible = sub.Visible and not sub.Implicit
        end
    end
    local shell = self.Shell :: Shell
    if shell.Active == self and not shell.Destroyed then
        shell:_ApplyHeader()
    end
end

function Tab.GetSubTab(self: Tab, name: string): SubTab?
    for _, sub in self.SubTabs do
        if not sub.Destroyed and sub.Name == name then
            return sub
        end
    end
    return nil
end

function Tab.GetSubTabs(self: Tab): { SubTab }
    return table.clone(self.SubTabs)
end

function Tab.AddSubTab(self: Tab, definition: string | SubTabDefinition): SubTab
    assert(not self.Destroyed, "Tab is destroyed")
    local config: SubTabDefinition = if type(definition) == "string" then { Name = definition } else definition
    return (self.Shell :: Shell):_BuildSubTab(self, config, false)
end

-- The page a section is given when it never asked for one. Created on first
-- use, so a section that declares its own pages never pays for one it does not
-- want, and a section that never mentions pages still has somewhere to put a
-- card.
function Tab._DefaultSubTab(self: Tab): SubTab
    for _, sub in self.SubTabs do
        if not sub.Destroyed then
            return sub
        end
    end
    return (self.Shell :: Shell):_BuildSubTab(self, { Name = self.Name }, true)
end

local function subSelectable(sub: SubTab): boolean
    return not sub.Destroyed and sub.Visible and not sub.Disabled
end

function Tab.SelectSubTab(self: Tab, name: string): SubTab?
    assert(not self.Destroyed, "Tab is destroyed")
    local target = self:GetSubTab(name)
    if not target or not subSelectable(target) then
        return nil
    end
    if self.ActiveSub == target then
        target.Page.Visible = self.Active
        return target
    end
    local previous = self.ActiveSub
    if previous and not previous.Destroyed then
        previous.Active = false
        previous.Page.Visible = false
        previous:_Refresh(Metrics.Motion.Select)
    end
    self.ActiveSub = target
    target.Active = true
    -- The page is shown only while its section is; a page in a closed section
    -- stays hidden so it can never contribute to the visible canvas.
    target.Page.Visible = self.Active
    target:_Refresh(Metrics.Motion.Select)
    return target
end

function Tab._SelectFirstValidSub(self: Tab)
    local ordered = {}
    for _, sub in self.SubTabs do
        if subSelectable(sub) then
            table.insert(ordered, sub)
        end
    end
    table.sort(ordered, function(a, b)
        if a.Order == b.Order then
            return a.Name < b.Name
        end
        return a.Order < b.Order
    end)
    local first = ordered[1]
    if first then
        self:SelectSubTab(first.Name)
    else
        local active = self.ActiveSub
        if active then
            active.Active = false
            active.Page.Visible = false
            active:_Refresh(0)
            self.ActiveSub = nil
        end
    end
end

-- Called after a page's visibility or disabled state changed. If the page that
-- changed was the open one and is no longer usable, the section falls back to
-- the first one that is; otherwise nothing moves.
function Tab._EnsureValidSub(self: Tab, changed: SubTab)
    self:_LayoutHeader()
    if self.ActiveSub == changed and not subSelectable(changed) then
        self.ActiveSub = nil
        changed.Active = false
        changed.Page.Visible = false
        changed:_Refresh(0)
        self:_SelectFirstValidSub()
    elseif self.ActiveSub == nil then
        self:_SelectFirstValidSub()
    end
end

--// Groupbox delegation ------------------------------------------------------
-- A section is not a page, but the one-page case is the common one and should
-- not have to say so. These forward to the section's default page; a section
-- with declared pages puts cards on those instead.

function Tab.AddGroupbox(self: Tab, options: Groupbox.Options?): Groupbox.Groupbox
    assert(not self.Destroyed, "Tab is destroyed")
    return self:_DefaultSubTab():AddGroupbox(options)
end

function Tab.AddLeftGroupbox(self: Tab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Left" })
end

function Tab.AddRightGroupbox(self: Tab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Right" })
end

function Tab.GetGroupboxes(self: Tab): { Groupbox.Groupbox }
    return table.clone(self.Groupboxes)
end

-- Published to every page in the section. The width is one number and it is
-- computed once, above; a page does not read its own AbsoluteSize to find it.
function Tab._ApplyWidth(self: Tab, available: number)
    if self.Destroyed then
        return
    end
    for _, sub in self.SubTabs do
        if not sub.Destroyed then
            sub:_ApplyWidth(available)
        end
    end
end

function Tab.Destroy(self: Tab)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    local shell = self.Shell :: Shell
    local index = table.find(shell.Tabs, self)
    if index then
        table.remove(shell.Tabs, index)
    end
    local wasActive = shell.Active == self
    if wasActive then
        shell.Active = nil
    end
    self.Scope:Destroy()
    if not shell.Destroyed then
        shell:_LayoutDock()
    end
    if wasActive and not shell.Destroyed then
        shell.Host:BeginInteraction()
        shell:_SelectFirstValid()
    end
end

--// Shell construction -------------------------------------------------------

local function createHostFrame(library: any, scope: Types.Scope): Frame
    -- Deliberately not clipped: the window's cast shadow draws outside these
    -- bounds, and a clipping ancestor would cut it off.
    return library:Create("Frame", {
        Name = "ZedlibWindow",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(Metrics.Window.Width, Metrics.Window.Height),
        ZIndex = Materials.Z.Base,
        ClipsDescendants = false,
    }, scope) :: Frame
end

-- The dock's identity anchor: a mascot emblem sitting near the top with
-- deliberate air beneath it. A caller-supplied image is used when there is one;
-- otherwise a rounded accent-tinted emblem carrying the product's initial holds
-- the same footprint, so the stack below it is positioned identically either
-- way and a real asset can be dropped in later without moving anything.
function Shell._BuildMascot(self: Shell, parent: Frame, asset: string?, title: string)
    local library = self.Library
    local dock = Metrics.Dock
    local size = dock.MascotSize

    local holder = library:Create("Frame", {
        Name = "Mascot",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, dock.PaddingTop + size / 2),
        Size = UDim2.fromOffset(size, size),
        ZIndex = Materials.Z.Structure,
        Parent = parent,
    }, self.Resources) :: Frame

    if asset and asset ~= "" then
        library:Create("ImageLabel", {
            Name = "Emblem",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Image = asset,
            ScaleType = Enum.ScaleType.Fit,
            Size = UDim2.fromScale(1, 1),
            ZIndex = Materials.Z.Text,
            Parent = holder,
        }, self.Resources)
        return
    end

    local emblem = Materials.CreateSurface(self.Context, {
        Name = "Emblem",
        Kind = "DockItemActive",
        Parent = holder,
        Scope = self.Resources,
        Size = UDim2.fromScale(1, 1),
        Radius = Metrics.Radius.DockItem,
        ZIndex = Materials.Z.Structure,
    })

    local initial = string.upper(string.sub(title, 1, 1))
    local glyph = self.Typography:Create("DockGlyphActive", {
        Name = "Initial",
        Text = if initial ~= "" then initial else "Z",
        Size = UDim2.fromScale(1, 1),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = Materials.Z.Text,
        Parent = emblem.Instance,
    }, self.Resources)
    assert(glyph ~= nil, "Mascot emblem failed to build")
end

--// Sub-tab construction ----------------------------------------------------

-- One page and the strip label that opens it. Both are built here, together,
-- because they are one object with two faces and neither is useful alone.
function Shell._BuildSubTab(self: Shell, tab: Tab, definition: SubTabDefinition, implicit: boolean): SubTab
    local library = self.Library
    local scope = library:CreateScope(tab.Scope)
    local content = Metrics.Content
    local header = Metrics.HeaderTabs

    tab._SubOrder += 1
    local order = definition.Order or tab._SubOrder

    --// Strip presentation ---------------------------------------------------
    -- The label's width is measured, and both the button and the underline take
    -- that width, so the underline is exactly as wide as the word above it
    -- rather than as wide as a padded box around it.
    local labelWidth =
        math.max(1, math.ceil(self.Typography:Measure(definition.Name, self.Typography.Roles.HeaderTab, math.huge).X))

    local headerButton = library:Create("TextButton", {
        Name = definition.Name .. "SubTab",
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        LayoutOrder = order,
        -- The button is the full strip height so its bottom edge is the strip's
        -- bottom edge, which is where the underline and the rule both sit.
        Size = UDim2.fromOffset(labelWidth, header.Height),
        ZIndex = Materials.Z.Structure,
        Visible = not implicit,
        Parent = tab.Strip,
    }, scope) :: TextButton

    -- The label occupies the button above the underline band, so the text is
    -- centred in the space it actually has rather than in the whole strip.
    local underlineBand = header.UnderlineThickness
    local label = self.Typography:Create("HeaderTab", {
        Name = "Label",
        Text = definition.Name,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, header.Height - underlineBand),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = Materials.Z.Text,
        Parent = headerButton,
    }, scope)

    -- Pinned to the button's bottom edge, which is the rule's line. The active
    -- marker sits on the rule rather than floating above it, so the strip reads
    -- as one edge with a highlighted span rather than two stacked lines.
    local underline = library:Create("Frame", {
        Name = "Underline",
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, header.UnderlineThickness),
        ZIndex = Materials.Z.Overlay,
        Parent = headerButton,
    }, scope) :: Frame
    library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(header.UnderlineThickness / 2)),
        Parent = underline,
    }, scope)
    library:RegisterProperty(underline, { BackgroundColor3 = "Accent.Base" }, scope)

    --// Page ----------------------------------------------------------------
    local page = library:Create("Frame", {
        Name = definition.Name .. "Page",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Structure,
        Visible = false,
        ClipsDescendants = false,
    }, scope) :: Frame

    -- The control region scrolls. A dropdown opened inside it is parented to the
    -- overlay, so this clipping frame cannot cut its popup off.
    local scroll = library:Create("ScrollingFrame", {
        Name = "Controls",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = content.ScrollBarThickness,
        ScrollBarImageTransparency = Theme.Alpha.ScrollBar,
        VerticalScrollBarInset = Enum.ScrollBarInset.None,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ClipsDescendants = true,
        ZIndex = Materials.Z.Structure,
        Parent = page,
    }, scope) :: ScrollingFrame
    library:RegisterProperty(scroll, { ScrollBarImageColor3 = "Overlay.ScrollBar" }, scope)

    -- The canvas's margins, declared as padding rather than added to a height
    -- by hand. AutomaticCanvasSize already accounts for UIPadding, so each
    -- margin is stated once and cannot be double counted.
    --
    -- The side and top gutters are one pixel: a card's border is a stroke, a
    -- stroke draws outside the frame it belongs to, and a card sitting flush
    -- against this frame's edge would have that side of its border clipped off.
    library:Create("UIPadding", {
        PaddingLeft = UDim.new(0, content.StrokeGutter),
        PaddingRight = UDim.new(0, content.StrokeGutter),
        PaddingTop = UDim.new(0, content.StrokeGutter),
        PaddingBottom = UDim.new(0, content.CanvasBottomPadding),
        Parent = scroll,
    }, scope)

    -- Two columns side by side, each stacking its own groupboxes. The columns
    -- size themselves to their contents; the Columns frame sizes to the TALLER
    -- of the two rather than to their sum, because they sit beside each other,
    -- and the canvas follows it. A groupbox resizing therefore never has to
    -- reach up and correct the page.
    local columns = library:Create("Frame", {
        Name = "Columns",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = scroll,
    }, scope) :: Frame

    local function column(name: string): Frame
        local frame = library:Create("Frame", {
            Name = name,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.new(0, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            ZIndex = Materials.Z.Structure,
            ClipsDescendants = false,
            Parent = columns,
        }, scope) :: Frame
        library:Create("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, Metrics.Groupbox.Spacing),
            Parent = frame,
        }, scope)
        return frame
    end

    local left, right = column("Left"), column("Right")
    page.Parent = self.PageArea

    local sub: SubTab = setmetatable({
        Destroyed = false,
        Shell = self,
        Tab = tab,
        Name = definition.Name,
        Order = order,
        Visible = definition.Visible ~= false,
        Disabled = definition.Disabled == true,
        Active = false,
        Hovered = false,
        Implicit = implicit,
        Label = label,
        HeaderButton = headerButton,
        Underline = underline,
        HeaderWidth = labelWidth,
        Page = page,
        Content = scroll,
        Columns = columns,
        Left = left,
        Right = right,
        Groupboxes = {},
        Scope = scope,
        _LeftOrder = 0,
        _RightOrder = 0,
    }, SubTab)

    headerButton.Visible = sub.Visible and not implicit
    sub:_ApplyWidth(self:_ColumnArea())

    library:Connect(headerButton.MouseEnter, function()
        if sub.Disabled then
            return
        end
        sub.Hovered = true
        sub:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(headerButton.MouseLeave, function()
        sub.Hovered = false
        sub:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(headerButton.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if sub.Disabled or not sub.Visible then
            return
        end
        tab:SelectSubTab(sub.Name)
    end, scope)

    scope:Add(function()
        sub.Destroyed = true
        table.clear(sub.Groupboxes)
        local index = table.find(tab.SubTabs, sub)
        if index then
            table.remove(tab.SubTabs, index)
        end
        if tab.ActiveSub == sub then
            tab.ActiveSub = nil
        end
    end)

    table.insert(tab.SubTabs, sub)
    sub:_Refresh(0)
    tab:_LayoutHeader()
    if tab.ActiveSub == nil then
        tab:_SelectFirstValidSub()
    end
    return sub
end

--// Tab construction ---------------------------------------------------------

function Shell._BuildTab(self: Shell, definition: TabDefinition): Tab
    local library = self.Library
    local scope = library:CreateScope(self.Resources)
    local dock = Metrics.Dock
    local header = Metrics.HeaderTabs

    self._Order += 1
    local order = self._Order
    local index = #self.Tabs + 1
    local centre = Metrics:DockItemCentre(index)

    --// Dock presentation ----------------------------------------------------
    -- Every item is placed by its own centre rather than by a list layout. The
    -- pitch is a metric, the container is smaller than the pitch, and the
    -- indicator is positioned against the dock's left inner edge -- so the three
    -- pieces stay aligned to each other at any dock width.
    local surface = Materials.CreateSurface(self.Context, {
        Name = definition.Name .. "DockItem",
        Kind = "DockItemActive",
        Parent = self.DockStack,
        Scope = scope,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, centre),
        Size = UDim2.fromOffset(dock.ItemSize, dock.ItemSize),
        Radius = Metrics.Radius.DockItem,
        ZIndex = Materials.Z.Structure,
    })
    surface.Instance.BackgroundTransparency = 1

    local icon: GuiObject
    if definition.Icon and definition.Icon ~= "" then
        icon = library:Create("ImageLabel", {
            Name = "Icon",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Image = definition.Icon,
            ScaleType = Enum.ScaleType.Fit,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(dock.IconSize, dock.IconSize),
            ZIndex = Materials.Z.Text,
            Parent = surface.Instance,
        }, scope) :: GuiObject
    else
        icon = self.Typography:Create("DockGlyph", {
            Name = "Icon",
            Text = string.upper(string.sub(definition.Name, 1, 1)),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(dock.ItemSize, dock.ItemSize),
            TextXAlignment = Enum.TextXAlignment.Center,
            TextYAlignment = Enum.TextYAlignment.Center,
            ZIndex = Materials.Z.Text,
            Parent = surface.Instance,
        }, scope) :: GuiObject
    end

    local indicator = library:Create("Frame", {
        Name = definition.Name .. "Indicator",
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, dock.IndicatorInset, 0, centre),
        Size = UDim2.fromOffset(dock.IndicatorWidth, dock.IndicatorHeight),
        ZIndex = Materials.Z.Edge,
        Parent = self.DockStack,
    }, scope) :: Frame
    library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(dock.IndicatorWidth / 2)),
        Parent = indicator,
    }, scope)
    library:RegisterProperty(indicator, { BackgroundColor3 = "Accent.Base" }, scope)

    -- The hit area is the full pitch, not the visible container: the dock is
    -- narrow, and a 30 pixel target inside a 40 pixel row leaves dead bands
    -- between items for no reason.
    local dockHit = library:Create("TextButton", {
        Name = definition.Name .. "DockHit",
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, centre),
        Size = UDim2.new(1, 0, 0, dock.ItemPitch),
        ZIndex = Materials.Z.Overlay,
        Parent = self.DockStack,
    }, scope) :: TextButton

    --// This section's sub-tab strip ------------------------------------------
    -- One strip per section, all stacked in the same header slot and only one
    -- of them visible. Switching sections does not rebuild labels or remeasure
    -- text; it changes which strip is shown.
    local strip = library:Create("Frame", {
        Name = definition.Name .. "Strip",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(header.Inset, 0),
        Size = UDim2.new(1, -header.Inset, 1, 0),
        LayoutOrder = order,
        Visible = false,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Header,
    }, scope) :: Frame
    library:Create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, header.Gap),
        HorizontalAlignment = if header.Alignment >= 1
            then Enum.HorizontalAlignment.Right
            elseif header.Alignment > 0 then Enum.HorizontalAlignment.Center
            else Enum.HorizontalAlignment.Left,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        Parent = strip,
    }, scope)

    local tab: Tab = setmetatable({
        Destroyed = false,
        Shell = self,
        Name = definition.Name,
        Subtitle = definition.Subtitle or "",
        Order = order,
        Visible = true,
        Disabled = false,
        Active = false,
        Hovered = false,
        Surface = surface,
        Icon = icon,
        Indicator = indicator,
        DockHit = dockHit,
        Strip = strip,
        SubTabs = {},
        ActiveSub = nil,
        Groupboxes = {},
        Scope = scope,
        _SubOrder = 0,
    }, Tab)

    -- The dock icon drives one selection path. It does not know how to select a
    -- section; it asks the shell, which is why hidden, disabled and destroyed
    -- sections resolve identically.
    library:Connect(dockHit.MouseEnter, function()
        if tab.Disabled then
            return
        end
        tab.Hovered = true
        tab:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(dockHit.MouseLeave, function()
        tab.Hovered = false
        tab:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(dockHit.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if tab.Disabled or not tab.Visible then
            return
        end
        self:SelectTab(tab.Name)
    end, scope)

    scope:Add(function()
        tab.Destroyed = true
        table.clear(tab.Groupboxes)
        table.clear(tab.SubTabs)
        local at = table.find(self.Tabs, tab)
        if at then
            table.remove(self.Tabs, at)
        end
        if self.Active == tab then
            self.Active = nil
        end
    end)

    table.insert(self.Tabs, tab)
    tab:_Refresh(0)

    for _, declared in definition.SubTabs or {} do
        tab:AddSubTab(declared)
    end

    return tab
end

function Shell.new(library: any, options: Options?): Shell
    library:_AssertLive()
    assert(library.Root, "Mount the library before creating the shell")

    local config: Options = options or {}
    local resources = library:CreateScope()
    local typography = Typography.new(library, resources)
    local host = Controls.NewHost(library, resources, typography)

    local self: Shell = setmetatable({
        Destroyed = false,
        Resources = resources,
        Library = library,
        Metrics = Metrics,
        Tokens = Tokens,
        Typography = typography,
        Host = host,
        Context = host.Context,
        HostFrame = nil :: any,
        Window = nil :: any,
        Dock = nil :: any,
        DockStack = nil :: any,
        Content = nil :: any,
        Body = nil :: any,
        Header = nil :: any,
        HeaderRule = nil :: any,
        TabList = nil,
        ShowHeaderTabs = config.HeaderTabs ~= false,
        Tabs = {},
        Active = nil,
        LogicalSize = Vector2.new(Metrics.Window.Width, Metrics.Window.Height),
        _Order = 0,
        _DragScope = nil,
        _HeaderHeight = 0,
    }, Shell)

    -- Sibling ZIndex keeps the roles in Materials.Z meaningful inside each
    -- parent rather than competing across the whole ScreenGui.
    local gui = library.ScreenGui
    if gui then
        library:_SetProperty(gui, "ZIndexBehavior", Enum.ZIndexBehavior.Sibling)
        library:_SetProperty(gui, "DisplayOrder", 100)
        library:_SetProperty(gui, "IgnoreGuiInset", true)
    end

    library:SetSource(Tokens.Source)

    local hostFrame = createHostFrame(library, resources)
    self.HostFrame = hostFrame

    self.Window = Materials.CreateSurface(self.Context, {
        Name = "Shell",
        Kind = "Shell",
        Parent = hostFrame,
        Scope = resources,
        Size = UDim2.fromScale(1, 1),
        Radius = Metrics.Radius.Window,
        ZIndex = Materials.Z.Base,
    })

    local window = Metrics.Window
    local dock = Metrics.Dock
    local content = Metrics.Content
    local originX = Metrics:ContentOriginX()

    -- The dock is a panel inset from the window edge on three sides, not a wall
    -- bolted to it. That inset is what makes the shell read as one rounded body
    -- with a strip carved into it rather than two frames pushed together.
    self.Dock = Materials.CreateSurface(self.Context, {
        Name = "Dock",
        Kind = "Dock",
        Parent = self.Window.Instance,
        Scope = resources,
        Position = UDim2.fromOffset(window.OuterPadding, window.OuterPadding),
        Size = UDim2.new(0, dock.Width, 1, -window.OuterPadding * 2),
        Radius = Metrics.Radius.Dock,
        ZIndex = Materials.Z.Structure,
    })

    -- The content region takes the rest of the window and stays flush with it:
    -- only the dock and the cards rise off the page.
    self.Content = Materials.CreateSurface(self.Context, {
        Name = "Content",
        Kind = "Content",
        Parent = self.Window.Instance,
        Scope = resources,
        Position = UDim2.fromOffset(originX, 0),
        Size = UDim2.new(1, -originX, 1, 0),
        ZIndex = Materials.Z.Structure,
    })
    self.Content.Instance.BackgroundTransparency = 1

    --// Dock interior
    self:_BuildMascot(self.Dock.Instance :: Frame, config.Mascot, config.Title or "ZEDLIB")

    self.DockStack = library:Create("Frame", {
        Name = "Navigation",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Dock.Instance,
    }, resources) :: Frame

    --// Content interior
    self.Body = library:Create("Frame", {
        Name = "Inner",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(content.PaddingLeft, content.PaddingTop),
        Size = UDim2.new(
            1,
            -(content.PaddingLeft + content.PaddingRight),
            1,
            -(content.PaddingTop + content.PaddingBottom)
        ),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Content.Instance,
    }, resources) :: Frame

    -- The sub-tab strip. One slot, holding one strip per section; the active
    -- section's is the only visible one, so the header is secondary navigation
    -- that belongs to the open page set rather than a bar over the window.
    --
    -- The strip closes with a full-width hairline. The active accent underline
    -- is drawn on that same line, which is what makes the row read as the top
    -- edge of the page under it instead of a free-floating tab bar.
    local headerTabs = Metrics.HeaderTabs

    self.Header = library:Create("Frame", {
        Name = "Header",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, headerTabs.Height),
        Visible = false,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Body,
    }, resources) :: Frame

    self.HeaderRule = library:Create("Frame", {
        Name = "Rule",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, headerTabs.RuleThickness),
        ZIndex = Materials.Z.Edge,
        Parent = self.Header,
    }, resources) :: Frame
    library:RegisterProperty(self.HeaderRule, { BackgroundColor3 = "Border.Divider" }, resources)

    -- Pages sit under the strip. One frame, repositioned when the header's
    -- height changes, so a page never has to know whether a strip is shown.
    self.PageArea = library:Create("Frame", {
        Name = "Pages",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Body,
    }, resources) :: Frame

    self._HeaderHeight = content.PaddingTop

    --// Interaction ownership: dedicated strips, above everything beneath them,
    -- covering only regions that contain no controls. The mascot band at the top
    -- of the dock sits above the first icon, and the header strip's gutter is
    -- clear of every tab label, so neither handle can swallow a click that was
    -- meant for navigation.
    local mascotHandle = library:Create("Frame", {
        Name = "MascotDrag",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(window.OuterPadding, window.OuterPadding),
        Size = UDim2.fromOffset(dock.Width, dock.PaddingTop + dock.MascotSize),
        ZIndex = Materials.Z.Overlay,
        Active = true,
        Parent = self.Window.Instance,
    }, resources) :: Frame

    -- The drag strip covers the content's top padding band only. It stops
    -- short of the sub-tab labels rather than reaching under them, so it can
    -- never swallow a click meant for navigation, and it does not need to
    -- follow the header's height when a section without a strip is open.
    local headerHandle = library:Create("Frame", {
        Name = "HeaderDrag",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(originX, 0),
        Size = UDim2.new(1, -originX, 0, content.PaddingTop),
        ZIndex = Materials.Z.Base,
        Active = true,
        Parent = self.Window.Instance,
    }, resources) :: Frame

    self:_BindDrag(mascotHandle)
    self:_BindDrag(headerHandle)

    local handleSize = Metrics.Window.ResizeHandle
    local resizeHandle = library:Create("Frame", {
        Name = "ResizeHandle",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromScale(1, 1),
        Size = UDim2.fromOffset(handleSize, handleSize),
        ZIndex = Materials.Z.Overlay,
        Active = true,
        Parent = self.Window.Instance,
    }, resources) :: Frame

    -- Two short strokes rather than an icon: it reads as a grip at every scale.
    for index = 1, 2 do
        local grip = library:Create("Frame", {
            Name = "Grip" .. tostring(index),
            BorderSizePixel = 0,
            BackgroundTransparency = Theme.Alpha.ResizeGrip,
            AnchorPoint = Vector2.new(1, 1),
            Position = UDim2.new(1, -window.GripInset, 1, -(window.GripInset + (index - 1) * window.GripPitch)),
            Size = UDim2.fromOffset(handleSize - window.GripTrim - (index - 1) * window.GripStep, window.GripThickness),
            Rotation = -45,
            ZIndex = Materials.Z.Overlay,
            Parent = resizeHandle,
        }, resources) :: Frame
        library:RegisterProperty(grip, { BackgroundColor3 = "Text.Disabled" }, resources)
    end

    self:_BindResize(resizeHandle)

    for _, definition in config.Tabs or DEFAULT_TABS do
        self:_BuildTab(definition)
    end

    self:_LayoutDock()
    self:_SelectFirstValid()
    self:_ApplyHeader()

    -- Parented last, once the window is fully built and styled: it appears in
    -- its final state rather than as a frame that fills in.
    hostFrame.Parent = library.Root
    assert(hostFrame.Parent ~= nil, "Window failed to parent into the library root")

    library.Window = self :: any
    local dynamicHost: any = host
    dynamicHost.Window, dynamicHost.ToggleKey = self, "RightShift"
    KeyPicker.Manager(host)
    library.Notify = function(_library: any, notification: any)
        return UX.Notify(host, notification)
    end
    resources:Add(function()
        self.Destroyed = true
        if library.Window == self then
            library.Window = nil
        end
    end)

    return self
end

--// Dock geometry ------------------------------------------------------------

-- Places every visible tab on the dock's pitch, in order. Hidden tabs are
-- skipped rather than left as a gap, which is what a list layout would do for
-- the header strip -- the dock places by centre, so it does the same thing here
-- explicitly instead of leaving a hole where a hidden section used to be.
function Shell._LayoutDock(self: Shell)
    if self.Destroyed then
        return
    end
    local ordered = {}
    for _, tab in self.Tabs do
        if not tab.Destroyed and tab.Visible then
            table.insert(ordered, tab)
        end
    end
    table.sort(ordered, function(a, b)
        if a.Order == b.Order then
            return a.Name < b.Name
        end
        return a.Order < b.Order
    end)
    for index, tab in ordered do
        tab:_PlaceDock(Metrics:DockItemCentre(index))
    end
end

--// Content geometry ---------------------------------------------------------

-- The width available to the two columns, derived from the window's logical size
-- rather than read back from AbsoluteSize. Absolute geometry lags a frame behind
-- a resize, and wrapped text measured against last frame's width is exactly the
-- kind of drift this avoids.
function Shell._ColumnArea(self: Shell): number
    local content = Metrics.Content
    local inner = self.LogicalSize.X - Metrics:ContentOriginX() - (content.PaddingLeft + content.PaddingRight)
    -- Two deductions, both real estate the columns genuinely do not have. The
    -- scroll bar draws over the content rather than in an inset gutter, so the
    -- columns keep clear of it instead of letting it sit on a card's border;
    -- and the scroll frame reserves a one pixel lane on each side for the
    -- border strokes themselves.
    return math.max(0, inner - (content.ScrollBarThickness + content.ScrollGutter) - content.StrokeGutter * 2)
end

-- One width, published to every page. Called once at construction and once per
-- resize step, and never from inside a groupbox.
function Shell._ApplyContentWidth(self: Shell)
    local available = self:_ColumnArea()
    for _, tab in self.Tabs do
        if not tab.Destroyed then
            tab:_ApplyWidth(available)
        end
    end
end

function Shell.SetSize(self: Shell, width: number, height: number): Shell
    assert(not self.Destroyed, "Shell is destroyed")
    local window = Metrics.Window
    local resolved = Vector2.new(
        math.clamp(math.round(width), window.MinWidth, window.MaxWidth),
        math.clamp(math.round(height), window.MinHeight, window.MaxHeight)
    )
    self.LogicalSize = resolved
    self.HostFrame.Size = UDim2.fromOffset(resolved.X, resolved.Y)
    self:_ApplyContentWidth()
    return self
end

--// Header geometry ----------------------------------------------------------

-- The one place that decides how tall the header is and where the page area
-- starts. Every path that can change the answer -- selecting a section, adding
-- or hiding a sub-tab, destroying one -- routes here rather than writing to
-- PageArea itself, so the two can never disagree.
--
-- The height is derived, never guessed: a section with a strip reserves the
-- strip and the gap below it, and a section without one reserves nothing and
-- gives the page the space back.
function Shell._ApplyHeader(self: Shell)
    if self.Destroyed then
        return
    end
    local content = Metrics.Content
    local active = self.Active
    local shows = active ~= nil and not active.Destroyed and active:ShowsStrip()

    -- Only the open section's strip is present. Switching sections swaps which
    -- one is shown; nothing is measured or rebuilt.
    for _, tab in self.Tabs do
        if not tab.Destroyed then
            tab.Strip.Visible = shows and tab == active
        end
    end

    local height = if shows then Metrics.HeaderTabs.Height + content.HeaderToBody else 0
    self.Header.Visible = shows
    self.PageArea.Position = UDim2.fromOffset(0, height)
    self.PageArea.Size = UDim2.new(1, 0, 1, -height)
    self._HeaderHeight = content.PaddingTop + height
end

--// Tab selection ------------------------------------------------------------

function Shell.GetTab(self: Shell, name: string): Tab?
    for _, tab in self.Tabs do
        if tab.Name == name then
            return tab
        end
    end
    return nil
end

function Shell.AddTab(self: Shell, definition: TabDefinition): Tab
    assert(not self.Destroyed, "Shell is destroyed")
    assert(self:GetTab(definition.Name) == nil, "Duplicate tab: " .. definition.Name)
    local tab = self:_BuildTab(definition)
    self:_LayoutDock()
    if not self.Active then
        self:_Activate(tab)
    end
    return tab
end

local function selectable(tab: Tab): boolean
    return not tab.Destroyed and tab.Visible and not tab.Disabled
end

-- The one place a tab becomes active. Every entry point funnels through here, so
-- there is no second copy of "hide the old page, show the new one".
-- Opening a section does three things in a fixed order: it closes the previous
-- one's page, it opens this one's, and it re-measures the header. The order
-- matters -- the header's height depends on the section that is open, and the
-- page area's height depends on the header -- so nothing else is allowed to
-- write to either.
function Shell._Activate(self: Shell, tab: Tab?)
    local previous = self.Active
    if previous == tab then
        return
    end

    if previous and not previous.Destroyed then
        previous.Active = false
        previous.Strip.Visible = false
        local page = previous.ActiveSub
        if page and not page.Destroyed then
            page.Page.Visible = false
        end
        previous:_Refresh(Metrics.Motion.Select)
    end

    self.Active = tab
    if tab then
        tab.Active = true
        -- A section reopens on the page it was left on, not on its first one.
        if tab.ActiveSub == nil or not tab.ActiveSub.Visible or tab.ActiveSub.Disabled then
            tab:_SelectFirstValidSub()
        end
        local page = tab.ActiveSub
        if page and not page.Destroyed then
            page.Page.Visible = true
        end
        tab:_Refresh(Metrics.Motion.Select)
    end
    self.TabList = if tab then tab.Strip else nil
    self:_ApplyHeader()
end

function Shell.SelectTab(self: Shell, name: string): Tab?
    assert(not self.Destroyed, "Shell is destroyed")
    local tab = self:GetTab(name)
    assert(tab, "Unknown tab: " .. tostring(name))
    local target = tab :: Tab
    if not selectable(target) then
        return nil
    end
    if self.Active == target then
        return target
    end
    -- Leaving a page invalidates anything that belonged to it: an open popup
    -- from the old page and any keyboard focus inside it are both released.
    self.Host:BeginInteraction()
    self:_Activate(target)
    return target
end

-- Opens a page inside a section, naming both. The two-argument form is the
-- honest spelling of what nested navigation is; `Tab:SelectSubTab` is the same
-- operation once the section is already open.
function Shell.SelectSubTab(self: Shell, tabName: string, subTabName: string): SubTab?
    assert(not self.Destroyed, "Shell is destroyed")
    local tab = self:SelectTab(tabName)
    if not tab then
        return nil
    end
    return tab:SelectSubTab(subTabName)
end

-- Picks the nearest selectable tab: forward from `from` in order, then backward.
-- Falls back to nothing selected only when no tab can be selected at all.
function Shell._SelectNearest(self: Shell, from: Tab?)
    local ordered = table.clone(self.Tabs)
    table.sort(ordered, function(a, b)
        return a.Order < b.Order
    end)

    local start = if from then table.find(ordered, from) else nil
    if start then
        for index = start + 1, #ordered do
            if selectable(ordered[index]) then
                self:_Activate(ordered[index])
                return
            end
        end
        for index = start - 1, 1, -1 do
            if selectable(ordered[index]) then
                self:_Activate(ordered[index])
                return
            end
        end
    end

    for _, tab in ordered do
        if selectable(tab) then
            self:_Activate(tab)
            return
        end
    end
    self:_Activate(nil)
end

function Shell._SelectFirstValid(self: Shell)
    self:_SelectNearest(nil)
end

-- Called whenever a tab's visibility or enabled state changes. The content area
-- must never keep pointing at a tab that can no longer be shown.
function Shell._EnsureValidSelection(self: Shell, changed: Tab)
    if self.Destroyed then
        return
    end
    local active = self.Active
    if active == nil then
        if selectable(changed) then
            self:_Activate(changed)
        end
        return
    end
    if selectable(active) then
        return
    end
    self.Host:BeginInteraction()
    self:_SelectNearest(active)
end

--// Teardown -----------------------------------------------------------------

function Shell.Destroy(self: Shell)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    self.Host:BeginInteraction()
    self.Active = nil
    table.clear(self.Tabs)
    self.Resources:Destroy()
end

function Shell.SetVisible(self: any, visible: boolean): any
    if self.Destroyed then
        return self
    end
    if visible == false then
        self.Host:BeginInteraction()
        if self._DragScope then
            self._DragScope:Destroy()
            self._DragScope = nil
        end
        if self.Library.ActiveModal then
            self.Library.ActiveModal:Close()
        end
        for _, tab in self.Tabs do
            for _, box in tab.Groupboxes do
                box:Deactivate()
            end
        end
        self.Host.Keybinds:Reset()
    end
    self.HostFrame.Visible = visible ~= false
    self.Visible = visible ~= false
    return self
end
function Shell.Toggle(self: any): any
    return self:SetVisible(not self.HostFrame.Visible)
end
function Shell.Show(self: any): any
    return self:SetVisible(true)
end
function Shell.Hide(self: any): any
    return self:SetVisible(false)
end
function Shell.SetToggleKey(self: any, key: string)
    self.Host.ToggleKey = key
end
function Shell.Notify(self: any, options: any): any
    return UX.Notify(self.Host, options)
end

-- Remeasures every page from scratch.
--
-- Width-driven layout is cached at each level: a groupbox that is told the width
-- it already has does nothing, and so does a wrapped label. That is the right
-- behaviour during a drag-resize, and the wrong behaviour when the thing that
-- changed is text metrics rather than width, which is what a font change is.
-- Invalidating the caches first makes the same one-way layout pass produce the
-- new heights without any control being rebuilt.
function Shell.Refresh(self: any): any
    if self.Destroyed then
        return self
    end
    for _, tab in self.Tabs do
        if not tab.Destroyed then
            for _, box in tab.Groupboxes do
                if not box.Destroyed then
                    box.Width = -1
                    local function invalidate(container: any)
                        for _, element in container.Elements do
                            if not element.Destroyed then
                                if element._Width ~= nil then
                                    element._Width = -1
                                end
                                if element.Elements then
                                    invalidate(element)
                                end
                            end
                        end
                    end
                    invalidate(box)
                end
            end
        end
    end
    self:_ApplyContentWidth()
    return self
end
function Shell.AddDialog(self: any, id: string, config: any): any
    return UX.Dialog(self, id, config)
end
function Shell.Search(self: any, query: string): any
    return UX.Search(self, query)
end
function Shell.AddSearch(self: any, container: any): any
    return UX.SearchBox(self, container)
end
function Shell.AddKeybindList(self: any, container: any, options: any): any
    local config = options or {}
    local label = container:AddLabel({ Text = "Keybinds", Wrap = true })
    local function update()
        if label.Destroyed then
            return
        end
        local lines = { "Keybinds" }
        for _, key in self.Host.Keybinds.Items do
            if
                not key.Destroyed
                and (not config.HideUnused or key.Value ~= "None")
                and (not config.ActiveOnly or key.Active)
            then
                table.insert(
                    lines,
                    (key.Text ~= "" and key.Text or key.Value) .. "  " .. key.Value .. "  [" .. key.Mode .. "]"
                )
            end
        end
        label:SetText(table.concat(lines, "\n"))
    end
    label.Resources:Add(self.Host.Keybinds.Changed:Connect(update))
    update()
    return label
end

return Shell
