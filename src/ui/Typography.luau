--!strict
local Metrics = require(script.Parent.Metrics)
local Types = require(script.Parent.Parent.Types)

local TextService = game:GetService("TextService")

local Typography = {}
Typography.__index = Typography

export type Role = {
    Name: string,
    Weight: string, -- key into the resolved font table
    TextSize: number,
    Token: Types.ThemeRole, -- semantic colour role
    Transparency: number,
    XAlignment: Enum.TextXAlignment,
    YAlignment: Enum.TextYAlignment,
}

-- Role definitions. Sizes come from Metrics so the visual rhythm stays in one
-- place; everything else that makes a role a role lives here.
local function role(
    name: string,
    weight: string,
    size: number,
    token: Types.ThemeRole,
    yAlignment: Enum.TextYAlignment?
): Role
    return {
        Name = name,
        Weight = weight,
        TextSize = size,
        Token = token,
        Transparency = 0,
        XAlignment = Enum.TextXAlignment.Left,
        YAlignment = yAlignment or Enum.TextYAlignment.Center,
    }
end

-- Role definitions. Sizes come from Metrics so the visual rhythm stays in one
-- place; everything else that makes a role a role lives here.
--
-- Roles that differ only by colour token share FontFace and TextSize by design:
-- a state change recolours a label, it never re-measures one, so no label can
-- shift by a subpixel when it activates, focuses or disables.
local Text = Metrics.Text
local Top = Enum.TextYAlignment.Top

local ROLES: { [string]: Role } = {
    Identity = role("Identity", "SemiBold", Text.Identity, "Text.Primary"),
    IdentitySub = role("IdentitySub", "Medium", Text.IdentitySub, "Text.Muted"),

    Navigation = role("Navigation", "Medium", Text.Navigation, "Text.Secondary"),
    NavigationActive = role("NavigationActive", "Medium", Text.Navigation, "Text.Primary"),
    NavigationDisabled = role("NavigationDisabled", "Medium", Text.Navigation, "Text.Disabled"),

    PageTitle = role("PageTitle", "SemiBold", Text.PageTitle, "Text.Primary"),

    -- The page-level tab strip. Inactive is muted, active is primary; the two
    -- share weight and size so activating a tab cannot move the label by a
    -- subpixel under its own underline.
    HeaderTab = role("HeaderTab", "Medium", Text.HeaderTab, "Text.Muted"),
    HeaderTabActive = role("HeaderTabActive", "Medium", Text.HeaderTab, "Text.Primary"),
    HeaderTabDisabled = role("HeaderTabDisabled", "Medium", Text.HeaderTab, "Text.Disabled"),

    -- The small uppercase label that sits outside a card, above its top edge.
    -- Uppercasing is done at assignment, not by the font, so the caller's
    -- string stays intact for search and serialisation.
    --
    -- The reference tracks this label out by a fraction of a stud. Roblox text
    -- objects have no letter-spacing property, and the alternatives -- one
    -- label per character, or padding the string with spaces -- both trade a
    -- real layout guarantee for a cosmetic one. The label is set small, muted
    -- and uppercase instead, which is what carries the role.
    SectionLabel = role("SectionLabel", "Medium", Text.SectionLabel, "Text.Muted"),

    -- The dock glyph, when it is a monogram rather than an image. Active sits on
    -- the accent container, so it takes the measured on-accent foreground rather
    -- than assuming white reads against whatever accent a preset chose.
    DockGlyph = role("DockGlyph", "Medium", Text.Navigation, "Text.Muted"),
    DockGlyphHover = role("DockGlyphHover", "Medium", Text.Navigation, "Text.Primary"),
    DockGlyphActive = role("DockGlyphActive", "Medium", Text.Navigation, "Text.OnAccent"),
    DockGlyphDisabled = role("DockGlyphDisabled", "Medium", Text.Navigation, "Text.Disabled"),
    -- Groupbox header. An organisational label, not a page heading: one step
    -- above control text in weight, never in size.
    GroupboxTitle = role("GroupboxTitle", "SemiBold", Text.GroupboxTitle, "Text.Primary"),
    GroupboxDescription = role("GroupboxDescription", "Regular", Text.GroupboxDescription, "Text.Muted", Top),

    Body = role("Body", "Regular", Text.Body, "Text.Secondary", Top),
    Secondary = role("Secondary", "Regular", Text.Secondary, "Text.Muted", Top),

    -- Control text. ControlLabel sits above a control; ControlValue, Input and
    -- Placeholder all sit inside one, and share a size so their baselines line
    -- up exactly across a dropdown trigger and a text field.
    ControlLabel = role("ControlLabel", "Medium", Text.ControlLabel, "Text.Primary"),
    ControlLabelDisabled = role("ControlLabelDisabled", "Medium", Text.ControlLabel, "Text.Disabled"),

    -- The optional second line under a control label. Smaller and one step
    -- dimmer, stacked tight against the label rather than floating under it.
    ControlDescription = role("ControlDescription", "Regular", Text.ControlDescription, "Text.Muted"),
    ControlDescriptionDisabled = role(
        "ControlDescriptionDisabled",
        "Regular",
        Text.ControlDescription,
        "Text.Disabled"
    ),

    ControlValue = role("ControlValue", "Regular", Text.ControlValue, "Text.Primary"),
    ControlValueMuted = role("ControlValueMuted", "Regular", Text.ControlValue, "Text.Muted"),
    ControlValueDisabled = role("ControlValueDisabled", "Regular", Text.ControlValue, "Text.Disabled"),

    -- Free text inside a groupbox. Wrapped labels align to the top so their
    -- first line sits on the same baseline as an unwrapped one.
    Label = role("Label", "Regular", Text.Label, "Text.Secondary", Top),
    LabelSecondary = role("LabelSecondary", "Regular", Text.Label, "Text.Muted", Top),
    LabelDisabled = role("LabelDisabled", "Regular", Text.Label, "Text.Disabled", Top),

    DividerText = role("DividerText", "Medium", Text.DividerText, "Text.Muted"),

    -- Button text. Same size as control value text by design: a button is not a
    -- different typographic class, only a different surface.
    Button = role("Button", "Medium", Text.Button, "Text.Primary"),
    ButtonRisky = role("ButtonRisky", "Medium", Text.Button, "Text.Destructive"),
    ButtonDisabled = role("ButtonDisabled", "Medium", Text.Button, "Text.Disabled"),

    -- Popup list text.
    Item = role("Item", "Regular", Text.Item, "Text.Secondary"),
    ItemSelected = role("ItemSelected", "Regular", Text.Item, "Text.Primary"),
    ItemDisabled = role("ItemDisabled", "Regular", Text.Item, "Text.Disabled"),
    ItemEmpty = role("ItemEmpty", "Regular", Text.Item, "Text.Muted"),
}

-- Font families are resolved once, with fallbacks, and never touched again.
-- rbxasset paths ship with the client: no network access is required.
local FAMILIES = {
    "rbxasset://fonts/families/BuilderSans.json",
    "rbxasset://fonts/families/GothamSSm.json",
    "rbxasset://fonts/families/SourceSansPro.json",
}

local WEIGHTS: { [string]: Enum.FontWeight } = {
    Regular = Enum.FontWeight.Regular,
    Medium = Enum.FontWeight.Medium,
    SemiBold = Enum.FontWeight.SemiBold,
}

local function resolveFonts(): ({ [string]: Font }, string)
    for _, family in FAMILIES do
        local built: { [string]: Font } = {}
        local ok = pcall(function()
            for name, weight in WEIGHTS do
                built[name] = Font.new(family, weight, Enum.FontStyle.Normal)
            end
        end)
        if ok and built.Regular then
            return built, family
        end
    end
    -- Last resort: enum fonts always exist, but lose weight differentiation.
    local fallback = Font.fromEnum(Enum.Font.Gotham)
    return { Regular = fallback, Medium = fallback, SemiBold = fallback }, "enum:Gotham"
end

export type Typography = typeof(setmetatable(
    {} :: {
        Library: any,
        Fonts: { [string]: Font },
        Family: string,
        Roles: { [string]: Role },
        _Scope: Types.Scope,
        _Probe: TextLabel?,
        _CanMeasureAsync: boolean,
        _LineHeights: { [string]: number },
        _Labels: { [Instance]: Role },
    },
    Typography
))

function Typography.new(library: any, scope: Types.Scope): Typography
    local fonts, family = resolveFonts()
    local runtime = library.Runtime
    return setmetatable({
        Library = library,
        Fonts = fonts,
        Family = family,
        Roles = ROLES,
        _Scope = scope,
        _Probe = nil,
        _CanMeasureAsync = runtime ~= nil and runtime:HasCapability("TextBounds"),
        _LineHeights = {},
        -- Every text instance this typography created, with the role it wears.
        -- A font change is a reassignment over this set: no instance is rebuilt,
        -- exactly as a colour change is a repaint over the theme registry.
        _Labels = setmetatable({}, { __mode = "k" }) :: any,
    }, Typography)
end

function Typography.FontFor(self: Typography, role: Role): Font
    return self.Fonts[role.Weight] or self.Fonts.Regular
end

-- A hidden, library-owned label used as the measurement fallback when the
-- text-bounds API is unavailable or throws. Created lazily, destroyed with scope.
function Typography._GetProbe(self: Typography): TextLabel?
    local probe = self._Probe
    if probe then
        return probe
    end
    local root = self.Library.Root
    if not root then
        return nil
    end
    local ok, created = pcall(function()
        return self.Library:Create("TextLabel", {
            Name = "TextMeasurementProbe",
            BackgroundTransparency = 1,
            TextTransparency = 1,
            Visible = false,
            Size = UDim2.fromOffset(4096, 4096),
            Text = "",
            Parent = root,
        }, self._Scope)
    end)
    if not ok then
        return nil
    end
    self._Probe = created :: TextLabel
    return self._Probe
end

-- Measures text in LOGICAL units. Callers must divide any AbsoluteSize they pass
-- as `width` by Library.DPIScale first; results are logical and are never scaled
-- again here.
function Typography.Measure(self: Typography, text: string, role: Role, width: number?): Vector2
    local font = self:FontFor(role)
    local constraint = width
    if constraint ~= nil then
        constraint = math.max(1, constraint)
    end

    if self._CanMeasureAsync then
        local ok, bounds = pcall(function()
            local params = Instance.new("GetTextBoundsParams")
            params.Text = text
            params.Font = font
            params.Size = role.TextSize
            params.RichText = false
            if constraint then
                params.Width = constraint
            end
            local result = TextService:GetTextBoundsAsync(params)
            params:Destroy()
            return result
        end)
        if ok and typeof(bounds) == "Vector2" then
            return bounds
        end
        -- One failure is enough: stop paying for pcall on every later measurement.
        self._CanMeasureAsync = false
    end

    local probe = self:_GetProbe()
    if probe then
        probe.FontFace = font
        probe.TextSize = role.TextSize
        probe.TextWrapped = constraint ~= nil
        probe.Size = UDim2.fromOffset(constraint or 4096, 4096)
        probe.Text = text
        local bounds = probe.TextBounds
        probe.Text = ""
        if bounds.Y > 0 then
            return bounds
        end
    end

    -- Neither path available. Return a height-correct, width-unknown result rather
    -- than a fabricated character-count estimate, and let layout clamp it.
    return Vector2.new(constraint or 0, role.TextSize)
end

-- The exact row height a single line of this role needs. Measured once per role
-- from a string containing both an ascender and a descender, then rounded up to a
-- whole pixel so text centres cleanly instead of landing on X + 0.5.
function Typography.LineHeight(self: Typography, role: Role): number
    local cached = self._LineHeights[role.Name]
    if cached then
        return cached
    end
    local measured = self:Measure("Agjq", role).Y
    local height = math.max(role.TextSize, math.ceil(measured))
    self._LineHeights[role.Name] = height
    return height
end

-- Creates a text instance for a role. Colour is bound through the foundation
-- scheme registry, so a palette change recolours it without rebuilding anything.
-- Height defaults to the role's measured line height; pass Size to override.
--
-- `className` is TextLabel or TextBox: an editable field must sit on exactly the
-- same baseline as a read-only value, so both go through this one path.
function Typography.CreateText(
    self: Typography,
    className: string,
    roleName: string,
    properties: { [string]: any },
    scope: Types.Scope
): TextLabel
    local role = self.Roles[roleName]
    assert(role, "Unknown typography role: " .. tostring(roleName))

    local props: { [string]: any } = table.clone(properties)
    props.Text = props.Text or ""
    props.FontFace = self:FontFor(role)
    props.TextSize = role.TextSize
    props.TextTransparency = props.TextTransparency or role.Transparency
    props.TextXAlignment = props.TextXAlignment or role.XAlignment
    props.TextYAlignment = props.TextYAlignment or role.YAlignment
    props.BackgroundTransparency = props.BackgroundTransparency or 1
    props.BorderSizePixel = 0
    props.RichText = false
    if props.Size == nil then
        props.Size = UDim2.new(1, 0, 0, self:LineHeight(role))
    end

    local placeholderToken: Types.ThemeRole? = props.PlaceholderToken
    props.PlaceholderToken = nil

    local parent = props.Parent
    props.Parent = nil

    local label = self.Library:Create(className, props, scope) :: TextLabel
    self._Labels[label] = role
    local bindings: Types.RegistryProperties = { TextColor3 = role.Token }
    if placeholderToken then
        bindings.PlaceholderColor3 = placeholderToken
    end
    self.Library:RegisterProperty(label, bindings, scope)
    if parent then
        label.Parent = parent
    end
    return label
end

function Typography.Create(
    self: Typography,
    roleName: string,
    properties: { [string]: any },
    scope: Types.Scope
): TextLabel
    return self:CreateText("TextLabel", roleName, properties, scope)
end

-- Rebinds an existing label to a different role. Roles that differ only by token
-- share FontFace and TextSize, so this cannot move geometry. `extra` carries any
-- additional bindings the instance had, such as a TextBox placeholder colour.
function Typography.SetRole(
    self: Typography,
    label: any,
    roleName: string,
    scope: Types.Scope,
    extra: { [string]: string }?
)
    local role = self.Roles[roleName]
    assert(role, "Unknown typography role: " .. tostring(roleName))
    local library = self.Library
    self._Labels[label] = role
    library:_SetProperty(label, "FontFace", self:FontFor(role))
    library:_SetProperty(label, "TextSize", role.TextSize)
    library:_SetProperty(label, "TextTransparency", role.Transparency)

    local bindings: Types.RegistryProperties = { TextColor3 = role.Token }
    if extra then
        for property, token in extra do
            bindings[property] = token
        end
    end

    -- A control destroyed during Unload still resolves its final visual state.
    -- The registry is closed by then, so apply the colours directly.
    if library.Unloaded then
        for property, token in bindings do
            library:_SetProperty(label, property, library.Scheme[token])
        end
        return
    end

    library:UnregisterProperty(label)
    library:RegisterProperty(label, bindings, scope)
end

--// Font family -------------------------------------------------------------
-- The families a theme may choose between, in the order they are offered. The
-- first entry is the library's own; the rest ship with every client, so none of
-- them can fail to load and leave the interface without text.

local SELECTABLE: { { Name: string, Family: string } } = {
    { Name = "BuilderSans", Family = "rbxasset://fonts/families/BuilderSans.json" },
    { Name = "Gotham", Family = "rbxasset://fonts/families/GothamSSm.json" },
    { Name = "SourceSans", Family = "rbxasset://fonts/families/SourceSansPro.json" },
    { Name = "Roboto", Family = "rbxasset://fonts/families/Roboto.json" },
    { Name = "RobotoMono", Family = "rbxasset://fonts/families/RobotoMono.json" },
    { Name = "Arial", Family = "rbxasset://fonts/families/Arial.json" },
    { Name = "Merriweather", Family = "rbxasset://fonts/families/Merriweather.json" },
}

-- Names only, for a dropdown. Returned as a fresh table so a caller sorting or
-- trimming the list cannot reach back into the module's own copy.
function Typography.GetFamilyNames(_self: Typography): { string }
    local names: { string } = {}
    for _, entry in SELECTABLE do
        table.insert(names, entry.Name)
    end
    return names
end

function Typography.FamilyNameFor(_self: Typography, family: string): string?
    for _, entry in SELECTABLE do
        if entry.Family == family then
            return entry.Name
        end
    end
    return nil
end

-- The name a theme stores. Falls back to the first selectable entry when the
-- resolved family is one of the emergency fallbacks, so a theme saved on a
-- client that could not load any family does not persist "enum:Gotham".
function Typography.CurrentFamilyName(self: Typography): string
    return self:FamilyNameFor(self.Family) or SELECTABLE[1].Name
end

-- Switches every piece of text in the interface to another family.
--
-- A font change is not a rebuild. The weights are resolved once, reassigned
-- over the tracked label set, and the per-role line-height cache is dropped so
-- the next measurement reflects the new metrics. Instances that have since been
-- destroyed drop out of the set here rather than accumulating in it.
--
-- Returns false when the name is not one of the selectable families, or when
-- the client cannot build that family at all; in both cases nothing changes.
function Typography.SetFamily(self: Typography, name: string): boolean
    local target: string? = nil
    for _, entry in SELECTABLE do
        if entry.Name == name then
            target = entry.Family
        end
    end
    if not target then
        return false
    end
    if target == self.Family then
        return true
    end

    local built: { [string]: Font } = {}
    local ok = pcall(function()
        for weight, value in WEIGHTS do
            built[weight] = Font.new(target :: string, value, Enum.FontStyle.Normal)
        end
    end)
    if not ok or not built.Regular then
        return false
    end

    self.Fonts = built
    self.Family = target :: string
    table.clear(self._LineHeights)

    for label, role in self._Labels do
        if not pcall(function()
            return (label :: any).Parent
        end) then
            self._Labels[label] = nil
        else
            self.Library:_SetProperty(label, "FontFace", self:FontFor(role))
        end
    end

    local probe = self._Probe
    if probe then
        self.Library:_SetProperty(probe, "FontFace", built.Regular)
    end
    return true
end

return Typography
