--!strict
local Types = require(script.Parent.Parent.Types)

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
