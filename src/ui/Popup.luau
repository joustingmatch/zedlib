--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)

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

-- Keeps a live "the pointer is over this surface" flag on a frame, and returns
-- a reader for it.
--
-- The geometric hit test below is correct and still the primary answer, but it
-- reads AbsolutePosition, and AbsolutePosition is a RENDERED value: it is one
-- frame stale every time a popup has just been placed, resized, reflowed by a
-- search filter, or carried along by a window drag. In that one frame an
-- outside-click handler tests the click against where the popup used to be,
-- decides the click was outside, and closes the popup the user was aiming at.
-- That is the "I click an item and it closes instead of selecting" bug.
--
-- MouseEnter/MouseLeave are maintained by the engine against the geometry it
-- actually rendered, so they cannot be stale in the way a coordinate read can.
-- The two together: hover answers for a mouse, the rectangle answers for touch.
function Popup.TrackHover(library: any, frame: GuiObject, scope: Types.Scope): () -> boolean
    local inside = false
    library:Connect(frame.MouseEnter, function()
        inside = true
    end, scope)
    library:Connect(frame.MouseLeave, function()
        inside = false
    end, scope)
    scope:Add(function()
        inside = false
    end)
    return function(): boolean
        return inside and frame.Visible
    end
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
