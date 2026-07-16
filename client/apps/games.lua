-- Every online game (chess, connectfour, battleship, wordle) plus Rail Runner's single-player
-- profile (rr* actions: high scores, coin wallet, cosmetics) shares this one bridge into the
-- generic games engine - a new game adds actions here only if the engine grows new callbacks.
---@type string[] NUI action suffixes proxied 1:1 to sd-phone:server:games:<action>.
local ACTIONS = {
    'createLobby', 'lobbies', 'joinLobby', 'inviteLobby', 'declineInvite',
    'leaveLobby', 'kickMember', 'setWager', 'setReady', 'returnToLobby', 'startLobby', 'pending', 'move',
    'resign', 'finish', 'report', 'stats', 'record', 'leaderboard', 'submitScore', 'scoreboard',
    'chipsGet', 'chipsBuy', 'chipsSell', 'chipsSettle',
    'rrProfile', 'rrSubmit', 'rrBuy', 'rrSelect', 'rrLeaderboard',
}

-- Thin delegates into the games engine (server/games/engine.lua), which owns lobby state,
-- move validation and wager settlement - each callback is documented there. The proxies add
-- no validation on purpose: the NUI payload reaches the server exactly as a modded client
-- could send it directly, so every real check lives server-side.
for _, name in ipairs(ACTIONS) do
    RegisterNUICallback('sd-phone:games:' .. name, function(payload, cb)
        local result = lib.callback.await('sd-phone:server:games:' .. name, false, payload)
        cb(result or { success = false, message = 'No response from server' })
    end)
end

---Server push: one channel carries every game's events; fan out to a per-game NUI action so
---each game's React controller keeps clean `useNuiEvent('<game>:<action>')` listeners. game
---and action are nil-guarded so a malformed push can't error the concatenation.
---@param data table { game: string, action: string, data?: table } from server/games/engine.lua
RegisterNetEvent('sd-phone:client:games', function(data)
    if not data or not data.game or not data.action then return end
    SendNUIMessage({ action = data.game .. ':' .. data.action, data = data.data or {} })
end)
