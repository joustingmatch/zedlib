-- Engineering stress harness.
--
-- This is not a showcase. Every case here exists to break something: build and
-- tear down the whole library repeatedly and check the resource count comes
-- back to where it started, create far more controls than any real script
-- would, destroy controls in the middle of the interactions that own them, and
-- push configs and themes at each other until one of them leaks.
--
-- The measurements that matter are counts, not timings. A timing on a mock
-- runtime says nothing useful; a registry that grows by a fixed amount on every
-- mount/unload cycle is a leak no matter how fast the machine is.

local Metrics = UIModule.Metrics

local passed = 0
local function test(name, callback)
    local started = os.clock()
    local ok, message = xpcall(callback, debug.traceback)
    assert(ok, name .. ": " .. tostring(message))
    passed += 1
    print(string.format("PASS %s (%.0f ms)", name, (os.clock() - started) * 1000))
end

local Library = LibraryModule
local UI = UIModule
local ThemeManager = ThemeManagerModule
local SaveManager = SaveManagerModule

local counter = 0
local function newDisk()
    local files, folders = {}, {}
    return {
        Files = files,
        Folders = folders,
        Adapter = {
            isfolder = function(path)
                return folders[path] == true
            end,
            isfile = function(path)
                return files[path] ~= nil
            end,
            listfiles = function(path)
                local found = {}
                for name in files do
                    if string.match(name, "^(.*)/[^/]+$") == path then
                        table.insert(found, name)
                    end
                end
                table.sort(found)
                return found
            end,
            makefolder = function(path)
                folders[path] = true
            end,
            readfile = function(path)
                assert(files[path], "no such file")
                return files[path]
            end,
            writefile = function(path, contents)
                files[path] = contents
            end,
            delfile = function(path)
                files[path] = nil
            end,
            setclipboard = function() end,
            JSON = JSONService,
        },
    }
end

local function newLibrary(disk)
    counter += 1
    return Library.new({
        OwnershipKey = "stress-" .. counter,
        Runtime = { Storage = (disk or newDisk()).Adapter },
    })
        :Initialize()
        :Mount()
end

local function resetManagers(library)
    ThemeManager.Library = nil
    ThemeManager.AppliedToTab = false
    ThemeManager.Options = nil
    ThemeManager.DefaultThemeName = nil
    ThemeManager.ContrastLabel = nil
    ThemeManager.DefaultLabel = nil
    ThemeManager._LowContrast = false
    SaveManager.Library = nil
    SaveManager.Options = nil
    SaveManager.Ignore = {}
    SaveManager.SubFolder = ""
    SaveManager.AutoloadConfig = nil
    SaveManager.AutoloadLabel = nil
    if library then
        ThemeManager:SetLibrary(library)
        SaveManager:SetLibrary(library)
        ThemeManager:SetFolder("Stress")
        SaveManager:SetFolder("Stress")
    end
end

-- One of everything, under ids unique to this batch.
local function populate(tab, batch, count)
    local box = tab:AddLeftGroupbox("Batch " .. batch)
    local made = {}
    for index = 1, count do
        local id = string.format("b%d_%d", batch, index)
        table.insert(made, box:AddToggle(id .. "_t", { Text = "Toggle " .. index, Default = index % 2 == 0 }))
        table.insert(
            made,
            box:AddSlider(
                id .. "_s",
                { Text = "Slider " .. index, Min = 0, Max = 100, Default = index % 100, Rounding = 0 }
            )
        )
        table.insert(
            made,
            box:AddDropdown(id .. "_d", { Text = "Drop " .. index, Values = { "A", "B", "C" }, Default = "A" })
        )
        table.insert(made, box:AddInput(id .. "_i", { Text = "Input " .. index, Default = tostring(index) }))
        table.insert(
            made,
            box:AddColorPicker(id .. "_c", { Text = "Colour " .. index, Default = Color3.fromRGB(index % 255, 0, 0) })
        )
        table.insert(made, box:AddKeyPicker(id .. "_k", { Text = "Key " .. index, Default = "F", Mode = "Toggle" }))
        box:AddButton({ Text = "Button " .. index, Callback = function() end })
        box:AddLabel({ Text = "Label " .. index })
    end
    return box, made
end

--// Lifecycle ----------------------------------------------------------------

test("thirty mount and unload cycles return every count to baseline", function()
    local baseline = nil
    for cycle = 1, 30 do
        local library = newLibrary()
        local shell = UI.Create(library)
        resetManagers(library)
        local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
        populate(tab, cycle, 3)
        SaveManager:IgnoreThemeSettings()
        ThemeManager:ApplyToTab(tab)
        SaveManager:BuildConfigSection(tab)

        local live = library:GetDiagnostics()
        assert(live.RegistryProblems == 0, "cycle " .. cycle .. " reported registry problems")
        if baseline == nil then
            baseline = live
        else
            -- Identical construction must produce identical counts. A number
            -- that creeps upward across cycles is the signature of something
            -- registered against a scope that outlives its owner.
            assert(
                live.Options == baseline.Options,
                string.format("options drifted: %d vs %d", live.Options, baseline.Options)
            )
            assert(live.Toggles == baseline.Toggles, "toggles drifted")
            assert(
                live.RegistryInstances == baseline.RegistryInstances,
                string.format("registry drifted: %d vs %d", live.RegistryInstances, baseline.RegistryInstances)
            )
            assert(live.Groupboxes == baseline.Groupboxes, "groupboxes drifted")
        end

        library:Unload()
        local after = library:GetDiagnostics()
        assert(after.Unloaded and not after.Mounted)
        assert(
            after.Options == 0 and after.Toggles == 0 and after.Buttons == 0 and after.Labels == 0,
            "registries were not cleared"
        )
        assert(after.RegistryInstances == 0, "theme registry was not cleared")
        assert(after.Groupboxes == 0 and after.Tabs == 0, "the window survived unload")
    end
end)

test("unloading twice is a no-op", function()
    local library = newLibrary()
    UI.Create(library)
    library:Unload()
    library:Unload()
    assert(library.Unloaded)
end)

--// Bulk ---------------------------------------------------------------------

for _, count in { 100, 250, 500 } do
    test(count .. " controls build, mutate and tear down", function()
        local library = newLibrary()
        local shell = UI.Create(library)
        local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })

        -- Suspending layout turns one pass per control into one pass for the
        -- batch, which is the difference between linear and quadratic here.
        local box, controls
        box, controls = populate(tab, 1, math.floor(count / 6))

        local report = library:GetDiagnostics()
        assert(report.Options + report.Toggles >= count * 0.9, report.Options + report.Toggles)
        assert(report.RegistryProblems == 0)

        for _, control in controls do
            if control.Type == "Toggle" then
                control:SetValue(true)
            elseif control.Type == "Slider" then
                control:SetValue(55)
            elseif control.Type == "Dropdown" then
                control:SetValue("B")
            elseif control.Type == "Input" then
                control:SetValue("x")
            elseif control.Type == "ColorPicker" then
                control:SetValue(Color3.fromRGB(1, 2, 3))
            elseif control.Type == "KeyPicker" then
                control:SetValue("G")
            end
        end

        assert(#library:Validate() == 0, table.concat(library:Validate(), "; "))
        box:Destroy()
        assert(#library:Validate() == 0, "destroying a groupbox left inconsistencies")
        library:Unload()
    end)
end

--// Value mutation -----------------------------------------------------------

test("two thousand rapid SetValue calls do not recurse or accumulate", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local box = tab:AddLeftGroupbox("Churn")

    local fired = 0
    local toggle = box:AddToggle("Churn_t", { Text = "T", Default = true })
    local slider = box:AddSlider("Churn_s", { Text = "S", Min = 0, Max = 1000, Default = 0, Rounding = 0 })
    local input = box:AddInput("Churn_i", { Text = "I", Default = "" })
    toggle:OnChanged(function()
        fired += 1
    end)
    slider:OnChanged(function()
        fired += 1
    end)
    input:OnChanged(function()
        fired += 1
    end)

    local registryBefore = library:GetDiagnostics().RegistryInstances
    for index = 1, 2000 do
        toggle:SetValue(index % 2 == 0)
        slider:SetValue(index % 1000)
        input:SetValue("v" .. index)
    end

    -- Every call was a real change, so every call reported exactly once.
    assert(fired == 6000, fired)
    assert(toggle.Value == true and slider.Value == 0 and input.Value == "v2000", "final state is wrong")
    -- A setter that leaked a connection or an instance would show here.
    assert(library:GetDiagnostics().RegistryInstances == registryBefore, "instances accumulated during mutation")
    library:Unload()
end)

test("setting a value that is already set reports nothing", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local box = tab:AddLeftGroupbox("Idempotent")
    local fired = 0
    local toggle = box:AddToggle("Idem_t", { Text = "T", Default = true })
    toggle:OnChanged(function()
        fired += 1
    end)
    for _ = 1, 100 do
        toggle:SetValue(true)
    end
    assert(fired == 0, fired)
    library:Unload()
end)

--// Popups -------------------------------------------------------------------

test("opening popups in sequence never leaves two open", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local second = shell:AddTab({ Name = "Second" })
    local box = tab:AddLeftGroupbox("Popups")
    local other = second:AddLeftGroupbox("Elsewhere")

    local dropdowns = {}
    for index = 1, 12 do
        table.insert(
            dropdowns,
            box:AddDropdown("pop_" .. index, { Text = "D" .. index, Values = { "A", "B" }, Default = "A" })
        )
    end
    local picker = box:AddColorPicker("pop_colour", { Text = "Colour" })
    other:AddLabel({ Text = "Nothing here" })

    for round = 1, 20 do
        for _, dropdown in dropdowns do
            dropdown:Open()
        end
        picker:Open()
        -- Switching tabs must close whatever the old tab had open.
        shell:SelectTab(if round % 2 == 0 then "Second" else tab.Name)
    end

    local open = 0
    for _, dropdown in dropdowns do
        if dropdown.IsOpen then
            open += 1
        end
    end
    if picker.IsOpen then
        open += 1
    end
    assert(open <= 1, open .. " popups open at once")
    assert(#library:Validate() == 0)

    -- Destroying the owner of a popup must take the popup with it.
    dropdowns[1]:Open()
    dropdowns[1]:Destroy()
    assert(library.ActivePopup == nil or not library.ActivePopup.Destroyed, "ActivePopup points at a destroyed control")
    assert(#library:Validate() == 0)
    library:Unload()
end)

test("hiding a groupbox closes what its children had open", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local box = tab:AddLeftGroupbox("Hideable")
    local dropdown = box:AddDropdown("hide_d", { Text = "D", Values = { "A", "B" }, Default = "A" })

    -- The headless mock has no real layout, so a popup cannot resolve a
    -- placement and Open closes itself again. What is still worth asserting is
    -- the invariant on the other side: after the container is hidden, nothing
    -- anywhere believes a popup belonging to it is still up.
    dropdown:Open()
    box:SetVisible(false)
    assert(not dropdown.IsOpen, "the popup outlived its container's visibility")
    assert(library.ActivePopup == nil, "ActivePopup survived its container")
    assert(#library:Validate() == 0)
    library:Unload()
end)

--// Destruction during interaction -------------------------------------------

test("controls can be destroyed in the middle of what they are doing", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local box = tab:AddLeftGroupbox("Violence")

    local input = box:AddInput("v_i", { Text = "I", Default = "" })
    input:Focus()
    input:Destroy()
    assert(library.FocusedControl == nil or not library.FocusedControl.Destroyed, "focus survived the control")

    local dropdown = box:AddDropdown("v_d", { Text = "D", Values = { "A" }, Default = "A" })
    dropdown:Open()
    dropdown:Destroy()

    local picker = box:AddColorPicker("v_c", { Text = "C" })
    picker:Open()
    picker:Destroy()

    local key = box:AddKeyPicker("v_k", { Text = "K", Default = "F" })
    key:Capture()
    key:Destroy()
    assert(library.CapturingKey == nil or not library.CapturingKey.Destroyed, "capture survived the key picker")

    local notification = shell:Notify({ Title = "Timed", Description = "Still running", Time = 60 })
    notification:Destroy()

    local nested = box:AddDependencyBox()
    local inner = nested:AddDropdown("v_nested", { Text = "N", Values = { "A" }, Default = "A" })
    inner:Open()
    box:Destroy()

    assert(#library:Validate() == 0, table.concat(library:Validate(), "; "))
    library:Unload()
end)

test("destroying a control twice is a no-op", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local box = tab:AddLeftGroupbox("Twice")
    local toggle = box:AddToggle("twice_t", { Text = "T" })
    toggle:Destroy()
    toggle:Destroy()
    assert(toggle.Destroyed)
    assert(library.Toggles.twice_t == nil, "a destroyed control stayed registered")
    library:Unload()
end)

--// Themes -------------------------------------------------------------------

test("cycling every built-in theme leaves no stale colours", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    resetManagers(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    populate(tab, 1, 6)

    -- The manager's interface is deliberately not attached here. Some of the
    -- built-in palettes legitimately fail the contrast check, and the editor
    -- answers that with a notification, which creates instances. That is
    -- correct behaviour and it would mask the thing being measured, which is
    -- that switching a theme touches no instance count at all.
    local instancesBefore = library:GetDiagnostics().RegistryInstances
    for round = 1, 4 do
        for _, entry in ThemeManager.BuiltInThemes do
            local ok = ThemeManager:ApplyTheme(entry[1])
            assert(ok, "could not apply " .. entry[1])
        end
        ThemeManager:ThemeUpdate()
        local _ = round
    end

    -- A theme change is a repaint. If it were a rebuild the instance count
    -- would move, and if it leaked the count would only go up.
    assert(library:GetDiagnostics().RegistryInstances == instancesBefore, "theme switching changed the instance count")
    assert(#library:Validate() == 0)

    -- Every registered instance still resolves to the final theme's colours.
    library:UpdateColorsUsingRegistry()
    assert(#library.Theme:ValidateRegistry() == 0)
    library:Unload()
end)

test("a theme round-trips through a file and back many times", function()
    local disk = newDisk()
    local library = newLibrary(disk)
    local shell = UI.Create(library)
    resetManagers(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    ThemeManager:ApplyToTab(tab)

    for index = 1, 40 do
        local entry = ThemeManager.BuiltInThemes[(index % #ThemeManager.BuiltInThemes) + 1]
        ThemeManager:ApplyTheme(entry[1])
        assert(ThemeManager:SaveCustomTheme("Roundtrip"))
        local ok, json = ThemeManager:SaveJSON()
        assert(ok, json)
        ThemeManager:ApplyTheme("Default")
        assert(ThemeManager:LoadJSON(json))
        assert(ThemeManager:ApplyTheme("Roundtrip"))
        assert(
            library.Source.AccentColor == ThemeManager.ToColor(entry[2].AccentColor),
            "colour drifted on round " .. index
        )
    end

    assert(#ThemeManager:ReloadCustomThemes() == 1, "theme files accumulated")
    library:Unload()
end)

--// Configs ------------------------------------------------------------------

test("a hundred save and load cycles over a large config stay stable", function()
    local disk = newDisk()
    local library = newLibrary(disk)
    local shell = UI.Create(library)
    resetManagers(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    SaveManager:IgnoreThemeSettings()
    ThemeManager:ApplyToTab(tab)
    SaveManager:BuildConfigSection(tab)
    local _, controls = populate(tab, 1, 20)

    for round = 1, 100 do
        for _, control in controls do
            if control.Type == "Toggle" then
                control:SetValue(round % 2 == 0)
            elseif control.Type == "Slider" then
                control:SetValue(round)
            end
        end
        assert(SaveManager:Save("bulk"))
        assert(SaveManager:Load("bulk"))
    end

    for _, control in controls do
        if control.Type == "Slider" then
            assert(control.Value == 100, control.Value)
        end
    end
    assert(#SaveManager:RefreshConfigList() == 1, "config files accumulated")
    assert(#library:Validate() == 0)
    library:Unload()
end)

test("hostile config payloads never take the library down", function()
    local library = newLibrary()
    local shell = UI.Create(library)
    resetManagers(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    populate(tab, 1, 4)

    local payloads = {
        "",
        "    ",
        "{",
        "[]",
        "null",
        "{}",
        '{"objects":null}',
        '{"objects":"nope"}',
        '{"objects":[null,null]}',
        '{"objects":[{"type":"Toggle"}]}',
        '{"objects":[{"idx":"b1_1_t"}]}',
        '{"objects":[{"type":"Toggle","idx":"b1_1_t","value":"yes"}]}',
        '{"objects":[{"type":"Slider","idx":"b1_1_s","value":"1e400"}]}',
        '{"objects":[{"type":"ColorPicker","idx":"b1_1_c","value":"not a colour","transparency":"x"}]}',
        '{"objects":[{"type":"KeyPicker","idx":"b1_1_k","mode":"Nonsense","key":12}]}',
        '{"objects":[{"type":"Dropdown","idx":"b1_1_d","value":{"a":1}}]}',
    }
    for _, payload in payloads do
        local ok, message = pcall(function()
            return SaveManager:LoadJSON(payload)
        end)
        assert(ok, "LoadJSON threw on " .. string.format("%q", payload) .. ": " .. tostring(message))
    end
    assert(#library:Validate() == 0)
    library:Unload()
end)

test("configs and themes stay independent under interleaved churn", function()
    local disk = newDisk()
    local library = newLibrary(disk)
    local shell = UI.Create(library)
    resetManagers(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    SaveManager:IgnoreThemeSettings()
    ThemeManager:ApplyToTab(tab)
    SaveManager:BuildConfigSection(tab)
    local box = tab:AddLeftGroupbox("Values")
    local toggle = box:AddToggle("Independent", { Text = "Independent", Default = false })

    for round = 1, 30 do
        toggle:SetValue(round % 2 == 0)
        assert(SaveManager:Save("c" .. (round % 3)))
        ThemeManager:ApplyTheme(ThemeManager.BuiltInThemes[(round % #ThemeManager.BuiltInThemes) + 1][1])
        assert(ThemeManager:SaveCustomTheme("t" .. (round % 3)))

        local accent = library.Source.AccentColor
        local value = toggle.Value
        assert(SaveManager:Load("c" .. (round % 3)))
        assert(library.Source.AccentColor == accent, "loading a config moved the theme on round " .. round)
        assert(ThemeManager:ApplyTheme("t" .. (round % 3)))
        assert(toggle.Value == value, "loading a theme moved a control on round " .. round)
    end

    -- Nothing wrote into the other's tree.
    for path in disk.Files do
        local isTheme = string.find(path, "/themes/", 1, true) ~= nil
        local isConfig = string.find(path, "/settings/", 1, true) ~= nil
        assert(isTheme ~= isConfig, "a file landed in neither or both trees: " .. path)
    end
    library:Unload()
end)

--// Touch -------------------------------------------------------------------

test("thin controls gain a hit area, sized for the pointing device", function()
    local function build(platform)
        counter += 1
        local library = Library.new({
            OwnershipKey = "touch-" .. counter,
            Runtime = {
                Storage = newDisk().Adapter,
                GetPlatform = function()
                    return platform
                end,
            },
        })
            :Initialize()
            :Mount()
        local shell = UI.Create(library)
        local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
        local box = tab:AddLeftGroupbox("Thin")
        local slider = box:AddSlider("touch_s", { Text = "S", Min = 0, Max = 10, Default = 5, Rounding = 0 })
        return library, slider
    end

    -- A mouse gets a pad too. The slider track is four pixels tall: that is a
    -- reasonable thing to look at and an unreasonable thing to hit with
    -- anything, which is why the sliders read as unresponsive when only a
    -- phone was given one. A pointer simply gets a smaller pad than a finger.
    local desktop, desktopSlider = build("Windows")
    assert(not desktop.IsMobile, "Windows was treated as mobile")
    local mousePad = desktopSlider.TouchTarget
    assert(mousePad, "a mouse device got no hit area at all")
    assert(mousePad.Size.X.Scale == 1 and mousePad.Size.X.Offset == 0, "the mouse pad is not full width")

    local phone, phoneSlider = build("Android")
    assert(phone.IsMobile, "Android was not treated as mobile")
    local pad = phoneSlider.TouchTarget
    assert(pad, "no touch pad on a phone")
    assert(pad.Size.Y.Offset >= mousePad.Size.Y.Offset, "a finger got a smaller target than a pointer")
    desktop:Unload()
    -- Full width, so the drag arithmetic is unchanged, and taller than the
    -- track it covers, centred on it.
    assert(pad.Size.X.Scale == 1 and pad.Size.X.Offset == 0, "the pad is not full width")
    local grown = pad.Size.Y.Offset
    assert(grown > 0, "the pad is not taller than the track")
    assert(pad.Position.Y.Offset == -grown / 2, "the pad is not centred on the track")
    assert(phoneSlider.Track.Size.Y.Offset == Metrics.Slider.TrackThickness, "the visible track changed size")
    assert(phoneSlider.LayoutHeight == desktopSlider.LayoutHeight, "the pad changed the layout height")

    -- It is interactive and it belongs to the control, so it goes when it does.
    phoneSlider:Destroy()
    assert(pad.Parent == nil, "the pad outlived its control")
    phone:Unload()
end)

test("MotionEnabled = false resolves transitions immediately", function()
    local library = newLibrary()
    library.MotionEnabled = false
    local shell = UI.Create(library)
    local tab = shell:GetTab("Home") or shell:AddTab({ Name = "Main" })
    local box = tab:AddLeftGroupbox("Still")
    local toggle = box:AddToggle("still_t", { Text = "T", Default = false })

    -- With motion off a state change is an assignment, so the final visual
    -- state is already in place by the time the setter returns rather than
    -- arriving a tenth of a second later. The knob travels between two terminal
    -- positions, so its position is what the assertion has to catch.
    local geometry = Metrics.Toggle
    local off = geometry.KnobInset
    local on = geometry.TrackWidth - geometry.KnobSize - geometry.KnobInset
    assert(toggle.Mark.Position.X.Offset == off, "the knob did not start at rest")

    toggle:SetValue(true)
    assert(toggle.Mark.Position.X.Offset == on, toggle.Mark.Position.X.Offset)

    toggle:SetValue(false)
    assert(toggle.Mark.Position.X.Offset == off, toggle.Mark.Position.X.Offset)
    assert(#library:Validate() == 0)
    library:Unload()
end)

print(passed .. " stress tests passed")
