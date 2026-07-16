---@type table sd-phone config root (configs/config.lua).
local config  = require 'configs.config'
---@type table Cookie persistence layer (server.cookie.store): one save row per character.
local store   = require 'server.cookie.store'
---@type table Authoritative cookie handlers (server.cookie.actions): clamping + write-behind cache.
local actions = require 'server.cookie.actions'

---@type integer Write-behind flush cadence in ms (config.Cookie.SaveInterval seconds).
local FLUSH_MS = (((config.Cookie or {}).SaveInterval) or 60) * 1000

-- Schema bootstrap, once at boot. pcall'd so a DB failure prints instead of aborting the whole
-- resource load.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:cookie]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:cookie]^0 schema ready')
end)

-- Write-behind flush: batch the in-memory autosaves to the DB on a slow interval rather than
-- writing on every client autosave. Coarse - nothing here is latency-sensitive, and disconnect /
-- resource stop flush immediately below.
CreateThread(function()
    while true do
        Wait(FLUSH_MS)
        actions.flushAll()
    end
end)

---Persist a leaving player's final state immediately - their slot can't wait for the timer once
---the src is gone - and free the per-src cache keys.
AddEventHandler('playerDropped', function()
    actions.playerDropped(source)
end)

---Safety net for a restart / resource stop: flush whatever is still pending before the
---in-memory cache vanishes with the resource.
---@param res string stopping resource name
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then actions.flushAll() end
end)

-- Authoritative NUI callbacks: thin delegates into server.cookie.actions, which owns the
-- validation + clamping (each handler is documented there; nickname unwraps its single field).
lib.callback.register('sd-phone:server:cookie:load', function(src) return actions.load(src) end)
lib.callback.register('sd-phone:server:cookie:save', function(src, payload) return actions.save(src, payload) end)
lib.callback.register('sd-phone:server:cookie:leaderboard', function(src) return actions.leaderboard(src) end)
lib.callback.register('sd-phone:server:cookie:nickname', function(src, payload) return actions.setNickname(src, type(payload) == 'table' and payload.nickname or nil) end)
