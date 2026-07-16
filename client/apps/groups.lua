-- Cached active-group view, refreshed at boot and after any push event that could affect
-- membership, so other resources reading the exports get an instant answer instead of a
-- server round-trip.
---@type string|nil Active group id mirror (nil when the player has no active group).
local activeGroupId    = nil
---@type table|nil Export-view snapshot of the active group (nil when none / not yet fetched).
local activeGroupCache = nil

---Pull a fresh snapshot of the player's active group from the server and stash it in the local
---cache. The id and view come from two server callbacks; a nil id clears the cache so consumers
---never read a stale group after leaving/disbanding.
local function refreshActiveGroup()
    local id = lib.callback.await('sd-phone:server:groups:activeId', false)
    activeGroupId = id
    if not id then
        activeGroupCache = nil
        return
    end
    activeGroupCache = lib.callback.await('sd-phone:server:groups:exportView', false, { groupId = id })
end

-- Deferred one-shot boot fetch so other resources finish their own start-up before we issue our
-- first server callback; pcall'd because a cold cache is fine (exports refetch lazily).
CreateThread(function()
    Wait(500)
    pcall(refreshActiveGroup)
end)

---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'

-- Thin delegates: each action proxies straight into its server callback, which owns the
-- validation + persistence (handlers are documented in server/groups/actions.lua).
proxyCallback('sd-phone:groups:list',    'sd-phone:server:groups:list')
proxyCallback('sd-phone:groups:create',  'sd-phone:server:groups:create')
proxyCallback('sd-phone:groups:invite',  'sd-phone:server:groups:invite')
proxyCallback('sd-phone:groups:accept',  'sd-phone:server:groups:accept')
proxyCallback('sd-phone:groups:decline', 'sd-phone:server:groups:decline')
proxyCallback('sd-phone:groups:leave',   'sd-phone:server:groups:leave')
proxyCallback('sd-phone:groups:disband', 'sd-phone:server:groups:disband')
proxyCallback('sd-phone:groups:kick',    'sd-phone:server:groups:kick')
proxyCallback('sd-phone:groups:setAvatar', 'sd-phone:server:groups:setAvatar')

---setActive needs a cache refresh on success BEFORE responding, so the new active id is already
---reflected the next time another resource reads the exports.
---@param payload table { groupId: string }
RegisterNUICallback('sd-phone:groups:setActive', function(payload, cb)
    local result = lib.callback.await('sd-phone:server:groups:setActive', false, payload)
    if result and result.success then
        pcall(refreshActiveGroup)
    end
    cb(result or { success = false, message = 'No response from server' })
end)

---Build a net-event handler that invalidates the active cache, then forwards the payload into
---the React app under the matching NUI action. Refresh-then-forward keeps the exports and the
---UI view consistent for any consumer reacting to the same push.
---@param action string NUI action name
---@return fun(data: any) handler
local function invalidateAndForward(action)
    return function(data)
        pcall(refreshActiveGroup)
        SendNUIMessage({ action = action, data = data })
    end
end

---An invite landed for this player. Forward-only - a pending invite doesn't change membership,
---so the active-group cache stays untouched.
---@param invite table invite payload from the server
RegisterNetEvent('sd-phone:client:groups:inviteReceived', function(invite)
    SendNUIMessage({ action = 'sd-phone:groups:inviteReceived', data = invite })
end)

-- Membership-affecting pushes: refresh the cached active group, then relay into the React app.
RegisterNetEvent('sd-phone:client:groups:memberJoined',
    invalidateAndForward('sd-phone:groups:memberJoined'))
RegisterNetEvent('sd-phone:client:groups:memberLeft',
    invalidateAndForward('sd-phone:groups:memberLeft'))
RegisterNetEvent('sd-phone:client:groups:disbanded',
    invalidateAndForward('sd-phone:groups:disbanded'))
RegisterNetEvent('sd-phone:client:groups:kicked',
    invalidateAndForward('sd-phone:groups:kicked'))
RegisterNetEvent('sd-phone:client:groups:updated',
    invalidateAndForward('sd-phone:groups:updated'))

---Read-only cache read for other client resources.
---@return string|nil cached id of the player's active group
exports('getActiveGroupId', function() return activeGroupId end)

---Cached export-view of the player's active group; refetches lazily when the cache is cold so a
---consumer reading before the boot fetch still gets an answer.
---@return table|nil cached export-view of the player's active group
exports('getActiveGroup', function()
    if activeGroupCache then return activeGroupCache end
    pcall(refreshActiveGroup)
    return activeGroupCache
end)

---Force a re-fetch of the cached active group. Useful for consumers that just performed a
---server action and want a guaranteed-fresh next read.
exports('refreshActiveGroup', function() pcall(refreshActiveGroup) end)
