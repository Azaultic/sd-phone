---@type table AirShare core (server.share.core): open-phone tracking + request handshake + proximity.
local core = require 'server.share.core'

---A client's phone was opened or closed - track it so the player only appears in others' share
---sheets while their phone is actually out. Self-reported, which is safe: claiming "open" only
---makes the CALLER a potential share target (they receive popups); it grants them nothing, and
---the server-side distance check still gates every request.
---@param open boolean whether the phone is now open
RegisterNetEvent('sd-phone:server:phone:setOpen', function(open)
    core.setOpen(source, open and true or false)
end)

---A departing player's open flag + pending AirShare requests are dropped (srcs recycle across
---sessions).
AddEventHandler('playerDropped', function()
    core.clear(source)
end)

---Nearby phone-open players this client may share to right now, measured from live server-side
---coords. Read-only.
lib.callback.register('sd-phone:server:share:nearby', function(src)
    return { success = true, data = { targets = core.nearby(src) } }
end)

---Recipient accepts/declines an AirShare request. core.respond enforces that the responder IS
---the request's addressed target, so a crafted id can't accept or dismiss a share meant for
---someone else.
---@param payload table { id: string, accept: boolean }
lib.callback.register('sd-phone:server:airshare:respond', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return core.respond(src, payload.id, payload.accept == true)
end)
