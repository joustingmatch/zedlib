--!strict
local Zedlib = require(script.Parent.Parent)

return function()
    local library = Zedlib.Library.new({ OwnershipKey = "zedlib-minimal" })
    library:Initialize()
    library:Mount()

    -- Naming the tabs replaces the default set rather than adding to it.
    local window = Zedlib.UI.Create(library, {
        Title = "Minimal",
        Subtitle = "Example",
        Tabs = { { Name = "Main" } },
    })

    local tab = window:GetTab("Main") :: any
    local box = tab:AddLeftGroupbox("Settings")

    box:AddToggle("Enabled", {
        Text = "Enabled",
        Default = true,
        Callback = function(value)
            print("enabled:", value)
        end,
    })

    box:AddSlider("Speed", {
        Text = "Speed",
        Min = 0,
        Max = 100,
        Default = 25,
        Rounding = 0,
    })

    box:AddDropdown("Mode", {
        Text = "Mode",
        Values = { "Off", "Low", "High" },
        Default = "Low",
    })

    box:AddButton({
        Text = "Unload",
        Callback = function()
            library:Unload()
        end,
    })

    return library, window
end
