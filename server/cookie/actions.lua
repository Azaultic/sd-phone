---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Cookie persistence layer (server.cookie.store): one save row per character.
local store  = require 'server.cookie.store'
---@type table Player bridge (bridge.server.player): citizenid/name lookups from a server id.
local player = require 'bridge.server.player'

---@type table Cookie app config (config.Cookie): leaderboard size, value clamp, alias cap.
local C = config.Cookie or {}
---@type integer Leaderboard row cap (config.Cookie.LeaderboardLimit).
local LIMIT = C.LeaderboardLimit or 25
---@type number Ceiling for saved cookies/earned (config.Cookie.MaxValue). The save is
---client-authoritative - it's the player's own single-player progress - so this clamp is what
---keeps a forged save from making the leaderboard unreadable.
local MAXV  = C.MaxValue or 1e15
---@type integer Alias length cap (config.Cookie.MaxNicknameLength), well inside the VARCHAR(40)
---column.
local MAXNICK = C.MaxNicknameLength or 20

---@type table Actions module; the table returned at end of file.
local actions = {}

-- Write-behind cache. Clients autosave every couple of seconds; writing each of those straight
-- to MySQL would be one query per player every few seconds. Instead the latest save lives in
-- memory and only dirty entries flush, on a slow timer plus on disconnect / resource stop
-- (wired in init.lua).
---@type table<string, table> Latest save per citizenid: { name, cookies, earned, owned, ach, rainOn, dirty }.
local cache    = {}
---@type table<integer, string> src -> citizenid, so a disconnect can evict the right slot
---without re-resolving an identifier for a player who is already gone.
local srcToCid = {}

---Stable per-character key (framework citizenid) scoping every read/write. Resolved from src via
---the bridge - never from the payload - so a client can't act on another character's save.
---@param src integer player server id
---@return string|nil citizenid (nil when the player can't be resolved)
local function cidOf(src) return player.getIdentifier(src) end

local util = require 'server.util'
local trim, isTruthy = util.trim, util.truthy

---A player's leaderboard label: their custom alias if set, else their character name.
---@param nickname any stored alias column (may be nil)
---@param charName string|nil stored character name
---@return string name
local function displayName(nickname, charName)
    return (type(nickname) == 'string' and nickname ~= '') and nickname or (charName or 'Baker')
end

---Clamp a client-supplied cookie count to [0, MaxValue]. NaN is rejected explicitly - it fails
---both boundary comparisons and would otherwise sit in the cache as an unencodable parameter
---that errors every DB flush.
---@param v any raw client value
---@return number clamped
local function clampNum(v)
    v = tonumber(v) or 0
    if v ~= v then return 0 end
    if v < 0 then return 0 end
    if v > MAXV then return MAXV end
    return v
end


---Decode a stored JSON column defensively: nil, non-strings, and garbage (hand-edited rows,
---pre-migration data) collapse to {} instead of erroring the load.
---@param raw any stored column value
---@return table decoded
local function decode(raw)
    if type(raw) ~= 'string' or raw == '' then return {} end
    local ok, d = pcall(json.decode, raw)
    return (ok and type(d) == 'table') and d or {}
end

---The caller's save. The freshest copy is the in-memory cache entry (it may not have flushed
---yet), so the DB is only read when nothing is cached - the first open this session. A player
---with no row gets an empty save with rain on, matching the client default. Read-only.
---@param src integer player server id
---@return table result { success, data = { cookies, earned, owned, achievements, rainOn } }
function actions.load(src)
    local cid = cidOf(src)
    if not cid then return { success = false } end

    local c = cache[cid]
    if c then
        return { success = true, data = {
            cookies = c.cookies, earned = c.earned,
            owned = c.owned, achievements = c.ach, rainOn = c.rainOn,
        } }
    end

    local row = store.get(cid)
    if not row then
        return { success = true, data = { cookies = 0, earned = 0, owned = {}, achievements = {}, rainOn = true } }
    end
    return { success = true, data = {
        cookies      = row.cookies or 0,
        earned       = row.earned or 0,
        owned        = decode(row.owned),
        achievements = decode(row.achievements),
        rainOn       = isTruthy(row.rain_on),
    } }
end

---Autosave into memory only - no DB write here; the periodic flush batches those (init.lua).
---The save is client-authoritative by design, so validation is clamp-and-accept: numbers
---clamped to [0, MaxValue], the table fields type-checked (their contents are opaque client
---progress), and the caller's name snapshotted so the leaderboard can label them offline. Also
---records src -> citizenid so the disconnect hook can flush + evict this exact slot.
---@param src integer player server id
---@param payload table { cookies, earned, owned, achievements, rainOn }
---@return table result
function actions.save(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end
    srcToCid[src] = cid
    cache[cid] = {
        name    = player.getName(src),
        cookies = clampNum(payload.cookies),
        earned  = clampNum(payload.earned),
        owned   = type(payload.owned) == 'table' and payload.owned or {},
        ach     = type(payload.achievements) == 'table' and payload.achievements or {},
        rainOn  = payload.rainOn ~= false,
        dirty   = true,
    }
    return { success = true }
end

---Persist one cached entry if it has unsaved changes, clearing the dirty bit so the next timer
---pass skips it.
---@param cid string citizenid
local function flushCid(cid)
    local c = cache[cid]
    if not c or not c.dirty then return end
    store.save(cid, c.name, c.cookies, c.earned,
        json.encode(c.owned), json.encode(c.ach),
        c.rainOn and 1 or 0, os.time())
    c.dirty = false
end

---Flush every dirty cached save to the DB (periodic timer + resource stop). Each entry flushes
---under pcall so one failing row (oversized JSON, DB hiccup) skips that player instead of
---erroring out of the loop - an uncaught error here would kill the periodic flush thread and
---stop persistence for EVERYONE until restart. A failed entry stays dirty and is retried on the
---next pass.
function actions.flushAll()
    for cid in pairs(cache) do pcall(flushCid, cid) end
end

---A player disconnected: persist their final state now (their autosaves have stopped, so the
---timer alone would race the cache eviction) and free both slots so recycled srcs can't inherit
---stale state.
---@param src integer player server id
function actions.playerDropped(src)
    local cid = srcToCid[src]
    srcToCid[src] = nil
    if not cid then return end
    flushCid(cid)
    cache[cid] = nil
end

---The leaderboard: the top real players by lifetime earned, excluding the caller - the client
---splices itself in with its live, unsaved count so its own rank is always current - plus the
---caller's display label and stored alias so the UI can label the highlighted row and pre-fill
---the nickname editor. Reads the DB rather than the write-behind cache, so a rival's entry may
---lag one flush interval. Works with a nil cid (no exclusion, fallback label). Read-only; only
---display names + totals leave the server, never citizenids.
---@param src integer player server id
---@return table result { success, data = { rivals, me } }
function actions.leaderboard(src)
    local cid = cidOf(src)

    local rivals = {}
    for _, r in ipairs(store.topRivals(LIMIT, cid or '')) do
        rivals[#rivals + 1] = { name = displayName(r.nickname, r.name), cookies = math.floor(r.earned or 0) }
    end

    local row = cid and store.get(cid) or nil
    local nickname = (row and type(row.nickname) == 'string') and row.nickname or ''
    local me = { name = displayName(nickname, player.getName(src)), nickname = nickname }

    return { success = true, data = { rivals = rivals, me = me } }
end

---Set (or clear, with an empty string) the caller's leaderboard alias. A non-string payload is
---normalised to '' rather than erroring the trim - the alias only ever belongs to the caller,
---so the worst a forged payload can do is clear their own. Trimmed + capped to
---MaxNicknameLength; empty clears the alias so the leaderboard falls back to the character
---name.
---@param src integer player server id
---@param nickname any raw client alias
---@return table result { success, data = { nickname } }
function actions.setNickname(src, nickname)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(nickname) ~= 'string' then nickname = '' end
    nickname = trim(nickname)
    if #nickname > MAXNICK then nickname = nickname:sub(1, MAXNICK) end
    store.setNickname(cid, nickname ~= '' and nickname or nil)
    return { success = true, data = { nickname = nickname } }
end

return actions
