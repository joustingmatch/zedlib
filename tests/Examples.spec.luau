-- The examples are code, so they are compiled and run like code.
--
-- Documentation that no longer matches the API is worse than none, and an
-- example is documentation that can be executed. Each one is run against the
-- mock runtime, checked for the controls it claims to create, and unloaded.

local passed = 0
local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    assert(ok, name .. ": " .. tostring(message))
    passed += 1
    print("PASS " .. name)
end

local function resetManagers()
    ThemeManagerModule.Library = nil
    ThemeManagerModule.AppliedToTab = false
    ThemeManagerModule.Options = nil
    ThemeManagerModule.DefaultThemeName = nil
    ThemeManagerModule.ContrastLabel = nil
    ThemeManagerModule.DefaultLabel = nil
    ThemeManagerModule._LowContrast = false
    SaveManagerModule.Library = nil
    SaveManagerModule.Options = nil
    SaveManagerModule.Ignore = {}
    SaveManagerModule.SubFolder = ""
    SaveManagerModule.AutoloadConfig = nil
    SaveManagerModule.AutoloadLabel = nil
end

test("the minimal example runs", function()
    resetManagers()
    local library, window = MinimalExample()
    assert(window:GetTab("Main"), "no Main tab")
    assert(library.Toggles.Enabled and library.Toggles.Enabled.Value == true)
    assert(library.Options.Speed.Value == 25)
    assert(library.Options.Mode.Value == "Low")
    assert(#library:Validate() == 0)
    library:Unload()
end)

test("the managers example runs and wires both managers", function()
    resetManagers()
    local library = ManagersExample()

    assert(ThemeManagerModule.Library == library)
    assert(SaveManagerModule.Library == library)
    assert(ThemeManagerModule:GetPaths().Themes == "ExampleLibrary/themes")
    assert(SaveManagerModule:GetPaths().Configs == "ExampleLibrary/settings/Example")

    -- The point of the example: the theme editor's ids, and the script's own
    -- keybind, are all excluded from configs.
    for _, id in ThemeManagerModule.OptionIds do
        assert(SaveManagerModule.Ignore[id], id .. " is not ignored")
    end
    assert(SaveManagerModule.Ignore.MenuKeybind, "MenuKeybind is not ignored")

    local ok, json = SaveManagerModule:SaveJSON()
    assert(ok, json)
    assert(string.find(json, '"Feature"', 1, true), "ordinary controls are missing")
    assert(not string.find(json, '"AccentColor"', 1, true), "the theme leaked into a config")
    assert(not string.find(json, '"MenuKeybind"', 1, true), "the menu keybind leaked into a config")

    assert(#library:Validate() == 0)
    library:Unload()
end)

test("the full example runs and builds every control type", function()
    resetManagers()
    local library, window = FullExample()

    local seen = {}
    for _, registry in { library.Toggles, library.Options } do
        for _, control in registry do
            seen[control.Type] = (seen[control.Type] or 0) + 1
        end
    end
    for _, kind in { "Toggle", "Slider", "Dropdown", "Input", "ColorPicker", "KeyPicker" } do
        assert(seen[kind], "the full example creates no " .. kind)
    end

    assert(window:GetTab("Controls") and window:GetTab("Layout") and window:GetTab("Settings"))
    assert(library.Toggles.ShowExtras, "the dependency master is missing")
    assert(library.Options.EnabledColor and library.Options.EnabledKey, "toggle addons are missing")

    local report = library:GetDiagnostics()
    assert(report.RegistryProblems == 0, report.RegistryProblems)
    assert(#library:Validate() == 0, table.concat(library:Validate(), "; "))
    library:Unload()
end)

print(passed .. " example tests passed")
