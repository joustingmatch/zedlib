local passed = 0
local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    assert(ok, name .. ": " .. tostring(message))
    passed += 1
    print("PASS " .. name)
end
local function fresh(config)
    return LibraryModule.new(config):Initialize()
end
local function expectError(callback)
    assert(not pcall(callback), "Expected an error")
end
local function activeConnections()
    local total = 0
    for _, connection in allConnections do
        if connection.Connected then
            total += 1
        end
    end
    return total
end

test("initialize, duplicate mount, idempotent terminal unload", function()
    local lib = LibraryModule.new()
    assert(not lib.Loaded and #playerGui:GetChildren() == 0)
    expectError(function()
        lib:Mount()
    end)
    assert(lib:Initialize() == lib and lib:Initialize() == lib)
    lib:Mount()
    local root = lib.ScreenGui
    assert(lib:Mount().ScreenGui == root and #playerGui:GetChildren() == 1)
    lib:Unload()
    lib:Unload()
    assert(root._destroyed and lib.ScreenGui == nil and activeConnections() == 0)
    expectError(function()
        lib:Initialize()
    end)
end)

test("reload retires connections, roots, and registries; separate owners coexist", function()
    local first = fresh():Mount()
    local other = fresh({ OwnershipKey = "other" }):Mount()
    local oldRoot = first.ScreenGui
    local event = first:Create("BindableEvent")
    local connection = first:Connect(event.Event, function()
        error("Should never run")
    end)
    local second = fresh():Mount()
    assert(first.Unloaded and oldRoot._destroyed and not connection.Connected)
    assert(not other.Unloaded and #playerGui:GetChildren() == 2)
    second:Unload()
    other:Unload()
end)

test("independently evaluated bundles share ownership and release old input", function()
    local first = fresh():Mount()
    local reloadedModule = loadModules()
    local second = reloadedModule.new():Initialize():Mount()
    assert(first.Unloaded and second.Mounted and #playerGui:GetChildren() == 1)
    second:Unload()
    local ownership = {}
    local config = { Runtime = { Ownership = ownership } }
    local injectedFirst = fresh(config):Mount()
    local injectedSecond = reloadedModule.new(config):Initialize():Mount()
    assert(injectedFirst.Unloaded and ownership.default ~= nil)
    injectedSecond:Unload()
    assert(next(ownership) == nil)
end)

test("runtime rejects server use and falls back from a failing optional adapter", function()
    local original = runService.IsClient
    runService.IsClient = function()
        return false
    end
    expectError(function()
        fresh()
    end)
    runService.IsClient = original
    local lib = fresh({
        Runtime = {
            ResolveGuiParent = function()
                error("optional host unavailable")
            end,
        },
    }):Mount()
    assert(lib.ScreenGui.Parent == playerGui and not lib.Runtime:HasCapability("Unknown"))
    lib:Unload()
end)

test("unavailable host and failed parenting are retryable and leak-free", function()
    local player = playersService.LocalPlayer
    playersService.LocalPlayer = nil
    local lib = fresh()
    expectError(function()
        lib:Mount()
    end)
    assert(not lib.Mounted and not lib.Unloaded)
    playersService.LocalPlayer = player
    local deadParent = Instance.new("Frame")
    deadParent:Destroy()
    local failed = fresh({
        Runtime = {
            ResolveGuiParent = function()
                return deadParent
            end,
        },
    })
    local before = activeConnections()
    expectError(function()
        failed:Mount()
    end)
    assert(activeConnections() == before and failed.ScreenGui == nil and not failed.Unloaded)
    failed:Unload()
    lib:Mount():Unload()
end)

test("nested scopes release independently, reverse cleanup survives exceptions", function()
    local errors, order = {}, {}
    local parent = ResourcesModule.new(function(message)
        table.insert(errors, message)
    end)
    parent:Add(function()
        table.insert(order, 1)
    end)
    local child = parent:Child()
    child:Add(function()
        table.insert(order, 2)
    end)
    child:Add(function()
        error("cleanup failure")
    end)
    child:Destroy()
    child:Destroy()
    assert(#errors == 1 and #order == 1 and order[1] == 2)
    parent:Destroy()
    assert(order[2] == 1)
    parent:Add(function()
        table.insert(order, 3)
    end)
    assert(order[3] == 3)
end)

test("factory optional properties warn; early instance destruction removes bindings", function()
    local lib = fresh()
    local count = #warnings
    local frame = lib:Create("Frame", { Invalid = 9 })
    assert(#warnings == count + 1)
    lib:RegisterProperty(frame, { BackgroundColor3 = "Surface.Canvas" })
    local color = Color3.new(0.1, 0.2, 0.3)
    lib:SetSource({ BackgroundColor = color })
    assert(frame.BackgroundColor3 == color)
    expectError(function()
        lib:RegisterProperty(frame, { BackgroundColor3 = "Text.Primary" })
    end)
    expectError(function()
        lib:SetSource({ BackgroundColor = "not a colour" })
    end)
    frame:Destroy()
    assert(lib.Registry[frame] == nil and activeConnections() == 0)
    expectError(function()
        lib:RegisterProperty(frame, { BackgroundColor3 = "Text.Primary" })
    end)
    lib:Unload()
end)

test("state registry rejects duplicates and disposes components", function()
    local lib = fresh()
    local destroyed = 0
    local function element()
        local result = { Destroyed = false, Resources = lib:CreateScope() }
        function result:Destroy()
            if self.Destroyed then
                return
            end
            self.Destroyed = true
            destroyed += 1
            self.Resources:Destroy()
        end
        return result
    end
    local one, two = element(), element()
    local remove = lib:RegisterElement("Options", "test", one)
    expectError(function()
        lib:RegisterElement("Options", "test", two)
    end)
    lib.ActivePopup = one
    one:Destroy()
    assert(lib.Options.test == nil and lib.ActivePopup == nil)
    remove()
    lib:RegisterElement("Options", "test", two)
    lib:Unload()
    assert(destroyed == 2 and next(lib.Options) == nil)
end)

test("callbacks preserve nil results and isolate callback/error-hook failures", function()
    local lib = fresh({
        OnError = function()
            error("bad hook")
        end,
    })
    local result = table.pack(lib:SafeCallback(function()
        return nil, 42, nil
    end))
    assert(result.n == 4 and result[1] and result[3] == 42)
    assert(lib:SafeCallback(nil))
    assert(not lib:SafeCallback(12))
    assert(not lib:SafeCallback(function()
        error("user error")
    end))
    lib:Mount():Unload()
end)

test("scale changes preserve logical offsets and reject nonfinite values", function()
    local lib = fresh():Mount()
    local frame = lib:Create("Frame", { Size = UDim2.fromOffset(16, 16), Parent = lib.Root })
    lib:SetDPIScale(2)
    lib:SetDPIScale(1.5)
    assert(frame.Size == UDim2.fromOffset(16, 16))
    assert(lib.Root.Size == UDim2.fromScale(1 / 1.5, 1 / 1.5))
    assert(lib:ToLogical(Vector2.new(150, 75)) == Vector2.new(100, 50))
    for _, scale in lib._Scales do
        assert(scale.Scale == 1.5)
    end
    expectError(function()
        lib:SetDPIScale(0 / 0)
    end)
    expectError(function()
        lib:SetDPIScale(math.huge)
    end)
    expectError(function()
        lib:SetDPIScale(0)
    end)
    lib:Unload()
end)

test("input capture resets on focus loss and unload", function()
    local lib = fresh():Mount()
    local key = { UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.A }
    inputService.InputBegan:Fire(key, true)
    assert(not lib:IsKeyDown(Enum.KeyCode.A))
    inputService.InputBegan:Fire(key, false)
    assert(lib:IsKeyDown(Enum.KeyCode.A))
    local touch = { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown }
    inputService.InputBegan:Fire(touch, false)
    assert(lib.Input.Pointer == touch and lib:IsPrimaryPointer(touch))
    inputService.InputEnded:Fire(touch)
    assert(lib.Input.Pointer == nil)
    inputService.WindowFocusReleased:Fire()
    assert(not lib.Input.Focused and not lib:IsKeyDown(Enum.KeyCode.A))
    inputService.WindowFocused:Fire()
    assert(lib.Input.Focused)
    lib:Unload()
    inputService.InputBegan:Fire(key, false)
    assert(not lib:IsKeyDown(Enum.KeyCode.A))
end)

test("device detection prefers platform and degrades without privileged access", function()
    inputService.TouchEnabled = true
    local desktop = fresh()
    assert(not desktop.IsMobile)
    desktop:Unload()
    local saved = inputService.GetPlatform
    inputService.GetPlatform = function()
        error("restricted")
    end
    local unknown = fresh()
    assert(unknown.DevicePlatform == "Unknown" and not unknown.IsMobile)
    unknown:Unload()
    inputService.KeyboardEnabled, inputService.MouseEnabled = false, false
    local touch = fresh()
    assert(touch.IsMobile)
    touch:Unload()
    inputService.GetPlatform = saved
    inputService.TouchEnabled, inputService.KeyboardEnabled, inputService.MouseEnabled = false, true, true
end)

test("external root destruction unloads entire library", function()
    local lib = fresh():Mount()
    lib.ScreenGui:Destroy()
    assert(lib.Unloaded and lib.ScreenGui == nil and activeConnections() == 0)
    fresh():Mount():Unload()
    for _, name in { "Root", "Overlay" } do
        local damaged = fresh():Mount()
        damaged[name]:Destroy()
        assert(damaged.Unloaded and activeConnections() == 0)
    end
    local damaged = fresh():Mount()
    damaged._Scales[1]:Destroy()
    assert(damaged.Unloaded and activeConnections() == 0)
end)

test("addon failures roll back and addons detach independently", function()
    local lib = fresh()
    local instance
    local failed = lib:AttachAddon("failure", {
        Attach = function(core, scope)
            instance = core:Create("BindableEvent", nil, scope)
            error("setup failed")
        end,
    })
    assert(failed == nil and instance._destroyed and lib._Addons.failure == nil)
    local calls = 0
    local scope = lib:AttachAddon("good", {
        Attach = function(_, owner)
            owner:Add(function()
                calls += 1
            end)
        end,
    })
    scope:Destroy()
    assert(calls == 1 and lib._Addons.good == nil)
    lib:Unload()
    assert(calls == 1)
end)

test("tracked task and tween are cancelled", function()
    local lib = fresh()
    local thread = coroutine.create(function()
        coroutine.yield()
    end)
    coroutine.resume(thread)
    lib:TrackTask(thread)
    local tween = {
        Cancel = function(self)
            self.Cancelled = true
        end,
        Destroy = function(self)
            self.Destroyed = true
        end,
    }
    lib:TrackTween(tween)
    lib:Unload()
    assert(coroutine.status(thread) == "dead" and tween.Cancelled and tween.Destroyed)
end)

test("reentrant replacement cannot steal an unloading slot", function()
    local first = fresh():Mount()
    local candidate = fresh()
    first:OnUnload(function()
        expectError(function()
            candidate:Mount()
        end)
    end)
    local nextOwner = fresh():Mount()
    assert(first.Unloaded and not candidate.Mounted and nextOwner.Mounted)
    candidate:Unload()
    nextOwner:Unload()
end)

test("50 reload cycles leave no live resources", function()
    local previous
    for _ = 1, 50 do
        local lib = fresh():Mount()
        if previous then
            assert(previous.Unloaded)
        end
        previous = lib
    end
    previous:Unload()
    assert(activeConnections() == 0 and #playerGui:GetChildren() == 0)
    for _, instance in allInstances do
        assert(instance == playerGui or instance._destroyed, instance.Name .. " leaked")
    end
    assert(next(shared.__ZedlibFoundationV1) == nil)
end)
print(string.format("%d foundation tests passed", passed))
