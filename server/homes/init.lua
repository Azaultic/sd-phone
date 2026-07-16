---@type table Housing bridge (bridge.server.housing): cross-resource housing-system detection,
---per-system property normalisation + action dispatch (lock/keys), and capability flags.
local housing = require 'bridge.server.housing'

---Property list plus the active system's capability flags (the app hides actions the detected
---system can't perform). Read-only, no payload: identity is resolved from src inside the
---bridge, and a disabled/undetected system degrades to an empty array.
lib.callback.register('sd-phone:server:homes:list', function(src)
    return { success = true, data = housing.list(src), caps = housing.capabilities() }
end)

---Toggle the front-door lock. `data.lock` is the desired state (coerced to a boolean in the
---bridge); returns the resulting locked boolean, nil when the system has no lock API (so
---success = false). `data.id` is client-supplied - per-system permission enforcement is
---delegated to the housing script's own export/owner-client path in the bridge. The payload is
---type-guarded before field access so a crafted non-table can't error the callback.
lib.callback.register('sd-phone:server:homes:lock', function(src, data)
    if type(data) ~= 'table' then data = nil end
    local locked = housing.lock(src, data and data.id, data and data.lock)
    return { success = locked ~= nil, locked = locked }
end)

---List who holds a key to the property ({ id = citizenid, name }). Read-only; degrades to an
---empty array when the system exposes no key-list API.
lib.callback.register('sd-phone:server:homes:keyHolders', function(src, data)
    if type(data) ~= 'table' then data = nil end
    return { success = true, holders = housing.keyHolders(src, data and data.id) }
end)

---Grant a key to an online player (data.target = recipient server id, coerced to a number in
---the bridge). Same delegation posture as lock: the bridge routes to the housing system's own
---export or the owner's client, which enforces its own permissions.
lib.callback.register('sd-phone:server:homes:giveKey', function(src, data)
    if type(data) ~= 'table' then data = nil end
    return { success = housing.giveKey(src, data and data.id, data and data.target) }
end)

---Revoke a key holder (data.holder = their citizenid, as returned by keyHolders). Same
---delegation posture as giveKey.
lib.callback.register('sd-phone:server:homes:removeKey', function(src, data)
    if type(data) ~= 'table' then data = nil end
    return { success = housing.removeKey(src, data and data.id, data and data.holder) }
end)

---Boot report: print the housing system the bridge detected at require time. The short delay
---only keeps the line out of the resource-start burst; detection itself is already done.
CreateThread(function()
    Wait(300)
    print(('^2[sd-phone:homes]^0 ready — system: ^3%s^0'):format(housing.activeSystem() or 'none'))
end)
