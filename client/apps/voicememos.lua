---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Thin delegates into server/voicememos - validation + persistence live in each server
-- handler, documented there.
proxy('sd-phone:voice:list',   'sd-phone:server:voice:list')
proxy('sd-phone:voice:rename', 'sd-phone:server:voice:rename')
proxy('sd-phone:voice:delete', 'sd-phone:server:voice:delete')
proxy('sd-phone:voice:share',  'sd-phone:server:voice:share')

---Upload is one-way by design: the base64 audio rides a fire-and-forget server event (the
---Fivemanage upload takes seconds, too long to block a callback round trip on) and cb fires
---immediately so the NUI never hangs. The outcome comes back on the voice:added /
---voice:uploadFailed pushes below; size/shape checks happen server-side.
---@param payload table { audio: string, ... } base64 recording from the NUI
RegisterNUICallback('sd-phone:voice:upload', function(payload, cb)
    TriggerServerEvent('sd-phone:server:voice:upload', payload)
    cb('ok')
end)

---Server push: a memo was saved for us - either our own upload finished, or a nearby player
---shared one. Relay it so the list updates live.
---@param memo table memo record from server/voicememos
RegisterNetEvent('sd-phone:client:voice:added', function(memo)
    SendNUIMessage({ action = 'sd-phone:voice:added', data = memo })
end)

---Server push: our upload was rejected (bad payload, too long, or the upstream upload
---failed) - relay the reason so the app can stop its spinner and explain.
---@param message string human-readable failure reason from server/voicememos/init.lua
RegisterNetEvent('sd-phone:client:voice:uploadFailed', function(message)
    SendNUIMessage({ action = 'sd-phone:voice:uploadFailed', data = { message = message } })
end)
