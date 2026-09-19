--!strict
local Zedlib = require(script.Parent.Parent)

local ThemeManager = Zedlib.ThemeManager
local SaveManager = Zedlib.SaveManager

return function()
    local library = Zedlib.Library.new({ OwnershipKey = "zedlib-full" })
    library:Initialize()
    library:Mount()

    local window = Zedlib.UI.Create(library, {
        Title = "Zedlib",
        Subtitle = "Full example",
        Tabs = {
            { Name = "Controls", Subtitle = "Every control type" },
            { Name = "Layout", Subtitle = "Containers and dependencies" },
            { Name = "Settings", Subtitle = "Themes and configs" },
        },
    })

    local controls = window:GetTab("Controls") :: any
    local layout = window:GetTab("Layout") :: any
    local settings = window:GetTab("Settings") :: any

    --// Values ----------------------------------------------------------------

    local values = controls:AddLeftGroupbox("Values", "One of each, in the order they are documented")

    values:AddLabel({ Text = "Labels wrap when asked to, and measure their own height.", Wrap = true })
    values:AddDivider("Inputs")

    local toggle = values:AddToggle("Enabled", {
        Text = "Enabled",
        Default = true,
        Callback = function(value)
            print("enabled:", value)
        end,
    })

    -- A toggle can carry addons. They are separate options with their own ids,
    -- so they save and load like any other control.
    toggle:AddColorPicker("EnabledColor", { Default = Color3.fromRGB(120, 180, 255) })
    toggle:AddKeyPicker("EnabledKey", { Default = "E", Mode = "Toggle" })

    values:AddCheckbox("Checkbox", { Text = "Checkbox presentation", Default = false })

    values:AddSlider("Amount", {
        Text = "Amount",
        Min = 0,
        Max = 100,
        Default = 40,
        Rounding = 0,
        Suffix = "%",
    })

    values:AddSlider("Precise", {
        Text = "Precise",
        Min = 0,
        Max = 1,
        Default = 0.25,
        Rounding = 2,
    })

    values:AddInput("Nickname", {
        Text = "Nickname",
        Placeholder = "Anyone",
        Default = "",
    })

    values:AddColorPicker("Highlight", {
        Text = "Highlight",
        Default = Color3.fromRGB(255, 120, 90),
        Transparency = 0,
    })

    values:AddKeyPicker("Panic", {
        Text = "Panic key",
        Default = "RightShift",
        Mode = "Hold",
    })

    --// Selection -------------------------------------------------------------

    local selection = controls:AddRightGroupbox("Selection")

    selection:AddDropdown("Quality", {
        Text = "Quality",
        Values = { "Low", "Medium", "High", "Ultra" },
        Default = "Medium",
    })

    selection:AddDropdown("Optional", {
        Text = "Optional",
        Values = { "One", "Two", "Three" },
        AllowNull = true,
        Placeholder = "Nothing selected",
    })

    selection:AddDropdown("Parts", {
        Text = "Parts",
        Values = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" },
        Multi = true,
        Default = { "Head", "Torso" },
    })

    selection:AddDropdown("Searchable", {
        Text = "Searchable",
        Values = { "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta" },
        Default = "Alpha",
        Searchable = true,
    })

    --// Actions ---------------------------------------------------------------

    local actions = controls:AddRightGroupbox("Actions")

    local button = actions:AddButton({
        Text = "Do the thing",
        Callback = function()
            window:Notify({ Title = "Done", Description = "The thing was done.", Time = 3 })
        end,
    })

    -- A second button shares the row with the first.
    button:AddButton({
        Text = "And again",
        Callback = function()
            window:Notify("Again.")
        end,
    })

    actions:AddButton({
        Text = "Something destructive",
        Risky = true,
        DoubleClick = true,
        Callback = function()
            print("confirmed")
        end,
    })

    local dialog = window:AddDialog("FullExampleDialog", {
        Title = "Confirm",
        Description = "Dialogs block the window until one of their buttons is used.",
        FooterButtons = {
            { Title = "Cancel", Order = 1 },
            {
                Title = "Delete",
                Order = 2,
                Variant = "Destructive",
                Callback = function()
                    print("deleted")
                end,
            },
        },
    })

    actions:AddButton({
        Text = "Open a dialog",
        Callback = function()
            dialog:Open()
        end,
    })

    --// Containers ------------------------------------------------------------

    local containers = layout:AddLeftGroupbox("Containers")

    local tabbox = containers:AddTabbox("Modes")
    local first = tabbox:AddTab("First")
    first:AddToggle("FirstToggle", { Text = "In the first tab" })
    local second = tabbox:AddTab("Second")
    second:AddToggle("SecondToggle", { Text = "In the second tab" })

    --// Dependencies ----------------------------------------------------------

    local dependencies = layout:AddRightGroupbox("Dependencies")
    local master = dependencies:AddToggle("ShowExtras", { Text = "Show extras", Default = false })

    -- A dependency box hides itself, and gives up whatever its children were
    -- holding, whenever its condition stops being true.
    local extras = dependencies:AddDependencyBox()
    extras:AddSlider("ExtraAmount", { Text = "Extra amount", Min = 0, Max = 10, Default = 5, Rounding = 0 })
    extras:AddDropdown("ExtraMode", { Text = "Extra mode", Values = { "A", "B" }, Default = "A" })
    extras:SetupDependencies({ { master, true } })

    --// Search ----------------------------------------------------------------

    local find = layout:AddLeftGroupbox("Find")
    window:AddSearch(find)

    --// Keybinds --------------------------------------------------------------

    window:AddKeybindList(layout:AddRightGroupbox("Keybinds"), { HideUnused = true })

    --// Managers --------------------------------------------------------------

    ThemeManager:SetLibrary(library)
    SaveManager:SetLibrary(library)

    SaveManager:IgnoreThemeSettings()
    SaveManager:SetIgnoreIndexes({ "Panic" })

    ThemeManager:SetFolder("ZedlibFullExample")
    SaveManager:SetFolder("ZedlibFullExample")

    ThemeManager:ApplyToTab(settings)
    SaveManager:BuildConfigSection(settings)

    SaveManager:LoadAutoloadConfig()

    --// Teardown --------------------------------------------------------------

    settings:AddLeftGroupbox("Library"):AddButton({
        Text = "Unload",
        Risky = true,
        DoubleClick = true,
        Callback = function()
            library:Unload()
        end,
    })

    return library, window
end
