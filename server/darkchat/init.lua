---@type table Dark Chat persistence layer (server.darkchat.store): schema bootstrap + CRUD.
local store   = require 'server.darkchat.store'
---@type table Dark Chat business logic (server.darkchat.actions): validated room/message/reaction handlers.
local actions = require 'server.darkchat.actions'

-- Schema bootstrap runs once at load; a failure aborts loudly rather than letting every callback
-- die later on missing tables.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:darkchat]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:darkchat]^0 schema ready')
end)

-- Live presence, in memory only: who is tabbed into which room, and who is sitting on the rooms
-- list. It drives pushing new messages/reactions straight to a room's current viewers and the
-- public rooms' live "active" counts; it deliberately resets on resource restart (viewers re-open
-- and re-register). Keyed by src, so playerDropped must scrub it (srcs recycle across sessions).
---@type table<string, table<integer, boolean>> Viewers currently inside a room, per room id.
local present  = {}
---@type table<integer, boolean> Viewers currently on the rooms list, by src.
local homepage = {}

---Mark `src` as viewing `roomId`. Only called after actions.open granted access, so the presence
---map can never hold a room the player couldn't read - and only open creates room sets, so
---arbitrary client roomIds can't grow the table.
---@param src integer player server id
---@param roomId string room id
local function joinPresence(src, roomId)
    present[roomId] = present[roomId] or {}
    present[roomId][src] = true
end

---Remove `src` from one room's viewer set. Pure lookup - a garbage roomId finds no set and
---changes nothing.
---@param src integer player server id
---@param roomId string room id (may be raw client input; only ever used as a table key)
local function leavePresence(src, roomId)
    local set = present[roomId]
    if set then set[src] = nil end
end

---Remove `src` from every room's viewer set (app exit / disconnect).
---@param src integer player server id
local function leaveAll(src)
    for _, set in pairs(present) do set[src] = nil end
end

---Mark `src` as sitting on the rooms list, where they receive active-count pushes.
---@param src integer player server id
local function joinHomepage(src)  homepage[src] = true end

---Drop `src` from the rooms-list set.
---@param src integer player server id
local function leaveHomepage(src) homepage[src] = nil  end

---How many viewers are currently inside `roomId`.
---@param roomId string room id
---@return integer n
local function countPresent(roomId)
    local set = present[roomId]
    if not set then return 0 end
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

---Live viewer count per room id, for listRooms' public-room member figures. May include private
---rooms that happen to have viewers; listRooms only reads the public ids.
---@return table<string, integer> counts
local function publicCounts()
    local counts = {}
    for roomId in pairs(present) do counts[roomId] = countPresent(roomId) end
    return counts
end

---Push the current "active" (tabbed-in) viewer count for a public room to everyone who'd display
---it: the viewers inside the room AND anyone sitting on the rooms list, so both the header and the
---homepage tick live as people come and go. Private rooms show their total membership instead, so
---they're skipped. The payload is a room id and a number - nothing about WHO the viewers are.
---@param roomId string room id (non-public ids no-op)
local function broadcastActive(roomId)
    if not actions.isPublic(roomId) then return end
    local n = countPresent(roomId)
    local sent = {}
    local set = present[roomId]
    if set then
        for tgt in pairs(set) do
            sent[tgt] = true
            TriggerClientEvent('sd-phone:client:darkchat:active', tgt, { roomId = roomId, active = n })
        end
    end
    for tgt in pairs(homepage) do
        if not sent[tgt] then
            TriggerClientEvent('sd-phone:client:darkchat:active', tgt, { roomId = roomId, active = n })
        end
    end
end

---Deliver a freshly-stored message to every OTHER live viewer of its room (the sender already has
---the authoritative copy from their callback return). The message carries only the author's
---nickname - no citizenid, phone number or server id ever rides in this payload, which is what
---keeps Dark Chat anonymous on the wire. Scoped to the room's present set, never -1.
---@param roomId string room id
---@param exceptSrc integer sender to skip
---@param message table client-shaped message from actions.send
local function broadcast(roomId, exceptSrc, message)
    local set = present[roomId]
    if not set then return end
    for tgt in pairs(set) do
        if tgt ~= exceptSrc then
            TriggerClientEvent('sd-phone:client:darkchat:message', tgt, { roomId = roomId, message = message })
        end
    end
end

---Push a message's new reaction set to everyone in the room except the reactor (who already has
---the authoritative set from the callback's return value). The set was computed from the REACTOR's
---viewpoint, so its `mine` flags mean nothing to recipients - the client deliberately merges only
---the emoji + counts and keeps its own local `mine` state (DarkChat.tsx mergeBroadcastReactions).
---Nothing in the payload identifies who reacted.
---@param roomId string room id
---@param exceptSrc integer reactor to skip
---@param messageId string message id
---@param reactions table[] { emoji, count, mine } rows
local function broadcastReaction(roomId, exceptSrc, messageId, reactions)
    local set = present[roomId]
    if not set then return end
    for tgt in pairs(set) do
        if tgt ~= exceptSrc then
            TriggerClientEvent('sd-phone:client:darkchat:reaction', tgt, { roomId = roomId, messageId = messageId, reactions = reactions })
        end
    end
end

---Room list + preloaded histories (validated + built in actions.listRooms). Fetching the list also
---marks the caller as sitting on the homepage, so they receive live active-count pushes until they
---open a room or exit the app.
lib.callback.register('sd-phone:server:darkchat:rooms', function(src)
    joinHomepage(src)
    return actions.listRooms(src, publicCounts())
end)

---Open one room: access-check + history via actions.open, then presence bookkeeping - the viewer
---moves from the homepage into the room, and a public room gets its live active count attached to
---the response (counting the opener) while everyone else's count is refreshed. roomId is
---type-checked here so no downstream lookup ever sees a non-string, and presence only changes when
---access was actually granted.
---@param payload table { roomId: string }
lib.callback.register('sd-phone:server:darkchat:open', function(src, payload)
    local roomId = type(payload) == 'table' and payload.roomId or nil
    if type(roomId) ~= 'string' then return { success = false } end
    local res = actions.open(src, roomId)
    if res.success then
        leaveHomepage(src)
        joinPresence(src, roomId)
        if actions.isPublic(roomId) then
            res.data.active = countPresent(roomId)
            broadcastActive(roomId)
        end
    end
    return res
end)

---A room view closed back to the rooms list: the caller becomes a homepage viewer again and the
---room's active count refreshes for everyone still watching. Tolerates a missing or garbage
---roomId - presence is only ever looked up here, never created.
---@param payload table { roomId: string }
lib.callback.register('sd-phone:server:darkchat:close', function(src, payload)
    joinHomepage(src)
    local roomId = type(payload) == 'table' and payload.roomId or nil
    if type(roomId) == 'string' then
        leavePresence(src, roomId)
        broadcastActive(roomId)
    end
    return { success = true }
end)

---The Dark Chat app itself closed (home button / app switch): scrub the viewer from all presence,
---then refresh the active count of each public room they were tabbed into so the remaining
---viewers' counts drop. Idempotent - a replayed exit finds nothing to remove.
lib.callback.register('sd-phone:server:darkchat:exit', function(src)
    leaveHomepage(src)
    local affected = {}
    for roomId, set in pairs(present) do
        if set[src] and actions.isPublic(roomId) then affected[#affected + 1] = roomId end
    end
    leaveAll(src)
    for _, roomId in ipairs(affected) do broadcastActive(roomId) end
    return { success = true }
end)

---Post a message (validated + stored in actions.send) and push it to the room's other live viewers
---on success. The broadcast reuses the exact client-shaped message from the callback result - the
---author field is the sender's nickname, never an identity field.
---@param payload table { roomId, kind?, body?, meta? }
lib.callback.register('sd-phone:server:darkchat:send', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    local res = actions.send(src, payload.roomId, payload)
    if res.success then broadcast(payload.roomId, src, res.data.message) end
    return res
end)

---Toggle a reaction (validated in actions.react) and push the updated set to the room's other
---live viewers on success.
---@param payload table { roomId, messageId, emoji }
lib.callback.register('sd-phone:server:darkchat:react', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    local res = actions.react(src, payload.roomId, payload.messageId, payload.emoji)
    if res.success then
        broadcastReaction(payload.roomId, src, res.data.messageId, res.data.reactions)
    end
    return res
end)

-- Thin delegates into server.darkchat.actions, which owns all validation (each handler is
-- documented there). The table-guard keeps a crafted non-table payload from erroring before that
-- validation runs.
lib.callback.register('sd-phone:server:darkchat:create', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.create(src, payload.name, payload.code)
end)

lib.callback.register('sd-phone:server:darkchat:join', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.join(src, payload.code)
end)

---Leave a private room: drop the caller's presence in it first (so active counts stay honest even
---when the membership delete finds nothing), then remove their membership via actions.leave.
---@param payload table { roomId: string }
lib.callback.register('sd-phone:server:darkchat:leave', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    if payload.roomId then leavePresence(src, payload.roomId) end
    return actions.leave(src, payload.roomId)
end)

---Save the caller's nickname (validated in actions.setNickname).
---@param payload table { nickname: string }
lib.callback.register('sd-phone:server:darkchat:nickname', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.setNickname(src, payload.nickname)
end)

---A disconnecting player is scrubbed from all presence state (srcs recycle across sessions, so a
---stale entry would count a future stranger as present), and each public room they were tabbed
---into gets its active count refreshed for the remaining viewers.
AddEventHandler('playerDropped', function()
    local src = source
    local affected = {}
    for roomId, set in pairs(present) do
        if set[src] and actions.isPublic(roomId) then affected[#affected + 1] = roomId end
    end
    leaveHomepage(src)
    leaveAll(src)
    for _, roomId in ipairs(affected) do broadcastActive(roomId) end
end)
