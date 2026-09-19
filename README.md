# Zedlib

A Roblox UI library with sidebar tabs, nested pages, controls, themes, and config persistence.

## Load

```lua
local repo = "https://raw.githubusercontent.com/joustingmatch/zedlib/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))().new()
Library:Initialize():Mount()
local Window = Library:CreateWindow({ Title = "Zedlib", Tabs = {} })
local Main = Window:AddTab({ Name = "Main" })
Main:AddLeftGroupbox("Preferences"):AddToggle("Enabled", { Text = "Enabled" })
```

Raw loading requires a client host that provides `loadstring` and `game:HttpGet`.
For Studio, use the package entry point described in [Getting started](docs/getting-started.md).

## Example

[Example.lua](Example.lua) demonstrates controls, change handlers, nested navigation, menu keys, and both managers.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/joustingmatch/zedlib/main/Example.lua"))()
```

## Managers

```lua
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local Settings = Window:AddTab({ Name = "Settings" })
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
ThemeManager:SetFolder("Zedlib")
SaveManager:SetFolder("Zedlib")
SaveManager:SetSubFolder("Example")
SaveManager:BuildConfigSection(Settings)
ThemeManager:ApplyToTab(Settings)
SaveManager:LoadAutoloadConfig()
```

Managers are optional. Saving files requires host filesystem support or an injected storage adapter.

## Documentation

- [Getting started](docs/getting-started.md)
- [API](docs/api.md) and [public types](Library.d.luau)
- [Managers](docs/managers.md)
- [Development](docs/development.md)

## License

A license has not been selected. See [LICENSE](LICENSE).
