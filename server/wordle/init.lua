---@type table Online-game engine (server.games.engine): lobbies, invites, move relay, wagers, stats.
local engine = require 'server.games.engine'

-- Wordle online is the generalized engine with a wordle config: two cosmetic sides ('a'/'b', no
-- turn order) running a race - both players solve the same word, fastest / fewest guesses wins.
-- freeRelay lets each client push its own progress snapshots without turn enforcement. All lobby
-- / relay / wager / stats logic lives in server/games/engine.lua.
engine.register('wordle', { sides = { 'a', 'b' }, title = 'Wordle', currency = 'bank', freeRelay = true })
