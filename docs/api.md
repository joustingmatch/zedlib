# API

[Example.lua](../Example.lua) is the runnable reference. [Library.d.luau](../Library.d.luau) declares the public control contracts.

## Lifecycle

`Library.new(config)` creates an instance. `Initialize` establishes ownership and runtime services; `Mount` creates the GUI. `CreateWindow` builds the window. `Unload` releases the GUI, connections, tasks, and control registries. `OnUnload(callback)` registers cleanup.

`config` accepts `OwnershipKey`, `Scale`, `ErrorReporting`, `OnError`, and `Runtime`.
`SetDPIScale` takes a scale factor, such as `1.25`. `SetSource` applies a partial source color scheme.

## Navigation

`Window:AddTab({ Name, Subtitle, Icon, SubTabs })` creates a sidebar section.
`Tab:AddSubTab("Name")` creates a top page within that section.
Pages provide `AddLeftGroupbox` and `AddRightGroupbox`. A section with no explicit sub-tabs uses one implicit page.
`SelectTab` and `SelectSubTab` select by name. Tabs and sub-tabs support visibility, disabled state, ordering, and destruction.

Window options are `Title`, `Subtitle`, `Mascot`, `HeaderTabs`, and `Tabs`.
Use `Tabs = {}` to start without the default sections. `SetSize(width, height)` changes window dimensions.
`SetToggleKey` changes the menu key. `Show`, `Hide`, and `Toggle` change visibility.

## Controls

Groupboxes support labels, dividers, buttons, toggles, checkboxes, sliders, inputs, dropdowns, key pickers, color pickers, tabboxes, and dependency boxes.
Value controls take an ID followed by an options table. IDs must be unique within their registry.

`Library.Toggles[id]` contains toggles and checkboxes. `Library.Options[id]` contains other value controls.
Read `.Value`, change it with `SetValue`, and subscribe with `OnChanged`. Subscriptions return a cleanup function.
Declare controls before connecting application logic.

Dropdowns accept `Multi`, `Searchable`, `AllowNull`, and `DisabledValues`. Multi-selection values are maps from label to boolean; defaults also accept lists.
Key pickers accept `Toggle`, `Hold`, `Press`, and `Always` modes. `OnChanged` reports a changed binding; `OnActivated` reports activation.
Color pickers expose `Value` and `Transparency`; `SetValueRGB` is an alias of `SetValue`.

`AddTabbox(name):AddTab(name)` returns another control container.
`AddDependencyBox():SetupDependencies({ { toggle, true } })` controls a nested container's visibility.
Controls accept `Tooltip` or can use `SetTooltip(text)`.

`Window:Notify` creates a timed notification. `Window:AddDialog(id, options)` returns a dialog with `Open` and `Close`.
`AddSearch(groupbox)` adds control search; `AddKeybindList(groupbox, options)` adds a live binding list.
