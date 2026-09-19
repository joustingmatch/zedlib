--!strict
local ColorUtils = require(script.Parent.ColorUtils)

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
