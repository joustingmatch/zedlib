-- Shell geometry regressions.
--
-- The frontend shell is measured from a reference interface, and these are the
-- measurements. Everything asserted here is a position, a size or a count in
-- logical units -- never a colour -- so the file states the geometry contract
-- rather than describing how the window looks.
--
-- Screen coordinates quoted in comments come from the reference at 1.0 scale,
-- where the window's top edge is y=19 and the dock's own origin is y=26.

local passed = 0
local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    assert(ok, name .. ": " .. tostring(message))
    passed += 1
    print("PASS " .. name)
end

local fails, checks = 0, 0
local function eq(label, actual, expected, tol)
    checks += 1
    tol = tol or 0
    local ok = math.abs(actual - expected) <= tol
    if not ok then
        fails += 1
        error(string.format("%s: got %s, want %s", label, tostring(actual), tostring(expected)), 0)
    end
end

local M = UIModule.Metrics

test("the shell matches the reference geometry", function()
    local library = LibraryModule.new({ OwnershipKey = "audit" }):Initialize():Mount()
    library.ScreenGui.AbsoluteSize = Vector2.new(1600, 1000)
    local shell = UIModule.Create(library)

    --// the dock is a slim inset panel on a fixed pitch
    eq("dock width", M.Dock.Width, 52)
    eq("dock x (window-relative)", M.Window.OuterPadding, 7)
    eq("content origin x", M:ContentOriginX(), 59)
    -- Reference centres are screen coordinates. The window's top edge is y=19 and
    -- the dock is inset 7 inside it, so the dock's own origin is y=26.
    local DOCK_TOP = 26
    eq("mascot centre", M.Dock.PaddingTop + M.Dock.MascotSize / 2, 52 - DOCK_TOP)
    for i, want in { 104, 144, 184, 224, 264, 304 } do
        eq("dock item " .. i .. " centre", M:DockItemCentre(i), want - DOCK_TOP)
    end

    --// a tab is a section, and it appears in the dock and nowhere else
    local tabs = shell.Tabs
    eq("tab count", #tabs, 4)
    local first = tabs[1]
    eq("dock item size", first.Surface.Instance.Size.X.Offset, M.Dock.ItemSize)
    eq("indicator width", first.Indicator.Size.X.Offset, 3)
    eq("indicator height", first.Indicator.Size.Y.Offset, 16)
    eq("indicator x", first.Indicator.Position.X.Offset, 0)
    eq("indicator rides item centre", first.Indicator.Position.Y.Offset, first.Surface.Instance.Position.Y.Offset)
    eq("hit spans the pitch", first.DockHit.Size.Y.Offset, M.Dock.ItemPitch)
    eq("active tab is opaque", tabs[1].Surface.Instance.BackgroundTransparency, 0)
    eq("inactive tab is clear", tabs[2].Surface.Instance.BackgroundTransparency, 1)
    -- A section owns no label in the strip. If it ever gains one again, the two
    -- navigation levels have collapsed back into one and this is where it shows.
    eq("a section has no strip label", if rawget(first, "Label") == nil then 1 else 0, 1)
    eq("a section has no page of its own", if rawget(first, "Content") == nil then 1 else 0, 1)

    --// a sub-tab is a page, and it appears in the strip and nowhere else
    local home = shell:GetTab("Home")
    eq("Home declares three pages", #home.SubTabs, 3)
    local general, movement = home.SubTabs[1], home.SubTabs[2]
    eq("the first page is open", if home.ActiveSub == general then 1 else 0, 1)
    eq("underline thickness", general.Underline.Size.Y.Offset, 2)
    eq("underline matches label width", general.Underline.Size.X.Scale, 1)
    eq("underline is pinned to the strip's baseline", general.Underline.Position.Y.Scale, 1)
    eq("underline is bottom-anchored", general.Underline.AnchorPoint.Y, 1)
    eq("strip button width is the label", general.HeaderButton.Size.X.Offset, general.HeaderWidth)
    eq("strip button spans the strip height", general.HeaderButton.Size.Y.Offset, M.HeaderTabs.Height)
    eq("active underline shown", general.Underline.BackgroundTransparency, 0)
    eq("inactive underline hidden", movement.Underline.BackgroundTransparency, 1)
    eq("the rule closes the strip", shell.HeaderRule.Position.Y.Scale, 1)
    eq("the rule is a hairline", shell.HeaderRule.Size.Y.Offset, M.HeaderTabs.RuleThickness)

    --// the strip belongs to the open section, and switching sections swaps it
    eq("the open section shows its strip", if home.Strip.Visible then 1 else 0, 1)
    local visuals = shell:GetTab("Visuals")
    eq("a closed section hides its strip", if visuals.Strip.Visible then 0 else 1, 1)

    -- A section that declares no page gets one implicit page and no strip at all,
    -- and the space the strip would have taken goes back to the content.
    shell:SelectTab("Visuals")
    visuals:AddLeftGroupbox("Rendering")
    eq("an undeclared section has one page", #visuals.SubTabs, 1)
    eq("that page is implicit", if visuals.SubTabs[1].Implicit then 1 else 0, 1)
    eq("it puts no label in the strip", if visuals.SubTabs[1].HeaderButton.Visible then 0 else 1, 1)
    eq("so the section shows no strip", if visuals:ShowsStrip() then 0 else 1, 1)
    eq("and the page starts at the top", shell.PageArea.Position.Y.Offset, 0)

    shell:SelectTab("Home")
    eq("a declared section shows its strip", if home:ShowsStrip() then 1 else 0, 1)
    eq("and the page starts below it", shell.PageArea.Position.Y.Offset, M.HeaderTabs.Height + M.Content.HeaderToBody)

    --// only the open page is visible, so nothing hidden can be measured
    home:SelectSubTab("Movement")
    eq("the chosen page is open", if movement.Page.Visible then 1 else 0, 1)
    eq("the previous page is closed", if general.Page.Visible then 0 else 1, 1)
    eq("its underline moved with it", movement.Underline.BackgroundTransparency, 0)
    eq("the previous underline cleared", general.Underline.BackgroundTransparency, 1)

    -- Closing the section closes its page too: a page in a closed section must not
    -- be left visible behind another section's content.
    shell:SelectTab("Visuals")
    eq("the page closed with its section", if movement.Page.Visible then 0 else 1, 1)
    shell:SelectTab("Home")
    eq("the section reopened on the page it was left on", if movement.Page.Visible then 1 else 0, 1)

    -- Hiding a page takes its label out of the strip and hands the section to the
    -- next usable page.
    movement:Hide()
    eq("a hidden page has no label", if movement.HeaderButton.Visible then 0 else 1, 1)
    eq("a hidden page is not open", if movement.Page.Visible then 0 else 1, 1)
    eq("the section fell back", if home.ActiveSub ~= movement then 1 else 0, 1)
    movement:Show()
    home:SelectSubTab("General")

    --// cards carry their name outside them and split the columns
    local tab = home:GetSubTab("General")
    local left = tab:AddLeftGroupbox("Speed & Teleport")
    local right = tab:AddRightGroupbox("Fly")
    eq("section label is uppercase", if left.SectionLabel.Text == "SPEED & TELEPORT" then 1 else 0, 1)
    eq("label sits outside the card", left.Holder.Instance.Position.Y.Offset, left.LabelHeight)
    eq("card radius", M.Groupbox.Radius, 10)
    eq("column gap", M.Columns.Gap, 10)
    eq("columns are equal", math.abs(left.Width - right.Width) <= 1 and 1 or 0, 1)

    --// every control lands on the shared row rhythm
    local toggle = left:AddToggle("a_walk", { Text = "Walk Speed" })
    local described = right:AddToggle("a_fly", { Text = "Fly", Description = "WASD + Space/Shift" })
    local slider = left:AddSlider("a_val", { Text = "Walk Speed Value", Min = 0, Max = 100, Default = 16 })
    local drop = left:AddDropdown("a_mode", { Text = "Mode", Values = { "A", "B" } })
    local input = left:AddInput("a_name", { Text = "Name" })
    local area = left:AddTextArea("a_json", { Text = "Config JSON" })
    local action = left:AddButton({ Label = "Rejoin" })

    eq("toggle row height", toggle.LayoutHeight, 40)
    eq("described row is one line taller", described.LayoutHeight > toggle.LayoutHeight and 1 or 0, 1)
    eq("slider row height", slider.LayoutHeight, 58)
    eq("dropdown row height", drop.LayoutHeight, 40)
    eq("input row height", input.LayoutHeight, 40)
    eq("action row height", action.LayoutHeight, 40)
    eq("text area spans the card", area.Field.Instance.Size.X.Scale, 1)
    eq("text area is multi-line", area.Box.MultiLine and 1 or 0, 1)

    eq("toggle track width", toggle.Surface.Instance.Size.X.Offset, 36)
    eq("toggle track height", toggle.Surface.Instance.Size.Y.Offset, 20)
    eq("knob size", toggle.Mark.Size.X.Offset, 16)
    eq("knob at rest", toggle.Mark.Position.X.Offset, 2)
    toggle:SetValue(true)
    eq("knob at travel", toggle.Mark.Position.X.Offset, 36 - 16 - 2)
    eq("knob clears both ends equally", toggle.Mark.Position.X.Offset, 36 - 16 - 2)

    eq("slider track thickness", slider.Track.Size.Y.Offset, 4)
    eq("slider thumb size", slider.Thumb.Size.X.Offset, 11)
    eq("thumb is centre-anchored", slider.Thumb.AnchorPoint.X, 0.5)
    eq("thumb tracks the value", slider.Thumb.Position.X.Scale, 0.16, 1e-6)
    eq("fill tracks the value", slider.Fill.Size.X.Scale, 0.16, 1e-6)
    eq("value pill width", slider.ValuePill.Instance.Size.X.Offset, 36)

    eq("dropdown field is right-anchored", drop.Trigger.Instance.AnchorPoint.X, 1)
    eq("dropdown field width", drop.Trigger.Instance.Size.X.Offset, M.Dropdown.FieldWidth)
    eq("input field is right-anchored", input.Field.Instance.AnchorPoint.X, 1)
    eq("fields share a height", drop.Trigger.Instance.Size.Y.Offset, input.Field.Instance.Size.Y.Offset)
    eq("action button width", action.Body.Size.X.Offset, 34)
    eq("action button height", action.Body.Size.Y.Offset, 24)
    eq("action button is right-anchored", action.Body.AnchorPoint.X, 1)

    --// one hairline sits between each pair of rows
    local shown = 0
    for _, d in left.Dividers do
        if d.Visible then
            shown += 1
        end
    end
    local visible = 0
    for _, e in left.Elements do
        if e.Visible then
            visible += 1
        end
    end
    eq("one hairline between each pair", shown, visible - 1)

    --// logical geometry does not move with DPI
    for _, scale in { 0.8, 1.0, 1.25, 1.5 } do
        library:SetDPIScale(scale)
        checks += 1
        assert(library.DPIScale == scale, "DPI scale did not take")
        -- Logical geometry must not move with DPI: the foundation scales once.
        eq("dpi " .. scale .. " keeps the toggle row", toggle.LayoutHeight, 40)
        eq("dpi " .. scale .. " keeps the knob", toggle.Mark.Position.X.Offset, 18)
        eq("dpi " .. scale .. " keeps the dock pitch", M:DockItemCentre(2) - M:DockItemCentre(1), 40)
    end
    library:SetDPIScale(1)

    --// hiding a tab closes the dock gap
    tabs[2]:SetVisible(false)
    eq("third tab moved up one pitch", tabs[3].Surface.Instance.Position.Y.Offset, M:DockItemCentre(2))
    eq("its indicator followed", tabs[3].Indicator.Position.Y.Offset, M:DockItemCentre(2))
    eq("its hit followed", tabs[3].DockHit.Position.Y.Offset, M:DockItemCentre(2))
    tabs[2]:SetVisible(true)
    eq("restoring puts it back", tabs[3].Surface.Instance.Position.Y.Offset, M:DockItemCentre(3))

    --// containment: nothing in the scroll region sits on the frame's own edge
    local page = home:GetSubTab("General")
    eq("the columns clear the scroll bar and the border lane", page.Columns.Size.X.Offset, shell:_ColumnArea())
    eq(
        "the column area gives up the scroll bar and both stroke lanes",
        shell:_ColumnArea(),
        shell.LogicalSize.X
            - M:ContentOriginX()
            - (M.Content.PaddingLeft + M.Content.PaddingRight)
            - (M.Content.ScrollBarThickness + M.Content.ScrollGutter)
            - M.Content.StrokeGutter * 2
    )
    eq("the scroll region clips", if page.Content.ClipsDescendants then 1 else 0, 1)
    -- A card deliberately does NOT clip. Its rows are inset from its corners, so
    -- clipping bought nothing visually and cost a row whenever a height came out
    -- short: the row vanished instead of overflowing where it could be seen.
    eq("the card surface does not clip", if left.Holder.Instance.ClipsDescendants then 1 else 0, 0)
    -- A card must never be wider than the column holding it, at any window size.
    for _, size in { { 640, 360 }, { 840, 530 }, { 1280, 800 } } do
        shell:SetSize(size[1], size[2])
        eq("card fits its column at " .. size[1], if left.Width <= page.Left.Size.X.Offset then 1 else 0, 1)
        eq("columns fit the area at " .. size[1], page.Columns.Size.X.Offset, shell:_ColumnArea())
    end
    shell:SetSize(M.Window.Width, M.Window.Height)

    eq("no validation errors", #library:Validate(), 0)
    library:Unload()

    -- The audit is only worth anything if it actually ran. A refactor that quietly
    -- skips half of it should fail here rather than pass silently.
    assert(checks > 100, "the audit lost coverage: only " .. tostring(checks) .. " checks ran")
    assert(fails == 0)
end)

print(passed .. " shell geometry tests passed")
