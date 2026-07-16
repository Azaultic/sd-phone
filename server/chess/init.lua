---@type table Online-game engine (server.games.engine): lobbies, invites, move relay, wagers, stats.
local engine = require 'server.games.engine'

-- Chess online is the generalized engine with a chess config: White/Black sides, White moves
-- first. All lobby / relay / wager / stats logic lives in server/games/engine.lua.
engine.register('chess', { sides = { 'w', 'b' }, title = 'Chess' })
