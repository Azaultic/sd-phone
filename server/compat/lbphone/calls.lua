---@type table Shared shim helpers (server.compat.lbphone.shared): export registration + warn-once.
local shim = require 'server.compat.lbphone.shared'
---@type table Authoritative call-routing handlers (server.calls.actions): dial/current/hangup.
local actions = require 'server.calls.actions'
---@type table Player bridge (bridge.server.player): source resolution from a citizenid.
local player = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): number -> citizenid resolution.
local settings = require 'server.settings.store'

local registerLbExport, stubLbExport, warnOnce = shim.registerLbExport, shim.stubLbExport, shim.warnOnce

---The caller's live call snapshot ({ channel, phase, number, name, elapsed }) or nil, unwrapped
---from the actions.current envelope the way the first-party read exports do it.
---@param source any
---@return table|nil
local function currentFor(source)
    if type(source) ~= 'number' then return nil end
    local res = actions.current(source)
    if type(res) == 'table' and res.success then return res.data end
    return nil
end

---CreateCall(caller { source, phoneNumber }, callee?, options?): start a 1:1 call on the
---caller's behalf through actions.dial, so the full player-originated validation applies
---(busy/airplane, digit normalisation, self-call guard, number-in-service, callee
---reachability). The caller resolves by source first, then by phoneNumber for source-less
---payloads. Returns the pma-voice channel number as the call id, nil when the call could not be
---placed. options.company / options.hideNumber have no equivalent and warn once.
registerLbExport('CreateCall', function(caller, callee, options)
    if type(caller) ~= 'table' then return nil end
    if type(options) == 'table' and (options.company ~= nil or options.hideNumber ~= nil) then
        warnOnce('CreateCall.options', ('CreateCall options.company/hideNumber are not supported (called by %s); the call was placed as a plain 1:1 call'):format(GetInvokingResource() or 'unknown'))
    end

    local src = tonumber(caller.source)
    if not src then
        local cid = settings.getCitizenByNumber(caller.phoneNumber)
        src = cid and player.getSourceByIdentifier(cid) or nil
    end
    if not src or not GetPlayerName(src) then return nil end

    local number = type(callee) == 'table' and callee.phoneNumber or callee
    local res = actions.dial(src, { number = number })
    return res.success and res.data.channel or nil
end)

---EndCall(source): end whatever call the player is in, resolving their OWN channel through
---actions.current and hanging up through actions.hangup so the ownership checks apply - the
---same shape as the first-party endCallFor export. Idempotent: not being in a call is success.
registerLbExport('EndCall', function(source)
    if type(source) ~= 'number' then return false end
    local call = currentFor(source)
    if not call then return true end
    return actions.hangup(source, { channel = call.channel }).success == true
end)

---IsInCall(source): whether the player is in a call or pending group ring, plus the channel as
---the call id second return. lb's third return (the raw call object) is not honoured - sd-phone
---keeps session internals private.
registerLbExport('IsInCall', function(source)
    local call = currentFor(source)
    if not call then return false end
    return true, call.channel
end)

-- Call sessions live in server.calls.actions locals keyed per player, not addressable by id
-- from outside, so a by-id lookup has nothing to read.
stubLbExport('GetCall', nil, 'is not supported: sd-phone call sessions are not addressable by id')
