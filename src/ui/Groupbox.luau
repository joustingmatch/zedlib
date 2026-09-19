--!strict
local Types = require(script.Parent.Parent.Types)
local Metrics = require(script.Parent.Metrics)
local Materials = require(script.Parent.Materials)
local Element = require(script.Parent.Element)
local Controls = require(script.Parent.Controls)
local Label = require(script.Parent.Label)
local Divider = require(script.Parent.Divider)
local Button = require(script.Parent.Button)
local Dropdown = require(script.Parent.Dropdown)
local Input = require(script.Parent.Input)
local Toggle = require(script.Parent.Toggle)
local Slider = require(script.Parent.Slider)
local KeyPicker = require(script.Parent.KeyPicker)
local ColorPicker = require(script.Parent.ColorPicker)
local Container = require(script.Parent.Container)
local UX = require(script.Parent.UX)

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
