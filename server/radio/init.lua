---@type table Radio persistence layer (server.radio.store): prefs row + saved-channel CRUD.
local store   = require 'server.radio.store'
---@type table Authoritative radio handlers (server.radio.actions): clamping + band rules.
local actions = require 'server.radio.actions'

-- Schema bootstrap, once at boot. pcall'd so a DB failure prints instead of aborting the whole
-- resource load. Voice itself is handled client-side via pma-voice; the server only persists
-- prefs and tracks channel presence.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:radio]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:radio]^0 schema ready')
end)

-- Authoritative NUI callbacks: thin delegates into server.radio.actions, which owns the
-- validation + clamping (each handler is documented there).
lib.callback.register('sd-phone:server:radio:get', function(src) return actions.get(src) end)
lib.callback.register('sd-phone:server:radio:save', function(src, payload) return actions.save(src, payload) end)
lib.callback.register('sd-phone:server:radio:canTune', function(src, freq) return actions.canTune(src, freq) end)
lib.callback.register('sd-phone:server:radio:saved:list', function(src) return actions.listSaved(src) end)
lib.callback.register('sd-phone:server:radio:saved:add', function(src, payload) return actions.addSaved(src, payload) end)
lib.callback.register('sd-phone:server:radio:saved:update', function(src, payload) return actions.updateSaved(src, payload) end)
lib.callback.register('sd-phone:server:radio:saved:remove', function(src, payload) return actions.removeSaved(src, payload) end)

-- Live channel presence, in memory only: the client reports its channel on every tune (0 = off,
-- never tracked) so the app can show a head-count of who shares a frequency. Nothing persists -
-- after a restart clients simply re-report on their next tune.
---@type table<number, table<integer, boolean>> Members per channel: members[channel][src] = true.
local members    = {}
---@type table<integer, number> The channel each src currently occupies (nil = off).
local srcChannel = {}

---How many players currently share `channel`.
---@param channel number radio channel
---@return integer n
local function countOf(channel)
    local n, m = 0, members[channel]
    if m then for _ in pairs(m) do n = n + 1 end end
    return n
end

---Fan the live member count out to everyone on `channel`, so each open app updates its
---head-count the moment someone joins or leaves. No-op for an untracked channel. The payload is
---just the count - nothing private leaves the server.
---@param channel number radio channel
local function pushCount(channel)
    local m = members[channel]
    if not m then return end
    local n = countOf(channel)
    for src in pairs(m) do
        TriggerClientEvent('sd-phone:client:radio:count', src, { count = n })
    end
end

---Move `src` onto `channel` (0/garbage = off) and push the new counts. Re-asserting the SAME
---channel doesn't rejoin - it just re-pushes the caller's live figure, because the client asks
---again whenever the phone reopens and reopening resets the app's local count. Emptied channel
---sets are pruned so `members` can't accumulate dead tables.
---@param src integer player server id
---@param channel any raw channel (tonumber-coerced)
local function setPresence(src, channel)
    channel = tonumber(channel) or 0
    local target = channel ~= 0 and channel or nil
    if srcChannel[src] == target then
        TriggerClientEvent('sd-phone:client:radio:count', src, { count = target and countOf(target) or 0 })
        return
    end

    local prev = srcChannel[src]
    if prev and members[prev] then
        members[prev][src] = nil
        if next(members[prev]) == nil then members[prev] = nil end
        pushCount(prev)
    end

    if target then
        srcChannel[src] = target
        members[target] = members[target] or {}
        members[target][src] = true
        pushCount(target)
    else
        srcChannel[src] = nil
        TriggerClientEvent('sd-phone:client:radio:count', src, { count = 0 })
    end
end

---A client reported the channel it's tuned to (0 = off). The job-restricted bands are enforced
---HERE as well as in the pre-tune canTune callback, so a player who bypasses the UI - or loses
---the qualifying job after tuning - is dropped: presence clears and the client is told to force
---the radio off. NaN is normalised to 0 before use: it passes every range comparison and errors
---as a table key inside setPresence. The /10 mapping converts the client's pma-voice channel
---number (freq x 10, see client/apps/radio.lua freqToChannel) back to the app's MHz frequency.
---@param channel any client-reported pma-voice channel number
RegisterNetEvent('sd-phone:server:radio:presence', function(channel)
    local src = source
    channel = tonumber(channel) or 0
    if channel ~= channel then channel = 0 end
    if channel ~= 0 then
        local res = actions.canTune(src, channel / 10)
        if res and res.allowed == false then
            setPresence(src, 0)
            TriggerClientEvent('sd-phone:client:radio:forceoff', src, { message = res.message })
            return
        end
    end
    setPresence(src, channel)
end)

---A departing player leaves their channel, keeping counts honest and preventing a recycled src
---from inheriting stale presence.
AddEventHandler('playerDropped', function()
    setPresence(source, 0)
end)
