-- Generated distribution file.
-- Edit the source modules, not this file.

local Module1 = (function()
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
end)()

local Module2 = (function()
--!strict
-- Shared theme serialization and reserved control IDs.
local ThemeData = {}

ThemeData.OptionIds = {
    "BackgroundColor",
    "MainColor",
    "AccentColor",
    "OutlineColor",
    "FontColor",
    "FontFace",
    "ThemeManager_ThemeList",
    "ThemeManager_CustomThemeList",
    "ThemeManager_CustomThemeName",
    "ThemeManager_ThemeJSON",
}

--// Colour conversion ---------------------------------------------------------

local function toHex(color: Color3): string
    return string.format(
        "#%02X%02X%02X",
        math.round(math.clamp(color.R, 0, 1) * 255),
        math.round(math.clamp(color.G, 0, 1) * 255),
        math.round(math.clamp(color.B, 0, 1) * 255)
    )
end

-- Accepts what a theme file or a pasted value can plausibly contain: a Color3
-- already, or a hex string with or without its hash. Anything else is nil, and
-- the caller reports which key was wrong rather than substituting a colour.
local function toColor(value: unknown): Color3?
    if typeof(value) == "Color3" then
        return value :: Color3
    end
    if type(value) ~= "string" then
        return nil
    end
    local hex = string.match(value, "^%s*#?(%x%x%x%x%x%x)%s*$")
    if not hex then
        return nil
    end
    return Color3.fromRGB(
        tonumber(string.sub(hex, 1, 2), 16) :: number,
        tonumber(string.sub(hex, 3, 4), 16) :: number,
        tonumber(string.sub(hex, 5, 6), 16) :: number
    )
end

ThemeData.ToHex = toHex
ThemeData.ToColor = toColor

return ThemeData
end)()

local Module3 = (function()
--!strict
local Persistence = Module1
local ThemeData = Module2

-- As with ThemeManager: the workflow is borrowed, the appearance is not. This
-- file creates no instance and sets no colour or size -- it builds ordinary
-- shell controls in ordinary module cards and lets the page lay them out.

local SaveManager = {}

local CONFIG_EXTENSION = ".json"
local AUTOLOAD_FILE = "autoload.txt"
local RESERVED_NAME = "autoload"

--// Element parsers -----------------------------------------------------------
-- One entry per control type. Save reads the control and returns a plain table;
-- Load takes that table and drives the control's setters. A parser returning
-- nil from Save means "this control has nothing worth persisting", which is a
-- normal answer, not a failure.
--
-- Keeping these separate is the point. A single chain of type comparisons grows
-- a new branch every time a control is added and eventually contains the whole
-- serializer; a table of small parsers stays the same size as the number of
-- control types, and each one can be read on its own.

local function hex(color: Color3): string
    return ThemeData.ToHex(color)
end

export type Parser = {
    Save: (control: any, id: string) -> { [string]: any }?,
    Load: (control: any, data: { [string]: any }) -> (),
}

local ElementParser: { [string]: Parser } = {}

ElementParser.Toggle = {
    Save = function(control: any, id: string)
        return { type = "Toggle", idx = id, value = control.Value == true }
    end,
    Load = function(control: any, data: { [string]: any })
        if type(data.value) == "boolean" then
            control:SetValue(data.value)
        end
    end,
}

ElementParser.Slider = {
    -- Stored as a string. JSON numbers round-trip through a double, and a
    -- rounded slider is one of the few places where a value that comes back as
    -- 0.30000000000000004 is visible to the user in a text field.
    Save = function(control: any, id: string)
        return { type = "Slider", idx = id, value = tostring(control.Value) }
    end,
    Load = function(control: any, data: { [string]: any })
        local value = tonumber(data.value)
        if value and value == value and value ~= math.huge and value ~= -math.huge then
            -- SetValue clamps to the control's current range and applies its
            -- rounding, so a config saved before the range was narrowed lands
            -- inside the new range instead of outside it.
            control:SetValue(value)
        end
    end,
}

ElementParser.Dropdown = {
    Save = function(control: any, id: string)
        local value = control.Value
        if control.Multi then
            local selected: { string } = {}
            if type(value) == "table" then
                for _, entry in value :: { any } do
                    if type(entry) == "string" then
                        table.insert(selected, entry)
                    end
                end
            end
            return { type = "Dropdown", idx = id, value = selected, multi = true }
        end
        return { type = "Dropdown", idx = id, value = value, multi = false }
    end,
    Load = function(control: any, data: { [string]: any })
        -- A config saved while the control was single-select can be loaded after
        -- it became multi-select and the other way round, so the shape is
        -- checked against the control as it is now, not as it was.
        if control.Multi then
            if type(data.value) == "table" then
                control:SetValue(data.value)
            elseif type(data.value) == "string" then
                control:SetValue({ data.value })
            end
            return
        end
        if type(data.value) == "string" then
            control:SetValue(data.value)
        elseif type(data.value) == "table" then
            local first = (data.value :: { any })[1]
            if type(first) == "string" then
                control:SetValue(first)
            end
        elseif data.value == nil and control.AllowNull then
            control:SetValue(nil)
        end
    end,
}

ElementParser.ColorPicker = {
    Save = function(control: any, id: string)
        return {
            type = "ColorPicker",
            idx = id,
            value = hex(control.Value),
            transparency = control.Transparency,
        }
    end,
    Load = function(control: any, data: { [string]: any })
        local color = ThemeData.ToColor(data.value)
        if color then
            control:SetValueRGB(color)
        end
        local transparency = tonumber(data.transparency)
        if transparency then
            control:SetTransparency(math.clamp(transparency, 0, 1))
        end
    end,
}

ElementParser.KeyPicker = {
    -- Our key pickers have no modifier concept, so there is no modifiers field
    -- to persist. `toggled` is the armed state of a Toggle-mode bind; for the
    -- other modes it is derived rather than stored, and restoring it would
    -- fight the control.
    Save = function(control: any, id: string)
        return {
            type = "KeyPicker",
            idx = id,
            mode = control.Mode,
            key = control.Value,
            toggled = control.Active == true,
        }
    end,
    Load = function(control: any, data: { [string]: any })
        if type(data.mode) == "string" then
            control:SetMode(data.mode)
        end
        if type(data.key) == "string" then
            control:SetValue(data.key)
        end
        -- After the mode and the key, because SetValue clears the armed state:
        -- a bind whose key changed should not stay active on the old one.
        if control.Mode == "Toggle" and type(data.toggled) == "boolean" then
            control:SetActive(data.toggled)
        end
        control:Refresh()
    end,
}

ElementParser.Input = {
    Save = function(control: any, id: string)
        return { type = "Input", idx = id, text = control.Value }
    end,
    Load = function(control: any, data: { [string]: any })
        if type(data.text) == "string" then
            control:SetValue(data.text)
        end
    end,
}

SaveManager.ElementParser = ElementParser

--// State ---------------------------------------------------------------------

SaveManager.Library = nil :: any
SaveManager.Folder = "Zedlib"
SaveManager.SubFolder = ""
SaveManager.Ignore = {} :: { [string]: boolean }
SaveManager.LoadingOrder = {} :: { string }
SaveManager.UseLoadingOrder = false
SaveManager.AutoloadConfig = nil :: string?
SaveManager.Options = nil :: any

--// Plumbing ------------------------------------------------------------------

local function library(self: any): any
    local value = self.Library
    assert(value ~= nil, "SaveManager:SetLibrary(Library) must be called first")
    assert(not value.Unloaded, "SaveManager is bound to an unloaded library")
    return value
end

local function storage(self: any): any
    return library(self).Runtime.Storage
end

local function notify(self: any, title: string, description: string, duration: number?)
    local lib = self.Library
    local window = lib and lib.Window
    if window and not window.Destroyed and window.Notify then
        window:Notify({ Title = title, Description = description, Time = duration or 5 })
        return
    end
    if lib then
        lib:_Report(title .. ": " .. description)
    end
end

local function dialog(self: any, config: any): boolean
    local lib = self.Library
    local window = lib and lib.Window
    if not window or window.Destroyed or not window.AddDialog then
        return false
    end
    self._DialogCount = (self._DialogCount or 0) + 1
    local instance = window:AddDialog("SaveManager_Confirm_" .. tostring(self._DialogCount), config)
    instance:Open()
    return true
end

--// Setup ---------------------------------------------------------------------

function SaveManager.SetLibrary(self: any, value: any): any
    assert(type(value) == "table" and value.Loaded ~= nil, "SetLibrary expects a Zedlib library")
    self.Library = value
    return self
end

function SaveManager.SetFolder(self: any, folder: string): any
    local resolved, message = Persistence.ValidateFolder(folder, "Config folder")
    assert(resolved, message)
    self.Folder = resolved
    return self
end

-- Optional. A hub that runs in several games keeps one folder and one subfolder
-- per game, so switching game switches config list and autoload together.
function SaveManager.SetSubFolder(self: any, folder: string?): any
    if folder == nil or folder == "" then
        self.SubFolder = ""
        return self
    end
    local resolved, message = Persistence.ValidateFolder(folder, "Config subfolder")
    assert(resolved, message)
    self.SubFolder = resolved
    return self
end

function SaveManager.GetPaths(self: any): { Folder: string, Settings: string, Configs: string, Autoload: string }
    local settings = Persistence.Join(self.Folder, "settings")
    local configs = if self.SubFolder ~= "" then Persistence.Join(settings, self.SubFolder) else settings
    return {
        Folder = self.Folder,
        Settings = settings,
        Configs = configs,
        Autoload = Persistence.Join(configs, AUTOLOAD_FILE),
    }
end

function SaveManager.ConfigPath(self: any, name: string): string
    return Persistence.Join(self:GetPaths().Configs, name .. CONFIG_EXTENSION)
end

function SaveManager.BuildFolderTree(self: any): (boolean, string?)
    local store = storage(self)
    if not store.Available then
        return false, "This host does not support saving configs"
    end
    return store:EnsureFolder(self:GetPaths().Configs)
end

function SaveManager.CheckFolderTree(self: any): boolean
    local ok = self:BuildFolderTree()
    return ok
end

function SaveManager.CheckSubFolder(self: any): boolean
    local paths = self:GetPaths()
    if self.SubFolder == "" then
        return true
    end
    return storage(self):IsFolder(paths.Configs)
end

--// Ignore --------------------------------------------------------------------

function SaveManager.SetIgnoreIndexes(self: any, ids: { string }): any
    assert(type(ids) == "table", "SetIgnoreIndexes expects an array of option ids")
    for _, id in ids do
        assert(type(id) == "string" and id ~= "", "Ignored ids must be nonempty strings")
        self.Ignore[id] = true
    end
    return self
end

-- Themes and configs are separate files with separate lifetimes, and a config
-- that quietly carried a palette would make loading someone else's settings
-- change how the interface looks. The ids come from ThemeManager rather than
-- being restated here, so adding a control to the theme editor cannot leave it
-- accidentally serializable.
function SaveManager.IgnoreThemeSettings(self: any): any
    return self:SetIgnoreIndexes(ThemeData.OptionIds)
end

--// Loading order -------------------------------------------------------------

function SaveManager.SetLoadingOrder(self: any, enabled: boolean, order: { string }?): any
    self.UseLoadingOrder = enabled == true
    if order then
        assert(type(order) == "table", "SetLoadingOrder expects an array of type names")
        self.LoadingOrder = table.clone(order)
    end
    return self
end

--// Save ----------------------------------------------------------------------

-- Walks both element registries and asks the matching parser for each control's
-- state. The walk is over what the library holds right now, so a control that
-- was destroyed since the last save is simply not there.
function SaveManager.SaveJSON(self: any, configName: string?): (boolean, string)
    local lib = library(self)
    local objects: { any } = {}

    local function collect(registry: { [string]: any })
        for id, control in registry do
            if not self.Ignore[id] and not control.Destroyed then
                local parser = ElementParser[control.Type]
                if parser then
                    local data = parser.Save(control, id)
                    if data then
                        table.insert(objects, data)
                    end
                end
            end
        end
    end

    collect(lib.Toggles)
    collect(lib.Options)

    -- Registry iteration order is not stable, so the file is sorted. Two saves
    -- of the same state then produce the same bytes, which makes a config
    -- diffable and makes a "did anything change" check meaningful.
    table.sort(objects, function(a, b)
        return tostring(a.idx) < tostring(b.idx)
    end)

    return storage(self):Encode({
        name = configName,
        timestamp = os.time(),
        objects = objects,
    })
end

function SaveManager.Save(self: any, configName: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(configName, "Config name")
    if not valid then
        return false, message
    end
    if string.lower(valid) == RESERVED_NAME then
        return false, '"autoload" is reserved for the autoload marker'
    end

    local store = storage(self)
    if not store.Available then
        return false, "This host does not support saving configs"
    end
    local built, buildMessage = self:BuildFolderTree()
    if not built then
        return false, buildMessage
    end

    local encoded, json = self:SaveJSON(valid)
    if not encoded then
        return false, json
    end
    return store:WriteFile(self:ConfigPath(valid), json)
end

--// Load ----------------------------------------------------------------------

function SaveManager.RefreshConfigList(self: any): { string }
    local ok, entries = storage(self):ListFiles(self:GetPaths().Configs)
    if not ok then
        return {}
    end
    local names: { string } = {}
    for _, entry in entries :: { string } do
        if string.sub(string.lower(entry), -#CONFIG_EXTENSION) == CONFIG_EXTENSION then
            local name = Persistence.BaseName(entry, CONFIG_EXTENSION)
            if string.lower(name) ~= RESERVED_NAME then
                table.insert(names, name)
            end
        end
    end
    table.sort(names)
    return names
end

-- Applies a decoded config.
--
-- Every entry is independent. An unknown type, an id that no longer exists, a
-- parser that throws on a malformed entry: none of those stop the rest of the
-- file from loading, because a config is a best-effort description of a state
-- that may no longer be reachable, and a script that has changed shape should
-- still restore the settings it does still have.
function SaveManager.LoadJSON(self: any, content: string): (boolean, string?)
    if type(content) ~= "string" or string.match(content, "^%s*$") then
        return false, "Nothing to load"
    end
    local lib = library(self)
    local ok, decoded = storage(self):Decode(content)
    if not ok then
        return false, "That is not valid JSON"
    end
    if type(decoded) ~= "table" then
        return false, "A config must be a JSON object"
    end
    local objects = (decoded :: any).objects
    if type(objects) ~= "table" then
        return false, "A config must contain an objects array"
    end

    local entries: { any } = {}
    for _, entry in objects :: { any } do
        if type(entry) == "table" and type(entry.idx) == "string" and type(entry.type) == "string" then
            table.insert(entries, entry)
        end
    end

    -- Optional ordering, for the case where one restored value changes what
    -- another one is allowed to be: a dropdown whose list is rebuilt by a
    -- toggle's callback has to be restored after that toggle.
    if self.UseLoadingOrder and #self.LoadingOrder > 0 then
        local rank: { [string]: number } = {}
        for index, kind in self.LoadingOrder do
            rank[kind] = index
        end
        local fallback = #self.LoadingOrder + 1
        table.sort(entries, function(a, b)
            local left, right = rank[a.type] or fallback, rank[b.type] or fallback
            if left == right then
                return tostring(a.idx) < tostring(b.idx)
            end
            return left < right
        end)
    end

    local applied, skipped = 0, 0
    for _, entry in entries do
        local id = entry.idx :: string
        local parser = ElementParser[entry.type]
        local control = lib.Toggles[id] or lib.Options[id]
        if not parser or not control or control.Destroyed or self.Ignore[id] then
            skipped += 1
        elseif control.Type ~= entry.type then
            -- The id was reused for a different kind of control. Applying a
            -- toggle's value to a slider would be worse than skipping it.
            skipped += 1
        else
            local success = lib:SafeCallback(parser.Load, control, entry)
            if success then
                applied += 1
            else
                skipped += 1
            end
        end
    end

    return true, string.format("%d restored, %d skipped", applied, skipped)
end

function SaveManager.Load(self: any, configName: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(configName, "Config name")
    if not valid then
        return false, message
    end
    local ok, contents = storage(self):ReadFile(self:ConfigPath(valid))
    if not ok then
        return false, contents
    end
    return self:LoadJSON(contents)
end

function SaveManager.Delete(self: any, configName: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(configName, "Config name")
    if not valid then
        return false, message
    end
    local ok, deleteMessage = storage(self):DeleteFile(self:ConfigPath(valid))
    if not ok then
        return false, deleteMessage
    end
    if self:GetAutoloadConfig() == valid then
        self:DeleteAutoLoadConfig()
    end
    return true, nil
end

--// Autoload ------------------------------------------------------------------

function SaveManager.GetAutoloadConfig(self: any): string?
    local ok, contents = storage(self):ReadFile(self:GetPaths().Autoload)
    if not ok then
        return nil
    end
    local trimmed = string.match(contents, "^%s*(.-)%s*$") :: string
    return if trimmed == "" then nil else trimmed
end

function SaveManager.SaveAutoloadConfig(self: any, configName: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(configName, "Config name")
    if not valid then
        return false, message
    end
    local store = storage(self)
    if not store:IsFile(self:ConfigPath(valid)) then
        return false, string.format("No config named %q", valid)
    end
    local built, buildMessage = self:BuildFolderTree()
    if not built then
        return false, buildMessage
    end
    local ok, writeMessage = store:WriteFile(self:GetPaths().Autoload, valid)
    if not ok then
        return false, writeMessage
    end
    self.AutoloadConfig = valid
    return true, nil
end

function SaveManager.DeleteAutoLoadConfig(self: any): (boolean, string?)
    self.AutoloadConfig = nil
    local store = storage(self)
    local path = self:GetPaths().Autoload
    if not store:IsFile(path) then
        return true, nil
    end
    return store:DeleteFile(path)
end

-- Called by the hub once the interface exists, so that restored values reach
-- controls that have already been created. No autoload configured is silent;
-- an autoload that names a missing or broken config is not, because the user
-- expects their settings and is about to not have them.
function SaveManager.LoadAutoloadConfig(self: any): boolean
    local name = self:GetAutoloadConfig()
    if not name then
        return false
    end
    self.AutoloadConfig = name
    local ok, message = self:Load(name)
    if not ok then
        notify(self, "Config", string.format("Could not load %q: %s", name, tostring(message)))
        return false
    end
    notify(self, "Config", string.format("Loaded %s", name))
    self:_RefreshDisplay()
    return true
end

--// Interface -----------------------------------------------------------------

local function stripMarker(name: string?): string?
    if type(name) ~= "string" then
        return nil
    end
    return (string.gsub(name, "%s%(autoload%)$", ""))
end

function SaveManager._RefreshDisplay(self: any)
    local label = self.AutoloadLabel
    if label and not label.Destroyed then
        label:SetText("Current autoload config: " .. (self.AutoloadConfig or "none"))
    end
end

function SaveManager._RefreshList(self: any)
    local list = self.Options and self.Options.SaveManager_ConfigList
    if not list or list.Destroyed then
        return
    end
    self.AutoloadConfig = self:GetAutoloadConfig()
    local selected = stripMarker(list.Value)
    local labelled: { string } = {}
    for _, name in self:RefreshConfigList() do
        table.insert(labelled, if name == self.AutoloadConfig then name .. " (autoload)" else name)
    end
    list:SetValues(labelled)
    if selected then
        for _, candidate in list.Values do
            if stripMarker(candidate) == selected then
                list:SetValue(candidate)
                break
            end
        end
    end
    self:_RefreshDisplay()
end

-- Section placement -----------------------------------------------------------
--
-- The manager builds a page, not a list. Its controls fall into groups the
-- shell already has a shape for -- the module card, with its name set outside
-- it -- so the manager asks for one card per group and lets the shell stack
-- them in its own two columns, instead of pouring everything into one tall box
-- with rules drawn between the parts.
--
-- Both entry points run the same builder. Given a page, `sectionsFromPage`
-- hands out a fresh card per group; given a single groupbox,
-- `sectionsFromGroupbox` hands back that same box every time and separates the
-- groups with a divider, which is exactly what the one-groupbox spelling has
-- always done.
local function sectionsFromGroupbox(groupbox: any)
    local first = true
    return function(_name: string, _side: string): any
        if not first then
            groupbox:AddDivider()
        end
        first = false
        return groupbox
    end
end

local function sectionsFromPage(page: any)
    return function(name: string, side: string): any
        return page:AddGroupbox({ Name = name, Side = side })
    end
end

function SaveManager.CreateConfigSection(self: any, groupbox: any?): any
    -- A page supplies its own sections; a lone groupbox is the only section.
    assert(self._Section ~= nil or (groupbox and not groupbox.Destroyed), "CreateConfigSection needs a live groupbox")
    assert(self.Library, "SaveManager:SetLibrary(Library) must be called first")

    local lib = library(self)
    self.Options = lib.Options
    self.AutoloadConfig = self:GetAutoloadConfig()

    local store = storage(self)
    local canPersist = store.Available

    local section = self._Section or sectionsFromGroupbox(groupbox)
    self._Section = nil

    do
        local box = section("Configuration", "Left")
        self.Groupbox = box
        local nameInput = box:AddInput("SaveManager_ConfigName", {
            Text = "Config name",
            Placeholder = "My config",
            Disabled = not canPersist,
        })

        local list = box:AddDropdown("SaveManager_ConfigList", {
            Text = "Config",
            Values = {},
            AllowNull = true,
            Disabled = not canPersist,
        })

        local function selected(): string?
            return stripMarker(list.Value)
        end

        local function write(name: string)
            local ok, message = self:Save(name)
            notify(self, "Config", if ok then "Saved " .. name else tostring(message))
            if ok then
                self:_RefreshList()
            end
        end

        box:AddButton({
            Text = "Create config",
            Disabled = not canPersist,
            Callback = function()
                local valid, message = Persistence.ValidateName(nameInput.Value, "Config name")
                if not valid then
                    notify(self, "Config", tostring(message))
                    return
                end
                if string.lower(valid) == RESERVED_NAME then
                    notify(self, "Config", '"autoload" is reserved')
                    return
                end
                if store:IsFile(self:ConfigPath(valid)) then
                    local shown = dialog(self, {
                        Title = "Overwrite config",
                        Description = string.format("%q already exists. This cannot be undone.", valid),
                        FooterButtons = {
                            { Title = "Cancel", Order = 1, Variant = "Ghost" },
                            {
                                Title = "Overwrite",
                                Order = 2,
                                Variant = "Destructive",
                                Callback = function()
                                    write(valid)
                                end,
                            },
                        },
                    })
                    if shown then
                        return
                    end
                end
                write(valid)
            end,
        })

        box:AddButton({
            Text = "Load config",
            Disabled = not canPersist,
            Callback = function()
                local name = selected()
                if not name then
                    notify(self, "Config", "Select a config first")
                    return
                end
                local function load()
                    local ok, message = self:Load(name)
                    notify(
                        self,
                        "Config",
                        if ok then string.format("Loaded %s (%s)", name, tostring(message)) else tostring(message)
                    )
                end
                local shown = dialog(self, {
                    Title = "Load config",
                    Description = string.format("Loading %q replaces the settings you are using now.", name),
                    FooterButtons = {
                        { Title = "Cancel", Order = 1, Variant = "Ghost" },
                        { Title = "Load", Order = 2, Callback = load },
                    },
                })
                if not shown then
                    load()
                end
            end,
        })

        box:AddButton({
            Text = "Overwrite config",
            Disabled = not canPersist,
            Callback = function()
                local name = selected()
                if not name then
                    notify(self, "Config", "Select a config first")
                    return
                end
                local shown = dialog(self, {
                    Title = "Overwrite config",
                    Description = string.format(
                        "%q will be replaced with your current settings. This cannot be undone.",
                        name
                    ),
                    FooterButtons = {
                        { Title = "Cancel", Order = 1, Variant = "Ghost" },
                        {
                            Title = "Overwrite",
                            Order = 2,
                            Variant = "Destructive",
                            Callback = function()
                                write(name)
                            end,
                        },
                    },
                })
                if not shown then
                    write(name)
                end
            end,
        })

        box:AddButton({
            Text = "Delete config",
            Risky = true,
            Disabled = not canPersist,
            Callback = function()
                local name = selected()
                if not name then
                    notify(self, "Config", "Select a config first")
                    return
                end
                local function remove()
                    local ok, message = self:Delete(name)
                    notify(self, "Config", if ok then "Deleted " .. name else tostring(message))
                    self:_RefreshList()
                end
                local shown = dialog(self, {
                    Title = "Delete config",
                    Description = string.format("%q will be deleted. This cannot be undone.", name),
                    FooterButtons = {
                        { Title = "Cancel", Order = 1, Variant = "Ghost" },
                        { Title = "Delete", Order = 2, Variant = "Destructive", Callback = remove },
                    },
                })
                if not shown then
                    remove()
                end
            end,
        })

        box:AddButton({
            Text = "Refresh list",
            Disabled = not canPersist,
            Callback = function()
                self:_RefreshList()
            end,
        })

        box:AddButton({
            Text = "Set as autoload",
            Disabled = not canPersist,
            Callback = function()
                local name = selected()
                if not name then
                    notify(self, "Config", "Select a config first")
                    return
                end
                local ok, message = self:SaveAutoloadConfig(name)
                notify(self, "Config", if ok then name .. " will load on startup" else tostring(message))
                self:_RefreshList()
            end,
        })

        box:AddButton({
            Text = "Reset autoload",
            Disabled = not canPersist,
            Callback = function()
                local function reset()
                    self:DeleteAutoLoadConfig()
                    notify(self, "Config", "No config will load on startup")
                    self:_RefreshList()
                end
                local shown = dialog(self, {
                    Title = "Reset autoload",
                    Description = "No config will be loaded when this script next runs.",
                    FooterButtons = {
                        { Title = "Cancel", Order = 1, Variant = "Ghost" },
                        { Title = "Reset", Order = 2, Callback = reset },
                    },
                })
                if not shown then
                    reset()
                end
            end,
        })

        self.AutoloadLabel = box:AddLabel({ Text = "Current autoload config: none", Secondary = true, Wrap = true })

        box = section("Transfer", "Right")
        local json = box:AddTextArea("SaveManager_JSON", {
            Text = "Config JSON",
            Placeholder = "Paste a config",
        })

        box:AddButton({
            Text = "Import config",
            Callback = function()
                local function load()
                    local ok, message = self:LoadJSON(json.Value)
                    notify(
                        self,
                        "Config",
                        if ok then "Config imported (" .. tostring(message) .. ")" else tostring(message)
                    )
                end
                local shown = dialog(self, {
                    Title = "Import config",
                    Description = "This replaces the settings you are using now.",
                    FooterButtons = {
                        { Title = "Cancel", Order = 1, Variant = "Ghost" },
                        { Title = "Import", Order = 2, Callback = load },
                    },
                })
                if not shown then
                    load()
                end
            end,
        })

        box:AddButton({
            Text = "Export current config",
            Callback = function()
                local ok, encoded = self:SaveJSON()
                if not ok then
                    notify(self, "Config", encoded)
                    return
                end
                json:SetValue(encoded)
                if store:SetClipboard(encoded) then
                    notify(self, "Config", "Config copied to clipboard")
                else
                    notify(self, "Config", "Config placed in the field below")
                end
            end,
        })
    end

    -- The manager's own fields are interface, not settings. Ignoring them here
    -- rather than at the call site means a script cannot forget to do it.
    self:SetIgnoreIndexes({
        "SaveManager_ConfigName",
        "SaveManager_ConfigList",
        "SaveManager_JSON",
    })

    if not canPersist then
        self.AutoloadLabel:SetText("Saving configs is unavailable on this host")
    end

    self:_RefreshList()
    return self.Groupbox
end

-- The config manager's own page, built exactly the way the theme manager's is:
-- ordinary module cards in the shell's own two columns, under a label in the
-- section's sub-tab strip. See ThemeManager.ApplyToTab.
function SaveManager.BuildConfigSection(self: any, tab: any): any
    assert(tab and not tab.Destroyed, "BuildConfigSection needs a live tab")
    if type(tab.AddSubTab) ~= "function" then
        return self:CreateConfigSection(tab:AddRightGroupbox("Configuration"))
    end
    local page = tab:AddSubTab("Config")
    self.Page = page
    self._Section = sectionsFromPage(page)
    return self:CreateConfigSection(nil)
end

return SaveManager
end)()

return Module3
