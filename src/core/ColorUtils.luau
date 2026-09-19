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
