---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Thin delegates into server/marketplace: listing CRUD - validation, ownership checks and
-- persistence live in each server handler, documented there.
proxy('sd-phone:marketplace:list',   'sd-phone:server:marketplace:list')
proxy('sd-phone:marketplace:create', 'sd-phone:server:marketplace:create')
proxy('sd-phone:marketplace:update', 'sd-phone:server:marketplace:update')
proxy('sd-phone:marketplace:delete', 'sd-phone:server:marketplace:delete')

---Server push (fan-out to every other open phone): another player posted / edited / removed a
---listing. Forwarded straight to the NUI; the React app patches its list if the Marketplace
---app is currently open, and ignores it otherwise.
---@param payload table feed patch from server/marketplace
RegisterNetEvent('sd-phone:client:marketplace:feed', function(payload)
    SendNUIMessage({ action = 'sd-phone:marketplace:feed', data = payload })
end)
