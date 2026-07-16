---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'

-- Thin delegates into server/cherry: profile CRUD, deck swipes, match threads, reactions and
-- blocking - validation + persistence live in each server handler, documented there.
proxyCallback('sd-phone:cherry:state',         'sd-phone:server:cherry:state')
proxyCallback('sd-phone:cherry:saveProfile',   'sd-phone:server:cherry:saveProfile')
proxyCallback('sd-phone:cherry:swipe',         'sd-phone:server:cherry:swipe')
proxyCallback('sd-phone:cherry:rewind',        'sd-phone:server:cherry:rewind')
proxyCallback('sd-phone:cherry:resetDeck',     'sd-phone:server:cherry:resetDeck')
proxyCallback('sd-phone:cherry:thread',        'sd-phone:server:cherry:thread')
proxyCallback('sd-phone:cherry:send',          'sd-phone:server:cherry:send')
proxyCallback('sd-phone:cherry:react',         'sd-phone:server:cherry:react')
proxyCallback('sd-phone:cherry:unmatch',       'sd-phone:server:cherry:unmatch')
proxyCallback('sd-phone:cherry:block',         'sd-phone:server:cherry:block')
proxyCallback('sd-phone:cherry:blockedList',   'sd-phone:server:cherry:blockedList')
proxyCallback('sd-phone:cherry:unblock',       'sd-phone:server:cherry:unblock')
proxyCallback('sd-phone:cherry:watch',         'sd-phone:server:cherry:watch')
proxyCallback('sd-phone:cherry:deleteAccount', 'sd-phone:server:cherry:deleteAccount')

---Server push: a message arrived in one of our match threads - relay it so an open thread
---updates live. Server-originated, so the payload is trusted as-is.
---@param payload table { matchId, message } from server/cherry/actions.lua
RegisterNetEvent('sd-phone:client:cherry:message', function(payload)
    SendNUIMessage({ action = 'sd-phone:cherry:message', data = payload })
end)

---Server push: someone we liked swiped right back - relay the fresh match card so the "It's a
---match" moment shows without a resync.
---@param payload table serialized match record from server/cherry/actions.lua
RegisterNetEvent('sd-phone:client:cherry:match', function(payload)
    SendNUIMessage({ action = 'sd-phone:cherry:match', data = payload })
end)

---Server push: the other side reacted to one of our thread messages - relay the updated
---reaction set so the bubble patches in place.
---@param payload table reaction patch from server/cherry/actions.lua
RegisterNetEvent('sd-phone:client:cherry:reaction', function(payload)
    SendNUIMessage({ action = 'sd-phone:cherry:reaction', data = payload })
end)

---Server push: the other side unmatched (or blocked) us - relay so the match and its thread
---drop out of the app immediately.
---@param payload table { matchId } from server/cherry/actions.lua
RegisterNetEvent('sd-phone:client:cherry:unmatch', function(payload)
    SendNUIMessage({ action = 'sd-phone:cherry:unmatch', data = payload })
end)
