---@type table Authoritative call-routing handlers (server.calls.actions).
local actions = require 'server.calls.actions'
---@type table Player bridge (bridge.server.player): server-id to citizenid resolution for the exports.
local player  = require 'bridge.server.player'
---@type table Shared server helpers (server.util): response envelopes + trim.
local util    = require 'server.util'
local ok, fail, trim = util.ok, util.fail, util.trim

-- Authoritative call callbacks: thin delegates into server.calls.actions, which owns the
-- session state + validation (each handler is documented there).
lib.callback.register('sd-phone:server:call:dial', function(src, payload) return actions.dial(src, payload) end)
lib.callback.register('sd-phone:server:call:accept', function(src, payload) return actions.accept(src, payload) end)
lib.callback.register('sd-phone:server:call:decline', function(src, payload) return actions.decline(src, payload) end)
lib.callback.register('sd-phone:server:call:hangup', function(src, payload) return actions.hangup(src, payload) end)
lib.callback.register('sd-phone:server:call:current', function(src) return actions.current(src) end)

-- Video calling: the ICE config is request/response; the rest are one-way signaling relays the
-- actions module routes to the sender's live-session peer only (each documented there).
lib.callback.register('sd-phone:server:call:video:config', function() return actions.iceConfig() end)
RegisterNetEvent('sd-phone:server:call:video:request', function() actions.videoRequest(source) end)
RegisterNetEvent('sd-phone:server:call:video:accept',  function() actions.videoAccept(source) end)
RegisterNetEvent('sd-phone:server:call:video:stop',    function() actions.videoStop(source) end)
RegisterNetEvent('sd-phone:server:call:video:signal',  function(payload) actions.videoSignal(source, payload) end)

---End any call a player was in when they disconnect, so the other party isn't left ringing a
---ghost, pma-voice is cleaned up, and per-src call state can't collide when srcs recycle.
AddEventHandler('playerDropped', function()
    actions.onDrop(source)
end)

---@type integer Bound on how many export-supplied recipients are scanned, mirroring messages' MAX_MEMBER_SCAN.
local MAX_MEMBER_SCAN = 64
---@type integer Cap on an export-supplied group-call display name, mirroring messages' group-name cap.
local MAX_DISPLAY_NAME = 40

---A player's live call snapshot from actions.current, unwrapped to the data table
---({ channel, phase, number, name, elapsed }) or nil when they aren't in a call or pending
---ring. Shared by the read exports below.
---@param source any acting player's server id
---@return table|nil
local function currentFor(source)
    if type(source) ~= 'number' then return nil end
    local res = actions.current(source)
    if type(res) == 'table' and res.success then return res.data end
    return nil
end

---Start a 1:1 call on a player's behalf from another resource -
---exports['sd-phone']:startCall(source, number). Delegates straight to actions.dial, so the
---full player-originated validation applies (already-on-a-call and airplane checks, digit
---normalisation, self-call guard, number-in-service, callee reachability and busy) and
---`source` is honoured as the acting caller. Returns the dial envelope:
---{ success = true, data = { channel } } or { success = false, message }.
---@param source number acting caller's server id
---@param number string|number the number to dial
---@return table
exports('startCall', function(source, number)
    if type(source) ~= 'number' then return fail('Invalid source') end
    return actions.dial(source, { number = number })
end)

---Ring several players at once on a caller's behalf from another resource -
---exports['sd-phone']:startGroupCall(source, targetSources, displayName, displayNumber?).
---`targetSources` is an array of server ids; each resolves to a citizenid via the player
---bridge, unresolvable entries are dropped, and the scan is bounded by MAX_MEMBER_SCAN.
---`displayName` (what the caller sees they're calling) is trimmed, required non-empty, and
---capped at MAX_DISPLAY_NAME. Delegates to actions.callGroup, which filters out recipients who
---are the caller, busy, or in airplane mode, and returns its envelope:
---{ success = true, data = { channel } } or { success = false, message }.
---@param source number acting caller's server id
---@param targetSources number[] recipient server ids
---@param displayName string what the caller sees they're calling (e.g. 'Police')
---@param displayNumber? string|number
---@return table
exports('startGroupCall', function(source, targetSources, displayName, displayNumber)
    if type(source) ~= 'number' then return fail('Invalid source') end
    if type(targetSources) ~= 'table' then return fail('No recipients') end

    local name = trim(displayName)
    if name == '' then return fail('No display name') end
    if #name > MAX_DISPLAY_NAME then name = name:sub(1, MAX_DISPLAY_NAME) end

    local targets = {}
    for i = 1, math.min(#targetSources, MAX_MEMBER_SCAN) do
        local tsrc = tonumber(targetSources[i])
        local tcid = tsrc and player.getIdentifier(tsrc)
        if tcid then targets[#targets + 1] = { src = tsrc, cid = tcid } end
    end
    if #targets == 0 then return fail('No one is available right now') end

    return actions.callGroup(source, targets, name, displayNumber)
end)

---Read a player's live call from their own perspective -
---exports['sd-phone']:getCurrentCall(source). Returns the actions.current snapshot unwrapped:
---{ channel, phase ('outgoing'|'incoming'|'active'), number, name, elapsed }, or nil when the
---player isn't in a call or pending ring. Read-only.
---@param source number player server id
---@return table|nil
exports('getCurrentCall', function(source)
    return currentFor(source)
end)

---Whether a player is currently in a call or pending ring -
---exports['sd-phone']:isInCall(source). Boolean shorthand over getCurrentCall.
---@param source number player server id
---@return boolean
exports('isInCall', function(source)
    return currentFor(source) ~= nil
end)

---End whatever call a player is in, on their behalf -
---exports['sd-phone']:endCallFor(source). Resolves the player's OWN channel via actions.current
---and hangs up through actions.hangup, so the ownership checks still apply and a caller can
---never end someone else's call; no raw channel argument is accepted. Idempotent: a player not
---in any call returns success.
---@param source number player server id
---@return table { success: boolean, message?: string }
exports('endCallFor', function(source)
    if type(source) ~= 'number' then return fail('Invalid source') end
    local call = currentFor(source)
    if not call then return ok() end
    return actions.hangup(source, { channel = call.channel })
end)
