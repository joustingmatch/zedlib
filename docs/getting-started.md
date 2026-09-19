# Getting started

Use the root `Library.lua` for raw loading. It returns the library constructor.
Call `.new(config)`, then `:Initialize():Mount()`, then `:CreateWindow(options)`.
Each instance owns its controls, resources, and cleanup. An `OwnershipKey` replaces an older instance with the same key when mounted.

## Studio and package use

The included `default.project.json` maps the root package into `ReplicatedStorage.Zedlib` with Rojo.
Alternatively, create a ModuleScript from `init.luau`, with `src` and `Library.d` children matching the repository paths. Folders containing `init.luau` must become ModuleScripts.

```lua
local Zedlib = require(game:GetService("ReplicatedStorage").Zedlib)
local Library = Zedlib.Library.new({ OwnershipKey = "my-interface" })
Library:Initialize():Mount()
local Window = Library:CreateWindow({ Title = "My interface", Tabs = {} })
```

Run UI code on the client. The default GUI parent is the local player's PlayerGui.
`Runtime.ResolveGuiParent` can supply a different GUI parent. `Runtime.Storage` can supply file and JSON operations for managers.

Both entry points use the same source. Package exports include `Library`, `Types`, `ThemeManager`, and `SaveManager`.
The type declarations are for editor support and package use; raw runtime loading does not fetch them.

See [Example.lua](../Example.lua) for the complete workflow. In Studio, replace its three raw loads with the package exports.
