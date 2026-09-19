--!strict
local Types = require(script.Parent.Parent.Types)
local Persistence = require(script.Parent.Persistence)
local Runtime = {}

-- Optional capabilities a host may or may not provide. Each probe must be pure,
-- non-yielding, and must not leave anything behind.
local PROBES: { [string]: () -> boolean } = {
    -- Real text measurement rather than estimation.
    TextBounds = function()
        local params = Instance.new("GetTextBoundsParams")
        params.Text = "A"
        params.Size = 12
        params:Destroy()
        return true
    end,
    -- Real inner/outer shadows, which is what gives a surface thickness.
    UIShadow = function()
        local instance = Instance.new("UIShadow")
        instance.Inset = true
        instance.BlurRadius = UDim.new(0, 8)
        instance:Destroy()
        return true
    end,
    -- Weighted font families, required for a text hierarchy without size changes.
    FontFamily = function()
        local font = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium)
        return font.Weight == Enum.FontWeight.Medium
    end,
}

function Runtime.new(adapter: Types.RuntimeAdapter?)
    local options: Types.RuntimeAdapter = adapter or {}
    --// Services: acquired once per library, no hidden waits or privileged APIs.
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local RunService = game:GetService("RunService")
    assert(RunService:IsClient(), "Zedlib requires a client runtime")

    -- shared is the only dynamic environment boundary. No executor globals are probed.
    local environment: any = shared
    if options.Ownership == nil then
        assert(type(environment) == "table", "Inject Runtime.Ownership in this host")
        if environment.__ZedlibFoundationV1 == nil then
            environment.__ZedlibFoundationV1 = {}
        end
        assert(type(environment.__ZedlibFoundationV1) == "table", "Invalid Zedlib ownership store")
    end
    local ownership: { [string]: Types.OwnershipSlot } = options.Ownership or environment.__ZedlibFoundationV1
    local capabilities: { [string]: boolean } = {}
    -- The host storage boundary, resolved once. Managers reach the filesystem,
    -- JSON and the clipboard only through here, so no code above the runtime
    -- ever reads a host global or decides what to do when one is missing.
    local storage = Persistence.new(options.Storage)
    local runtime = { Input = UserInputService, Render = RunService, Ownership = ownership, Storage = storage }

    function runtime:ResolveGuiParent(): Instance?
        if options.ResolveGuiParent then
            local ok, parent = pcall(options.ResolveGuiParent)
            if ok and typeof(parent) == "Instance" then
                return parent
            end
            -- A failing optional host adapter falls back to PlayerGui.
        end
        local player = Players.LocalPlayer
        return if player then player:FindFirstChildOfClass("PlayerGui") else nil
    end

    function runtime:GetPlatform(): (string, boolean)
        if options.GetPlatform then
            local ok, platform = pcall(options.GetPlatform)
            if ok and type(platform) == "string" then
                return platform, platform == "Android" or platform == "IOS"
            end
        end
        -- GetPlatform may be restricted in some hosts; keep the probe here.
        local ok, platform = pcall(function()
            return UserInputService:GetPlatform().Name
        end)
        if ok and platform ~= "None" then
            return platform, platform == "Android" or platform == "IOS"
        end
        if
            UserInputService.TouchEnabled
            and not UserInputService.KeyboardEnabled
            and not UserInputService.MouseEnabled
        then
            return "Touch", true
        end
        return "Unknown", false
    end

    function runtime:HasCapability(name: string): boolean
        if name == "Touch" then
            return UserInputService.TouchEnabled
        end
        if name == "Keyboard" then
            return UserInputService.KeyboardEnabled
        end
        if name == "Mouse" then
            return UserInputService.MouseEnabled
        end
        if name == "CustomGuiParent" then
            return options.ResolveGuiParent ~= nil
        end
        -- Storage capabilities are resolved by Persistence, not probed here:
        -- asking twice in two places is how the two answers drift apart.
        if name == "FileSystem" then
            return storage.Available
        end
        if name == "Clipboard" then
            return storage.HasClipboard
        end
        -- Optional rendering/text capabilities. Probed once, cached, and never
        -- re-probed, so visual code asks here instead of scattering pcalls.
        local cached = capabilities[name]
        if cached ~= nil then
            return cached
        end
        local probe = PROBES[name]
        if not probe then
            return false
        end
        local ok, supported = pcall(probe)
        local result = ok and supported == true
        capabilities[name] = result
        return result
    end

    return runtime
end

export type Runtime = typeof(Runtime.new(nil))
return Runtime
