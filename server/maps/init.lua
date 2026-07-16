---@type table Maps persistence layer (server.maps.store): one JSON row per citizenid.
local store   = require 'server.maps.store'
---@type table Authoritative Maps handlers (server.maps.actions): sanitize + cap + scope.
local actions = require 'server.maps.actions'
---@type table AirShare core (server.share.core): per-kind delivery handler registry.
local share   = require 'server.share.core'

-- Deliver an accepted pin AirShare into the recipient's saved pins (payload was sanitized at
-- request time; the handler is documented in server.maps.actions).
share.registerHandler('pin', actions.deliverShare)

---Bootstrap the pins schema once at boot; a failed bootstrap is reported and leaves the
---callbacks in place (they degrade to empty lists / failed saves rather than hard errors).
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:maps]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:maps]^0 schema ready')
end)

-- Authoritative NUI callbacks: thin delegates into server.maps.actions, which owns the
-- validation + persistence (each handler is documented there). Identity always comes from src;
-- the payload is type-guarded before any field access so a crafted non-table can't error out.
lib.callback.register('sd-phone:server:maps:list', function(src)
    return actions.list(src)
end)

lib.callback.register('sd-phone:server:maps:save', function(src, payload)
    return actions.save(src, payload)
end)

lib.callback.register('sd-phone:server:maps:sharePin', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    return actions.requestShare(src, payload.target, payload)
end)
