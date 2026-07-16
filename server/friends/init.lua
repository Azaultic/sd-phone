---@type table Find Friends config (configs/friends.lua): MaxFriends cap + push interval.
local config  = require 'configs.friends'
---@type table Find Friends persistence (server.friends.store): directed share-edge CRUD.
local store   = require 'server.friends.store'
---@type table Authoritative Find Friends handlers (server.friends.actions).
local actions = require 'server.friends.actions'

---@type table<number, boolean> Players whose Find Friends app is currently open (live-push
---targets), by src.
local watchers = {}

-- Schema bootstrap, once at boot: create/upgrade the phone_friends table. A failure is loud but
-- doesn't take the resource down.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:friends]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:friends]^0 schema ready')
end)

-- Authoritative roster callbacks: thin delegates into server.friends.actions, which owns the
-- validation + persistence (each handler is documented there). Payloads are attacker-controlled
-- and may be any type, so they're coerced to a table here before field access; every field is
-- then validated inside the action it reaches. `accept` is pinned to a strict boolean at the
-- boundary.
lib.callback.register('sd-phone:server:friends:list', function(src)
    return actions.list(src)
end)

lib.callback.register('sd-phone:server:friends:add', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    return actions.add(src, payload.phone)
end)

lib.callback.register('sd-phone:server:friends:remove', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    return actions.remove(src, payload.id)
end)

lib.callback.register('sd-phone:server:friends:share', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    return actions.setShare(src, payload.id, payload.enabled)
end)

lib.callback.register('sd-phone:server:friends:respond', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    return actions.respond(src, payload.id, payload.phone, payload.accept == true)
end)

lib.callback.register('sd-phone:server:friends:status', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    return actions.status(src, payload.phone)
end)

---The app flips this on while it's open and off when it closes, so live positions are pushed
---only to players actually looking at the map. Self-scoped: the payload can only subscribe or
---unsubscribe the CALLER, and a subscription only ever earns them their own roster snapshot -
---there's nothing here to aim at anyone else.
---@param payload table { on: boolean }
lib.callback.register('sd-phone:server:friends:watch', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    if payload.on == true then watchers[src] = true else watchers[src] = nil end
    return { success = true }
end)

---A departing watcher's entry is dropped (srcs recycle across sessions, so a stale key would
---push another player's roster to the wrong client).
AddEventHandler('playerDropped', function()
    watchers[source] = nil
end)

---@type table Player bridge (bridge.server.player): the once-per-tick online cid->src map.
local player = require 'bridge.server.player'

-- Live push loop: every UpdateInterval ms, hand each watcher their fresh roster snapshot -
-- positions included only for online, accepted, sharing friends (actions.snapshot owns that
-- privacy gate). The online cid->src map is viewer-agnostic, so it's built ONCE per tick and
-- shared across every watcher's snapshot rather than rebuilt per watcher. The app replaces its
-- list wholesale, so friends who go offline or stop sharing drop off the map in near real time.
-- Watchers whose player vanished without firing playerDropped are pruned in-line. Coarse (3s
-- default) - nothing here is frame-sensitive.
CreateThread(function()
    while true do
        Wait(config.UpdateInterval or 3000)
        if next(watchers) then
            local onlineCids = player.onlineCidMap()
            for src in pairs(watchers) do
                if GetPlayerName(src) then
                    TriggerClientEvent('sd-phone:client:friends:update', src, { friends = actions.snapshot(src, onlineCids) })
                else
                    watchers[src] = nil
                end
            end
        end
    end
end)
