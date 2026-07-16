---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Thin delegates into server/pages: listing CRUD - validation, ownership checks and
-- persistence live in each server handler, documented there.
proxy('sd-phone:pages:list',   'sd-phone:server:pages:list')
proxy('sd-phone:pages:create', 'sd-phone:server:pages:create')
proxy('sd-phone:pages:update', 'sd-phone:server:pages:update')
proxy('sd-phone:pages:delete', 'sd-phone:server:pages:delete')

---Server push (fan-out to every other open phone): another player posted / edited / removed a
---listing. Forwarded straight to the NUI; the React app patches its list if the Pages app is
---currently open, and ignores it otherwise.
---@param payload table feed patch from server/pages
RegisterNetEvent('sd-phone:client:pages:feed', function(payload)
    SendNUIMessage({ action = 'sd-phone:pages:feed', data = payload })
end)
