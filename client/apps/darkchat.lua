---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Thin delegates into server/darkchat: room lifecycle, membership, messaging, reactions and
-- nicknames - validation + persistence live in each server handler, documented there.
proxy('sd-phone:darkchat:rooms',    'sd-phone:server:darkchat:rooms')
proxy('sd-phone:darkchat:open',     'sd-phone:server:darkchat:open')
proxy('sd-phone:darkchat:close',    'sd-phone:server:darkchat:close')
proxy('sd-phone:darkchat:send',     'sd-phone:server:darkchat:send')
proxy('sd-phone:darkchat:react',    'sd-phone:server:darkchat:react')
proxy('sd-phone:darkchat:create',   'sd-phone:server:darkchat:create')
proxy('sd-phone:darkchat:join',     'sd-phone:server:darkchat:join')
proxy('sd-phone:darkchat:leave',    'sd-phone:server:darkchat:leave')
proxy('sd-phone:darkchat:nickname', 'sd-phone:server:darkchat:nickname')
proxy('sd-phone:darkchat:exit',     'sd-phone:server:darkchat:exit')

---Server push: a message landed in a room we're a member of - relay it so an open room
---updates live. Server-originated, so the payload is trusted as-is.
---@param data table message record from server/darkchat
RegisterNetEvent('sd-phone:client:darkchat:message', function(data)
    SendNUIMessage({ action = 'sd-phone:darkchat:message', data = data })
end)

---Server push: a room's active-member presence changed - relay so the app updates who's
---currently in the room.
---@param data table presence patch from server/darkchat
RegisterNetEvent('sd-phone:client:darkchat:active', function(data)
    SendNUIMessage({ action = 'sd-phone:darkchat:active', data = data })
end)

---Server push: a reaction changed on a message in one of our rooms - relay the updated set so
---the bubble patches in place.
---@param data table reaction patch from server/darkchat
RegisterNetEvent('sd-phone:client:darkchat:reaction', function(data)
    SendNUIMessage({ action = 'sd-phone:darkchat:reaction', data = data })
end)
