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
    -- aligns it. Centred: the strip reads as the page set's own navigation
    -- rather than as a ragged left-hand list that ends in dead space.
    Alignment = 0.5,
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
    -- Rows are separated by a hairline at their shared boundary, so the list
    -- spacing between them is zero. The card still owes its FIRST and LAST row
    -- air against its own edge: without it the top row's ascenders are clipped
    -- by the card's corner radius, which is exactly the "text cut off at the
    -- top of the box" artifact.
    PaddingTop = 6,
    PaddingBottom = 6,
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
    -- The thumb grows under the pointer. Feedback that the control is live
    -- before the value has moved at all.
    ThumbHover = 13,
    ThumbPressed = 15,
    -- The invisible band that actually accepts the pointer, centred on the
    -- visible track. A mouse can hit fourteen pixels; it should not have to.
    GrabHeight = 24,
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
    -- Air above and below a label's text inside its own row. A label measured
    -- at exactly its line height sits flush against the row above and below it,
    -- which reads as two overlapping strings rather than two rows.
    PaddingY = 7,
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
    -- The same idea for a mouse. Smaller than the touch floor, because a
    -- pointer is precise, but never as small as the visible hairline.
    MinPointerTarget = 22,
}

--// Motion (seconds). Restrained by intent; 0 disables a transition.
Metrics.Motion = {
    Hover = 0.12,
    Select = 0.18,
    Focus = 0.12,
    Popup = 0.16,
    Chevron = 0.18,
    -- The toggle knob and the dock indicator travel; they do not pop.
    Knob = 0.22,
}

--// Motion curves. A tween's shape carries as much of its character as its
-- duration does, and one curve applied to everything is why an interface reads
-- as flat however long the tweens are.
--
-- Named by intent, resolved in Materials.Animate. A property change that is a
-- state report (a colour, a transparency) settles; a property change that is a
-- physical movement (a knob, an indicator, a thumb) overshoots very slightly
-- and comes back, which is what makes it read as an object rather than a value.
Metrics.Curve = {
    Settle = { Style = Enum.EasingStyle.Quint, Direction = Enum.EasingDirection.Out },
    Travel = { Style = Enum.EasingStyle.Back, Direction = Enum.EasingDirection.Out },
    Emerge = { Style = Enum.EasingStyle.Cubic, Direction = Enum.EasingDirection.Out },
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
