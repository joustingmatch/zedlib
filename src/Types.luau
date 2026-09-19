--!strict
local Theme = require(script.Parent.core.Theme)

export type Cleanup = () -> ()
export type Scope = {
    Destroyed: boolean,
    Add: (self: Scope, cleanup: Cleanup) -> Cleanup,
    Child: (self: Scope) -> Scope,
    Destroy: (self: Scope) -> (),
}
export type Disposable = { Destroy: (self: Disposable) -> () }
export type BaseElement = {
    Destroyed: boolean,
    Resources: Scope,
    Destroy: (self: BaseElement) -> (),
}
export type RegistryKind = "Toggles" | "Options" | "Labels" | "Buttons"

--// Theme -------------------------------------------------------------------
-- The source scheme is what a theme authors: nine values. Everything else in
-- the interface is derived from it by core/Theme, so these are re-exported here
-- rather than redefined, and there is exactly one definition of each.
export type Scheme = Theme.Scheme
export type SourceKey = Theme.SourceKey
-- A role is one of core/Theme's canonical token names. Luau cannot express the
-- union and keep the token list in one place at the same time, so the list in
-- Theme.Roles is authoritative and every bind site is checked against it at
-- runtime; an unknown role raises rather than resolving to a default.
export type ThemeRole = Theme.Role
export type Palette = Theme.Palette
export type ContrastPair = Theme.ContrastPair
export type ContrastResult = Theme.ContrastResult
export type ContrastReport = Theme.ContrastReport
export type ValidationReport = Theme.ValidationReport

-- A bound property either names a role, or computes one from live component
-- state. A resolver may return a role name or a finished Color3; returning a
-- role is preferred, because a value chosen outside the palette is invisible to
-- the contrast engine.
export type ThemeBinding = ThemeRole | () -> ThemeRole | Color3
export type RegistryProperties = { [string]: ThemeBinding }
export type RegistryEntry = { Properties: RegistryProperties, Resources: Scope }

export type OwnershipSlot = { Release: Cleanup }
export type RuntimeAdapter = {
    ResolveGuiParent: (() -> Instance?)?,
    GetPlatform: (() -> string)?,
    -- Persist this table across executions when the host does not preserve `shared`.
    Ownership: { [string]: OwnershipSlot }?,
    -- Filesystem, clipboard and JSON overrides. Any function left out is looked
    -- up in the host environment instead; supplying the table in full is how a
    -- test drives the managers without touching a real disk.
    Storage: {
        isfolder: ((string) -> boolean)?,
        isfile: ((string) -> boolean)?,
        listfiles: ((string) -> { string })?,
        makefolder: ((string) -> ())?,
        readfile: ((string) -> string)?,
        writefile: ((string, string) -> ())?,
        delfile: ((string) -> ())?,
        setclipboard: ((string) -> ())?,
        JSON: any?,
    }?,
}
export type Config = {
    OwnershipKey: string?,
    Scale: number?,
    ErrorReporting: boolean?,
    OnError: ((message: string) -> ())?,
    Runtime: RuntimeAdapter?,
}
return {}
