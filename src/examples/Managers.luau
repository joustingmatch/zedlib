--!strict
local Zedlib = require(script.Parent.Parent)

local ThemeManager = Zedlib.ThemeManager
local SaveManager = Zedlib.SaveManager

return function()
    local library = Zedlib.Library.new({ OwnershipKey = "zedlib-managers" })
    library:Initialize()
    library:Mount()

    local window = Zedlib.UI.Create(library, {
        Title = "Managers",
        Subtitle = "Themes and configs",
        Tabs = { { Name = "Main" }, { Name = "Settings", Subtitle = "Themes and configs" } },
    })

    local main = window:GetTab("Main") :: any
    local settings = window:GetTab("Settings") :: any

    -- Something worth saving, so the config buttons have an effect to show.
    local box = main:AddLeftGroupbox("Features")
    box:AddToggle("Feature", { Text = "Feature", Default = false })
    box:AddSlider("Amount", { Text = "Amount", Min = 0, Max = 10, Default = 3, Rounding = 0 })
    box:AddDropdown("Target", { Text = "Target", Values = { "Head", "Torso" }, Default = "Head" })
    box:AddColorPicker("Highlight", { Text = "Highlight", Default = Color3.fromRGB(120, 180, 255) })
    box:AddKeyPicker("MenuKeybind", { Text = "Menu", Default = "RightShift", Mode = "Toggle" })

    ThemeManager:SetLibrary(library)
    SaveManager:SetLibrary(library)

    SaveManager:IgnoreThemeSettings()
    -- The menu keybind belongs to the script, not to a config: loading someone
    -- else's settings should not change the key that opens the window.
    SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

    ThemeManager:SetFolder("ExampleLibrary")
    SaveManager:SetFolder("ExampleLibrary")
    SaveManager:SetSubFolder("Example")

    ThemeManager:ApplyToTab(settings)
    SaveManager:BuildConfigSection(settings)

    SaveManager:LoadAutoloadConfig()

    return library, window
end
