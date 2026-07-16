---@type table Streaks persistence layer (server.streaks.store): schema bootstrap + row CRUD.
local store   = require 'server.streaks.store'
---@type table Authoritative Streaks handlers (server.streaks.actions): validation + world mutation.
local actions = require 'server.streaks.actions'
---@type table Live-push module (server.streaks.live): the gallery presence set + scoped pushes.
local live    = require 'server.streaks.live'

-- One-shot boot thread: create/verify the Streaks tables before players start hitting the
-- callbacks. A failed bootstrap is printed and swallowed so the rest of the phone still boots.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:streaks]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:streaks]^0 schema ready')
end)

---Register one Streaks callback under the app's 'sd-phone:server:streaks:' prefix.
---@param action string callback name suffix
---@param fn function handler fun(src, payload?): table
local function register(action, fn)
    lib.callback.register('sd-phone:server:streaks:' .. action, fn)
end

-- Authoritative app callbacks: thin delegates into server.streaks.actions, which owns the
-- validation + world mutation (each handler is documented there).
register('sync',        function(src) return actions.sync(src) end)
register('post',        function(src, payload) return actions.post(src, payload) end)
register('gallery',     function(src, payload) return actions.gallery(src, payload) end)
register('like',        function(src, payload) return actions.like(src, payload) end)
register('leaderboard', function(src) return actions.leaderboard(src) end)

---The gallery flips this on while it's open and off when it closes, so live post/like pushes go
---only to players actually viewing it. Self-scoped: the payload can only sub/unsub the CALLER.
register('watch', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    live.watch(src, payload.on == true)
    return { success = true }
end)

---A departing viewer's presence is dropped so a recycled src can't inherit the subscription.
AddEventHandler('playerDropped', function()
    live.drop(source)
end)

---Confirm an admin command to its caller under the Streaks title.
---@param src integer player server id
---@param msg string notification text
local function notify(src, msg)
    TriggerClientEvent('ox_lib:notify', src, { title = 'Streaks', description = msg, type = 'success' })
end

---/streakset <days> - force the caller's own streak to a given day count (admin/testing).
---Restricted to group.admin; the day math, persistence and live-refresh push live in
---actions.setStreak.
---@param source integer player server id
---@param args table parsed command args { days: number }
lib.addCommand('streakset', {
    help = 'Set your Streaks day count (admin/testing)',
    params = { { name = 'days', type = 'number', help = 'Day count to set (0 = fresh)' } },
    restricted = 'group.admin',
}, function(source, args)
    local ok, days = actions.setStreak(source, args.days)
    if ok then notify(source, ('Streak set to day %d. Reopen the app.'):format(days)) end
end)

---/streakadd <amount> - raise (or, with a negative amount, revert) the caller's own streak days
---(admin/testing). Restricted to group.admin; delegates clamping + persistence to
---actions.addStreak.
---@param source integer player server id
---@param args table parsed command args { amount: number }
lib.addCommand('streakadd', {
    help = 'Raise or revert your Streaks days (admin/testing)',
    params = { { name = 'amount', type = 'number', help = 'Days to add (use a negative number to revert)' } },
    restricted = 'group.admin',
}, function(source, args)
    local ok, days = actions.addStreak(source, args.amount)
    if ok then notify(source, ('Streak now day %d. Reopen the app.'):format(days)) end
end)

---/streakwipe - wipe ALL Streaks data for every player (admin/testing), for a clean slate.
---Restricted to group.admin.
---@param source integer player server id
lib.addCommand('streakwipe', {
    help = 'Wipe ALL Streaks data for everyone (admin/testing)',
    restricted = 'group.admin',
}, function(source)
    actions.wipeAll(source)
    notify(source, 'All Streaks data wiped. You can post again now.')
end)
