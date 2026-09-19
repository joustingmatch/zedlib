--!strict
local Types = require(script.Parent.Parent.Types)
type Scope = Types.Scope
type Cleanup = Types.Cleanup

local ResourceTracker = {}

function ResourceTracker.new(report: (string) -> ()): Scope
    local callbacks: { [Cleanup]: number } = {}
    local sequence = 0
    local scope: Scope
    scope = {
        Destroyed = false,
        Add = function(self: Scope, cleanup: Cleanup): Cleanup
            assert(type(cleanup) == "function", "Cleanup must be a function")
            local function dispose()
                if callbacks[cleanup] == nil then
                    return
                end
                callbacks[cleanup] = nil
                local ok, message = xpcall(function()
                    cleanup()
                    return true
                end, debug.traceback)
                if not ok then
                    report(tostring(message))
                end
            end
            if self.Destroyed then
                local ok, message = xpcall(function()
                    cleanup()
                    return true
                end, debug.traceback)
                if not ok then
                    report(tostring(message))
                end
            else
                assert(callbacks[cleanup] == nil, "Cleanup already tracked by this scope")
                sequence += 1
                callbacks[cleanup] = sequence
            end
            return dispose
        end,
        Child = function(self: Scope): Scope
            assert(not self.Destroyed, "Cannot create a child of a destroyed scope")
            local child = ResourceTracker.new(report)
            local dispose = self:Add(function()
                child:Destroy()
            end)
            -- Removing the parent entry on early disposal avoids retaining dead children.
            child:Add(dispose)
            return child
        end,
        Destroy = function(self: Scope)
            if self.Destroyed then
                return
            end
            self.Destroyed = true
            local ordered = {}
            for callback, order in callbacks do
                table.insert(ordered, { Callback = callback, Order = order })
            end
            table.sort(ordered, function(a, b)
                return a.Order > b.Order
            end)
            for _, entry in ordered do
                if callbacks[entry.Callback] then
                    callbacks[entry.Callback] = nil
                    local ok, message = xpcall(function()
                        entry.Callback()
                        return true
                    end, debug.traceback)
                    if not ok then
                        report(tostring(message))
                    end
                end
            end
            table.clear(callbacks)
        end,
    }
    return scope
end

return ResourceTracker
