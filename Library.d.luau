--!strict
-- Public contracts for raw and package consumers.
local Core = require(script.Parent.src.Library)
local Foundation = require(script.Parent.src.Types)
local LabelModule = require(script.Parent.src.ui.Label)
local ButtonModule = require(script.Parent.src.ui.Button)
local InputModule = require(script.Parent.src.ui.Input)
local DividerModule = require(script.Parent.src.ui.Divider)

export type Config = Foundation.Config
export type RuntimeAdapter = Foundation.RuntimeAdapter
export type Scheme = Foundation.Scheme
export type Palette = Foundation.Palette
export type ThemeFacade = Core.ThemeFacade
export type Scope = Foundation.Scope
export type Cleanup = Foundation.Cleanup
export type Connection = Cleanup
export type Disposable = { Destroy: (self: Disposable) -> () }
export type CommonOptions = {
    Text: string?,
    Visible: boolean?,
    Disabled: boolean?,
    Tooltip: string?,
    LayoutOrder: number?,
}
export type ValueControl<T> = {
    Value: T,
    Visible: boolean,
    Disabled: boolean,
    Destroyed: boolean,
    SetValue: (self: ValueControl<T>, value: T) -> ValueControl<T>,
    OnChanged: (self: ValueControl<T>, callback: (T) -> ()) -> Connection,
    SetText: (self: ValueControl<T>, text: string) -> ValueControl<T>,
    SetVisible: (self: ValueControl<T>, visible: boolean) -> ValueControl<T>,
    SetDisabled: (self: ValueControl<T>, disabled: boolean) -> ValueControl<T>,
    SetTooltip: (self: ValueControl<T>, text: string) -> Disposable,
    Destroy: (self: ValueControl<T>) -> (),
}
export type ToggleOptions = CommonOptions & { Default: boolean?, Description: string?, Callback: ((boolean) -> ())? }
export type SliderOptions = CommonOptions & {
    Default: number?,
    Min: number?,
    Max: number?,
    Rounding: number?,
    Prefix: string?,
    Suffix: string?,
    Callback: ((number) -> ())?,
}
export type KeyMode = "Always" | "Toggle" | "Hold" | "Press"
export type KeyPickerOptions = CommonOptions & {
    Default: string?,
    Mode: KeyMode?,
    Callback: ((string) -> ())?,
    OnActivated: ((boolean) -> ())?,
}
export type ColorPickerOptions =
    CommonOptions
    & { Default: Color3?, Transparency: number?, Callback: ((Color3, number) -> ())? }
export type DropdownValue = string | { [string]: boolean }
export type DropdownOptions = CommonOptions & {
    Values: { string }?,
    Default: (string | { string } | { [string]: boolean })?,
    Multi: boolean?,
    AllowNull: boolean?,
    Searchable: boolean?,
    Placeholder: string?,
    DisabledValues: { [string]: boolean }?,
    MaxDisplay: number?,
    Width: number?,
    Callback: ((DropdownValue?) -> ())?,
}
export type KeyPicker = ValueControl<string> & {
    Mode: KeyMode,
    Active: boolean,
    Capturing: boolean,
    SetMode: (self: KeyPicker, mode: KeyMode) -> KeyPicker,
    SetActive: (self: KeyPicker, active: boolean) -> (),
    Capture: (self: KeyPicker) -> (),
    CancelCapture: (self: KeyPicker) -> (),
    OnActivated: (self: KeyPicker, callback: (boolean) -> ()) -> Connection,
}
export type ColorPicker = ValueControl<Color3> & {
    Transparency: number,
    IsOpen: boolean,
    SetTransparency: (self: ColorPicker, value: number) -> ColorPicker,
    Open: (self: ColorPicker) -> (),
    Close: (self: ColorPicker) -> (),
    Toggle: (self: ColorPicker) -> (),
}
export type Addons = {
    AddKeyPicker: (self: Addons, id: string, options: KeyPickerOptions?) -> KeyPicker,
    AddColorPicker: (self: Addons, id: string, options: ColorPickerOptions?) -> ColorPicker,
}
export type Toggle = ValueControl<boolean> & Addons & { SetDescription: (self: Toggle, text: string) -> Toggle }
export type Slider = ValueControl<number> & {
    SetMin: (self: Slider, value: number) -> Slider,
    SetMax: (self: Slider, value: number) -> Slider,
}
export type Dropdown = ValueControl<DropdownValue?> & {
    Values: { string },
    Multi: boolean,
    IsOpen: boolean,
    SetValues: (self: Dropdown, values: { string }) -> Dropdown,
    Open: (self: Dropdown) -> (),
    Close: (self: Dropdown) -> (),
}
export type Label = LabelModule.Label
export type LabelOptions = LabelModule.Options
export type Button = ButtonModule.Button
export type ButtonOptions = ButtonModule.Options
export type Input = InputModule.Input
export type InputOptions = InputModule.Options
export type Divider = DividerModule.Divider
export type Control = Toggle | Slider | Input | Dropdown | KeyPicker | ColorPicker
export type Container = {
    AddLabel: (self: Container, options: (LabelOptions | string)?) -> Label,
    AddDivider: (self: Container, options: (string | DividerModule.Options)?) -> Divider,
    AddButton: (self: Container, options: ButtonOptions?) -> Button,
    AddToggle: (self: Container, id: string, options: ToggleOptions?) -> Toggle,
    AddCheckbox: (self: Container, id: string, options: ToggleOptions?) -> Toggle,
    AddSlider: (self: Container, id: string, options: SliderOptions?) -> Slider,
    AddInput: (self: Container, id: string, options: InputOptions?) -> Input,
    AddDropdown: (self: Container, id: string, options: DropdownOptions?) -> Dropdown,
    AddKeyPicker: (self: Container, id: string, options: KeyPickerOptions?) -> KeyPicker,
    AddColorPicker: (self: Container, id: string, options: ColorPickerOptions?) -> ColorPicker,
    AddTabbox: (self: Container, name: string) -> Tabbox,
    AddDependencyBox: (self: Container) -> DependencyBox,
}
export type DependencyBox = Container & {
    SetupDependencies: (self: DependencyBox, dependencies: { { Toggle | boolean } }) -> DependencyBox,
    SetVisible: (self: DependencyBox, visible: boolean) -> DependencyBox,
    SetDisabled: (self: DependencyBox, disabled: boolean) -> DependencyBox,
    Destroy: (self: DependencyBox) -> (),
}
export type Tabbox = {
    AddTab: (self: Tabbox, name: string) -> Container,
    SelectTab: (self: Tabbox, tab: Container | string) -> Container?,
    Destroy: (self: Tabbox) -> (),
}
export type Groupbox = Container & {
    SetName: (self: Groupbox, name: string) -> Groupbox,
    SetDescription: (self: Groupbox, description: string) -> Groupbox,
    SetVisible: (self: Groupbox, visible: boolean) -> Groupbox,
    SetOrder: (self: Groupbox, order: number) -> Groupbox,
    Update: (self: Groupbox, callback: () -> ()) -> Groupbox,
    Destroy: (self: Groupbox) -> (),
}
export type GroupboxOptions = {
    Name: string?,
    Description: string?,
    Side: ("Left" | "Right")?,
    Visible: boolean?,
    LayoutOrder: number?,
    Width: number?,
}
export type Page = {
    AddLeftGroupbox: (self: Page, name: string, description: string?) -> Groupbox,
    AddRightGroupbox: (self: Page, name: string, description: string?) -> Groupbox,
    AddGroupbox: (self: Page, options: GroupboxOptions?) -> Groupbox,
}
export type Navigation = {
    Name: string,
    Visible: boolean,
    Disabled: boolean,
    Active: boolean,
    Select: (self: Navigation) -> Navigation,
    SetVisible: (self: Navigation, visible: boolean) -> Navigation,
    SetDisabled: (self: Navigation, disabled: boolean) -> Navigation,
    SetOrder: (self: Navigation, order: number) -> Navigation,
    Show: (self: Navigation) -> Navigation,
    Hide: (self: Navigation) -> Navigation,
    Destroy: (self: Navigation) -> (),
}
export type SubTab = Page & Navigation
export type SubTabDefinition = { Name: string, Order: number?, Visible: boolean?, Disabled: boolean? }
export type Tab = Page & Navigation & {
    AddSubTab: (self: Tab, definition: string | SubTabDefinition) -> SubTab,
    GetSubTab: (self: Tab, name: string) -> SubTab?,
    GetSubTabs: (self: Tab) -> { SubTab },
    SelectSubTab: (self: Tab, name: string) -> SubTab?,
}
export type TabDefinition = { Name: string, Subtitle: string?, Icon: string?, SubTabs: { string | SubTabDefinition }? }
export type WindowOptions = {
    Title: string?,
    Subtitle: string?,
    Mascot: string?,
    HeaderTabs: boolean?,
    Tabs: { TabDefinition }?,
}
export type NotificationOptions = { Title: string?, Description: string?, Time: number? }
export type DialogOptions = {
    Title: string?,
    Description: string?,
    EscapeDismiss: boolean?,
    Time: number?,
    FooterButtons: { { Title: string?, Order: number?, Variant: string?, Callback: (() -> ())? } }?,
}
export type Dialog = {
    IsOpen: boolean,
    Open: (self: Dialog) -> (),
    Close: (self: Dialog) -> (),
    Destroy: (self: Dialog) -> (),
}
export type Window = {
    AddTab: (self: Window, definition: TabDefinition) -> Tab,
    GetTab: (self: Window, name: string) -> Tab?,
    SelectTab: (self: Window, name: string) -> Tab?,
    SelectSubTab: (self: Window, tabName: string, subTabName: string) -> SubTab?,
    Show: (self: Window) -> Window,
    Hide: (self: Window) -> Window,
    SetVisible: (self: Window, visible: boolean) -> Window,
    Toggle: (self: Window) -> Window,
    SetToggleKey: (self: Window, key: string) -> (),
    SetSize: (self: Window, width: number, height: number) -> Window,
    Notify: (self: Window, options: string | NotificationOptions) -> Disposable,
    AddDialog: (self: Window, id: string, options: DialogOptions) -> Dialog,
    AddSearch: (self: Window, groupbox: Groupbox) -> Input,
    AddKeybindList: (
        self: Window,
        groupbox: Groupbox,
        options: { HideUnused: boolean?, ActiveOnly: boolean? }?
    ) -> Label,
    Destroy: (self: Window) -> (),
}
export type Library = {
    Loaded: boolean,
    Mounted: boolean,
    Unloaded: boolean,
    Options: { [string]: Control },
    Toggles: { [string]: Toggle },
    Labels: { [string]: Label },
    Buttons: { [string]: Button },
    Theme: ThemeFacade,
    Source: Scheme,
    Scheme: Palette,
    DPIScale: number,
    MotionEnabled: boolean,
    Initialize: (self: Library) -> Library,
    Mount: (self: Library) -> Library,
    CreateWindow: (self: Library, options: WindowOptions?) -> Window,
    SetSource: (self: Library, patch: { [string]: Color3 }) -> (),
    SetDPIScale: (self: Library, scale: number) -> (),
    OnUnload: (self: Library, callback: () -> ()) -> Cleanup,
    CreateScope: (self: Library, parent: Scope?) -> Scope,
    Unload: (self: Library) -> (),
}
export type LibraryModule = { new: (config: Config?) -> Library }
export type ThemeManager = {
    SetLibrary: (self: ThemeManager, library: Library) -> ThemeManager,
    SetFolder: (self: ThemeManager, folder: string) -> ThemeManager,
    ApplyToTab: (self: ThemeManager, tab: Tab) -> Groupbox,
    ApplyToGroupbox: (self: ThemeManager, groupbox: Groupbox) -> Groupbox,
    ApplyTheme: (self: ThemeManager, name: string) -> (boolean, string?),
    SaveCustomTheme: (self: ThemeManager, name: string) -> (boolean, string?),
    SaveDefault: (self: ThemeManager, name: string) -> (boolean, string?),
    LoadDefault: (self: ThemeManager) -> boolean,
    SaveJSON: (self: ThemeManager) -> (boolean, string),
    LoadJSON: (self: ThemeManager, content: string) -> (boolean, string?),
}
export type SaveManager = {
    SetLibrary: (self: SaveManager, library: Library) -> SaveManager,
    SetFolder: (self: SaveManager, folder: string) -> SaveManager,
    SetSubFolder: (self: SaveManager, folder: string?) -> SaveManager,
    SetIgnoreIndexes: (self: SaveManager, ids: { string }) -> SaveManager,
    IgnoreThemeSettings: (self: SaveManager) -> SaveManager,
    BuildConfigSection: (self: SaveManager, tab: Tab) -> Groupbox,
    Save: (self: SaveManager, name: string) -> (boolean, string?),
    Load: (self: SaveManager, name: string) -> (boolean, string?),
    Delete: (self: SaveManager, name: string) -> (boolean, string?),
    SaveJSON: (self: SaveManager, name: string?) -> (boolean, string),
    LoadJSON: (self: SaveManager, content: string) -> (boolean, string?),
    SaveAutoloadConfig: (self: SaveManager, name: string) -> (boolean, string?),
    LoadAutoloadConfig: (self: SaveManager) -> boolean,
}

return {}
