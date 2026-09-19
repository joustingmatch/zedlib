local repo = "https://raw.githubusercontent.com/joustingmatch/zedlib/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))().new({ OwnershipKey = "zedlib-example" })
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

Library:Initialize():Mount()
local Options = Library.Options
local Toggles = Library.Toggles

local Window = Library:CreateWindow({
    Title = "Zedlib",
    Subtitle = "Controls and settings",
    Tabs = {},
})

-- Primary tabs appear in the sidebar. Each tab owns its top navigation.
local Tabs = {
    Main = Window:AddTab({ Name = "Main", Subtitle = "Inputs and actions" }),
    Visuals = Window:AddTab({ Name = "Visuals", Subtitle = "Colors and layout" }),
    Settings = Window:AddTab({ Name = "Settings", Subtitle = "Menu, themes and configs" }),
}
local Controls = Tabs.Main:AddSubTab("Controls")
local Actions = Tabs.Main:AddSubTab("Actions")
local Appearance = Tabs.Visuals:AddSubTab("Appearance")
local Layout = Tabs.Visuals:AddSubTab("Layout")
local Menu = Tabs.Settings:AddSubTab("Menu")

local Playback = Controls:AddLeftGroupbox("Playback")
Playback:AddLabel({ Text = "Changes below update local example values.", Wrap = true })
Playback:AddDivider("Preferences")
Playback:AddToggle("Enabled", {
    Text = "Enable preview",
    Default = true,
    Description = "Show additional preview options",
    Tooltip = "This controls the dependent settings below.",
})
Playback:AddCheckbox("Loop", { Text = "Repeat preview", Default = false })
Playback:AddSlider("Volume", { Text = "Volume", Min = 0, Max = 100, Default = 40, Rounding = 0, Suffix = "%" })
Playback:AddInput("Caption", { Text = "Caption", Default = "Preview", MaxLength = 32, Placeholder = "Enter a caption" })

local Selection = Controls:AddRightGroupbox("Selection")
Selection:AddDropdown("Quality", {
    Text = "Quality",
    Values = { "Low", "Medium", "High" },
    Default = "Medium",
})
Selection:AddDropdown("Layers", {
    Text = "Visible layers",
    Values = { "Grid", "Labels", "Guides" },
    Multi = true,
    Default = { "Grid", "Labels" },
})
Selection:AddDropdown("Palette", {
    Text = "Palette",
    Values = { "Amber", "Azure", "Coral", "Mint", "Slate", "Violet" },
    Searchable = true,
    AllowNull = true,
    Placeholder = "Find a palette",
})

local Details = Playback:AddDependencyBox()
Details:AddSlider("PreviewScale", { Text = "Preview scale", Min = 0.5, Max = 2, Default = 1, Rounding = 2 })
Details:SetupDependencies({ { Toggles.Enabled, true } })

local Colors = Appearance:AddLeftGroupbox("Highlight")
Colors:AddColorPicker("Highlight", { Text = "Color", Default = Color3.fromRGB(110, 150, 245), Transparency = 0 })
Colors:AddToggle("Outline", { Text = "Outline", Default = true })
    :AddColorPicker("PreviewOutlineColor", { Default = Color3.fromRGB(210, 215, 230) })

local Modes = Layout:AddLeftGroupbox("Layouts"):AddTabbox("Modes")
Modes:AddTab("Compact"):AddToggle("CompactLabels", { Text = "Show labels", Default = true })
Modes:AddTab("Expanded"):AddSlider("Spacing", { Text = "Spacing", Min = 4, Max = 24, Default = 8 })
Window:AddSearch(Layout:AddRightGroupbox("Find controls"))
Window:AddKeybindList(Appearance:AddRightGroupbox("Keybinds"), { HideUnused = true })

local Commands = Actions:AddLeftGroupbox("Commands")
Commands:AddButton({
    Text = "Show notification",
    Callback = function()
        Window:Notify({ Title = "Preview", Description = "Your settings are ready.", Time = 3 })
    end,
})
local Confirm = Window:AddDialog("ResetPreview", {
    Title = "Reset volume?",
    Description = "Restore the example volume to 40 percent.",
    FooterButtons = {
        { Title = "Cancel", Order = 1 },
        {
            Title = "Reset",
            Order = 2,
            Callback = function()
                Options.Volume:SetValue(40)
            end,
        },
    },
})
Commands:AddButton({
    Text = "Reset volume",
    Callback = function()
        Confirm:Open()
    end,
})

-- Declare controls first, then connect application behavior.
Toggles.Enabled:OnChanged(function(Value)
    print("Preview enabled:", Value, Toggles.Enabled.Value)
end)
Options.Volume:OnChanged(function(Value)
    print("Volume:", Value, Options.Volume.Value)
end)
Options.Quality:OnChanged(function(Value)
    print("Quality:", Value)
end)
Toggles.Enabled:SetValue(false)
Toggles.Enabled:SetValue(true)
Options.Volume:SetValue(50)

local MenuControls = Menu:AddLeftGroupbox("Menu")
MenuControls:AddKeyPicker("MenuKeybind", { Text = "Toggle menu", Default = "RightShift", Mode = "Toggle" })
Options.MenuKeybind:OnChanged(function(Value)
    Window:SetToggleKey(Value)
end)
Window:SetToggleKey(Options.MenuKeybind.Value)
MenuControls:AddButton({
    Text = "Unload",
    Callback = function()
        Library:Unload()
    end,
})

-- Managers create their own settings pages. Load configs after every control exists.
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
ThemeManager:SetFolder("Zedlib")
SaveManager:SetFolder("Zedlib")
SaveManager:SetSubFolder("Example")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()

return Library, Window
