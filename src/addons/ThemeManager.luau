--!strict
local Persistence = require(script.Parent.Parent.core.Persistence)

local ThemeData = require(script.Parent.Parent.core.ThemeData)

local ThemeManager = {}

local EDITABLE: { string } = {
    "BackgroundColor",
    "MainColor",
    "AccentColor",
    "OutlineColor",
    "FontColor",
}

-- The stable option ids the manager's controls register under. SaveManager
-- reads this list through IgnoreThemeSettings, which is what keeps a normal
-- config from carrying a theme.
ThemeManager.OptionIds = ThemeData.OptionIds
ThemeManager.ToHex = ThemeData.ToHex
ThemeManager.ToColor = ThemeData.ToColor
local toHex, toColor = ThemeData.ToHex, ThemeData.ToColor

export type ThemeData = {
    BackgroundColor: string,
    MainColor: string,
    AccentColor: string,
    OutlineColor: string,
    FontColor: string,
    FontFace: string?,
}

ThemeManager.BuiltInThemes = {
    {
        "Default",
        {
            BackgroundColor = "#111114",
            MainColor = "#16161A",
            AccentColor = "#6984FA",
            OutlineColor = "#2D2E36",
            FontColor = "#EBECF0",
        },
    },
    {
        "BBot",
        {
            BackgroundColor = "#1E1E1E",
            MainColor = "#282828",
            AccentColor = "#7E2ADB",
            OutlineColor = "#323232",
            FontColor = "#FFFFFF",
        },
    },
    {
        "Fatality",
        {
            BackgroundColor = "#1E1842",
            MainColor = "#191335",
            AccentColor = "#C50754",
            OutlineColor = "#3A2D5E",
            FontColor = "#FFFFFF",
        },
    },
    {
        "Jester",
        {
            BackgroundColor = "#101010",
            MainColor = "#1C1C1C",
            AccentColor = "#DB2D5B",
            OutlineColor = "#242424",
            FontColor = "#FFFFFF",
        },
    },
    {
        "Mint",
        {
            BackgroundColor = "#0F1512",
            MainColor = "#171E1A",
            AccentColor = "#3EDBA0",
            OutlineColor = "#243029",
            FontColor = "#E6F2EC",
        },
    },
    {
        "Tokyo Night",
        {
            BackgroundColor = "#1A1B26",
            MainColor = "#24283B",
            AccentColor = "#7AA2F7",
            OutlineColor = "#414868",
            FontColor = "#C0CAF5",
        },
    },
    {
        "Ubuntu",
        {
            BackgroundColor = "#1D1715",
            MainColor = "#2C2220",
            AccentColor = "#E95420",
            OutlineColor = "#3D302C",
            FontColor = "#EEEEEC",
        },
    },
    {
        "Quartz",
        {
            BackgroundColor = "#191919",
            MainColor = "#232323",
            AccentColor = "#A9A9B8",
            OutlineColor = "#333333",
            FontColor = "#F0F0F2",
        },
    },
    {
        "Nord",
        {
            BackgroundColor = "#2E3440",
            MainColor = "#3B4252",
            AccentColor = "#88C0D0",
            OutlineColor = "#4C566A",
            FontColor = "#ECEFF4",
        },
    },
    {
        "Dracula",
        {
            BackgroundColor = "#282A36",
            MainColor = "#343746",
            AccentColor = "#BD93F9",
            OutlineColor = "#44475A",
            FontColor = "#F8F8F2",
        },
    },
    {
        "Monokai",
        {
            BackgroundColor = "#272822",
            MainColor = "#32332C",
            AccentColor = "#A6E22E",
            OutlineColor = "#49483E",
            FontColor = "#F8F8F2",
        },
    },
    {
        "Gruvbox",
        {
            BackgroundColor = "#282828",
            MainColor = "#32302F",
            AccentColor = "#FABD2F",
            OutlineColor = "#504945",
            FontColor = "#EBDBB2",
        },
    },
    {
        "Solarized",
        {
            BackgroundColor = "#002B36",
            MainColor = "#073642",
            AccentColor = "#268BD2",
            OutlineColor = "#0E4A59",
            FontColor = "#EEE8D5",
        },
    },
    {
        "Catppuccin",
        {
            BackgroundColor = "#1E1E2E",
            MainColor = "#282839",
            AccentColor = "#CBA6F7",
            OutlineColor = "#45475A",
            FontColor = "#CDD6F4",
        },
    },
    {
        "One Dark",
        {
            BackgroundColor = "#282C34",
            MainColor = "#31363F",
            AccentColor = "#61AFEF",
            OutlineColor = "#3E4451",
            FontColor = "#ABB2BF",
        },
    },
    {
        "Cyberpunk",
        {
            BackgroundColor = "#0B0E14",
            MainColor = "#131822",
            AccentColor = "#00E5FF",
            OutlineColor = "#1F2733",
            FontColor = "#E4F3F7",
        },
    },
    {
        "Oceanic Next",
        {
            BackgroundColor = "#1B2B34",
            MainColor = "#23353F",
            AccentColor = "#6699CC",
            OutlineColor = "#334E5C",
            FontColor = "#D8DEE9",
        },
    },
    {
        "Material",
        {
            BackgroundColor = "#212121",
            MainColor = "#2B2B2B",
            AccentColor = "#80CBC4",
            OutlineColor = "#3A3A3A",
            FontColor = "#EEFFFF",
        },
    },
} :: { { any } }

--// State ---------------------------------------------------------------------

ThemeManager.Library = nil :: any
ThemeManager.Folder = "Zedlib"
ThemeManager.AppliedToTab = false
ThemeManager.DefaultThemeName = nil :: string?
ThemeManager.Groupbox = nil :: any
ThemeManager.Options = nil :: any
ThemeManager._LowContrast = false
ThemeManager._Applying = false

local THEME_EXTENSION = ".json"
local DEFAULT_FILE = "default.txt"

--// Plumbing ------------------------------------------------------------------

local function library(self: any): any
    local value = self.Library
    assert(value ~= nil, "ThemeManager:SetLibrary(Library) must be called first")
    assert(not value.Unloaded, "ThemeManager is bound to an unloaded library")
    return value
end

local function storage(self: any): any
    return library(self).Runtime.Storage
end

-- Notifications go to the window when there is one. Before the interface
-- exists, or on a host where the shell was never built, the message still has
-- to reach someone, so it falls back to the library's reporting hook.
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
    local id = "ThemeManager_Confirm_" .. tostring(self._DialogCount)
    local instance = window:AddDialog(id, config)
    instance:Open()
    return true
end

--// Setup ---------------------------------------------------------------------

function ThemeManager.SetLibrary(self: any, value: any): any
    assert(type(value) == "table" and value.Loaded ~= nil, "SetLibrary expects a Zedlib library")
    self.Library = value
    return self
end

function ThemeManager.SetFolder(self: any, folder: string): any
    local resolved, message = Persistence.ValidateFolder(folder, "Theme folder")
    assert(resolved, message)
    self.Folder = resolved
    return self
end

function ThemeManager.GetPaths(self: any): { Folder: string, Themes: string, Default: string }
    local themes = Persistence.Join(self.Folder, "themes")
    return {
        Folder = self.Folder,
        Themes = themes,
        Default = Persistence.Join(themes, DEFAULT_FILE),
    }
end

function ThemeManager.ThemePath(self: any, name: string): string
    return Persistence.Join(self:GetPaths().Themes, name .. THEME_EXTENSION)
end

-- Creates the folders the manager writes into. A host without a filesystem is
-- not an error here: the manager still runs, themes still switch live, and only
-- the persistence buttons report that they cannot do their job.
function ThemeManager.BuildFolderTree(self: any): (boolean, string?)
    local store = storage(self)
    if not store.Available then
        return false, "This host does not support saving themes"
    end
    local ok, message = store:EnsureFolder(self:GetPaths().Themes)
    return ok, message
end

function ThemeManager.CheckFolderTree(self: any): boolean
    local ok = self:BuildFolderTree()
    return ok
end

--// Default theme override ----------------------------------------------------
-- Redefines what the built-in "Default" entry means, for a script that ships
-- its own palette but still wants the manager's list. Called before the manager
-- is attached; afterwards the dropdown has already been built from the old
-- values and the two would disagree.

function ThemeManager.SetDefaultTheme(self: any, values: { [string]: any }): any
    assert(not self.AppliedToTab, "SetDefaultTheme must be called before the ThemeManager UI is created")
    assert(type(values) == "table", "SetDefaultTheme expects a table of scheme values")

    local entry = self.BuiltInThemes[1][2] :: { [string]: any }
    for _, key in EDITABLE do
        local supplied = values[key]
        if supplied ~= nil then
            local color = toColor(supplied)
            assert(color, string.format("SetDefaultTheme: %s must be a Color3 or a hex string", key))
            entry[key] = toHex(color)
        end
    end
    if values.FontFace ~= nil then
        assert(type(values.FontFace) == "string", "SetDefaultTheme: FontFace must be a string")
        entry.FontFace = values.FontFace
    end

    -- The running library adopts the new definition immediately, so a script
    -- that calls this at startup does not show its old palette for a frame.
    if self.Library then
        self:ApplyThemeData(entry)
    end
    return self
end

--// Theme data ----------------------------------------------------------------

function ThemeManager.GetBuiltInTheme(self: any, name: string): ThemeData?
    for _, entry in self.BuiltInThemes do
        if entry[1] == name then
            return table.clone(entry[2])
        end
    end
    return nil
end

function ThemeManager.GetBuiltInNames(self: any): { string }
    local names: { string } = {}
    for _, entry in self.BuiltInThemes do
        table.insert(names, entry[1] :: string)
    end
    return names
end

-- The current live scheme, as a theme file. Source values only: the derived
-- roles are recomputed from these on load, so persisting them would create a
-- second, staler description of the same thing.
function ThemeManager.GetCurrentThemeData(self: any): ThemeData
    local lib = library(self)
    local data: { [string]: any } = {}
    for _, key in EDITABLE do
        data[key] = toHex(lib.Source[key])
    end
    local window = lib.Window
    if window and window.Typography then
        data.FontFace = window.Typography:CurrentFamilyName()
    end
    return data :: any
end

-- Reads a theme table into the running library.
--
-- This is the only application path. Built-in themes, custom theme files, JSON
-- imports and the default-theme loader all end here, which is why they cannot
-- disagree about what applying a theme means. A missing key keeps its current
-- value rather than falling back to a shipped colour, so a partial theme edits
-- rather than resets.
function ThemeManager.ApplyThemeData(self: any, data: { [string]: any }): (boolean, string?)
    if type(data) ~= "table" then
        return false, "Theme data must be a table"
    end
    local lib = library(self)

    local patch: { [string]: any } = {}
    for _, key in EDITABLE do
        local supplied = data[key]
        if supplied ~= nil then
            local color = toColor(supplied)
            if not color then
                return false, string.format("%s is not a colour", key)
            end
            patch[key] = color
        end
    end

    -- Guards the option controls' own change callbacks. Writing five pickers
    -- would otherwise re-enter this function five times, each with a scheme
    -- that is partly the old theme and partly the new one.
    self._Applying = true

    local ok, message = pcall(function()
        lib:SetSource(patch)
    end)

    local window = lib.Window
    if ok and type(data.FontFace) == "string" and window and window.Typography then
        if window.Typography:SetFamily(data.FontFace) then
            window:Refresh()
        end
    end

    -- The manager's own controls are display state, not the source of truth, so
    -- they are brought in line after the scheme rather than driving it.
    self:_SyncControls()
    self._Applying = false

    if not ok then
        return false, tostring(message)
    end

    self:_UpdateContrast()
    return true, nil
end

function ThemeManager.ApplyTheme(self: any, name: string): (boolean, string?)
    local builtIn = self:GetBuiltInTheme(name)
    if builtIn then
        return self:ApplyThemeData(builtIn)
    end
    local custom = self:GetCustomTheme(name)
    if custom then
        return self:ApplyThemeData(custom)
    end
    return false, string.format("No theme named %q", name)
end

-- Called by the manager's colour pickers. The picker already holds the new
-- value, so this reads the controls and pushes them into the scheme, which is
-- the opposite direction to ApplyThemeData.
function ThemeManager.ThemeUpdate(self: any)
    if self._Applying or not self.Options then
        return
    end
    local lib = library(self)
    local patch: { [string]: any } = {}
    for _, key in EDITABLE do
        local control = self.Options[key]
        if control and not control.Destroyed then
            patch[key] = control.Value
        end
    end
    local ok, message = pcall(function()
        lib:SetSource(patch)
    end)
    if not ok then
        notify(self, "Theme", tostring(message))
        return
    end
    self:_UpdateContrast()
end

--// Contrast ------------------------------------------------------------------
-- The theme engine reports every pair it knows about. The manager shows the
-- weakest of them, because that is the one that will be unreadable first.

local NORMAL_TEXT_TARGET = 4.5

local MANAGER_PAIRS: { any } = {
    {
        Name = "text on the window canvas",
        Foreground = "Text.Primary",
        Background = "Surface.Canvas",
        Threshold = NORMAL_TEXT_TARGET,
    },
    {
        Name = "text on groupboxes",
        Foreground = "Text.Primary",
        Background = "Surface.Primary",
        Threshold = NORMAL_TEXT_TARGET,
    },
    {
        Name = "text on raised surfaces",
        Foreground = "Text.Primary",
        Background = "Surface.Raised",
        Threshold = NORMAL_TEXT_TARGET,
    },
    {
        Name = "values in input fields",
        Foreground = "Text.Primary",
        Background = "Surface.Sunken",
        Threshold = NORMAL_TEXT_TARGET,
    },
    {
        Name = "text in popups",
        Foreground = "Text.Primary",
        Background = "Surface.Popup",
        Threshold = NORMAL_TEXT_TARGET,
    },
    {
        Name = "secondary text",
        Foreground = "Text.Secondary",
        Background = "Surface.Primary",
        Threshold = NORMAL_TEXT_TARGET,
    },
}

ThemeManager.ContrastPairs = MANAGER_PAIRS

function ThemeManager.GetContrastReport(self: any): any
    return library(self).Theme:AnalyzeContrast(MANAGER_PAIRS)
end

function ThemeManager._Weakest(self: any): (number, string)
    local report = self:GetContrastReport()
    local worst = math.huge
    local label = "text"
    for _, result in report.Results do
        if result.Required >= NORMAL_TEXT_TARGET and result.Ratio < worst then
            worst = result.Ratio
            label = result.Name or label
        end
    end
    if worst == math.huge then
        return 21, label
    end
    return worst, label
end

function ThemeManager._UpdateContrast(self: any)
    if not self.Options then
        return
    end
    local ratio, label = self:_Weakest()
    local poor = ratio < NORMAL_TEXT_TARGET

    local display = self.ContrastLabel
    if display and not display.Destroyed then
        if poor then
            display:SetText(string.format("Low contrast (%.1f:1) on %s", ratio, label))
        else
            display:SetText(string.format("Contrast check: good (%.1f:1)", ratio))
        end
        -- The warning is carried by the primary/secondary text distinction the
        -- library already has, rather than by a colour this module invents: a
        -- passing check sits quietly at the secondary level, a failing one is
        -- promoted to primary and reads at the same weight as a control label.
        display:SetSecondary(not poor)
    end

    -- Only the transition into a poor state is worth interrupting the user for.
    -- Dragging a colour picker through a bad region would otherwise produce one
    -- notification per pixel of travel.
    if poor and not self._LowContrast then
        notify(self, "Low contrast", string.format("%s is at %.1f:1. Text may be hard to read.", label, ratio))
    end
    self._LowContrast = poor
end

--// Custom themes -------------------------------------------------------------

function ThemeManager.ReloadCustomThemes(self: any): { string }
    local paths = self:GetPaths()
    local ok, entries = storage(self):ListFiles(paths.Themes)
    if not ok then
        return {}
    end
    local names: { string } = {}
    for _, entry in entries :: { string } do
        -- default.txt is the manager's own metadata, not a theme.
        if string.sub(string.lower(entry), -#THEME_EXTENSION) == THEME_EXTENSION then
            table.insert(names, Persistence.BaseName(entry, THEME_EXTENSION))
        end
    end
    table.sort(names)
    return names
end

-- Returns the decoded theme, or nil. A file that is missing, unreadable, not
-- JSON or not a table is all the same answer to the caller: there is no theme
-- by that name that can be applied.
function ThemeManager.GetCustomTheme(self: any, name: string): ThemeData?
    local valid = Persistence.ValidateName(name, "Theme name")
    if not valid then
        return nil
    end
    local store = storage(self)
    local path = self:ThemePath(valid)
    local ok, contents = store:ReadFile(path)
    if not ok then
        return nil
    end
    local decoded, value = store:Decode(contents)
    if not decoded or type(value) ~= "table" then
        return nil
    end
    return value
end

function ThemeManager.SaveCustomTheme(self: any, name: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(name, "Theme name")
    if not valid then
        return false, message
    end
    if string.lower(valid) == "default" then
        return false, '"default" is reserved; the built-in Default theme cannot be overwritten'
    end

    local store = storage(self)
    if not store.Available then
        return false, "This host does not support saving themes"
    end
    local built, buildMessage = self:BuildFolderTree()
    if not built then
        return false, buildMessage
    end

    local encoded, json = store:Encode(self:GetCurrentThemeData())
    if not encoded then
        return false, json
    end
    local written, writeMessage = store:WriteFile(self:ThemePath(valid), json)
    if not written then
        return false, writeMessage
    end
    return true, nil
end

function ThemeManager.Delete(self: any, name: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(name, "Theme name")
    if not valid then
        return false, message
    end
    local store = storage(self)
    local deleted, deleteMessage = store:DeleteFile(self:ThemePath(valid))
    if not deleted then
        return false, deleteMessage
    end
    -- A default pointing at a file that no longer exists would notify a failure
    -- on every load, so the pointer goes with the file.
    if self:GetDefaultTheme() == valid then
        self:DeleteDefaultTheme()
    end
    return true, nil
end

--// Persisted default ---------------------------------------------------------

function ThemeManager.GetDefaultTheme(self: any): string?
    local ok, contents = storage(self):ReadFile(self:GetPaths().Default)
    if not ok then
        return nil
    end
    local trimmed = string.match(contents, "^%s*(.-)%s*$") :: string
    return if trimmed == "" then nil else trimmed
end

function ThemeManager.SaveDefault(self: any, name: string): (boolean, string?)
    local valid, message = Persistence.ValidateName(name, "Theme name")
    if not valid then
        return false, message
    end
    if not self:GetBuiltInTheme(valid) and not self:GetCustomTheme(valid) then
        return false, string.format("No theme named %q", valid)
    end
    local built, buildMessage = self:BuildFolderTree()
    if not built then
        return false, buildMessage
    end
    local ok, writeMessage = storage(self):WriteFile(self:GetPaths().Default, valid)
    if not ok then
        return false, writeMessage
    end
    self.DefaultThemeName = valid
    return true, nil
end

function ThemeManager.DeleteDefaultTheme(self: any): (boolean, string?)
    self.DefaultThemeName = nil
    local store = storage(self)
    local path = self:GetPaths().Default
    if not store:IsFile(path) then
        return true, nil
    end
    return store:DeleteFile(path)
end

-- Applies the persisted default, if there is one.
--
-- Three outcomes, and only one of them is a problem. No default configured is
-- the ordinary first-run state and says nothing. A default that loads applies
-- silently, because the user chose it and does not need telling. A default that
-- names a theme which has since been deleted or corrupted is worth a message,
-- since the interface is about to look wrong for a reason the user cannot see.
function ThemeManager.LoadDefault(self: any): boolean
    local name = self:GetDefaultTheme()
    if not name then
        return false
    end
    self.DefaultThemeName = name
    local ok, message = self:ApplyTheme(name)
    if not ok then
        notify(self, "Theme", string.format("Could not load default theme %q: %s", name, tostring(message)))
        return false
    end
    return true
end

--// JSON ----------------------------------------------------------------------

function ThemeManager.SaveJSON(self: any): (boolean, string)
    return storage(self):Encode(self:GetCurrentThemeData())
end

function ThemeManager.LoadJSON(self: any, content: string): (boolean, string?)
    if type(content) ~= "string" or string.match(content, "^%s*$") then
        return false, "Paste a theme first"
    end
    local ok, decoded = storage(self):Decode(content)
    if not ok then
        return false, "That is not valid JSON"
    end
    if type(decoded) ~= "table" then
        return false, "A theme must be a JSON object"
    end

    -- An import replaces the whole palette, so it must be complete. A partial
    -- object here is much more likely to be the wrong file than a deliberate
    -- patch, and half-applying it would leave a scheme nobody authored.
    local missing: { string } = {}
    for _, key in EDITABLE do
        if decoded[key] == nil then
            table.insert(missing, key)
        elseif not toColor(decoded[key]) then
            return false, string.format("%s is not a colour", key)
        end
    end
    if #missing > 0 then
        return false, "Missing " .. table.concat(missing, ", ")
    end
    if decoded.FontFace ~= nil and type(decoded.FontFace) ~= "string" then
        return false, "FontFace must be a string"
    end

    return self:ApplyThemeData(decoded)
end

--// Interface -----------------------------------------------------------------

local function themeNames(self: any): { string }
    local names = self:GetBuiltInNames()
    local default = self.DefaultThemeName
    if default then
        for index, name in names do
            -- "Default (default)" reads as a bug rather than as information.
            if name == default and name ~= "Default" then
                names[index] = name .. " (default)"
            end
        end
    end
    return names
end

local function stripMarker(name: string?): string?
    if type(name) ~= "string" then
        return nil
    end
    return (string.gsub(name, "%s%(default%)$", ""))
end

function ThemeManager._SyncControls(self: any)
    local options = self.Options
    if not options then
        return
    end
    local lib = library(self)
    for _, key in EDITABLE do
        local control = options[key]
        if control and not control.Destroyed and control.Value ~= lib.Source[key] then
            control:SetValue(lib.Source[key])
        end
    end
    local font = options.FontFace
    local window = lib.Window
    if font and not font.Destroyed and window and window.Typography then
        local current = window.Typography:CurrentFamilyName()
        if font.Value ~= current then
            font:SetValue(current)
        end
    end
end

function ThemeManager._RefreshCustomList(self: any)
    local list = self.Options and self.Options.ThemeManager_CustomThemeList
    if not list or list.Destroyed then
        return
    end
    local names = self:ReloadCustomThemes()
    local default = self.DefaultThemeName
    local labelled: { string } = {}
    for _, name in names do
        table.insert(labelled, if name == default then name .. " (default)" else name)
    end
    list:SetValues(labelled)

    local display = self.DefaultLabel
    if display and not display.Destroyed then
        display:SetText("Current default theme: " .. (default or "none"))
    end
end

function ThemeManager._RefreshThemeList(self: any)
    local list = self.Options and self.Options.ThemeManager_ThemeList
    if list and not list.Destroyed then
        local selected = stripMarker(list.Value)
        list:SetValues(themeNames(self))
        if selected then
            for _, candidate in list.Values do
                if stripMarker(candidate) == selected then
                    list:SetValue(candidate)
                    break
                end
            end
        end
    end
    self:_RefreshCustomList()
end

-- Builds the manager's section inside a groupbox the caller owns.
--
-- Every control here is one of the library's ordinary controls, registered
-- under an ordinary option id. There is no manager-only widget: the colour
-- picker in the theme editor is the same colour picker a script would add to
-- its own groupbox, which is why the section looks like part of the interface
-- rather than like a panel bolted to it.
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

function ThemeManager.CreateThemeManager(self: any, groupbox: any?): any
    -- A page supplies its own sections; a lone groupbox is the only section.
    assert(self._Section ~= nil or (groupbox and not groupbox.Destroyed), "CreateThemeManager needs a live groupbox")
    assert(self.Library, "ThemeManager:SetLibrary(Library) must be called first")
    assert(not self.AppliedToTab, "The ThemeManager UI has already been created")

    local lib = library(self)
    self.AppliedToTab = true
    self.Options = lib.Options
    self.DefaultThemeName = self:GetDefaultTheme()

    local store = storage(self)
    local canPersist = store.Available

    local section = self._Section or sectionsFromGroupbox(groupbox)
    self._Section = nil

    do
        --// Live scheme editing.
        local box = section("Palette", "Left")
        self.Groupbox = box
        for _, key in EDITABLE do
            -- "AccentColor" reads as "Accent color" in the interface, so the
            -- label is derived rather than restated and cannot drift from the id.
            local text = (string.gsub(key, "Color$", " color"))
            text = string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
            local picker = box:AddColorPicker(key, {
                Text = text,
                Default = lib.Source[key],
            })
            picker:OnChanged(function()
                self:ThemeUpdate()
            end)
        end

        self.ContrastLabel = box:AddLabel({ Text = "Contrast check: good", Secondary = true, Wrap = true })

        local window = lib.Window
        if window and window.Typography then
            local fonts = window.Typography:GetFamilyNames()
            local font = box:AddDropdown("FontFace", {
                Text = "Font",
                Values = fonts,
                Default = window.Typography:CurrentFamilyName(),
            })
            font:OnChanged(function(value)
                if self._Applying or type(value) ~= "string" then
                    return
                end
                if window.Typography:SetFamily(value) then
                    window:Refresh()
                end
            end)
        end

        --// Built-in themes.
        box = section("Presets", "Left")
        local list = box:AddDropdown("ThemeManager_ThemeList", {
            Text = "Theme",
            Values = themeNames(self),
            Default = self.DefaultThemeName or "Default",
        })
        list:OnChanged(function(value)
            local name = stripMarker(value)
            if not name or self._Applying then
                return
            end
            local ok, message = self:ApplyTheme(name)
            if not ok then
                notify(self, "Theme", tostring(message))
            end
        end)

        box:AddButton({
            Text = "Set as default",
            Callback = function()
                local name = stripMarker(list.Value)
                if not name then
                    return
                end
                local ok, message = self:SaveDefault(name)
                notify(self, "Theme", if ok then name .. " will load on startup" else tostring(message))
                self:_RefreshThemeList()
            end,
        })

        --// Custom themes.
        box = section("Custom themes", "Right")
        local nameInput = box:AddInput("ThemeManager_CustomThemeName", {
            Text = "Custom theme name",
            Placeholder = "My theme",
            Disabled = not canPersist,
        })

        local customList = box:AddDropdown("ThemeManager_CustomThemeList", {
            Text = "Custom themes",
            Values = {},
            AllowNull = true,
            Disabled = not canPersist,
        })

        local function selectedCustom(): string?
            return stripMarker(customList.Value)
        end

        -- One save path for both Create and Overwrite. The only difference is
        -- whether the file already exists, and that is checked by the caller.
        local function commitSave(name: string)
            local ratio = self:_Weakest()
            local function write()
                local ok, message = self:SaveCustomTheme(name)
                notify(self, "Theme", if ok then "Saved " .. name else tostring(message))
                if ok then
                    self:_RefreshCustomList()
                end
            end
            if ratio >= NORMAL_TEXT_TARGET then
                write()
                return
            end
            -- A failing contrast report is a warning, not a veto: it is the
            -- user's interface and they may have a reason.
            local shown = dialog(self, {
                Title = "Low contrast theme",
                Description = string.format(
                    "This theme has a contrast ratio of %.1f:1. Text may be hard to read.",
                    ratio
                ),
                FooterButtons = {
                    { Title = "Cancel", Order = 1, Variant = "Ghost" },
                    { Title = "Save anyway", Order = 2, Callback = write },
                },
            })
            if not shown then
                write()
            end
        end

        box:AddButton({
            Text = "Create theme",
            Disabled = not canPersist,
            Callback = function()
                local valid, message = Persistence.ValidateName(nameInput.Value, "Theme name")
                if not valid then
                    notify(self, "Theme", tostring(message))
                    return
                end
                if string.lower(valid) == "default" then
                    notify(self, "Theme", '"default" is reserved')
                    return
                end
                if store:IsFile(self:ThemePath(valid)) then
                    local shown = dialog(self, {
                        Title = "Overwrite theme",
                        Description = string.format("%q already exists. This cannot be undone.", valid),
                        FooterButtons = {
                            { Title = "Cancel", Order = 1, Variant = "Ghost" },
                            {
                                Title = "Overwrite",
                                Order = 2,
                                Variant = "Destructive",
                                Callback = function()
                                    commitSave(valid)
                                end,
                            },
                        },
                    })
                    if shown then
                        return
                    end
                end
                commitSave(valid)
            end,
        })

        box:AddButton({
            Text = "Load theme",
            Disabled = not canPersist,
            Callback = function()
                local name = selectedCustom()
                if not name then
                    notify(self, "Theme", "Select a theme first")
                    return
                end
                local ok, message = self:ApplyTheme(name)
                notify(self, "Theme", if ok then "Loaded " .. name else tostring(message))
            end,
        })

        box:AddButton({
            Text = "Overwrite theme",
            Disabled = not canPersist,
            Callback = function()
                local name = selectedCustom()
                if not name then
                    notify(self, "Theme", "Select a theme first")
                    return
                end
                local shown = dialog(self, {
                    Title = "Overwrite theme",
                    Description = string.format(
                        "%q will be replaced with the current colours. This cannot be undone.",
                        name
                    ),
                    FooterButtons = {
                        { Title = "Cancel", Order = 1, Variant = "Ghost" },
                        {
                            Title = "Overwrite",
                            Order = 2,
                            Variant = "Destructive",
                            Callback = function()
                                commitSave(name)
                            end,
                        },
                    },
                })
                if not shown then
                    commitSave(name)
                end
            end,
        })

        box:AddButton({
            Text = "Delete theme",
            Risky = true,
            Disabled = not canPersist,
            Callback = function()
                local name = selectedCustom()
                if not name then
                    notify(self, "Theme", "Select a theme first")
                    return
                end
                local function remove()
                    local ok, message = self:Delete(name)
                    notify(self, "Theme", if ok then "Deleted " .. name else tostring(message))
                    self:_RefreshCustomList()
                end
                local shown = dialog(self, {
                    Title = "Delete theme",
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
                self:_RefreshCustomList()
            end,
        })

        box:AddButton({
            Text = "Set as default",
            Disabled = not canPersist,
            Callback = function()
                local name = selectedCustom()
                if not name then
                    notify(self, "Theme", "Select a theme first")
                    return
                end
                local ok, message = self:SaveDefault(name)
                notify(self, "Theme", if ok then name .. " will load on startup" else tostring(message))
                self:_RefreshThemeList()
            end,
        })

        box:AddButton({
            Text = "Reset default",
            Disabled = not canPersist,
            Callback = function()
                self:DeleteDefaultTheme()
                notify(self, "Theme", "No theme will load on startup")
                self:_RefreshThemeList()
            end,
        })

        self.DefaultLabel = box:AddLabel({ Text = "Current default theme: none", Secondary = true, Wrap = true })

        --// Import and export.
        box = section("Transfer", "Right")
        local json = box:AddTextArea("ThemeManager_ThemeJSON", {
            Text = "Theme JSON",
            Placeholder = "Paste a theme",
        })

        box:AddButton({
            Text = "Import theme",
            Callback = function()
                local function load()
                    local ok, message = self:LoadJSON(json.Value)
                    notify(self, "Theme", if ok then "Theme imported" else tostring(message))
                end
                local shown = dialog(self, {
                    Title = "Import theme",
                    Description = "This replaces the colours you are using now.",
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
            Text = "Export current theme",
            Callback = function()
                local ok, encoded = self:SaveJSON()
                if not ok then
                    notify(self, "Theme", encoded)
                    return
                end
                json:SetValue(encoded)
                -- Clipboard support is optional, so the export succeeds either
                -- way and the message only reports what actually happened.
                if store:SetClipboard(encoded) then
                    notify(self, "Theme", "Theme copied to clipboard")
                else
                    notify(self, "Theme", "Theme placed in the field below")
                end
            end,
        })
    end

    if not canPersist then
        self.DefaultLabel:SetText("Saving themes is unavailable on this host")
    end

    self:_RefreshCustomList()
    self:_UpdateContrast()
    self.LoadedDefault = self:LoadDefault()
    self:_RefreshThemeList()
    return self.Groupbox
end

function ThemeManager.ApplyToGroupbox(self: any, groupbox: any): any
    return self:CreateThemeManager(groupbox)
end

-- The manager's own page inside a section. It is a page like any other: the
-- shell gives it a label in that section's sub-tab strip and two columns to
-- fill, and the manager fills them with ordinary module cards. Nothing here is
-- styled by the manager, which is the point -- the settings screen is part of
-- the shell rather than a panel dropped into it.
--
-- A caller that hands over something without pages still gets the single-card
-- spelling, unchanged.
function ThemeManager.ApplyToTab(self: any, tab: any): any
    assert(tab and not tab.Destroyed, "ApplyToTab needs a live tab")
    if type(tab.AddSubTab) ~= "function" then
        return self:CreateThemeManager(tab:AddLeftGroupbox("Themes"))
    end
    local page = tab:AddSubTab("Theme")
    self.Page = page
    self._Section = sectionsFromPage(page)
    return self:CreateThemeManager(nil)
end

return ThemeManager
