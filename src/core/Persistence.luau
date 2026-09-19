--!strict
local Persistence = {}

--// Host lookup ---------------------------------------------------------------
-- The one dynamic environment read in the library. An injected adapter always
-- wins, so a test or an embedding host never has to satisfy a global.

local FUNCTIONS = {
    "isfolder",
    "isfile",
    "listfiles",
    "makefolder",
    "readfile",
    "writefile",
    "delfile",
}

local function hostEnvironment(): { [string]: any }
    if getfenv then
        local ok, environment = pcall(getfenv, 0)
        if ok and type(environment) == "table" then
            return environment
        end
    end
    return (_G :: any) or {}
end

local function resolveFunctions(adapter: { [string]: any }?): { [string]: any }
    local supplied = adapter or {}
    local environment = hostEnvironment()
    local resolved: { [string]: any } = {}
    for _, name in FUNCTIONS do
        local candidate = supplied[name]
        if type(candidate) ~= "function" then
            candidate = rawget(environment, name)
        end
        if type(candidate) == "function" then
            resolved[name] = candidate
        end
    end
    return resolved
end

--// Paths ---------------------------------------------------------------------
-- A name is a single path segment supplied by a user through a text field. It
-- must not be able to escape the manager's folder, so separators, traversal and
-- the characters Windows rejects are refused rather than sanitised: a theme
-- silently saved under a different name than the one typed is worse than an
-- error saying why.

local RESERVED = { "con", "prn", "aux", "nul" }
local ILLEGAL = '[%c/\\:%*%?"<>|]'

-- Returns the trimmed name, or nil plus a message explaining the rejection.
function Persistence.ValidateName(name: unknown, subject: string?): (string?, string?)
    local label = subject or "Name"
    if type(name) ~= "string" then
        return nil, string.format("%s must be a string, got %s", label, typeof(name))
    end
    local trimmed = string.match(name, "^%s*(.-)%s*$") :: string
    if trimmed == "" then
        return nil, string.format("%s cannot be empty", label)
    end
    if #trimmed > 64 then
        return nil, string.format("%s cannot be longer than 64 characters", label)
    end
    if string.find(trimmed, ILLEGAL) then
        return nil, string.format('%s cannot contain / \\ : * ? " < > | or control characters', label)
    end
    if string.find(trimmed, "%.%.") then
        return nil, string.format('%s cannot contain ".."', label)
    end
    if string.sub(trimmed, -1) == "." then
        return nil, string.format("%s cannot end with a period", label)
    end
    local lowered = string.lower(trimmed)
    for _, reserved in RESERVED do
        if lowered == reserved then
            return nil, string.format("%q is reserved by the operating system", trimmed)
        end
    end
    return trimmed, nil
end

-- A folder may be several segments deep ("MyHub/Games"), so each segment is
-- validated on its own and the separators are normalised to forward slashes.
function Persistence.ValidateFolder(path: unknown, subject: string?): (string?, string?)
    local label = subject or "Folder"
    if type(path) ~= "string" then
        return nil, string.format("%s must be a string, got %s", label, typeof(path))
    end
    local normalised = string.gsub(path, "\\", "/")
    normalised = string.gsub(normalised, "//+", "/")
    normalised = string.match(normalised, "^/*(.-)/*$") :: string
    if normalised == "" then
        return nil, string.format("%s cannot be empty", label)
    end
    local segments: { string } = {}
    for segment in string.gmatch(normalised, "[^/]+") do
        local valid, message = Persistence.ValidateName(segment, label .. " segment")
        if not valid then
            return nil, message
        end
        table.insert(segments, valid)
    end
    return table.concat(segments, "/"), nil
end

function Persistence.Join(...: string): string
    local parts: { string } = {}
    for index = 1, select("#", ...) do
        local part = select(index, ...)
        if type(part) == "string" and part ~= "" then
            table.insert(parts, (string.gsub(part, "^/+", "")))
        end
    end
    return table.concat(parts, "/")
end

-- Hosts disagree about whether listfiles returns names or full paths. Managers
-- want the base name without its extension, which is what the user typed.
function Persistence.BaseName(path: string, extension: string?): string
    local name = string.match(path, "[^/\\]+$") or path
    if extension and #name > #extension and string.sub(string.lower(name), -#extension) == string.lower(extension) then
        name = string.sub(name, 1, #name - #extension)
    end
    return name
end

--// Storage -------------------------------------------------------------------

export type Storage = {
    Available: boolean,
    HasClipboard: boolean,
    Missing: { string },
    IsFolder: (self: Storage, path: string) -> boolean,
    IsFile: (self: Storage, path: string) -> boolean,
    ListFiles: (self: Storage, path: string) -> (boolean, any),
    MakeFolder: (self: Storage, path: string) -> (boolean, string?),
    EnsureFolder: (self: Storage, path: string) -> (boolean, string?),
    ReadFile: (self: Storage, path: string) -> (boolean, string),
    WriteFile: (self: Storage, path: string, contents: string) -> (boolean, string?),
    DeleteFile: (self: Storage, path: string) -> (boolean, string?),
    Encode: (self: Storage, value: any) -> (boolean, string),
    Decode: (self: Storage, text: string) -> (boolean, any),
    SetClipboard: (self: Storage, text: string) -> boolean,
}

local UNAVAILABLE = "This host does not expose the filesystem functions the manager needs"

function Persistence.new(adapter: { [string]: any }?): Storage
    local functions = resolveFunctions(adapter)
    local missing: { string } = {}
    for _, name in FUNCTIONS do
        if functions[name] == nil then
            table.insert(missing, name)
        end
    end

    local environment = hostEnvironment()
    local clipboard = (adapter and adapter.setclipboard)
        or rawget(environment, "setclipboard")
        or rawget(environment, "toclipboard")

    local jsonService: any = nil
    if adapter and adapter.JSON then
        jsonService = adapter.JSON
    else
        pcall(function()
            jsonService = game:GetService("HttpService")
        end)
    end

    local self = {} :: any
    self.Available = #missing == 0
    self.HasClipboard = type(clipboard) == "function"
    self.Missing = missing

    -- Predicates answer false when the host cannot say. A manager treats "I do
    -- not know" and "it is not there" the same way, and both are recoverable.
    local function predicate(name: string, path: string): boolean
        local fn = functions[name]
        if not fn then
            return false
        end
        local ok, result = pcall(fn, path)
        return ok and result == true
    end

    function self:IsFolder(path: string): boolean
        return predicate("isfolder", path)
    end

    function self:IsFile(path: string): boolean
        return predicate("isfile", path)
    end

    -- A missing folder lists as empty rather than as a failure: "no themes yet"
    -- is the normal first-run state, not something to report to the user.
    function self:ListFiles(path: string): (boolean, any)
        local fn = functions.listfiles
        if not fn then
            return false, UNAVAILABLE
        end
        if not self:IsFolder(path) then
            return true, {}
        end
        local ok, result = pcall(fn, path)
        if not ok then
            return false, "Could not list " .. path .. ": " .. tostring(result)
        end
        if type(result) ~= "table" then
            return false, "listfiles returned " .. typeof(result)
        end
        local entries: { string } = {}
        for _, entry in result :: { any } do
            if type(entry) == "string" then
                table.insert(entries, entry)
            end
        end
        return true, entries
    end

    function self:MakeFolder(path: string): (boolean, string?)
        local fn = functions.makefolder
        if not fn then
            return false, UNAVAILABLE
        end
        if self:IsFolder(path) then
            return true, nil
        end
        local ok, message = pcall(fn, path)
        if not ok then
            return false, "Could not create " .. path .. ": " .. tostring(message)
        end
        return true, nil
    end

    -- Builds every missing segment from the outside in. A host that refuses one
    -- level stops the walk with a message naming the level it refused.
    function self:EnsureFolder(path: string): (boolean, string?)
        local accumulated = ""
        for segment in string.gmatch(path, "[^/]+") do
            accumulated = if accumulated == "" then segment else accumulated .. "/" .. segment
            local ok, message = self:MakeFolder(accumulated)
            if not ok then
                return false, message
            end
        end
        return true, nil
    end

    function self:ReadFile(path: string): (boolean, string)
        local fn = functions.readfile
        if not fn then
            return false, UNAVAILABLE
        end
        if not self:IsFile(path) then
            return false, path .. " does not exist"
        end
        local ok, contents = pcall(fn, path)
        if not ok then
            return false, "Could not read " .. path .. ": " .. tostring(contents)
        end
        if type(contents) ~= "string" then
            return false, "readfile returned " .. typeof(contents)
        end
        return true, contents
    end

    function self:WriteFile(path: string, contents: string): (boolean, string?)
        local fn = functions.writefile
        if not fn then
            return false, UNAVAILABLE
        end
        if type(contents) ~= "string" then
            return false, "File contents must be a string"
        end
        local ok, message = pcall(fn, path, contents)
        if not ok then
            return false, "Could not write " .. path .. ": " .. tostring(message)
        end
        return true, nil
    end

    function self:DeleteFile(path: string): (boolean, string?)
        local fn = functions.delfile
        if not fn then
            return false, UNAVAILABLE
        end
        if not self:IsFile(path) then
            return false, path .. " does not exist"
        end
        local ok, message = pcall(fn, path)
        if not ok then
            return false, "Could not delete " .. path .. ": " .. tostring(message)
        end
        return true, nil
    end

    function self:Encode(value: any): (boolean, string)
        if not jsonService then
            return false, "No JSON encoder available"
        end
        local ok, result = pcall(function()
            return jsonService:JSONEncode(value)
        end)
        if not ok or type(result) ~= "string" then
            return false, "Could not encode JSON: " .. tostring(result)
        end
        return true, result
    end

    function self:Decode(text: string): (boolean, any)
        if not jsonService then
            return false, "No JSON decoder available"
        end
        if type(text) ~= "string" or string.match(text, "^%s*$") then
            return false, "Nothing to decode"
        end
        local ok, result = pcall(function()
            return jsonService:JSONDecode(text)
        end)
        if not ok then
            return false, "Invalid JSON"
        end
        return true, result
    end

    -- Optional. Export must succeed on a host with no clipboard, so this reports
    -- whether the copy happened rather than failing the operation.
    function self:SetClipboard(text: string): boolean
        if type(clipboard) ~= "function" or type(text) ~= "string" then
            return false
        end
        return (pcall(clipboard, text))
    end

    return self :: Storage
end

return Persistence
