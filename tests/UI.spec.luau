-- Groupbox, element and control-ownership regressions.
--
-- Everything asserted here is arithmetic or ownership, never appearance. Heights
-- are checked against the elements' own reported heights rather than against
-- constants, so the test states the layout contract instead of restating the
-- implementation's numbers.

local passed = 0
local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    assert(ok, name .. ": " .. tostring(message))
    passed += 1
    print("PASS " .. name)
end

local function expectError(callback)
    assert(not pcall(callback), "Expected an error")
end

local Metrics = UIModule.Metrics

local function activeConnections()
    local total = 0
    for _, connection in allConnections do
        if connection.Connected then
            total += 1
        end
    end
    return total
end

local function mount(): (any, any)
    local library = LibraryModule.new({ OwnershipKey = "ui-spec" }):Initialize():Mount()
    library.ScreenGui.AbsoluteSize = Vector2.new(1000, 800)
    local shell = UIModule.Create(library)
    return library, shell
end

-- The height a groupbox should be, derived from its children rather than from
-- the groupbox's own bookkeeping.
local function expectedHeight(box): number
    local geometry = Metrics.Groupbox
    local total, count = 0, 0
    for _, element in box.Elements do
        if element.Visible and not element.Destroyed then
            total += element.LayoutHeight
            count += 1
        end
    end
    if count == 0 then
        return box.HeaderHeight
    end
    return box.HeaderHeight
        + geometry.PaddingTop
        + total
        + (count - 1) * geometry.ElementSpacing
        + geometry.PaddingBottom
end

local function assertHeight(box, label)
    local expected = expectedHeight(box)
    assert(box.Height == expected, string.format("%s: height %d, expected %d", label, box.Height, expected))
    assert(box.Holder.Instance.Size.Y.Offset == box.Height, label .. ": holder disagrees with state")
end

--// Groupbox geometry --------------------------------------------------------

test("a card's name is outside it, and an empty card has no height", function()
    local library, shell = mount()
    local tab = shell:GetTab("Home")

    -- A name produces an external section label, not an in-card header band.
    -- The card itself is empty, so it has no height at all; the wrapper the
    -- column stacks reports the label and the gap beneath it.
    local named = tab:AddLeftGroupbox("Named")
    assert(named.SectionLabel ~= nil and named.LabelHeight > 0)
    assert(named.Header == nil and named.HeaderHeight == 0)
    assert(named.ContentHeight == 0 and named.Height == 0)
    assert(named.Wrapper.Size.Y.Offset == named.LabelHeight)

    -- A description is the one thing that still opens a header inside the card.
    local described = tab:AddGroupbox({ Name = "Described", Description = "Why" })
    assert(described.Header ~= nil and described.HeaderHeight > 0)
    assert(described.Height == described.HeaderHeight)

    -- No name and no description means neither a label nor a header.
    local bare = tab:AddGroupbox({})
    assert(bare.SectionLabel == nil and bare.LabelHeight == 0)
    assert(bare.Header == nil and bare.HeaderHeight == 0 and bare.Height == 0)

    library:Unload()
end)

test("height is the sum of visible element heights, whatever the mix", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Mixed")

    assertHeight(box, "empty")
    box:AddLabel("One")
    assertHeight(box, "one child")

    box:AddDivider()
    box:AddButton({ Text = "Go" })
    box:AddInput("Field", { Text = "Field" })
    box:AddDropdown("Pick", { Text = "Pick", Values = { "A", "B" } })
    assertHeight(box, "five children")

    for index = 1, 10 do
        box:AddLabel("Filler " .. tostring(index))
    end
    assert(#box.Elements == 15)
    assertHeight(box, "fifteen children")

    library:Unload()
end)

test("hiding and showing children never accumulates layout gaps", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Visibility")
    local label = box:AddLabel("Label")
    local button = box:AddButton({ Text = "Button" })
    local input = box:AddInput("V_Field", { Text = "Field" })
    local dropdown = box:AddDropdown("V_Pick", { Text = "Pick", Values = { "A" } })

    local full = box.Height
    for _ = 1, 3 do
        for _, element in { label, button, input, dropdown } do
            element:SetVisible(false)
            assertHeight(box, "hidden")
            assert(element.Holder.Visible == false)
        end
        assert(box.Height == box.HeaderHeight, "all hidden should collapse to the header")

        for _, element in { label, button, input, dropdown } do
            element:SetVisible(true)
            assertHeight(box, "shown")
        end
        assert(box.Height == full, "restoring should return the original height exactly")
    end

    library:Unload()
end)

test("wrapped labels measure against the content width and resize the box", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Wrapping")

    local short = box:AddLabel("Short")
    local long = box:AddLabel({
        Text = string.rep("wrapped text ", 12),
        Wrap = true,
    })

    assert(long.LayoutHeight > short.LayoutHeight, "a wrapped paragraph is taller than one line")
    assertHeight(box, "wrapped")

    local narrow = long.LayoutHeight
    box:SetWidth(box.Width * 3)
    assert(long.LayoutHeight < narrow, "a wider column needs fewer lines")
    assertHeight(box, "widened")

    -- An unwrapped label is one measured line regardless of how long it is,
    -- plus the row padding that keeps it off the rows above and below it.
    short:SetText(string.rep("no wrapping here ", 20))
    assert(
        short.LayoutHeight
            == short.Host.Typography:LineHeight(short.Host.Typography.Roles.Label) + Metrics.Label.PaddingY * 2
    )
    assertHeight(box, "retexted")

    library:Unload()
end)

test("a description changes the header height and only reserves space when set", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Header")
    local plain = box.HeaderHeight

    box:SetDescription("A short description.")
    assert(box.HeaderHeight > plain)
    local oneLine = box.HeaderHeight

    box:SetDescription(string.rep("a much longer description that has to wrap ", 6))
    assert(box.HeaderHeight > oneLine, "a wrapping description is taller")

    box:SetDescription("")
    assert(box.HeaderHeight == plain, "clearing a description gives the space back")

    library:Unload()
end)

test("columns split the content width exactly", function()
    local library, shell = mount()
    local tab = shell:GetTab("Home")
    local left = tab:AddLeftGroupbox("Left")
    local right = tab:AddRightGroupbox("Right")
    -- Columns belong to a page, not to the section that holds pages. The cards
    -- above went to the section's first page, so that is the one measured.
    local page = tab:GetSubTabs()[1]

    local function check()
        local gap = Metrics.Columns.Gap
        assert(left.Width + gap + right.Width == page.Columns.Size.X.Offset, "columns must span the area")
        assert(
            left.Width - right.Width == 0 or left.Width - right.Width == 1,
            "columns differ by at most the remainder"
        )
        assert(left.ContentWidth == left.Width - Metrics.Groupbox.PaddingLeft - Metrics.Groupbox.PaddingRight)
    end

    check()
    shell:SetSize(1100, 700)
    check()
    shell:SetSize(Metrics.Window.MinWidth, Metrics.Window.MinHeight)
    check()

    library:Unload()
end)

--// Ownership and destruction ------------------------------------------------

test("elements are owned by their groupbox and leave no registry residue", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Ownership")

    local input = box:AddInput("Owned", { Text = "Owned" })
    local dropdown = box:AddDropdown("Picked", { Text = "Picked", Values = { "A" } })
    local button = box:AddButton({ Text = "Act", Id = "Acted" })
    local label = box:AddLabel({ Text = "Note", Id = "Noted" })

    assert(input.Parent == box and dropdown.Parent == box)
    assert(library.Options.Owned == input and library.Options.Picked == dropdown)
    assert(library.Buttons.Acted == button and library.Labels.Noted == label)

    local before = box.Height
    input:Destroy()
    assert(input.Destroyed and library.Options.Owned == nil)
    assert(table.find(box.Elements, input) == nil, "a destroyed element leaves the collection")
    assert(box.Height < before)
    assertHeight(box, "after destroying a child")

    library:Unload()
end)

test("duplicate option ids are rejected, not silently replaced", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Duplicates")
    local first = box:AddInput("Same", { Text = "First" })

    expectError(function()
        box:AddInput("Same", { Text = "Second" })
    end)
    expectError(function()
        box:AddDropdown("Same", { Text = "Second", Values = { "A" } })
    end)
    assert(library.Options.Same == first, "the original control keeps the id")

    library:Unload()
end)

test("destroying a groupbox destroys what it owns", function()
    local library, shell = mount()
    local tab = shell:GetTab("Home")
    local box = tab:AddLeftGroupbox("Doomed")

    local label = box:AddLabel("Label")
    local button = box:AddButton({ Text = "Button", Id = "DoomedButton" })
    local input = box:AddInput("DoomedInput", { Text = "Field" })
    local dropdown = box:AddDropdown("DoomedPick", { Text = "Pick", Values = { "A", "B" } })
    local holder = box.Holder.Instance

    box:Destroy()

    assert(box.Destroyed and #box.Elements == 0)
    for _, element in { label, button, input, dropdown } do
        assert(element.Destroyed, element.Type .. " survived its groupbox")
        assert(element.Resources.Destroyed)
    end
    assert(holder._destroyed, "the groupbox instances are gone")
    assert(library.Options.DoomedInput == nil and library.Options.DoomedPick == nil)
    assert(library.Buttons.DoomedButton == nil)
    assert(table.find(tab.Groupboxes, box) == nil, "the tab no longer lists it")
    assert(library.FocusedControl == nil and library.ActivePopup == nil)

    library:Unload()
end)

test("destroying a tab takes its groupboxes with it", function()
    local library, shell = mount()
    local tab = shell:AddTab({ Name = "Temporary" })
    local box = tab:AddLeftGroupbox("Inside")
    local input = box:AddInput("TempField", { Text = "Field" })

    tab:Destroy()
    assert(input.Destroyed and box.Resources.Destroyed)
    assert(library.Options.TempField == nil)
    assert(shell:GetTab("Temporary") == nil)

    library:Unload()
end)

--// Buttons ------------------------------------------------------------------

test("a button has one activation path, and a disabled one has none", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Buttons")

    local count = 0
    local button = box:AddButton({
        Text = "Press",
        Callback = function()
            count += 1
        end,
    })

    button:Press()
    button:Press()
    assert(count == 2, "programmatic activation runs the callback")

    -- The pointer path ends in the same place.
    button.Main.Surface.Instance.InputBegan:Fire({
        UserInputType = Enum.UserInputType.MouseButton1,
        UserInputState = Enum.UserInputState.Begin,
    })
    button.Main.Surface.Instance.InputEnded:Fire({
        UserInputType = Enum.UserInputType.MouseButton1,
        UserInputState = Enum.UserInputState.End,
    })
    assert(count == 3, "a click runs the callback exactly once")
    assert(button.Main.Pressed == false, "the pressed state is released")

    button:SetDisabled(true)
    button:Press()
    assert(count == 3, "a disabled button ignores activation")

    button:SetDisabled(false)
    button:Press()
    assert(count == 4)

    library:Unload()
end)

test("a throwing callback cannot corrupt the button", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Failures")
    local reached = 0
    local button = box:AddButton({
        Text = "Throws",
        Callback = function()
            reached += 1
            error("deliberate")
        end,
    })

    button:Press()
    button:Press()
    assert(reached == 2, "the button keeps working after a failed callback")
    assert(not button.Destroyed and button.Main.Pressed == false and button.Main.Armed == false)

    library:Unload()
end)

test("double click arms once, fires on the second press, and forgets on hide", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Confirm")
    local fired = 0
    local button = box:AddButton({
        Text = "Reset",
        DoubleClick = true,
        Callback = function()
            fired += 1
        end,
    })

    button:Press()
    assert(fired == 0 and button.Main.Armed, "the first press arms rather than firing")
    assert(button.Main.Label.Text == button.Main.ConfirmText)

    button:Press()
    assert(fired == 1 and not button.Main.Armed)
    assert(button.Main.Label.Text == "Reset", "the prompt is replaced by the button's own text")

    button:Press()
    button:SetVisible(false)
    assert(not button.Main.Armed, "hiding forgets a pending confirmation")
    button:SetVisible(true)
    button:Press()
    assert(fired == 1, "the armed state did not survive being hidden")

    library:Unload()
end)

test("a sub-button shares the row and the pair spans the width", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Paired")
    local main = box:AddButton({ Text = "Main" })
    local sub = main:AddButton({ Text = "Sub" })

    local before = box.Height
    assert(box.Height == before, "a sub-button adds no height")
    assert(main.LayoutHeight == Metrics.Button.Height)

    local mainWidth = main.Main.Surface.Instance.Size.X.Offset
    local subWidth = sub.Face.Surface.Instance.Size.X.Offset
    assert(mainWidth + Metrics.Button.SubGap + subWidth == box.ContentWidth, "the pair spans the content width")
    assert(mainWidth - subWidth == 0 or mainWidth - subWidth == 1)

    local fired = 0
    sub:OnClick(function()
        fired += 1
    end)
    sub:Press()
    assert(fired == 1)

    sub:SetVisible(false)
    assert(main.Main.Surface.Instance.Size.X.Scale == 1, "the main button reclaims the row")

    sub:Destroy()
    assert(main.Sub == nil and not main.Destroyed)

    library:Unload()
end)

--// Inputs -------------------------------------------------------------------

test("a hidden or destroyed input never keeps keyboard focus", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Fields")
    local input = box:AddInput("Focusable", { Text = "Field" })

    input:Focus()
    assert(input.Focused and library.FocusedControl == input)

    input:SetVisible(false)
    assert(not input.Focused and library.FocusedControl == nil, "hiding releases focus")
    assertHeight(box, "input hidden")

    input:SetVisible(true)
    input:Focus()
    assert(input.Focused)

    local second = box:AddInput("Second", { Text = "Second" })
    second:Focus()
    assert(not input.Focused and second.Focused, "focus moves, it does not accumulate")

    second:Destroy()
    assert(library.FocusedControl == nil, "destroying a focused field releases the keyboard")
    assert(library.Options.Second == nil)
    assertHeight(box, "input destroyed")

    library:Unload()
end)

test("input values commit through one path", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Values")

    local seen = {}
    local input = box:AddInput("Committed", {
        Text = "Field",
        Callback = function(value)
            table.insert(seen, value)
        end,
    })

    input:SetValue("hello")
    assert(input.Value == "hello" and seen[1] == "hello")
    input:SetValue("hello")
    assert(#seen == 1, "an unchanged value does not fire")

    local numeric = box:AddInput("Numeric", { Text = "Numeric", Numeric = true })
    numeric:SetValue("-12.5")
    assert(numeric.Value == "-12.5")
    numeric:SetValue("12abc3")
    assert(numeric.Value == "123", "non-numeric characters are filtered")

    local limited = box:AddInput("Limited", { Text = "Limited", MaxLength = 4 })
    limited:SetValue("abcdefgh")
    assert(limited.Value == "abcd")

    library:Unload()
end)

--// Dropdown integration -----------------------------------------------------

local function placeable(dropdown)
    -- Popup placement reads real geometry, which a mock does not produce. These
    -- are the values the engine would have supplied for a trigger on screen.
    local trigger = dropdown.Trigger.Instance
    trigger.AbsolutePosition = Vector2.new(120, 200)
    trigger.AbsoluteSize = Vector2.new(200, Metrics.Dropdown.Height)
end

test("opening a dropdown does not change its groupbox", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Popups")
    local dropdown = box:AddDropdown("Opened", {
        Text = "Opened",
        Values = { "A", "B", "C", "D", "E", "F", "G", "H" },
    })
    placeable(dropdown)

    local closed = box.Height
    dropdown:Open()
    assert(dropdown.IsOpen, "the dropdown should be open")
    assert(box.Height == closed, "an open popup must not grow the groupbox")
    assert(dropdown.LayoutHeight == dropdown.Row.Height)
    assert(library.ActivePopup == dropdown)

    -- The popup is in the overlay layer, not inside the groupbox.
    local popup = dropdown._Popup.Instance
    local ancestor = popup.Parent
    assert(ancestor == library.Overlay, "the popup belongs to the overlay")

    dropdown:Close()
    assert(box.Height == closed and library.ActivePopup == nil)

    library:Unload()
end)

test("a dropdown cannot outlive its groupbox with a popup open", function()
    local library, shell = mount()
    local tab = shell:GetTab("Home")

    local hidden = tab:AddLeftGroupbox("Hidden")
    local first = hidden:AddDropdown("HiddenPick", { Text = "Pick", Values = { "A", "B" } })
    placeable(first)
    first:Open()
    assert(first.IsOpen)
    hidden:SetVisible(false)
    assert(not first.IsOpen and library.ActivePopup == nil, "hiding the box closes the popup")
    assert(next(library.OpenedFrames) == nil, "no orphan popup is left registered")

    local doomed = tab:AddRightGroupbox("Doomed")
    local second = doomed:AddDropdown("DoomedPick", { Text = "Pick", Values = { "A", "B" } })
    placeable(second)
    second:Open()
    local popup = second._Popup.Instance
    doomed:Destroy()
    assert(second.Destroyed and popup._destroyed)
    assert(library.ActivePopup == nil and next(library.OpenedFrames) == nil)
    assert(library.Options.DoomedPick == nil)

    library:Unload()
end)

test("hiding and destroying a dropdown reflows its groupbox", function()
    local library, shell = mount()
    local box = shell:GetTab("Home"):AddLeftGroupbox("Reflow")
    box:AddLabel("Above")
    local dropdown = box:AddDropdown("Reflowed", { Text = "Pick", Values = { "A", "B" } })
    box:AddLabel("Below")
    placeable(dropdown)

    local full = box.Height
    dropdown:Open()
    dropdown:SetVisible(false)
    assert(not dropdown.IsOpen, "a hidden dropdown is a closed dropdown")
    assertHeight(box, "dropdown hidden")
    assert(box.Height < full)

    dropdown:SetVisible(true)
    assert(box.Height == full)

    dropdown:Destroy()
    assert(library.Options.Reflowed == nil)
    assertHeight(box, "dropdown destroyed")

    library:Unload()
end)

test("switching tabs releases popups and focus but keeps state", function()
    local library, shell = mount()
    local home = shell:GetTab("Home")
    local box = home:AddLeftGroupbox("State")
    local dropdown = box:AddDropdown("Kept", { Text = "Pick", Values = { "A", "B" }, Default = "B" })
    local input = box:AddInput("KeptField", { Text = "Field", Default = "typed" })
    placeable(dropdown)

    dropdown:Open()
    input:Focus()
    assert(not dropdown.IsOpen, "focusing a field closes an open popup")

    dropdown:Open()
    shell:SelectTab("Visuals")
    assert(not dropdown.IsOpen and library.ActivePopup == nil)
    assert(library.FocusedControl == nil)

    -- The page is hidden, not destroyed: values and objects survive.
    assert(not dropdown.Destroyed and dropdown.Value == "B")
    assert(input.Value == "typed" and library.Options.KeptField == input)
    assert(box.Height > 0 and not box.Destroyed)

    shell:SelectTab("Home")
    assert(dropdown.Value == "B")

    library:Unload()
end)

--// Teardown -----------------------------------------------------------------

test("unload leaves no live connections or registry entries", function()
    local library, shell = mount()
    local tab = shell:GetTab("Home")
    local box = tab:AddLeftGroupbox("Everything", "With a description.")
    box:AddLabel({ Text = "Wrapped text that is long enough to wrap somewhere", Wrap = true })
    box:AddDivider("Section")
    local button = box:AddButton({ Text = "Act" })
    button:AddButton({ Text = "Also" })
    local input = box:AddInput("AllField", { Text = "Field" })
    local dropdown = box:AddDropdown("AllPick", { Text = "Pick", Values = { "A", "B" } })
    placeable(dropdown)
    dropdown:Open()
    input:Focus()

    library:Unload()

    assert(activeConnections() == 0, "every connection is disconnected")
    assert(next(library.Options) == nil and next(library.Buttons) == nil and next(library.Labels) == nil)
    assert(next(library.Registry) == nil and next(library.OpenedFrames) == nil)
    assert(library.ActivePopup == nil and library.FocusedControl == nil)
    assert(dropdown.Destroyed and input.Destroyed and box.Destroyed and shell.Destroyed)
end)

print(tostring(passed) .. " ui tests passed")
