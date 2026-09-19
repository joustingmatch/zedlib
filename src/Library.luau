--!strict
local Types = require(script.Parent.Types)
local ResourceTracker = require(script.Parent.core.ResourceTracker)
local Runtime = require(script.Parent.core.Runtime)
local Theme = require(script.Parent.core.Theme)
type Scope = Types.Scope
type Cleanup = Types.Cleanup
type Element = Types.BaseElement

local Library = {}
Library.__index = Library

type State = {
    Loaded: boolean,
    Mounted: boolean,
    Unloaded: boolean,
    ScreenGui: ScreenGui?,
    Root: Frame?,
    Overlay: Frame?,
    Window: Element?,
    Toggles: { [string]: Element },
    Options: { [string]: Element },
    Labels: { [string]: Element },
    Buttons: { [string]: Element },
    Registry: { [Instance]: Types.RegistryEntry },
    -- Source is what a theme authors; Scheme is what it resolves to. Scheme is
    -- derived output and is never written directly: assigning a role a colour
    -- that no source value produces would survive exactly until the next
    -- repaint. Go through SetSource.
    Source: Types.Scheme,
    Scheme: Types.Palette,
    Theme: ThemeFacade,
    DPIScale: number,
    DevicePlatform: string,
    IsMobile: boolean,
    ActivePopup: Element?,
    ActiveModal: Element?,
    FocusedControl: Element?,
    OpenedFrames: { [GuiObject]: boolean },
    Input: { Focused: boolean, Keys: { [Enum.KeyCode]: boolean }, Pointer: InputObject? },
    Config: Types.Config,
    Runtime: Runtime.Runtime?,
    Resources: Scope,
    _Scales: { UIScale },
    _Slot: Types.OwnershipSlot?,
    _Mounting: boolean,
    _Reporting: boolean,
    _Addons: { [string]: Scope },
    -- Setting this false makes every transition resolve instantly. It is a
    -- switch, not an accessibility feature: the keyboard and screen-reader work
    -- that would go with one is not here, and this exists so that adding it
    -- later does not require touching every component.
    MotionEnabled: boolean,
}
export type Library = typeof(setmetatable({} :: State, Library))
export type Addon = { Attach: (library: Library, resources: Scope) -> () }

--// Helpers
local function validScale(scale: number): boolean
    return type(scale) == "number" and scale > 0 and scale < math.huge
end

function Library._Report(self: Library, message: string)
    if self.Config.ErrorReporting ~= false then
        warn("[Zedlib] " .. message)
    end
    if self.Config.OnError and not self._Reporting then
        self._Reporting = true
        local hook = self.Config.OnError
        local ok, hookError = pcall(function()
            hook(message)
            return true
        end)
        self._Reporting = false
        if not ok then
            warn("[Zedlib] Error hook failed: " .. tostring(hookError))
        end
    end
end

function Library._AssertLive(self: Library)
    assert(self.Loaded and not self.Unloaded, "Initialize a live library first")
end

--// Theme
-- A deliberately colourless default. Every role resolves to some shade of grey,
-- which makes an unstyled library obviously unstyled rather than accidentally
-- shipping the foundation's taste.
local DEFAULT_SOURCE: Types.Scheme = {
    BackgroundColor = Color3.new(0.10, 0.10, 0.10),
    MainColor = Color3.new(0.16, 0.16, 0.16),
    AccentColor = Color3.new(0.50, 0.50, 0.50),
    OutlineColor = Color3.new(0.26, 0.26, 0.26),
    FontColor = Color3.new(0.92, 0.92, 0.92),
    DestructiveColor = Color3.new(0.78, 0.30, 0.30),
    DarkColor = Color3.new(0, 0, 0),
    WhiteColor = Color3.new(1, 1, 1),
    Font = Font.fromEnum(Enum.Font.SourceSans),
}

-- The public theme surface, bound to one library. Kept small on purpose: a
-- component needs Get, a diagnostic needs the contrast functions, and nothing
-- else should be reachable. The resolver, the ramps and the role table stay
-- inside core/Theme.
export type ThemeFacade = {
    Get: (self: ThemeFacade, role: Types.ThemeRole) -> Color3,
    GetTextOnColor: (self: ThemeFacade, background: Color3) -> Color3,
    GetRelativeLuminance: (self: ThemeFacade, color: Color3) -> number,
    GetContrastRatio: (self: ThemeFacade, foreground: Color3, background: Color3) -> number,
    Composite: (self: ThemeFacade, foreground: Color3, backdrop: Color3, transparency: number) -> Color3,
    AnalyzeContrast: (self: ThemeFacade, pairs: { Types.ContrastPair }?) -> Types.ContrastReport,
    ValidateScheme: (self: ThemeFacade, source: unknown, strict: boolean?) -> Types.ValidationReport,
    GetRegisteredCount: (self: ThemeFacade) -> number,
    ValidateRegistry: (self: ThemeFacade) -> { string },
}

local function newThemeFacade(library: Library): ThemeFacade
    local facade = {}

    -- Fails loudly on an unknown role. A typo must be discoverable at the call
    -- that made it, not three screens later as an unexpectedly white label.
    function facade.Get(_self: ThemeFacade, role: Types.ThemeRole): Color3
        local value = library.Scheme[role]
        if value == nil then
            error(Theme.DescribeUnknownRole(role), 2)
        end
        return value
    end

    function facade.GetTextOnColor(_self: ThemeFacade, background: Color3): Color3
        return Theme.GetTextOnColor(library.Source, background)
    end

    function facade.GetRelativeLuminance(_self: ThemeFacade, color: Color3): number
        return Theme.GetRelativeLuminance(color)
    end

    function facade.GetContrastRatio(_self: ThemeFacade, foreground: Color3, background: Color3): number
        return Theme.GetContrastRatio(foreground, background)
    end

    function facade.Composite(_self: ThemeFacade, foreground: Color3, backdrop: Color3, transparency: number): Color3
        return Theme.Composite(foreground, backdrop, transparency)
    end

    function facade.AnalyzeContrast(_self: ThemeFacade, pairs: { Types.ContrastPair }?): Types.ContrastReport
        return Theme.AnalyzeContrast(library.Scheme, pairs)
    end

    function facade.ValidateScheme(_self: ThemeFacade, source: unknown, strict: boolean?): Types.ValidationReport
        return Theme.ValidateScheme(source, strict)
    end

    --// Diagnostics for developing themes, not for end users.
    function facade.GetRegisteredCount(_self: ThemeFacade): number
        local total = 0
        for _ in library.Registry do
            total += 1
        end
        return total
    end

    -- Reports registry entries that can no longer be repainted. Under normal
    -- operation this is always empty: every binding carries a scope and a
    -- Destroying connection. A non-empty result means something bypassed that.
    function facade.ValidateRegistry(_self: ThemeFacade): { string }
        local problems: { string } = {}
        for instance, entry in library.Registry do
            local alive = pcall(function()
                return instance.Parent
            end)
            if not alive then
                table.insert(problems, "Unreachable instance still registered")
            elseif entry.Resources.Destroyed then
                table.insert(problems, instance.ClassName .. " binding outlived its scope")
            else
                for property, binding in entry.Properties do
                    if type(binding) == "string" and not Theme.IsRole(binding) then
                        table.insert(
                            problems,
                            string.format("%s.%s binds unknown role %q", instance.ClassName, property, binding)
                        )
                    end
                end
            end
        end
        return problems
    end

    return facade :: any
end

function Library.new(config: Types.Config?): Library
    local options: Types.Config = table.clone(config or {} :: Types.Config)
    local adapter = options.Runtime
    options.Runtime = if adapter then table.clone(adapter) else nil
    options.OwnershipKey = options.OwnershipKey or "default"
    assert(type(options.OwnershipKey) == "string" and #options.OwnershipKey > 0, "OwnershipKey must be nonempty")
    local scale = options.Scale or 1
    assert(validScale(scale), "Scale must be finite and positive")
    options.Scale = scale
    local self: Library
    self = setmetatable({
        Loaded = false,
        Mounted = false,
        Unloaded = false,
        ScreenGui = nil,
        Root = nil,
        Overlay = nil,
        Window = nil,
        Toggles = {},
        Options = {},
        Labels = {},
        Buttons = {},
        Registry = {},
        -- A neutral placeholder source, not a visual identity: the foundation
        -- has no opinion about how the interface looks. A palette supplies real
        -- values through SetSource, and Scheme is resolved from whatever that
        -- source happens to be.
        Source = DEFAULT_SOURCE,
        Scheme = Theme.Resolve(DEFAULT_SOURCE),
        Theme = nil :: any,
        DPIScale = scale,
        DevicePlatform = "Unknown",
        IsMobile = false,
        ActivePopup = nil,
        ActiveModal = nil,
        FocusedControl = nil,
        OpenedFrames = {},
        Input = { Focused = false, Keys = {}, Pointer = nil },
        Config = options,
        Runtime = nil,
        Resources = ResourceTracker.new(function(message)
            self:_Report(message)
        end),
        _Scales = {},
        _Slot = nil,
        _Mounting = false,
        _Reporting = false,
        _Addons = {},
        MotionEnabled = true,
    }, Library)
    self.Theme = newThemeFacade(self)
    return self
end

-- Returns xpcall's success flag followed by all results (including nil slots).
-- `any` is restricted to user callback and dynamic Roblox property boundaries.
function Library.SafeCallback(self: Library, callback: any, ...: any): ...any
    if callback == nil then
        return true
    end
    if type(callback) ~= "function" then
        self:_Report("Callback must be a function or nil")
        return false, "Invalid callback"
    end
    return xpcall(callback, function(message)
        local trace = debug.traceback(tostring(message), 2)
        self:_Report(trace)
        return trace
    end, ...)
end

--// Ownership
function Library.CreateScope(self: Library, parent: Scope?): Scope
    self:_AssertLive()
    return (parent or self.Resources):Child()
end

function Library.GiveSignal(self: Library, connection: RBXScriptConnection, scope: Scope?): RBXScriptConnection
    self:_AssertLive()
    local owner = scope or self.Resources
    owner:Add(function()
        connection:Disconnect()
    end)
    return connection
end

function Library.Connect(
    self: Library,
    signal: RBXScriptSignal,
    callback: (...any) -> (),
    scope: Scope?
): RBXScriptConnection
    self:_AssertLive()
    local owner = scope or self.Resources
    assert(not owner.Destroyed, "Connection owner is destroyed")
    return self:GiveSignal(
        signal:Connect(function(...)
            if not self.Unloaded and not owner.Destroyed then
                self:SafeCallback(callback, ...)
            end
        end),
        owner
    )
end

function Library.TrackTask(self: Library, thread: thread, scope: Scope?): Cleanup
    self:_AssertLive()
    return (scope or self.Resources):Add(function()
        if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
            task.cancel(thread)
        end
    end)
end

function Library.TrackTween(self: Library, tween: Tween, scope: Scope?): Cleanup
    self:_AssertLive()
    return (scope or self.Resources):Add(function()
        tween:Cancel()
        tween:Destroy()
    end)
end

function Library.OnUnload(self: Library, callback: () -> ()): Cleanup
    self:_AssertLive()
    return self.Resources:Add(callback)
end

--// Instance factory
function Library._SetProperty(self: Library, instance: Instance, property: string, value: any): boolean
    local ok, message = pcall(function()
        (instance :: any)[property] = value
    end)
    if not ok then
        self:_Report(instance.ClassName .. "." .. property .. ": " .. tostring(message))
    end
    return ok
end

function Library.Create(self: Library, className: string, properties: { [string]: any }?, scope: Scope?): Instance
    self:_AssertLive()
    local owner = scope or self.Resources
    assert(not owner.Destroyed, "Instance owner is destroyed")
    local instance = Instance.new(className)
    local resources = owner:Child()
    resources:Add(function()
        instance:Destroy()
    end)
    resources:Add(function()
        self:UnregisterProperty(instance)
    end)
    self:GiveSignal(
        instance.Destroying:Connect(function()
            resources:Destroy()
        end),
        resources
    )
    local values: { [string]: any } = properties or {}
    for property, value in values do
        if property ~= "Parent" then
            self:_SetProperty(instance, property, value)
        end
    end
    -- Parent last, and treat failed parenting as a construction failure.
    if properties and properties.Parent ~= nil then
        if not self:_SetProperty(instance, "Parent", properties.Parent) then
            resources:Destroy()
            error("Could not parent " .. className, 2)
        end
    end
    return instance
end

--// Theme registry
-- An instance names the roles that control its colour properties; the registry
-- repaints it whenever the source scheme changes. This is what makes a theme
-- change a repaint rather than a rebuild: no instance is recreated, no
-- component callback fires, and no control loses its state.

-- Resolves one binding to a colour, or nil if it cannot be resolved this pass.
-- A resolver returning a role is preferred over one returning a Color3: a value
-- produced outside the palette is invisible to the contrast engine and will not
-- follow the next theme change.
function Library._ResolveBinding(self: Library, binding: Types.ThemeBinding): Color3?
    local role = binding
    if type(role) == "function" then
        local ok, result = pcall(role)
        if not ok then
            self:_Report("Theme resolver failed: " .. tostring(result))
            return nil
        end
        if typeof(result) == "Color3" then
            return result
        end
        role = result
    end
    if type(role) ~= "string" then
        self:_Report("Theme resolver must return a role name or a Color3, got " .. typeof(role))
        return nil
    end
    local value = self.Scheme[role]
    if value == nil then
        self:_Report(Theme.DescribeUnknownRole(role))
        return nil
    end
    return value
end

function Library.UnregisterProperty(self: Library, instance: Instance)
    local entry = self.Registry[instance]
    if not entry then
        return
    end
    self.Registry[instance] = nil
    entry.Resources:Destroy()
end

function Library.RegisterProperty(
    self: Library,
    instance: Instance,
    properties: Types.RegistryProperties,
    scope: Scope?
): Cleanup
    self:_AssertLive()
    assert(self.Registry[instance] == nil, "Instance already has property bindings; unregister first")
    -- Destroy locks Parent. A same-parent assignment also permits live unparented instances.
    local usable = pcall(function()
        instance.Parent = instance.Parent
    end)
    assert(usable, "Cannot bind a destroyed or inaccessible instance")
    -- Static roles are checked here, where the mistake was made. A resolver can
    -- only be checked when it runs, so a bad one is reported at repaint.
    for _, binding in properties do
        if type(binding) ~= "function" then
            assert(Theme.IsRole(binding), Theme.DescribeUnknownRole(binding))
        end
    end
    local resources = self:CreateScope(scope)
    local bindings = table.clone(properties)
    self.Registry[instance] = { Properties = bindings, Resources = resources }
    resources:Add(function()
        self.Registry[instance] = nil
    end)
    self:GiveSignal(
        instance.Destroying:Connect(function()
            resources:Destroy()
        end),
        resources
    )
    self:_PaintInstance(instance, bindings)
    return function()
        resources:Destroy()
    end
end

Library.AddToRegistry = Library.RegisterProperty
Library.RemoveFromRegistry = Library.UnregisterProperty

function Library._PaintInstance(self: Library, instance: Instance, bindings: Types.RegistryProperties)
    for property, binding in bindings do
        local value = self:_ResolveBinding(binding)
        -- A property that will not accept the value is dropped rather than
        -- retried on every repaint; the failure is reported once.
        if value == nil or not self:_SetProperty(instance, property, value) then
            bindings[property] = nil
        end
    end
end

-- The one deterministic repaint path. It resolves and assigns; it does not
-- create instances, does not touch layout, and does not invoke component
-- callbacks. Theme repainting is kept strictly separate from functional state
-- changes, which is why a control that is hovered, focused, open or disabled
-- when the theme changes comes out the other side still hovered, focused, open
-- or disabled -- and repainted for that state, because its resolver is
-- consulted fresh.
function Library.UpdateColorsUsingRegistry(self: Library)
    for instance, entry in self.Registry do
        -- Dead entries are removed rather than skipped, so a registry cannot
        -- grow without bound even if an instance escaped its Destroying signal.
        if entry.Resources.Destroyed or not pcall(function()
            return instance.Parent
        end) then
            self.Registry[instance] = nil
        else
            self:_PaintInstance(instance, entry.Properties)
        end
    end
end

-- Patches the source scheme and repaints. This is the only way the palette
-- changes: roles are derived, so writing Scheme directly would be undone here.
function Library.SetSource(self: Library, patch: { [string]: any })
    self:_AssertLive()
    assert(type(patch) == "table", "Source patch must be a table")
    local merged: { [string]: any } = table.clone(self.Source :: any)
    for key, value in patch do
        merged[key] = value
    end
    local report = Theme.ValidateScheme(merged)
    if not report.Valid then
        error("Invalid source scheme: " .. table.concat(report.Errors, "; "), 2)
    end
    self.Source = merged :: any
    self.Scheme = Theme.Resolve(self.Source)
    self:UpdateColorsUsingRegistry()
end

--// State registry: component owns its scope, registry takes lifetime ownership.
function Library.RegisterElement(self: Library, kind: Types.RegistryKind, id: string, element: Element): Cleanup
    self:_AssertLive()
    assert(kind == "Toggles" or kind == "Options" or kind == "Labels" or kind == "Buttons", "Unknown registry")
    assert(type(id) == "string" and #id > 0, "Element id must be nonempty")
    assert(not element.Destroyed and not element.Resources.Destroyed, "Cannot register a destroyed element")
    local registry = self[kind]
    -- A duplicate id is almost always two controls that were meant to be one,
    -- and the useful part of the report is what is already there: the same
    -- name under two different control types is a copied line, the same name
    -- under the same type is usually a loop that forgot its index.
    local existing = registry[id]
    if existing ~= nil then
        error(
            string.format(
                "Duplicate %s id %q\n  Existing type: %s\n  New type: %s",
                kind,
                id,
                tostring((existing :: any).Type or "unknown"),
                tostring((element :: any).Type or "unknown")
            ),
            2
        )
    end
    registry[id] = element
    local registration = self:CreateScope()
    registration:Add(function()
        if registry[id] == element then
            registry[id] = nil
        end
        if self.ActivePopup == element then
            self.ActivePopup = nil
        end
        if self.ActiveModal == element then
            self.ActiveModal = nil
        end
        if self.FocusedControl == element then
            self.FocusedControl = nil
        end
        if not element.Destroyed then
            self:SafeCallback(element.Destroy, element)
        end
        element.Resources:Destroy()
    end)
    local remove = element.Resources:Add(function()
        registration:Destroy()
    end)
    registration:Add(remove)
    return function()
        registration:Destroy()
    end
end

--// Input and scale: logical offsets are scaled exactly once by ancestor UIScale.
function Library.IsPrimaryPointer(_self: Library, input: InputObject): boolean
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

function Library.IsPointerMovement(_self: Library, input: InputObject): boolean
    return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

function Library.IsInputBegin(_self: Library, input: InputObject): boolean
    return input.UserInputState == Enum.UserInputState.Begin
end

function Library.IsKeyDown(self: Library, key: Enum.KeyCode): boolean
    return self.Input.Keys[key] == true
end

function Library.SetDPIScale(self: Library, scale: number)
    self:_AssertLive()
    assert(validScale(scale), "Scale must be finite and positive")
    self.DPIScale = scale
    self.Config.Scale = scale
    for _, uiScale in self._Scales do
        uiScale.Scale = scale
    end
    -- Full viewport in logical units, so scaled root still occupies the viewport.
    local root, overlay = self.Root, self.Overlay
    if root then
        root.Size = UDim2.fromScale(1 / scale, 1 / scale)
    end
    if overlay then
        overlay.Size = UDim2.fromScale(1 / scale, 1 / scale)
    end
end

function Library.ToLogical(self: Library, physical: Vector2): Vector2
    return physical / self.DPIScale
end

function Library._BindInput(self: Library, scope: Scope)
    local runtime = self.Runtime
    assert(runtime)
    local input = runtime.Input
    local state = self.Input
    local focusedOk, focused = pcall(function()
        return input:IsWindowFocused()
    end)
    state.Focused = if focusedOk then focused else true
    self:Connect(input.InputBegan, function(event: InputObject, processed: boolean)
        if processed or not state.Focused then
            return
        end
        if event.UserInputType == Enum.UserInputType.Keyboard then
            state.Keys[event.KeyCode] = true
        end
        if self:IsPrimaryPointer(event) and state.Pointer == nil then
            state.Pointer = event
        end
    end, scope)
    self:Connect(input.InputEnded, function(event: InputObject)
        state.Keys[event.KeyCode] = nil
        if state.Pointer == event then
            state.Pointer = nil
        end
    end, scope)
    self:Connect(input.WindowFocusReleased, function()
        state.Focused = false
        table.clear(state.Keys)
        state.Pointer = nil
    end, scope)
    self:Connect(input.WindowFocused, function()
        state.Focused = true
    end, scope)
end

--// Addons: setup must not yield; all acquired resources belong to the supplied scope.
function Library.AttachAddon(self: Library, id: string, addon: Addon): Scope?
    self:_AssertLive()
    assert(self._Addons[id] == nil, "Addon already attached: " .. id)
    local scope = self:CreateScope()
    self._Addons[id] = scope
    scope:Add(function()
        self._Addons[id] = nil
    end)
    local ok = self:SafeCallback(addon.Attach, self, scope)
    if not ok or self.Unloaded or scope.Destroyed then
        scope:Destroy()
        return nil
    end
    return scope
end

--// Diagnostics
-- An engineering tool, not a status display. It counts what the library is
-- holding so that a leak shows up as a number that does not come back down
-- across a mount/unload cycle, and it names what is currently interactive so
-- that a stuck popup can be identified without reading the instance tree.
--
-- Nothing here exposes a control, an instance or a user value: a diagnostic
-- that handed back live objects would become an alternative way to reach into
-- the library, and the counts are what is actually useful.
export type Diagnostics = {
    Loaded: boolean,
    Mounted: boolean,
    Unloaded: boolean,
    Toggles: number,
    Options: number,
    Labels: number,
    Buttons: number,
    RegistryInstances: number,
    RegistryProblems: number,
    Tabs: number,
    Groupboxes: number,
    Notifications: number,
    ActivePopup: string?,
    ActiveDialog: string?,
    FocusedControl: string?,
    OpenedFrames: number,
    Addons: { string },
    Scale: number,
    Platform: string,
    Storage: boolean,
}

local function describe(element: any): string?
    if element == nil then
        return nil
    end
    local kind = rawget(element, "Type")
    local text = rawget(element, "Text")
    if type(kind) == "string" and type(text) == "string" and text ~= "" then
        return kind .. " (" .. text .. ")"
    end
    return if type(kind) == "string" then kind else "unknown"
end

function Library.GetDiagnostics(self: Library): Diagnostics
    local function count(registry: { [string]: any }): number
        local total = 0
        for _ in registry do
            total += 1
        end
        return total
    end

    local tabs, groupboxes, notifications = 0, 0, 0
    local window: any = self.Window
    if window and not window.Destroyed then
        for _, tab in window.Tabs do
            if not tab.Destroyed then
                tabs += 1
                for _, box in tab.Groupboxes do
                    if not box.Destroyed then
                        groupboxes += 1
                    end
                end
            end
        end
        local host = window.Host
        local toasts = host and host.Notifications
        if toasts then
            for _, child in toasts:GetChildren() do
                if child:IsA("GuiObject") then
                    notifications += 1
                end
            end
        end
    end

    local frames = 0
    for _ in self.OpenedFrames do
        frames += 1
    end

    local addons: { string } = {}
    for id in self._Addons do
        table.insert(addons, id)
    end
    table.sort(addons)

    return {
        Loaded = self.Loaded,
        Mounted = self.Mounted,
        Unloaded = self.Unloaded,
        Toggles = count(self.Toggles),
        Options = count(self.Options),
        Labels = count(self.Labels),
        Buttons = count(self.Buttons),
        RegistryInstances = self.Theme:GetRegisteredCount(),
        RegistryProblems = #self.Theme:ValidateRegistry(),
        Tabs = tabs,
        Groupboxes = groupboxes,
        Notifications = notifications,
        ActivePopup = describe(self.ActivePopup),
        ActiveDialog = describe(self.ActiveModal),
        FocusedControl = describe(self.FocusedControl),
        OpenedFrames = frames,
        Addons = addons,
        Scale = self.DPIScale,
        Platform = self.DevicePlatform,
        Storage = self.Runtime ~= nil and self.Runtime:HasCapability("FileSystem"),
    }
end

-- Every inconsistency the library can detect in itself, as a list of sentences.
-- An empty list is the normal state; a non-empty one always describes something
-- that leaked or outlived its owner, never a matter of degree.
function Library.Validate(self: Library): { string }
    local problems = self.Theme:ValidateRegistry()

    local function sweep(kind: Types.RegistryKind)
        for id, element in self[kind] :: { [string]: any } do
            if element.Destroyed or element.Resources.Destroyed then
                table.insert(problems, string.format("%s %q is destroyed but still registered", kind, id))
            end
        end
    end
    sweep("Toggles")
    sweep("Options")
    sweep("Labels")
    sweep("Buttons")

    local popup: any = self.ActivePopup
    if popup and popup.Destroyed then
        table.insert(problems, "ActivePopup points at a destroyed control")
    end
    local modal: any = self.ActiveModal
    if modal and modal.Destroyed then
        table.insert(problems, "ActiveDialog points at a destroyed dialog")
    end
    local focused: any = self.FocusedControl
    if focused and focused.Destroyed then
        table.insert(problems, "FocusedControl points at a destroyed control")
    end

    local window: any = self.Window
    if window and not window.Destroyed then
        for _, tab in window.Tabs do
            for _, box in tab.Groupboxes do
                if not box.Destroyed then
                    for _, element in box.Elements do
                        if element.Destroyed then
                            table.insert(
                                problems,
                                string.format(
                                    "Groupbox %q still holds a destroyed %s",
                                    tostring(box.Name),
                                    tostring(element.Type)
                                )
                            )
                        end
                    end
                end
            end
        end
    end

    return problems
end

--// Lifecycle
function Library.Initialize(self: Library): Library
    assert(not self.Unloaded, "Unload is terminal; construct a new library")
    if self.Loaded then
        return self
    end
    local runtime = Runtime.new(self.Config.Runtime)
    self.DevicePlatform, self.IsMobile = runtime:GetPlatform()
    self.Runtime = runtime
    self.Loaded = true
    return self
end

function Library.Mount(self: Library): Library
    self:_AssertLive()
    if self.Mounted then
        return self
    end
    assert(not self._Mounting, "Mount is already in progress")
    local runtime = self.Runtime
    assert(runtime)
    local parent = runtime:ResolveGuiParent()
    assert(parent, "No GUI host available; provide Runtime.ResolveGuiParent or retry when PlayerGui exists")
    local key = self.Config.OwnershipKey :: string
    local previous = runtime.Ownership[key]
    self._Mounting = true
    -- Retire all old resources, not merely the previous ScreenGui.
    if previous then
        local ok, message = pcall(function()
            previous.Release()
            return true
        end)
        if not ok or runtime.Ownership[key] == previous then
            self._Mounting = false
            error("Previous owner did not release its slot: " .. tostring(message), 2)
        end
    end
    if self.Unloaded then
        self._Mounting = false
        error("Library unloaded during ownership transfer", 2)
    end
    if runtime.Ownership[key] ~= nil then
        self._Mounting = false
        error("Ownership was acquired reentrantly during cleanup", 2)
    end
    local scope = self:CreateScope()
    local slot = {
        Release = function()
            self:Unload()
        end,
    }
    self._Slot = slot
    runtime.Ownership[key] = slot
    -- Construction transaction: any required root/parent/input failure rolls back.
    local ok, message = xpcall(function()
        local gui = self:Create("ScreenGui", { Name = "ZedlibFoundation", ResetOnSpawn = false }, scope) :: ScreenGui
        self.ScreenGui = gui
        gui:SetAttribute("ZedlibOwner", key)
        gui:SetAttribute("ZedlibVersion", 1)
        local function layer(name: string): Frame
            local frame = self:Create("Frame", {
                Name = name,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Size = UDim2.fromScale(1 / self.DPIScale, 1 / self.DPIScale),
                Parent = gui,
            }, scope) :: Frame
            local scale = self:Create("UIScale", { Scale = self.DPIScale, Parent = frame }, scope) :: UIScale
            table.insert(self._Scales, scale)
            self:GiveSignal(
                frame.Destroying:Connect(function()
                    self:Unload()
                end),
                scope
            )
            self:GiveSignal(
                scale.Destroying:Connect(function()
                    self:Unload()
                end),
                scope
            )
            return frame
        end
        self.Root = layer("Root")
        local overlay = layer("Overlay")
        self.Overlay = overlay
        overlay.ZIndex = 2
        self:GiveSignal(
            gui.Destroying:Connect(function()
                self:Unload()
            end),
            scope
        )
        -- Direct assignment here: root parenting is required, never an optional warning.
        gui.Parent = parent
        self:_BindInput(scope)
        assert(not self.Unloaded, "Root destroyed while mounting")
    end, debug.traceback)
    self._Mounting = false
    if not ok then
        scope:Destroy()
        if runtime.Ownership[key] == slot then
            runtime.Ownership[key] = nil
        end
        self._Slot = nil
        self.ScreenGui, self.Root, self.Overlay = nil, nil, nil
        table.clear(self._Scales)
        error("Mount failed: " .. tostring(message), 2)
    end
    self.Mounted = true
    return self
end

function Library.Unload(self: Library)
    if self.Unloaded then
        return
    end
    self.Unloaded, self.Mounted, self.Loaded = true, false, false
    -- Keep slot reserved until cleanup completes, preventing reentrant replacements.
    self.Resources:Destroy()
    local runtime = self.Runtime
    local key = self.Config.OwnershipKey :: string
    if runtime and self._Slot and runtime.Ownership[key] == self._Slot then
        runtime.Ownership[key] = nil
    end
    self._Slot = nil
    self.ScreenGui, self.Root, self.Overlay, self.Window = nil, nil, nil, nil
    self.ActivePopup, self.ActiveModal, self.FocusedControl = nil, nil, nil
    for _, registry in { self.Toggles, self.Options, self.Labels, self.Buttons } do
        table.clear(registry)
    end
    table.clear(self.Registry)
    table.clear(self.OpenedFrames)
    table.clear(self._Addons)
    table.clear(self._Scales)
    table.clear(self.Input.Keys)
    self.Input.Pointer, self.Input.Focused = nil, false
    self.Runtime = nil
    self.Config.Runtime, self.Config.OnError = nil, nil
end

return Library
