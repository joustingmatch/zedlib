--!strict
-- Shared theme serialization and reserved control IDs.
local ThemeData = {}

ThemeData.OptionIds = {
    "BackgroundColor",
    "MainColor",
    "AccentColor",
    "OutlineColor",
    "FontColor",
    "FontFace",
    "ThemeManager_ThemeList",
    "ThemeManager_CustomThemeList",
    "ThemeManager_CustomThemeName",
    "ThemeManager_ThemeJSON",
}

--// Colour conversion ---------------------------------------------------------

local function toHex(color: Color3): string
    return string.format(
        "#%02X%02X%02X",
        math.round(math.clamp(color.R, 0, 1) * 255),
        math.round(math.clamp(color.G, 0, 1) * 255),
        math.round(math.clamp(color.B, 0, 1) * 255)
    )
end

-- Accepts what a theme file or a pasted value can plausibly contain: a Color3
-- already, or a hex string with or without its hash. Anything else is nil, and
-- the caller reports which key was wrong rather than substituting a colour.
local function toColor(value: unknown): Color3?
    if typeof(value) == "Color3" then
        return value :: Color3
    end
    if type(value) ~= "string" then
        return nil
    end
    local hex = string.match(value, "^%s*#?(%x%x%x%x%x%x)%s*$")
    if not hex then
        return nil
    end
    return Color3.fromRGB(
        tonumber(string.sub(hex, 1, 2), 16) :: number,
        tonumber(string.sub(hex, 3, 4), 16) :: number,
        tonumber(string.sub(hex, 5, 6), 16) :: number
    )
end

ThemeData.ToHex = toHex
ThemeData.ToColor = toColor

return ThemeData
