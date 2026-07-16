---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Dark Chat persistence layer (server.darkchat.store): rooms/members/messages/reactions/nicknames CRUD.
local store  = require 'server.darkchat.store'
---@type table Player bridge (bridge.server.player): citizenid lookups from a server id.
local player = require 'bridge.server.player'

---@type table Dark Chat config (config.DarkChat): public rooms, length caps, history limit, code length.
local DC = config.DarkChat
---@type table Actions module; the table returned at end of file. Every handler returns the
---{ success, message?, data? } envelope; live presence + delivery is init.lua's job. Author names
---always come from the player's saved nickname (server-authoritative - clients can't spoof who
---sent a message), and no citizenid, phone number or server id ever appears in anything returned
---or broadcast, which is what keeps Dark Chat anonymous.
local actions = {}

-- Seed the shared RNG once at load so genCode doesn't mint the same room-code sequence every
-- server start (GetGameTimer varies within a boot, os.time across boots).
math.randomseed(GetGameTimer() + os.time())

---@type table<string, table> Public-room config rows keyed by room id, for O(1) access checks.
local PUBLIC_BY_ID = {}
for _, r in ipairs(DC.PublicRooms) do PUBLIC_BY_ID[r.id] = r end

---@type string Room-code alphabet - ambiguous 0/O/1/I excluded so codes survive being read aloud.
local CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

---Mint a random room code of DC.CodeLength characters from CODE_ALPHABET. Uniqueness is the
---caller's job (actions.create retries until store.roomByCode misses).
---@return string code
local function genCode()
    local t = {}
    for i = 1, DC.CodeLength do
        local n = math.random(#CODE_ALPHABET)
        t[i] = CODE_ALPHABET:sub(n, n)
    end
    return table.concat(t)
end

local util = require 'server.util'
local trim = util.trim

---Trim a client string and cap its byte length; nil for non-strings and empties, so callers can
---treat absent and garbage the same way. The cap runs after trimming, matching what the app's own
---composer would have sent.
---@param s any client-supplied value
---@param max integer maximum byte length kept
---@return string|nil clean trimmed, capped string (nil if unusable)
local function sanitizeStr(s, max)
    if type(s) ~= 'string' then return nil end
    s = trim(s)
    if s == '' then return nil end
    if #s > max then s = s:sub(1, max) end
    return s
end

---@type table<string, boolean> Message kinds a client may send (mirrors DarkChatKind in
---web/src/apps/darkchat/data.ts); anything else demotes to plain 'text' in actions.send.
local VALID_KINDS = { text = true, image = true, gif = true, voice = true, location = true }

---@type table<string, boolean> The four reactions the shared MessageBubble picker offers
---(web/src/shared/chat/MessageBubble.tsx REACTIONS), whitelist-checked in actions.react so a
---modified client can't inject arbitrary text into every viewer's reaction chips. Mirrors
---REACTION_SET in server/messages/actions.lua.
local REACTION_SET = { ['❤️'] = true, ['👍'] = true, ['👎'] = true, ['😂'] = true }

---@return string clock time "HH:MM" the client renders next to a message
local function fmtTime(ts) return os.date('%H:%M', ts) end

---Stable per-character identity (framework citizenid) resolved from the server id - the ONLY
---identity source; nothing identity-shaped is ever read from a payload. It keys memberships,
---nicknames and message ownership in the DB but is never included in anything sent to a client.
---@param src integer player server id
---@return string|nil citizenid or nil if the player can't be resolved
local function cidOf(src) return player.getIdentifier(src) end

---Normalise a client-supplied room code: uppercase, strip everything outside A-Z0-9. Non-strings
---collapse to '' so join/create reject them through their normal empty/short-code paths.
---@param c any client-supplied code
---@return string code normalised (possibly empty)
local function sanitizeCode(c)
    if type(c) ~= 'string' then return '' end
    return (c:upper():gsub('[^A-Z0-9]', ''))
end

---Room-access gate every read/write passes through: public rooms are open to everyone, private
---rooms require a membership row. Checked server-side on each call (not just at open) so calling
---send/react directly can't reach a room the player never joined.
---@param roomId string room id
---@param cid string caller citizenid
---@return boolean allowed
local function canAccess(roomId, cid)
    if PUBLIC_BY_ID[roomId] then return true end
    return store.isMember(roomId, cid)
end

---@return boolean public - is this a config public room?
function actions.isPublic(roomId) return PUBLIC_BY_ID[roomId] ~= nil end

---A room's recent history shaped for the client: each stored meta blob is flattened back onto its
---message (media URL, audio, waypoint, reply quote) so the client renders one flat shape, and each
---message carries its distinct reaction set from `cid`'s viewpoint. `mine` is derived by comparing
---the stored citizenid against the caller - only the boolean leaves the server. A meta blob that
---fails to decode is skipped and the message still renders as its plain body. Shared by listRooms
---(which preloads every room's history so opening is instant) and open (a live refresh).
---@param roomId string room id
---@param cid string viewer citizenid
---@return table[] messages oldest-first client message rows
local function buildMessages(roomId, cid)
    local reactions = store.reactionsForRoom(roomId, cid)
    local out = {}
    for _, m in ipairs(store.recentMessages(roomId, DC.HistoryLimit)) do
        local msg = {
            id = tostring(m.id), author = m.author, body = m.body, at = fmtTime(m.created_at),
            mine = m.citizenid == cid, kind = m.kind or 'text',
            reactions = reactions[tostring(m.id)] or {},
        }
        if m.meta and m.meta ~= '' then
            local okDecode, decoded = pcall(json.decode, m.meta)
            if okDecode and type(decoded) == 'table' then
                for k, v in pairs(decoded) do msg[k] = v end
            end
        end
        out[#out + 1] = msg
    end
    return out
end

---Every room the caller can see - public rooms from config, private rooms from their membership
---rows - each with its history preloaded alongside the list so opening a room is instant (no
---second round-trip) and the chat never flicks in after the slide. `publicCounts` is live presence
---data owned by init.lua (who is tabbed into each public room right now); private rooms report
---total membership instead. Read-only apart from the identity resolve.
---@param src integer player server id
---@param publicCounts table<string, integer>|nil live viewer count per public room id
---@return table result { success, data = { public, private, nickname } }
function actions.listRooms(src, publicCounts)
    local cid = cidOf(src)
    if not cid then return { success = false, data = { public = {}, private = {} } } end

    local pub = {}
    for _, r in ipairs(DC.PublicRooms) do
        pub[#pub + 1] = {
            id = r.id, name = r.name, topic = r.topic,
            members = (publicCounts and publicCounts[r.id]) or 0,
            isPrivate = false, messages = buildMessages(r.id, cid),
        }
    end

    local priv = {}
    for _, row in ipairs(store.privateRoomsFor(cid)) do
        priv[#priv + 1] = {
            id = row.id, name = row.name, topic = 'Private room',
            members = store.memberCount(row.id), isPrivate = true, code = row.code,
            messages = buildMessages(row.id, cid),
        }
    end

    return { success = true, data = { public = pub, private = priv, nickname = store.getNickname(cid) or '' } }
end

---A live refresh of one room's history. Access-checked so a crafted open can't read a private
---room the caller never joined. Read-only; the presence bookkeeping lives with the init.lua
---callback that wraps this (which also type-checks roomId).
---@param src integer player server id
---@param roomId string room id
---@return table result { success, data = { messages } }
function actions.open(src, roomId)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if not canAccess(roomId, cid) then return { success = false, message = 'No access to that room' } end
    return { success = true, data = { messages = buildMessages(roomId, cid) } }
end

---Post a message to a room the caller can access. The author name is the caller's saved nickname,
---resolved server-side from their citizenid, so a client can't spoof who sent a message; the
---citizenid is stored for ownership only and never sent anywhere. `payload` carries { kind, body,
---meta }: kind is whitelisted against VALID_KINDS (anything else demotes to 'text'), and meta is
---rebuilt field-by-field per kind - media/audio URLs length-capped, voice duration clamped to
---1-600s, waveform clamped to 64 bars of 0-100 ints, waypoint strings capped - so a malformed
---payload can't bloat the row or smuggle extra fields into the stored blob. A reply quote (name +
---body, both capped) may ride along with any kind. Body is capped at DC.MaxMessageLength after the
---per-kind placeholder defaults. Returns the stored message in the same flattened shape
---buildMessages produces; init.lua broadcasts that exact object to the room's other live viewers.
---@param src integer player server id
---@param roomId string room id
---@param payload table { kind?, body?, meta? }
---@return table result { success, data = { message } }
function actions.send(src, roomId, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(roomId) ~= 'string' then return { success = false, message = 'Bad room' } end
    if not canAccess(roomId, cid) then return { success = false, message = 'No access to that room' } end

    local nick = store.getNickname(cid)
    if not nick or nick == '' then return { success = false, message = 'Pick a nickname first' } end

    payload = payload or {}
    local kind = VALID_KINDS[payload.kind] and payload.kind or 'text'
    local raw  = type(payload.meta) == 'table' and payload.meta or {}
    local body = trim(payload.body or '')
    local meta = {}

    if kind == 'text' then
        if body == '' then return { success = false, message = 'Empty message' } end
    elseif kind == 'image' or kind == 'gif' then
        local url = sanitizeStr(raw.mediaUrl, 1024)
        if not url then return { success = false, message = 'Missing media' } end
        meta.mediaUrl = url
        if body == '' then body = (kind == 'gif') and 'GIF' or '📷 Photo' end
    elseif kind == 'voice' then
        local url = sanitizeStr(raw.audioUrl, 1024)
        if not url then return { success = false, message = 'Missing audio' } end
        meta.audioUrl = url
        meta.duration = math.max(1, math.min(600, math.floor(tonumber(raw.duration) or 1)))
        if type(raw.waveform) == 'table' then
            local bars = {}
            for i = 1, math.min(#raw.waveform, 64) do
                bars[i] = math.max(0, math.min(100, math.floor(tonumber(raw.waveform[i]) or 0)))
            end
            if #bars > 0 then meta.waveform = bars end
        end
        if body == '' then body = '🎤 Voice message' end
    elseif kind == 'location' then
        meta.wpCode = sanitizeStr(raw.wpCode, 256)
        meta.wpSub  = sanitizeStr(raw.wpSub, 64)
        if body == '' then body = 'Current Location' end
    end

    if type(raw.replyTo) == 'table' then
        local rn = sanitizeStr(raw.replyTo.name, 40)
        local rb = sanitizeStr(raw.replyTo.body, 120)
        if rn and rb then meta.replyTo = { name = rn, body = rb } end
    end

    if #body > DC.MaxMessageLength then body = body:sub(1, DC.MaxMessageLength) end

    local metaJson = next(meta) ~= nil and json.encode(meta) or nil
    local ts = os.time()
    local id = store.insertMessage(roomId, cid, nick, body, ts, kind, metaJson)

    local message = { id = tostring(id), author = nick, body = body, at = fmtTime(ts), kind = kind, reactions = {} }
    for k, v in pairs(meta) do message[k] = v end
    return { success = true, data = { message = message } }
end

---Toggle the caller's reaction on a message, returning the message's new reaction set from the
---caller's viewpoint. The emoji must be one of REACTION_SET and the message must belong to
---`roomId` - which the caller must be able to access - so a bare message id is never trusted and
---a crafted call can't decorate messages in rooms the caller never joined. The message id is
---coerced to a finite number before it reaches the store (NaN/inf never touch a query param).
---Idempotent in the toggle sense: replaying the same call just flips the reaction back.
---@param src integer player server id
---@param roomId string room id
---@param messageId any client-supplied message id
---@param emoji any reaction emoji
---@return table result { success, data = { messageId, reactions } }
function actions.react(src, roomId, messageId, emoji)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(roomId) ~= 'string' then return { success = false } end
    if not canAccess(roomId, cid) then return { success = false, message = 'No access to that room' } end

    messageId = tonumber(messageId)
    if not messageId or messageId ~= messageId or messageId == math.huge or messageId == -math.huge then
        return { success = false, message = 'Bad message' }
    end
    emoji = sanitizeStr(emoji, 32)
    if not emoji or not REACTION_SET[emoji] then return { success = false, message = 'Bad emoji' } end

    if store.messageRoom(messageId) ~= roomId then return { success = false, message = 'No such message' } end

    store.toggleReaction(messageId, cid, emoji, os.time())
    return { success = true, data = { messageId = tostring(messageId), reactions = store.reactionsFor(messageId, cid) } }
end

---Create a private room owned by the caller and auto-join them. The client proposes a code so its
---UI can show one immediately; it's honoured only if well-formed after normalisation - 4-16 chars,
---the darkchat_rooms.code column is VARCHAR(16) - and not already taken, otherwise a
---guaranteed-unique one is minted server-side. Room ids are 'p-<code>', so code uniqueness makes
---the id unique too. Capped at DC.MaxPrivateRoomsPerPlayer memberships per character.
---@param src integer player server id
---@param name any room display name (trimmed, length-capped)
---@param code any client-proposed room code
---@return table result { success, data = { room } }
function actions.create(src, name, code)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    name = trim(name)
    if #name < DC.MinRoomNameLength then return { success = false, message = 'Name too short' } end
    if #name > DC.MaxRoomNameLength then name = name:sub(1, DC.MaxRoomNameLength) end
    if store.privateCountFor(cid) >= DC.MaxPrivateRoomsPerPlayer then
        return { success = false, message = 'You have too many rooms' }
    end

    code = sanitizeCode(code)
    if #code < 4 or #code > 16 or store.roomByCode(code) then
        repeat code = genCode() until not store.roomByCode(code)
    end

    local id, ts = 'p-' .. code, os.time()
    store.createRoom(id, code, name, cid, ts)
    store.addMember(id, cid, ts)
    return { success = true, data = { room = {
        id = id, name = name, topic = 'Private room', members = 1, isPrivate = true, code = code, messages = {},
    } } }
end

---Join a private room by its code. The code IS the credential - anyone holding it may join, which
---is the app's sharing model - so there is no permission check beyond the lookup. New memberships
---count against the same DC.MaxPrivateRoomsPerPlayer cap create enforces (join would otherwise
---bypass it, and every membership adds preloaded history to each listRooms call). Idempotent: a
---replayed join of a room the caller is already in skips the cap and the INSERT IGNORE membership
---insert changes nothing.
---@param src integer player server id
---@param code any client-supplied room code
---@return table result { success, data = { room } }
function actions.join(src, code)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    code = sanitizeCode(code)
    if code == '' then return { success = false, message = 'Enter a code' } end

    local row = store.roomByCode(code)
    if not row then return { success = false, message = 'No room with that code' } end

    if not store.isMember(row.id, cid) and store.privateCountFor(cid) >= DC.MaxPrivateRoomsPerPlayer then
        return { success = false, message = 'You have too many rooms' }
    end

    store.addMember(row.id, cid, os.time())
    return { success = true, data = { room = {
        id = row.id, name = row.name, topic = 'Private room', members = store.memberCount(row.id),
        isPrivate = true, code = row.code, messages = {},
    } } }
end

---Leave a private room. Public rooms are config-defined and can't be left. Only the caller's own
---membership row is deleted (scoped by their citizenid), so a crafted call can't evict anyone
---else. Idempotent: leaving a room you're not in deletes nothing.
---@param src integer player server id
---@param roomId any room id
---@return table result { success, data = { roomId } }
function actions.leave(src, roomId)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(roomId) ~= 'string' then return { success = false, message = 'Bad room' } end
    if PUBLIC_BY_ID[roomId] then return { success = false, message = 'Cannot leave a public room' } end
    store.removeMember(roomId, cid)
    return { success = true, data = { roomId = roomId } }
end

---Set the caller's Dark Chat nickname - the only author name other players ever see. Keyed by the
---caller's citizenid (resolved from src, never the payload) so it survives relogs; trimmed and
---length-capped within the darkchat_nicknames column.
---@param src integer player server id
---@param nick any proposed nickname
---@return table result { success, data = { nickname } }
function actions.setNickname(src, nick)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    nick = trim(nick)
    if #nick < DC.MinNicknameLength then return { success = false, message = 'Nickname too short' } end
    if #nick > DC.MaxNicknameLength then nick = nick:sub(1, DC.MaxNicknameLength) end
    store.setNickname(cid, nick)
    return { success = true, data = { nickname = nick } }
end

return actions
