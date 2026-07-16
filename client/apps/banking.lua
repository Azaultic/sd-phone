---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Thin delegates into server/banking: the account overview and phone transfers - all money
-- movement is validated + executed server-side, documented there.
proxy('sd-phone:banking:overview', 'sd-phone:server:banking:overview')
proxy('sd-phone:banking:send',     'sd-phone:server:banking:send')

---Server push: another player transferred money to us - relay so the Wallet refreshes live.
---@param data table { amount, from } from server/banking/actions.lua
RegisterNetEvent('sd-phone:client:bankReceived', function(data)
    SendNUIMessage({ action = 'sd-phone:bank:received', data = data })
end)

---Server push: a transaction was recorded outside the app (an external debit/credit) - nudge
---the Wallet to refetch; no payload because the overview callback owns the shape.
RegisterNetEvent('sd-phone:client:bankTxAdded', function()
    SendNUIMessage({ action = 'sd-phone:bank:txAdded' })
end)
