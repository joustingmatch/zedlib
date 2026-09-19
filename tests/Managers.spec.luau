-- ThemeManager and SaveManager regressions.
--
-- Both managers are driven against an in-memory filesystem injected through the
-- runtime adapter, so nothing here touches a disk and every test starts from a
-- known set of files. The point of most of these is not that a happy path works
-- but that the unhappy ones are survivable: a config that names a control which
-- no longer exists, a theme file that is not JSON, a default pointing at a theme
-- someone deleted, a host with no filesystem at all.

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

local Library = LibraryModule
local UI = UIModule
local ThemeManager = ThemeManagerModule
local SaveManager = SaveManagerModule

--// An executor-shaped filesystem, in a table -------------------------------

local function newDisk()
    local files = {}
    local folders = {}
    local disk
    disk = {
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
                    local parent = string.match(name, "^(.*)/[^/]+$")
                    if parent == path then
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
                local contents = files[path]
                if contents == nil then
                    error("no such file: " .. path)
                end
                return contents
            end,
            writefile = function(path, contents)
                local parent = string.match(path, "^(.*)/[^/]+$")
                if parent and not folders[parent] then
                    error("no such folder: " .. tostring(parent))
                end
                files[path] = contents
            end,
            delfile = function(path)
                files[path] = nil
            end,
            setclipboard = function(text)
                disk.Clipboard = text
            end,
            JSON = JSONService,
        },
    }
    return disk
end

-- One live library, window and settings tab, with both managers attached.
local function newSuite(options)
    local config = options or {}
    local disk = config.Disk or newDisk()
    local library = Library.new({
        OwnershipKey = "managers-" .. tostring(math.random(1, 1e9)),
        Runtime = { Storage = if config.NoStorage then { JSON = JSONService } else disk.Adapter },
    })
        :Initialize()
        :Mount()
    local shell = UI.Create(library)

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
    SaveManager.UseLoadingOrder = false
    SaveManager.AutoloadConfig = nil
    SaveManager.AutoloadLabel = nil

    ThemeManager:SetLibrary(library)
    SaveManager:SetLibrary(library)
    ThemeManager:SetFolder("TestHub")
    SaveManager:SetFolder("TestHub")

    return {
        Disk = disk,
        Library = library,
        Shell = shell,
        Tab = shell:GetTab("Home") or shell:AddTab({ Name = "Settings" }),
    }
end

--// Paths and validation ----------------------------------------------------

test("theme and config folders are separate trees under one root", function()
    local suite = newSuite()
    local themePaths = ThemeManager:GetPaths()
    local configPaths = SaveManager:GetPaths()
    assert(themePaths.Themes == "TestHub/themes", themePaths.Themes)
    assert(themePaths.Default == "TestHub/themes/default.txt", themePaths.Default)
    assert(configPaths.Configs == "TestHub/settings", configPaths.Configs)
    assert(configPaths.Autoload == "TestHub/settings/autoload.txt", configPaths.Autoload)
    suite.Library:Unload()
end)

test("a subfolder moves configs and autoload together", function()
    local suite = newSuite()
    SaveManager:SetSubFolder("SomeGame")
    local paths = SaveManager:GetPaths()
    assert(paths.Configs == "TestHub/settings/SomeGame", paths.Configs)
    assert(paths.Autoload == "TestHub/settings/SomeGame/autoload.txt", paths.Autoload)
    suite.Library:Unload()
end)

test("names that could escape the folder are rejected", function()
    local suite = newSuite()
    for _, bad in { "", "  ", "../escape", "a/b", "a\\b", "with:colon", "trailing." } do
        local ok = SaveManager:Save(bad)
        assert(not ok, "accepted " .. string.format("%q", bad))
        local themeOk = ThemeManager:SaveCustomTheme(bad)
        assert(not themeOk, "accepted theme " .. string.format("%q", bad))
    end
    expectError(function()
        SaveManager:SetFolder("../elsewhere")
    end)
    suite.Library:Unload()
end)

test("reserved names are refused by the manager that reserves them", function()
    local suite = newSuite()
    local ok, message = SaveManager:Save("autoload")
    assert(not ok and string.find(message, "reserved"), tostring(message))
    local themeOk, themeMessage = ThemeManager:SaveCustomTheme("default")
    assert(not themeOk and string.find(themeMessage, "reserved"), tostring(themeMessage))
    suite.Library:Unload()
end)

--// ThemeManager -------------------------------------------------------------

test("built-in themes are ordered and complete", function()
    local suite = newSuite()
    local names = ThemeManager:GetBuiltInNames()
    assert(names[1] == "Default", names[1])
    assert(#names == 18, #names)
    for _, name in names do
        local data = ThemeManager:GetBuiltInTheme(name)
        for _, key in { "BackgroundColor", "MainColor", "AccentColor", "OutlineColor", "FontColor" } do
            assert(ThemeManager.ToColor(data[key]), name .. " is missing " .. key)
        end
    end
    suite.Library:Unload()
end)

test("applying a built-in theme changes the source scheme and repaints", function()
    local suite = newSuite()
    local library = suite.Library
    local before = library.Source.AccentColor
    local ok = ThemeManager:ApplyTheme("Nord")
    assert(ok)
    assert(library.Source.AccentColor ~= before, "accent did not change")
    assert(library.Source.AccentColor == Color3.fromRGB(0x88, 0xC0, 0xD0), "wrong accent")
    -- Structural keys are not a theme's business and must survive it.
    assert(library.Source.DarkColor == Color3.new(0, 0, 0), "compositing pole was overwritten")
    assert(#library:Validate() == 0, "registry inconsistent after a theme change")
    suite.Library:Unload()
end)

test("a theme change repaints rather than rebuilding controls", function()
    local suite = newSuite()
    local box = suite.Tab:AddLeftGroupbox("Probe")
    local toggle = box:AddToggle("ProbeToggle", { Text = "Probe", Default = true })
    local slider = box:AddSlider("ProbeSlider", { Text = "Probe", Min = 0, Max = 10, Default = 7 })
    local instance = toggle.Holder

    ThemeManager:ApplyTheme("Dracula")

    assert(toggle.Holder == instance, "the toggle was rebuilt")
    assert(toggle.Value == true, "the toggle lost its value")
    assert(slider.Value == 7, "the slider lost its value")
    suite.Library:Unload()
end)

test("a partial theme edits rather than resets", function()
    local suite = newSuite()
    local library = suite.Library
    ThemeManager:ApplyTheme("Nord")
    local background = library.Source.BackgroundColor
    ThemeManager:ApplyThemeData({ AccentColor = "#FF0000" })
    assert(library.Source.AccentColor == Color3.fromRGB(255, 0, 0), "accent did not apply")
    assert(library.Source.BackgroundColor == background, "background was reset")
    suite.Library:Unload()
end)

test("custom themes round-trip through the filesystem", function()
    local suite = newSuite()
    ThemeManager:ApplyTheme("Gruvbox")
    local saved = ThemeManager:SaveCustomTheme("Mine")
    assert(saved, "could not save")
    assert(suite.Disk.Files["TestHub/themes/Mine.json"], "no file was written")

    ThemeManager:ApplyTheme("Nord")
    assert(suite.Library.Source.AccentColor == Color3.fromRGB(0x88, 0xC0, 0xD0))

    local ok = ThemeManager:ApplyTheme("Mine")
    assert(ok, "could not load the custom theme")
    assert(suite.Library.Source.AccentColor == Color3.fromRGB(0xFA, 0xBD, 0x2F), "wrong accent after load")

    local names = ThemeManager:ReloadCustomThemes()
    assert(#names == 1 and names[1] == "Mine", table.concat(names, ","))
    suite.Library:Unload()
end)

test("the theme list ignores default.txt and tolerates junk files", function()
    local suite = newSuite()
    ThemeManager:BuildFolderTree()
    ThemeManager:SaveDefault("Nord")
    suite.Disk.Files["TestHub/themes/Broken.json"] = "{not json"
    suite.Disk.Files["TestHub/themes/notes.txt"] = "ignore me"
    ThemeManager:ApplyTheme("Nord")
    ThemeManager:SaveCustomTheme("Good")

    local names = ThemeManager:ReloadCustomThemes()
    assert(#names == 2, table.concat(names, ","))
    assert(table.find(names, "Broken") and table.find(names, "Good"), table.concat(names, ","))
    assert(not table.find(names, "default"), "default.txt was listed as a theme")

    -- Listed, but not loadable, and asking for it must not throw.
    assert(ThemeManager:GetCustomTheme("Broken") == nil, "invalid JSON decoded")
    local ok = ThemeManager:ApplyTheme("Broken")
    assert(not ok, "a corrupt theme applied")
    suite.Library:Unload()
end)

test("deleting a theme clears a default that pointed at it", function()
    local suite = newSuite()
    ThemeManager:BuildFolderTree()
    ThemeManager:SaveCustomTheme("Temp")
    local ok = ThemeManager:SaveDefault("Temp")
    assert(ok, "could not set the default")
    assert(ThemeManager:GetDefaultTheme() == "Temp")

    ThemeManager:Delete("Temp")
    assert(ThemeManager:GetDefaultTheme() == nil, "default outlived its theme")
    assert(suite.Disk.Files["TestHub/themes/Temp.json"] == nil, "file was not deleted")
    suite.Library:Unload()
end)

test("no default configured loads quietly", function()
    local suite = newSuite()
    assert(ThemeManager:LoadDefault() == false)
    assert(ThemeManager:GetDefaultTheme() == nil)
    suite.Library:Unload()
end)

test("a default naming a missing theme fails without throwing", function()
    local suite = newSuite()
    ThemeManager:BuildFolderTree()
    suite.Disk.Files["TestHub/themes/default.txt"] = "Vanished"
    assert(ThemeManager:LoadDefault() == false)
    suite.Library:Unload()
end)

test("a default can only name a theme that exists", function()
    local suite = newSuite()
    ThemeManager:BuildFolderTree()
    local ok, message = ThemeManager:SaveDefault("NotAThing")
    assert(not ok and string.find(message, "No theme"), tostring(message))
    suite.Library:Unload()
end)

test("theme JSON export and import use one application path", function()
    local suite = newSuite()
    ThemeManager:ApplyTheme("Monokai")
    local ok, json = ThemeManager:SaveJSON()
    assert(ok, json)

    ThemeManager:ApplyTheme("Nord")
    local loaded, message = ThemeManager:LoadJSON(json)
    assert(loaded, tostring(message))
    assert(suite.Library.Source.AccentColor == Color3.fromRGB(0xA6, 0xE2, 0x2E), "import did not apply")
    suite.Library:Unload()
end)

test("theme import rejects incomplete and malformed input", function()
    local suite = newSuite()
    local cases = {
        { "", "empty" },
        { "   ", "blank" },
        { "{not json", "malformed" },
        { "[1,2,3]", "array" },
        { '{"AccentColor":"#FF0000"}', "partial" },
        {
            '{"BackgroundColor":"#000000","MainColor":"#111111","AccentColor":"nope","OutlineColor":"#222222","FontColor":"#FFFFFF"}',
            "bad colour",
        },
    }
    for _, case in cases do
        local ok = ThemeManager:LoadJSON(case[1])
        assert(not ok, "accepted " .. case[2])
    end
    suite.Library:Unload()
end)

test("SetDefaultTheme redefines the built-in Default entry", function()
    local suite = newSuite()
    ThemeManager:SetDefaultTheme({ AccentColor = Color3.fromRGB(1, 2, 3) })
    local data = ThemeManager:GetBuiltInTheme("Default")
    assert(data.AccentColor == "#010203", data.AccentColor)
    assert(suite.Library.Source.AccentColor == Color3.fromRGB(1, 2, 3), "the running library did not adopt it")
    -- Restore, since the built-in table is module state shared across suites.
    ThemeManager:SetDefaultTheme({ AccentColor = "#6984FA" })
    suite.Library:Unload()
end)

test("the theme UI uses ordinary controls under stable ids", function()
    local suite = newSuite()
    ThemeManager:ApplyToTab(suite.Tab)
    local options = suite.Library.Options
    for _, id in ThemeManager.OptionIds do
        assert(options[id], "no control registered for " .. id)
    end
    assert(options.AccentColor.Type == "ColorPicker", options.AccentColor.Type)
    assert(options.ThemeManager_ThemeList.Type == "Dropdown", options.ThemeManager_ThemeList.Type)
    assert(options.ThemeManager_ThemeJSON.Type == "Input", options.ThemeManager_ThemeJSON.Type)
    suite.Library:Unload()
end)

test("editing a manager colour picker updates the live scheme", function()
    local suite = newSuite()
    ThemeManager:ApplyToTab(suite.Tab)
    suite.Library.Options.AccentColor:SetValue(Color3.fromRGB(10, 20, 30))
    assert(suite.Library.Source.AccentColor == Color3.fromRGB(10, 20, 30), "ThemeUpdate did not run")
    suite.Library:Unload()
end)

test("applying a theme syncs the manager's own pickers", function()
    local suite = newSuite()
    ThemeManager:ApplyToTab(suite.Tab)
    ThemeManager:ApplyTheme("Dracula")
    local picker = suite.Library.Options.AccentColor
    assert(picker.Value == Color3.fromRGB(0xBD, 0x93, 0xF9), "the picker did not follow the theme")
    suite.Library:Unload()
end)

test("the contrast label tracks the live scheme", function()
    local suite = newSuite()
    ThemeManager:ApplyToTab(suite.Tab)
    assert(ThemeManager.ContrastLabel, "no contrast label")

    ThemeManager:ApplyThemeData({ BackgroundColor = "#EEEEEE", MainColor = "#EFEFEF", FontColor = "#F0F0F0" })
    assert(string.find(ThemeManager.ContrastLabel.Text, "Low contrast"), ThemeManager.ContrastLabel.Text)
    assert(ThemeManager._LowContrast, "poor state was not recorded")

    ThemeManager:ApplyTheme("Nord")
    assert(string.find(ThemeManager.ContrastLabel.Text, "good"), ThemeManager.ContrastLabel.Text)
    assert(not ThemeManager._LowContrast)
    suite.Library:Unload()
end)

test("a host without a filesystem still themes, and says why it cannot save", function()
    local suite = newSuite({ NoStorage = true })
    ThemeManager:ApplyToTab(suite.Tab)
    assert(ThemeManager:ApplyTheme("Nord"), "live theming needs no filesystem")
    local ok, message = ThemeManager:SaveCustomTheme("Nope")
    assert(not ok and string.find(message, "does not support"), tostring(message))
    assert(#ThemeManager:ReloadCustomThemes() == 0)
    assert(ThemeManager:GetDefaultTheme() == nil)
    suite.Library:Unload()
end)

--// SaveManager --------------------------------------------------------------

local function buildControls(tab)
    local box = tab:AddLeftGroupbox("Controls")
    local controls = {}
    controls.Toggle = box:AddToggle("Aim", { Text = "Aim", Default = false })
    controls.Slider = box:AddSlider("Smoothing", { Text = "Smoothing", Min = 0, Max = 100, Default = 10, Rounding = 0 })
    controls.Dropdown =
        box:AddDropdown("Bone", { Text = "Bone", Values = { "Head", "Torso", "Root" }, Default = "Head" })
    controls.Multi =
        box:AddDropdown("Parts", { Text = "Parts", Values = { "A", "B", "C" }, Multi = true, Default = { "A" } })
    controls.Color =
        box:AddColorPicker("ChamsColor", { Text = "Chams", Default = Color3.fromRGB(255, 0, 0), Transparency = 0 })
    controls.Key = box:AddKeyPicker("AimKey", { Text = "Aim key", Default = "MouseButton2", Mode = "Hold" })
    controls.Input = box:AddInput("Nickname", { Text = "Nickname", Default = "one" })
    return box, controls
end

test("every persistent control type round-trips", function()
    local suite = newSuite()
    local _, controls = buildControls(suite.Tab)

    controls.Toggle:SetValue(true)
    controls.Slider:SetValue(42)
    controls.Dropdown:SetValue("Torso")
    controls.Multi:SetValue({ "B", "C" })
    controls.Color:SetValue(Color3.fromRGB(0, 128, 255))
    controls.Color:SetTransparency(0.25)
    controls.Key:SetMode("Toggle")
    controls.Key:SetValue("F")
    controls.Key:SetActive(true)
    controls.Input:SetValue("two")

    local ok, json = SaveManager:SaveJSON("probe")
    assert(ok, json)

    controls.Toggle:SetValue(false)
    controls.Slider:SetValue(0)
    controls.Dropdown:SetValue("Root")
    controls.Multi:SetValue({ "A" })
    controls.Color:SetValue(Color3.fromRGB(255, 255, 255))
    controls.Color:SetTransparency(0)
    controls.Key:SetValue("G")
    controls.Key:SetActive(false)
    controls.Input:SetValue("three")

    local loaded, message = SaveManager:LoadJSON(json)
    assert(loaded, tostring(message))

    assert(controls.Toggle.Value == true, "toggle")
    assert(controls.Slider.Value == 42, "slider: " .. tostring(controls.Slider.Value))
    assert(controls.Dropdown.Value == "Torso", "dropdown")
    assert(#controls.Multi.Value == 2, "multi count")
    assert(controls.Color.Value == Color3.fromRGB(0, 128, 255), "colour")
    assert(math.abs(controls.Color.Transparency - 0.25) < 1e-6, "transparency")
    assert(controls.Key.Value == "F", "key")
    assert(controls.Key.Mode == "Toggle", "key mode")
    assert(controls.Key.Active == true, "key toggled state")
    assert(controls.Input.Value == "two", "input")
    suite.Library:Unload()
end)

test("slider values survive as strings without drift", function()
    local suite = newSuite()
    local box = suite.Tab:AddLeftGroupbox("Precision")
    local slider = box:AddSlider("Fine", { Text = "Fine", Min = 0, Max = 1, Default = 0, Rounding = 2 })
    slider:SetValue(0.07)
    local ok, json = SaveManager:SaveJSON()
    assert(ok, json)
    assert(string.find(json, '"value":"0.07"'), json)
    slider:SetValue(1)
    SaveManager:LoadJSON(json)
    assert(math.abs(slider.Value - 0.07) < 1e-9, tostring(slider.Value))
    suite.Library:Unload()
end)

test("a slider value outside a narrowed range clamps instead of failing", function()
    local suite = newSuite()
    local box = suite.Tab:AddLeftGroupbox("Range")
    local slider = box:AddSlider("Wide", { Text = "Wide", Min = 0, Max = 100, Default = 90, Rounding = 0 })
    local ok, json = SaveManager:SaveJSON()
    assert(ok)
    slider:SetMax(50)
    SaveManager:LoadJSON(json)
    assert(slider.Value == 50, tostring(slider.Value))
    suite.Library:Unload()
end)

test("configs survive controls that were removed or renamed", function()
    local suite = newSuite()
    local box, controls = buildControls(suite.Tab)
    controls.Toggle:SetValue(true)
    controls.Input:SetValue("kept")
    local ok, json = SaveManager:SaveJSON()
    assert(ok)

    controls.Dropdown:Destroy()
    controls.Toggle:SetValue(false)
    controls.Input:SetValue("changed")

    local loaded, message = SaveManager:LoadJSON(json)
    assert(loaded, tostring(message))
    assert(string.find(message, "skipped"), message)
    assert(controls.Toggle.Value == true, "surviving control did not load")
    assert(controls.Input.Value == "kept", "surviving input did not load")
    suite.Library:Unload()
    local _ = box
end)

test("unknown types, bad shapes and reused ids are skipped, not fatal", function()
    local suite = newSuite()
    local _, controls = buildControls(suite.Tab)
    controls.Toggle:SetValue(false)

    local payload = JSONService:JSONEncode({
        name = "hostile",
        objects = {
            { type = "Hologram", idx = "Aim", value = true },
            { type = "Toggle", idx = "Smoothing", value = true },
            { type = "Toggle", idx = "Aim", value = true },
            { type = "Slider", idx = "Smoothing", value = "not a number" },
            { type = "Input", idx = "Nickname", text = 42 },
            { idx = "Aim" },
            "a string",
            { type = "Dropdown", idx = "Bone", value = "NotAValue" },
        },
    })

    local ok, message = SaveManager:LoadJSON(payload)
    assert(ok, tostring(message))
    assert(controls.Toggle.Value == true, "the one valid entry did not apply")
    assert(controls.Slider.Value == 10, "a malformed slider changed the value")
    assert(controls.Input.Value == "one", "a non-string input changed the value")
    assert(controls.Dropdown.Value == "Head", "an unknown dropdown value was accepted")
    suite.Library:Unload()
end)

test("a config file that is not a config is refused with a reason", function()
    local suite = newSuite()
    for _, bad in { "", "  ", "{not json", "[1,2]", "{}", '{"objects":5}' } do
        local ok, message = SaveManager:LoadJSON(bad)
        assert(not ok, "accepted " .. string.format("%q", bad))
        assert(type(message) == "string" and message ~= "", "no reason given")
    end
    suite.Library:Unload()
end)

test("save, load, overwrite, delete and list", function()
    local suite = newSuite()
    local _, controls = buildControls(suite.Tab)

    controls.Toggle:SetValue(true)
    assert(SaveManager:Save("one"))
    controls.Toggle:SetValue(false)
    assert(SaveManager:Save("two"))

    local names = SaveManager:RefreshConfigList()
    assert(#names == 2 and names[1] == "one" and names[2] == "two", table.concat(names, ","))

    assert(SaveManager:Load("one"))
    assert(controls.Toggle.Value == true, "load did not restore")

    controls.Toggle:SetValue(false)
    assert(SaveManager:Save("one"), "overwrite failed")
    controls.Toggle:SetValue(true)
    assert(SaveManager:Load("one"))
    assert(controls.Toggle.Value == false, "overwrite did not take")

    assert(SaveManager:Delete("two"))
    assert(#SaveManager:RefreshConfigList() == 1)
    local ok, message = SaveManager:Load("two")
    assert(not ok and string.find(message, "does not exist"), tostring(message))
    suite.Library:Unload()
end)

test("the config list never contains the autoload marker", function()
    local suite = newSuite()
    buildControls(suite.Tab)
    assert(SaveManager:Save("real"))
    assert(SaveManager:SaveAutoloadConfig("real"))
    assert(suite.Disk.Files["TestHub/settings/autoload.txt"] == "real")
    local names = SaveManager:RefreshConfigList()
    assert(#names == 1 and names[1] == "real", table.concat(names, ","))
    suite.Library:Unload()
end)

test("autoload restores on a fresh run and is cleared with its config", function()
    local disk = newDisk()
    local first = newSuite({ Disk = disk })
    local _, controls = buildControls(first.Tab)
    controls.Input:SetValue("remembered")
    assert(SaveManager:Save("main"))
    assert(SaveManager:SaveAutoloadConfig("main"))
    first.Library:Unload()

    -- A second execution against the same disk, as a re-run would be.
    local second = newSuite({ Disk = disk })
    local _, reborn = buildControls(second.Tab)
    assert(reborn.Input.Value == "one", "the control did not start fresh")
    assert(SaveManager:LoadAutoloadConfig(), "autoload did not run")
    assert(reborn.Input.Value == "remembered", "autoload did not restore")

    assert(SaveManager:Delete("main"))
    assert(SaveManager:GetAutoloadConfig() == nil, "autoload outlived its config")
    assert(SaveManager:LoadAutoloadConfig() == false)
    second.Library:Unload()
end)

test("autoload naming a missing config reports rather than throwing", function()
    local suite = newSuite()
    suite.Disk.Folders["TestHub/settings"] = true
    suite.Disk.Files["TestHub/settings/autoload.txt"] = "gone"
    assert(SaveManager:LoadAutoloadConfig() == false)
    suite.Library:Unload()
end)

test("loading order is honoured when enabled", function()
    local suite = newSuite()
    local box = suite.Tab:AddLeftGroupbox("Order")
    local seen = {}
    local toggle = box:AddToggle("Gate", { Text = "Gate", Default = false })
    local input = box:AddInput("Field", { Text = "Field", Default = "" })
    toggle:OnChanged(function()
        table.insert(seen, "Toggle")
    end)
    input:OnChanged(function()
        table.insert(seen, "Input")
    end)

    local payload = JSONService:JSONEncode({
        objects = {
            { type = "Input", idx = "Field", text = "x" },
            { type = "Toggle", idx = "Gate", value = true },
        },
    })

    SaveManager:SetLoadingOrder(true, { "Toggle", "Input" })
    assert(SaveManager:LoadJSON(payload))
    assert(seen[1] == "Toggle" and seen[2] == "Input", table.concat(seen, ","))
    SaveManager:SetLoadingOrder(false)
    suite.Library:Unload()
end)

test("saved objects are sorted, so two saves of one state match", function()
    local suite = newSuite()
    buildControls(suite.Tab)
    local okA, a = SaveManager:SaveJSON()
    local okB, b = SaveManager:SaveJSON()
    assert(okA and okB)
    -- The timestamp is the only field allowed to differ.
    local function strip(text)
        return (string.gsub(text, '"timestamp":%d+', ""))
    end
    assert(strip(a) == strip(b), "two saves of the same state differ")
    suite.Library:Unload()
end)

--// Separation ---------------------------------------------------------------

test("IgnoreThemeSettings keeps every theme id out of a config", function()
    local suite = newSuite()
    SaveManager:IgnoreThemeSettings()
    ThemeManager:ApplyToTab(suite.Tab)
    SaveManager:BuildConfigSection(suite.Tab)
    buildControls(suite.Tab)

    ThemeManager:ApplyTheme("Dracula")
    local ok, json = SaveManager:SaveJSON("mixed")
    assert(ok, json)

    for _, id in ThemeManager.OptionIds do
        assert(not string.find(json, '"' .. id .. '"', 1, true), id .. " leaked into a config")
    end
    -- The manager's own fields go too.
    for _, id in { "SaveManager_ConfigName", "SaveManager_ConfigList", "SaveManager_JSON" } do
        assert(not string.find(json, '"' .. id .. '"', 1, true), id .. " saved itself")
    end
    -- A normal control is still there.
    assert(string.find(json, '"Aim"', 1, true), "ordinary controls were dropped")
    suite.Library:Unload()
end)

test("loading a config leaves the theme alone, and the reverse", function()
    local suite = newSuite()
    local library = suite.Library
    SaveManager:IgnoreThemeSettings()
    ThemeManager:ApplyToTab(suite.Tab)
    SaveManager:BuildConfigSection(suite.Tab)
    local _, controls = buildControls(suite.Tab)

    ThemeManager:ApplyTheme("Nord")
    controls.Toggle:SetValue(true)
    assert(SaveManager:Save("nordish"))

    -- Change both, then restore only the config.
    ThemeManager:ApplyTheme("Monokai")
    controls.Toggle:SetValue(false)
    assert(SaveManager:Load("nordish"))
    assert(controls.Toggle.Value == true, "the config did not restore")
    assert(library.Source.AccentColor == Color3.fromRGB(0xA6, 0xE2, 0x2E), "loading a config changed the theme")

    -- Now restore only the theme.
    controls.Toggle:SetValue(false)
    ThemeManager:ApplyTheme("Nord")
    assert(library.Source.AccentColor == Color3.fromRGB(0x88, 0xC0, 0xD0), "the theme did not change")
    assert(controls.Toggle.Value == false, "loading a theme changed a control value")
    suite.Library:Unload()
end)

test("SetIgnoreIndexes keeps a named control out of configs", function()
    local suite = newSuite()
    SaveManager:SetIgnoreIndexes({ "Nickname" })
    buildControls(suite.Tab)
    local ok, json = SaveManager:SaveJSON()
    assert(ok)
    assert(not string.find(json, '"Nickname"', 1, true), "an ignored id was saved")
    assert(string.find(json, '"Aim"', 1, true))
    suite.Library:Unload()
end)

--// Diagnostics --------------------------------------------------------------

test("diagnostics count what the library holds", function()
    local suite = newSuite()
    SaveManager:IgnoreThemeSettings()
    ThemeManager:ApplyToTab(suite.Tab)
    SaveManager:BuildConfigSection(suite.Tab)
    buildControls(suite.Tab)

    local report = suite.Library:GetDiagnostics()
    assert(report.Mounted and not report.Unloaded)
    assert(report.Toggles >= 1, report.Toggles)
    assert(report.Options >= 10, report.Options)
    assert(report.Groupboxes >= 3, report.Groupboxes)
    assert(report.RegistryInstances > 0)
    assert(report.RegistryProblems == 0, report.RegistryProblems)
    assert(report.Storage == true)
    assert(#suite.Library:Validate() == 0)
    suite.Library:Unload()
end)

test("duplicate ids name both types", function()
    local suite = newSuite()
    local box = suite.Tab:AddLeftGroupbox("Clash")
    box:AddColorPicker("ESPColor", { Text = "ESP" })
    local ok, message = pcall(function()
        box:AddDropdown("ESPColor", { Text = "ESP", Values = { "A" } })
    end)
    assert(not ok)
    message = tostring(message)
    assert(string.find(message, "ESPColor", 1, true), message)
    assert(string.find(message, "ColorPicker", 1, true), message)
    assert(string.find(message, "Dropdown", 1, true), message)
    suite.Library:Unload()
end)

print(passed .. " manager tests passed")
