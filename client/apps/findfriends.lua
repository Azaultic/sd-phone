---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'

-- Thin delegates into server/friends: roster CRUD, share requests and the watch toggle.
-- There is deliberately no client-side position streaming - the server reads each friend's
-- coords itself, so a client can't spoof its location. Each handler is documented there.
proxyCallback('sd-phone:friends:list',    'sd-phone:server:friends:list')
proxyCallback('sd-phone:friends:add',     'sd-phone:server:friends:add')
proxyCallback('sd-phone:friends:remove',  'sd-phone:server:friends:remove')
proxyCallback('sd-phone:friends:share',   'sd-phone:server:friends:share')
proxyCallback('sd-phone:friends:respond', 'sd-phone:server:friends:respond')
proxyCallback('sd-phone:friends:status',  'sd-phone:server:friends:status')
proxyCallback('sd-phone:friends:watch',   'sd-phone:server:friends:watch')

---Server push: a fresh friends snapshot (positions + share state), streamed while we're
---watching. Forwarded under the maps action name because the Find Friends layer renders
---inside the Maps app.
---@param data table { friends = snapshot } from server/friends/init.lua
RegisterNetEvent('sd-phone:client:friends:update', function(data)
    SendNUIMessage({ action = 'sd-phone:maps:friends:update', data = data })
end)
