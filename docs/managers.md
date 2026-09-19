# Managers

Load each manager separately, then pass the mounted library to `SetLibrary`.
Neither manager is included in `Library.lua`. Both use shared serialization helpers from the canonical source.

## Themes

`ThemeManager:SetFolder("Zedlib")` stores themes under `Zedlib/themes`.
`ApplyToTab(settings)` creates a Theme page; `ApplyToGroupbox(groupbox)` uses an existing groupbox.
The generated UI edits colors, selects built-in themes, saves custom themes, and selects a default.
`ApplyTheme(name)` selects a built-in or saved theme. `SaveCustomTheme(name)`, `SaveDefault(name)`, and `LoadDefault()` provide the same operations in code.

## Configs

`SaveManager:SetFolder("Zedlib")` and `SetSubFolder("Example")` store configs under `Zedlib/settings/Example`.
Call `IgnoreThemeSettings()` before building the manager sections. Use `SetIgnoreIndexes({ "MenuKeybind" })` to exclude other IDs.
`BuildConfigSection(settings)` creates the Config page and its save, load, delete, and autoload controls.
`Save(name)`, `Load(name)`, and `Delete(name)` return success and an optional error.

Call `LoadAutoloadConfig()` last, after all persistent controls exist.
Both managers provide `SaveJSON` and `LoadJSON` for explicit transfer. Missing filesystem capabilities are reported in their UI.
