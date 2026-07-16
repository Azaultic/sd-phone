---@type table sd-phone config root (configs/config.lua).
local config   = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid/name/phone-number lookups.
local player   = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): phone_settings row CRUD.
local settings = require 'server.settings.store'

---@type table Actions module; the table returned at end of file.
local actions = {}

local util = require 'server.util'
local ok, fail = util.ok, util.fail


-- Downloadable = every homescreen app NOT flagged `base`. Base apps are always installed and
-- can't be downloaded, so they're excluded. Built once at load from config.Homescreen.Apps; this
-- set is the whitelist every client-supplied app id is checked against, so the stored
-- installed_apps column only ever holds catalog slugs.
---@type table<string, boolean> Set of app ids a player may install/uninstall.
local DOWNLOADABLE = {}
for _, app in ipairs(config.Homescreen.Apps or {}) do
    if app.id and app.base ~= true then DOWNLOADABLE[app.id] = true end
end

---Drop ids that aren't currently valid downloadables (e.g. the config changed since they were
---installed, or a hand-edited row holds junk) and de-dupe, preserving order. Run on EVERY read of
---the stored list, so stale or crafted ids never reach the UI or get written back.
---@param ids string[] stored app ids
---@return string[] clean valid, de-duped ids
local function sanitize(ids)
    local out, seen = {}, {}
    for _, id in ipairs(ids or {}) do
        if DOWNLOADABLE[id] and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

---The caller's installed downloadable apps + saved home-screen layout, scoped to the citizenid
---resolved from src. Read-only.
---@param source number player server id
---@return table result { success, data = { installed, layout } }
function actions.list(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    return ok({
        installed = sanitize(settings.getInstalledApps(cid)),
        layout    = settings.getHomeLayout(cid),
    })
end

---Install one downloadable app for the caller. The id is whitelist-checked against DOWNLOADABLE
---(checked here, not just in the store UI, so calling the callback directly can't store an
---arbitrary string), and the stored list is re-sanitized before the append so junk never
---propagates. Idempotent: a replayed install of an already-installed app returns the unchanged
---list without a duplicate entry.
---@param source number player server id
---@param payload { id?: string } client payload
---@return table result { success, data = { installed } }
function actions.install(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local id = payload.id
    if type(id) ~= 'string' or not DOWNLOADABLE[id] then
        return fail('That app can\'t be downloaded')
    end

    local installed = sanitize(settings.getInstalledApps(cid))
    for _, existing in ipairs(installed) do
        if existing == id then return ok({ installed = installed }) end
    end
    installed[#installed + 1] = id
    settings.setInstalledApps(cid, installed)
    return ok({ installed = installed })
end

---Uninstall one app for the caller. The id is only ever used as an equality filter over the
---already-sanitized list, so any type or unknown value is safe and simply removes nothing.
---Idempotent: uninstalling something not installed rewrites the same list.
---@param source number player server id
---@param payload { id?: string } client payload
---@return table result { success, data = { installed } }
function actions.uninstall(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local id = payload.id
    local installed = sanitize(settings.getInstalledApps(cid))
    local remaining = {}
    for _, existing in ipairs(installed) do
        if existing ~= id then remaining[#remaining + 1] = existing end
    end
    settings.setInstalledApps(cid, remaining)
    return ok({ installed = remaining })
end

---Persist the caller's home-screen layout - an opaque JSON string from the UI (the slot
---arrangement). The server never parses it; the frontend owns the shape, so validation is type +
---a 16k size cap, which keeps a crafted payload from ballooning the TEXT column or DoS-ing the
---NUI that later renders it. Scoped to the citizenid resolved from src.
---@param source number player server id
---@param payload { layout?: string } client payload
---@return table result { success }
function actions.saveLayout(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local layout = payload.layout
    if type(layout) ~= 'string' or #layout > 16000 then return fail('Invalid layout') end
    settings.setHomeLayout(cid, layout)
    return ok()
end

return actions
