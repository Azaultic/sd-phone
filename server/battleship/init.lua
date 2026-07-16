---@type table Online-game engine (server.games.engine): lobbies, invites, move relay, wagers, stats.
local engine = require 'server.games.engine'

-- Battleship online is the generalized engine with a battleship config: two sides ('1' goes
-- first), opaque shot/result relay. All lobby / relay / wager / stats logic lives in
-- server/games/engine.lua.
engine.register('battleship', { sides = { '1', '2' }, title = 'Battleship' })
