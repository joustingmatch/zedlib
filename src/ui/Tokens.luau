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
