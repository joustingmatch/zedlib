-- Generated distribution file.
-- Edit the source modules, not this file.

local Module1 = (function()
--!strict
local ColorUtils = {}

-- WCAG 2.1 relative luminance. https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
local SRGB_LINEAR_THRESHOLD = 0.03928
local SRGB_LINEAR_DIVISOR = 12.92
local SRGB_GAMMA_OFFSET = 0.055
local SRGB_GAMMA_SCALE = 1.055
local SRGB_GAMMA_EXPONENT = 2.4

local LUMINANCE_RED = 0.2126
local LUMINANCE_GREEN = 0.7152
local LUMINANCE_BLUE = 0.0722

-- Added to both luminances so the ratio stays finite and black-on-black is 1.
local CONTRAST_OFFSET = 0.05

local function clamp01(value: number): number
    if value ~= value then -- NaN never compares true, so it is caught here.
        return 0
    end
    return math.clamp(value, 0, 1)
end

ColorUtils.Clamp01 = clamp01

-- Undoes the sRGB transfer function for one channel, taking it from the encoded
-- value a Color3 carries to the linear light the eye integrates. Contrast is a
-- statement about light, so this step is not optional: comparing encoded channel
-- values directly overstates the contrast of dark pairs by a wide margin.
function ColorUtils.LinearizeChannel(channel: number): number
    local value = clamp01(channel)
    if value <= SRGB_LINEAR_THRESHOLD then
        return value / SRGB_LINEAR_DIVISOR
    end
    return ((value + SRGB_GAMMA_OFFSET) / SRGB_GAMMA_SCALE) ^ SRGB_GAMMA_EXPONENT
end

function ColorUtils.RelativeLuminance(color: Color3): number
    return LUMINANCE_RED * ColorUtils.LinearizeChannel(color.R)
        + LUMINANCE_GREEN * ColorUtils.LinearizeChannel(color.G)
        + LUMINANCE_BLUE * ColorUtils.LinearizeChannel(color.B)
end

-- The raw, unrounded ratio. Callers compare this against a threshold; rounding
-- belongs to display only, because a 4.4996 rounded to 4.5 is still a failure.
function ColorUtils.ContrastRatio(foreground: Color3, background: Color3): number
    local a = ColorUtils.RelativeLuminance(foreground)
    local b = ColorUtils.RelativeLuminance(background)
    local lighter, darker = math.max(a, b), math.min(a, b)
    return (lighter + CONTRAST_OFFSET) / (darker + CONTRAST_OFFSET)
end

-- Linear interpolation from `from` at t = 0 to `to` at t = 1. This is the only
-- sanctioned way to derive one colour from another anywhere in the library; a
-- component adding a constant to each channel is what makes a theme system
-- impossible to control.
function ColorUtils.Mix(from: Color3, to: Color3, t: number): Color3
    local alpha = clamp01(t)
    return Color3.new(
        from.R + (to.R - from.R) * alpha,
        from.G + (to.G - from.G) * alpha,
        from.B + (to.B - from.B) * alpha
    )
end

-- Lighten and Darken are Mix against the two fixed poles, named for readability
-- at the call site. They are not separate algorithms, and there is deliberately
-- no HSV variant: pulling saturation around while changing value produces hue
-- shifts that a palette author cannot predict.
function ColorUtils.Lighten(color: Color3, amount: number): Color3
    return ColorUtils.Mix(color, Color3.new(1, 1, 1), amount)
end

function ColorUtils.Darken(color: Color3, amount: number): Color3
    return ColorUtils.Mix(color, Color3.new(0, 0, 0), amount)
end

-- The effective colour of `foreground` drawn at `transparency` over `backdrop`.
-- Transparency is Roblox's convention: 0 is opaque, 1 is invisible. At 1 the
-- result is the backdrop itself, which is the correct answer and also why a
-- fully transparent foreground can never be readable.
function ColorUtils.Composite(foreground: Color3, backdrop: Color3, transparency: number): Color3
    return ColorUtils.Mix(foreground, backdrop, transparency)
end

-- Picks whichever of two candidates reads better on `background`.
--
-- Deterministic by construction: the result depends only on the three colours,
-- never on interaction state, so a control cannot change its foreground while
-- the pointer is over it. Ties go to `dark`, which only occurs when both
-- candidates are equally poor and is therefore arbitrary but stable.
function ColorUtils.ChooseReadableForeground(background: Color3, light: Color3, dark: Color3): Color3
    local lightRatio = ColorUtils.ContrastRatio(light, background)
    local darkRatio = ColorUtils.ContrastRatio(dark, background)
    if lightRatio > darkRatio then
        return light
    end
    return dark
end

return ColorUtils
end)()

local Module2 = (function()
--!strict
local ColorUtils = Module1

local Theme = {}

export type SourceKey =
    "BackgroundColor"
    | "MainColor"
    | "AccentColor"
    | "OutlineColor"
    | "FontColor"
    | "DestructiveColor"
    | "DarkColor"
    | "WhiteColor"

export type Scheme = {
    --// The deepest surface: the window body, recessed regions, the page behind
    -- everything else. Every other neutral in the interface is measured from it.
    BackgroundColor: Color3,
    --// The primary elevated surface: groupboxes, popups, buttons, the fill a
    -- control sits on. One step up from Background, never two.
    MainColor: Color3,
    --// Emphasis, and only emphasis: selection markers, enabled toggles, focus.
    -- Not borders, not headings, not icons. A theme with accent everywhere has
    -- no accent.
    AccentColor: Color3,
    --// Structural separation: strokes, borders, dividers. Also the far end of
    -- the neutral ramp, so the surface and text ladders are both measured
    -- against it rather than against invented per-step constants.
    OutlineColor: Color3,
    --// Primary readable foreground.
    FontColor: Color3,
    --// Destructive and error semantics. Deliberately its own source value:
    -- destructive meaning must never be derived from whatever the accent
    -- happens to be this week, or a blue-accented theme gets blue delete
    -- buttons.
    DestructiveColor: Color3,
    --// Fixed compositing poles, not decorative choices. They are the ends of
    -- the lighten/darken axis and the two candidates for readable foreground on
    -- an arbitrary accent, so they are part of the scheme but are not expected
    -- to be interesting.
    DarkColor: Color3,
    WhiteColor: Color3,
    --// Reserved for the font override a future theme will carry. Validated at
    -- this boundary so a malformed value is rejected where it enters rather
    -- than at the first label that tries to use it. Typography resolves its own
    -- family chain today and does not read this.
    Font: Font,
}

export type Role = string
export type Palette = { [Role]: Color3 }
-- A derivation is a pure function of the source scheme. It may not read the
-- resolved palette, which keeps resolution order irrelevant and cycles
-- impossible to express.
type Derivation = SourceKey | (source: Scheme) -> Color3

--// Ramps ---------------------------------------------------------------------
-- Every derived neutral is a mix along one of three documented ramps. The
-- positions are not a uniform ladder: "each nested surface 5% brighter" makes
-- stacked containers noisy, so these were fitted to the hand-tuned palette the
-- library already shipped and then kept as the definition of the ramp. The fit
-- reproduces every one of those colours to within 3.6/255 on a channel, which
-- is why the theme architecture could be introduced without redrawing the
-- interface. Changing a value here restyles the whole library.
--
--   Depth    Background -> Main -> Outline. Surfaces rise toward the structural
--            neutral, so a theme only has to place two ends of the ramp and the
--            intermediate surfaces follow.
--   Recede   Font -> Outline. Text steps down toward the same structural
--            neutral rather than toward the background, which keeps secondary
--            text on the neutral axis instead of washing it into the surface.
--   Mute     colour -> Dark. Muted accent and destructive variants.
local Ramp = {
    -- Both recessed and raised surfaces climb from Main toward Outline. On a
    -- near-black page a field cut into a card cannot get darker and stay
    -- legible, so "sunken" is expressed by the field being a distinct, slightly
    -- lighter plate inside a quiet card -- the depth cue is the border and the
    -- inset, not a drop in value. Raised sits above it, so a button still reads
    -- as one step proud of the field beside it.
    SurfaceSunken = 0.6100, -- Main toward Outline: recessed fields, tracks, wells
    SurfaceRaised = 0.7800, -- Main toward Outline: buttons and action triggers
    InteractionHover = 0.5745,
    InteractionPressed = 0.9215,
    -- Selection tint: the only place a surface picks up accent hue, and it is a
    -- seventh of the way there. Enough to read as selected next to its
    -- neighbours, not enough to compete with the accent marker itself.
    InteractionSelected = 0.1499,

    BorderDisabled = 0.6140, -- Background toward Outline: weaker than a normal border
    BorderDivider = 0.7258,
    BorderHover = 0.0771, -- Outline toward Font: a border brightening, not glowing
    BorderFocused = 0.2182, -- Accent pulled toward Main so focus reads as a rim

    TextSecondary = 0.3883,
    TextMuted = 0.6330,
    TextPlaceholder = 0.7234,
    -- Disabled text is measured against the sunken surface it most often sits
    -- on, and that surface rose with the rest of the ramp. The step back from
    -- the outline keeps the pair above the identifiable threshold rather than
    -- letting disabled text dissolve into the field behind it.
    TextDisabled = 0.7600,

    TextAccent = 0.4258, -- Accent toward White: accent-coloured text, not accent fill
    AccentMuted = 0.4345,
    DestructiveMuted = 0.4064,
    ScrollBar = 0.0984,
}

Theme.Ramp = Ramp

--// Alpha ---------------------------------------------------------------------
-- Repeated transparency semantics. Transparency is part of how a colour is
-- perceived, so these belong with the palette rather than scattered through
-- controls as bare literals. A number appearing here means the same thing every
-- time it is used; a number that is geometry or motion does not belong here and
-- lives in Metrics.
Theme.Alpha = {
    --// Interaction fills, drawn over the surface they belong to.
    Rest = 1, -- no fill at all
    Hover = 0.25,
    Pressed = 0,
    Selected = 0.1,
    --// A disabled control is dimmed by its tokens, not by an overlay, so that
    -- disabled text stays a known colour the contrast engine can evaluate
    -- instead of an unknowable composite.
    Disabled = 1,

    --// Chrome that must be visible without competing with content.
    ScrollBar = 0.4,
    ScrollBarPopup = 0.35,
    ResizeGrip = 0.45,

    --// Cast shadows.
    ShadowPopup = 0.6,
}

--// Roles ---------------------------------------------------------------------
-- The canonical token list. These strings are the entire vocabulary components
-- may use to name a colour; anything not in this table is a typo and is
-- rejected at bind time rather than silently resolving to white.
--
-- Groups are load-bearing. Surface / Text / Border / Interaction exist so that a
-- button, an input and a dropdown express hover with the same token and
-- therefore feel like one system. Accent and Destructive are separate groups
-- precisely so that emphasis and danger cannot be confused for each other.
local Roles: { [Role]: Derivation } = {
    --// Surfaces, shallowest hierarchy that still reads as depth.
    ["Surface.Canvas"] = "BackgroundColor",
    ["Surface.Primary"] = "MainColor",
    ["Surface.Sunken"] = function(source)
        return ColorUtils.Mix(source.MainColor, source.OutlineColor, Ramp.SurfaceSunken)
    end,
    ["Surface.Raised"] = function(source)
        return ColorUtils.Mix(source.MainColor, source.OutlineColor, Ramp.SurfaceRaised)
    end,
    -- A popup is the same material as a primary surface; it is separated from
    -- what is behind it by its border and its cast shadow, not by a different
    -- colour. It still gets its own role so overlay UI participates in the
    -- theme rather than being themed twice.
    ["Surface.Popup"] = "MainColor",
    -- A disabled control is recessed rather than tinted: it drops back to the
    -- sunken surface and loses its interaction fill entirely.
    ["Surface.Disabled"] = function(source)
        return ColorUtils.Mix(source.BackgroundColor, source.MainColor, 0.5)
    end,

    --// Interaction fills. One shared vocabulary for every control.
    ["Interaction.Hover"] = function(source)
        return ColorUtils.Mix(source.MainColor, source.OutlineColor, Ramp.InteractionHover)
    end,
    ["Interaction.Pressed"] = function(source)
        return ColorUtils.Mix(source.MainColor, source.OutlineColor, Ramp.InteractionPressed)
    end,
    ["Interaction.Selected"] = function(source)
        return ColorUtils.Mix(source.MainColor, source.AccentColor, Ramp.InteractionSelected)
    end,

    --// Accent. Emphasis only.
    ["Accent.Base"] = "AccentColor",
    ["Accent.Muted"] = function(source)
        return ColorUtils.Mix(source.AccentColor, source.DarkColor, Ramp.AccentMuted)
    end,

    --// Destructive. Never derived from the accent.
    ["Destructive.Base"] = "DestructiveColor",
    ["Destructive.Muted"] = function(source)
        return ColorUtils.Mix(source.DestructiveColor, source.DarkColor, Ramp.DestructiveMuted)
    end,

    --// Text. A contrast hierarchy, not a transparency hierarchy: each step is
    -- a real colour, so each step can be measured.
    ["Text.Primary"] = "FontColor",
    ["Text.Secondary"] = function(source)
        return ColorUtils.Mix(source.FontColor, source.OutlineColor, Ramp.TextSecondary)
    end,
    ["Text.Muted"] = function(source)
        return ColorUtils.Mix(source.FontColor, source.OutlineColor, Ramp.TextMuted)
    end,
    ["Text.Placeholder"] = function(source)
        return ColorUtils.Mix(source.FontColor, source.OutlineColor, Ramp.TextPlaceholder)
    end,
    ["Text.Disabled"] = function(source)
        return ColorUtils.Mix(source.FontColor, source.OutlineColor, Ramp.TextDisabled)
    end,
    ["Text.Accent"] = function(source)
        return ColorUtils.Mix(source.AccentColor, source.WhiteColor, Ramp.TextAccent)
    end,
    ["Text.Destructive"] = "DestructiveColor",
    -- The one role whose value is chosen rather than placed. A bright accent
    -- does not automatically take white text and a dark one does not
    -- automatically take black, so the foreground is selected by measuring both
    -- candidates against the accent. See Theme.GetTextOnColor.
    ["Text.OnAccent"] = function(source)
        return ColorUtils.ChooseReadableForeground(source.AccentColor, source.WhiteColor, source.DarkColor)
    end,

    --// Borders. One token per interaction state, shared by every control.
    ["Border.Normal"] = "OutlineColor",
    ["Border.Hover"] = function(source)
        return ColorUtils.Mix(source.OutlineColor, source.FontColor, Ramp.BorderHover)
    end,
    ["Border.Focused"] = function(source)
        return ColorUtils.Mix(source.AccentColor, source.MainColor, Ramp.BorderFocused)
    end,
    ["Border.Disabled"] = function(source)
        return ColorUtils.Mix(source.BackgroundColor, source.OutlineColor, Ramp.BorderDisabled)
    end,
    ["Border.Divider"] = function(source)
        return ColorUtils.Mix(source.BackgroundColor, source.OutlineColor, Ramp.BorderDivider)
    end,
    ["Border.Destructive"] = function(source)
        return ColorUtils.Mix(source.DestructiveColor, source.DarkColor, Ramp.DestructiveMuted)
    end,

    --// Compositing and chrome.
    ["Overlay.ScrollBar"] = function(source)
        return ColorUtils.Mix(source.OutlineColor, source.FontColor, Ramp.ScrollBar)
    end,
    ["Overlay.Shadow"] = "DarkColor",
    ["Overlay.Highlight"] = "WhiteColor",
}

Theme.Roles = Roles

-- Required source keys, in a fixed order so validation messages are stable.
local SOURCE_KEYS: { SourceKey } = {
    "BackgroundColor",
    "MainColor",
    "AccentColor",
    "OutlineColor",
    "FontColor",
    "DestructiveColor",
    "DarkColor",
    "WhiteColor",
}

Theme.SourceKeys = SOURCE_KEYS

local ROLE_NAMES: { Role } = {}
for role in Roles do
    table.insert(ROLE_NAMES, role)
end
table.sort(ROLE_NAMES)

Theme.RoleNames = ROLE_NAMES

function Theme.IsRole(role: unknown): boolean
    return type(role) == "string" and Roles[role] ~= nil
end

-- Nearest-neighbour suggestion for an unknown role, so a typo reports what was
-- probably meant instead of only that it was wrong.
local function suggestRole(role: string): string?
    local lowered = string.lower(role)
    for _, candidate in ROLE_NAMES do
        local other = string.lower(candidate)
        if other == lowered then
            return candidate
        end
        -- Same group and same length is overwhelmingly a transposition.
        if #other == #lowered then
            local differences = 0
            for index = 1, #other do
                if string.sub(other, index, index) ~= string.sub(lowered, index, index) then
                    differences += 1
                end
            end
            if differences <= 2 then
                return candidate
            end
        end
    end
    return nil
end

Theme.SuggestRole = suggestRole

function Theme.DescribeUnknownRole(role: unknown): string
    local text = if type(role) == "string" then string.format("%q", role) else typeof(role)
    local suggestion = if type(role) == "string" then suggestRole(role) else nil
    if suggestion then
        return string.format("Unknown theme role %s; did you mean %q?", text, suggestion)
    end
    return string.format("Unknown theme role %s", text)
end

--// Resolution ----------------------------------------------------------------

-- Resolves one role against a source scheme. Pure: the same source always
-- produces the same palette, so a repaint cannot drift.
function Theme.ResolveRole(source: Scheme, role: Role): Color3
    local derivation = Roles[role]
    assert(derivation ~= nil, Theme.DescribeUnknownRole(role))
    if type(derivation) == "string" then
        local value = (source :: any)[derivation]
        assert(typeof(value) == "Color3", string.format("Source scheme is missing %q", derivation))
        return value
    end
    return derivation(source)
end

function Theme.Resolve(source: Scheme): Palette
    local palette: Palette = {}
    for _, role in ROLE_NAMES do
        palette[role] = Theme.ResolveRole(source, role)
    end
    return palette
end

-- The documented rule for foreground selection on an arbitrary fill, exposed so
-- callers with a runtime colour (a user-chosen accent, a swatch) get the same
-- answer the palette got. Deterministic in its arguments and nothing else.
function Theme.GetTextOnColor(source: Scheme, background: Color3): Color3
    return ColorUtils.ChooseReadableForeground(background, source.WhiteColor, source.DarkColor)
end

--// Contrast ------------------------------------------------------------------

-- WCAG 2.1 targets. Disabled is not a WCAG figure: 1.4.3 exempts inactive
-- components from contrast requirements entirely, so the alternative to an
-- explicit floor is no check at all. This one asserts only that disabled text
-- stays visible, which is the property that actually matters -- a disabled
-- control must read as present and inactive, never as absent.
Theme.Contrast = {
    NormalText = 4.5,
    LargeText = 3.0,
    UIComponent = 3.0,
    Identifiable = 2.0,
}

export type ContrastPair = {
    Name: string,
    Foreground: Role,
    Background: Role,
    Threshold: number,
    -- Foreground transparency, when the pair is genuinely drawn translucent.
    -- The engine composites before measuring, because a foreground at 40%
    -- transparency does not have its own raw contrast.
    Alpha: number?,
}

-- Real adjacencies only.
--
-- Two omissions are deliberate. A normal border against its surface is not
-- listed, and neither is the selection tint: in this library a control is
-- identified by its surface (a sunken well versus a raised button) and a
-- selection by its accent marker, both of which *are* listed. Adding the
-- decorative hairlines would mean every theme permanently carries two warnings
-- about relationships nothing depends on, and a report that always fails is a
-- report nobody reads.
Theme.ContrastPairs = {
    {
        Name = "Primary text on the window canvas",
        Foreground = "Text.Primary",
        Background = "Surface.Canvas",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Primary text on primary surfaces",
        Foreground = "Text.Primary",
        Background = "Surface.Primary",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Primary text on raised surfaces",
        Foreground = "Text.Primary",
        Background = "Surface.Raised",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Control values on sunken surfaces",
        Foreground = "Text.Primary",
        Background = "Surface.Sunken",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Primary text on popup surfaces",
        Foreground = "Text.Primary",
        Background = "Surface.Popup",
        Threshold = Theme.Contrast.NormalText,
    },

    {
        Name = "Secondary text on primary surfaces",
        Foreground = "Text.Secondary",
        Background = "Surface.Primary",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Secondary text on sunken surfaces",
        Foreground = "Text.Secondary",
        Background = "Surface.Sunken",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Muted text on primary surfaces",
        Foreground = "Text.Muted",
        Background = "Surface.Primary",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Placeholder text in inputs",
        Foreground = "Text.Placeholder",
        Background = "Surface.Sunken",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Disabled text remains visible",
        Foreground = "Text.Disabled",
        Background = "Surface.Sunken",
        Threshold = Theme.Contrast.Identifiable,
    },

    {
        Name = "Accent text on primary surfaces",
        Foreground = "Text.Accent",
        Background = "Surface.Primary",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Destructive text on raised surfaces",
        Foreground = "Text.Destructive",
        Background = "Surface.Raised",
        Threshold = Theme.Contrast.NormalText,
    },
    {
        Name = "Text on accent fills",
        Foreground = "Text.OnAccent",
        Background = "Accent.Base",
        Threshold = Theme.Contrast.NormalText,
    },

    {
        Name = "Accent markers against primary surfaces",
        Foreground = "Accent.Base",
        Background = "Surface.Primary",
        Threshold = Theme.Contrast.UIComponent,
    },
    {
        Name = "Focused border against a control",
        Foreground = "Border.Focused",
        Background = "Surface.Sunken",
        Threshold = Theme.Contrast.UIComponent,
    },
    {
        Name = "Scroll bar against its content",
        Foreground = "Overlay.ScrollBar",
        Background = "Surface.Primary",
        Threshold = Theme.Contrast.UIComponent,
        Alpha = Theme.Alpha.ScrollBar,
    },
} :: { ContrastPair }

export type ContrastResult = {
    Name: string,
    Foreground: Role,
    Background: Role,
    Ratio: number,
    Required: number,
    Passes: boolean,
}

export type ContrastReport = {
    Passes: boolean,
    WorstRatio: number,
    WorstPair: string?,
    -- The weakest pair *relative to its own requirement*. Ranking by raw ratio
    -- alone would always surface the 3:1 pairs simply because they are allowed
    -- to be darker; this names the relationship that is furthest from being
    -- acceptable, which is the one worth fixing first.
    WorstMargin: number,
    WorstMarginPair: string?,
    Failures: { ContrastResult },
    Results: { ContrastResult },
}

function Theme.GetRelativeLuminance(color: Color3): number
    return ColorUtils.RelativeLuminance(color)
end

function Theme.GetContrastRatio(foreground: Color3, background: Color3): number
    return ColorUtils.ContrastRatio(foreground, background)
end

function Theme.Composite(foreground: Color3, backdrop: Color3, transparency: number): Color3
    return ColorUtils.Composite(foreground, backdrop, transparency)
end

-- Objective and free of side effects. It measures the palette it is given and
-- says what it found; it never adjusts a source value to make its own report
-- look better. Deciding what to do about a failure -- warn, block a save, offer
-- a suggestion, allow it anyway -- is policy, and policy belongs to whatever is
-- built on top of this, not here.
function Theme.AnalyzeContrast(palette: Palette, pairs: { ContrastPair }?): ContrastReport
    local definitions = pairs or Theme.ContrastPairs
    local results: { ContrastResult } = {}
    local failures: { ContrastResult } = {}
    local worstRatio, worstPair = math.huge, nil :: string?
    local worstMargin, worstMarginPair = math.huge, nil :: string?

    for _, pair in definitions do
        local foreground = palette[pair.Foreground]
        local background = palette[pair.Background]
        assert(foreground, Theme.DescribeUnknownRole(pair.Foreground))
        assert(background, Theme.DescribeUnknownRole(pair.Background))

        -- A translucent foreground is measured as it is actually drawn.
        if pair.Alpha and pair.Alpha > 0 then
            foreground = ColorUtils.Composite(foreground, background, pair.Alpha)
        end

        local ratio = ColorUtils.ContrastRatio(foreground, background)
        local result: ContrastResult = {
            Name = pair.Name,
            Foreground = pair.Foreground,
            Background = pair.Background,
            Ratio = ratio,
            Required = pair.Threshold,
            -- Compared unrounded. Rounding first would let 4.4996 pass as 4.5.
            Passes = ratio >= pair.Threshold,
        }
        table.insert(results, result)
        if not result.Passes then
            table.insert(failures, result)
        end
        if ratio < worstRatio then
            worstRatio, worstPair = ratio, pair.Name
        end
        local margin = ratio / pair.Threshold
        if margin < worstMargin then
            worstMargin, worstMarginPair = margin, pair.Name
        end
    end

    return {
        Passes = #failures == 0,
        WorstRatio = worstRatio,
        WorstPair = worstPair,
        WorstMargin = worstMargin,
        WorstMarginPair = worstMarginPair,
        Failures = failures,
        Results = results,
    }
end

--// Validation ----------------------------------------------------------------
-- Structural validation is a different question from contrast validation.
-- "Does FontColor exist and is it a Color3" and "can FontColor be read against
-- MainColor" fail for unrelated reasons and are reported separately: a scheme
-- can be structurally perfect and unreadable, or structurally broken in a way
-- that makes contrast analysis meaningless.

export type ValidationReport = {
    Valid: boolean,
    Errors: { string },
    Warnings: { string },
    Contrast: ContrastReport?,
}

function Theme.ValidateScheme(source: unknown, strict: boolean?): ValidationReport
    local errors: { string } = {}
    local warnings: { string } = {}

    if type(source) ~= "table" then
        return {
            Valid = false,
            Errors = { "Scheme must be a table, got " .. typeof(source) },
            Warnings = warnings,
            Contrast = nil,
        }
    end

    local candidate = source :: { [string]: unknown }
    for _, key in SOURCE_KEYS do
        local value = candidate[key]
        if value == nil then
            table.insert(errors, string.format("Missing required scheme key %q", key))
        elseif typeof(value) ~= "Color3" then
            table.insert(errors, string.format("Scheme key %q must be a Color3, got %s", key, typeof(value)))
        end
    end

    local font = candidate.Font
    if font ~= nil and typeof(font) ~= "Font" then
        table.insert(errors, string.format('Scheme key "Font" must be a Font, got %s', typeof(font)))
    elseif font == nil then
        table.insert(warnings, "Scheme has no Font; the default family chain will be used")
    end

    local known: { [string]: boolean } = { Font = true }
    for _, key in SOURCE_KEYS do
        known[key] = true
    end
    for key in candidate do
        if not known[key] then
            local message = string.format("Unknown scheme key %q", key)
            if strict then
                table.insert(errors, message)
            else
                table.insert(warnings, message)
            end
        end
    end

    -- Contrast is only meaningful once the structure holds; resolving an
    -- incomplete scheme would error inside the analyser and report the wrong
    -- problem.
    local contrast: ContrastReport? = nil
    if #errors == 0 then
        contrast = Theme.AnalyzeContrast(Theme.Resolve(source :: any))
    end

    return { Valid = #errors == 0, Errors = errors, Warnings = warnings, Contrast = contrast }
end

return Theme
end)()

local Module3 = (function()
--!strict
local Theme = Module2

export type Cleanup = () -> ()
export type Scope = {
    Destroyed: boolean,
    Add: (self: Scope, cleanup: Cleanup) -> Cleanup,
    Child: (self: Scope) -> Scope,
    Destroy: (self: Scope) -> (),
}
export type Disposable = { Destroy: (self: Disposable) -> () }
export type BaseElement = {
    Destroyed: boolean,
    Resources: Scope,
    Destroy: (self: BaseElement) -> (),
}
export type RegistryKind = "Toggles" | "Options" | "Labels" | "Buttons"

--// Theme -------------------------------------------------------------------
-- The source scheme is what a theme authors: nine values. Everything else in
-- the interface is derived from it by core/Theme, so these are re-exported here
-- rather than redefined, and there is exactly one definition of each.
export type Scheme = Theme.Scheme
export type SourceKey = Theme.SourceKey
-- A role is one of core/Theme's canonical token names. Luau cannot express the
-- union and keep the token list in one place at the same time, so the list in
-- Theme.Roles is authoritative and every bind site is checked against it at
-- runtime; an unknown role raises rather than resolving to a default.
export type ThemeRole = Theme.Role
export type Palette = Theme.Palette
export type ContrastPair = Theme.ContrastPair
export type ContrastResult = Theme.ContrastResult
export type ContrastReport = Theme.ContrastReport
export type ValidationReport = Theme.ValidationReport

-- A bound property either names a role, or computes one from live component
-- state. A resolver may return a role name or a finished Color3; returning a
-- role is preferred, because a value chosen outside the palette is invisible to
-- the contrast engine.
export type ThemeBinding = ThemeRole | () -> ThemeRole | Color3
export type RegistryProperties = { [string]: ThemeBinding }
export type RegistryEntry = { Properties: RegistryProperties, Resources: Scope }

export type OwnershipSlot = { Release: Cleanup }
export type RuntimeAdapter = {
    ResolveGuiParent: (() -> Instance?)?,
    GetPlatform: (() -> string)?,
    -- Persist this table across executions when the host does not preserve `shared`.
    Ownership: { [string]: OwnershipSlot }?,
    -- Filesystem, clipboard and JSON overrides. Any function left out is looked
    -- up in the host environment instead; supplying the table in full is how a
    -- test drives the managers without touching a real disk.
    Storage: {
        isfolder: ((string) -> boolean)?,
        isfile: ((string) -> boolean)?,
        listfiles: ((string) -> { string })?,
        makefolder: ((string) -> ())?,
        readfile: ((string) -> string)?,
        writefile: ((string, string) -> ())?,
        delfile: ((string) -> ())?,
        setclipboard: ((string) -> ())?,
        JSON: any?,
    }?,
}
export type Config = {
    OwnershipKey: string?,
    Scale: number?,
    ErrorReporting: boolean?,
    OnError: ((message: string) -> ())?,
    Runtime: RuntimeAdapter?,
}
return {}
end)()

local Module4 = (function()
--!strict
local Types = Module3
type Scope = Types.Scope
type Cleanup = Types.Cleanup

local ResourceTracker = {}

function ResourceTracker.new(report: (string) -> ()): Scope
    local callbacks: { [Cleanup]: number } = {}
    local sequence = 0
    local scope: Scope
    scope = {
        Destroyed = false,
        Add = function(self: Scope, cleanup: Cleanup): Cleanup
            assert(type(cleanup) == "function", "Cleanup must be a function")
            local function dispose()
                if callbacks[cleanup] == nil then
                    return
                end
                callbacks[cleanup] = nil
                local ok, message = xpcall(function()
                    cleanup()
                    return true
                end, debug.traceback)
                if not ok then
                    report(tostring(message))
                end
            end
            if self.Destroyed then
                local ok, message = xpcall(function()
                    cleanup()
                    return true
                end, debug.traceback)
                if not ok then
                    report(tostring(message))
                end
            else
                assert(callbacks[cleanup] == nil, "Cleanup already tracked by this scope")
                sequence += 1
                callbacks[cleanup] = sequence
            end
            return dispose
        end,
        Child = function(self: Scope): Scope
            assert(not self.Destroyed, "Cannot create a child of a destroyed scope")
            local child = ResourceTracker.new(report)
            local dispose = self:Add(function()
                child:Destroy()
            end)
            -- Removing the parent entry on early disposal avoids retaining dead children.
            child:Add(dispose)
            return child
        end,
        Destroy = function(self: Scope)
            if self.Destroyed then
                return
            end
            self.Destroyed = true
            local ordered = {}
            for callback, order in callbacks do
                table.insert(ordered, { Callback = callback, Order = order })
            end
            table.sort(ordered, function(a, b)
                return a.Order > b.Order
            end)
            for _, entry in ordered do
                if callbacks[entry.Callback] then
                    callbacks[entry.Callback] = nil
                    local ok, message = xpcall(function()
                        entry.Callback()
                        return true
                    end, debug.traceback)
                    if not ok then
                        report(tostring(message))
                    end
                end
            end
            table.clear(callbacks)
        end,
    }
    return scope
end

return ResourceTracker
end)()

local Module5 = (function()
--!strict
local Persistence = {}

--// Host lookup ---------------------------------------------------------------
-- The one dynamic environment read in the library. An injected adapter always
-- wins, so a test or an embedding host never has to satisfy a global.

local FUNCTIONS = {
    "isfolder",
    "isfile",
    "listfiles",
    "makefolder",
    "readfile",
    "writefile",
    "delfile",
}

local function hostEnvironment(): { [string]: any }
    if getfenv then
        local ok, environment = pcall(getfenv, 0)
        if ok and type(environment) == "table" then
            return environment
        end
    end
    return (_G :: any) or {}
end

local function resolveFunctions(adapter: { [string]: any }?): { [string]: any }
    local supplied = adapter or {}
    local environment = hostEnvironment()
    local resolved: { [string]: any } = {}
    for _, name in FUNCTIONS do
        local candidate = supplied[name]
        if type(candidate) ~= "function" then
            candidate = rawget(environment, name)
        end
        if type(candidate) == "function" then
            resolved[name] = candidate
        end
    end
    return resolved
end

--// Paths ---------------------------------------------------------------------
-- A name is a single path segment supplied by a user through a text field. It
-- must not be able to escape the manager's folder, so separators, traversal and
-- the characters Windows rejects are refused rather than sanitised: a theme
-- silently saved under a different name than the one typed is worse than an
-- error saying why.

local RESERVED = { "con", "prn", "aux", "nul" }
local ILLEGAL = '[%c/\\:%*%?"<>|]'

-- Returns the trimmed name, or nil plus a message explaining the rejection.
function Persistence.ValidateName(name: unknown, subject: string?): (string?, string?)
    local label = subject or "Name"
    if type(name) ~= "string" then
        return nil, string.format("%s must be a string, got %s", label, typeof(name))
    end
    local trimmed = string.match(name, "^%s*(.-)%s*$") :: string
    if trimmed == "" then
        return nil, string.format("%s cannot be empty", label)
    end
    if #trimmed > 64 then
        return nil, string.format("%s cannot be longer than 64 characters", label)
    end
    if string.find(trimmed, ILLEGAL) then
        return nil, string.format('%s cannot contain / \\ : * ? " < > | or control characters', label)
    end
    if string.find(trimmed, "%.%.") then
        return nil, string.format('%s cannot contain ".."', label)
    end
    if string.sub(trimmed, -1) == "." then
        return nil, string.format("%s cannot end with a period", label)
    end
    local lowered = string.lower(trimmed)
    for _, reserved in RESERVED do
        if lowered == reserved then
            return nil, string.format("%q is reserved by the operating system", trimmed)
        end
    end
    return trimmed, nil
end

-- A folder may be several segments deep ("MyHub/Games"), so each segment is
-- validated on its own and the separators are normalised to forward slashes.
function Persistence.ValidateFolder(path: unknown, subject: string?): (string?, string?)
    local label = subject or "Folder"
    if type(path) ~= "string" then
        return nil, string.format("%s must be a string, got %s", label, typeof(path))
    end
    local normalised = string.gsub(path, "\\", "/")
    normalised = string.gsub(normalised, "//+", "/")
    normalised = string.match(normalised, "^/*(.-)/*$") :: string
    if normalised == "" then
        return nil, string.format("%s cannot be empty", label)
    end
    local segments: { string } = {}
    for segment in string.gmatch(normalised, "[^/]+") do
        local valid, message = Persistence.ValidateName(segment, label .. " segment")
        if not valid then
            return nil, message
        end
        table.insert(segments, valid)
    end
    return table.concat(segments, "/"), nil
end

function Persistence.Join(...: string): string
    local parts: { string } = {}
    for index = 1, select("#", ...) do
        local part = select(index, ...)
        if type(part) == "string" and part ~= "" then
            table.insert(parts, (string.gsub(part, "^/+", "")))
        end
    end
    return table.concat(parts, "/")
end

-- Hosts disagree about whether listfiles returns names or full paths. Managers
-- want the base name without its extension, which is what the user typed.
function Persistence.BaseName(path: string, extension: string?): string
    local name = string.match(path, "[^/\\]+$") or path
    if extension and #name > #extension and string.sub(string.lower(name), -#extension) == string.lower(extension) then
        name = string.sub(name, 1, #name - #extension)
    end
    return name
end

--// Storage -------------------------------------------------------------------

export type Storage = {
    Available: boolean,
    HasClipboard: boolean,
    Missing: { string },
    IsFolder: (self: Storage, path: string) -> boolean,
    IsFile: (self: Storage, path: string) -> boolean,
    ListFiles: (self: Storage, path: string) -> (boolean, any),
    MakeFolder: (self: Storage, path: string) -> (boolean, string?),
    EnsureFolder: (self: Storage, path: string) -> (boolean, string?),
    ReadFile: (self: Storage, path: string) -> (boolean, string),
    WriteFile: (self: Storage, path: string, contents: string) -> (boolean, string?),
    DeleteFile: (self: Storage, path: string) -> (boolean, string?),
    Encode: (self: Storage, value: any) -> (boolean, string),
    Decode: (self: Storage, text: string) -> (boolean, any),
    SetClipboard: (self: Storage, text: string) -> boolean,
}

local UNAVAILABLE = "This host does not expose the filesystem functions the manager needs"

function Persistence.new(adapter: { [string]: any }?): Storage
    local functions = resolveFunctions(adapter)
    local missing: { string } = {}
    for _, name in FUNCTIONS do
        if functions[name] == nil then
            table.insert(missing, name)
        end
    end

    local environment = hostEnvironment()
    local clipboard = (adapter and adapter.setclipboard)
        or rawget(environment, "setclipboard")
        or rawget(environment, "toclipboard")

    local jsonService: any = nil
    if adapter and adapter.JSON then
        jsonService = adapter.JSON
    else
        pcall(function()
            jsonService = game:GetService("HttpService")
        end)
    end

    local self = {} :: any
    self.Available = #missing == 0
    self.HasClipboard = type(clipboard) == "function"
    self.Missing = missing

    -- Predicates answer false when the host cannot say. A manager treats "I do
    -- not know" and "it is not there" the same way, and both are recoverable.
    local function predicate(name: string, path: string): boolean
        local fn = functions[name]
        if not fn then
            return false
        end
        local ok, result = pcall(fn, path)
        return ok and result == true
    end

    function self:IsFolder(path: string): boolean
        return predicate("isfolder", path)
    end

    function self:IsFile(path: string): boolean
        return predicate("isfile", path)
    end

    -- A missing folder lists as empty rather than as a failure: "no themes yet"
    -- is the normal first-run state, not something to report to the user.
    function self:ListFiles(path: string): (boolean, any)
        local fn = functions.listfiles
        if not fn then
            return false, UNAVAILABLE
        end
        if not self:IsFolder(path) then
            return true, {}
        end
        local ok, result = pcall(fn, path)
        if not ok then
            return false, "Could not list " .. path .. ": " .. tostring(result)
        end
        if type(result) ~= "table" then
            return false, "listfiles returned " .. typeof(result)
        end
        local entries: { string } = {}
        for _, entry in result :: { any } do
            if type(entry) == "string" then
                table.insert(entries, entry)
            end
        end
        return true, entries
    end

    function self:MakeFolder(path: string): (boolean, string?)
        local fn = functions.makefolder
        if not fn then
            return false, UNAVAILABLE
        end
        if self:IsFolder(path) then
            return true, nil
        end
        local ok, message = pcall(fn, path)
        if not ok then
            return false, "Could not create " .. path .. ": " .. tostring(message)
        end
        return true, nil
    end

    -- Builds every missing segment from the outside in. A host that refuses one
    -- level stops the walk with a message naming the level it refused.
    function self:EnsureFolder(path: string): (boolean, string?)
        local accumulated = ""
        for segment in string.gmatch(path, "[^/]+") do
            accumulated = if accumulated == "" then segment else accumulated .. "/" .. segment
            local ok, message = self:MakeFolder(accumulated)
            if not ok then
                return false, message
            end
        end
        return true, nil
    end

    function self:ReadFile(path: string): (boolean, string)
        local fn = functions.readfile
        if not fn then
            return false, UNAVAILABLE
        end
        if not self:IsFile(path) then
            return false, path .. " does not exist"
        end
        local ok, contents = pcall(fn, path)
        if not ok then
            return false, "Could not read " .. path .. ": " .. tostring(contents)
        end
        if type(contents) ~= "string" then
            return false, "readfile returned " .. typeof(contents)
        end
        return true, contents
    end

    function self:WriteFile(path: string, contents: string): (boolean, string?)
        local fn = functions.writefile
        if not fn then
            return false, UNAVAILABLE
        end
        if type(contents) ~= "string" then
            return false, "File contents must be a string"
        end
        local ok, message = pcall(fn, path, contents)
        if not ok then
            return false, "Could not write " .. path .. ": " .. tostring(message)
        end
        return true, nil
    end

    function self:DeleteFile(path: string): (boolean, string?)
        local fn = functions.delfile
        if not fn then
            return false, UNAVAILABLE
        end
        if not self:IsFile(path) then
            return false, path .. " does not exist"
        end
        local ok, message = pcall(fn, path)
        if not ok then
            return false, "Could not delete " .. path .. ": " .. tostring(message)
        end
        return true, nil
    end

    function self:Encode(value: any): (boolean, string)
        if not jsonService then
            return false, "No JSON encoder available"
        end
        local ok, result = pcall(function()
            return jsonService:JSONEncode(value)
        end)
        if not ok or type(result) ~= "string" then
            return false, "Could not encode JSON: " .. tostring(result)
        end
        return true, result
    end

    function self:Decode(text: string): (boolean, any)
        if not jsonService then
            return false, "No JSON decoder available"
        end
        if type(text) ~= "string" or string.match(text, "^%s*$") then
            return false, "Nothing to decode"
        end
        local ok, result = pcall(function()
            return jsonService:JSONDecode(text)
        end)
        if not ok then
            return false, "Invalid JSON"
        end
        return true, result
    end

    -- Optional. Export must succeed on a host with no clipboard, so this reports
    -- whether the copy happened rather than failing the operation.
    function self:SetClipboard(text: string): boolean
        if type(clipboard) ~= "function" or type(text) ~= "string" then
            return false
        end
        return (pcall(clipboard, text))
    end

    return self :: Storage
end

return Persistence
end)()

local Module6 = (function()
--!strict
local Types = Module3
local Persistence = Module5
local Runtime = {}

-- Optional capabilities a host may or may not provide. Each probe must be pure,
-- non-yielding, and must not leave anything behind.
local PROBES: { [string]: () -> boolean } = {
    -- Real text measurement rather than estimation.
    TextBounds = function()
        local params = Instance.new("GetTextBoundsParams")
        params.Text = "A"
        params.Size = 12
        params:Destroy()
        return true
    end,
    -- Real inner/outer shadows, which is what gives a surface thickness.
    UIShadow = function()
        local instance = Instance.new("UIShadow")
        instance.Inset = true
        instance.BlurRadius = UDim.new(0, 8)
        instance:Destroy()
        return true
    end,
    -- Weighted font families, required for a text hierarchy without size changes.
    FontFamily = function()
        local font = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium)
        return font.Weight == Enum.FontWeight.Medium
    end,
}

function Runtime.new(adapter: Types.RuntimeAdapter?)
    local options: Types.RuntimeAdapter = adapter or {}
    --// Services: acquired once per library, no hidden waits or privileged APIs.
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local RunService = game:GetService("RunService")
    assert(RunService:IsClient(), "Zedlib requires a client runtime")

    -- shared is the only dynamic environment boundary. No executor globals are probed.
    local environment: any = shared
    if options.Ownership == nil then
        assert(type(environment) == "table", "Inject Runtime.Ownership in this host")
        if environment.__ZedlibFoundationV1 == nil then
            environment.__ZedlibFoundationV1 = {}
        end
        assert(type(environment.__ZedlibFoundationV1) == "table", "Invalid Zedlib ownership store")
    end
    local ownership: { [string]: Types.OwnershipSlot } = options.Ownership or environment.__ZedlibFoundationV1
    local capabilities: { [string]: boolean } = {}
    -- The host storage boundary, resolved once. Managers reach the filesystem,
    -- JSON and the clipboard only through here, so no code above the runtime
    -- ever reads a host global or decides what to do when one is missing.
    local storage = Persistence.new(options.Storage)
    local runtime = { Input = UserInputService, Render = RunService, Ownership = ownership, Storage = storage }

    function runtime:ResolveGuiParent(): Instance?
        if options.ResolveGuiParent then
            local ok, parent = pcall(options.ResolveGuiParent)
            if ok and typeof(parent) == "Instance" then
                return parent
            end
            -- A failing optional host adapter falls back to PlayerGui.
        end
        local player = Players.LocalPlayer
        return if player then player:FindFirstChildOfClass("PlayerGui") else nil
    end

    function runtime:GetPlatform(): (string, boolean)
        if options.GetPlatform then
            local ok, platform = pcall(options.GetPlatform)
            if ok and type(platform) == "string" then
                return platform, platform == "Android" or platform == "IOS"
            end
        end
        -- GetPlatform may be restricted in some hosts; keep the probe here.
        local ok, platform = pcall(function()
            return UserInputService:GetPlatform().Name
        end)
        if ok and platform ~= "None" then
            return platform, platform == "Android" or platform == "IOS"
        end
        if
            UserInputService.TouchEnabled
            and not UserInputService.KeyboardEnabled
            and not UserInputService.MouseEnabled
        then
            return "Touch", true
        end
        return "Unknown", false
    end

    function runtime:HasCapability(name: string): boolean
        if name == "Touch" then
            return UserInputService.TouchEnabled
        end
        if name == "Keyboard" then
            return UserInputService.KeyboardEnabled
        end
        if name == "Mouse" then
            return UserInputService.MouseEnabled
        end
        if name == "CustomGuiParent" then
            return options.ResolveGuiParent ~= nil
        end
        -- Storage capabilities are resolved by Persistence, not probed here:
        -- asking twice in two places is how the two answers drift apart.
        if name == "FileSystem" then
            return storage.Available
        end
        if name == "Clipboard" then
            return storage.HasClipboard
        end
        -- Optional rendering/text capabilities. Probed once, cached, and never
        -- re-probed, so visual code asks here instead of scattering pcalls.
        local cached = capabilities[name]
        if cached ~= nil then
            return cached
        end
        local probe = PROBES[name]
        if not probe then
            return false
        end
        local ok, supported = pcall(probe)
        local result = ok and supported == true
        capabilities[name] = result
        return result
    end

    return runtime
end

export type Runtime = typeof(Runtime.new(nil))
return Runtime
end)()

local Module7 = (function()
--!strict
local Types = Module3
local ResourceTracker = Module4
local Runtime = Module6
local Theme = Module2
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
end)()

local Module8 = (function()
--!strict
local Metrics = {}
Metrics.Core = {
    Indicator = 16,
    SwitchWidth = 28,
    KeyWidth = 72,
    ColorWidth = 32,
    ValueWidth = 84,
    TrackHeight = 14,
    Cursor = 6,
    PopupWidth = 240,
    SVHeight = 130,
    ColorHeight = 214,
    ToastWidth = 300,
    DialogWidth = 400,
    TooltipDelay = 0.5,
}

--// Radius scale. Five steps, used everywhere; no component invents its own.
-- Card sits one step inside Window, and Control one step inside Card, so the
-- curvature reads as a single family nesting rather than three opinions.
Metrics.Radius = {
    Window = 14,
    Card = 10,
    Dock = 12,
    DockItem = 9,
    Control = 8,
    Popup = 10,
    Small = 6,
    -- Anything that must read as a capsule: toggle tracks, pills, thumbs.
    Pill = 999,
}

--// Lines
Metrics.Stroke = {
    Thickness = 1,
    Divider = 1,
}

--// Window shell
Metrics.Window = {
    Width = 840,
    Height = 530,
    MinWidth = 640,
    MinHeight = 360,
    MaxWidth = 1600,
    MaxHeight = 1000,
    -- Air between the window edge and the dock, mirrored on every side. The
    -- dock is a panel inside the shell, not a wall bolted to its edge.
    OuterPadding = 7,
    -- Kept on screen while dragging, so the window is always recoverable.
    ClampMargin = 72,
    ResizeHandle = 14,
    -- The corner grip: two short diagonal strokes. Stated here rather than
    -- improvised at the call site, because a stroke inset the shell does not
    -- own is a stroke that drifts out of the corner's radius when either
    -- changes.
    GripInset = 3,
    GripPitch = 3,
    GripThickness = 1,
    -- How much shorter the outer stroke is than the handle, and how much
    -- shorter each successive stroke is than the one before it.
    GripTrim = 5,
    GripStep = 4,
    ShadowBlur = 30,
    ShadowSpread = -8,
    ShadowOffsetY = 12,
    ShadowTransparency = 0.62,
}

--// Left navigation dock. A vertical strip: mascot at the top, then an evenly
-- spaced stack of line glyphs. The active glyph gains a filled rounded square
-- and a narrow pill against the dock's left edge.
Metrics.Dock = {
    Width = 52,

    -- The mascot's centre lands 26 below the dock's top edge, which puts it 52
    -- below the window's, exactly as the reference does.
    PaddingTop = 11,
    PaddingBottom = 11,

    MascotSize = 30,
    -- Distance from the mascot's centre to the first icon's centre.
    MascotGap = 52,

    -- One item's hit area and the distance between two item centres. The
    -- container is smaller than the pitch, which is what produces the even air
    -- between active chips.
    ItemSize = 30,
    ItemPitch = 40,
    IconSize = 18,

    -- The active marker, hard against the dock's left inner edge.
    IndicatorWidth = 3,
    IndicatorHeight = 16,
    IndicatorInset = 0,
}

--// Content region. The body that sits to the right of the dock.
Metrics.Content = {
    PaddingLeft = 15,
    PaddingRight = 16,
    PaddingTop = 18,
    PaddingBottom = 14,
    HeaderToBody = 12,
    ScrollBarThickness = 3,
    -- Air between the scroll bar and the content it scrolls. The bar draws over
    -- the page rather than in its own inset gutter, so the columns give up this
    -- much width instead of letting a card border pass underneath it.
    ScrollGutter = 3,
    -- Air below the last card, inside the canvas. Without it the final card's
    -- bottom edge is the canvas edge and the page ends hard against the frame.
    CanvasBottomPadding = 14,
    -- A card's border is a UIStroke, and a stroke is drawn OUTSIDE the frame it
    -- belongs to. A card flush with the scroll frame's edge therefore has that
    -- edge of its border clipped away, which is exactly the "card bleeds into
    -- the frame" artifact. The scroll region gives the stroke its own lane on
    -- all four sides so no card can ever lose an edge, and the column width
    -- below accounts for it rather than the columns silently overhanging.
    StrokeGutter = 1,
}

--// Sub-tab strip. The row of text labels across the top of the content, which
-- is SECONDARY navigation: it switches pages inside whichever section the dock
-- has selected, and every entry in it belongs to that one section.
--
-- Two things say so visually. The strip is left-aligned to the content body it
-- governs rather than centred like a title, and it closes with a full-width
-- hairline rule that the active accent underline sits on top of -- so the strip
-- reads as the top edge of the page beneath it, not as a bar over the window.
Metrics.HeaderTabs = {
    Height = 26,
    -- Gap between two labels, measured edge to edge.
    Gap = 22,
    -- Left offset from the content body's origin. 0 aligns the first label to
    -- the left column's left edge.
    Inset = 0,
    UnderlineThickness = 2,
    -- The hairline closing the strip. The active underline is drawn on it, so
    -- the two share a baseline exactly.
    RuleThickness = 1,
    -- 0 left-aligns the strip to the content body, 0.5 centres it, 1 right-
    -- aligns it. Sub-navigation is left-aligned to the page it governs.
    Alignment = 0,
}

--// Tabboxes: the in-card tab strip a Container draws across the top of its own
-- surface. Distinct from HeaderTabs above, which is the page-level strip.
Metrics.Tabs = {
    Height = 26,
    Spacing = 2,
    HorizontalPadding = 10,
    IndicatorWidth = 2,
    IndicatorInset = 6,
}

--// Shared control rhythm. Every row-shaped control derives from this, so a
-- dropdown trigger and a text input are the same height on the same baseline.
Metrics.Control = {
    Height = 28,
    LabelGap = 6,
    HorizontalPadding = 10,
}

--// Spacing scale. Every gap in the content area is one of these five steps,
-- assigned a semantic use below; no component picks a loose number.
Metrics.Spacing = {
    XS = 3,
    S = 6,
    M = 10,
    L = 14,
    XL = 18,
}

--// Module cards (the canonical control container inside a page).
--
-- The card carries no header. Its name is set outside it, above its top edge,
-- as a small spaced uppercase section label -- which is what lets the card
-- itself stay a plain, quiet rounded surface with nothing but rows in it.
Metrics.Groupbox = {
    -- The air between the external section label's baseline box and the card's
    -- top edge. The label's own height is measured from its text role.
    SectionLabelGap = 9,

    -- Retained for the header path, which is now only used when a container
    -- explicitly asks for an in-card description.
    HeaderPaddingTop = 9,
    HeaderPaddingBottom = 8,
    HeaderPaddingX = 16,
    DescriptionGap = 3,

    -- Padding inside the card, and the gap between two rows. Rows are separated
    -- by a hairline drawn at the element boundary, so the list spacing is zero:
    -- each row owns its own breathing room through its height.
    PaddingLeft = 16,
    PaddingRight = 16,
    PaddingTop = 0,
    PaddingBottom = 0,
    ElementSpacing = 0,

    -- Between two cards stacked in the same column, label included.
    Spacing = 14,

    Radius = 10,

    -- The hairline between two rows, inset to the card's text padding.
    RowDivider = 1,
}

--// Row rhythm inside a card. Measured from the reference: a plain row is 40
-- tall, a row that also carries a track below its label is 58.
Metrics.Row = {
    Height = 40,
    TallHeight = 58,
    -- A row with a description line beneath its label needs the extra line.
    DescriptionGap = 1,
}

--// Two-column page layout
Metrics.Columns = {
    Gap = 10,
    MinWidth = 160,
}

--// Toggles. A capsule track with a circular knob, sized so the knob clears the
-- track by a consistent inset at both terminal positions.
Metrics.Toggle = {
    TrackWidth = 36,
    TrackHeight = 20,
    KnobSize = 16,
    KnobInset = 2,
}

--// Sliders. A thin full-width track under the label, with a circular thumb and
-- a compact value pill sitting at the right end of the label line.
Metrics.Slider = {
    TrackThickness = 4,
    ThumbSize = 11,
    -- Air between the label line and the track.
    LabelGap = 8,
    ValuePillWidth = 36,
    ValuePillHeight = 18,
}

--// Buttons. The height is deliberately the shared control height: a button, a
-- text field and a dropdown trigger are the same object size on the same grid.
Metrics.Button = {
    Height = 28,
    HorizontalPadding = 12,
    SubGap = 6,
    -- A compact action trigger sitting at the right of a labelled row.
    ActionWidth = 34,
    ActionHeight = 24,
    -- A double-click prompt is armed for this long and then forgets.
    DoubleClickWindow = 0.6,
}

--// Labels
Metrics.Label = {
    -- Extra height a wrapped label adds per line beyond what measurement reports.
    LineGap = 0,
}

--// Dividers. Structure without another box: a hairline with deliberate air
-- above and below it, never a bright rule.
Metrics.Divider = {
    Thickness = 1,
    MarginTop = 4,
    MarginBottom = 4,
    TextGap = 8,
}

--// Dropdown
Metrics.Dropdown = {
    Height = 28,

    ItemHeight = 26,
    ItemSpacing = 1,
    ItemPaddingX = 10,

    HorizontalPadding = 10,

    PopupPadding = 5,
    PopupGap = 5, -- between trigger edge and popup edge
    PopupMinWidth = 130,
    ViewportMargin = 8,

    ChevronSize = 8,
    ChevronThickness = 1,
    ChevronPadding = 10,

    MaxVisibleItems = 6,

    SearchHeight = 26,
    SearchGap = 5,

    MarkerWidth = 2,
    MarkerInset = 3,
    MarkerVerticalInset = 6,

    ScrollBarThickness = 3,

    -- The recessed field at the right of a labelled row.
    FieldWidth = 132,
}

--// Text input
Metrics.Input = {
    Height = 28,
    HorizontalPadding = 10,
    FieldWidth = 132,
}

--// Multi-line text area. Full width inside the card, recessed, with its own
-- internal padding and a controlled line rhythm.
Metrics.TextArea = {
    PaddingX = 10,
    PaddingY = 8,
    LineSpacing = 3,
    MinLines = 3,
    MaxLines = 8,
}

--// Popups and overlays
Metrics.Popup = {
    Radius = 10,
    Padding = 5,
    ToastPaddingX = 14,
    ToastPaddingY = 11,
    ToastGap = 8,
    DialogPaddingX = 20,
    DialogPaddingY = 18,
    DialogButtonGap = 8,
}

--// Typography sizes. Roles live in Typography.luau; sizes live here so the
-- whole vertical rhythm is tunable from one place.
Metrics.Text = {
    Identity = 13,
    IdentitySub = 11,
    Navigation = 13,
    PageTitle = 19,
    -- The external uppercase card label.
    SectionLabel = 10,
    -- The header tab strip.
    HeaderTab = 13,
    GroupboxTitle = 12,
    GroupboxDescription = 11,
    Body = 13,
    -- A control's primary label, and the smaller line that may sit under it.
    ControlLabel = 13,
    ControlDescription = 11,
    ControlValue = 12,
    Item = 12,
    Secondary = 12,
    Label = 13,
    Button = 12,
    DividerText = 11,
}

--// Touch. The interface keeps its compact geometry on a phone; what changes is
-- how much of it accepts a finger. A 4 pixel slider track is a reasonable thing
-- to look at and an unreasonable thing to hit, so the thin controls get an
-- invisible interaction area of this height, centred on the visible one. Nothing
-- moves and nothing grows: the pad overflows its row, and rows do not clip.
--
-- The value is a compromise. It is well short of the 44 pixel guideline because
-- these are logical units before DPI scaling, and a phone user running the
-- library at 1.5 scale is already past that.
Metrics.Touch = {
    MinTarget = 30,
}

--// Motion (seconds). Restrained by intent; 0 disables a transition.
Metrics.Motion = {
    Hover = 0.09,
    Select = 0.11,
    Focus = 0.09,
    Popup = 0.10,
    Chevron = 0.12,
    -- The toggle knob and the dock indicator travel; they do not pop.
    Knob = 0.13,
}

--// Derived geometry. Functions rather than cached values so edits above stay
-- coherent without a rebuild step.

-- Left edge of the content region, measured from the window's inner origin. The
-- dock is inset from the window edge, so the content clears both.
function Metrics.ContentOriginX(self: typeof(Metrics)): number
    return self.Window.OuterPadding + self.Dock.Width
end

-- Vertical centre of the nth dock item (1-based), measured from the dock's top.
function Metrics.DockItemCentre(self: typeof(Metrics), index: number): number
    local dock = self.Dock
    return dock.PaddingTop + dock.MascotSize / 2 + dock.MascotGap + (index - 1) * dock.ItemPitch
end

-- Popup height for a given item count, including padding and optional search.
function Metrics.DropdownPopupHeight(self: typeof(Metrics), itemCount: number, searchable: boolean): number
    local dropdown = self.Dropdown
    local visible = math.clamp(itemCount, 1, dropdown.MaxVisibleItems)
    local list = visible * dropdown.ItemHeight + math.max(0, visible - 1) * dropdown.ItemSpacing
    local height = list + dropdown.PopupPadding * 2
    if searchable then
        height += dropdown.SearchHeight + dropdown.SearchGap
    end
    return height
end

-- Canvas height for the full item list, independent of the visible window.
function Metrics.DropdownCanvasHeight(self: typeof(Metrics), itemCount: number): number
    local dropdown = self.Dropdown
    if itemCount <= 0 then
        return 0
    end
    return itemCount * dropdown.ItemHeight + (itemCount - 1) * dropdown.ItemSpacing
end

return Metrics
end)()

local Module9 = (function()
--!strict
local Tokens = {}

local function rgb(r: number, g: number, b: number): Color3
    return Color3.fromRGB(r, g, b)
end

Tokens.Source = {
    --// The window body. Neutral: the shell carries its hierarchy in borders,
    -- spacing and one accent, so the surfaces themselves stay out of the way
    -- and any accent a preset chooses reads cleanly on top of them.
    BackgroundColor = rgb(21, 21, 21),
    --// One step up: cards, the dock, popups. Two points, not fifty -- the card
    -- is separated from the page by its border and its radius far more than by
    -- its value, which is what keeps a column of them quiet.
    MainColor = rgb(23, 23, 23),
    --// Emphasis. A blue bright enough to survive on a dark surface at a two
    -- pixel marker width, which is the smallest thing that ever wears it.
    AccentColor = rgb(105, 132, 250),
    --// Structural separation, and the far end of the neutral ramp that both
    -- the surface and text ladders are measured against. Every recessed field
    -- in the interface is a mix toward this value, so raising it lifts the
    -- whole ramp at once.
    OutlineColor = rgb(41, 41, 41),
    --// Primary text. Not pure white: at 228 it stops vibrating against a very
    -- dark background while still clearing 14:1.
    FontColor = rgb(228, 228, 228),
    --// Destructive. Desaturated well below a warning red so that a risky
    -- button reads as serious rather than alarming, and light enough to clear
    -- normal-text contrast as text on a raised button, which is the surface it
    -- is hardest to read on.
    DestructiveColor = rgb(224, 106, 106),
    --// Compositing poles.
    DarkColor = Color3.new(0, 0, 0),
    WhiteColor = Color3.new(1, 1, 1),

    Font = Font.fromEnum(Enum.Font.BuilderSans),
}

return Tokens
end)()

local Module10 = (function()
--!strict
local Metrics = Module8
local Types = Module3

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
end)()

local Module11 = (function()
--!strict
local Types = Module3
local Theme = Module2
local Metrics = Module8

local TweenService = game:GetService("TweenService")

local Materials = {}

-- ZIndex roles. Sibling ZIndexBehavior, so these compare only within a parent.
Materials.Z = {
    Base = 1,
    Interaction = 3,
    Structure = 4,
    Edge = 5,
    Text = 6,
    Overlay = 10,
}

export type LayerSpec = { Token: string, Transparency: number }
export type ShadowSpec = {
    Token: string,
    Transparency: number,
    Blur: number,
    Spread: number,
    OffsetY: number?,
}
export type SurfaceSpec = {
    Base: LayerSpec,
    Border: LayerSpec?,
    Cast: ShadowSpec?,
}

-- Every surface kind in the library. A component names a kind; it never names a
-- colour, a transparency or a stroke width.
Materials.Surfaces = {
    Shell = {
        Base = { Token = "Surface.Canvas", Transparency = 0 },
        Border = { Token = "Border.Normal", Transparency = 0 },
        Cast = {
            Token = "Overlay.Shadow",
            Transparency = Metrics.Window.ShadowTransparency,
            Blur = Metrics.Window.ShadowBlur,
            Spread = Metrics.Window.ShadowSpread,
            OffsetY = Metrics.Window.ShadowOffsetY,
        },
    },
    Sidebar = { Base = { Token = "Surface.Primary", Transparency = 0 } },
    -- The content region is the window body. It is not a raised plate: the only
    -- things that rise off it are the dock and the cards.
    Content = { Base = { Token = "Surface.Canvas", Transparency = 0 } },
    Divider = { Base = { Token = "Border.Divider", Transparency = 0 } },

    -- The left navigation dock. A panel inset from the window edge, one step
    -- above the page with the same restrained border every card wears, so the
    -- dock and the cards read as the same class of object.
    Dock = {
        Base = { Token = "Surface.Primary", Transparency = 0 },
        Border = { Token = "Border.Normal", Transparency = 0 },
    },

    -- The rounded container behind an active dock glyph. Its fill is the accent
    -- itself rather than an interaction tint: this is the one place in the
    -- interface where a surface is painted accent.
    DockItemActive = { Base = { Token = "Accent.Base", Transparency = 0 } },

    -- A module card. Deliberately identical to Groupbox: they are the same
    -- object, named twice while the two words are both in use.
    Card = {
        Base = { Token = "Surface.Primary", Transparency = 0 },
        Border = { Token = "Border.Normal", Transparency = 0 },
    },

    -- A recessed plate inside a card: a dropdown field, a text input, a text
    -- area, a slider track, a value pill. Borderless, because inside a card the
    -- value step alone is enough and a border here would add a third edge to
    -- every row.
    Field = { Base = { Token = "Surface.Sunken", Transparency = 0 } },

    -- The canonical control container. One step above the page it sits on, with
    -- a restrained border; the controls inside it are sunken, so the hierarchy
    -- reads page -> groupbox -> field without a single extra wrapper.
    Groupbox = {
        Base = { Token = "Surface.Primary", Transparency = 0 },
        Border = { Token = "Border.Normal", Transparency = 0 },
    },

    -- A control at rest: a sunken well with a restrained border.
    Control = {
        Base = { Token = "Surface.Sunken", Transparency = 0 },
        Border = { Token = "Border.Normal", Transparency = 0 },
    },

    -- A detached surface floating over the interface.
    Popup = {
        Base = { Token = "Surface.Primary", Transparency = 0 },
        Border = { Token = "Border.Hover", Transparency = 0 },
        Cast = {
            Token = "Overlay.Shadow",
            Transparency = Theme.Alpha.ShadowPopup,
            Blur = 18,
            Spread = -6,
            OffsetY = 6,
        },
    },

    -- A button is raised where a field is sunken. That, not size, is what makes
    -- it read as something to press rather than something to type into.
    Button = {
        Base = { Token = "Surface.Raised", Transparency = 0 },
        Border = { Token = "Border.Normal", Transparency = 0 },
    },

    -- A compact action trigger at the right of a labelled row. Raised like a
    -- button, but with no border: at 34 by 24 a stroke would eat the glyph.
    Action = { Base = { Token = "Surface.Raised", Transparency = 0 } },

    -- A surface whose fill is carried entirely by its interaction layer.
    Interactive = { Base = { Token = "Interaction.Hover", Transparency = 1 } },
} :: { [string]: SurfaceSpec }

-- Interaction states. Not every surface uses every state; where two controls
-- share a state conceptually, they share these values -- which is what makes a
-- hovered button, a hovered dropdown and a hovered list item read as the same
-- gesture rather than three near-misses.
--
-- The alphas come from Theme.Alpha rather than sitting here as literals: a
-- transparency is part of how a colour is perceived, so it belongs with the
-- palette.
Materials.States = {
    Rest = { Token = "Interaction.Hover", Transparency = Theme.Alpha.Rest },
    Hover = { Token = "Interaction.Hover", Transparency = Theme.Alpha.Hover },
    Active = { Token = "Interaction.Pressed", Transparency = Theme.Alpha.Pressed },
    -- Pressed is a fill change and nothing else: no shrink, no text offset, no
    -- glow. The control stays exactly where it was under the pointer.
    Pressed = { Token = "Interaction.Pressed", Transparency = Theme.Alpha.Pressed },
    Selected = { Token = "Interaction.Selected", Transparency = Theme.Alpha.Selected },
    -- A disabled control drops its interaction fill entirely and recedes
    -- through its own tokens instead, so disabled text keeps a known colour the
    -- contrast engine can measure.
    Disabled = { Token = "Interaction.Hover", Transparency = Theme.Alpha.Disabled },
} :: { [string]: LayerSpec }

-- Border roles per control state. One mapping, used by every bordered control,
-- so no control invents its own focus colour.
Materials.BorderStates = {
    Rest = "Border.Normal",
    Hover = "Border.Hover",
    Focused = "Border.Focused",
    Open = "Border.Focused",
    Risky = "Border.Destructive",
    Disabled = "Border.Disabled",
} :: { [string]: Types.ThemeRole }

function Materials.SpecFor(kind: string): SurfaceSpec
    local spec = Materials.Surfaces[kind]
    assert(spec, "Unknown surface kind: " .. tostring(kind))
    return spec
end

--// Motion -------------------------------------------------------------------
-- At most one live tween per instance. Retargeting disposes the previous one, so
-- nothing accumulates however fast the pointer moves.

export type Animator = {
    Library: any,
    Scope: Types.Scope,
    Slots: { [Instance]: Types.Cleanup },
}

function Materials.NewAnimator(library: any, scope: Types.Scope): Animator
    local animator: Animator = { Library = library, Scope = scope, Slots = {} }
    scope:Add(function()
        for instance, dispose in animator.Slots do
            animator.Slots[instance] = nil
            dispose()
        end
        table.clear(animator.Slots)
    end)
    return animator
end

local function setDirect(library: any, instance: Instance, properties: { [string]: any })
    for property, value in properties do
        library:_SetProperty(instance, property, value)
    end
end

function Materials.Animate(animator: Animator, instance: Instance, properties: { [string]: any }, duration: number)
    local previous = animator.Slots[instance]
    if previous then
        previous()
    end

    -- No tween during teardown: tracking one needs a live library, and a fading
    -- control that is about to be destroyed is not worth an error.
    if
        duration <= 0
        or animator.Library.MotionEnabled == false
        or animator.Scope.Destroyed
        or animator.Library.Unloaded
    then
        setDirect(animator.Library, instance, properties)
        return
    end

    local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local ok, tween = pcall(function()
        return TweenService:Create(instance, info, properties)
    end)
    if not ok or not tween then
        setDirect(animator.Library, instance, properties)
        return
    end

    local dispose = animator.Library:TrackTween(tween, animator.Scope)
    animator.Slots[instance] = function()
        if animator.Slots[instance] then
            animator.Slots[instance] = nil
        end
        dispose()
    end
    tween:Play()
end

--// Surfaces -----------------------------------------------------------------

export type Surface = {
    Instance: Frame,
    Kind: string,
    Scope: Types.Scope,
    Radius: number,
    Border: UIStroke?,
    Cast: UIShadow?,
    Interaction: Frame?,
    State: string,
    BorderState: string,
}

export type Context = {
    Library: any,
    Animator: Animator,
    Surfaces: { Surface },
    HasShadows: boolean,
}

-- Rebinds a token through the foundation's scheme registry, so a palette change
-- recolours the instance without any component storing a colour.
local function bindToken(library: any, instance: Instance, property: string, token: string, scope: Types.Scope)
    -- Teardown order is not ours to choose. A control registered in the library
    -- registry is destroyed before the shell's own scope, so its Destroy can run
    -- while the library is already unloaded and every binding API refuses. Write
    -- the value straight through instead of erroring inside a cleanup callback.
    if library.Unloaded then
        library:_SetProperty(instance, property, library.Scheme[token])
        return
    end

    -- Rebinding is not free, and hover states ask for the same token over and
    -- over. Skip when the instance already carries exactly this one binding.
    local entry = library.Registry[instance]
    if entry then
        local matches = entry.Properties[property] == token
        if matches then
            for key in entry.Properties do
                if key ~= property then
                    matches = false
                    break
                end
            end
        end
        if matches then
            return
        end
    end
    library:UnregisterProperty(instance)
    library:RegisterProperty(instance, { [property] = token }, scope)
end

Materials.BindToken = bindToken

function Materials.NewContext(library: any, scope: Types.Scope): Context
    return {
        Library = library,
        Animator = Materials.NewAnimator(library, scope),
        Surfaces = {},
        HasShadows = library.Runtime ~= nil and library.Runtime:HasCapability("UIShadow"),
    }
end

function Materials.CreateSurface(
    context: Context,
    params: {
        Name: string,
        Kind: string,
        Parent: Instance?,
        Scope: Types.Scope,
        Position: UDim2?,
        Size: UDim2,
        Radius: number?,
        AnchorPoint: Vector2?,
        ZIndex: number?,
        Interactive: boolean?,
        Clip: boolean?,
        Visible: boolean?,
    }
): Surface
    local library = context.Library
    local scope = params.Scope
    local radius = params.Radius or 0

    local frame = library:Create("Frame", {
        Name = params.Name,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = params.Position or UDim2.fromOffset(0, 0),
        AnchorPoint = params.AnchorPoint or Vector2.zero,
        Size = params.Size,
        ZIndex = params.ZIndex or Materials.Z.Base,
        Visible = params.Visible ~= false,
        -- Clipping to the rounded corner is what stops a square child from
        -- poking through a rounded parent.
        ClipsDescendants = params.Clip ~= false,
    }, scope) :: Frame

    if radius > 0 then
        library:Create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = frame }, scope)
    end

    local surface: Surface = {
        Instance = frame,
        Kind = params.Kind,
        Scope = scope,
        Radius = radius,
        Border = nil,
        Cast = nil,
        Interaction = nil,
        State = "Rest",
        BorderState = "Rest",
    }

    -- Interaction fill, kept separate from the base so a state change never
    -- touches the surface's own material values, and never moves geometry.
    if params.Interactive then
        local interaction = library:Create("Frame", {
            Name = "Interaction",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.fromScale(1, 1),
            ZIndex = Materials.Z.Interaction,
            Parent = frame,
        }, scope) :: Frame
        surface.Interaction = interaction
        if radius > 0 then
            library:Create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = interaction }, scope)
        end
    end

    if params.Parent then
        frame.Parent = params.Parent
    end

    table.insert(context.Surfaces, surface)
    scope:Add(function()
        local index = table.find(context.Surfaces, surface)
        if index then
            table.remove(context.Surfaces, index)
        end
    end)

    Materials.ApplySurface(context, surface, 0)
    return surface
end

-- Created lazily so surfaces that never want a border do not stack two strokes
-- on a shared edge, which is what makes overlapping rims read twice as bright.
function Materials.EnsureBorder(context: Context, surface: Surface): UIStroke
    local existing = surface.Border
    if existing then
        return existing
    end
    local stroke = context.Library:Create("UIStroke", {
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Thickness = Metrics.Stroke.Thickness,
        Transparency = 1,
        Parent = surface.Instance,
    }, surface.Scope) :: UIStroke
    surface.Border = stroke
    return stroke
end

local function ensureShadow(context: Context, surface: Surface): UIShadow?
    if not context.HasShadows then
        return nil
    end
    if surface.Cast then
        return surface.Cast
    end
    local ok, shadow = pcall(function()
        return context.Library:Create("UIShadow", {
            Name = "Cast",
            Inset = false,
            Enabled = false,
            Transparency = 1,
            -- An outer shadow must not draw over the surface it belongs to.
            ShowBehindParent = true,
            ZIndex = Materials.Z.Base,
            Parent = surface.Instance,
        }, surface.Scope)
    end)
    if not ok or not shadow then
        return nil
    end
    surface.Cast = shadow :: UIShadow
    return surface.Cast
end

function Materials.ApplySurface(context: Context, surface: Surface, duration: number)
    local library = context.Library
    local spec = Materials.SpecFor(surface.Kind)
    local frame = surface.Instance
    local scope = surface.Scope

    bindToken(library, frame, "BackgroundColor3", spec.Base.Token, scope)
    Materials.Animate(context.Animator, frame, { BackgroundTransparency = spec.Base.Transparency }, duration)

    if spec.Border then
        local border = Materials.EnsureBorder(context, surface)
        border.Thickness = Metrics.Stroke.Thickness
        Materials.ApplyBorderState(context, surface, surface.BorderState)
        Materials.Animate(context.Animator, border, { Transparency = spec.Border.Transparency }, duration)
    elseif surface.Border then
        Materials.Animate(context.Animator, surface.Border, { Transparency = 1 }, duration)
    end

    local castSpec = spec.Cast
    if castSpec then
        local shadow = ensureShadow(context, surface)
        if shadow then
            bindToken(library, shadow, "Color", castSpec.Token, scope)
            shadow.BlurRadius = UDim.new(0, castSpec.Blur)
            shadow.Spread = UDim2.fromOffset(castSpec.Spread, castSpec.Spread)
            shadow.Offset = UDim2.fromOffset(0, castSpec.OffsetY or 0)
            shadow.Enabled = true
            Materials.Animate(context.Animator, shadow, { Transparency = castSpec.Transparency }, duration)
        end
    elseif surface.Cast then
        surface.Cast.Enabled = false
    end

    if surface.Interaction then
        Materials.ApplyState(context, surface, surface.State, duration)
    end
end

-- Hover / pressed / active / selected / rest. Only the interaction layer's
-- colour and transparency change: no padding, no size, no font, so geometry
-- cannot move between states.
function Materials.ApplyState(context: Context, surface: Surface, state: string, duration: number)
    local interaction = surface.Interaction
    if not interaction then
        return
    end
    surface.State = state
    local spec = Materials.States[state]
    assert(spec, "Unknown interaction state: " .. tostring(state))
    bindToken(context.Library, interaction, "BackgroundColor3", spec.Token, surface.Scope)
    Materials.Animate(context.Animator, interaction, { BackgroundTransparency = spec.Transparency }, duration)
end

-- Border state is independent of fill state: a focused input is not hovered, and
-- an open dropdown keeps its focus border while the pointer is over its popup.
--
-- Only the bound colour token changes. Opacity belongs to the surface spec, and
-- thickness never changes, so a state change cannot alter the control's outline
-- geometry by so much as a subpixel.
function Materials.ApplyBorderState(context: Context, surface: Surface, state: string)
    surface.BorderState = state
    local border = surface.Border
    if not border then
        return
    end
    local token = Materials.BorderStates[state]
    assert(token, "Unknown border state: " .. tostring(state))
    bindToken(context.Library, border, "Color", token, surface.Scope)
end

return Materials
end)()

local Module12 = (function()
--!strict
local Types = Module3
local Metrics = Module8

local GuiService = game:GetService("GuiService")

local Popup = {}
Popup.__index = Popup

-- An owner is anything that can be closed and can say whether a screen point
-- belongs to it. Dropdowns implement it; future temporary surfaces can too.
export type Owner = {
    Close: (any) -> (),
    ContainsPoint: (any, point: Vector2) -> boolean,
    Destroyed: boolean,
}

export type Manager = typeof(setmetatable(
    {} :: {
        Library: any,
        Resources: Types.Scope,
        Active: Owner?,
        _InputScope: Types.Scope?,
    },
    Popup
))

function Popup.new(library: any, scope: Types.Scope): Manager
    local manager: Manager = setmetatable({
        Library = library,
        Resources = scope,
        Active = nil,
        _InputScope = nil,
    }, Popup)
    scope:Add(function()
        manager:CloseActive()
    end)
    return manager
end

--// Ownership ----------------------------------------------------------------

-- Starts listening for the click that dismisses whatever is open. One connection
-- total, created on the first open and dropped on the last close.
function Popup._BindOutside(self: Manager)
    if self._InputScope then
        return
    end
    local library = self.Library
    local runtime = library.Runtime
    if not runtime then
        return
    end
    local scope = library:CreateScope(self.Resources)
    self._InputScope = scope
    scope:Add(function()
        if self._InputScope == scope then
            self._InputScope = nil
        end
    end)
    -- The GUI-processed flag is deliberately ignored. A click on another part of
    -- this same interface is processed input, and it is exactly the click that
    -- has to dismiss the popup; the hit test below decides, not the engine.
    library:Connect(runtime.Input.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        local owner = self.Active
        if not owner then
            return
        end
        if owner.Destroyed or not owner:ContainsPoint(Popup.PointerPoint(input)) then
            self:CloseActive()
        end
    end, scope)
end

function Popup._UnbindOutside(self: Manager)
    local scope = self._InputScope
    if scope then
        self._InputScope = nil
        scope:Destroy()
    end
end

-- Opening always closes whatever was open first, including this owner's own
-- previous popup, so reopening cannot leave a second surface behind.
function Popup.Open(self: Manager, owner: Owner)
    assert(not self.Resources.Destroyed, "Popup manager is destroyed")
    if self.Active == owner then
        return
    end
    self:CloseActive()
    self.Active = owner
    self.Library.ActivePopup = owner :: any
    self:_BindOutside()
end

-- Releases ownership without calling back into the owner. Used by an owner that
-- is already closing itself, and by teardown.
function Popup.Release(self: Manager, owner: Owner)
    if self.Active ~= owner then
        return
    end
    self.Active = nil
    if self.Library.ActivePopup == owner then
        self.Library.ActivePopup = nil
    end
    self:_UnbindOutside()
end

function Popup.CloseActive(self: Manager)
    local owner = self.Active
    if not owner then
        return
    end
    -- Clear first: the owner's Close calls back into Release, and a destroyed or
    -- throwing owner must not be able to leave ActivePopup pointing at it.
    self.Active = nil
    if self.Library.ActivePopup == owner then
        self.Library.ActivePopup = nil
    end
    self:_UnbindOutside()
    if not owner.Destroyed then
        self.Library:SafeCallback(owner.Close, owner)
    end
end

--// Geometry -----------------------------------------------------------------

-- True when `instance` and every ancestor up to the layer are visible. A trigger
-- inside a hidden page must not keep a popup attached to it.
function Popup.IsDisplayed(instance: GuiObject): boolean
    local current: Instance? = instance
    while current and current:IsA("GuiObject") do
        if not (current :: GuiObject).Visible then
            return false
        end
        current = current.Parent
    end
    return current ~= nil
end

export type Placement = {
    Position: UDim2,
    Size: UDim2,
    Direction: "Down" | "Up",
    Width: number,
    Height: number,
}

-- Resolves a popup rectangle in the Overlay layer's logical units.
--
-- Everything is derived from the trigger's current absolute geometry, never from
-- where the trigger was when it was created, so window dragging, resizing, page
-- scrolling, layout changes and DPI changes all resolve correctly by calling
-- this again.
function Popup.Place(library: any, trigger: GuiObject, desiredHeight: number, minWidth: number?): Placement?
    local overlay = library.Overlay
    local gui = library.ScreenGui
    if not overlay or not gui then
        return nil
    end
    local scale = library.DPIScale
    if scale <= 0 then
        return nil
    end

    local origin = overlay.AbsolutePosition
    local triggerPosition = (trigger.AbsolutePosition - origin) / scale
    local triggerSize = trigger.AbsoluteSize / scale
    if triggerSize.X <= 0 or triggerSize.Y <= 0 then
        return nil
    end

    -- Viewport expressed in the same logical frame as the trigger.
    local viewportOrigin = (gui.AbsolutePosition - origin) / scale
    local viewportSize = gui.AbsoluteSize / scale

    local config = Metrics.Dropdown
    local margin = config.ViewportMargin
    local gap = config.PopupGap

    -- The layer ignores the GUI inset, so the top of the layer is behind the
    -- topbar. A popup placed there would be drawn under it and unclickable.
    local insetY = Popup.GuiInset().Y / scale

    local left = viewportOrigin.X + margin
    local right = viewportOrigin.X + viewportSize.X - margin
    local top = viewportOrigin.Y + insetY + margin
    local bottom = viewportOrigin.Y + viewportSize.Y - margin

    -- Width follows the trigger, with a floor, and never leaves the viewport.
    local width = math.max(triggerSize.X, minWidth or config.PopupMinWidth)
    width = math.min(width, math.max(1, right - left))

    local below = bottom - (triggerPosition.Y + triggerSize.Y) - gap
    local above = triggerPosition.Y - top - gap

    -- Prefer downward. Flip only when below genuinely cannot hold the popup and
    -- above can hold more of it.
    local direction: "Down" | "Up" = "Down"
    local available = below
    if desiredHeight > below and above > below then
        direction = "Up"
        available = above
    end

    -- When neither side can hold the popup, it is still a popup: it keeps a
    -- usable minimum height and the clamp below brings it back into view rather
    -- than collapsing it into a sliver.
    local minimum = math.min(config.ItemHeight + config.PopupPadding * 2, math.max(1, bottom - top))
    local height = math.clamp(math.floor(math.min(desiredHeight, available)), minimum, math.max(minimum, desiredHeight))

    local x = math.clamp(triggerPosition.X, left, math.max(left, right - width))
    local y: number
    if direction == "Down" then
        y = triggerPosition.Y + triggerSize.Y + gap
    else
        y = triggerPosition.Y - gap - height
    end
    y = math.clamp(y, top, math.max(top, bottom - height))

    -- Whole logical pixels: a popup edge on a half pixel reads as a soft edge.
    return {
        Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5)),
        Size = UDim2.fromOffset(math.floor(width + 0.5), math.floor(height + 0.5)),
        Direction = direction,
        Width = math.floor(width + 0.5),
        Height = math.floor(height + 0.5),
    }
end

-- An InputObject's position is measured from the top-left of the viewport below
-- the topbar, while AbsolutePosition is measured from the top-left of the screen.
-- Comparing them directly is off by the inset, which is why a hit test that looks
-- right lands a topbar's height above where the pointer actually is.
-- The screen area the topbar covers. Also the reason a window whose top edge
-- sits at y = 0 has an ungrabbable title strip.
function Popup.GuiInset(): Vector2
    local ok, inset = pcall(function()
        return (GuiService:GetGuiInset())
    end)
    if ok and typeof(inset) == "Vector2" then
        return inset
    end
    return Vector2.zero
end

function Popup.PointerPoint(input: InputObject): Vector2
    return Vector2.new(input.Position.X, input.Position.Y) + Popup.GuiInset()
end

-- Screen-space hit test against a rendered rectangle. Both the adjusted pointer
-- position and AbsolutePosition/AbsoluteSize are physical, so no DPI scaling is
-- involved here.
function Popup.Contains(instance: GuiObject?, point: Vector2): boolean
    if not instance or not instance.Visible then
        return false
    end
    local position = instance.AbsolutePosition
    local size = instance.AbsoluteSize
    return point.X >= position.X
        and point.X <= position.X + size.X
        and point.Y >= position.Y
        and point.Y <= position.Y + size.Y
end

return Popup
end)()

local Module13 = (function()
--!strict
local Types = Module3
local Metrics = Module8
local Materials = Module11
local Typography = Module10
local Popup = Module12

local Controls = {}

--// Host ---------------------------------------------------------------------

export type Focusable = {
    Destroyed: boolean,
    ReleaseFocus: (any) -> (),
}

export type Host = {
    Library: any,
    Resources: Types.Scope,
    Context: Materials.Context,
    Typography: Typography.Typography,
    Popups: Popup.Manager,
    Focused: Focusable?,
    ReleaseFocus: (Host) -> (),
    SetFocused: (Host, Focusable?) -> (),
    -- Called before any control takes over interaction: opening a dropdown or
    -- focusing a field is a single, consistent handover.
    BeginInteraction: (Host, keepFocus: boolean?, source: GuiObject?) -> (),
}

function Controls.NewHost(library: any, scope: Types.Scope, typography: Typography.Typography): Host
    local host: Host

    host = {
        Library = library,
        Resources = scope,
        Context = Materials.NewContext(library, scope),
        Typography = typography,
        Popups = Popup.new(library, scope),
        Focused = nil,

        SetFocused = function(self: Host, control: Focusable?)
            self.Focused = control
            self.Library.FocusedControl = control :: any
        end,

        -- Releasing focus goes through the control, so its own committed-value
        -- and visual-state logic runs instead of being bypassed.
        ReleaseFocus = function(self: Host)
            local control = self.Focused
            if not control then
                return
            end
            self.Focused = nil
            if self.Library.FocusedControl == control then
                self.Library.FocusedControl = nil
            end
            if not control.Destroyed then
                self.Library:SafeCallback(control.ReleaseFocus, control)
            end
        end,

        -- One rule for the whole library: taking interaction closes any open
        -- popup and, unless the caller is the field itself, releases keyboard
        -- focus. Nothing can end up typing into a covered or invisible field.
        BeginInteraction = function(self: Host, keepFocus: boolean?, source: GuiObject?)
            local dynamic: any = self
            if dynamic.Library.CapturingKey then
                dynamic.Library.CapturingKey:CancelCapture()
            end
            local active: any = self.Popups.Active
            local surface = active and (active.Frame or (active._Popup and active._Popup.Instance))
            local current: Instance? = source
            local inside = false
            while current do
                if current == surface then
                    inside = true
                    break
                end
                current = current.Parent
            end
            if not inside then
                self.Popups:CloseActive()
            end
            if not keepFocus then
                self:ReleaseFocus()
            end
        end,
    }

    scope:Add(function()
        host.Focused = nil
        if library.FocusedControl ~= nil then
            library.FocusedControl = nil
        end
    end)

    return host
end

--// Callback lists -----------------------------------------------------------
-- Insertion-ordered, safe against a listener that disconnects during dispatch,
-- and cleared with the control's scope.

export type Signal = {
    Connect: (Signal, callback: (...any) -> ()) -> Types.Cleanup,
    Fire: (Signal, ...any) -> (),
}

function Controls.NewSignal(library: any, scope: Types.Scope): Signal
    local listeners: { (...any) -> () } = {}
    local signal: Signal
    signal = {
        Connect = function(_self: Signal, callback: (...any) -> ()): Types.Cleanup
            assert(type(callback) == "function", "Listener must be a function")
            table.insert(listeners, callback)
            return function()
                local index = table.find(listeners, callback)
                if index then
                    table.remove(listeners, index)
                end
            end
        end,
        Fire = function(_self: Signal, ...: any)
            -- Snapshot: a listener may disconnect itself or another listener.
            for _, callback in table.clone(listeners) do
                library:SafeCallback(callback, ...)
            end
        end,
    }
    scope:Add(function()
        table.clear(listeners)
    end)
    return signal
end

--// Rows ---------------------------------------------------------------------
-- A control row is a label on the left and a fixed-height body on the right,
-- both centred on the row's own centre line; or just the body, filling the row,
-- when there is no label.
--
-- Every row-shaped control in the library goes through here, which is what makes
-- a dropdown field, a text input and an action button land on the same baseline
-- inside the same card and share one row height. A control does not decide how
-- tall its row is -- Metrics.Row does.

export type Row = {
    Frame: Frame,
    Label: TextLabel?,
    BodyOffset: number,
    BodyWidth: number,
    Height: number,
}

function Controls.CreateRow(
    host: Host,
    params: {
        Name: string,
        Text: string?,
        Parent: Instance?,
        Scope: Types.Scope,
        LayoutOrder: number?,
        BodyHeight: number?,
        -- The width the body reserves at the right of the row. The label takes the
        -- rest, less one gap, so the two can never overlap.
        BodyWidth: number?,
        -- A row that owns its own height rather than taking the shared one: a text
        -- area, a colour picker's canvas, anything taller than a single line.
        Height: number?,
    }
): Row
    local library = host.Library
    local typography = host.Typography
    local bodyHeight = params.BodyHeight or Metrics.Control.Height

    local hasLabel = params.Text ~= nil and params.Text ~= ""
    -- A labelled row takes the shared row height so it sits on the card's
    -- rhythm; an unlabelled one is exactly its body.
    local height = params.Height or (if hasLabel then math.max(Metrics.Row.Height, bodyHeight) else bodyHeight)
    local bodyWidth = params.BodyWidth or 0

    local frame = library:Create("Frame", {
        Name = params.Name,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height),
        LayoutOrder = params.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
    }, params.Scope) :: Frame

    local label: TextLabel? = nil
    if hasLabel then
        local line = typography:LineHeight(typography.Roles.ControlLabel)
        label = typography:Create("ControlLabel", {
            Name = "Label",
            Text = params.Text,
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = UDim2.new(1, -(bodyWidth + Metrics.Control.LabelGap), 0, line),
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = Materials.Z.Text,
            Parent = frame,
        }, params.Scope)
    end

    if params.Parent then
        frame.Parent = params.Parent
    end

    -- The body's vertical origin: centred in the row, so a 28 tall field and a
    -- 24 tall action button in adjacent rows share a centre line.
    local bodyOffset = math.floor((height - bodyHeight) / 2)

    return {
        Frame = frame,
        Label = label,
        BodyOffset = bodyOffset,
        BodyWidth = bodyWidth,
        Height = height,
    }
end

--// Chevron ------------------------------------------------------------------
-- Two thin bars meeting at a point. Drawn rather than typed, so it is exactly
-- the configured size at every scale instead of whatever a glyph happens to be,
-- and rotating the container is the whole open/closed animation.

export type Chevron = { Frame: Frame, Bars: { Frame } }

function Controls.CreateChevron(
    host: Host,
    params: {
        Parent: Instance,
        Scope: Types.Scope,
        Token: Types.ThemeRole?,
        -- A chevron centred in its parent and turned a quarter turn is the action
        -- button's glyph. It is the same object as the dropdown's indicator, so the
        -- two are the same weight and the same size wherever they appear together.
        Centred: boolean?,
        Rotation: number?,
    }
): Chevron
    local library = host.Library
    local size = Metrics.Dropdown.ChevronSize
    local thickness = Metrics.Dropdown.ChevronThickness
    local token = params.Token or "Text.Muted"
    local centred = params.Centred == true

    local frame = library:Create("Frame", {
        Name = "Chevron",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Rotation = params.Rotation or 0,
        AnchorPoint = if centred then Vector2.new(0.5, 0.5) else Vector2.new(1, 0.5),
        Position = if centred
            then UDim2.fromScale(0.5, 0.5)
            else UDim2.new(1, -Metrics.Dropdown.ChevronPadding, 0.5, 0),
        Size = UDim2.fromOffset(size, size),
        ZIndex = Materials.Z.Text,
        ClipsDescendants = false,
        Parent = params.Parent,
    }, params.Scope) :: Frame

    local bars: { Frame } = {}
    for index, definition in
        {
            { Name = "Left", X = 0.305, Rotation = 45 },
            { Name = "Right", X = 0.695, Rotation = -45 },
        }
    do
        local bar = library:Create("Frame", {
            Name = definition.Name,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(definition.X, 0.57),
            Size = UDim2.fromOffset(math.round(size * 0.75), thickness),
            Rotation = definition.Rotation,
            ZIndex = Materials.Z.Text,
            Parent = frame,
        }, params.Scope) :: Frame
        library:RegisterProperty(bar, { BackgroundColor3 = token }, params.Scope)
        bars[index] = bar
    end

    return { Frame = frame, Bars = bars }
end

function Controls.SetChevronToken(host: Host, chevron: Chevron, token: Types.ThemeRole, scope: Types.Scope)
    for _, bar in chevron.Bars do
        Materials.BindToken(host.Library, bar, "BackgroundColor3", token, scope)
    end
end

--// Touch targets ------------------------------------------------------------

-- An invisible interaction area over a control that is too thin to hit with a
-- finger, returned as the thing to bind input to instead of the visible one.
--
-- It is a child of the target and is full width, so the horizontal arithmetic a
-- drag does against it is identical to the arithmetic against the target. Only
-- the height differs, and the extra height overflows the row rather than
-- displacing anything, because rows do not clip and layout heights are declared
-- by the control rather than measured from its descendants.
--
-- Returns nil on a device that is not touch-driven, and the caller then binds to
-- the visible control as before. There is deliberately no way to turn this on
-- for a mouse: a mouse can hit fourteen pixels, and an oversized invisible
-- button would only steal hover from the row above.
function Controls.TouchTarget(host: Host, target: GuiObject, scope: Types.Scope): GuiObject?
    local library = host.Library
    if not library.IsMobile then
        return nil
    end
    local minimum = Metrics.Touch.MinTarget
    local height = target.Size.Y.Offset
    if height >= minimum then
        return nil
    end
    local overhang = (minimum - height) / 2
    return library:Create("TextButton", {
        Name = "TouchTarget",
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, -overhang),
        Size = UDim2.new(1, 0, 1, overhang * 2),
        ZIndex = (target.ZIndex or Materials.Z.Structure) + 1,
        Parent = target,
    }, scope) :: GuiObject
end

return Controls
end)()

local Module14 = (function()
--!strict
local Types = Module3

local Element = {}

export type Container = {
    Destroyed: boolean,
    Elements: { any },
    Resources: Types.Scope,
    Resize: (any) -> (),
    ContentWidth: number,
}

export type Element = {
    Type: string,
    Parent: Container?,
    Holder: GuiObject,
    LayoutHeight: number,
    Visible: boolean,
    Destroyed: boolean,
    Resources: Types.Scope,
    Destroy: (any) -> (),
    Deactivate: ((any) -> ())?,
    _OnWidth: ((any, width: number) -> ())?,
}

-- Ownership is established once, at construction. An element belongs to exactly
-- one container for its whole life; there is no reparenting, because a control
-- that could move between containers would need two layout owners to agree.
function Element.Attach(element: any, container: Container)
    element.Parent = container
    table.insert(container.Elements, element)
end

-- Removes the element from its container's collection and asks the container to
-- close the gap. Safe to call more than once, and safe when the container is
-- already gone: a groupbox tearing down its children must not have each child
-- trigger a resize of a half-destroyed container.
function Element.Release(element: any)
    local container = element.Parent :: Container?
    element.Parent = nil
    if not container then
        return
    end
    local index = table.find(container.Elements, element)
    if index then
        table.remove(container.Elements, index)
    end
    if not container.Destroyed and not container.Resources.Destroyed then
        container:Resize()
    end
end

-- The single place a container is told its content changed height. Controls call
-- this; they never write to the container's geometry themselves.
function Element.RequestResize(element: any)
    local container = element.Parent :: Container?
    if not container or container.Destroyed or container.Resources.Destroyed then
        return
    end
    container:Resize()
end

-- Publishes a new flow height. The holder's own size is written here, so the
-- height a control reports and the height it occupies cannot drift apart.
function Element.SetHeight(element: any, height: number)
    local resolved = math.max(0, math.round(height))
    if element.LayoutHeight == resolved then
        return
    end
    element.LayoutHeight = resolved
    local holder = element.Holder :: GuiObject?
    if holder then
        holder.Size = UDim2.new(1, 0, 0, resolved)
    end
    Element.RequestResize(element)
end

-- Hidden elements do not occupy space: the holder stops participating in the
-- list layout entirely, rather than staying as an empty row. Any transient
-- interaction state the control owns is given up first, so nothing can be left
-- typing into, or hovering over, a control that is no longer on screen.
function Element.ApplyVisible(element: any, visible: boolean): boolean
    local flag = visible ~= false
    element.Visible = flag
    if not flag then
        Element.Deactivate(element)
    end
    local holder = element.Holder :: GuiObject?
    if holder then
        holder.Visible = flag
    end
    Element.RequestResize(element)
    return flag
end

function Element.Deactivate(element: any)
    if element.Tooltip then
        element.Tooltip:Close()
    end
    local hook = element.Deactivate
    if type(hook) == "function" then
        hook(element)
    end
end

-- Called by the container when its usable width changes. Only elements whose
-- height depends on width implement the hook; for everything else this is free.
function Element.ApplyWidth(element: any, width: number)
    local hook = element._OnWidth
    if type(hook) == "function" then
        hook(element, width)
    end
end

return Element
end)()

local Module15 = (function()
--!strict
local Types = Module3
local Metrics = Module8
local Materials = Module11
local Element = Module14
local Controls = Module13

local Label = {}
Label.__index = Label

export type Label = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Text: string,
        Wrap: boolean,
        Secondary: boolean,
        Disabled: boolean,
        Visible: boolean,

        Holder: Frame,
        Instance: TextLabel,
        LayoutHeight: number,

        _Width: number,
    },
    Label
))

export type Options = {
    Text: string?,
    Wrap: boolean?,
    Secondary: boolean?,
    Disabled: boolean?,
    Visible: boolean?,
    LayoutOrder: number?,
    Id: string?,
}

-- AddLabel("text") and AddLabel({ Text = "text" }) are the same call.
function Label.Normalise(options: (string | Options)?): Options
    if type(options) == "string" then
        return { Text = options }
    end
    return if options then table.clone(options :: Options) else {}
end

function Label.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Label
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    local holder = library:Create("Frame", {
        Name = "Label",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = config.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
    }, resources) :: Frame

    local self: Label = setmetatable({
        Type = "Label",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Text = config.Text or "",
        Wrap = config.Wrap == true,
        Secondary = config.Secondary == true,
        Disabled = config.Disabled == true,
        Visible = config.Visible ~= false,

        Holder = holder,
        Instance = nil :: any,
        LayoutHeight = 0,

        _Width = 0,
    }, Label)

    self.Instance = host.Typography:Create(self:_Role(), {
        Name = "Text",
        Text = self.Text,
        Size = UDim2.fromScale(1, 1),
        TextWrapped = self.Wrap,
        TextTruncate = if self.Wrap then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = holder,
    }, resources)

    holder.Visible = self.Visible
    holder.Parent = parent
    self:_Measure()

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

function Label._Role(self: Label): string
    if self.Disabled then
        return "LabelDisabled"
    end
    return if self.Secondary then "LabelSecondary" else "Label"
end

-- One measurement path. An unwrapped label is exactly one measured line; a
-- wrapped one is whatever the text needs at the current width, and never less
-- than one line, so an empty string still holds its row open predictably.
function Label._Measure(self: Label)
    if self.Destroyed then
        return
    end
    local typography = self.Host.Typography
    local role = typography.Roles[self:_Role()]
    local line = typography:LineHeight(role)

    local height = line
    if self.Wrap and self._Width > 0 and self.Text ~= "" then
        local measured = typography:Measure(self.Text, role, self._Width).Y
        height = math.max(line, math.ceil(measured) + Metrics.Label.LineGap)
    end
    Element.SetHeight(self, height)
end

function Label._OnWidth(self: Label, width: number)
    if self._Width == width then
        return
    end
    self._Width = width
    if self.Wrap then
        self:_Measure()
    end
end

--// Public API ---------------------------------------------------------------

function Label.SetText(self: Label, text: string): Label
    assert(not self.Destroyed, "Label is destroyed")
    local value = tostring(text)
    self.Text = value
    self.Instance.Text = value
    self:_Measure()
    return self
end

function Label.SetWrap(self: Label, wrap: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    local flag = wrap == true
    if self.Wrap == flag then
        return self
    end
    self.Wrap = flag
    self.Instance.TextWrapped = flag
    self.Instance.TextTruncate = if flag then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd
    self:_Measure()
    return self
end

-- A label has no interaction, so "disabled" here means exactly one thing: it is
-- drawn in the disabled text colour. It exists because a label describing a
-- disabled control should be able to dim along with it.
function Label.SetDisabled(self: Label, disabled: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    self.Host.Typography:SetRole(self.Instance, self:_Role(), self.Resources)
    return self
end

-- Moves the label between the primary and secondary text levels. Like
-- SetDisabled this is a rebinding, not a repaint: the role changes, and the
-- registry supplies whatever colour that role resolves to under the current
-- theme. Geometry cannot move, because the two roles share a size and a weight.
function Label.SetSecondary(self: Label, secondary: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    local flag = secondary == true
    if self.Secondary == flag then
        return self
    end
    self.Secondary = flag
    self.Host.Typography:SetRole(self.Instance, self:_Role(), self.Resources)
    return self
end

function Label.SetVisible(self: Label, visible: boolean): Label
    assert(not self.Destroyed, "Label is destroyed")
    Element.ApplyVisible(self, visible)
    return self
end

function Label.Destroy(self: Label)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    Element.Release(self)
    self.Resources:Destroy()
end

return Label
end)()

local Module16 = (function()
--!strict
local Types = Module3
local Metrics = Module8
local Materials = Module11
local Element = Module14
local Controls = Module13

local Divider = {}
Divider.__index = Divider

export type Divider = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Text: string,
        Visible: boolean,

        Holder: Frame,
        Rule: Frame,
        Instance: TextLabel?,
        LayoutHeight: number,

        _Width: number,
    },
    Divider
))

export type Options = { Text: string?, Visible: boolean?, LayoutOrder: number? }

function Divider.Normalise(options: (string | Options)?): Options
    if type(options) == "string" then
        return { Text = options }
    end
    return if options then table.clone(options :: Options) else {}
end

function Divider.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Divider
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)
    local geometry = Metrics.Divider

    local holder = library:Create("Frame", {
        Name = "Divider",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = config.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
    }, resources) :: Frame

    local self: Divider = setmetatable({
        Type = "Divider",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Text = config.Text or "",
        Visible = config.Visible ~= false,

        Holder = holder,
        Rule = nil :: any,
        Instance = nil,
        LayoutHeight = 0,

        _Width = 0,
    }, Divider)

    -- Anchored to the right edge: a caption grows from the left, and the rule
    -- gives up exactly the width the caption took.
    local rule = library:Create("Frame", {
        Name = "Rule",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, geometry.Thickness),
        ZIndex = Materials.Z.Edge,
        Parent = holder,
    }, resources) :: Frame
    library:RegisterProperty(rule, { BackgroundColor3 = "Border.Divider" }, resources)
    self.Rule = rule

    if self.Text ~= "" then
        self.Instance = host.Typography:Create("DividerText", {
            Name = "Caption",
            Text = self.Text,
            Size = UDim2.new(0, 0, 1, 0),
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = Materials.Z.Text,
            Parent = holder,
        }, resources)
    end

    holder.Visible = self.Visible
    holder.Parent = parent
    self:_Layout()

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

-- A captioned divider is a caption followed by the rule filling what is left.
-- The caption's width is measured, not estimated, so the rule starts exactly
-- where the text ends however long the text is.
function Divider._Layout(self: Divider)
    if self.Destroyed then
        return
    end
    local typography = self.Host.Typography
    local geometry = Metrics.Divider
    local caption = self.Instance

    if not caption then
        self.Rule.Size = UDim2.new(1, 0, 0, geometry.Thickness)
        Element.SetHeight(self, geometry.Thickness + geometry.MarginTop + geometry.MarginBottom)
        return
    end

    local role = typography.Roles.DividerText
    local line = typography:LineHeight(role)
    local available = math.max(0, self._Width - geometry.TextGap)
    local width = math.ceil(typography:Measure(self.Text, role).X)
    if available > 0 then
        width = math.min(width, available)
    end

    caption.Size = UDim2.new(0, width, 1, 0)
    self.Rule.Size = UDim2.new(1, -(width + geometry.TextGap), 0, geometry.Thickness)
    Element.SetHeight(self, line + geometry.MarginTop + geometry.MarginBottom)
end

function Divider._OnWidth(self: Divider, width: number)
    if self._Width == width then
        return
    end
    self._Width = width
    if self.Instance then
        self:_Layout()
    end
end

function Divider.SetText(self: Divider, text: string): Divider
    assert(not self.Destroyed, "Divider is destroyed")
    -- A divider created without a caption stays without one: building the label
    -- lazily would mean a second construction path for one rare case.
    local caption = self.Instance
    if caption then
        self.Text = tostring(text)
        caption.Text = self.Text
        self:_Layout()
    end
    return self
end

function Divider.SetVisible(self: Divider, visible: boolean): Divider
    assert(not self.Destroyed, "Divider is destroyed")
    Element.ApplyVisible(self, visible)
    return self
end

function Divider.Destroy(self: Divider)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    Element.Release(self)
    self.Resources:Destroy()
end

return Divider
end)()

local Module17 = (function()
--!strict
local Types = Module3
local Metrics = Module8
local Materials = Module11
local Element = Module14
local Controls = Module13

local Button = {}
Button.__index = Button

local Sub = {}
Sub.__index = Sub

-- The interactive part of a button: a surface, a label, and the state that
-- decides how they look. A row holds one or two of these.
type Face = {
    Owner: any,
    Name: string,
    Scope: Types.Scope,

    Text: string,
    ConfirmText: string,
    Disabled: boolean,
    Risky: boolean,
    DoubleClick: boolean,

    Hovered: boolean,
    Pressed: boolean,
    Armed: boolean,

    Surface: Materials.Surface,
    Label: TextLabel,
    Glyph: Controls.Chevron?,
    Changed: Controls.Signal,
    _Disarm: Types.Cleanup?,
}

export type Options = {
    -- When set, the button becomes an action row: this label on the left, and a
    -- compact glyph trigger on the right, rather than a full-width bar.
    Label: string?,
    Text: string?,
    Callback: (() -> ())?,
    Disabled: boolean?,
    Visible: boolean?,
    Risky: boolean?,
    DoubleClick: boolean?,
    ConfirmText: string?,
    LayoutOrder: number?,
    Id: string?,
}

export type SubButton = typeof(setmetatable({} :: { Owner: any, Face: Face }, Sub))

export type Button = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Visible: boolean,
        Holder: Frame,
        Body: Frame,
        Action: boolean,
        Row: Controls.Row?,
        LayoutHeight: number,

        Main: Face,
        Sub: SubButton?,

        _Width: number,
    },
    Button
))

--// Faces --------------------------------------------------------------------

local function faceRole(face: Face): string
    if face.Disabled then
        return "ButtonDisabled"
    end
    return if face.Risky then "ButtonRisky" else "Button"
end

local function faceRefresh(face: Face, duration: number)
    local button = face.Owner :: Button
    if button.Destroyed then
        return
    end
    local context = button.Host.Context

    -- A disabled button has no hover and no pressed state at all: showing one
    -- would promise an interaction that is not going to happen.
    local fill = if face.Disabled
        then "Disabled"
        elseif face.Pressed then "Pressed"
        elseif face.Hovered then "Hover"
        else "Rest"
    Materials.ApplyState(context, face.Surface, fill, duration)

    local border = if face.Disabled
        then "Disabled"
        elseif face.Risky and (face.Hovered or face.Armed) then "Risky"
        elseif face.Hovered or face.Pressed then "Hover"
        else "Rest"
    Materials.ApplyBorderState(context, face.Surface, border)

    button.Host.Typography:SetRole(face.Label, faceRole(face), face.Scope)
end

local function faceDisarm(face: Face, duration: number)
    local dispose = face._Disarm
    face._Disarm = nil
    if dispose then
        dispose()
    end
    if not face.Armed then
        return
    end
    face.Armed = false
    face.Label.Text = face.Text
    faceRefresh(face, duration)
end

-- Arming is bounded in time. A button that was clicked once a minute ago is not
-- half-confirmed; it has forgotten, and says so by returning to its own text.
local function faceArm(face: Face)
    local button = face.Owner :: Button
    local library = button.Host.Library
    faceDisarm(face, 0)
    face.Armed = true
    face.Label.Text = face.ConfirmText
    faceRefresh(face, Metrics.Motion.Hover)

    local thread = task.delay(Metrics.Button.DoubleClickWindow, function()
        if not button.Destroyed and not face.Scope.Destroyed then
            faceDisarm(face, Metrics.Motion.Hover)
        end
    end)
    face._Disarm = library:TrackTask(thread, face.Scope)
end

-- The one activation path. Everything that can press a button ends up here.
local function faceActivate(face: Face)
    local button = face.Owner :: Button
    if button.Destroyed or face.Disabled or not button.Visible then
        return
    end
    if face.DoubleClick and not face.Armed then
        faceArm(face)
        return
    end
    faceDisarm(face, 0)
    -- The button finishes its own state transition before the callback runs, so
    -- a callback that throws cannot leave it armed, pressed or half-hovered.
    face.Changed:Fire()
end

local function createFace(
    button: Button,
    params: {
        Name: string,
        Position: UDim2,
        Size: UDim2,
        Options: Options,
    }
): Face
    local host = button.Host
    local library = host.Library
    local scope = library:CreateScope(button.Resources)
    local config = params.Options

    local action = button.Action
    local surface = Materials.CreateSurface(host.Context, {
        Name = params.Name,
        Kind = if action then "Action" else "Button",
        Parent = button.Body,
        Scope = scope,
        Position = params.Position,
        Size = params.Size,
        Radius = Metrics.Radius.Control,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    surface.Instance.Active = true

    local face: Face = {
        Owner = button,
        Name = params.Name,
        Scope = scope,

        Text = config.Text or "",
        ConfirmText = config.ConfirmText or "Are you sure?",
        Disabled = config.Disabled == true,
        Risky = config.Risky == true,
        DoubleClick = config.DoubleClick == true,

        Hovered = false,
        Pressed = false,
        Armed = false,

        Surface = surface,
        Label = nil :: any,
        Glyph = nil,
        Changed = Controls.NewSignal(library, scope),
        _Disarm = nil,
    }

    -- Centred on both axes, at the shared control text size. A button's label is
    -- not a different typographic class from a dropdown's value.
    face.Label = host.Typography:Create("Button", {
        Name = "Text",
        Text = face.Text,
        Position = UDim2.fromOffset(Metrics.Button.HorizontalPadding, 0),
        Size = UDim2.new(1, -Metrics.Button.HorizontalPadding * 2, 1, 0),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Visible = not action,
        ZIndex = Materials.Z.Text,
        Parent = surface.Instance,
    }, scope)

    -- An action trigger carries a glyph rather than a word: it is 34 wide, and
    -- the row's label to its left already says what it does.
    if action then
        face.Glyph = Controls.CreateChevron(host, {
            Parent = surface.Instance,
            Scope = scope,
            Centred = true,
            Rotation = -90,
            Token = "Text.Primary",
        })
    end

    if config.Callback then
        face.Changed:Connect(config.Callback)
    end

    local frame = surface.Instance
    library:Connect(frame.MouseEnter, function()
        if face.Disabled then
            return
        end
        face.Hovered = true
        faceRefresh(face, Metrics.Motion.Hover)
    end, scope)

    -- Leaving cancels the press. A pointer released outside the control is not
    -- an activation, and the control must not be left looking held down.
    library:Connect(frame.MouseLeave, function()
        face.Hovered = false
        face.Pressed = false
        faceRefresh(face, Metrics.Motion.Hover)
    end, scope)

    library:Connect(frame.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if face.Disabled or not button.Visible then
            return
        end
        -- Pressing a button is an interaction handover like any other: an open
        -- popup closes and a focused field commits before anything happens.
        host:BeginInteraction(false, frame)
        face.Pressed = true
        faceRefresh(face, 0)
    end, scope)

    library:Connect(frame.InputEnded, function(input: InputObject)
        if not library:IsPrimaryPointer(input) then
            return
        end
        local wasPressed = face.Pressed
        face.Pressed = false
        faceRefresh(face, Metrics.Motion.Hover)
        if wasPressed then
            faceActivate(face)
        end
    end, scope)

    faceRefresh(face, 0)
    return face
end

local function faceSetDisabled(face: Face, disabled: boolean)
    local flag = disabled == true
    if face.Disabled == flag then
        return
    end
    face.Disabled = flag
    if flag then
        face.Hovered = false
        face.Pressed = false
        faceDisarm(face, 0)
    end
    faceRefresh(face, Metrics.Motion.Hover)
end

local function faceSetText(face: Face, text: string)
    face.Text = tostring(text)
    -- An armed button is showing its confirmation prompt; the new text becomes
    -- visible when it disarms rather than overwriting the prompt mid-decision.
    if not face.Armed then
        face.Label.Text = face.Text
    end
end

--// Construction -------------------------------------------------------------

function Button.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Button
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    -- Two shapes, one object. Without a label the button is a full-width bar in
    -- its own frame; with one it is a labelled row whose body is a compact
    -- trigger at the right. The faces below are built into Body either way, so
    -- nothing downstream has to know which shape it got.
    local action = config.Label ~= nil and config.Label ~= ""
    local geometry = Metrics.Button
    local holder: Frame
    local body: Frame
    local row: Controls.Row? = nil
    local layoutHeight: number

    if action then
        local created = Controls.CreateRow(host, {
            Name = "Action",
            Text = config.Label,
            Scope = resources,
            LayoutOrder = config.LayoutOrder,
            BodyHeight = geometry.ActionHeight,
            BodyWidth = geometry.ActionWidth,
        })
        row = created
        holder = created.Frame
        layoutHeight = created.Height
        body = library:Create("Frame", {
            Name = "Body",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, 0, 0, created.BodyOffset),
            Size = UDim2.fromOffset(geometry.ActionWidth, geometry.ActionHeight),
            ZIndex = Materials.Z.Structure,
            ClipsDescendants = false,
            Parent = holder,
        }, resources) :: Frame
    else
        holder = library:Create("Frame", {
            Name = "Button",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, geometry.Height),
            LayoutOrder = config.LayoutOrder or 1,
            ZIndex = Materials.Z.Structure,
            ClipsDescendants = false,
        }, resources) :: Frame
        body = holder
        layoutHeight = geometry.Height
    end

    local self: Button = setmetatable({
        Type = "Button",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Visible = config.Visible ~= false,
        Holder = holder,
        Body = body,
        Action = action,
        Row = row,
        LayoutHeight = layoutHeight,

        Main = nil :: any,
        Sub = nil,

        _Width = 0,
    }, Button)

    -- A lone button fills the row: its bounds are the groupbox's content bounds,
    -- so it aligns with every field above and below it without arithmetic.
    self.Main = createFace(self, {
        Name = "Main",
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Options = config,
    })

    holder.Visible = self.Visible
    holder.Parent = parent

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

--// Row layout ---------------------------------------------------------------

-- Two faces split the row at whole pixels, with the remainder given to the main
-- button, so the pair always spans exactly the available width: no 1px seam on
-- odd widths, and no face a pixel wider than its partner by accident.
function Button._Layout(self: Button)
    if self.Destroyed then
        return
    end
    local sub = self.Sub
    if not sub or not sub.Face.Surface.Instance.Visible then
        self.Main.Surface.Instance.Size = UDim2.new(1, 0, 1, 0)
        return
    end

    local gap = Metrics.Button.SubGap
    local width = self._Width
    if width <= 0 then
        -- Width is not known yet (the groupbox publishes it on its first
        -- resize). A scale split is correct to within a pixel until then.
        self.Main.Surface.Instance.Size = UDim2.new(0.5, -gap / 2, 1, 0)
        sub.Face.Surface.Instance.Size = UDim2.new(0.5, -gap / 2, 1, 0)
        return
    end

    local usable = math.max(0, width - gap)
    local subWidth = math.floor(usable / 2)
    local mainWidth = usable - subWidth
    self.Main.Surface.Instance.Size = UDim2.new(0, mainWidth, 1, 0)
    sub.Face.Surface.Instance.Size = UDim2.new(0, subWidth, 1, 0)
end

function Button._OnWidth(self: Button, width: number)
    if self._Width == width then
        return
    end
    self._Width = width
    self:_Layout()
end

--// Public API ---------------------------------------------------------------

function Button.AddButton(self: Button, options: Options?): SubButton
    assert(not self.Destroyed, "Button is destroyed")
    assert(self.Sub == nil, "A button can carry one sub-button")
    local config: Options = if options then table.clone(options) else {}

    local face = createFace(self, {
        Name = "Sub",
        Position = UDim2.new(1, 0, 0, 0),
        Size = UDim2.new(0.5, -Metrics.Button.SubGap / 2, 1, 0),
        Options = config,
    })
    face.Surface.Instance.AnchorPoint = Vector2.new(1, 0)

    local sub: SubButton = setmetatable({ Owner = self, Face = face }, Sub)
    self.Sub = sub
    self:_Layout()
    return sub
end

function Button.SetText(self: Button, text: string): Button
    assert(not self.Destroyed, "Button is destroyed")
    faceSetText(self.Main, text)
    return self
end

function Button.SetDisabled(self: Button, disabled: boolean): Button
    assert(not self.Destroyed, "Button is destroyed")
    faceSetDisabled(self.Main, disabled)
    return self
end

function Button.SetVisible(self: Button, visible: boolean): Button
    assert(not self.Destroyed, "Button is destroyed")
    Element.ApplyVisible(self, visible)
    return self
end

-- Programmatic activation takes exactly the path a click takes, including the
-- disabled check and the double-click state machine.
function Button.Press(self: Button): Button
    assert(not self.Destroyed, "Button is destroyed")
    faceActivate(self.Main)
    return self
end

function Button.OnClick(self: Button, callback: () -> ()): Types.Cleanup
    assert(not self.Destroyed, "Button is destroyed")
    return self.Main.Changed:Connect(callback)
end

-- Hiding, collapsing or destroying the button gives up everything transient it
-- was holding: the hover it will never be told it lost, and any armed prompt.
function Button.Deactivate(self: Button)
    local faces: { Face } = { self.Main }
    local sub = self.Sub
    if sub then
        table.insert(faces, sub.Face)
    end
    for _, face in faces do
        face.Hovered = false
        face.Pressed = false
        faceDisarm(face, 0)
        if not self.Destroyed then
            faceRefresh(face, 0)
        end
    end
end

function Button.Destroy(self: Button)
    if self.Destroyed then
        return
    end
    self:Deactivate()
    self.Destroyed = true
    self.Sub = nil
    Element.Release(self)
    self.Resources:Destroy()
end

--// Sub-buttons --------------------------------------------------------------
-- The same control, sharing the row. It is not an element in its own right: the
-- groupbox owns the row, and the row owns both faces.

function Sub.SetText(self: SubButton, text: string): SubButton
    faceSetText(self.Face, text)
    return self
end

function Sub.SetDisabled(self: SubButton, disabled: boolean): SubButton
    faceSetDisabled(self.Face, disabled)
    return self
end

function Sub.SetVisible(self: SubButton, visible: boolean): SubButton
    local flag = visible ~= false
    self.Face.Surface.Instance.Visible = flag
    if not flag then
        self.Face.Hovered = false
        self.Face.Pressed = false
        faceDisarm(self.Face, 0)
    end -- The main button reclaims the whole row rather than leaving a gap where -- the sub-button used to be.
    (self.Owner :: Button):_Layout()
    return self
end

function Sub.Press(self: SubButton): SubButton
    faceActivate(self.Face)
    return self
end

function Sub.OnClick(self: SubButton, callback: () -> ()): Types.Cleanup
    return self.Face.Changed:Connect(callback)
end

function Sub.Destroy(self: SubButton)
    local owner = self.Owner :: Button
    if owner.Sub == self then
        owner.Sub = nil
    end
    faceDisarm(self.Face, 0)
    self.Face.Scope:Destroy()
    if not owner.Destroyed then
        owner:_Layout()
    end
end

return Button
end)()

local Module18 = (function()
--!strict
local Types = Module3
local Theme = Module2
local Metrics = Module8
local Materials = Module11
local Element = Module14
local Controls = Module13
local Popup = Module12

local Dropdown = {}
Dropdown.__index = Dropdown

type Item = {
    Value: string,
    Surface: Materials.Surface,
    Label: TextLabel,
    Marker: Frame,
    Scope: Types.Scope,
    Hovered: boolean,
    Disabled: boolean,
    Visible: boolean,
}

export type Dropdown = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Holder: Frame,
        LayoutHeight: number,

        Text: string,
        Placeholder: string,
        Values: { string },
        DisabledValues: { [string]: boolean },
        Value: any,

        Multi: boolean,
        AllowNull: boolean,
        Searchable: boolean,
        MaxDisplay: number,

        IsOpen: boolean,
        Disabled: boolean,
        Visible: boolean,
        Hovered: boolean,

        Row: Controls.Row,
        Trigger: Materials.Surface,
        ValueLabel: TextLabel,
        Chevron: Controls.Chevron,

        Changed: Controls.Signal,

        _Selected: { [string]: boolean },
        _Items: { Item },
        _ItemScope: Types.Scope?,
        _Popup: Materials.Surface?,
        _Scroll: ScrollingFrame?,
        _List: Frame?,
        _Search: TextBox?,
        _Empty: TextLabel?,
        _Filter: string,
        _VisibleCount: number,
        _Dirty: boolean,
        _OpenScope: Types.Scope?,
    },
    Dropdown
))

export type Options = {
    Width: number?,
    Text: string?,
    Placeholder: string?,
    Values: { string }?,
    Default: any?,
    DisabledValues: { [string]: boolean }?,
    Multi: boolean?,
    AllowNull: boolean?,
    Searchable: boolean?,
    MaxDisplay: number?,
    Disabled: boolean?,
    Visible: boolean?,
    LayoutOrder: number?,
    Callback: ((any) -> ())?,
}

--// Helpers ------------------------------------------------------------------

local function copyValues(values: { string }?): { string }
    local result: { string } = {}
    if values then
        for _, value in values do
            if type(value) == "string" then
                table.insert(result, value)
            end
        end
    end
    return result
end

local function contains(values: { string }, value: string): boolean
    return table.find(values, value) ~= nil
end

--// Construction -------------------------------------------------------------

-- `scope` is the owning container's scope. The trigger belongs to the groupbox;
-- the popup does not, and never will. See _EnsurePopup: the popup is built in
-- the library's overlay layer, and the groupbox owns the dropdown object rather
-- than the popup's instances.
function Dropdown.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Dropdown
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    local self: Dropdown = setmetatable({
        Type = "Dropdown",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Holder = nil :: any,
        LayoutHeight = 0,

        Text = config.Text or "",
        Placeholder = config.Placeholder or "None",
        Values = copyValues(config.Values),
        DisabledValues = if config.DisabledValues then table.clone(config.DisabledValues) else {},
        Value = if config.Multi then {} else nil,

        Multi = config.Multi == true,
        AllowNull = config.AllowNull == true,
        Searchable = config.Searchable == true,
        MaxDisplay = math.max(1, config.MaxDisplay or 2),

        IsOpen = false,
        Disabled = config.Disabled == true,
        Visible = config.Visible ~= false,
        Hovered = false,

        Row = nil :: any,
        Trigger = nil :: any,
        ValueLabel = nil :: any,
        Chevron = nil :: any,

        Changed = Controls.NewSignal(library, resources),

        _Selected = {},
        _Items = {},
        _ItemScope = nil,
        _Popup = nil,
        _Scroll = nil,
        _List = nil,
        _Search = nil,
        _Empty = nil,
        _Filter = "",
        _VisibleCount = 0,
        _Dirty = true,
        _OpenScope = nil,
    }, Dropdown)

    self:_Build(parent, config)
    -- The trigger row is the dropdown's entire flow footprint. Opening the
    -- popup does not change it, because the popup is not in the flow at all.
    self.Holder = self.Row.Frame
    self.LayoutHeight = self.Row.Height

    if config.Callback then
        self.Changed:Connect(config.Callback)
    end

    -- Default selection is applied through the same validation path as any later
    -- assignment, so an invalid default cannot create an impossible state.
    if config.Default ~= nil then
        self:_Assign(config.Default, true)
    elseif not self.Multi and not self.AllowNull then
        self:_Assign(self:_FirstSelectable(), false)
    end

    self:_UpdateDisplay()
    self:_UpdateVisual(0)
    self.Row.Frame.Visible = self.Visible

    -- Runs before the instances are destroyed. Destroy() does this explicitly,
    -- but a scope teardown (Unload, a destroyed tab, a destroyed groupbox) does
    -- not go through Destroy, and an open dropdown must not leave its popup
    -- registered in OpenedFrames or owned by the popup manager either way.
    resources:Add(function()
        self.Destroyed = true
        local popup = self._Popup
        if popup then
            library.OpenedFrames[popup.Instance] = nil
        end
        self.IsOpen = false
        host.Popups:Release(self :: any)
    end)

    return self
end

function Dropdown._Build(self: Dropdown, parent: Instance, config: Options)
    local host = self.Host
    local scope = self.Resources

    local row = Controls.CreateRow(host, {
        Name = "Dropdown",
        Text = if self.Text ~= "" then self.Text else nil,
        Parent = parent,
        Scope = scope,
        LayoutOrder = config.LayoutOrder,
        BodyHeight = Metrics.Dropdown.Height,
        BodyWidth = if self.Text ~= "" then (config.Width or Metrics.Dropdown.FieldWidth) else nil,
    })
    self.Row = row

    -- The field is a recessed plate at the right of the row when the dropdown
    -- carries a label, and the full row when it does not.
    local labelled = self.Text ~= ""
    local trigger = Materials.CreateSurface(host.Context, {
        Name = "Trigger",
        Kind = "Field",
        Parent = row.Frame,
        Scope = scope,
        AnchorPoint = if labelled then Vector2.new(1, 0) else Vector2.zero,
        Position = if labelled then UDim2.new(1, 0, 0, row.BodyOffset) else UDim2.fromOffset(0, row.BodyOffset),
        Size = if labelled
            then UDim2.fromOffset(row.BodyWidth, Metrics.Dropdown.Height)
            else UDim2.new(1, 0, 0, Metrics.Dropdown.Height),
        Radius = Metrics.Radius.Control,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    trigger.Instance.Active = true
    self.Trigger = trigger

    -- The value label's right edge stops short of the chevron's reserved column,
    -- so a long value truncates instead of running under the indicator.
    local chevronColumn = Metrics.Dropdown.ChevronPadding + Metrics.Dropdown.ChevronSize + 6
    self.ValueLabel = host.Typography:Create("ControlValue", {
        Name = "Value",
        Text = "",
        Position = UDim2.fromOffset(Metrics.Dropdown.HorizontalPadding, 0),
        Size = UDim2.new(1, -(Metrics.Dropdown.HorizontalPadding + chevronColumn), 1, 0),
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = trigger.Instance,
    }, scope)

    self.Chevron = Controls.CreateChevron(host, {
        Parent = trigger.Instance,
        Scope = scope,
    })

    self:_BindTrigger()
end

function Dropdown._BindTrigger(self: Dropdown)
    local library = self.Host.Library
    local scope = self.Resources
    local frame = self.Trigger.Instance

    library:Connect(frame.MouseEnter, function()
        self.Hovered = true
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)

    library:Connect(frame.MouseLeave, function()
        self.Hovered = false
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)

    library:Connect(frame.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if self.Disabled or not self.Visible then
            return
        end
        -- Read the open state before the handover: BeginInteraction closes the
        -- active popup, which may be this one, and a toggle must not reopen it.
        local wasOpen = self.IsOpen
        self.Host:BeginInteraction()
        if not wasOpen then
            self:Open()
        end
    end, scope)
end

--// Selection ----------------------------------------------------------------

function Dropdown._IsValueDisabled(self: Dropdown, value: string): boolean
    return self.DisabledValues[value] == true
end

function Dropdown._FirstSelectable(self: Dropdown): string?
    for _, value in self.Values do
        if not self:_IsValueDisabled(value) then
            return value
        end
    end
    return nil
end

function Dropdown.IsSelected(self: Dropdown, value: string): boolean
    return self._Selected[value] == true
end

-- Rebuilds the ordered public Value from the selection set. Order follows Values,
-- so the array is deterministic no matter what order items were clicked in.
function Dropdown._SyncValue(self: Dropdown)
    if not self.Multi then
        return
    end
    local ordered: { string } = {}
    for _, value in self.Values do
        if self._Selected[value] then
            table.insert(ordered, value)
        end
    end
    self.Value = ordered
end

local function sameSelection(a: { [string]: boolean }, b: { [string]: boolean }): boolean
    for key, value in a do
        if value and not b[key] then
            return false
        end
    end
    for key, value in b do
        if value and not a[key] then
            return false
        end
    end
    return true
end

-- The one write path for selection. Returns true when the selection changed.
-- `report` controls whether a rejected assignment is warned about; internal
-- revalidation after SetValues is expected to drop values and stays quiet.
function Dropdown._Assign(self: Dropdown, value: any, report: boolean): boolean
    local library = self.Host.Library
    local previous = table.clone(self._Selected)
    local proposed: { [string]: boolean } = {}

    if self.Multi then
        if value == nil then
            -- An empty multi selection is always representable.
        elseif type(value) == "table" then
            local source: { [string]: boolean } = {}
            -- Accept both an array of values and a set of value -> boolean.
            local list = value :: { any }
            if #list > 0 then
                for _, entry in list do
                    if type(entry) == "string" then
                        source[entry] = true
                    end
                end
            end
            for key, flag in value :: { [string]: any } do
                if type(key) == "string" and flag == true then
                    source[key] = true
                end
            end
            for entry in source do
                if contains(self.Values, entry) and not self:_IsValueDisabled(entry) then
                    proposed[entry] = true
                elseif report then
                    library:_Report("Dropdown: rejected value " .. entry)
                end
            end
        else
            if report then
                library:_Report("Dropdown: multi-select value must be a table or nil")
            end
            return false
        end
    else
        if value == nil then
            if not self.AllowNull then
                if report then
                    library:_Report("Dropdown: cannot clear a dropdown without AllowNull")
                end
                return false
            end
        elseif type(value) ~= "string" then
            if report then
                library:_Report("Dropdown: value must be a string or nil")
            end
            return false
        elseif not contains(self.Values, value) or self:_IsValueDisabled(value) then
            if report then
                library:_Report("Dropdown: rejected value " .. value)
            end
            return false
        else
            proposed[value] = true
        end
    end

    if sameSelection(previous, proposed) then
        return false
    end

    self._Selected = proposed
    if self.Multi then
        self:_SyncValue()
    else
        local selected: string? = nil
        for entry in proposed do
            selected = entry
        end
        self.Value = selected
    end
    return true
end

-- Applies a selection change and publishes it. Display, item visuals and the
-- callback all hang off this one call, so no path can update two of the three.
function Dropdown._Commit(self: Dropdown, value: any, report: boolean): boolean
    if not self:_Assign(value, report) then
        return false
    end
    self:_UpdateDisplay()
    self:_UpdateItems(Metrics.Motion.Hover)
    self.Changed:Fire(self.Value)
    return true
end

--// Display ------------------------------------------------------------------

-- Deterministic trigger text. A long value list can never grow the trigger: past
-- MaxDisplay entries the tail collapses into a count.
function Dropdown._Display(self: Dropdown): (string, boolean)
    if self.Multi then
        local selected = self.Value :: { string }
        local count = #selected
        if count == 0 then
            return self.Placeholder, true
        end
        if count <= self.MaxDisplay then
            return table.concat(selected, ", "), false
        end
        local shown = {}
        for index = 1, self.MaxDisplay do
            table.insert(shown, selected[index])
        end
        return table.concat(shown, ", ") .. ", +" .. tostring(count - self.MaxDisplay), false
    end

    local value = self.Value :: string?
    if value == nil or value == "" then
        return self.Placeholder, true
    end
    return value, false
end

function Dropdown._UpdateDisplay(self: Dropdown)
    local text, isPlaceholder = self:_Display()
    self.ValueLabel.Text = text
    local role = if self.Disabled
        then "ControlValueDisabled"
        elseif isPlaceholder then "ControlValueMuted"
        else "ControlValue"
    self.Host.Typography:SetRole(self.ValueLabel, role, self.Resources)
end

--// Visual state -------------------------------------------------------------

function Dropdown._UpdateVisual(self: Dropdown, duration: number)
    if self.Destroyed then
        return
    end
    local context = self.Host.Context
    local trigger = self.Trigger

    local fill = if self.Disabled
        then "Disabled"
        elseif self.IsOpen then "Active"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyState(context, trigger, fill, duration)

    local border = if self.Disabled
        then "Disabled"
        elseif self.IsOpen then "Open"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyBorderState(context, trigger, border)

    Controls.SetChevronToken(
        self.Host,
        self.Chevron,
        if self.Disabled then "Text.Disabled" elseif self.IsOpen then "Text.Primary" else "Text.Muted",
        self.Resources
    )
    Materials.Animate(
        context.Animator,
        self.Chevron.Frame,
        { Rotation = if self.IsOpen then 180 else 0 },
        if duration > 0 then Metrics.Motion.Chevron else 0
    )
end

--// Items --------------------------------------------------------------------

function Dropdown._ItemState(self: Dropdown, item: Item): string
    if item.Disabled then
        return "Disabled"
    end
    if item.Hovered then
        return "Hover"
    end
    if self:IsSelected(item.Value) then
        return "Selected"
    end
    return "Rest"
end

function Dropdown._UpdateItems(self: Dropdown, duration: number)
    for _, item in self._Items do
        local selected = self:IsSelected(item.Value)
        Materials.ApplyState(self.Host.Context, item.Surface, self:_ItemState(item), duration)
        Materials.Animate(
            self.Host.Context.Animator,
            item.Marker,
            { BackgroundTransparency = if selected then 0 else 1 },
            duration
        )
        local role = if item.Disabled then "ItemDisabled" elseif selected then "ItemSelected" else "Item"
        self.Host.Typography:SetRole(item.Label, role, item.Scope)
    end
end

function Dropdown._CreateItem(self: Dropdown, value: string, index: number, parent: Instance, scope: Types.Scope): Item
    local host = self.Host
    local library = host.Library
    local config = Metrics.Dropdown

    local surface = Materials.CreateSurface(host.Context, {
        Name = "Item",
        Kind = "Interactive",
        Parent = parent,
        Scope = scope,
        Size = UDim2.new(1, 0, 0, config.ItemHeight),
        Radius = Metrics.Radius.Small,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    surface.Instance.LayoutOrder = index
    surface.Instance.Active = true

    -- The marker sits in its own reserved column, left of where text begins, and
    -- is only ever faded. Selecting a row cannot move its label.
    local marker = library:Create("Frame", {
        Name = "Marker",
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, config.MarkerInset, 0.5, 0),
        Size = UDim2.fromOffset(config.MarkerWidth, config.ItemHeight - config.MarkerVerticalInset * 2),
        ZIndex = Materials.Z.Edge,
        Parent = surface.Instance,
    }, scope) :: Frame
    library:RegisterProperty(marker, { BackgroundColor3 = "Accent.Base" }, scope)

    local label = host.Typography:Create("Item", {
        Name = "Label",
        Text = value,
        Position = UDim2.fromOffset(config.ItemPaddingX, 0),
        Size = UDim2.new(1, -config.ItemPaddingX * 2, 1, 0),
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = surface.Instance,
    }, scope)

    local item: Item = {
        Value = value,
        Surface = surface,
        Label = label,
        Marker = marker,
        Scope = scope,
        Hovered = false,
        Disabled = self:_IsValueDisabled(value),
        Visible = true,
    }

    local frame = surface.Instance
    library:Connect(frame.MouseEnter, function()
        item.Hovered = true
        Materials.ApplyState(host.Context, surface, self:_ItemState(item), Metrics.Motion.Hover)
    end, scope)
    library:Connect(frame.MouseLeave, function()
        item.Hovered = false
        Materials.ApplyState(host.Context, surface, self:_ItemState(item), Metrics.Motion.Hover)
    end, scope)
    library:Connect(frame.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        self:_Choose(item)
    end, scope)

    return item
end

-- Row selection. The popup's own hit test already told the outside-click handler
-- that this click was inside, so nothing can have closed the popup underneath
-- this call.
function Dropdown._Choose(self: Dropdown, item: Item)
    if self.Destroyed or self.Disabled or item.Disabled then
        return
    end
    if self.Multi then
        local selection = table.clone(self._Selected)
        if selection[item.Value] then
            selection[item.Value] = nil
        else
            selection[item.Value] = true
        end
        self:_Commit(selection, false)
        -- Multi-select stays open: a selection is one of several.
        return
    end

    if self:IsSelected(item.Value) and self.AllowNull then
        self:_Commit(nil, false)
    else
        self:_Commit(item.Value, false)
    end
    self:Close()
end

-- One item instance per value, built once per value set. Filtering toggles
-- Visible on these rows rather than rebuilding them, so typing in the search
-- field never reconstructs the control tree.
function Dropdown._RebuildItems(self: Dropdown)
    local list = self._List
    if not list then
        return
    end

    local previous = self._ItemScope
    self._ItemScope = nil
    table.clear(self._Items)
    if previous then
        previous:Destroy()
    end

    local scope = self.Host.Library:CreateScope(self.Resources)
    self._ItemScope = scope
    scope:Add(function()
        if self._ItemScope == scope then
            self._ItemScope = nil
        end
    end)

    for index, value in self.Values do
        local itemScope = self.Host.Library:CreateScope(scope)
        local item = self:_CreateItem(value, index, list, itemScope)
        table.insert(self._Items, item)
    end

    self._Dirty = false
    self:_ApplyFilter()
    self:_UpdateItems(0)
end

--// Search and filtering -----------------------------------------------------

function Dropdown._Matches(self: Dropdown, value: string): boolean
    if self._Filter == "" then
        return true
    end
    return string.find(string.lower(value), self._Filter, 1, true) ~= nil
end

function Dropdown._ApplyFilter(self: Dropdown)
    local visible = 0
    for _, item in self._Items do
        local shown = self:_Matches(item.Value)
        item.Visible = shown
        item.Surface.Instance.Visible = shown
        if shown then
            visible += 1
        else
            -- A hidden row must not keep a hover state it can never clear.
            if item.Hovered then
                item.Hovered = false
                Materials.ApplyState(self.Host.Context, item.Surface, self:_ItemState(item), 0)
            end
        end
    end
    self._VisibleCount = visible

    local empty = self._Empty
    if empty then
        empty.Visible = visible == 0
        -- An empty value list and a search that matched nothing are different
        -- situations, and the popup says which one it is.
        empty.Text = if #self.Values == 0 then "No values" else "No results"
    end
    local scroll = self._Scroll
    if scroll then
        scroll.Visible = visible > 0
        scroll.CanvasSize = UDim2.fromOffset(0, Metrics:DropdownCanvasHeight(visible))
        if visible == 0 then
            scroll.CanvasPosition = Vector2.zero
        end
    end
end

--// Popup --------------------------------------------------------------------

function Dropdown._PopupHeight(self: Dropdown): number
    local count = if self._VisibleCount > 0 then self._VisibleCount else 1
    return Metrics:DropdownPopupHeight(count, self.Searchable)
end

function Dropdown._EnsurePopup(self: Dropdown): boolean
    if self._Popup then
        return true
    end
    local host = self.Host
    local library = host.Library
    local overlay = library.Overlay
    if not overlay then
        return false
    end
    local scope = self.Resources
    local config = Metrics.Dropdown

    local popup = Materials.CreateSurface(host.Context, {
        Name = "DropdownPopup",
        Kind = "Popup",
        Parent = overlay,
        Scope = scope,
        Size = UDim2.fromOffset(config.PopupMinWidth, config.ItemHeight),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
        Visible = false,
    })
    popup.Instance.Active = true
    self._Popup = popup

    local listTop = config.PopupPadding
    if self.Searchable then
        local search = Materials.CreateSurface(host.Context, {
            Name = "Search",
            Kind = "Control",
            Parent = popup.Instance,
            Scope = scope,
            Position = UDim2.fromOffset(config.PopupPadding, config.PopupPadding),
            Size = UDim2.new(1, -config.PopupPadding * 2, 0, config.SearchHeight),
            Radius = Metrics.Radius.Small,
            ZIndex = Materials.Z.Structure,
        })

        local box = host.Typography:CreateText("TextBox", "ControlValue", {
            Name = "Input",
            Text = "",
            PlaceholderText = "Search",
            PlaceholderToken = "Text.Placeholder",
            ClearTextOnFocus = false,
            Position = UDim2.fromOffset(config.ItemPaddingX, 0),
            Size = UDim2.new(1, -config.ItemPaddingX * 2, 1, 0),
            ZIndex = Materials.Z.Text,
            Parent = search.Instance,
        }, scope) :: TextBox
        self._Search = box

        library:Connect(box:GetPropertyChangedSignal("Text"), function()
            local filter = string.lower(box.Text)
            if filter == self._Filter then
                return
            end
            self._Filter = filter
            self:_ApplyFilter()
            self:_Reposition()
        end, scope)

        listTop += config.SearchHeight + config.SearchGap
    end

    local scroll = library:Create("ScrollingFrame", {
        Name = "Items",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(config.PopupPadding, listTop),
        Size = UDim2.new(1, -config.PopupPadding * 2, 1, -(listTop + config.PopupPadding)),
        CanvasSize = UDim2.fromOffset(0, 0),
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = config.ScrollBarThickness,
        ScrollBarImageTransparency = Theme.Alpha.ScrollBarPopup,
        VerticalScrollBarInset = Enum.ScrollBarInset.None,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ClipsDescendants = true,
        ZIndex = Materials.Z.Structure,
        Parent = popup.Instance,
    }, scope) :: ScrollingFrame
    library:RegisterProperty(scroll, { ScrollBarImageColor3 = "Overlay.ScrollBar" }, scope)
    self._Scroll = scroll
    self._List = scroll :: any

    library:Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, config.ItemSpacing),
        Parent = scroll,
    }, scope)

    self._Empty = host.Typography:Create("ItemEmpty", {
        Name = "Empty",
        Text = "No results",
        Position = UDim2.fromOffset(config.PopupPadding + config.ItemPaddingX, listTop),
        Size = UDim2.new(1, -(config.PopupPadding * 2 + config.ItemPaddingX * 2), 0, config.ItemHeight),
        Visible = false,
        ZIndex = Materials.Z.Text,
        Parent = popup.Instance,
    }, scope)

    self:_RebuildItems()
    return true
end

function Dropdown._Reposition(self: Dropdown)
    if self.Destroyed or not self.IsOpen then
        return
    end
    local popup = self._Popup
    if not popup then
        return
    end
    local trigger = self.Trigger.Instance
    -- A trigger on a hidden page is not somewhere a popup can stay attached to.
    if not Popup.IsDisplayed(trigger) then
        self:Close()
        return
    end
    local placement = Popup.Place(self.Host.Library, trigger, self:_PopupHeight())
    if not placement then
        self:Close()
        return
    end
    popup.Instance.Position = placement.Position
    popup.Instance.Size = placement.Size
end

--// Open / close -------------------------------------------------------------

function Dropdown.Open(self: Dropdown)
    if self.Destroyed or self.IsOpen or self.Disabled or not self.Visible then
        return
    end
    if not self:_EnsurePopup() then
        return
    end
    if self._Dirty then
        self:_RebuildItems()
    end
    local popup = self._Popup :: Materials.Surface
    local library = self.Host.Library

    self.IsOpen = true
    popup.Instance.Visible = true
    library.OpenedFrames[popup.Instance] = true

    -- Live geometry tracking: the popup follows its trigger through window drags,
    -- resizes, page scrolling and DPI changes instead of detaching from it.
    local scope = library:CreateScope(self.Resources)
    self._OpenScope = scope
    scope:Add(function()
        if self._OpenScope == scope then
            self._OpenScope = nil
        end
    end)

    local trigger = self.Trigger.Instance
    library:Connect(trigger:GetPropertyChangedSignal("AbsolutePosition"), function()
        self:_Reposition()
    end, scope)
    library:Connect(trigger:GetPropertyChangedSignal("AbsoluteSize"), function()
        self:_Reposition()
    end, scope)
    local gui = library.ScreenGui
    if gui then
        library:Connect(gui:GetPropertyChangedSignal("AbsoluteSize"), function()
            self:_Reposition()
        end, scope)
    end

    self:_Reposition()
    -- Placement can fail: a trigger on a page that is not displayed, or a
    -- viewport with no room for the popup, and _Reposition closes the dropdown
    -- rather than leaving it somewhere it cannot be seen. Claiming popup
    -- ownership after that would leave ActivePopup pointing at a closed
    -- control, which suppresses tooltips and misroutes the next outside click.
    if not self.IsOpen then
        return
    end
    self:_UpdateVisual(Metrics.Motion.Popup)
    self.Host.Popups:Open(self :: any)
end

function Dropdown.Close(self: Dropdown)
    if not self.IsOpen then
        return
    end
    self.IsOpen = false

    local scope = self._OpenScope
    self._OpenScope = nil
    if scope then
        scope:Destroy()
    end

    local popup = self._Popup
    if popup then
        popup.Instance.Visible = false
        self.Host.Library.OpenedFrames[popup.Instance] = nil
    end

    -- Search is a transient view of the values, not part of the selection.
    local search = self._Search
    if search then
        search:ReleaseFocus()
        if search.Text ~= "" then
            search.Text = ""
        end
    end
    self._Filter = ""
    self:_ApplyFilter()

    self.Host.Popups:Release(self :: any)
    if not self.Destroyed then
        self:_UpdateVisual(Metrics.Motion.Popup)
    end
end

function Dropdown.Toggle(self: Dropdown)
    if self.IsOpen then
        self:Close()
    else
        self.Host:BeginInteraction()
        self:Open()
    end
end

-- The popup manager's outside-click test. The trigger and the popup are one
-- interaction surface even though they are in different parts of the hierarchy.
function Dropdown.ContainsPoint(self: Dropdown, point: Vector2): boolean
    if self.Destroyed then
        return false
    end
    if Popup.Contains(self.Trigger.Instance, point) then
        return true
    end
    local popup = self._Popup
    return popup ~= nil and Popup.Contains(popup.Instance, point)
end

--// Public API ---------------------------------------------------------------

function Dropdown.GetValue(self: Dropdown): any
    return self.Value
end

function Dropdown.SetValue(self: Dropdown, value: any): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self:_Commit(value, true)
    return self
end

-- Replaces the value list. Old item instances and their connections are
-- destroyed with their scope; the current selection survives if it is still
-- valid, and is resolved deliberately if it is not.
function Dropdown.SetValues(self: Dropdown, values: { string }): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self.Values = copyValues(values)
    self._Dirty = true

    local before = table.clone(self._Selected)
    local survivors: { [string]: boolean } = {}
    for value in before do
        if contains(self.Values, value) and not self:_IsValueDisabled(value) then
            survivors[value] = true
        end
    end

    local changed = false
    if not sameSelection(before, survivors) then
        self._Selected = survivors
        if self.Multi then
            self:_SyncValue()
        else
            local selected: string? = nil
            for entry in survivors do
                selected = entry
            end
            self.Value = selected
        end
        changed = true
    end

    -- A single-select dropdown that cannot be empty falls back to the first
    -- selectable value rather than sitting in an impossible state.
    if not self.Multi and self.Value == nil and not self.AllowNull then
        local fallback = self:_FirstSelectable()
        if fallback and self:_Assign(fallback, false) then
            changed = true
        end
    end

    if self._Popup then
        self:_RebuildItems()
    end
    self:_UpdateDisplay()

    if self.IsOpen then
        self:_Reposition()
    end
    if changed then
        self.Changed:Fire(self.Value)
    end
    return self
end

function Dropdown.SetDisabledValues(self: Dropdown, disabled: { [string]: boolean }?): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self.DisabledValues = if disabled then table.clone(disabled) else {}
    for _, item in self._Items do
        item.Disabled = self:_IsValueDisabled(item.Value)
    end
    -- A value that just became disabled cannot remain selected.
    local survivors: { [string]: boolean } = {}
    for value in self._Selected do
        if not self:_IsValueDisabled(value) then
            survivors[value] = true
        end
    end
    local changed = not sameSelection(self._Selected, survivors)
    if changed then
        self._Selected = survivors
        if self.Multi then
            self:_SyncValue()
        else
            local selected: string? = nil
            for entry in survivors do
                selected = entry
            end
            self.Value = selected
        end
        self:_UpdateDisplay()
    end
    self:_UpdateItems(0)
    if changed then
        self.Changed:Fire(self.Value)
    end
    return self
end

function Dropdown.SetText(self: Dropdown, text: string): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    self.Text = text
    local label = self.Row.Label
    if label then
        label.Text = text
    end
    return self
end

function Dropdown.SetDisabled(self: Dropdown, disabled: boolean): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
        self:Close()
    end
    local label = self.Row.Label
    if label then
        self.Host.Typography:SetRole(label, if flag then "ControlLabelDisabled" else "ControlLabel", self.Resources)
    end
    self:_UpdateDisplay()
    self:_UpdateVisual(Metrics.Motion.Hover)
    return self
end

function Dropdown.SetVisible(self: Dropdown, visible: boolean): Dropdown
    assert(not self.Destroyed, "Dropdown is destroyed")
    -- Element.ApplyVisible closes the popup through Deactivate below, drops the
    -- trigger row out of the flow, and asks the groupbox to close the gap. A
    -- hidden dropdown can never leave an orphan popup on the overlay.
    Element.ApplyVisible(self, visible)
    return self
end

-- Everything transient this control owns. Called when it is hidden, when its
-- groupbox is hidden, and before it is destroyed.
function Dropdown.Deactivate(self: Dropdown)
    self.Hovered = false
    self:Close()
end

function Dropdown.OnChanged(self: Dropdown, callback: (any) -> ()): Types.Cleanup
    assert(not self.Destroyed, "Dropdown is destroyed")
    return self.Changed:Connect(callback)
end

function Dropdown.Destroy(self: Dropdown)
    if self.Destroyed then
        return
    end
    -- Close first, so the popup manager never holds a reference to a dead owner.
    self:Close()
    self.Destroyed = true
    self.Host.Popups:Release(self :: any)
    table.clear(self._Items)
    table.clear(self._Selected)
    self._Popup = nil
    self._Scroll = nil
    self._List = nil
    self._Search = nil
    self._Empty = nil
    self._ItemScope = nil
    Element.Release(self)
    self.Resources:Destroy()
end

return Dropdown
end)()

local Module19 = (function()
--!strict
local Types = Module3
local Metrics = Module8
local Materials = Module11
local Element = Module14
local Controls = Module13

local Input = {}
Input.__index = Input

export type Input = typeof(setmetatable(
    {} :: {
        Type: string,
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,
        Parent: any,

        Holder: Frame,
        LayoutHeight: number,

        Text: string,
        Value: string,
        Placeholder: string,

        Focused: boolean,
        Disabled: boolean,
        Visible: boolean,
        Hovered: boolean,

        Numeric: boolean,
        MaxLength: number?,
        FinishedOnly: boolean,

        Row: Controls.Row,
        Field: Materials.Surface,
        Box: TextBox,
        Changed: Controls.Signal,

        _Guard: boolean,
    },
    Input
))

export type Options = {
    Text: string?,
    Default: string?,
    Placeholder: string?,
    Numeric: boolean?,
    MaxLength: number?,
    FinishedOnly: boolean?,
    Disabled: boolean?,
    Visible: boolean?,
    LayoutOrder: number?,
    Callback: ((string) -> ())?,

    -- Presentation. A field is a bordered well by default; a caller that is
    -- already providing the surface -- a slider's value pill, for instance --
    -- overrides the kind, the radius and the padding rather than stacking a
    -- second plate inside the first.
    Kind: string?,
    Radius: number?,
    Align: Enum.TextXAlignment?,
    BodyHeight: number?,
    Padding: number?,
    Width: number?,
    Height: number?,

    -- A multi-line field: a recessed plate spanning the card's content width,
    -- with its own vertical padding and a height stated in lines rather than
    -- pixels, so it scales with the text role instead of drifting from it.
    MultiLine: boolean?,
    Lines: number?,
}

--// Text rules ---------------------------------------------------------------

-- Character-correct truncation. Byte slicing would cut a multi-byte sequence in
-- half and leave the field holding text the engine cannot render.
local function truncate(text: string, maximum: number): string
    local length = utf8.len(text)
    if length == nil or length <= maximum then
        return text
    end
    local offset = utf8.offset(text, maximum + 1)
    if offset == nil then
        return text
    end
    return string.sub(text, 1, offset - 1)
end

-- Keeps only what can still become a number: an optional leading sign, digits,
-- and at most one decimal point. "-" and "." on their own survive, because they
-- are what a half-typed number looks like.
local function numericFilter(text: string): string
    local result = {}
    local seenDot = false
    local index = 0
    for character in string.gmatch(text, ".") do
        index += 1
        if character == "-" then
            if index == 1 then
                table.insert(result, character)
            end
        elseif character == "." then
            if not seenDot then
                seenDot = true
                table.insert(result, character)
            end
        elseif string.match(character, "%d") then
            table.insert(result, character)
        end
    end
    return table.concat(result)
end

--// Construction -------------------------------------------------------------

-- `scope` is the owning container's scope. A control created through a groupbox
-- belongs to that groupbox: destroying the box destroys the field, and the field
-- can still be destroyed on its own without disturbing anything else.
function Input.new(host: Controls.Host, parent: Instance, options: Options?, scope: Types.Scope?): Input
    local library = host.Library
    local config: Options = options or {}
    local resources = library:CreateScope(scope or host.Resources)

    local maxLength = config.MaxLength
    if maxLength ~= nil then
        assert(type(maxLength) == "number" and maxLength >= 1, "MaxLength must be a positive number")
        maxLength = math.floor(maxLength)
    end

    local self: Input = setmetatable({
        Type = "Input",
        Destroyed = false,
        Resources = resources,
        Host = host,
        Parent = nil,

        Holder = nil :: any,
        LayoutHeight = 0,

        Text = config.Text or "",
        Value = "",
        Placeholder = config.Placeholder or "",

        Focused = false,
        Disabled = config.Disabled == true,
        Visible = config.Visible ~= false,
        Hovered = false,

        Numeric = config.Numeric == true,
        MaxLength = maxLength,
        FinishedOnly = config.FinishedOnly ~= false,

        Row = nil :: any,
        Field = nil :: any,
        Box = nil :: any,
        Changed = Controls.NewSignal(library, resources),

        _Guard = false,
    }, Input)

    self:_Build(parent, config)
    -- The row is the whole flow footprint of this control, label included, and
    -- its height is fixed at construction. The groupbox reads exactly this.
    self.Holder = self.Row.Frame
    self.LayoutHeight = self.Row.Height

    if config.Callback then
        self.Changed:Connect(config.Callback)
    end

    if config.Default ~= nil then
        self.Value = self:_Sanitise(tostring(config.Default))
    end
    self:_Push(self.Value)
    self:_UpdateVisual(0)
    self.Row.Frame.Visible = self.Visible

    -- Runs before the instances are destroyed, so Unload cannot leave the
    -- keyboard attached to a TextBox that is about to stop existing.
    resources:Add(function()
        if self.Focused then
            self.Focused = false
            pcall(function()
                self.Box:ReleaseFocus()
            end)
        end
        if host.Focused == (self :: any) then
            host:SetFocused(nil)
        end
        self.Destroyed = true
    end)

    return self
end

function Input._Build(self: Input, parent: Instance, config: Options)
    local host = self.Host
    local library = host.Library
    local scope = self.Resources
    local geometry = Metrics.Input
    local area = Metrics.TextArea
    local multiLine = config.MultiLine == true
    local lines = math.clamp(config.Lines or area.MinLines, 1, area.MaxLines)
    local textLine = host.Typography:LineHeight(host.Typography.Roles.ControlValue)
    local bodyHeight = config.BodyHeight
        or (
            if multiLine then area.PaddingY * 2 + lines * textLine + (lines - 1) * area.LineSpacing else geometry.Height
        )
    local padding = config.Padding or (if multiLine then area.PaddingX else geometry.HorizontalPadding)

    local row = Controls.CreateRow(host, {
        Name = "Input",
        Text = if self.Text ~= "" and not multiLine then self.Text else nil,
        Parent = parent,
        Scope = scope,
        LayoutOrder = config.LayoutOrder,
        BodyHeight = bodyHeight,
        BodyWidth = if self.Text ~= "" and not multiLine then (config.Width or geometry.FieldWidth) else nil,
        Height = config.Height,
    })
    self.Row = row

    -- A labelled field is a row: label on the left, a recessed plate of a fixed
    -- width on the right. Without a label the plate takes the whole row, which
    -- is what a text area and a bare value pill both want.
    local labelled = self.Text ~= "" and not multiLine
    local fieldWidth = config.Width or geometry.FieldWidth
    local field = Materials.CreateSurface(host.Context, {
        Name = "Field",
        Kind = config.Kind or "Control",
        Parent = row.Frame,
        Scope = scope,
        AnchorPoint = if labelled then Vector2.new(1, 0) else Vector2.zero,
        Position = if labelled then UDim2.new(1, 0, 0, row.BodyOffset) else UDim2.fromOffset(0, row.BodyOffset),
        Size = if labelled then UDim2.fromOffset(fieldWidth, bodyHeight) else UDim2.new(1, 0, 0, bodyHeight),
        Radius = config.Radius or Metrics.Radius.Control,
        ZIndex = Materials.Z.Structure,
        Interactive = true,
    })
    self.Field = field

    -- The text area is inset by real geometry, and stops short of both borders,
    -- so the caret and the selection highlight never touch the stroke.
    local box = host.Typography:CreateText("TextBox", "ControlValue", {
        Name = "Box",
        Text = "",
        PlaceholderText = self.Placeholder,
        PlaceholderToken = "Text.Placeholder",
        ClearTextOnFocus = false,
        MultiLine = multiLine,
        TextWrapped = multiLine,
        TextTruncate = if multiLine then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
        TextXAlignment = config.Align or Enum.TextXAlignment.Left,
        TextYAlignment = if multiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
        LineHeight = if multiLine then 1 + area.LineSpacing / textLine else 1,
        Position = UDim2.fromOffset(padding, if multiLine then area.PaddingY else 0),
        Size = UDim2.new(1, -padding * 2, 1, if multiLine then -area.PaddingY * 2 else 0),
        ZIndex = Materials.Z.Text,
        Parent = field.Instance,
    }, scope) :: TextBox
    self.Box = box

    library:Connect(field.Instance.MouseEnter, function()
        self.Hovered = true
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)
    library:Connect(field.Instance.MouseLeave, function()
        self.Hovered = false
        self:_UpdateVisual(Metrics.Motion.Hover)
    end, scope)

    library:Connect(box.Focused, function()
        if self.Disabled or not self.Visible then
            box:ReleaseFocus()
            return
        end
        -- Focusing a field is an interaction handover like any other: any open
        -- popup closes, and any previously focused field commits and releases.
        host:BeginInteraction(true, box)
        if host.Focused ~= nil and host.Focused ~= (self :: any) then
            host:ReleaseFocus()
        end
        self.Focused = true
        host:SetFocused(self :: any)
        self:_UpdateVisual(Metrics.Motion.Focus)
    end, scope)

    library:Connect(box.FocusLost, function(enterPressed: boolean)
        self.Focused = false
        if host.Focused == (self :: any) then
            host:SetFocused(nil)
        end
        self:_Commit()
        self:_UpdateVisual(Metrics.Motion.Focus)
        -- Enter and click-away are the same commit; only the cause differs.
        local _ = enterPressed
    end, scope)

    library:Connect(box:GetPropertyChangedSignal("Text"), function()
        if self._Guard then
            return
        end
        self:_OnTyped()
    end, scope)
end

--// Text handling ------------------------------------------------------------

-- Writes text into the box without the change handler treating it as typing.
function Input._Push(self: Input, text: string)
    if self.Box.Text == text then
        return
    end
    self._Guard = true
    self.Box.Text = text
    self._Guard = false
end

-- Applies the field's rules to live text. Deliberately permissive: this is what
-- the user is allowed to have on screen mid-edit, not what commits.
function Input._Sanitise(self: Input, text: string): string
    local result = text
    if self.Numeric then
        result = numericFilter(result)
    end
    local maximum = self.MaxLength
    if maximum then
        result = truncate(result, maximum)
    end
    return result
end

function Input._OnTyped(self: Input)
    local raw = self.Box.Text
    local sanitised = self:_Sanitise(raw)
    if sanitised ~= raw then
        self:_Push(sanitised)
    end
    if self.FinishedOnly then
        return
    end
    if sanitised == self.Value then
        return
    end
    self.Value = sanitised
    self.Changed:Fire(self.Value)
end

-- Commit validation, which is stricter than live entry: a numeric field that
-- holds only "-" or "." has nothing to commit, so it reverts rather than
-- publishing a value no callback could use.
function Input._Commit(self: Input)
    local candidate = self:_Sanitise(self.Box.Text)
    if self.Numeric and candidate ~= "" and tonumber(candidate) == nil then
        candidate = self.Value
    end
    self:_Push(candidate)
    if candidate == self.Value then
        return
    end
    self.Value = candidate
    self.Changed:Fire(self.Value)
end

--// Visual state -------------------------------------------------------------

function Input._UpdateVisual(self: Input, duration: number)
    if self.Destroyed then
        return
    end
    local context = self.Host.Context

    local fill = if self.Disabled
        then "Disabled"
        elseif self.Focused then "Active"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyState(context, self.Field, fill, duration)

    local border = if self.Disabled
        then "Disabled"
        elseif self.Focused then "Focused"
        elseif self.Hovered then "Hover"
        else "Rest"
    Materials.ApplyBorderState(context, self.Field, border)

    self.Host.Typography:SetRole(
        self.Box,
        if self.Disabled then "ControlValueDisabled" else "ControlValue",
        self.Resources,
        { PlaceholderColor3 = if self.Disabled then "Text.Disabled" else "Text.Placeholder" }
    )
    self.Box.TextEditable = not self.Disabled
end

--// Public API ---------------------------------------------------------------

function Input.SetValue(self: Input, value: string?): Input
    assert(not self.Destroyed, "Input is destroyed")
    local text = self:_Sanitise(if value == nil then "" else tostring(value))
    self:_Push(text)
    if text == self.Value then
        return self
    end
    self.Value = text
    self.Changed:Fire(self.Value)
    return self
end

function Input.SetPlaceholder(self: Input, placeholder: string): Input
    assert(not self.Destroyed, "Input is destroyed")
    self.Placeholder = placeholder
    self.Box.PlaceholderText = placeholder
    return self
end

function Input.SetText(self: Input, text: string): Input
    assert(not self.Destroyed, "Input is destroyed")
    self.Text = text
    local label = self.Row.Label
    if label then
        label.Text = text
    end
    return self
end

function Input.SetDisabled(self: Input, disabled: boolean): Input
    assert(not self.Destroyed, "Input is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
        self:ReleaseFocus()
    end
    local label = self.Row.Label
    if label then
        self.Host.Typography:SetRole(label, if flag then "ControlLabelDisabled" else "ControlLabel", self.Resources)
    end
    self:_UpdateVisual(Metrics.Motion.Hover)
    return self
end

function Input.SetVisible(self: Input, visible: boolean): Input
    assert(not self.Destroyed, "Input is destroyed")
    -- Element.ApplyVisible releases focus through Deactivate below, drops the
    -- row out of the flow, and asks the groupbox to close the gap.
    Element.ApplyVisible(self, visible)
    return self
end

-- Everything transient this field owns. Called when it is hidden, when its
-- groupbox is hidden, and before it is destroyed.
function Input.Deactivate(self: Input)
    self.Hovered = false
    self:ReleaseFocus()
    -- ReleaseFocus only repaints when the field actually held focus, and a
    -- hovered field that is hidden has a hover state to give up either way.
    if not self.Destroyed then
        self:_UpdateVisual(0)
    end
end

function Input.Focus(self: Input): Input
    assert(not self.Destroyed, "Input is destroyed")
    if self.Disabled or not self.Visible then
        return self
    end
    self.Box:CaptureFocus()
    return self
end

-- Safe to call when the field does not have focus, is hidden, or is being torn
-- down: the engine's FocusLost is what actually clears state, and this never
-- assumes it ran.
function Input.ReleaseFocus(self: Input): Input
    if self.Box then
        pcall(function()
            self.Box:ReleaseFocus()
        end)
    end
    if self.Focused then
        self.Focused = false
        if self.Host.Focused == (self :: any) then
            self.Host:SetFocused(nil)
        end
        if not self.Destroyed then
            self:_UpdateVisual(0)
        end
    end
    return self
end

function Input.OnChanged(self: Input, callback: (string) -> ()): Types.Cleanup
    assert(not self.Destroyed, "Input is destroyed")
    return self.Changed:Connect(callback)
end

function Input.Destroy(self: Input)
    if self.Destroyed then
        return
    end
    -- Release before the instances go: a destroyed TextBox that still holds
    -- focus leaves the keyboard attached to nothing.
    self:ReleaseFocus()
    self.Destroyed = true
    if self.Host.Focused == (self :: any) then
        self.Host:SetFocused(nil)
    end
    Element.Release(self)
    self.Resources:Destroy()
end

return Input
end)()

local Module20 = (function()
--!strict
local Controls = Module13
local Element = Module14
local Materials = Module11
local Metrics = Module8
local Popup = Module12
local ValueControl = {}

function ValueControl.new(host: any, parent: Instance, config: any, scope: any, kind: string): any
    local resources = host.Library:CreateScope(scope or host.Resources)
    -- Every value control is a row on the card's rhythm. The control paints its
    -- own body inside that row; it does not decide how tall the row is, which is
    -- what keeps a toggle, a key picker and a colour picker on one grid.
    local row = Controls.CreateRow(host, {
        Name = kind,
        Parent = parent,
        Scope = resources,
        LayoutOrder = config.LayoutOrder,
        BodyHeight = Metrics.Control.Height,
        Height = Metrics.Row.Height,
    })
    local self: any = {
        Type = kind,
        Host = host,
        Resources = resources,
        Holder = row.Frame,
        LayoutHeight = row.Height,
        Visible = config.Visible ~= false,
        Disabled = config.Disabled == true,
        Destroyed = false,
        Text = config.Text or "",
        Addons = {},
        Hovered = false,
        Pressed = false,
    }
    self.Changed = Controls.NewSignal(host.Library, resources)
    self.Destroying = Controls.NewSignal(host.Library, resources)
    for name, method in ValueControl do
        if name ~= "new" then
            self[name] = method
        end
    end
    self.Label = host.Typography:Create("ControlLabel", {
        Text = self.Text,
        Size = UDim2.fromScale(1, 1),
        TextTruncate = Enum.TextTruncate.AtEnd,
        BackgroundTransparency = 1,
        ZIndex = Materials.Z.Text,
        Parent = row.Frame,
    }, resources)
    row.Frame.Visible = self.Visible
    if config.Callback then
        self.Changed:Connect(config.Callback)
    end
    resources:Add(function()
        if not self.Destroyed then
            self:Destroy()
        end
    end)
    return self
end

function ValueControl.OnChanged(self: any, callback: any): any
    return self.Changed:Connect(callback)
end
function ValueControl.SetText(self: any, text: string): any
    assert(not self.Destroyed, "Control is destroyed")
    self.Text = tostring(text)
    self.Label.Text = self.Text
    return self
end
function ValueControl.SetVisible(self: any, flag: boolean): any
    if not self.Destroyed then
        Element.ApplyVisible(self, flag)
    end
    if self.AddonOwner then
        self.AddonOwner:LayoutAddons()
    end
    return self
end
function ValueControl.SetDisabled(self: any, flag: boolean): any
    if self.Destroyed then
        return self
    end
    self.Disabled = flag == true
    if self.Disabled then
        self:Deactivate()
    end
    self:Refresh()
    return self
end
function ValueControl.CanInteract(self: any): boolean
    return not self.Destroyed
        and not self.Disabled
        and self.Visible
        and Popup.IsDisplayed(self.Holder)
        and self.Host.Library.ActiveModal == nil
        and (not self.AddonOwner or self.AddonOwner:CanInteract())
end
function ValueControl.Deactivate(self: any)
    self.Pressed, self.Hovered = false, false
    if self._Drag then
        self._Drag:Destroy()
        self._Drag = nil
    end
    if self.Close then
        self:Close()
    end
    if self.CancelCapture then
        self:CancelCapture()
    end
    if self.Entry then
        self.Entry:ReleaseFocus()
    end
    for _, addon in self.Addons do
        addon:Deactivate()
    end
    if self.Tooltip then
        self.Tooltip:Close()
    end
end
function ValueControl.Refresh(self: any)
    if self.Destroyed then
        return
    end
    self.Host.Typography:SetRole(
        self.Label,
        if self.Disabled then "ControlLabelDisabled" else "ControlLabel",
        self.Resources
    )
    if self.Surface then
        Materials.ApplyState(
            self.Host.Context,
            self.Surface,
            if self.Disabled
                then "Disabled"
                elseif self.Pressed then "Pressed"
                elseif self.Hovered then "Hover"
                else "Rest",
            0
        )
        Materials.ApplyBorderState(
            self.Host.Context,
            self.Surface,
            if self.Disabled then "Disabled" elseif self.Hovered then "Hover" else "Rest"
        )
    end
end
function ValueControl.Destroy(self: any)
    if self.Destroyed then
        return
    end
    self:Deactivate()
    self.Destroying:Fire()
    self.Destroyed = true
    for _, addon in table.clone(self.Addons) do
        addon:Destroy()
    end
    table.clear(self.Addons)
    if self.AddonOwner then
        local owner = self.AddonOwner
        local index = table.find(owner.Addons, self)
        if index then
            table.remove(owner.Addons, index)
        end
        self.AddonOwner = nil
        if owner.LayoutAddons then
            owner:LayoutAddons()
        end
    end
    Element.Release(self)
    self.Resources:Destroy()
end

function ValueControl.BindFace(self: any, frame: GuiObject, activate: any)
    local lib = self.Host.Library
    lib:Connect(frame.MouseEnter, function()
        self.Hovered = true
        self:Refresh()
    end, self.Resources)
    lib:Connect(frame.MouseLeave, function()
        self.Hovered = false
        self.Pressed = false
        self:Refresh()
    end, self.Resources)
    lib:Connect(frame.InputBegan, function(input)
        if self:CanInteract() and lib:IsPrimaryPointer(input) then
            self.Pressed = true
            self:Refresh()
        end
    end, self.Resources)
    lib:Connect(frame.InputEnded, function()
        self.Pressed = false
        self:Refresh()
    end, self.Resources)
    lib:Connect((frame :: any).Activated, function()
        if self:CanInteract() then
            self.Pressed = false
            activate()
            self:Refresh()
        end
    end, self.Resources)
end

-- Pointer sessions exist only during a drag. Absolute rectangles are read for
-- every update, so moving a window or changing DPI cannot stale the math.
function ValueControl.Drag(self: any, frame: GuiObject, input: InputObject, update: any)
    local lib = self.Host.Library
    if not self:CanInteract() or not lib:IsPrimaryPointer(input) then
        return
    end
    if self._Drag then
        self._Drag:Destroy()
    end
    local scope = lib:CreateScope(self.Resources)
    self._Drag = scope
    scope:Add(function()
        if self._Drag == scope then
            self._Drag = nil
        end
    end)
    local function move(event)
        local point = Popup.PointerPoint(event) - frame.AbsolutePosition
        local size = frame.AbsoluteSize
        if size.X > 0 and size.Y > 0 then
            update(math.clamp(point.X / size.X, 0, 1), math.clamp(point.Y / size.Y, 0, 1))
        end
    end
    local runtime = lib.Runtime.Input
    lib:Connect(runtime.InputChanged, function(event)
        if
            (input.UserInputType == Enum.UserInputType.Touch and event == input)
            or (
                input.UserInputType ~= Enum.UserInputType.Touch
                and event.UserInputType == Enum.UserInputType.MouseMovement
            )
        then
            move(event)
        end
    end, scope)
    lib:Connect(runtime.InputEnded, function(event)
        if
            event == input
            or (input.UserInputType ~= Enum.UserInputType.Touch and event.UserInputType == input.UserInputType)
        then
            scope:Destroy()
        end
    end, scope)
    lib:Connect(runtime.WindowFocusReleased, function()
        scope:Destroy()
    end, scope)
    move(input)
end
return ValueControl
end)()

local Module21 = (function()
--!strict
local ValueControl = Module20
local Materials = Module11
local Metrics = Module8
local Element = Module14
local Toggle = {}

function Toggle.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    local self = ValueControl.new(host, parent, config, scope, "Toggle")
    self.Value = config.Default == true
    self.Presentation = config.Presentation or "Switch"
    self.Description = config.Description or ""

    local geometry = Metrics.Toggle
    local switch = self.Presentation == "Switch"
    local width = if switch then geometry.TrackWidth else geometry.TrackHeight
    local height = geometry.TrackHeight
    local knob = geometry.KnobSize
    local inset = geometry.KnobInset

    local surface = Materials.CreateSurface(host.Context, {
        Name = "Track",
        Kind = "Field",
        Parent = self.Holder,
        Scope = self.Resources,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(width, height),
        Radius = if switch then Metrics.Radius.Pill else Metrics.Radius.Small,
        ZIndex = Materials.Z.Structure,
    })
    self.Surface = surface
    self.TrackWidth = width

    self.Mark = host.Library:Create("Frame", {
        Name = "Knob",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.fromOffset(knob, knob),
        Position = UDim2.new(0, inset, 0.5, 0),
        ZIndex = Materials.Z.Edge,
        Parent = surface.Instance,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, if switch then math.floor(knob / 2) else Metrics.Radius.Small),
        Parent = self.Mark,
    }, self.Resources)
    host.Library:RegisterProperty(self.Mark, { BackgroundColor3 = "Text.Primary" }, self.Resources)

    -- The secondary line, when there is one. It is created up front so that
    -- setting a description later never has to rebuild the row.
    self.Descriptor = host.Typography:Create("ControlDescription", {
        Name = "Description",
        Text = self.Description,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Visible = self.Description ~= "",
        ZIndex = Materials.Z.Text,
        Parent = self.Holder,
    }, self.Resources)

    self.Hit = host.Library:Create("TextButton", {
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Text + 1,
        Parent = self.Holder,
    }, self.Resources)

    self.IndicatorWidth = width

    -- The label block is centred as a unit: one line sits on the row's centre
    -- line, two lines straddle it. That is what keeps a row with a description
    -- and a row without one reading as the same rhythm rather than two.
    function self:LayoutText()
        local typography = self.Host.Typography
        local labelLine = typography:LineHeight(typography.Roles.ControlLabel)
        local descLine = typography:LineHeight(typography.Roles.ControlDescription)
        local described = self.Description ~= ""
        local block = labelLine + (if described then Metrics.Row.DescriptionGap + descLine else 0)
        local rowHeight = self.Holder.Size.Y.Offset
        local top = math.floor((rowHeight - block) / 2)

        self.Label.Position = UDim2.fromOffset(0, top)
        self.Label.Size = UDim2.new(1, -self._Reserve, 0, labelLine)
        self.Descriptor.Visible = described
        self.Descriptor.Position = UDim2.fromOffset(0, top + labelLine + Metrics.Row.DescriptionGap)
        self.Descriptor.Size = UDim2.new(1, -self._Reserve, 0, descLine)
    end

    function self:LayoutAddons()
        local reserve = width + Metrics.Spacing.M
        for index = #self.Addons, 1, -1 do
            local addon = self.Addons[index]
            if addon.Visible and not addon.Destroyed then
                local w = if addon.Type == "KeyPicker" then Metrics.Core.KeyWidth else Metrics.Core.ColorWidth
                reserve += w
                addon.Holder.Position = UDim2.new(1, -reserve, 0.5, -Metrics.Control.Height / 2)
                addon.Holder.Size = UDim2.fromOffset(w, Metrics.Control.Height)
                reserve += Metrics.Spacing.S
            end
        end
        self._Reserve = reserve
        self.Hit.Size = UDim2.new(1, 0, 1, 0)
        self:LayoutText()
    end

    function self:SetDescription(text: string)
        assert(not self.Destroyed, "Toggle is destroyed")
        self.Description = tostring(text)
        self.Descriptor.Text = self.Description
        self:_ApplyHeight()
        self:LayoutText()
        return self
    end

    -- A described row is taller by exactly one description line, and the height
    -- is published through Element so the card's arithmetic stays exact.
    function self:_ApplyHeight()
        local typography = self.Host.Typography
        local extra = if self.Description ~= ""
            then Metrics.Row.DescriptionGap + typography:LineHeight(typography.Roles.ControlDescription)
            else 0
        Element.SetHeight(self, Metrics.Row.Height + extra)
    end

    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        local on = self.Value
        self.Mark.Visible = on or self.Presentation == "Switch"
        Materials.Animate(
            self.Host.Context.Animator,
            self.Mark,
            { Position = UDim2.new(0, if switch and on then width - knob - inset else inset, 0.5, 0) },
            Metrics.Motion.Knob
        )
        -- The knob is light against a dark track when off, and dark against the
        -- accent when on, so it stays a distinct object in both states.
        self.Host.Library:UnregisterProperty(self.Mark)
        self.Host.Library:RegisterProperty(self.Mark, {
            BackgroundColor3 = if self.Disabled
                then "Text.Disabled"
                elseif on then "Text.OnAccent"
                else "Text.Secondary",
        }, self.Resources)
        self.Host.Library:UnregisterProperty(self.Surface.Instance)
        self.Host.Library:RegisterProperty(self.Surface.Instance, {
            BackgroundColor3 = if on and not self.Disabled then "Accent.Base" else "Surface.Sunken",
        }, self.Resources)
        self.Surface.Instance.BackgroundTransparency = if self.Disabled then 0.5 else 0

        self.Host.Typography:SetRole(
            self.Descriptor,
            if self.Disabled then "ControlDescriptionDisabled" else "ControlDescription",
            self.Resources
        )
    end

    function self:SetValue(value)
        assert(not self.Destroyed, "Toggle is destroyed")
        assert(type(value) == "boolean", "Toggle value must be boolean")
        if value == self.Value then
            return self
        end
        self.Value = value
        self:Refresh()
        self.Changed:Fire(value)
        return self
    end

    self._Reserve = width + Metrics.Spacing.M
    self:BindFace(self.Hit, function()
        host:BeginInteraction()
        self:SetValue(not self.Value)
    end)
    self:_ApplyHeight()
    self:LayoutAddons()
    self:Refresh()
    return self
end

return Toggle
end)()

local Module22 = (function()
--!strict
local ValueControl = Module20
local Controls = Module13
local Input = Module19
local Element = Module14
local Materials = Module11
local Metrics = Module8
local Slider = {}
local function finite(value: any): boolean
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function Slider.Normalize(value: number, minimum: number, maximum: number, rounding: number): number
    assert(finite(value), "Slider value must be finite")
    local factor = 10 ^ rounding
    return math.clamp(math.round(math.clamp(value, minimum, maximum) * factor) / factor, minimum, maximum)
end
function Slider.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    local minimum, maximum = config.Min or 0, config.Max or 100
    local rounding = config.Rounding or 0
    assert(finite(minimum) and finite(maximum) and minimum <= maximum, "Invalid slider range")
    assert(finite(rounding) and rounding >= 0 and rounding <= 6 and rounding % 1 == 0, "Rounding must be 0..6")
    local initial = Slider.Normalize(config.Default or minimum, minimum, maximum, rounding)
    local self = ValueControl.new(host, parent, config, scope, "Slider")
    self.Min, self.Max, self.Rounding, self.Value = minimum, maximum, rounding, initial
    self.Prefix, self.Suffix = config.Prefix or "", config.Suffix or ""
    local geometry = Metrics.Slider
    local labelLine = host.Typography:LineHeight(host.Typography.Roles.ControlLabel)
    -- The label line is the row's top band; the track sits under it. Both are
    -- placed from the same two numbers, so the row reads as one object rather
    -- than a label with a bar underneath.
    local labelTop = math.floor((Metrics.Row.TallHeight - (labelLine + geometry.LabelGap + geometry.ThumbSize)) / 2)
    local trackY = labelTop + labelLine + geometry.LabelGap + math.floor(geometry.ThumbSize / 2)

    self.Label.Position = UDim2.fromOffset(0, labelTop)
    self.Label.Size = UDim2.new(1, -(geometry.ValuePillWidth + Metrics.Spacing.M), 0, labelLine)

    -- A compact readout pill rather than an editable field on the row. The entry
    -- is still a real text input -- clicking the pill focuses it -- so the
    -- control keeps the typed-value path it already had.
    local pill = Materials.CreateSurface(host.Context, {
        Name = "Value",
        Kind = "Field",
        Parent = self.Holder,
        Scope = self.Resources,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, labelTop + math.floor((labelLine - geometry.ValuePillHeight) / 2)),
        Size = UDim2.fromOffset(geometry.ValuePillWidth, geometry.ValuePillHeight),
        Radius = Metrics.Radius.Small,
        ZIndex = Materials.Z.Structure,
    })
    self.ValuePill = pill

    self.Entry = Input.new(host, pill.Instance, {
        Default = tostring(initial),
        FinishedOnly = true,
        Bare = true,
        Align = Enum.TextXAlignment.Center,
    }, self.Resources)
    self.Entry.Holder.Position = UDim2.fromScale(0, 0)
    self.Entry.Holder.Size = UDim2.fromScale(1, 1)

    self.Track = host.Library:Create("TextButton", {
        Name = "Track",
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0, trackY),
        Size = UDim2.new(1, 0, 0, geometry.TrackThickness),
        ZIndex = Materials.Z.Structure,
        Parent = self.Holder,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(geometry.TrackThickness / 2)),
        Parent = self.Track,
    }, self.Resources)
    host.Library:RegisterProperty(self.Track, { BackgroundColor3 = "Surface.Sunken" }, self.Resources)

    self.Fill = host.Library:Create("Frame", {
        Name = "Fill",
        BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1),
        ZIndex = Materials.Z.Interaction,
        Parent = self.Track,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(geometry.TrackThickness / 2)),
        Parent = self.Fill,
    }, self.Resources)
    host.Library:RegisterProperty(self.Fill, { BackgroundColor3 = "Accent.Base" }, self.Resources)

    -- The thumb rides the fill's right edge. It is anchored on its own centre,
    -- so it stays centred on the track at both ends instead of hanging off them.
    self.Thumb = host.Library:Create("Frame", {
        Name = "Thumb",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(geometry.ThumbSize, geometry.ThumbSize),
        ZIndex = Materials.Z.Edge,
        Parent = self.Track,
    }, self.Resources)
    host.Library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(geometry.ThumbSize / 2)),
        Parent = self.Thumb,
    }, self.Resources)
    host.Library:RegisterProperty(self.Thumb, { BackgroundColor3 = "Accent.Base" }, self.Resources)

    Element.SetHeight(self, Metrics.Row.TallHeight)
    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        local alpha = if self.Max == self.Min then 0 else (self.Value - self.Min) / (self.Max - self.Min)
        self.Fill.Size = UDim2.fromScale(alpha, 1)
        self.Fill.BackgroundTransparency = if self.Disabled then 0.6 else 0
        self.Thumb.Position = UDim2.fromScale(alpha, 0.5)
        self.Thumb.BackgroundTransparency = if self.Disabled then 0.6 else 0
        self.Entry:SetDisabled(self.Disabled)
        if not self.Entry.Focused then
            self.Entry:_Push(self.Prefix .. string.format("%." .. self.Rounding .. "f", self.Value) .. self.Suffix)
        end
    end
    function self:SetValue(value)
        assert(not self.Destroyed, "Slider is destroyed")
        local nextValue = Slider.Normalize(value, self.Min, self.Max, self.Rounding)
        local changed = self.Value ~= nextValue
        self.Value = nextValue
        self:Refresh()
        if changed then
            self.Changed:Fire(nextValue)
        end
        return self
    end
    function self:SetMin(value)
        assert(finite(value) and value <= self.Max, "Invalid minimum")
        self.Min = value
        return self:SetValue(self.Value)
    end
    function self:SetMax(value)
        assert(finite(value) and value >= self.Min, "Invalid maximum")
        self.Max = value
        return self:SetValue(self.Value)
    end
    self.Entry:OnChanged(function(text)
        local value = tonumber(text)
        if finite(value) then
            self:SetValue(value)
        else
            self:Refresh()
        end
    end)
    host.Library:Connect(self.Entry.Box.Focused, function()
        self.Entry:_Push(tostring(self.Value))
    end, self.Resources)
    host.Library:Connect(self.Entry.Box.FocusLost, function()
        self:Refresh()
    end, self.Resources)
    -- On a touch device the drag starts from an invisible pad taller than the
    -- track. It is full width, so the position arithmetic is unchanged; only
    -- the region that accepts a finger is larger.
    self.TouchTarget = Controls.TouchTarget(host, self.Track, self.Resources)
    local grip = self.TouchTarget or self.Track
    host.Library:Connect(grip.InputBegan, function(input)
        if self:CanInteract() and host.Library:IsPrimaryPointer(input) then
            host:BeginInteraction()
            self:Drag(self.Track, input, function(x)
                self:SetValue(self.Min + x * (self.Max - self.Min))
            end)
        end
    end, self.Resources)
    host.Library:Connect(self.Track.InputBegan, function(input)
        if not self:CanInteract() then
            return
        end
        local direction = if input.KeyCode == Enum.KeyCode.Left
            then -1
            elseif input.KeyCode == Enum.KeyCode.Right then 1
            else 0
        if direction ~= 0 then
            self:SetValue(self.Value + direction * 10 ^ -self.Rounding)
        end
    end, self.Resources)
    self:Refresh()
    return self
end
return Slider
end)()

local Module23 = (function()
--!strict
local Popup = Module12
local Materials = Module11
local Metrics = Module8
local ContextMenu = {}
ContextMenu.__index = ContextMenu
function ContextMenu.new(host: any, trigger: GuiObject, options: any, parentScope: any): any
    local config = options or {}
    local scope = host.Library:CreateScope(parentScope or host.Resources)
    local self: any = setmetatable({
        Host = host,
        Trigger = trigger,
        Resources = scope,
        Width = config.Width or Metrics.Core.PopupWidth,
        Height = config.Height or Metrics.Control.Height,
        IsOpen = false,
        Destroyed = false,
        OnClose = config.OnClose,
    }, ContextMenu)
    self.Surface = Materials.CreateSurface(host.Context, {
        Name = "ContextMenu",
        Kind = "Popup",
        Parent = host.Library.Overlay,
        Scope = scope,
        Size = UDim2.fromOffset(self.Width, self.Height),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
    })
    self.Frame = self.Surface.Instance
    self.Frame.Visible = false
    self.Frame.ClipsDescendants = true
    scope:Add(function()
        self:Close()
        self.Destroyed = true
    end)
    return self
end
function ContextMenu.Reposition(self: any)
    if not self.IsOpen then
        return
    end
    if not Popup.IsDisplayed(self.Trigger) then
        self:Close()
        return
    end
    local placement = Popup.Place(self.Host.Library, self.Trigger, self.Height, self.Width)
    if placement then
        self.Frame.Position, self.Frame.Size = placement.Position, placement.Size
    end
end
function ContextMenu.Open(self: any)
    if self.Destroyed or self.IsOpen or self.Host.Library.ActiveModal or not Popup.IsDisplayed(self.Trigger) then
        return
    end
    self.Host:BeginInteraction()
    self.IsOpen, self.Frame.Visible = true, true
    local lib = self.Host.Library
    lib.OpenedFrames[self.Frame] = true
    local scope = lib:CreateScope(self.Resources)
    self.OpenScope = scope
    for _, prop in { "AbsolutePosition", "AbsoluteSize", "Visible" } do
        lib:Connect(self.Trigger:GetPropertyChangedSignal(prop), function()
            self:Reposition()
        end, scope)
    end
    lib:Connect(lib.ScreenGui:GetPropertyChangedSignal("AbsoluteSize"), function()
        self:Reposition()
    end, scope)
    self:Reposition()
    if self.IsOpen then
        self.Host.Popups:Open(self)
    end
end
function ContextMenu.Close(self: any)
    local wasOpen = self.IsOpen
    self.IsOpen = false
    self.Frame.Visible = false
    self.Host.Library.OpenedFrames[self.Frame] = nil
    self.Host.Popups:Release(self)
    if self.OpenScope then
        self.OpenScope:Destroy()
        self.OpenScope = nil
    end
    if wasOpen and self.OnClose then
        self.Host.Library:SafeCallback(self.OnClose)
    end
end
function ContextMenu.Toggle(self: any)
    if self.IsOpen then
        self:Close()
    else
        self:Open()
    end
end
function ContextMenu.ContainsPoint(self: any, point: Vector2): boolean
    return Popup.Contains(self.Frame, point) or Popup.Contains(self.Trigger, point)
end
function ContextMenu.SetSize(self: any, width: number, height: number)
    assert(width > 0 and height > 0 and width < math.huge and height < math.huge, "Invalid menu size")
    self.Width, self.Height = width, height
    self:Reposition()
end
function ContextMenu.Destroy(self: any)
    if self.Destroyed then
        return
    end
    self:Close()
    self.Destroyed = true
    self.Resources:Destroy()
end
return ContextMenu
end)()

local Module24 = (function()
--!strict
local ValueControl = Module20
local Controls = Module13
local ContextMenu = Module23
local Button = Module17
local Metrics = Module8
local KeyPicker = {}
local modes = { "Toggle", "Hold", "Press", "Always" }
local mouse = { MouseButton1 = true, MouseButton2 = true, MouseButton3 = true }
local readable =
    { MouseButton1 = "LMB", MouseButton2 = "RMB", MouseButton3 = "MMB", RightShift = "RShift", LeftShift = "LShift" }
local function valid(key: any): boolean
    if type(key) ~= "string" then
        return false
    end
    if key == "None" or mouse[key] then
        return true
    end
    local ok, item = pcall(function()
        return Enum.KeyCode[key]
    end)
    return ok and item ~= nil and key ~= "Unknown"
end
local function inputKey(input: InputObject): string?
    if input.UserInputType == Enum.UserInputType.Keyboard then
        return input.KeyCode.Name
    end
    if mouse[input.UserInputType.Name] then
        return input.UserInputType.Name
    end
    return nil
end
-- One dispatcher per host. Capture is library-wide and consumes the event
-- before any normal binding or window toggle can see it.
function KeyPicker.Manager(host: any): any
    if host.Keybinds then
        return host.Keybinds
    end
    local lib = host.Library
    local manager: any = { Items = {}, Changed = Controls.NewSignal(lib, host.Resources) }
    host.Keybinds = manager
    function manager:Reset()
        for _, picker in table.clone(self.Items) do
            picker._Down = false
            if picker.Mode == "Hold" then
                picker:SetActive(false)
            end
        end
        if lib.CapturingKey and lib.CapturingKey.Host == host then
            lib.CapturingKey:CancelCapture()
        end
    end
    lib:Connect(lib.Runtime.Input.InputBegan, function(input, processed)
        local key = inputKey(input)
        local capture = lib.CapturingKey
        if capture then
            if capture.Host ~= host then
                return
            end
            if key == "Escape" then
                capture:CancelCapture()
            elseif key and valid(key) then
                capture:CancelCapture()
                capture:SetValue(key)
            end
            return
        end
        if processed or lib.ActiveModal or lib.Runtime.Input:GetFocusedTextBox() then
            return
        end
        for _, picker in table.clone(manager.Items) do
            if
                not picker.Destroyed
                and not picker.Disabled
                and picker.Value == key
                and not picker._Down
                and (not picker.AddonOwner or not picker.AddonOwner.Disabled)
            then
                picker._Down = true
                if picker.Mode == "Toggle" then
                    picker:SetActive(not picker.Active)
                elseif picker.Mode == "Hold" then
                    picker:SetActive(true)
                elseif picker.Mode == "Press" then
                    picker.Activated:Fire(true)
                end
            end
        end
        if key == host.ToggleKey and host.Window and not host.Window.Destroyed then
            host.Window:Toggle()
        end
    end, host.Resources)
    lib:Connect(lib.Runtime.Input.InputEnded, function(input)
        local key = inputKey(input)
        for _, picker in table.clone(manager.Items) do
            if picker.Value == key then
                picker._Down = false
                if picker.Mode == "Hold" then
                    picker:SetActive(false)
                end
            end
        end
    end, host.Resources)
    lib:Connect(lib.Runtime.Input.WindowFocusReleased, function()
        manager:Reset()
    end, host.Resources)
    host.Resources:Add(function()
        manager:Reset()
        table.clear(manager.Items)
    end)
    return manager
end
function KeyPicker.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    assert(valid(config.Default or "None"), "Invalid binding")
    assert(table.find(modes, config.Mode or "Toggle"), "Invalid binding mode")
    local self = ValueControl.new(host, parent, config, scope, "KeyPicker")
    self.Value, self.Mode = config.Default or "None", config.Mode or "Toggle"
    self.Active, self.Capturing, self._Down = self.Mode == "Always", false, false
    self.Activated = Controls.NewSignal(host.Library, self.Resources)
    if config.OnActivated then
        self.Activated:Connect(config.OnActivated)
    end
    self.Label.Size = UDim2.new(1, -Metrics.Core.KeyWidth - Metrics.Spacing.S, 1, 0)
    self.Key = Button.new(host, self.Holder, { Text = "" }, self.Resources)
    self.Key.Holder.AnchorPoint = Vector2.new(1, 0.5)
    self.Key.Holder.Position = UDim2.new(1, 0, 0.5, 0)
    self.Key.Holder.Size = UDim2.fromOffset(Metrics.Core.KeyWidth, Metrics.Control.Height)
    self.Key.Holder.Position = UDim2.new(1, -Metrics.Core.KeyWidth, 0, 0)
    local manager = KeyPicker.Manager(host)
    table.insert(manager.Items, self)
    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        self.Key:SetText(if self.Capturing then "…" else readable[self.Value] or self.Value)
        self.Key:SetDisabled(self.Disabled)
    end
    function self:SetActive(flag)
        flag = if self.Mode == "Always" then true else flag == true
        if self.Active == flag then
            return
        end
        self.Active = flag
        self.Activated:Fire(flag)
        manager.Changed:Fire()
    end
    function self:SetValue(value)
        assert(not self.Destroyed and valid(value), "Invalid binding")
        if self.Value == value then
            return self
        end
        self.Value, self._Down = value, false
        self:SetActive(false)
        self:Refresh()
        self.Changed:Fire(value, self.Mode)
        manager.Changed:Fire()
        return self
    end
    function self:SetMode(mode)
        assert(not self.Destroyed and table.find(modes, mode), "Invalid binding mode")
        if self.Mode == mode then
            return self
        end
        self.Mode, self._Down = mode, false
        self:SetActive(mode == "Always")
        self.Changed:Fire(self.Value, mode)
        manager.Changed:Fire()
        return self
    end
    function self:Capture()
        if not self:CanInteract() then
            return
        end
        host:BeginInteraction()
        local old = host.Library.CapturingKey
        if old then
            old:CancelCapture()
        end
        manager:Reset()
        host.Library.CapturingKey, self.Capturing = self, true
        self:Refresh()
    end
    function self:CancelCapture()
        self.Capturing = false
        if host.Library.CapturingKey == self then
            host.Library.CapturingKey = nil
        end
        self:Refresh()
    end
    function self:OnActivated(callback)
        return self.Activated:Connect(callback)
    end
    self.Menu = ContextMenu.new(
        host,
        self.Key.Holder,
        { Width = Metrics.Core.KeyWidth, Height = #modes * Metrics.Control.Height },
        self.Resources
    )
    for index, mode in modes do
        local button = Button.new(host, self.Menu.Frame, {
            Text = mode,
            Callback = function()
                self:SetMode(mode)
                self.Menu:Close()
            end,
        }, self.Menu.Resources)
        button.Holder.Position = UDim2.fromOffset(0, (index - 1) * Metrics.Control.Height)
    end
    function self:Close()
        self.Menu:Close()
    end
    self.Key:OnClick(function()
        self:Capture()
    end)
    host.Library:Connect(self.Key.Holder.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 and self:CanInteract() then
            self.Menu:Toggle()
        end
    end, self.Resources)
    self.Resources:Add(function()
        if host.Library.CapturingKey == self then
            host.Library.CapturingKey = nil
        end
        local index = table.find(manager.Items, self)
        if index then
            table.remove(manager.Items, index)
        end
        manager.Changed:Fire()
    end)
    self:Refresh()
    manager.Changed:Fire()
    return self
end
return KeyPicker
end)()

local Module25 = (function()
--!strict
local ValueControl = Module20
local ContextMenu = Module23
local Controls = Module13
local Input = Module19
local Materials = Module11
local Metrics = Module8
local ColorPicker = {}
local function hsv(color: Color3): (number, number, number)
    local high, low = math.max(color.R, color.G, color.B), math.min(color.R, color.G, color.B)
    local delta, hue = high - low, 0
    if delta > 0 then
        if high == color.R then
            hue = ((color.G - color.B) / delta) % 6
        elseif high == color.G then
            hue = (color.B - color.R) / delta + 2
        else
            hue = (color.R - color.G) / delta + 4
        end
    end
    return hue / 6, if high == 0 then 0 else delta / high, high
end
local function finite(n: any): boolean
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end
function ColorPicker.new(host: any, parent: Instance, options: any, scope: any): any
    local config = options or {}
    local initial = config.Default or Color3.new(1, 1, 1)
    assert(typeof(initial) == "Color3", "Expected Color3")
    assert(config.Transparency == nil or finite(config.Transparency), "Invalid transparency")
    local self = ValueControl.new(host, parent, config, scope, "ColorPicker")
    self.Value, self.Transparency = initial, math.clamp(config.Transparency or 0, 0, 1)
    self.Hue, self.Saturation, self.Brightness = hsv(initial)
    local lib = host.Library
    self.Label.Size = UDim2.new(1, -Metrics.Core.ColorWidth - Metrics.Spacing.M, 1, 0)
    self.Swatch = lib:Create("TextButton", {
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.fromOffset(Metrics.Core.ColorWidth, Metrics.Control.Height),
        Position = UDim2.new(1, 0, 0.5, 0),
        Parent = self.Holder,
    }, self.Resources)
    -- The swatch wears the shared control radius, so it lines up with the
    -- dropdown field and the key picker shell it sits beside in a mixed row.
    lib:Create("UICorner", { CornerRadius = UDim.new(0, Metrics.Radius.Control), Parent = self.Swatch }, self.Resources)
    self.Menu = ContextMenu.new(host, self.Swatch, {
        Width = Metrics.Core.PopupWidth,
        Height = Metrics.Core.ColorHeight,
        OnClose = function()
            if self._Drag then
                self._Drag:Destroy()
                self._Drag = nil
            end
            if self.Entry then
                self.Entry:ReleaseFocus()
            end
            self.IsOpen = false
        end,
    }, self.Resources)
    local frame, resources = self.Menu.Frame, self.Menu.Resources
    local pad, bar = Metrics.Spacing.S, Metrics.Core.TrackHeight
    local function area(name, y, height)
        return lib:Create("TextButton", {
            Name = name,
            Text = "",
            AutoButtonColor = false,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(pad, y),
            Size = UDim2.new(1, -pad * 2, 0, height),
            Parent = frame,
        }, resources)
    end
    self.SV = area("SaturationValue", pad, Metrics.Core.SVHeight)
    -- HSV gradients are color data, not UI chrome. White/black here define the
    -- color space; borders and selection markers still consume theme roles.
    local white = lib:Create(
        "Frame",
        { BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1), Parent = self.SV },
        resources
    )
    lib:Create("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = white }, resources)
    local black = lib:Create(
        "Frame",
        { BorderSizePixel = 0, BackgroundColor3 = Color3.new(0, 0, 0), Size = UDim2.fromScale(1, 1), Parent = self.SV },
        resources
    )
    lib:Create("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = black }, resources)
    self.HueBar = area("Hue", pad * 2 + Metrics.Core.SVHeight, bar)
    self.HueBar.BackgroundColor3 = Color3.new(1, 1, 1)
    local keys = {}
    for i = 0, 6 do
        table.insert(keys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1)))
    end
    lib:Create("UIGradient", { Color = ColorSequence.new(keys), Parent = self.HueBar }, resources)
    self.AlphaBar = area("Transparency", pad * 3 + Metrics.Core.SVHeight + bar, bar)
    lib:Create("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = self.AlphaBar }, resources)
    local function cursor(parentFrame)
        local marker = lib:Create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(Metrics.Core.Cursor, Metrics.Core.Cursor),
            BorderSizePixel = 1,
            ZIndex = Materials.Z.Text,
            Parent = parentFrame,
        }, resources)
        lib:RegisterProperty(marker, { BackgroundColor3 = "Text.Primary", BorderColor3 = "Surface.Canvas" }, resources)
        return marker
    end
    self.SVCursor, self.HueCursor, self.AlphaCursor = cursor(self.SV), cursor(self.HueBar), cursor(self.AlphaBar)
    self.Entry = Input.new(host, frame, { Placeholder = "#RRGGBB", FinishedOnly = true }, resources)
    self.Entry.Holder.Position = UDim2.fromOffset(pad, pad * 4 + Metrics.Core.SVHeight + bar * 2)
    self.Entry.Holder.Size = UDim2.new(1, -pad * 2, 0, Metrics.Control.Height)
    function self:Refresh()
        ValueControl.Refresh(self)
        if self.Destroyed then
            return
        end
        self.Swatch.BackgroundColor3, self.Swatch.BackgroundTransparency = self.Value, self.Transparency
        self.SV.BackgroundColor3 = Color3.fromHSV(self.Hue, 1, 1)
        self.AlphaBar.BackgroundColor3 = self.Value
        self.SVCursor.Position = UDim2.fromScale(self.Saturation, 1 - self.Brightness)
        self.HueCursor.Position = UDim2.fromScale(self.Hue, 0.5)
        self.AlphaCursor.Position = UDim2.fromScale(self.Transparency, 0.5)
        if not self.Entry.Focused then
            self.Entry:_Push(
                string.format(
                    "#%02X%02X%02X",
                    math.round(self.Value.R * 255),
                    math.round(self.Value.G * 255),
                    math.round(self.Value.B * 255)
                )
            )
        end
    end
    function self:_Commit(color, transparency, preserveHSV)
        local changed = self.Value ~= color or self.Transparency ~= transparency
        self.Value, self.Transparency = color, transparency
        if not preserveHSV then
            local h, s, v = hsv(color)
            if s > 0 then
                self.Hue = h
            end
            self.Saturation, self.Brightness = s, v
        end
        self:Refresh()
        if changed then
            self.Changed:Fire(color, transparency)
        end
        return self
    end
    function self:SetValue(color)
        assert(not self.Destroyed and typeof(color) == "Color3", "Expected Color3")
        assert(finite(color.R) and finite(color.G) and finite(color.B), "Invalid color")
        return self:_Commit(
            Color3.new(math.clamp(color.R, 0, 1), math.clamp(color.G, 0, 1), math.clamp(color.B, 0, 1)),
            self.Transparency,
            false
        )
    end
    self.SetValueRGB = self.SetValue
    function self:SetTransparency(value)
        assert(not self.Destroyed and finite(value), "Invalid transparency")
        return self:_Commit(self.Value, math.clamp(value, 0, 1), true)
    end
    function self:Open()
        if self:CanInteract() then
            self.Menu:Open()
            self.IsOpen = self.Menu.IsOpen
        end
    end
    function self:Close()
        self.Menu:Close()
        self.IsOpen = false
    end
    function self:Toggle()
        if self.IsOpen then
            self:Close()
        else
            self:Open()
        end
    end
    self:BindFace(self.Swatch, function()
        self:Toggle()
    end)
    -- The hue and alpha bars are fourteen pixels tall, which is fine to look at
    -- and impossible to hit with a thumb. On touch the drag begins from a pad
    -- over the bar; the drag itself still measures against the bar, so the
    -- colour a finger lands on is the colour under it.
    local function bind(target, update)
        local grip = Controls.TouchTarget(host, target, resources) or target
        lib:Connect(grip.InputBegan, function(input)
            if self:CanInteract() then
                self:Drag(target, input, function(x, y)
                    update(x, y)
                    self:_Commit(Color3.fromHSV(self.Hue, self.Saturation, self.Brightness), self.Transparency, true)
                end)
            end
        end, resources)
    end
    bind(self.SV, function(x, y)
        self.Saturation, self.Brightness = x, 1 - y
    end)
    bind(self.HueBar, function(x)
        self.Hue = x
    end)
    local alphaGrip = Controls.TouchTarget(host, self.AlphaBar, resources) or self.AlphaBar
    lib:Connect(alphaGrip.InputBegan, function(input)
        if self:CanInteract() then
            self:Drag(self.AlphaBar, input, function(x)
                self:SetTransparency(x)
            end)
        end
    end, resources)
    self.Entry:OnChanged(function(text)
        local hex = string.match(text, "^#?(%x%x%x%x%x%x)$")
        if hex then
            self:SetValue(
                Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
            )
        end
        self:Refresh()
    end)
    lib:Connect(self.Entry.Box.FocusLost, function()
        self:Refresh()
    end, resources)
    self:Refresh()
    return self
end
return ColorPicker
end)()

local Module26 = (function()
--!strict
local Element = Module14
local Metrics = Module8
local Button = Module17
local Container = {}
Container.__index = Container
function Container.new(parent: any, kind: string, base: any): any
    local host = parent.Host
    local resources = host.Library:CreateScope(parent.Resources)
    local self: any = setmetatable({
        Host = host,
        Resources = resources,
        Type = kind,
        Elements = {},
        ContentWidth = parent.ContentWidth,
        LayoutHeight = 0,
        Visible = true,
        RequestedVisible = true,
        Destroyed = false,
        Disabled = false,
        _Order = 0,
        Base = base,
        Dependencies = {},
    }, Container)
    for name, method in base do
        self[name] = method
    end
    self.Holder = host.Library:Create("Frame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = parent:_Next(),
        Parent = parent.Container,
    }, resources)
    self.Container = self.Holder
    host.Library:Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, Metrics.Groupbox.ElementSpacing),
        Parent = self.Container,
    }, resources)
    resources:Add(function()
        if not self.Destroyed then
            self:Destroy()
        end
    end)
    return self
end
function Container.Resize(self: any)
    if self.Destroyed or self._Resizing then
        return
    end
    self._Resizing = true
    local height, count = 0, 0
    for _, element in self.Elements do
        if not element.Destroyed and element.Visible then
            Element.ApplyWidth(element, self.ContentWidth)
            height += element.LayoutHeight
            count += 1
        end
    end
    height += math.max(0, count - 1) * Metrics.Groupbox.ElementSpacing
    self._Resizing = false
    Element.SetHeight(self, height)
end
function Container._OnWidth(self: any, width: number)
    self.ContentWidth = width
    self:Resize()
end
function Container.Deactivate(self: any)
    for _, element in self.Elements do
        Element.Deactivate(element)
    end
end
function Container.SetVisible(self: any, visible: boolean): any
    self.RequestedVisible = visible ~= false
    self:Evaluate()
    if self.Tabbox then
        self.Tabbox:EnsureSelection()
    end
    return self
end
function Container.SetDisabled(self: any, disabled: boolean): any
    self.Disabled = disabled == true
    if self.Tabbox then
        self.Tabbox:EnsureSelection()
    end
    return self
end
function Container.Evaluate(self: any)
    if self.Destroyed or self.Resources.Destroyed then
        return
    end
    local enabled = true
    for _, dependency in self.Dependencies do
        local control, expected = dependency[1], dependency[2]
        if control.Destroyed then
            enabled = false
            break
        end
        if type(expected) == "function" then
            local ok, result = pcall(expected, control.Value)
            if not ok or not result then
                enabled = false
                break
            end
        elseif control.Value ~= expected then
            enabled = false
            break
        end
    end
    self.DependencySatisfied = enabled
    Element.ApplyVisible(self, self.RequestedVisible and enabled and (not self.Tabbox or self.Tabbox.ActiveTab == self))
end
function Container.SetupDependencies(self: any, dependencies: any): any
    assert(not self.Destroyed, "Container destroyed")
    for _, dependency in dependencies do
        assert(type(dependency[1].OnChanged) == "function", "Dependency must be a value control")
    end
    if self.DependencyScope then
        self.DependencyScope:Destroy()
    end
    local scope = self.Host.Library:CreateScope(self.Resources)
    self.DependencyScope = scope
    self.Dependencies = {}
    for _, dependency in dependencies do
        table.insert(self.Dependencies, table.clone(dependency))
        scope:Add(dependency[1]:OnChanged(function()
            self:Evaluate()
        end))
        scope:Add(dependency[1].Resources:Add(function()
            self:Evaluate()
        end))
    end
    self:Evaluate()
    return self
end
function Container.Select(self: any)
    if self.Tabbox then
        self.Tabbox:SelectTab(self)
    end
    return self
end
function Container.Destroy(self: any)
    if self.Destroyed then
        return
    end
    self:Deactivate()
    self.Destroyed = true
    for _, element in table.clone(self.Elements) do
        element:Destroy()
    end
    table.clear(self.Elements)
    local tabbox = self.Tabbox
    if tabbox then
        local index = table.find(tabbox.Tabs, self)
        if index then
            table.remove(tabbox.Tabs, index)
        end
        if self.HeaderButton then
            self.HeaderButton:Destroy()
        end
    end
    Element.Release(self)
    self.Resources:Destroy()
    if tabbox and not tabbox.Destroyed then
        tabbox:EnsureSelection()
    end
end

function Container.NewTabbox(parent: any, name: string, base: any): any
    local self = Container.new(parent, "Tabbox", base)
    self.Name, self.Tabs, self.ActiveTab = name, {}, nil
    -- Replace the simple vertical list with a header and active-page slot.
    self.Container = self.Host.Library:Create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, Metrics.Tabs.Height + Metrics.Spacing.S),
        Size = UDim2.new(1, 0, 1, -(Metrics.Tabs.Height + Metrics.Spacing.S)),
        Parent = self.Holder,
    }, self.Resources)
    -- Tabbox holder is manually laid out; no list may reposition its two slots.
    for _, child in self.Holder:GetChildren() do
        if child:IsA("UIListLayout") then
            child:Destroy()
        end
    end
    function self:Resize()
        if self.Destroyed or self._Resizing then
            return
        end
        self._Resizing = true
        local active = self.ActiveTab
        if active then
            Element.ApplyWidth(active, self.ContentWidth)
        end
        local height = Metrics.Tabs.Height + Metrics.Spacing.S + (if active then active.LayoutHeight else 0)
        for index, tab in self.Tabs do
            local width = self.ContentWidth / math.max(1, #self.Tabs)
            tab.HeaderButton.Holder.Position = UDim2.fromOffset((index - 1) * width, 0)
            tab.HeaderButton.Holder.Size = UDim2.fromOffset(width, Metrics.Tabs.Height)
            tab.HeaderButton:SetDisabled(tab.Disabled)
            tab.HeaderButton.Holder.Visible = tab.RequestedVisible
        end
        self._Resizing = false
        Element.SetHeight(self, height)
    end
    function self:SelectTab(tab)
        if type(tab) == "string" then
            local found = nil
            for _, candidate in self.Tabs do
                if candidate.Name == tab then
                    found = candidate
                    break
                end
            end
            tab = found
        end
        if not tab or tab.Destroyed or tab.Disabled or not tab.RequestedVisible then
            return nil
        end
        if self.ActiveTab ~= tab then
            self:Deactivate()
            self.Host:BeginInteraction()
            self.ActiveTab = tab
            for _, page in self.Tabs do
                page:Evaluate()
            end
            self:Resize()
        end
        return tab
    end
    function self:EnsureSelection()
        local active = self.ActiveTab
        if active and not active.Destroyed and active.RequestedVisible and not active.Disabled then
            self:Resize()
            return
        end
        self.ActiveTab = nil
        for _, tab in self.Tabs do
            if tab.RequestedVisible and not tab.Disabled and not tab.Destroyed then
                self:SelectTab(tab)
                return
            end
        end
        for _, tab in self.Tabs do
            tab:Evaluate()
        end
        self:Resize()
    end
    function self:AddTab(text)
        assert(not self.Destroyed, "Tabbox destroyed")
        local page = Container.new(self, "SubTab", base)
        page.Name, page.Tabbox = text, self
        page.HeaderButton = Button.new(self.Host, self.Holder, {
            Text = text,
            Callback = function()
                self:SelectTab(page)
            end,
        }, page.Resources)
        self:_Adopt(page)
        table.insert(self.Tabs, page)
        page:Evaluate()
        self:EnsureSelection()
        return page
    end
    self:Resize()
    return self
end
return Container
end)()

local Module27 = (function()
--!strict
local ContextMenu = Module23
local Materials = Module11
local Metrics = Module8
local Button = Module17
local Input = Module19
local Popup = Module12
local UX = {}

function UX.Tooltip(control: any, text: string): any
    if control.Tooltip then
        control.Tooltip:Destroy()
    end
    local host, lib = control.Host, control.Host.Library
    local trigger = if typeof(control.Holder) == "Instance" then control.Holder else control.Holder.Instance
    local menu = ContextMenu.new(host, trigger, { Width = Metrics.Core.PopupWidth }, control.Resources)
    local label = host.Typography:Create("ControlLabel", {
        Text = text,
        TextWrapped = true,
        Position = UDim2.fromOffset(Metrics.Spacing.S, Metrics.Spacing.S),
        Size = UDim2.new(1, -Metrics.Spacing.S * 2, 1, -Metrics.Spacing.S * 2),
        Parent = menu.Frame,
    }, menu.Resources)
    local height = host.Typography:Measure(
        text,
        host.Typography.Roles.ControlLabel,
        Metrics.Core.PopupWidth - Metrics.Spacing.S * 2
    ).Y + Metrics.Spacing.S * 2
    menu:SetSize(Metrics.Core.PopupWidth, height)
    local cancel: any = nil
    local function close()
        if cancel then
            cancel()
            cancel = nil
        end
        menu:Close()
    end
    local function schedule()
        close()
        local thread = task.delay(Metrics.Core.TooltipDelay, function()
            cancel = nil
            if
                not control.Destroyed
                and Popup.IsDisplayed(trigger)
                and not lib.ActivePopup
                and not lib.ActiveModal
                and not host.Focused
            then
                menu:Open()
            end
        end)
        cancel = lib:TrackTask(thread, menu.Resources)
    end
    lib:Connect(trigger.MouseEnter, schedule, menu.Resources)
    lib:Connect(trigger.MouseLeave, close, menu.Resources)
    lib:Connect(trigger.SelectionGained, schedule, menu.Resources)
    lib:Connect(trigger.SelectionLost, close, menu.Resources)
    lib:Connect(trigger.InputBegan, close, menu.Resources)
    menu.Resources:Add(close)
    menu.Label = label
    control.Tooltip = menu
    return menu
end

function UX.Notify(host: any, options: any): any
    local config = if type(options) == "string" then { Description = options } else options or {}
    local lib = host.Library
    if not host.Notifications then
        host.Notifications = lib:Create("Frame", {
            Name = "Notifications",
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -Metrics.Spacing.L, 0, Metrics.Spacing.L),
            Size = UDim2.new(0, Metrics.Core.ToastWidth, 1, -Metrics.Spacing.L * 2),
            ZIndex = Materials.Z.Overlay + 2,
            Parent = lib.Overlay,
        }, host.Resources)
        lib:Create("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, Metrics.Popup.ToastGap),
            Parent = host.Notifications,
        }, host.Resources)
    end
    local scope = lib:CreateScope(host.Resources)
    local self: any = { Resources = scope, Destroyed = false }
    self.Surface = Materials.CreateSurface(host.Context, {
        Name = "Notification",
        Kind = "Popup",
        Parent = host.Notifications,
        Scope = scope,
        Size = UDim2.fromOffset(Metrics.Core.ToastWidth, 0),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
    })
    local title = tostring(config.Title or "Notice")
    local description = tostring(config.Description or "")
    local padX, padY = Metrics.Popup.ToastPaddingX, Metrics.Popup.ToastPaddingY
    local width = Metrics.Core.ToastWidth - padX * 2
    local titleHeight =
        host.Typography:Measure(title, host.Typography.Roles.ControlLabel, width - Metrics.Control.Height).Y
    local descHeight = host.Typography:Measure(description, host.Typography.Roles.ControlDescription, width).Y
    self.Surface.Instance.Size =
        UDim2.fromOffset(Metrics.Core.ToastWidth, titleHeight + Metrics.Row.DescriptionGap + descHeight + padY * 2)
    host.Typography:Create("ControlLabel", {
        Text = title,
        TextWrapped = true,
        Position = UDim2.fromOffset(padX, padY),
        Size = UDim2.fromOffset(width - Metrics.Control.Height, titleHeight),
        Parent = self.Surface.Instance,
    }, scope)
    host.Typography:Create("ControlDescription", {
        Text = description,
        TextWrapped = true,
        Position = UDim2.fromOffset(padX, padY + titleHeight + Metrics.Row.DescriptionGap),
        Size = UDim2.fromOffset(width, descHeight),
        Parent = self.Surface.Instance,
    }, scope)
    function self:Destroy()
        if self.Destroyed then
            return
        end
        self.Destroyed = true
        scope:Destroy()
    end
    self.Close = self.Destroy
    local close = Button.new(host, self.Surface.Instance, {
        Text = "×",
        Callback = function()
            self:Destroy()
        end,
    }, scope)
    close.Holder.Position = UDim2.new(1, -Metrics.Control.Height, 0, 0)
    close.Holder.Size = UDim2.fromOffset(Metrics.Control.Height, Metrics.Control.Height)
    scope:Add(function()
        self.Destroyed = true
    end)
    local duration = config.Time or 4
    if config.Persistent ~= true and duration > 0 then
        lib:TrackTask(
            task.delay(duration, function()
                if not self.Destroyed then
                    self:Destroy()
                end
            end),
            scope
        )
    end
    return self
end

function UX.Dialog(window: any, id: string, options: any): any
    window.Dialogs = window.Dialogs or {}
    assert(type(id) == "string" and id ~= "" and not window.Dialogs[id], "Duplicate or empty dialog id")
    local config = options or {}
    local host, lib = window.Host, window.Library
    local scope = lib:CreateScope(window.Resources)
    local self: any = { Resources = scope, Destroyed = false, IsOpen = false }
    self.Blocker = lib:Create("TextButton", {
        Name = "ModalBlocker",
        Text = "",
        AutoButtonColor = false,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 0.35,
        Visible = false,
        Modal = true,
        ZIndex = Materials.Z.Overlay + 5,
        Parent = lib.Overlay,
    }, scope)
    lib:RegisterProperty(self.Blocker, { BackgroundColor3 = "Overlay.Shadow" }, scope)
    self.Surface = Materials.CreateSurface(host.Context, {
        Name = "Dialog",
        Kind = "Popup",
        Parent = self.Blocker,
        Scope = scope,
        Size = UDim2.fromOffset(Metrics.Core.DialogWidth, 0),
        Radius = Metrics.Radius.Popup,
        ZIndex = Materials.Z.Overlay,
    })
    self.Surface.Instance.AnchorPoint = Vector2.new(0.5, 0.5)
    self.Surface.Instance.Position = UDim2.fromScale(0.5, 0.5)
    local text = tostring(config.Title or "") .. "\n\n" .. tostring(config.Description or "")
    local label = host.Typography:Create("ControlLabel", {
        Text = text,
        TextWrapped = true,
        Position = UDim2.fromOffset(Metrics.Popup.DialogPaddingX, Metrics.Popup.DialogPaddingY),
        Parent = self.Surface.Instance,
    }, scope)
    local buttons = {}
    function self:Close()
        self.IsOpen, self.Blocker.Visible = false, false
        if self.OpenScope then
            self.OpenScope:Destroy()
            self.OpenScope = nil
        end
        if lib.ActiveModal == self then
            lib.ActiveModal = nil
        end
    end
    function self:Open()
        if self.Destroyed or self.IsOpen or not window.HostFrame.Visible then
            return
        end
        host:BeginInteraction()
        if lib.ActiveModal then
            lib.ActiveModal:Close()
        end
        lib.ActiveModal = self
        self.IsOpen, self.Blocker.Visible = true, true
        local openScope = lib:CreateScope(scope)
        self.OpenScope = openScope
        lib:Connect(lib.Runtime.Input.InputBegan, function(input)
            if config.EscapeDismiss ~= false and input.KeyCode == Enum.KeyCode.Escape then
                self:Close()
            end
        end, openScope)
        if config.Time and config.Time > 0 then
            lib:TrackTask(
                task.delay(config.Time, function()
                    self:Close()
                end),
                openScope
            )
        end
    end
    function self:Destroy()
        if self.Destroyed then
            return
        end
        self:Close()
        self.Destroyed = true
        window.Dialogs[id] = nil
        scope:Destroy()
    end
    local definitions = config.FooterButtons or { { Title = "Close" } }
    local ordered = {}
    for key, definition in definitions do
        table.insert(ordered, { Key = key, Definition = definition })
    end
    table.sort(ordered, function(a, b)
        local ao, bo = a.Definition.Order or 0, b.Definition.Order or 0
        return if ao == bo then tostring(a.Key) < tostring(b.Key) else ao < bo
    end)
    for _, entry in ordered do
        local definition = entry.Definition
        local button = Button.new(host, self.Surface.Instance, {
            Text = definition.Title or tostring(entry.Key),
            Risky = definition.Variant == "Destructive",
            Callback = function()
                if definition.Close ~= false then
                    self:Close()
                end
                lib:SafeCallback(definition.Callback)
            end,
        }, scope)
        table.insert(buttons, button)
    end
    -- The footer splits the dialog's inner width at whole pixels, with the
    -- remainder given to the last button, so the row always spans exactly the
    -- content width however many buttons there are.
    local function layout()
        local popup = Metrics.Popup
        local padX, padY, gap = popup.DialogPaddingX, popup.DialogPaddingY, popup.DialogButtonGap
        local available = lib.ScreenGui.AbsoluteSize / lib.DPIScale
        local width = math.max(1, math.min(Metrics.Core.DialogWidth, available.X - padX * 2))
        local inner = math.max(1, width - padX * 2)
        local height = host.Typography:Measure(text, host.Typography.Roles.ControlLabel, inner).Y
        label.Size = UDim2.new(1, -padX * 2, 0, height)
        self.Surface.Instance.Size = UDim2.fromOffset(width, height + padY * 3 + Metrics.Button.Height)

        local count = math.max(1, #buttons)
        local span = inner - gap * (count - 1)
        local each = math.floor(span / count)
        local offset = padX
        for index, button in buttons do
            local w = if index == count then inner - (offset - padX) else each
            button.Holder.Position = UDim2.fromOffset(offset, height + padY * 2)
            button.Holder.Size = UDim2.fromOffset(w, Metrics.Button.Height)
            offset += w + gap
        end
    end
    lib:Connect(lib.ScreenGui:GetPropertyChangedSignal("AbsoluteSize"), layout, scope)
    lib:Connect(self.Blocker.Activated, function(input)
        if
            config.OutsideDismiss == true
            and input
            and not Popup.Contains(self.Surface.Instance, Popup.PointerPoint(input))
        then
            self:Close()
        end
    end, scope)
    scope:Add(function()
        self:Close()
        self.Destroyed = true
        window.Dialogs[id] = nil
    end)
    window.Dialogs[id] = self
    layout()
    return self
end

-- Search walks the navigation as it actually is: sections, then the pages in
-- them, then the cards on a page and the controls in a card. A result's path
-- names every level it needed, and navigating to one opens the section AND the
-- page before it scrolls -- a result on a page that is not open is otherwise a
-- result the user cannot see.
--
-- The page segment is dropped from the path when the section has only the one
-- implicit page, because "Visuals / Visuals / Fields / Live" says nothing the
-- first word did not.
function UX.Search(window: any, query: string): any
    local results = {}
    local needle = string.lower(query)
    if needle == "" then
        return results
    end
    local function walk(container, path, ancestors, tab, page)
        for _, control in container.Elements do
            local label = control.Text or control.Name or ""
            local full = path .. " / " .. label
            local nextAncestors = table.clone(ancestors)
            if control.Elements then
                table.insert(nextAncestors, control)
            end
            if label ~= "" and string.find(string.lower(full), needle, 1, true) then
                local result: any = { Text = full, Control = control, Tab = tab, SubTab = page }
                function result:Navigate()
                    if control.Destroyed or page.Destroyed then
                        return false
                    end
                    window:SelectTab(tab.Name)
                    tab:SelectSubTab(page.Name)
                    for _, ancestor in ancestors do
                        if ancestor.Type == "SubTab" then
                            ancestor:Select()
                        end
                        if ancestor.DependencySatisfied == false or ancestor.RequestedVisible == false then
                            return false
                        end
                    end
                    if not control.Visible then
                        return false
                    end
                    local holder = if typeof(control.Holder) == "Instance"
                        then control.Holder
                        else control.Holder.Instance
                    local view = page.Content
                    local y = (holder.AbsolutePosition.Y - view.AbsolutePosition.Y) / window.Library.DPIScale
                        + view.CanvasPosition.Y
                    view.CanvasPosition = Vector2.new(0, math.max(0, y))
                    return true
                end
                table.insert(results, result)
            end
            if control.Elements then
                walk(control, full, nextAncestors, tab, page)
            end
        end
    end
    for _, tab in window.Tabs do
        for _, page in tab.SubTabs do
            local prefix = if page.Implicit then tab.Name else tab.Name .. " / " .. page.Name
            for _, box in page.Groupboxes do
                walk(box, prefix .. " / " .. box.Name, {}, tab, page)
            end
        end
    end
    return results
end
function UX.SearchBox(window: any, parent: any): any
    local input = parent:AddInput("__search", { Text = "Find controls", FinishedOnly = false })
    local menu = ContextMenu.new(window.Host, input.Holder, {}, input.Resources)
    local resultScope: any = nil
    input:OnChanged(function(query)
        if resultScope then
            resultScope:Destroy()
        end
        resultScope = window.Library:CreateScope(menu.Resources)
        local results = UX.Search(window, query)
        if #results == 0 then
            menu:Close()
            return
        end
        menu:SetSize(Metrics.Core.PopupWidth, math.min(#results, 8) * Metrics.Control.Height)
        for index = 1, math.min(#results, 8) do
            local result = results[index]
            local button = Button.new(window.Host, menu.Frame, {
                Text = result.Text,
                Callback = function()
                    menu:Close()
                    result:Navigate()
                end,
            }, resultScope)
            button.Holder.Position = UDim2.fromOffset(0, (index - 1) * Metrics.Control.Height)
        end
        -- Do not steal typing focus just to display search results.
        menu.IsOpen, menu.Frame.Visible = true, true
        menu:Reposition()
        window.Host.Popups:Open(menu)
    end)
    return input
end
return UX
end)()

local Module28 = (function()
--!strict
local Types = Module3
local Metrics = Module8
local Materials = Module11
local Element = Module14
local Controls = Module13
local Label = Module15
local Divider = Module16
local Button = Module17
local Dropdown = Module18
local Input = Module19
local Toggle = Module21
local Slider = Module22
local KeyPicker = Module24
local ColorPicker = Module25
local Container = Module26
local UX = Module27

local Groupbox = {}
Groupbox.__index = Groupbox

-- A resize cannot be allowed to chase its own tail. Measuring a wrapped label
-- can change that label's height, which requests another resize; two passes
-- settle every real case, and this ceiling stops a pathological one.
local MAX_PASSES = 4

export type Side = "Left" | "Right"

export type Groupbox = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Resources: Types.Scope,
        Host: Controls.Host,

        Name: string,
        Description: string,
        Side: Side,
        Tab: any,
        Visible: boolean,

        Elements: { any },

        Wrapper: Frame,
        SectionLabel: TextLabel?,
        LabelHeight: number,
        Holder: Materials.Surface,
        Header: Frame?,
        Separator: Frame?,
        Title: TextLabel?,
        Descriptor: TextLabel?,
        Container: Frame,
        Dividers: { Frame },

        Width: number,
        ContentWidth: number,
        HeaderHeight: number,
        ContentHeight: number,
        Height: number,

        _Order: number,
        _Suspend: number,
        _Resizing: boolean,
        _Dirty: boolean,
    },
    Groupbox
))

export type Options = {
    Name: string?,
    Description: string?,
    Side: Side?,
    Visible: boolean?,
    LayoutOrder: number?,
    Width: number?,
}

export type Params = {
    Tab: any,
    Parent: Instance,
    Side: Side,
    Options: Options,
    Scope: Types.Scope?,
}

--// Construction -------------------------------------------------------------

function Groupbox.new(host: Controls.Host, params: Params): Groupbox
    local library = host.Library
    local config = params.Options
    local resources = library:CreateScope(params.Scope or host.Resources)
    local geometry = Metrics.Groupbox

    local width = config.Width or 0

    -- The wrapper is what the column stacks, and it is the only thing in this
    -- file that carries a LayoutOrder: the label and the card move together
    -- because they are one object as far as the column is concerned.
    local wrapper = library:Create("Frame", {
        Name = "Module",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        LayoutOrder = config.LayoutOrder or 1,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = params.Parent,
    }, resources) :: Frame

    local holder = Materials.CreateSurface(host.Context, {
        Name = "Card",
        Kind = "Card",
        Parent = wrapper,
        Scope = resources,
        Size = UDim2.new(1, 0, 0, 0),
        Radius = geometry.Radius,
        ZIndex = Materials.Z.Structure,
    })

    local self: Groupbox = setmetatable({
        Destroyed = false,
        Resources = resources,
        Host = host,

        Name = config.Name or "",
        Description = config.Description or "",
        Side = params.Side,
        Tab = params.Tab,
        Visible = config.Visible ~= false,

        Elements = {},

        Wrapper = wrapper,
        SectionLabel = nil,
        LabelHeight = 0,
        Holder = holder,
        Header = nil,
        Separator = nil,
        Title = nil,
        Descriptor = nil,
        Container = nil :: any,
        Dividers = {},

        Width = width,
        ContentWidth = math.max(0, width - geometry.PaddingLeft - geometry.PaddingRight),
        HeaderHeight = 0,
        ContentHeight = 0,
        Height = 0,

        _Order = 0,
        _Suspend = 0,
        _Resizing = false,
        _Dirty = false,
    }, Groupbox)

    self:_BuildSectionLabel()
    self:_BuildHeader()

    self.Container = library:Create("Frame", {
        Name = "Container",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = holder.Instance,
    }, resources) :: Frame

    library:Create("UIPadding", {
        PaddingLeft = UDim.new(0, geometry.PaddingLeft),
        PaddingRight = UDim.new(0, geometry.PaddingRight),
        PaddingTop = UDim.new(0, geometry.PaddingTop),
        PaddingBottom = UDim.new(0, geometry.PaddingBottom),
        Parent = self.Container,
    }, resources)

    library:Create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, geometry.ElementSpacing),
        Parent = self.Container,
    }, resources)

    wrapper.Visible = self.Visible
    self:_MeasureHeader()
    self:Resize()

    resources:Add(function()
        self.Destroyed = true
    end)

    return self
end

-- The card's name, set outside its top-left corner. Uppercased at assignment so
-- the caller's string survives intact for search, serialisation and SetName.
function Groupbox._BuildSectionLabel(self: Groupbox)
    if self.Name == "" then
        return
    end
    local geometry = Metrics.Groupbox
    local typography = self.Host.Typography
    local height = typography:LineHeight(typography.Roles.SectionLabel)

    self.SectionLabel = typography:Create("SectionLabel", {
        Name = "SectionLabel",
        Text = string.upper(self.Name),
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, height),
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = Materials.Z.Text,
        Parent = self.Wrapper,
    }, self.Resources)

    self.LabelHeight = height + geometry.SectionLabelGap
end

-- The header exists only when there is something to put in it. A groupbox with
-- no name reserves no vertical space for one, and neither does a groupbox with
-- no description.
function Groupbox._BuildHeader(self: Groupbox)
    if self.Description == "" then
        return
    end
    local library = self.Host.Library
    local geometry = Metrics.Groupbox
    local resources = self.Resources

    local header = library:Create("Frame", {
        Name = "Header",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Holder.Instance,
    }, resources) :: Frame
    self.Header = header

    library:Create("UIPadding", {
        PaddingLeft = UDim.new(0, geometry.HeaderPaddingX),
        PaddingRight = UDim.new(0, geometry.HeaderPaddingX),
        PaddingTop = UDim.new(0, geometry.HeaderPaddingTop),
        Parent = header,
    }, resources)

    self.Descriptor = self.Host.Typography:Create("GroupboxDescription", {
        Name = "Description",
        Text = self.Description,
        Size = UDim2.new(1, 0, 0, 0),
        TextWrapped = true,
        Visible = self.Description ~= "",
        ZIndex = Materials.Z.Text,
        Parent = header,
    }, resources)

    -- No closing rule. Rows carry their own hairlines at their boundaries, so a
    -- second one under the description would double the edge.
end

--// Layout -------------------------------------------------------------------

-- Header height is measured, so a description that wraps to three lines makes
-- the header three lines taller and the groupbox with it.
function Groupbox._MeasureHeader(self: Groupbox)
    local header = self.Header
    if not header then
        self.HeaderHeight = 0
        return
    end
    local typography = self.Host.Typography
    local geometry = Metrics.Groupbox

    -- A header with nothing in it reserves nothing. Clearing a description gives
    -- the space back rather than leaving its padding behind as a silent band.
    if self.Description == "" then
        self.HeaderHeight = 0
        header.Visible = false
        header.Size = UDim2.new(1, 0, 0, 0)
        return
    end
    header.Visible = true

    local height = geometry.HeaderPaddingTop

    local descriptor = self.Descriptor
    if descriptor then
        local visible = self.Description ~= ""
        descriptor.Visible = visible
        local descriptionHeight = 0
        if visible then
            local role = typography.Roles.GroupboxDescription
            local available = math.max(0, self.Width - geometry.HeaderPaddingX * 2)
            local line = typography:LineHeight(role)
            if available > 0 then
                descriptionHeight = math.max(line, math.ceil(typography:Measure(self.Description, role, available).Y))
            else
                descriptionHeight = line
            end
        end
        descriptor.Position = UDim2.fromOffset(0, 0)
        descriptor.Size = UDim2.new(1, 0, 0, descriptionHeight)
        height += descriptionHeight
    end

    height += geometry.HeaderPaddingBottom
    self.HeaderHeight = height

    header.Size = UDim2.new(1, 0, 0, height)
end

-- Row hairlines. Rows sit flush against each other, so the separation between
-- two of them is a single line drawn at their shared boundary rather than a gap.
-- The frames are pooled: a card whose rows are shown and hidden repeatedly
-- reuses the same hairlines instead of churning instances.
function Groupbox._ApplyDividers(self: Groupbox, boundaries: { number })
    local library = self.Host.Library
    local pool = self.Dividers

    for index, offset in boundaries do
        local divider = pool[index]
        if not divider then
            divider = library:Create("Frame", {
                Name = "RowDivider",
                BorderSizePixel = 0,
                Size = UDim2.new(1, 0, 0, Metrics.Groupbox.RowDivider),
                ZIndex = Materials.Z.Edge,
                Parent = self.Container,
            }, self.Resources) :: Frame
            library:RegisterProperty(divider, { BackgroundColor3 = "Border.Divider" }, self.Resources)
            pool[index] = divider
        end
        divider.Position = UDim2.fromOffset(0, offset)
        divider.Visible = true
    end

    for index = #boundaries + 1, #pool do
        pool[index].Visible = false
    end
end

function Groupbox._Apply(self: Groupbox)
    local geometry = Metrics.Groupbox
    local total = 0
    local count = 0
    local boundaries: { number } = {}

    for _, element in self.Elements do
        if element.Destroyed or not element.Visible then
            continue
        end
        -- Width first: an element whose height depends on its width remeasures
        -- here, before its height is read.
        Element.ApplyWidth(element, self.ContentWidth)
        if count > 0 then
            -- The boundary between the previous row and this one, measured from
            -- the container's padded origin.
            table.insert(boundaries, total + count * geometry.ElementSpacing)
        end
        total += element.LayoutHeight
        count += 1
    end

    -- An empty card is nothing at all. Padding around no content is empty space
    -- pretending to be structure.
    local contentHeight = 0
    if count > 0 then
        contentHeight = geometry.PaddingTop + total + (count - 1) * geometry.ElementSpacing + geometry.PaddingBottom
    end

    self:_ApplyDividers(boundaries)

    self.ContentHeight = contentHeight
    self.Height = self.HeaderHeight + contentHeight
    self.Container.Position = UDim2.fromOffset(0, self.HeaderHeight)
    self.Container.Size = UDim2.new(1, 0, 0, contentHeight)

    -- The card is placed below its label, and the wrapper reports both.
    self.Holder.Instance.Position = UDim2.fromOffset(0, self.LabelHeight)
    self.Holder.Instance.Size = UDim2.new(1, 0, 0, self.Height)
    self.Wrapper.Size = UDim2.new(1, 0, 0, self.LabelHeight + self.Height)
end

-- The single resize path. Every element change routes here, and nothing else
-- writes to the groupbox's own height.
function Groupbox.Resize(self: Groupbox)
    if self.Destroyed or self.Resources.Destroyed then
        return
    end
    if self._Suspend > 0 or self._Resizing then
        self._Dirty = true
        return
    end
    self._Resizing = true
    local passes = 0
    repeat
        self._Dirty = false
        self:_Apply()
        passes += 1
    until not self._Dirty or passes >= MAX_PASSES
    self._Resizing = false
end

-- Compound updates: rebuilding several elements at once should cost one layout
-- pass, not one per element. Resizing resumes even if the body throws.
function Groupbox.Update(self: Groupbox, body: () -> ()): Groupbox
    assert(not self.Destroyed, "Groupbox is destroyed")
    self._Suspend += 1
    self.Host.Library:SafeCallback(body)
    self._Suspend -= 1
    if self._Suspend <= 0 then
        self._Suspend = 0
        self:Resize()
    end
    return self
end

-- Called by the tab when the column width changes. Width is deterministic and
-- supplied from above; a groupbox never reads its own AbsoluteSize to find out
-- how wide it is, which is what makes wrapped text stable during a drag-resize.
function Groupbox.SetWidth(self: Groupbox, width: number): Groupbox
    if self.Destroyed then
        return self
    end
    local resolved = math.max(0, math.floor(width))
    if self.Width == resolved then
        return self
    end
    local geometry = Metrics.Groupbox
    self.Width = resolved
    self.ContentWidth = math.max(0, resolved - geometry.PaddingLeft - geometry.PaddingRight)
    self:_MeasureHeader()
    self:Resize()
    return self
end

--// Public state -------------------------------------------------------------

-- The name lives on the external section label. A card that was built without
-- one gains it here rather than staying anonymous for the rest of its life.
function Groupbox.SetName(self: Groupbox, name: string): Groupbox
    assert(not self.Destroyed, "Groupbox is destroyed")
    self.Name = tostring(name)
    local label = self.SectionLabel
    if label then
        label.Text = string.upper(self.Name)
        label.Visible = self.Name ~= ""
        self.LabelHeight = if self.Name ~= ""
            then self.Host.Typography:LineHeight(self.Host.Typography.Roles.SectionLabel) + Metrics.Groupbox.SectionLabelGap
            else 0
    else
        self:_BuildSectionLabel()
    end
    self:_MeasureHeader()
    self:Resize()
    return self
end

-- The description is the one thing that still opens a header inside the card.
-- A card built without one grows the header on demand, so the space is reserved
-- only once there is something to put in it.
function Groupbox.SetDescription(self: Groupbox, description: string): Groupbox
    assert(not self.Destroyed, "Groupbox is destroyed")
    self.Description = tostring(description)
    if self.Description ~= "" and not self.Header then
        self:_BuildHeader()
    end
    local descriptor = self.Descriptor
    if descriptor then
        descriptor.Text = self.Description
    end
    self:_MeasureHeader()
    self:Resize()
    return self
end

-- A hidden groupbox stops occupying a column slot entirely, and gives up every
-- transient thing its children were holding first: an open dropdown popup lives
-- in the overlay, so hiding the box that owns it would otherwise leave the
-- popup floating with nothing behind it.
function Groupbox.SetVisible(self: Groupbox, visible: boolean): Groupbox
    assert(not self.Destroyed, "Groupbox is destroyed")
    local flag = visible ~= false
    self.Visible = flag
    if not flag then
        for _, element in self.Elements do
            if not element.Destroyed then
                Element.Deactivate(element)
            end
        end
    end
    self.Holder.Instance.Visible = flag
    return self
end

function Groupbox.SetOrder(self: Groupbox, order: number): Groupbox
    assert(not self.Destroyed, "Groupbox is destroyed")
    self.Holder.Instance.LayoutOrder = order
    return self
end

function Groupbox.GetElements(self: Groupbox): { any }
    return table.clone(self.Elements)
end

-- Destroying a container destroys what it owns. Children are destroyed through
-- their own Destroy, so each one releases its popup, its focus and its registry
-- entry exactly as it would if it had been destroyed on its own.
function Groupbox.Destroy(self: Groupbox)
    if self.Destroyed then
        return
    end
    self.Destroyed = true

    local owned = table.clone(self.Elements)
    table.clear(self.Elements)
    for _, element in owned do
        element.Parent = nil
        if not element.Destroyed then
            self.Host.Library:SafeCallback(element.Destroy, element)
        end
    end

    -- The owning page lists this card, and so does the section that holds the
    -- page -- the section keeps a flat view of every card under it so callers
    -- that walk tabs do not have to know about pages. Both lists are released,
    -- because a card that outlives itself in either one is a leak the library's
    -- own Validate() will report.
    local function release(owner: any)
        if owner and owner.Groupboxes then
            local index = table.find(owner.Groupboxes, self)
            if index then
                table.remove(owner.Groupboxes, index)
            end
        end
    end
    local owner = self.Tab
    release(owner)
    release(if owner then owner.Tab else nil)

    self.Resources:Destroy()
end

--// BaseGroupbox -------------------------------------------------------------
-- The shared element constructors. Anything that satisfies the container
-- contract can mix these in and become a control host.

local Base = {}

function Base._Next(self: Groupbox): number
    self._Order += 1
    return self._Order
end

-- Ownership is the same for every element type, so it is written once: attach,
-- publish the initial width, register under an id if one was given, resize.
function Base._Adopt(self: Groupbox, element: any, kind: Types.RegistryKind?, id: string?): any
    Element.Attach(element, self :: any)
    Element.ApplyWidth(element, self.ContentWidth)
    if kind and id then
        local ok, message = pcall(function()
            self.Host.Library:RegisterElement(kind, id, element)
        end)
        if not ok then
            element:Destroy()
            error(message, 2)
        end
    end
    element.SetTooltip = function(control: any, text: string)
        return UX.Tooltip(control, text)
    end
    self:Resize()
    return element
end

function Base.AddLabel(self: Groupbox, options: (string | Label.Options)?): Label.Label
    assert(not self.Destroyed, "Groupbox is destroyed")
    local config = Label.Normalise(options)
    config.LayoutOrder = config.LayoutOrder or self:_Next()
    local element = Label.new(self.Host, self.Container, config, self.Resources)
    return self:_Adopt(element, "Labels", config.Id)
end

function Base.AddDivider(self: Groupbox, options: (string | Divider.Options)?): Divider.Divider
    assert(not self.Destroyed, "Groupbox is destroyed")
    local config = Divider.Normalise(options)
    config.LayoutOrder = config.LayoutOrder or self:_Next()
    local element = Divider.new(self.Host, self.Container, config, self.Resources)
    return self:_Adopt(element)
end

function Base.AddButton(self: Groupbox, options: Button.Options?): Button.Button
    assert(not self.Destroyed, "Groupbox is destroyed")
    local config: Button.Options = if options then table.clone(options) else {}
    config.LayoutOrder = config.LayoutOrder or self:_Next()
    local element = Button.new(self.Host, self.Container, config, self.Resources)
    return self:_Adopt(element, "Buttons", config.Id)
end

-- Inputs and dropdowns carry a value, so an id is required: they are Options
-- entries, and a duplicate id is rejected by the registry rather than silently
-- replacing the control that is already there.
function Base.AddInput(self: Groupbox, id: string, options: Input.Options?): Input.Input
    assert(not self.Destroyed, "Groupbox is destroyed")
    local config: Input.Options = if options then table.clone(options) else {}
    config.LayoutOrder = config.LayoutOrder or self:_Next()
    local element = Input.new(self.Host, self.Container, config, self.Resources)
    return self:_Adopt(element, "Options", id)
end

-- A multi-line field. The same control, the same commit rules and the same
-- registry entry as a single-line one; only its presentation differs, which is
-- why this is one line rather than a second input implementation.
function Base.AddTextArea(self: Groupbox, id: string, options: Input.Options?): Input.Input
    local config: Input.Options = if options then table.clone(options) else {}
    config.MultiLine = true
    return Base.AddInput(self, id, config)
end

function Base.AddDropdown(self: Groupbox, id: string, options: Dropdown.Options?): Dropdown.Dropdown
    assert(not self.Destroyed, "Groupbox is destroyed")
    local config: Dropdown.Options = if options then table.clone(options) else {}
    config.LayoutOrder = config.LayoutOrder or self:_Next()
    local element = Dropdown.new(self.Host, self.Container, config, self.Resources)
    return self:_Adopt(element, "Options", id)
end

Groupbox.Base = Base

local function addValue(self: any, id: string, options: any, constructor: any, kind: string): any
    assert(not self.Destroyed, "Container is destroyed")
    assert(
        type(id) == "string" and id ~= "" and self.Host.Library[kind][id] == nil,
        "Duplicate or empty " .. kind .. " id"
    )
    local config = table.clone(options or {})
    config.LayoutOrder = config.LayoutOrder or self:_Next()
    return self:_Adopt(constructor.new(self.Host, self.Container, config, self.Resources), kind, id)
end

function Groupbox.Deactivate(self: Groupbox)
    for _, element in self.Elements do
        Element.Deactivate(element)
    end
end
function Base.AddToggle(self: any, id: string, options: any): any
    local toggle = addValue(self, id, options, Toggle, "Toggles")
    local function addon(owner, addonId, config, constructor)
        assert(not owner.Destroyed and not owner.Host.Library.Options[addonId], "Duplicate addon id or destroyed owner")
        local picker = constructor.new(owner.Host, owner.Holder, config or {}, owner.Resources)
        owner.Host.Library:RegisterElement("Options", addonId, picker)
        picker.AddonOwner = owner
        picker.Label.Visible = false
        table.insert(owner.Addons, picker)
        owner:LayoutAddons()
        return picker
    end
    toggle.AddKeyPicker = function(owner, addonId, config)
        return addon(owner, addonId, config, KeyPicker)
    end
    toggle.AddColorPicker = function(owner, addonId, config)
        return addon(owner, addonId, config, ColorPicker)
    end
    return toggle
end
function Base.AddCheckbox(self: any, id: string, options: any): any
    local config = table.clone(options or {})
    config.Presentation = "Checkbox"
    return self:AddToggle(id, config)
end
function Base.AddSlider(self: any, id: string, options: any): any
    return addValue(self, id, options, Slider, "Options")
end
function Base.AddKeyPicker(self: any, id: string, options: any): any
    return addValue(self, id, options, KeyPicker, "Options")
end
function Base.AddColorPicker(self: any, id: string, options: any): any
    return addValue(self, id, options, ColorPicker, "Options")
end
function Base.AddDependencyBox(self: any): any
    return self:_Adopt(Container.new(self, "DependencyBox", Base))
end
function Base.AddTabbox(self: any, name: string): any
    return self:_Adopt(Container.NewTabbox(self, name, Base))
end

-- The mix-in. A container type that wants the same constructors copies this
-- table into its own metatable exactly as Groupbox does here.
function Groupbox.Extend(target: any)
    for name, method in Base do
        target[name] = method
    end
end

Groupbox.Extend(Groupbox)

return Groupbox
end)()

local Module29 = (function()
--!strict
local Types = Module3
local Theme = Module2
local Metrics = Module8
local Tokens = Module9
local Typography = Module10
local Materials = Module11
local Controls = Module13
local Popup = Module12
local Groupbox = Module28
local KeyPicker = Module24
local UX = Module27

local Shell = {}
Shell.__index = Shell

local Tab = {}
Tab.__index = Tab

local SubTab = {}
SubTab.__index = SubTab

-- A page inside a section. It owns the scroll frame, the two columns and the
-- groupboxes in them, plus its own label in the parent tab's strip.
export type SubTab = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Shell: any,
        Tab: any,
        Name: string,
        Order: number,
        Visible: boolean,
        Disabled: boolean,
        Active: boolean,
        Hovered: boolean,
        -- True for the page a tab is given when it never asked for one. It is
        -- real in every respect except that it does not put a label in the
        -- strip: a section with one page has nothing to navigate between.
        Implicit: boolean,

        -- Strip presentation: a text label with an underline beneath it, both
        -- sized to the measured label width.
        Label: TextLabel,
        HeaderButton: TextButton,
        Underline: Frame,
        HeaderWidth: number,

        Page: Frame,
        Content: ScrollingFrame,
        Columns: Frame,
        Left: Frame,
        Right: Frame,
        Groupboxes: { Groupbox.Groupbox },
        Scope: Types.Scope,
        _LeftOrder: number,
        _RightOrder: number,
    },
    SubTab
))

export type Tab = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Shell: any,
        Name: string,
        Subtitle: string,
        Order: number,
        Visible: boolean,
        Disabled: boolean,
        Active: boolean,
        Hovered: boolean,
        -- Dock presentation: an accent-filled rounded container behind the
        -- glyph, plus a narrow pill against the dock's left inner edge. Both
        -- exist for every tab and are only ever faded, so selecting a tab can
        -- never reflow the stack.
        Surface: Materials.Surface,
        Icon: GuiObject,
        Indicator: Frame,
        DockHit: TextButton,

        -- This section's own sub-tab strip. One frame per tab, all parented to
        -- the shared header; the active tab's is the only visible one, so
        -- switching sections swaps strips instead of rebuilding labels.
        Strip: Frame,
        SubTabs: { SubTab },
        ActiveSub: SubTab?,

        -- The union of every sub-tab's groupboxes, in creation order. The
        -- library's diagnostics, validation and search all walk tabs looking
        -- for cards, and they should not have to know that a section is now a
        -- stack of pages.
        Groupboxes: { Groupbox.Groupbox },
        Scope: Types.Scope,
        _SubOrder: number,
    },
    Tab
))

export type Shell = typeof(setmetatable(
    {} :: {
        Destroyed: boolean,
        Resources: Types.Scope,
        Library: any,
        Metrics: typeof(Metrics),
        Tokens: typeof(Tokens),
        Typography: Typography.Typography,
        Host: Controls.Host,
        Context: Materials.Context,
        HostFrame: Frame,
        Window: Materials.Surface,
        Dock: Materials.Surface,
        Content: Materials.Surface,
        Body: Frame,
        Header: Frame,
        HeaderRule: Frame,
        TabList: Frame?,
        PageArea: Frame,
        DockStack: Frame,
        ShowHeaderTabs: boolean,
        Tabs: { Tab },
        Active: Tab?,
        LogicalSize: Vector2,
        _Order: number,
        _DragScope: Types.Scope?,
        _HeaderHeight: number,
    },
    Shell
))

-- Icon is an image asset for the dock glyph. When it is absent the dock falls
-- back to a monogram taken from the tab name, which keeps the stack's geometry
-- and its active treatment intact without shipping a placeholder asset that
-- pretends to be an icon.
export type TabDefinition = {
    Name: string,
    Subtitle: string?,
    Icon: string?,
    -- Declaring a section's pages up front. Omitting this gives the section one
    -- implicit page and no strip.
    SubTabs: { string | SubTabDefinition }?,
}
export type SubTabDefinition = { Name: string, Order: number?, Visible: boolean?, Disabled: boolean? }
export type Options = {
    Tabs: { TabDefinition }?,
    Title: string?,
    Subtitle: string?,
    Mascot: string?,
    HeaderTabs: boolean?,
}

-- The default sections, and the pages inside the two that have more than one.
-- Home and Settings declare pages; Visuals and Players do not, and so show no
-- strip at all -- which is the point of the implicit page: a section only pays
-- for secondary navigation when it has something to navigate.
local DEFAULT_TABS: { TabDefinition } = {
    { Name = "Home", Subtitle = "Overview and status", SubTabs = { "General", "Movement", "Actions" } },
    { Name = "Visuals", Subtitle = "Rendering and appearance" },
    { Name = "Players", Subtitle = "Per-player controls" },
    { Name = "Settings", Subtitle = "Library configuration", SubTabs = { "General" } },
}

--// Window interaction -------------------------------------------------------

-- Converts a scale-anchored window to an offset position in logical units, so
-- dragging is arithmetic on one coordinate space rather than a mix of two.
local function logicalCentre(self: Shell): Vector2
    local frame = self.HostFrame
    local root = self.Library.Root
    local scale = self.Library.DPIScale
    if not root or scale <= 0 then
        return Vector2.zero
    end
    local absolute = frame.AbsolutePosition - root.AbsolutePosition + frame.AbsoluteSize / 2
    return absolute / scale
end

local function viewportLogical(self: Shell): Vector2
    local gui = self.Library.ScreenGui
    local scale = self.Library.DPIScale
    if not gui or scale <= 0 then
        return Vector2.new(Metrics.Window.Width, Metrics.Window.Height)
    end
    return gui.AbsoluteSize / scale
end

-- Keeps a recoverable amount of the window on screen. Unobtrusive: it only
-- engages once an edge has already left the viewport.
local function clampCentre(self: Shell, centre: Vector2, size: Vector2): Vector2
    local viewport = viewportLogical(self)
    local margin = Metrics.Window.ClampMargin
    local halfWidth = size.X / 2
    local halfHeight = size.Y / 2
    local minX = -halfWidth + math.min(margin, size.X)
    local maxX = viewport.X + halfWidth - math.min(margin, size.X)
    -- The drag strips live along the top edge, so that edge never goes under the
    -- topbar: the window always stays grabbable. The layer ignores the GUI inset,
    -- so the inset has to be honoured here instead.
    local minY = halfHeight + Popup.GuiInset().Y / math.max(self.Library.DPIScale, 0.0001)
    local maxY = viewport.Y + halfHeight - math.min(margin, size.Y)
    return Vector2.new(
        math.clamp(centre.X, math.min(minX, maxX), math.max(minX, maxX)),
        math.clamp(centre.Y, math.min(minY, maxY), math.max(minY, maxY))
    )
end

local function setCentre(self: Shell, centre: Vector2)
    self.HostFrame.Position = UDim2.fromOffset(math.round(centre.X), math.round(centre.Y))
end

-- One pointer session at a time, tracked through a scope. There is no per-frame
-- connection and nothing survives losing window focus mid-drag.
function Shell._BeginPointerSession(self: Shell, input: InputObject, step: (delta: Vector2) -> ())
    local library = self.Library
    local runtime = library.Runtime
    if not runtime or self._DragScope then
        return
    end
    local scale = library.DPIScale
    if scale <= 0 then
        return
    end

    local origin = Vector2.new(input.Position.X, input.Position.Y)
    local scope = library:CreateScope(self.Resources)
    self._DragScope = scope
    scope:Add(function()
        if self._DragScope == scope then
            self._DragScope = nil
        end
    end)

    local function finish()
        scope:Destroy()
    end

    library:Connect(runtime.Input.InputChanged, function(moved: InputObject)
        if not library:IsPointerMovement(moved) then
            return
        end
        local current = Vector2.new(moved.Position.X, moved.Position.Y)
        step((current - origin) / scale)
    end, scope)

    library:Connect(runtime.Input.InputEnded, function(ended: InputObject)
        if ended == input or library:IsPrimaryPointer(ended) then
            finish()
        end
    end, scope)

    -- Alt-tabbing away mid-drag must not leave the window following the cursor.
    library:Connect(runtime.Input.WindowFocusReleased, finish, scope)
end

function Shell._BindDrag(self: Shell, handle: GuiObject)
    local library = self.Library
    library:Connect(handle.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        -- Starting a drag is an interaction handover: a popup that was open is
        -- attached to a window that is about to move.
        self.Host:BeginInteraction()
        local startCentre = logicalCentre(self)
        setCentre(self, startCentre)
        local size = self.HostFrame.AbsoluteSize / library.DPIScale
        self:_BeginPointerSession(input, function(delta)
            setCentre(self, clampCentre(self, startCentre + delta, size))
        end)
    end, self.Resources)
end

function Shell._BindResize(self: Shell, handle: GuiObject)
    local library = self.Library
    local window = Metrics.Window
    library:Connect(handle.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        self.Host:BeginInteraction()
        local startCentre = logicalCentre(self)
        setCentre(self, startCentre)
        local startSize = self.HostFrame.AbsoluteSize / library.DPIScale
        self:_BeginPointerSession(input, function(delta)
            local width = math.clamp(math.round(startSize.X + delta.X), window.MinWidth, window.MaxWidth)
            local height = math.clamp(math.round(startSize.Y + delta.Y), window.MinHeight, window.MaxHeight)
            local size = Vector2.new(width, height)
            self.LogicalSize = size
            self.HostFrame.Size = UDim2.fromOffset(width, height)
            -- Columns follow the window inside the same step, so the content
            -- never trails the frame it is inside.
            self:_ApplyContentWidth()
            -- Anchored at its centre, so growing from the bottom-right corner
            -- means moving the centre by half the growth to pin the top-left.
            setCentre(self, clampCentre(self, startCentre + (size - startSize) / 2, size))
        end)
    end, self.Resources)
end

--// Sub-tabs -----------------------------------------------------------------
-- A sub-tab is a page. It owns a scroll frame, two columns and the groupboxes
-- stacked in them, and it contributes one label to its parent tab's strip.

-- Selection is a colour on the label and a transparency on the underline. Both
-- instances already exist at their final size, so activating a page cannot
-- shift the strip by a subpixel.
function SubTab._Refresh(self: SubTab, duration: number)
    if self.Destroyed then
        return
    end
    local shell = self.Shell :: Shell

    local role = if self.Disabled
        then "HeaderTabDisabled"
        elseif self.Active then "HeaderTabActive"
        elseif self.Hovered then "HeaderTabActive"
        else "HeaderTab"
    shell.Typography:SetRole(self.Label, role, self.Scope)

    Materials.Animate(
        shell.Context.Animator,
        self.Underline,
        { BackgroundTransparency = if self.Active then 0 else 1 },
        duration
    )
end

function SubTab.Select(self: SubTab): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    local tab = self.Tab :: Tab
    (self.Shell :: Shell):SelectTab(tab.Name)
    tab:SelectSubTab(self.Name)
    return self
end

function SubTab.SetVisible(self: SubTab, visible: boolean): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    local flag = visible ~= false
    if self.Visible == flag then
        return self
    end
    self.Visible = flag
    self.Hovered = false
    -- A hidden page contributes neither a label to the strip nor content to the
    -- canvas. Both go at once, so nothing hidden can be measured.
    self.HeaderButton.Visible = flag and not self.Implicit
    if not flag then
        self.Active = false
        self.Page.Visible = false
        self:_Refresh(0)
    end
    (self.Tab :: Tab):_EnsureValidSub(self)
    return self
end

function SubTab.Show(self: SubTab): SubTab
    return self:SetVisible(true)
end

function SubTab.Hide(self: SubTab): SubTab
    return self:SetVisible(false)
end

function SubTab.SetDisabled(self: SubTab, disabled: boolean): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
    end
    self:_Refresh(Metrics.Motion.Hover);
    (self.Tab :: Tab):_EnsureValidSub(self)
    return self
end

function SubTab.SetOrder(self: SubTab, order: number): SubTab
    assert(not self.Destroyed, "SubTab is destroyed")
    self.Order = order
    self.HeaderButton.LayoutOrder = order
    return self
end

--// Groupboxes ---------------------------------------------------------------
-- A page hosts two columns and nothing else. It does not position groupboxes;
-- it appends one to a column, hands it that column's width, and lets the
-- column's list layout stack it.

function SubTab.AddGroupbox(self: SubTab, options: Groupbox.Options?): Groupbox.Groupbox
    assert(not self.Destroyed, "SubTab is destroyed")
    local shell = self.Shell :: Shell
    local config: Groupbox.Options = if options then table.clone(options) else {}

    local side: Groupbox.Side = if config.Side == "Right" then "Right" else "Left"
    local column = if side == "Right" then self.Right else self.Left

    if config.LayoutOrder == nil then
        if side == "Right" then
            self._RightOrder += 1
            config.LayoutOrder = self._RightOrder
        else
            self._LeftOrder += 1
            config.LayoutOrder = self._LeftOrder
        end
    end
    config.Width = config.Width or math.round(column.Size.X.Offset)

    local groupbox = Groupbox.new(shell.Host, {
        Tab = self,
        Parent = column,
        Side = side,
        Options = config,
        Scope = self.Scope,
    })
    table.insert(self.Groupboxes, groupbox)
    -- The section keeps a flat view of every card under it, so the library's
    -- diagnostics, validation and search do not have to walk two levels.
    table.insert((self.Tab :: Tab).Groupboxes, groupbox)
    return groupbox
end

-- Convenience, not a second implementation: both call the constructor above.
function SubTab.AddLeftGroupbox(self: SubTab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Left" })
end

function SubTab.AddRightGroupbox(self: SubTab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Right" })
end

function SubTab.GetGroupboxes(self: SubTab): { Groupbox.Groupbox }
    return table.clone(self.Groupboxes)
end

-- Column geometry is computed once, from the window's logical width, and handed
-- down. Both columns come out of the same subtraction and the remainder goes to
-- the left one, so the two can never disagree by a pixel.
function SubTab._ApplyWidth(self: SubTab, available: number)
    if self.Destroyed then
        return
    end
    local gap = Metrics.Columns.Gap
    local usable = math.max(Metrics.Columns.MinWidth * 2 + gap, math.floor(available))
    local right = math.floor((usable - gap) / 2)
    local left = usable - gap - right

    self.Columns.Size = UDim2.new(0, usable, 0, 0)
    self.Left.Position = UDim2.fromOffset(0, 0)
    self.Left.Size = UDim2.new(0, left, 0, 0)
    self.Right.Position = UDim2.fromOffset(left + gap, 0)
    self.Right.Size = UDim2.new(0, right, 0, 0)

    for _, groupbox in self.Groupboxes do
        if not groupbox.Destroyed then
            groupbox:SetWidth(if groupbox.Side == "Right" then right else left)
        end
    end
end

function SubTab.Destroy(self: SubTab)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    local tab = self.Tab :: Tab
    local index = table.find(tab.SubTabs, self)
    if index then
        table.remove(tab.SubTabs, index)
    end
    for _, groupbox in self.Groupboxes do
        local at = table.find(tab.Groupboxes, groupbox)
        if at then
            table.remove(tab.Groupboxes, at)
        end
    end
    local wasActive = tab.ActiveSub == self
    if wasActive then
        tab.ActiveSub = nil
    end
    self.Scope:Destroy()
    if not tab.Destroyed then
        tab:_LayoutHeader()
        if wasActive then
            tab:_SelectFirstValidSub()
        end
    end
end

--// Tabs ---------------------------------------------------------------------

-- A tab's selection is expressed in three places at once -- the dock
-- container's fill, the dock pill and the glyph's colour -- and every one of
-- them is a transparency or a colour change on an instance that already exists
-- at its final size. Nothing is created, destroyed, moved or resized here,
-- which is why a section change cannot shift the dock stack by a subpixel.
--
-- The header strip is deliberately not touched from here. It is not a second
-- presentation of this tab; it is the navigation of the page set underneath it,
-- and it is swapped wholesale when the active section changes.
function Tab._Refresh(self: Tab, duration: number)
    if self.Destroyed then
        return
    end
    local shell = self.Shell :: Shell
    local animator = shell.Context.Animator

    -- The active container is painted accent; an inactive one shows nothing but
    -- the dock behind it, and picks up only a hover tint.
    local container = if self.Active then 0 elseif self.Disabled then 1 elseif self.Hovered then 0.88 else 1
    Materials.Animate(animator, self.Surface.Instance, { BackgroundTransparency = container }, duration)

    Materials.Animate(animator, self.Indicator, { BackgroundTransparency = if self.Active then 0 else 1 }, duration)

    -- The glyph reads against whatever is behind it: the accent fill when
    -- active, the dock surface otherwise.
    local icon = self.Icon
    if icon:IsA("ImageLabel") then
        local token: Types.ThemeRole = if self.Active
            then "Text.OnAccent"
            elseif self.Disabled then "Text.Disabled"
            elseif self.Hovered then "Text.Primary"
            else "Text.Muted"
        -- A binding is replaced, not stacked: the registry holds one entry per
        -- instance, exactly as SetRole does for a label.
        shell.Library:UnregisterProperty(icon)
        shell.Library:RegisterProperty(icon, { ImageColor3 = token }, self.Scope)
    else
        shell.Typography:SetRole(
            icon,
            if self.Disabled
                then "DockGlyphDisabled"
                elseif self.Active then "DockGlyphActive"
                elseif self.Hovered then "DockGlyphHover"
                else "DockGlyph",
            self.Scope
        )
    end
end

function Tab.Select(self: Tab): Tab
    assert(not self.Destroyed, "Tab is destroyed");
    (self.Shell :: Shell):SelectTab(self.Name)
    return self
end

function Tab.SetVisible(self: Tab, visible: boolean): Tab
    assert(not self.Destroyed, "Tab is destroyed")
    local flag = visible ~= false
    if self.Visible == flag then
        return self
    end
    self.Visible = flag
    self.Hovered = false
    self:_ApplyPresence()
    if not flag then
        self:_Refresh(0)
    end -- The dock places items by centre, so it is re-laid out explicitly.
    (self.Shell :: Shell):_LayoutDock();
    (self.Shell :: Shell):_EnsureValidSelection(self)
    return self
end

-- The three instances that make up a tab's dock presentation are shown and
-- hidden together, along with the strip it owns. They are listed once, here,
-- rather than at each call site.
function Tab._ApplyPresence(self: Tab)
    local flag = self.Visible
    self.Surface.Instance.Visible = flag
    self.Indicator.Visible = flag
    self.DockHit.Visible = flag
    if not flag then
        self.Strip.Visible = false
    end
end

-- Places this tab's dock container, pill and hit area on a given centre line.
function Tab._PlaceDock(self: Tab, centre: number)
    local dock = Metrics.Dock
    self.Surface.Instance.Position = UDim2.new(0.5, 0, 0, centre)
    self.Indicator.Position = UDim2.new(0, dock.IndicatorInset, 0, centre)
    self.DockHit.Position = UDim2.new(0.5, 0, 0, centre)
end

function Tab.Show(self: Tab): Tab
    return self:SetVisible(true)
end

function Tab.Hide(self: Tab): Tab
    return self:SetVisible(false)
end

function Tab.SetDisabled(self: Tab, disabled: boolean): Tab
    assert(not self.Destroyed, "Tab is destroyed")
    local flag = disabled == true
    if self.Disabled == flag then
        return self
    end
    self.Disabled = flag
    if flag then
        self.Hovered = false
    end
    self:_Refresh(Metrics.Motion.Hover);
    (self.Shell :: Shell):_EnsureValidSelection(self)
    return self
end

function Tab.SetOrder(self: Tab, order: number): Tab
    assert(not self.Destroyed, "Tab is destroyed")
    self.Order = order
    self.Strip.LayoutOrder = order;
    (self.Shell :: Shell):_LayoutDock()
    return self
end

--// Sub-tab ownership --------------------------------------------------------

-- Whether this section has anything to navigate between. A section with one
-- page has no strip: a single label under no heading is decoration, not
-- navigation, and the page gets the vertical space back instead.
function Tab.ShowsStrip(self: Tab): boolean
    if not (self.Shell :: Shell).ShowHeaderTabs then
        return false
    end
    for _, sub in self.SubTabs do
        if not sub.Destroyed and sub.Visible and not sub.Implicit then
            return true
        end
    end
    return false
end

-- Reconciles the strip with the pages behind it, then tells the shell how much
-- vertical space the header now needs. One call, from every path that can
-- change either answer.
function Tab._LayoutHeader(self: Tab)
    if self.Destroyed then
        return
    end
    for _, sub in self.SubTabs do
        if not sub.Destroyed then
            sub.HeaderButton.Visible = sub.Visible and not sub.Implicit
        end
    end
    local shell = self.Shell :: Shell
    if shell.Active == self and not shell.Destroyed then
        shell:_ApplyHeader()
    end
end

function Tab.GetSubTab(self: Tab, name: string): SubTab?
    for _, sub in self.SubTabs do
        if not sub.Destroyed and sub.Name == name then
            return sub
        end
    end
    return nil
end

function Tab.GetSubTabs(self: Tab): { SubTab }
    return table.clone(self.SubTabs)
end

function Tab.AddSubTab(self: Tab, definition: string | SubTabDefinition): SubTab
    assert(not self.Destroyed, "Tab is destroyed")
    local config: SubTabDefinition = if type(definition) == "string" then { Name = definition } else definition
    return (self.Shell :: Shell):_BuildSubTab(self, config, false)
end

-- The page a section is given when it never asked for one. Created on first
-- use, so a section that declares its own pages never pays for one it does not
-- want, and a section that never mentions pages still has somewhere to put a
-- card.
function Tab._DefaultSubTab(self: Tab): SubTab
    for _, sub in self.SubTabs do
        if not sub.Destroyed then
            return sub
        end
    end
    return (self.Shell :: Shell):_BuildSubTab(self, { Name = self.Name }, true)
end

local function subSelectable(sub: SubTab): boolean
    return not sub.Destroyed and sub.Visible and not sub.Disabled
end

function Tab.SelectSubTab(self: Tab, name: string): SubTab?
    assert(not self.Destroyed, "Tab is destroyed")
    local target = self:GetSubTab(name)
    if not target or not subSelectable(target) then
        return nil
    end
    if self.ActiveSub == target then
        target.Page.Visible = self.Active
        return target
    end
    local previous = self.ActiveSub
    if previous and not previous.Destroyed then
        previous.Active = false
        previous.Page.Visible = false
        previous:_Refresh(Metrics.Motion.Select)
    end
    self.ActiveSub = target
    target.Active = true
    -- The page is shown only while its section is; a page in a closed section
    -- stays hidden so it can never contribute to the visible canvas.
    target.Page.Visible = self.Active
    target:_Refresh(Metrics.Motion.Select)
    return target
end

function Tab._SelectFirstValidSub(self: Tab)
    local ordered = {}
    for _, sub in self.SubTabs do
        if subSelectable(sub) then
            table.insert(ordered, sub)
        end
    end
    table.sort(ordered, function(a, b)
        if a.Order == b.Order then
            return a.Name < b.Name
        end
        return a.Order < b.Order
    end)
    local first = ordered[1]
    if first then
        self:SelectSubTab(first.Name)
    else
        local active = self.ActiveSub
        if active then
            active.Active = false
            active.Page.Visible = false
            active:_Refresh(0)
            self.ActiveSub = nil
        end
    end
end

-- Called after a page's visibility or disabled state changed. If the page that
-- changed was the open one and is no longer usable, the section falls back to
-- the first one that is; otherwise nothing moves.
function Tab._EnsureValidSub(self: Tab, changed: SubTab)
    self:_LayoutHeader()
    if self.ActiveSub == changed and not subSelectable(changed) then
        self.ActiveSub = nil
        changed.Active = false
        changed.Page.Visible = false
        changed:_Refresh(0)
        self:_SelectFirstValidSub()
    elseif self.ActiveSub == nil then
        self:_SelectFirstValidSub()
    end
end

--// Groupbox delegation ------------------------------------------------------
-- A section is not a page, but the one-page case is the common one and should
-- not have to say so. These forward to the section's default page; a section
-- with declared pages puts cards on those instead.

function Tab.AddGroupbox(self: Tab, options: Groupbox.Options?): Groupbox.Groupbox
    assert(not self.Destroyed, "Tab is destroyed")
    return self:_DefaultSubTab():AddGroupbox(options)
end

function Tab.AddLeftGroupbox(self: Tab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Left" })
end

function Tab.AddRightGroupbox(self: Tab, name: string, description: string?): Groupbox.Groupbox
    return self:AddGroupbox({ Name = name, Description = description, Side = "Right" })
end

function Tab.GetGroupboxes(self: Tab): { Groupbox.Groupbox }
    return table.clone(self.Groupboxes)
end

-- Published to every page in the section. The width is one number and it is
-- computed once, above; a page does not read its own AbsoluteSize to find it.
function Tab._ApplyWidth(self: Tab, available: number)
    if self.Destroyed then
        return
    end
    for _, sub in self.SubTabs do
        if not sub.Destroyed then
            sub:_ApplyWidth(available)
        end
    end
end

function Tab.Destroy(self: Tab)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    local shell = self.Shell :: Shell
    local index = table.find(shell.Tabs, self)
    if index then
        table.remove(shell.Tabs, index)
    end
    local wasActive = shell.Active == self
    if wasActive then
        shell.Active = nil
    end
    self.Scope:Destroy()
    if not shell.Destroyed then
        shell:_LayoutDock()
    end
    if wasActive and not shell.Destroyed then
        shell.Host:BeginInteraction()
        shell:_SelectFirstValid()
    end
end

--// Shell construction -------------------------------------------------------

local function createHostFrame(library: any, scope: Types.Scope): Frame
    -- Deliberately not clipped: the window's cast shadow draws outside these
    -- bounds, and a clipping ancestor would cut it off.
    return library:Create("Frame", {
        Name = "ZedlibWindow",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(Metrics.Window.Width, Metrics.Window.Height),
        ZIndex = Materials.Z.Base,
        ClipsDescendants = false,
    }, scope) :: Frame
end

-- The dock's identity anchor: a mascot emblem sitting near the top with
-- deliberate air beneath it. A caller-supplied image is used when there is one;
-- otherwise a rounded accent-tinted emblem carrying the product's initial holds
-- the same footprint, so the stack below it is positioned identically either
-- way and a real asset can be dropped in later without moving anything.
function Shell._BuildMascot(self: Shell, parent: Frame, asset: string?, title: string)
    local library = self.Library
    local dock = Metrics.Dock
    local size = dock.MascotSize

    local holder = library:Create("Frame", {
        Name = "Mascot",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, dock.PaddingTop + size / 2),
        Size = UDim2.fromOffset(size, size),
        ZIndex = Materials.Z.Structure,
        Parent = parent,
    }, self.Resources) :: Frame

    if asset and asset ~= "" then
        library:Create("ImageLabel", {
            Name = "Emblem",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Image = asset,
            ScaleType = Enum.ScaleType.Fit,
            Size = UDim2.fromScale(1, 1),
            ZIndex = Materials.Z.Text,
            Parent = holder,
        }, self.Resources)
        return
    end

    local emblem = Materials.CreateSurface(self.Context, {
        Name = "Emblem",
        Kind = "DockItemActive",
        Parent = holder,
        Scope = self.Resources,
        Size = UDim2.fromScale(1, 1),
        Radius = Metrics.Radius.DockItem,
        ZIndex = Materials.Z.Structure,
    })

    local initial = string.upper(string.sub(title, 1, 1))
    local glyph = self.Typography:Create("DockGlyphActive", {
        Name = "Initial",
        Text = if initial ~= "" then initial else "Z",
        Size = UDim2.fromScale(1, 1),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = Materials.Z.Text,
        Parent = emblem.Instance,
    }, self.Resources)
    assert(glyph ~= nil, "Mascot emblem failed to build")
end

--// Sub-tab construction ----------------------------------------------------

-- One page and the strip label that opens it. Both are built here, together,
-- because they are one object with two faces and neither is useful alone.
function Shell._BuildSubTab(self: Shell, tab: Tab, definition: SubTabDefinition, implicit: boolean): SubTab
    local library = self.Library
    local scope = library:CreateScope(tab.Scope)
    local content = Metrics.Content
    local header = Metrics.HeaderTabs

    tab._SubOrder += 1
    local order = definition.Order or tab._SubOrder

    --// Strip presentation ---------------------------------------------------
    -- The label's width is measured, and both the button and the underline take
    -- that width, so the underline is exactly as wide as the word above it
    -- rather than as wide as a padded box around it.
    local labelWidth =
        math.max(1, math.ceil(self.Typography:Measure(definition.Name, self.Typography.Roles.HeaderTab, math.huge).X))

    local headerButton = library:Create("TextButton", {
        Name = definition.Name .. "SubTab",
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        LayoutOrder = order,
        -- The button is the full strip height so its bottom edge is the strip's
        -- bottom edge, which is where the underline and the rule both sit.
        Size = UDim2.fromOffset(labelWidth, header.Height),
        ZIndex = Materials.Z.Structure,
        Visible = not implicit,
        Parent = tab.Strip,
    }, scope) :: TextButton

    -- The label occupies the button above the underline band, so the text is
    -- centred in the space it actually has rather than in the whole strip.
    local underlineBand = header.UnderlineThickness
    local label = self.Typography:Create("HeaderTab", {
        Name = "Label",
        Text = definition.Name,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, header.Height - underlineBand),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = Materials.Z.Text,
        Parent = headerButton,
    }, scope)

    -- Pinned to the button's bottom edge, which is the rule's line. The active
    -- marker sits on the rule rather than floating above it, so the strip reads
    -- as one edge with a highlighted span rather than two stacked lines.
    local underline = library:Create("Frame", {
        Name = "Underline",
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, header.UnderlineThickness),
        ZIndex = Materials.Z.Overlay,
        Parent = headerButton,
    }, scope) :: Frame
    library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(header.UnderlineThickness / 2)),
        Parent = underline,
    }, scope)
    library:RegisterProperty(underline, { BackgroundColor3 = "Accent.Base" }, scope)

    --// Page ----------------------------------------------------------------
    local page = library:Create("Frame", {
        Name = definition.Name .. "Page",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Structure,
        Visible = false,
        ClipsDescendants = false,
    }, scope) :: Frame

    -- The control region scrolls. A dropdown opened inside it is parented to the
    -- overlay, so this clipping frame cannot cut its popup off.
    local scroll = library:Create("ScrollingFrame", {
        Name = "Controls",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = content.ScrollBarThickness,
        ScrollBarImageTransparency = Theme.Alpha.ScrollBar,
        VerticalScrollBarInset = Enum.ScrollBarInset.None,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ClipsDescendants = true,
        ZIndex = Materials.Z.Structure,
        Parent = page,
    }, scope) :: ScrollingFrame
    library:RegisterProperty(scroll, { ScrollBarImageColor3 = "Overlay.ScrollBar" }, scope)

    -- The canvas's margins, declared as padding rather than added to a height
    -- by hand. AutomaticCanvasSize already accounts for UIPadding, so each
    -- margin is stated once and cannot be double counted.
    --
    -- The side and top gutters are one pixel: a card's border is a stroke, a
    -- stroke draws outside the frame it belongs to, and a card sitting flush
    -- against this frame's edge would have that side of its border clipped off.
    library:Create("UIPadding", {
        PaddingLeft = UDim.new(0, content.StrokeGutter),
        PaddingRight = UDim.new(0, content.StrokeGutter),
        PaddingTop = UDim.new(0, content.StrokeGutter),
        PaddingBottom = UDim.new(0, content.CanvasBottomPadding),
        Parent = scroll,
    }, scope)

    -- Two columns side by side, each stacking its own groupboxes. The columns
    -- size themselves to their contents; the Columns frame sizes to the TALLER
    -- of the two rather than to their sum, because they sit beside each other,
    -- and the canvas follows it. A groupbox resizing therefore never has to
    -- reach up and correct the page.
    local columns = library:Create("Frame", {
        Name = "Columns",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = scroll,
    }, scope) :: Frame

    local function column(name: string): Frame
        local frame = library:Create("Frame", {
            Name = name,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Size = UDim2.new(0, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            ZIndex = Materials.Z.Structure,
            ClipsDescendants = false,
            Parent = columns,
        }, scope) :: Frame
        library:Create("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, Metrics.Groupbox.Spacing),
            Parent = frame,
        }, scope)
        return frame
    end

    local left, right = column("Left"), column("Right")
    page.Parent = self.PageArea

    local sub: SubTab = setmetatable({
        Destroyed = false,
        Shell = self,
        Tab = tab,
        Name = definition.Name,
        Order = order,
        Visible = definition.Visible ~= false,
        Disabled = definition.Disabled == true,
        Active = false,
        Hovered = false,
        Implicit = implicit,
        Label = label,
        HeaderButton = headerButton,
        Underline = underline,
        HeaderWidth = labelWidth,
        Page = page,
        Content = scroll,
        Columns = columns,
        Left = left,
        Right = right,
        Groupboxes = {},
        Scope = scope,
        _LeftOrder = 0,
        _RightOrder = 0,
    }, SubTab)

    headerButton.Visible = sub.Visible and not implicit
    sub:_ApplyWidth(self:_ColumnArea())

    library:Connect(headerButton.MouseEnter, function()
        if sub.Disabled then
            return
        end
        sub.Hovered = true
        sub:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(headerButton.MouseLeave, function()
        sub.Hovered = false
        sub:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(headerButton.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if sub.Disabled or not sub.Visible then
            return
        end
        tab:SelectSubTab(sub.Name)
    end, scope)

    scope:Add(function()
        sub.Destroyed = true
        table.clear(sub.Groupboxes)
        local index = table.find(tab.SubTabs, sub)
        if index then
            table.remove(tab.SubTabs, index)
        end
        if tab.ActiveSub == sub then
            tab.ActiveSub = nil
        end
    end)

    table.insert(tab.SubTabs, sub)
    sub:_Refresh(0)
    tab:_LayoutHeader()
    if tab.ActiveSub == nil then
        tab:_SelectFirstValidSub()
    end
    return sub
end

--// Tab construction ---------------------------------------------------------

function Shell._BuildTab(self: Shell, definition: TabDefinition): Tab
    local library = self.Library
    local scope = library:CreateScope(self.Resources)
    local dock = Metrics.Dock
    local header = Metrics.HeaderTabs

    self._Order += 1
    local order = self._Order
    local index = #self.Tabs + 1
    local centre = Metrics:DockItemCentre(index)

    --// Dock presentation ----------------------------------------------------
    -- Every item is placed by its own centre rather than by a list layout. The
    -- pitch is a metric, the container is smaller than the pitch, and the
    -- indicator is positioned against the dock's left inner edge -- so the three
    -- pieces stay aligned to each other at any dock width.
    local surface = Materials.CreateSurface(self.Context, {
        Name = definition.Name .. "DockItem",
        Kind = "DockItemActive",
        Parent = self.DockStack,
        Scope = scope,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, centre),
        Size = UDim2.fromOffset(dock.ItemSize, dock.ItemSize),
        Radius = Metrics.Radius.DockItem,
        ZIndex = Materials.Z.Structure,
    })
    surface.Instance.BackgroundTransparency = 1

    local icon: GuiObject
    if definition.Icon and definition.Icon ~= "" then
        icon = library:Create("ImageLabel", {
            Name = "Icon",
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Image = definition.Icon,
            ScaleType = Enum.ScaleType.Fit,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(dock.IconSize, dock.IconSize),
            ZIndex = Materials.Z.Text,
            Parent = surface.Instance,
        }, scope) :: GuiObject
    else
        icon = self.Typography:Create("DockGlyph", {
            Name = "Icon",
            Text = string.upper(string.sub(definition.Name, 1, 1)),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(dock.ItemSize, dock.ItemSize),
            TextXAlignment = Enum.TextXAlignment.Center,
            TextYAlignment = Enum.TextYAlignment.Center,
            ZIndex = Materials.Z.Text,
            Parent = surface.Instance,
        }, scope) :: GuiObject
    end

    local indicator = library:Create("Frame", {
        Name = definition.Name .. "Indicator",
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, dock.IndicatorInset, 0, centre),
        Size = UDim2.fromOffset(dock.IndicatorWidth, dock.IndicatorHeight),
        ZIndex = Materials.Z.Edge,
        Parent = self.DockStack,
    }, scope) :: Frame
    library:Create("UICorner", {
        CornerRadius = UDim.new(0, math.floor(dock.IndicatorWidth / 2)),
        Parent = indicator,
    }, scope)
    library:RegisterProperty(indicator, { BackgroundColor3 = "Accent.Base" }, scope)

    -- The hit area is the full pitch, not the visible container: the dock is
    -- narrow, and a 30 pixel target inside a 40 pixel row leaves dead bands
    -- between items for no reason.
    local dockHit = library:Create("TextButton", {
        Name = definition.Name .. "DockHit",
        Text = "",
        AutoButtonColor = false,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0, centre),
        Size = UDim2.new(1, 0, 0, dock.ItemPitch),
        ZIndex = Materials.Z.Overlay,
        Parent = self.DockStack,
    }, scope) :: TextButton

    --// This section's sub-tab strip ------------------------------------------
    -- One strip per section, all stacked in the same header slot and only one
    -- of them visible. Switching sections does not rebuild labels or remeasure
    -- text; it changes which strip is shown.
    local strip = library:Create("Frame", {
        Name = definition.Name .. "Strip",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(header.Inset, 0),
        Size = UDim2.new(1, -header.Inset, 1, 0),
        LayoutOrder = order,
        Visible = false,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Header,
    }, scope) :: Frame
    library:Create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, header.Gap),
        HorizontalAlignment = if header.Alignment >= 1
            then Enum.HorizontalAlignment.Right
            elseif header.Alignment > 0 then Enum.HorizontalAlignment.Center
            else Enum.HorizontalAlignment.Left,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        Parent = strip,
    }, scope)

    local tab: Tab = setmetatable({
        Destroyed = false,
        Shell = self,
        Name = definition.Name,
        Subtitle = definition.Subtitle or "",
        Order = order,
        Visible = true,
        Disabled = false,
        Active = false,
        Hovered = false,
        Surface = surface,
        Icon = icon,
        Indicator = indicator,
        DockHit = dockHit,
        Strip = strip,
        SubTabs = {},
        ActiveSub = nil,
        Groupboxes = {},
        Scope = scope,
        _SubOrder = 0,
    }, Tab)

    -- The dock icon drives one selection path. It does not know how to select a
    -- section; it asks the shell, which is why hidden, disabled and destroyed
    -- sections resolve identically.
    library:Connect(dockHit.MouseEnter, function()
        if tab.Disabled then
            return
        end
        tab.Hovered = true
        tab:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(dockHit.MouseLeave, function()
        tab.Hovered = false
        tab:_Refresh(Metrics.Motion.Hover)
    end, scope)
    library:Connect(dockHit.InputBegan, function(input: InputObject)
        if not library:IsPrimaryPointer(input) or not library:IsInputBegin(input) then
            return
        end
        if tab.Disabled or not tab.Visible then
            return
        end
        self:SelectTab(tab.Name)
    end, scope)

    scope:Add(function()
        tab.Destroyed = true
        table.clear(tab.Groupboxes)
        table.clear(tab.SubTabs)
        local at = table.find(self.Tabs, tab)
        if at then
            table.remove(self.Tabs, at)
        end
        if self.Active == tab then
            self.Active = nil
        end
    end)

    table.insert(self.Tabs, tab)
    tab:_Refresh(0)

    for _, declared in definition.SubTabs or {} do
        tab:AddSubTab(declared)
    end

    return tab
end

function Shell.new(library: any, options: Options?): Shell
    library:_AssertLive()
    assert(library.Root, "Mount the library before creating the shell")

    local config: Options = options or {}
    local resources = library:CreateScope()
    local typography = Typography.new(library, resources)
    local host = Controls.NewHost(library, resources, typography)

    local self: Shell = setmetatable({
        Destroyed = false,
        Resources = resources,
        Library = library,
        Metrics = Metrics,
        Tokens = Tokens,
        Typography = typography,
        Host = host,
        Context = host.Context,
        HostFrame = nil :: any,
        Window = nil :: any,
        Dock = nil :: any,
        DockStack = nil :: any,
        Content = nil :: any,
        Body = nil :: any,
        Header = nil :: any,
        HeaderRule = nil :: any,
        TabList = nil,
        ShowHeaderTabs = config.HeaderTabs ~= false,
        Tabs = {},
        Active = nil,
        LogicalSize = Vector2.new(Metrics.Window.Width, Metrics.Window.Height),
        _Order = 0,
        _DragScope = nil,
        _HeaderHeight = 0,
    }, Shell)

    -- Sibling ZIndex keeps the roles in Materials.Z meaningful inside each
    -- parent rather than competing across the whole ScreenGui.
    local gui = library.ScreenGui
    if gui then
        library:_SetProperty(gui, "ZIndexBehavior", Enum.ZIndexBehavior.Sibling)
        library:_SetProperty(gui, "DisplayOrder", 100)
        library:_SetProperty(gui, "IgnoreGuiInset", true)
    end

    library:SetSource(Tokens.Source)

    local hostFrame = createHostFrame(library, resources)
    self.HostFrame = hostFrame

    self.Window = Materials.CreateSurface(self.Context, {
        Name = "Shell",
        Kind = "Shell",
        Parent = hostFrame,
        Scope = resources,
        Size = UDim2.fromScale(1, 1),
        Radius = Metrics.Radius.Window,
        ZIndex = Materials.Z.Base,
    })

    local window = Metrics.Window
    local dock = Metrics.Dock
    local content = Metrics.Content
    local originX = Metrics:ContentOriginX()

    -- The dock is a panel inset from the window edge on three sides, not a wall
    -- bolted to it. That inset is what makes the shell read as one rounded body
    -- with a strip carved into it rather than two frames pushed together.
    self.Dock = Materials.CreateSurface(self.Context, {
        Name = "Dock",
        Kind = "Dock",
        Parent = self.Window.Instance,
        Scope = resources,
        Position = UDim2.fromOffset(window.OuterPadding, window.OuterPadding),
        Size = UDim2.new(0, dock.Width, 1, -window.OuterPadding * 2),
        Radius = Metrics.Radius.Dock,
        ZIndex = Materials.Z.Structure,
    })

    -- The content region takes the rest of the window and stays flush with it:
    -- only the dock and the cards rise off the page.
    self.Content = Materials.CreateSurface(self.Context, {
        Name = "Content",
        Kind = "Content",
        Parent = self.Window.Instance,
        Scope = resources,
        Position = UDim2.fromOffset(originX, 0),
        Size = UDim2.new(1, -originX, 1, 0),
        ZIndex = Materials.Z.Structure,
    })
    self.Content.Instance.BackgroundTransparency = 1

    --// Dock interior
    self:_BuildMascot(self.Dock.Instance :: Frame, config.Mascot, config.Title or "ZEDLIB")

    self.DockStack = library:Create("Frame", {
        Name = "Navigation",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Dock.Instance,
    }, resources) :: Frame

    --// Content interior
    self.Body = library:Create("Frame", {
        Name = "Inner",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(content.PaddingLeft, content.PaddingTop),
        Size = UDim2.new(
            1,
            -(content.PaddingLeft + content.PaddingRight),
            1,
            -(content.PaddingTop + content.PaddingBottom)
        ),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Content.Instance,
    }, resources) :: Frame

    -- The sub-tab strip. One slot, holding one strip per section; the active
    -- section's is the only visible one, so the header is secondary navigation
    -- that belongs to the open page set rather than a bar over the window.
    --
    -- The strip closes with a full-width hairline. The active accent underline
    -- is drawn on that same line, which is what makes the row read as the top
    -- edge of the page under it instead of a free-floating tab bar.
    local headerTabs = Metrics.HeaderTabs

    self.Header = library:Create("Frame", {
        Name = "Header",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, headerTabs.Height),
        Visible = false,
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Body,
    }, resources) :: Frame

    self.HeaderRule = library:Create("Frame", {
        Name = "Rule",
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, headerTabs.RuleThickness),
        ZIndex = Materials.Z.Edge,
        Parent = self.Header,
    }, resources) :: Frame
    library:RegisterProperty(self.HeaderRule, { BackgroundColor3 = "Border.Divider" }, resources)

    -- Pages sit under the strip. One frame, repositioned when the header's
    -- height changes, so a page never has to know whether a strip is shown.
    self.PageArea = library:Create("Frame", {
        Name = "Pages",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        ZIndex = Materials.Z.Structure,
        ClipsDescendants = false,
        Parent = self.Body,
    }, resources) :: Frame

    self._HeaderHeight = content.PaddingTop

    --// Interaction ownership: dedicated strips, above everything beneath them,
    -- covering only regions that contain no controls. The mascot band at the top
    -- of the dock sits above the first icon, and the header strip's gutter is
    -- clear of every tab label, so neither handle can swallow a click that was
    -- meant for navigation.
    local mascotHandle = library:Create("Frame", {
        Name = "MascotDrag",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(window.OuterPadding, window.OuterPadding),
        Size = UDim2.fromOffset(dock.Width, dock.PaddingTop + dock.MascotSize),
        ZIndex = Materials.Z.Overlay,
        Active = true,
        Parent = self.Window.Instance,
    }, resources) :: Frame

    -- The drag strip covers the content's top padding band only. It stops
    -- short of the sub-tab labels rather than reaching under them, so it can
    -- never swallow a click meant for navigation, and it does not need to
    -- follow the header's height when a section without a strip is open.
    local headerHandle = library:Create("Frame", {
        Name = "HeaderDrag",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(originX, 0),
        Size = UDim2.new(1, -originX, 0, content.PaddingTop),
        ZIndex = Materials.Z.Base,
        Active = true,
        Parent = self.Window.Instance,
    }, resources) :: Frame

    self:_BindDrag(mascotHandle)
    self:_BindDrag(headerHandle)

    local handleSize = Metrics.Window.ResizeHandle
    local resizeHandle = library:Create("Frame", {
        Name = "ResizeHandle",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromScale(1, 1),
        Size = UDim2.fromOffset(handleSize, handleSize),
        ZIndex = Materials.Z.Overlay,
        Active = true,
        Parent = self.Window.Instance,
    }, resources) :: Frame

    -- Two short strokes rather than an icon: it reads as a grip at every scale.
    for index = 1, 2 do
        local grip = library:Create("Frame", {
            Name = "Grip" .. tostring(index),
            BorderSizePixel = 0,
            BackgroundTransparency = Theme.Alpha.ResizeGrip,
            AnchorPoint = Vector2.new(1, 1),
            Position = UDim2.new(1, -window.GripInset, 1, -(window.GripInset + (index - 1) * window.GripPitch)),
            Size = UDim2.fromOffset(handleSize - window.GripTrim - (index - 1) * window.GripStep, window.GripThickness),
            Rotation = -45,
            ZIndex = Materials.Z.Overlay,
            Parent = resizeHandle,
        }, resources) :: Frame
        library:RegisterProperty(grip, { BackgroundColor3 = "Text.Disabled" }, resources)
    end

    self:_BindResize(resizeHandle)

    for _, definition in config.Tabs or DEFAULT_TABS do
        self:_BuildTab(definition)
    end

    self:_LayoutDock()
    self:_SelectFirstValid()
    self:_ApplyHeader()

    -- Parented last, once the window is fully built and styled: it appears in
    -- its final state rather than as a frame that fills in.
    hostFrame.Parent = library.Root
    assert(hostFrame.Parent ~= nil, "Window failed to parent into the library root")

    library.Window = self :: any
    local dynamicHost: any = host
    dynamicHost.Window, dynamicHost.ToggleKey = self, "RightShift"
    KeyPicker.Manager(host)
    library.Notify = function(_library: any, notification: any)
        return UX.Notify(host, notification)
    end
    resources:Add(function()
        self.Destroyed = true
        if library.Window == self then
            library.Window = nil
        end
    end)

    return self
end

--// Dock geometry ------------------------------------------------------------

-- Places every visible tab on the dock's pitch, in order. Hidden tabs are
-- skipped rather than left as a gap, which is what a list layout would do for
-- the header strip -- the dock places by centre, so it does the same thing here
-- explicitly instead of leaving a hole where a hidden section used to be.
function Shell._LayoutDock(self: Shell)
    if self.Destroyed then
        return
    end
    local ordered = {}
    for _, tab in self.Tabs do
        if not tab.Destroyed and tab.Visible then
            table.insert(ordered, tab)
        end
    end
    table.sort(ordered, function(a, b)
        if a.Order == b.Order then
            return a.Name < b.Name
        end
        return a.Order < b.Order
    end)
    for index, tab in ordered do
        tab:_PlaceDock(Metrics:DockItemCentre(index))
    end
end

--// Content geometry ---------------------------------------------------------

-- The width available to the two columns, derived from the window's logical size
-- rather than read back from AbsoluteSize. Absolute geometry lags a frame behind
-- a resize, and wrapped text measured against last frame's width is exactly the
-- kind of drift this avoids.
function Shell._ColumnArea(self: Shell): number
    local content = Metrics.Content
    local inner = self.LogicalSize.X - Metrics:ContentOriginX() - (content.PaddingLeft + content.PaddingRight)
    -- Two deductions, both real estate the columns genuinely do not have. The
    -- scroll bar draws over the content rather than in an inset gutter, so the
    -- columns keep clear of it instead of letting it sit on a card's border;
    -- and the scroll frame reserves a one pixel lane on each side for the
    -- border strokes themselves.
    return math.max(0, inner - (content.ScrollBarThickness + content.ScrollGutter) - content.StrokeGutter * 2)
end

-- One width, published to every page. Called once at construction and once per
-- resize step, and never from inside a groupbox.
function Shell._ApplyContentWidth(self: Shell)
    local available = self:_ColumnArea()
    for _, tab in self.Tabs do
        if not tab.Destroyed then
            tab:_ApplyWidth(available)
        end
    end
end

function Shell.SetSize(self: Shell, width: number, height: number): Shell
    assert(not self.Destroyed, "Shell is destroyed")
    local window = Metrics.Window
    local resolved = Vector2.new(
        math.clamp(math.round(width), window.MinWidth, window.MaxWidth),
        math.clamp(math.round(height), window.MinHeight, window.MaxHeight)
    )
    self.LogicalSize = resolved
    self.HostFrame.Size = UDim2.fromOffset(resolved.X, resolved.Y)
    self:_ApplyContentWidth()
    return self
end

--// Header geometry ----------------------------------------------------------

-- The one place that decides how tall the header is and where the page area
-- starts. Every path that can change the answer -- selecting a section, adding
-- or hiding a sub-tab, destroying one -- routes here rather than writing to
-- PageArea itself, so the two can never disagree.
--
-- The height is derived, never guessed: a section with a strip reserves the
-- strip and the gap below it, and a section without one reserves nothing and
-- gives the page the space back.
function Shell._ApplyHeader(self: Shell)
    if self.Destroyed then
        return
    end
    local content = Metrics.Content
    local active = self.Active
    local shows = active ~= nil and not active.Destroyed and active:ShowsStrip()

    -- Only the open section's strip is present. Switching sections swaps which
    -- one is shown; nothing is measured or rebuilt.
    for _, tab in self.Tabs do
        if not tab.Destroyed then
            tab.Strip.Visible = shows and tab == active
        end
    end

    local height = if shows then Metrics.HeaderTabs.Height + content.HeaderToBody else 0
    self.Header.Visible = shows
    self.PageArea.Position = UDim2.fromOffset(0, height)
    self.PageArea.Size = UDim2.new(1, 0, 1, -height)
    self._HeaderHeight = content.PaddingTop + height
end

--// Tab selection ------------------------------------------------------------

function Shell.GetTab(self: Shell, name: string): Tab?
    for _, tab in self.Tabs do
        if tab.Name == name then
            return tab
        end
    end
    return nil
end

function Shell.AddTab(self: Shell, definition: TabDefinition): Tab
    assert(not self.Destroyed, "Shell is destroyed")
    assert(self:GetTab(definition.Name) == nil, "Duplicate tab: " .. definition.Name)
    local tab = self:_BuildTab(definition)
    self:_LayoutDock()
    if not self.Active then
        self:_Activate(tab)
    end
    return tab
end

local function selectable(tab: Tab): boolean
    return not tab.Destroyed and tab.Visible and not tab.Disabled
end

-- The one place a tab becomes active. Every entry point funnels through here, so
-- there is no second copy of "hide the old page, show the new one".
-- Opening a section does three things in a fixed order: it closes the previous
-- one's page, it opens this one's, and it re-measures the header. The order
-- matters -- the header's height depends on the section that is open, and the
-- page area's height depends on the header -- so nothing else is allowed to
-- write to either.
function Shell._Activate(self: Shell, tab: Tab?)
    local previous = self.Active
    if previous == tab then
        return
    end

    if previous and not previous.Destroyed then
        previous.Active = false
        previous.Strip.Visible = false
        local page = previous.ActiveSub
        if page and not page.Destroyed then
            page.Page.Visible = false
        end
        previous:_Refresh(Metrics.Motion.Select)
    end

    self.Active = tab
    if tab then
        tab.Active = true
        -- A section reopens on the page it was left on, not on its first one.
        if tab.ActiveSub == nil or not tab.ActiveSub.Visible or tab.ActiveSub.Disabled then
            tab:_SelectFirstValidSub()
        end
        local page = tab.ActiveSub
        if page and not page.Destroyed then
            page.Page.Visible = true
        end
        tab:_Refresh(Metrics.Motion.Select)
    end
    self.TabList = if tab then tab.Strip else nil
    self:_ApplyHeader()
end

function Shell.SelectTab(self: Shell, name: string): Tab?
    assert(not self.Destroyed, "Shell is destroyed")
    local tab = self:GetTab(name)
    assert(tab, "Unknown tab: " .. tostring(name))
    local target = tab :: Tab
    if not selectable(target) then
        return nil
    end
    if self.Active == target then
        return target
    end
    -- Leaving a page invalidates anything that belonged to it: an open popup
    -- from the old page and any keyboard focus inside it are both released.
    self.Host:BeginInteraction()
    self:_Activate(target)
    return target
end

-- Opens a page inside a section, naming both. The two-argument form is the
-- honest spelling of what nested navigation is; `Tab:SelectSubTab` is the same
-- operation once the section is already open.
function Shell.SelectSubTab(self: Shell, tabName: string, subTabName: string): SubTab?
    assert(not self.Destroyed, "Shell is destroyed")
    local tab = self:SelectTab(tabName)
    if not tab then
        return nil
    end
    return tab:SelectSubTab(subTabName)
end

-- Picks the nearest selectable tab: forward from `from` in order, then backward.
-- Falls back to nothing selected only when no tab can be selected at all.
function Shell._SelectNearest(self: Shell, from: Tab?)
    local ordered = table.clone(self.Tabs)
    table.sort(ordered, function(a, b)
        return a.Order < b.Order
    end)

    local start = if from then table.find(ordered, from) else nil
    if start then
        for index = start + 1, #ordered do
            if selectable(ordered[index]) then
                self:_Activate(ordered[index])
                return
            end
        end
        for index = start - 1, 1, -1 do
            if selectable(ordered[index]) then
                self:_Activate(ordered[index])
                return
            end
        end
    end

    for _, tab in ordered do
        if selectable(tab) then
            self:_Activate(tab)
            return
        end
    end
    self:_Activate(nil)
end

function Shell._SelectFirstValid(self: Shell)
    self:_SelectNearest(nil)
end

-- Called whenever a tab's visibility or enabled state changes. The content area
-- must never keep pointing at a tab that can no longer be shown.
function Shell._EnsureValidSelection(self: Shell, changed: Tab)
    if self.Destroyed then
        return
    end
    local active = self.Active
    if active == nil then
        if selectable(changed) then
            self:_Activate(changed)
        end
        return
    end
    if selectable(active) then
        return
    end
    self.Host:BeginInteraction()
    self:_SelectNearest(active)
end

--// Teardown -----------------------------------------------------------------

function Shell.Destroy(self: Shell)
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    self.Host:BeginInteraction()
    self.Active = nil
    table.clear(self.Tabs)
    self.Resources:Destroy()
end

function Shell.SetVisible(self: any, visible: boolean): any
    if self.Destroyed then
        return self
    end
    if visible == false then
        self.Host:BeginInteraction()
        if self._DragScope then
            self._DragScope:Destroy()
            self._DragScope = nil
        end
        if self.Library.ActiveModal then
            self.Library.ActiveModal:Close()
        end
        for _, tab in self.Tabs do
            for _, box in tab.Groupboxes do
                box:Deactivate()
            end
        end
        self.Host.Keybinds:Reset()
    end
    self.HostFrame.Visible = visible ~= false
    self.Visible = visible ~= false
    return self
end
function Shell.Toggle(self: any): any
    return self:SetVisible(not self.HostFrame.Visible)
end
function Shell.Show(self: any): any
    return self:SetVisible(true)
end
function Shell.Hide(self: any): any
    return self:SetVisible(false)
end
function Shell.SetToggleKey(self: any, key: string)
    self.Host.ToggleKey = key
end
function Shell.Notify(self: any, options: any): any
    return UX.Notify(self.Host, options)
end

-- Remeasures every page from scratch.
--
-- Width-driven layout is cached at each level: a groupbox that is told the width
-- it already has does nothing, and so does a wrapped label. That is the right
-- behaviour during a drag-resize, and the wrong behaviour when the thing that
-- changed is text metrics rather than width, which is what a font change is.
-- Invalidating the caches first makes the same one-way layout pass produce the
-- new heights without any control being rebuilt.
function Shell.Refresh(self: any): any
    if self.Destroyed then
        return self
    end
    for _, tab in self.Tabs do
        if not tab.Destroyed then
            for _, box in tab.Groupboxes do
                if not box.Destroyed then
                    box.Width = -1
                    local function invalidate(container: any)
                        for _, element in container.Elements do
                            if not element.Destroyed then
                                if element._Width ~= nil then
                                    element._Width = -1
                                end
                                if element.Elements then
                                    invalidate(element)
                                end
                            end
                        end
                    end
                    invalidate(box)
                end
            end
        end
    end
    self:_ApplyContentWidth()
    return self
end
function Shell.AddDialog(self: any, id: string, config: any): any
    return UX.Dialog(self, id, config)
end
function Shell.Search(self: any, query: string): any
    return UX.Search(self, query)
end
function Shell.AddSearch(self: any, container: any): any
    return UX.SearchBox(self, container)
end
function Shell.AddKeybindList(self: any, container: any, options: any): any
    local config = options or {}
    local label = container:AddLabel({ Text = "Keybinds", Wrap = true })
    local function update()
        if label.Destroyed then
            return
        end
        local lines = { "Keybinds" }
        for _, key in self.Host.Keybinds.Items do
            if
                not key.Destroyed
                and (not config.HideUnused or key.Value ~= "None")
                and (not config.ActiveOnly or key.Active)
            then
                table.insert(
                    lines,
                    (key.Text ~= "" and key.Text or key.Value) .. "  " .. key.Value .. "  [" .. key.Mode .. "]"
                )
            end
        end
        label:SetText(table.concat(lines, "\n"))
    end
    label.Resources:Add(self.Host.Keybinds.Changed:Connect(update))
    update()
    return label
end

return Shell
end)()

local Module30 = (function()
--!strict
local Library = Module7
local Shell = Module29

function Library.CreateWindow(self: Library.Library, options: Shell.Options?): Shell.Shell
    return Shell.new(self, options)
end

return Library
end)()

return Module30
