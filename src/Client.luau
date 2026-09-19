--!strict
local Library = require(script.Parent.Library)
local Shell = require(script.Parent.ui.Shell)

function Library.CreateWindow(self: Library.Library, options: Shell.Options?): Shell.Shell
    return Shell.new(self, options)
end

return Library
