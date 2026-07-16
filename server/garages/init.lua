---@type table Garages bridge (bridge.server.garages): cross-resource garage-system detection +
---DB normalisation into the app's vehicle shape.
local garages = require 'bridge.server.garages'

---Owned-vehicle list for the caller. Read-only, no payload: identity is resolved from src
---inside the bridge (never from the client), and a disabled/undetected system degrades to an
---empty array, so this always answers with a well-formed envelope.
lib.callback.register('sd-phone:server:garages:list', function(src)
    return { success = true, data = garages.list(src) }
end)

---Boot report: print the garage system the bridge detected at require time. The short delay
---only keeps the line out of the resource-start burst; detection itself is already done.
CreateThread(function()
    Wait(300)
    print(('^2[sd-phone:garages]^0 ready — system: ^3%s^0'):format(garages.activeSystem() or 'none (framework table)'))
end)
