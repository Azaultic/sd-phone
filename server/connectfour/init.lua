---@type table Online-game engine (server.games.engine): lobbies, invites, move relay, wagers, stats.
local engine = require 'server.games.engine'

-- Connect Four online is the generalized engine with a connectfour config: Red(1)/Yellow(2)
-- sides, Red moves first. All lobby / relay / wager / stats logic lives in
-- server/games/engine.lua.
engine.register('connectfour', { sides = { '1', '2' }, title = 'Connect Four' })
