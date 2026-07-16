---@type table Notify bridge (bridge.client.notify): backend-agnostic toast notifications.
local notify = require 'bridge.client.notify'
-- Loaded for side effects: registers the owner-context exec callback the server-side housing
-- bridge delegates to for actions that must run on the owner's client.
require 'bridge.client.housing'

---List the caller's owned properties. Thin forward into server/homes, where the per-system
---housing bridge normalises every supported housing script into one shape.
RegisterNUICallback('sd-phone:homes:list', function(_payload, cb)
    cb(lib.callback.await('sd-phone:server:homes:list', false) or { success = false, data = {} })
end)

---Drop a map waypoint at a property's coords. The web hands us the { x, y } the server
---attached to the home; both are type-checked and tonumber-coerced so a malformed payload
---fails the callback instead of erroring in the native (SetNewWaypoint wants floats, hence
---the + 0.0). Purely local - nothing reaches the server.
---@param payload table { x: number, y: number }
RegisterNUICallback('sd-phone:homes:waypoint', function(payload, cb)
    local x = type(payload) == 'table' and tonumber(payload.x) or nil
    local y = type(payload) == 'table' and tonumber(payload.y) or nil
    if not x or not y then return cb({ success = false }) end
    SetNewWaypoint(x + 0.0, y + 0.0)
    notify.show({ description = 'Waypoint set.', type = 'success' })
    cb({ success = true })
end)

-- Thin delegates into server/homes: lock toggling and key management. Ownership + per-system
-- capability checks live server-side in the housing bridge, documented there.
RegisterNUICallback('sd-phone:homes:lock', function(payload, cb)
    cb(lib.callback.await('sd-phone:server:homes:lock', false, payload) or { success = false })
end)

RegisterNUICallback('sd-phone:homes:keyHolders', function(payload, cb)
    cb(lib.callback.await('sd-phone:server:homes:keyHolders', false, payload) or { success = false, holders = {} })
end)

RegisterNUICallback('sd-phone:homes:giveKey', function(payload, cb)
    cb(lib.callback.await('sd-phone:server:homes:giveKey', false, payload) or { success = false })
end)

RegisterNUICallback('sd-phone:homes:removeKey', function(payload, cb)
    cb(lib.callback.await('sd-phone:server:homes:removeKey', false, payload) or { success = false })
end)
