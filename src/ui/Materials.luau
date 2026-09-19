--!strict
local Types = require(script.Parent.Parent.Types)
local Theme = require(script.Parent.Parent.core.Theme)
local Metrics = require(script.Parent.Metrics)

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
