-- Theme foundation regressions: colour mathematics, the semantic resolver, the
-- property registry, and the contrast engine.
--
-- These exist because the theme system has not been built yet. Every one of
-- them states a property that a future ThemeManager will depend on, so that
-- building it is a matter of adding a UI rather than discovering that the
-- machinery underneath does not hold.

local passed = 0
local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    assert(ok, name .. ": " .. tostring(message))
    passed += 1
    print("PASS " .. name)
end

local function expectError(callback)
    assert(not pcall(callback), "Expected an error")
end

local Theme = ThemeModule
local ColorUtils = ColorUtilsModule
local Tokens = UIModule.Tokens

local function approx(a, b, tolerance)
    return math.abs(a - b) <= (tolerance or 1e-6)
end

local function sameColor(a, b, tolerance)
    return approx(a.R, b.R, tolerance) and approx(a.G, b.G, tolerance) and approx(a.B, b.B, tolerance)
end

local function rgb(r, g, b)
    return Color3.fromRGB(r, g, b)
end

local function mount()
    local library = LibraryModule.new({ OwnershipKey = "theme-spec" }):Initialize():Mount()
    library.ScreenGui.AbsoluteSize = Vector2.new(1000, 800)
    return library
end

--// Colour mathematics -------------------------------------------------------

test("relative luminance linearises sRGB rather than averaging channels", function()
    local white = ColorUtils.RelativeLuminance(Color3.new(1, 1, 1))
    local black = ColorUtils.RelativeLuminance(Color3.new(0, 0, 0))
    assert(approx(white, 1, 1e-6) and approx(black, 0, 1e-6))

    -- Mid grey is the case that separates a real implementation from a fake
    -- one: its encoded value is 0.5, but it emits about 21% of white's light.
    -- Anything that reports ~0.5 here is averaging channels, not linearising.
    local mid = ColorUtils.RelativeLuminance(Color3.new(0.5, 0.5, 0.5))
    assert(mid > 0.21 and mid < 0.22, "mid grey luminance is ~0.2140, got " .. tostring(mid))

    -- Green carries most of the perceived brightness, blue almost none.
    local green = ColorUtils.RelativeLuminance(Color3.new(0, 1, 0))
    local red = ColorUtils.RelativeLuminance(Color3.new(1, 0, 0))
    local blue = ColorUtils.RelativeLuminance(Color3.new(0, 0, 1))
    assert(green > red and red > blue)
end)

test("contrast ratio matches the WCAG definition and is symmetric", function()
    local white, black = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
    assert(approx(ColorUtils.ContrastRatio(white, black), 21, 1e-6))
    assert(approx(ColorUtils.ContrastRatio(black, white), 21, 1e-6))
    assert(approx(ColorUtils.ContrastRatio(white, white), 1, 1e-6))
    assert(approx(ColorUtils.ContrastRatio(black, black), 1, 1e-6))

    -- Similar greys sit near the bottom of the range; this is the case a
    -- naive RGB-distance check gets badly wrong.
    local grayA, grayB = rgb(120, 120, 120), rgb(130, 130, 130)
    local similar = ColorUtils.ContrastRatio(grayA, grayB)
    assert(similar > 1 and similar < 1.2, "near greys contrast barely at all")

    assert(ColorUtils.ContrastRatio(white, rgb(30, 30, 30)) > ColorUtils.ContrastRatio(white, rgb(90, 90, 90)))
end)

test("a bright accent takes dark text and a dark accent takes light text", function()
    local white, black = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

    local brightAccent = rgb(250, 204, 21)
    local chosen = ColorUtils.ChooseReadableForeground(brightAccent, white, black)
    assert(sameColor(chosen, black), "a bright yellow accent must not take white text")
    assert(ColorUtils.ContrastRatio(chosen, brightAccent) > ColorUtils.ContrastRatio(white, brightAccent))

    local darkAccent = rgb(40, 30, 120)
    assert(sameColor(ColorUtils.ChooseReadableForeground(darkAccent, white, black), white))

    -- Deterministic: the same accent must always produce the same foreground,
    -- or a control would change its text colour as it is interacted with.
    for _ = 1, 10 do
        assert(sameColor(ColorUtils.ChooseReadableForeground(brightAccent, white, black), black))
    end
end)

test("compositing is deterministic and distinct from mixing a real colour", function()
    local foreground, backdrop = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

    -- Transparency is Roblox's convention: 0 opaque, 1 invisible.
    assert(sameColor(ColorUtils.Composite(foreground, backdrop, 0), foreground))
    assert(sameColor(ColorUtils.Composite(foreground, backdrop, 1), backdrop))

    local half = ColorUtils.Composite(foreground, backdrop, 0.5)
    assert(sameColor(half, Color3.new(0.5, 0.5, 0.5)))
    for _ = 1, 5 do
        assert(sameColor(ColorUtils.Composite(foreground, backdrop, 0.5), half))
    end

    -- A translucent foreground does not keep its own raw contrast: white on
    -- black is 21:1, but white at 50% over black is far less.
    local raw = ColorUtils.ContrastRatio(foreground, backdrop)
    local effective = ColorUtils.ContrastRatio(half, backdrop)
    assert(raw > 20 and effective < 6, "compositing must change the measured contrast")
end)

--// Resolver -----------------------------------------------------------------

test("every canonical role resolves to a Color3 and resolution is pure", function()
    local palette = Theme.Resolve(Tokens.Source)
    assert(#Theme.RoleNames > 0)
    for _, role in Theme.RoleNames do
        assert(typeof(palette[role]) == "Color3", role .. " did not resolve")
    end
    local again = Theme.Resolve(Tokens.Source)
    for _, role in Theme.RoleNames do
        assert(sameColor(palette[role], again[role]), role .. " is not deterministic")
    end
end)

test("an unknown role fails loudly and suggests the intended one", function()
    expectError(function()
        Theme.ResolveRole(Tokens.Source, "Text.Primray")
    end)
    assert(Theme.SuggestRole("Text.Primray") == "Text.Primary")
    assert(string.find(Theme.DescribeUnknownRole("Text.Primray"), "Text.Primary") ~= nil)
    assert(not Theme.IsRole("Text.Nonsense"))
    assert(Theme.IsRole("Text.Primary"))

    local library = mount()
    expectError(function()
        library.Theme:Get("Surface.Cavnas")
    end)
    assert(typeof(library.Theme:Get("Surface.Canvas")) == "Color3")
    library:Unload()
end)

test("destructive meaning never follows the accent", function()
    local source = table.clone(Tokens.Source)
    source.AccentColor = rgb(40, 220, 90)
    local palette = Theme.Resolve(source)
    assert(sameColor(palette["Destructive.Base"], Tokens.Source.DestructiveColor))
    assert(sameColor(palette["Text.Destructive"], Tokens.Source.DestructiveColor))
    assert(not sameColor(palette["Destructive.Base"], source.AccentColor))
    -- Accent roles do move, which is what makes the previous assertions mean
    -- something.
    assert(sameColor(palette["Accent.Base"], source.AccentColor))
end)

test("the shipped source resolves to the shell palette, exactly", function()
    -- The palette the interface actually paints, pinned. These are not
    -- hand-authored colours: each is derived from the nine source values in
    -- Tokens through Theme's ramps, and the point of pinning them is that a
    -- change to a ramp or a source value is a deliberate decision about the
    -- whole interface rather than something that slips through unnoticed.
    --
    -- The surface ladder is the load-bearing part. Canvas 21 is the window,
    -- Primary 23 the dock and the cards, Sunken 34 every recessed field, and
    -- Border.Normal 41 the hairline that separates them -- a deliberately
    -- shallow ramp, because the shell carries its hierarchy in borders, radius
    -- and spacing rather than in value.
    local PALETTE = {
        ["Surface.Canvas"] = rgb(21, 21, 21),
        ["Surface.Primary"] = rgb(23, 23, 23),
        ["Surface.Popup"] = rgb(23, 23, 23),
        ["Surface.Sunken"] = rgb(34, 34, 34),
        ["Surface.Raised"] = rgb(37, 37, 37),
        ["Surface.Disabled"] = rgb(22, 22, 22),
        ["Interaction.Hover"] = rgb(33, 33, 33),
        ["Interaction.Pressed"] = rgb(40, 40, 40),
        ["Interaction.Selected"] = rgb(35, 39, 57),
        ["Accent.Base"] = rgb(105, 132, 250),
        ["Accent.Muted"] = rgb(59, 75, 141),
        ["Text.Accent"] = rgb(169, 184, 252),
        ["Text.OnAccent"] = rgb(0, 0, 0),
        ["Destructive.Base"] = rgb(224, 106, 106),
        ["Destructive.Muted"] = rgb(133, 63, 63),
        ["Text.Primary"] = rgb(228, 228, 228),
        ["Text.Secondary"] = rgb(155, 155, 155),
        ["Text.Muted"] = rgb(110, 110, 110),
        ["Text.Disabled"] = rgb(86, 86, 86),
        ["Text.Placeholder"] = rgb(93, 93, 93),
        ["Text.Destructive"] = rgb(224, 106, 106),
        ["Border.Normal"] = rgb(41, 41, 41),
        ["Border.Hover"] = rgb(55, 55, 55),
        ["Border.Focused"] = rgb(87, 108, 200),
        ["Border.Disabled"] = rgb(33, 33, 33),
        ["Border.Divider"] = rgb(36, 36, 36),
        ["Border.Destructive"] = rgb(133, 63, 63),
        ["Overlay.ScrollBar"] = rgb(59, 59, 59),
        ["Overlay.Shadow"] = Color3.new(0, 0, 0),
        ["Overlay.Highlight"] = Color3.new(1, 1, 1),
    }
    local palette = Theme.Resolve(Tokens.Source)
    -- One part in 255 per channel: these are the derived values, so anything
    -- beyond rounding means a ramp moved.
    local tolerance = 1 / 255 + 1e-6
    local worst = 0
    local covered = 0
    for role, expected in PALETTE do
        local actual = palette[role]
        assert(actual, role .. " is missing from the palette")
        for _, channel in { "R", "G", "B" } do
            worst = math.max(worst, math.abs(actual[channel] - expected[channel]))
        end
        assert(sameColor(actual, expected, tolerance), role .. " drifted from its pinned value")
        covered += 1
    end
    assert(worst * 255 < 2)

    -- Every role is pinned, so a new one cannot be added without a decision
    -- about what colour it is.
    local total = 0
    for _ in Theme.Roles do
        total += 1
    end
    assert(covered == total, string.format("%d roles pinned, %d exist", covered, total))
end)

--// Registry -----------------------------------------------------------------

test("changing the source repaints every registered instance", function()
    local library = mount()
    local frame = library:Create("Frame")
    local label = library:Create("TextLabel")
    local stroke = library:Create("UIStroke")

    library:RegisterProperty(frame, { BackgroundColor3 = "Surface.Primary" })
    library:RegisterProperty(label, { TextColor3 = "Text.Primary" })
    library:RegisterProperty(stroke, { Color = "Border.Normal" })

    assert(sameColor(frame.BackgroundColor3, library.Scheme["Surface.Primary"]))
    assert(sameColor(label.TextColor3, library.Scheme["Text.Primary"]))
    assert(sameColor(stroke.Color, library.Scheme["Border.Normal"]))

    library:SetSource({
        MainColor = rgb(60, 20, 20),
        FontColor = rgb(255, 240, 230),
        OutlineColor = rgb(120, 40, 40),
    })

    assert(sameColor(frame.BackgroundColor3, rgb(60, 20, 20)))
    assert(sameColor(label.TextColor3, rgb(255, 240, 230)))
    assert(sameColor(stroke.Color, rgb(120, 40, 40)))

    -- Derived roles follow their sources without being named in the patch.
    assert(sameColor(frame.BackgroundColor3, library.Theme:Get("Surface.Primary")))
    assert(not sameColor(library.Theme:Get("Surface.Raised"), library.Theme:Get("Surface.Primary")))

    library:Unload()
end)

test("a dynamic resolver reflects component state through every repaint", function()
    local library = mount()
    local control = { Disabled = false }
    local frame = library:Create("Frame")

    library:RegisterProperty(frame, {
        BackgroundColor3 = function()
            return control.Disabled and "Surface.Disabled" or "Surface.Primary"
        end,
    })
    assert(sameColor(frame.BackgroundColor3, library.Theme:Get("Surface.Primary")))

    control.Disabled = true
    library:UpdateColorsUsingRegistry()
    assert(sameColor(frame.BackgroundColor3, library.Theme:Get("Surface.Disabled")))

    -- The role, not the colour, is what was captured: a source change while
    -- disabled must produce the new disabled colour.
    library:SetSource({ BackgroundColor = rgb(10, 0, 30), MainColor = rgb(40, 0, 90) })
    assert(sameColor(frame.BackgroundColor3, library.Theme:Get("Surface.Disabled")))
    assert(not sameColor(frame.BackgroundColor3, library.Theme:Get("Surface.Primary")))

    control.Disabled = false
    library:UpdateColorsUsingRegistry()
    assert(sameColor(frame.BackgroundColor3, library.Theme:Get("Surface.Primary")))

    -- A resolver may also return a finished colour, and a failing one is
    -- reported rather than propagated.
    local fixed = library:Create("Frame")
    library:RegisterProperty(fixed, {
        BackgroundColor3 = function()
            return rgb(1, 2, 3)
        end,
    })
    assert(sameColor(fixed.BackgroundColor3, rgb(1, 2, 3)))

    local broken = library:Create("Frame")
    library:RegisterProperty(broken, {
        BackgroundColor3 = function()
            error("resolver blew up")
        end,
    })
    library:UpdateColorsUsingRegistry()

    library:Unload()
end)

test("destroyed instances leave the registry and never break a repaint", function()
    local library = mount()
    local kept = library:Create("Frame")
    library:RegisterProperty(kept, { BackgroundColor3 = "Surface.Primary" })

    for _ = 1, 25 do
        local doomed = library:Create("Frame")
        library:RegisterProperty(doomed, { BackgroundColor3 = "Surface.Raised" })
        doomed:Destroy()
    end

    assert(library.Theme:GetRegisteredCount() == 1, "dead instances must not accumulate")
    library:SetSource({ MainColor = rgb(9, 9, 9) })
    assert(sameColor(kept.BackgroundColor3, rgb(9, 9, 9)))
    assert(#library.Theme:ValidateRegistry() == 0)

    -- Explicit removal is available and is idempotent.
    library:RemoveFromRegistry(kept)
    library:RemoveFromRegistry(kept)
    assert(library.Theme:GetRegisteredCount() == 0)
    library:SetSource({ MainColor = rgb(3, 3, 3) })

    library:Unload()
end)

--// Contrast engine ----------------------------------------------------------

test("the report identifies the weakest important pair, never an average", function()
    -- Font reads strongly against the canvas and weakly against control
    -- surfaces. Averaging the two would call this palette fine; the report has
    -- to name the weak relationship.
    local source = table.clone(Tokens.Source)
    source.BackgroundColor = rgb(0, 0, 0)
    source.MainColor = rgb(150, 150, 150)
    source.FontColor = rgb(170, 170, 170)

    local palette = Theme.Resolve(source)
    local pairs = {
        { Name = "font on canvas", Foreground = "Text.Primary", Background = "Surface.Canvas", Threshold = 4.5 },
        { Name = "font on main", Foreground = "Text.Primary", Background = "Surface.Primary", Threshold = 4.5 },
    }
    local report = Theme.AnalyzeContrast(palette, pairs)

    assert(not report.Passes)
    assert(report.WorstPair == "font on main", "got " .. tostring(report.WorstPair))
    assert(#report.Failures == 1 and report.Failures[1].Name == "font on main")
    assert(report.Results[1].Ratio > report.Results[2].Ratio)
    assert(report.WorstRatio == report.Results[2].Ratio)

    -- The strong pair is still reported, with its own context.
    assert(report.Results[1].Passes and report.Results[1].Required == 4.5)
end)

test("thresholds are compared unrounded and a translucent pair is composited", function()
    local palette = Theme.Resolve(Tokens.Source)

    -- A pair whose ratio rounds to the threshold but does not reach it must
    -- fail. Constructed by walking a grey until it lands just under 4.5.
    local background = Color3.new(0, 0, 0)
    local marginal = nil
    for step = 0, 255 do
        local candidate = rgb(step, step, step)
        if ColorUtils.ContrastRatio(candidate, background) >= 4.5 then
            marginal = rgb(step - 1, step - 1, step - 1)
            break
        end
    end
    assert(marginal, "expected to find a marginal grey")
    local ratio = ColorUtils.ContrastRatio(marginal, background)
    assert(ratio < 4.5 and ratio > 4.4)
    local custom = { ["Surface.Canvas"] = background, ["Text.Primary"] = marginal }
    local report = Theme.AnalyzeContrast(custom, {
        { Name = "marginal", Foreground = "Text.Primary", Background = "Surface.Canvas", Threshold = 4.5 },
    })
    assert(not report.Passes, "a ratio that only rounds up to the threshold is a failure")

    -- Declaring an alpha lowers the measured ratio, because the foreground is
    -- evaluated as it is actually drawn.
    local opaque = Theme.AnalyzeContrast(palette, {
        { Name = "opaque", Foreground = "Text.Primary", Background = "Surface.Primary", Threshold = 4.5 },
    })
    local faded = Theme.AnalyzeContrast(palette, {
        { Name = "faded", Foreground = "Text.Primary", Background = "Surface.Primary", Threshold = 4.5, Alpha = 0.6 },
    })
    assert(faded.WorstRatio < opaque.WorstRatio)
end)

test("the engine reports without ever mutating the palette it was given", function()
    local source = table.clone(Tokens.Source)
    source.FontColor = rgb(30, 30, 34) -- unreadable on every surface
    local palette = Theme.Resolve(source)
    local before = {}
    for role, colour in palette do
        before[role] = colour
    end

    local report = Theme.AnalyzeContrast(palette)
    assert(not report.Passes and #report.Failures > 0)

    for role, colour in palette do
        assert(sameColor(colour, before[role]), role .. " was altered by analysis")
    end
    assert(sameColor(source.FontColor, rgb(30, 30, 34)), "the source scheme was altered by analysis")
end)

test("the shipped palette's contrast is reported honestly", function()
    local report = Theme.AnalyzeContrast(Theme.Resolve(Tokens.Source))

    -- Primary text clears normal-text contrast on every surface it appears on,
    -- with a margin wide enough that the surface ramp can be retuned without
    -- putting body text at risk. The floor is well under the figures the shipped
    -- palette actually reports: the assertion is about headroom, not about
    -- restating today's numbers.
    for _, result in report.Results do
        if result.Foreground == "Text.Primary" then
            assert(result.Passes, result.Name .. " must pass, got " .. string.format("%.2f", result.Ratio))
            assert(result.Ratio > 10, result.Name .. " lost its margin at " .. string.format("%.2f", result.Ratio))
        end
    end

    -- The accent is a usable non-text indicator, and text on it is readable
    -- because the foreground was chosen rather than assumed.
    local function find(name)
        for _, result in report.Results do
            if result.Name == name then
                return result
            end
        end
        return nil
    end
    assert(find("Accent markers against primary surfaces").Passes)
    assert(find("Focused border against a control").Passes)
    assert(find("Text on accent fills").Passes)
    assert(find("Disabled text remains visible").Passes)

    -- Three pairs do not pass, and the foundation says so rather than quietly
    -- brightening the palette to make its own report look better. Fixing them
    -- is a design decision, not something the contrast engine is allowed to
    -- make on its own. This assertion is deliberately exact: if a future change
    -- fixes one of these, or introduces a fourth, that should be a decision
    -- someone made rather than something that drifted in.
    assert(not find("Muted text on primary surfaces").Passes)
    assert(not find("Placeholder text in inputs").Passes)
    assert(not find("Scroll bar against its content").Passes)
    assert(#report.Failures == 3, "expected exactly three known failures, got " .. tostring(#report.Failures))
    assert(not report.Passes)

    -- The scroll bar fails because it is measured as drawn. Its raw colour is
    -- appreciably better than its composited one, which is the whole reason the
    -- pair declares an alpha.
    local raw = Theme.GetContrastRatio(
        Theme.Resolve(Tokens.Source)["Overlay.ScrollBar"],
        Theme.Resolve(Tokens.Source)["Surface.Primary"]
    )
    assert(raw > find("Scroll bar against its content").Ratio)

    -- Both worst-pair figures are populated, and neither is an average.
    assert(report.WorstPair ~= nil and report.WorstMarginPair ~= nil)
    assert(report.WorstRatio <= find("Muted text on primary surfaces").Ratio)
end)

--// Validation ---------------------------------------------------------------

test("structural validation is separate from contrast validation", function()
    local library = mount()

    local missing = table.clone(Tokens.Source)
    missing.FontColor = nil
    local report = library.Theme:ValidateScheme(missing)
    assert(not report.Valid and #report.Errors == 1)
    assert(string.find(report.Errors[1], "FontColor") ~= nil)
    -- Contrast is not attempted on a scheme that cannot be resolved, or the
    -- report would describe the wrong problem.
    assert(report.Contrast == nil)

    local wrongType = table.clone(Tokens.Source)
    wrongType.AccentColor = "purple"
    assert(not library.Theme:ValidateScheme(wrongType).Valid)

    local badFont = table.clone(Tokens.Source)
    badFont.Font = "Arial"
    assert(not library.Theme:ValidateScheme(badFont).Valid)

    -- Structurally perfect and completely unreadable: valid, with a contrast
    -- report that fails. The two questions are answered separately.
    local unreadable = table.clone(Tokens.Source)
    unreadable.FontColor = unreadable.BackgroundColor
    local blind = library.Theme:ValidateScheme(unreadable)
    assert(blind.Valid and #blind.Errors == 0)
    assert(blind.Contrast ~= nil and not blind.Contrast.Passes)

    -- Unknown keys are a warning by default and an error under strict mode.
    local extra = table.clone(Tokens.Source)
    extra.MysteryColor = Color3.new(1, 0, 0)
    assert(library.Theme:ValidateScheme(extra).Valid)
    assert(#library.Theme:ValidateScheme(extra).Warnings > 0)
    assert(not library.Theme:ValidateScheme(extra, true).Valid)

    assert(not library.Theme:ValidateScheme("not a scheme").Valid)
    assert(library.Theme:ValidateScheme(Tokens.Source).Valid)

    library:Unload()
end)

--// The live interface -------------------------------------------------------

test("a theme change repaints the whole shell without rebuilding it", function()
    local library = mount()
    local shell = UIModule.Create(library)
    local box = shell:GetTab("Home"):AddLeftGroupbox("Rendering")
    local button = box:AddButton({ Text = "Apply", Callback = function() end })
    local input = box:AddInput("Search", { Text = "Search", Placeholder = "type here" })
    local dropdown = box:AddDropdown("Quality", { Text = "Quality", Values = { "Low", "High" } })
    box:AddLabel("A description")
    box:AddDivider()

    local registered = library.Theme:GetRegisteredCount()
    assert(registered > 20, "the shell should bind many properties, got " .. tostring(registered))

    local window = shell.Window.Instance
    local identity = { Instance = window, Children = #window:GetChildren() }

    library:SetSource({
        BackgroundColor = rgb(250, 250, 252),
        MainColor = rgb(240, 240, 244),
        OutlineColor = rgb(200, 200, 208),
        FontColor = rgb(20, 20, 24),
        AccentColor = rgb(20, 110, 60),
    })

    -- Nothing was recreated and nothing was destroyed.
    assert(shell.Window.Instance == identity.Instance, "the window instance survived the repaint")
    assert(#window:GetChildren() == identity.Children)
    assert(not button.Destroyed and not input.Destroyed and not dropdown.Destroyed)
    assert(library.Theme:GetRegisteredCount() == registered, "the registry is unchanged by a repaint")
    assert(#library.Theme:ValidateRegistry() == 0)

    -- Surfaces actually took the new colours: no orphan hardcoded defaults.
    assert(sameColor(window.BackgroundColor3, rgb(250, 250, 252)))
    assert(sameColor(box.Holder.Instance.BackgroundColor3, rgb(240, 240, 244)))

    -- Text on the new light theme resolves from the new font colour.
    assert(sameColor(library.Theme:Get("Text.Primary"), rgb(20, 20, 24)))

    library:Unload()
end)

test("a repaint preserves hovered, focused, open and disabled controls", function()
    local library = mount()
    local shell = UIModule.Create(library)
    local box = shell:GetTab("Home"):AddLeftGroupbox("States")
    local hovered = box:AddButton({ Text = "Hovered", Callback = function() end })
    local disabled = box:AddButton({ Text = "Disabled", Callback = function() end })
    local input = box:AddInput("Focus", { Text = "Focus" })
    local dropdown = box:AddDropdown("Open", { Text = "Open", Values = { "A", "B" } })

    -- Popup placement reads real geometry, which the mock does not produce.
    dropdown.Trigger.Instance.AbsolutePosition = Vector2.new(120, 200)
    dropdown.Trigger.Instance.AbsoluteSize = Vector2.new(200, 28)

    -- Driven through the real events, so the states are the ones the library
    -- actually produces rather than fields poked from the outside.
    hovered.Main.Surface.Instance.MouseEnter:Fire()
    disabled:SetDisabled(true)
    input:Focus()
    dropdown:Open()

    local hoveredState = hovered.Main.Surface.State
    local disabledBorder = disabled.Main.Surface.BorderState
    local inputBorder = input.Field.BorderState
    assert(hoveredState == "Hover" and disabledBorder == "Disabled" and inputBorder == "Focused")

    library:SetSource({ MainColor = rgb(70, 30, 30), OutlineColor = rgb(160, 60, 60) })

    -- The states themselves are untouched: a repaint is not a state change.
    assert(hovered.Main.Surface.State == hoveredState, "hover state survived the repaint")
    assert(disabled.Main.Surface.BorderState == disabledBorder)
    assert(input.Field.BorderState == inputBorder)
    assert(disabled.Main.Disabled and dropdown.IsOpen)
    assert(library.FocusedControl == input)

    -- And each control is painted for the state it is actually in, with the
    -- new palette -- not left carrying the colour it had before.
    assert(sameColor(hovered.Main.Surface.Interaction.BackgroundColor3, library.Theme:Get("Interaction.Hover")))
    assert(sameColor(disabled.Main.Surface.Border.Color, library.Theme:Get("Border.Disabled")))
    assert(sameColor(input.Field.Border.Color, library.Theme:Get("Border.Focused")))

    library:Unload()
end)

print(tostring(passed) .. " theme tests passed")
