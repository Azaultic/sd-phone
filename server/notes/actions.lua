---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Notes persistence layer (server.notes.store): per-citizenid note row CRUD.
local store  = require 'server.notes.store'
---@type table Player bridge (bridge.server.player): citizenid lookups from a server id.
local player = require 'bridge.server.player'
---@type table AirShare core (server.share.core): nearby/phone-open share request handshake.
local share  = require 'server.share.core'

---@type table Notes config (configs/notes.lua): per-player note count + content caps.
local N = config.Notes

---@type table Actions module; the table returned at end of file. Handlers return the phone's
---{ success, message?, data? } envelope. Notes are pure per-player storage - the client owns the
---id and the ISO timestamps; the server validates, clamps and persists them, scoped to the
---caller's citizenid so one player can never touch another's notes.
local actions = {}

---@type integer Upper bound (bytes) for each encoded sketches/images JSON column - just under the
---MEDIUMTEXT limit (16,777,215), so a hostile oversized payload fails cleanly here instead of
---erroring at the INSERT (or, in non-strict SQL mode, truncating into corrupt JSON).
local MAX_MEDIA_JSON = 16000000

---The acting player's citizenid, always resolved from src via the player bridge - identity is
---never read from a payload.
---@param src integer player server id
---@return string|nil citizenid nil when the player can't be resolved
local function cidOf(src) return player.getIdentifier(src) end

---Keep only well-formed, non-empty strings from a client-supplied array, capped at `limit`
---entries. Used for both sketches (PNG data URLs) and images (hosted photo URLs); anything that
---isn't a table yields an empty list rather than erroring.
---@param arr any client-supplied array
---@param limit integer max entries to keep
---@return string[] out sanitized list
local function sanitizeList(arr, limit)
    if type(arr) ~= 'table' then return {} end
    local out = {}
    for i = 1, #arr do
        local s = arr[i]
        if type(s) == 'string' and s ~= '' then
            out[#out + 1] = s
            if #out >= limit then break end
        end
    end
    return out
end

---Decode a JSON-array text column back into a Lua array (empty on null/garbage). pcall-guarded:
---the column is server-written, but a truncated or hand-edited row must not crash the list.
---@param raw string|nil stored JSON text
---@return table arr decoded array, empty when absent or malformed
local function decodeArr(raw)
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return {}
end

---All of the caller's notes, newest-edited first. Scoped to the caller's citizenid - there is no
---way to request another player's notes. Read-only.
---@param src integer player server id
---@return table result envelope with { notes }
function actions.list(src)
    local cid = cidOf(src)
    if not cid then return { success = false, data = { notes = {} } } end

    local out = {}
    for _, row in ipairs(store.forPlayer(cid)) do
        out[#out + 1] = {
            id        = row.id,
            body      = row.body or '',
            sketches  = decodeArr(row.sketches),
            images    = decodeArr(row.images),
            createdAt = row.created_at,
            updatedAt = row.updated_at,
        }
    end
    return { success = true, data = { notes = out } }
end

---Insert or update one of the caller's notes. The id is client-generated but only ever used under
---the caller's citizenid (the PK is citizenid+id), so a forged id can at worst create or overwrite
---the caller's own rows. The per-player cap is enforced only when this would be a brand-new note;
---the existence check is a cheap primary-key lookup, so updates skip the COUNT entirely (matters
---because the editor saves on every keystroke pause). Timestamps are the client's ISO strings
---(they sort chronologically) but fall back to server time when malformed or longer than their
---VARCHAR(40) columns, and each encoded media array is size-capped to fit its MEDIUMTEXT column.
---@param src integer player server id
---@param payload any client-supplied note { id, body?, sketches?, images?, createdAt?, updatedAt? }
---@return table result envelope
function actions.save(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end

    local id = payload.id
    if type(id) ~= 'string' or id == '' or #id > 40 then return { success = false, message = 'Bad note id' } end

    if not store.exists(cid, id) and store.countFor(cid) >= N.MaxNotesPerPlayer then
        return { success = false, message = 'Note limit reached' }
    end

    local body = type(payload.body) == 'string' and payload.body or ''
    if #body > N.MaxBodyLength then body = body:sub(1, N.MaxBodyLength) end

    local sketches     = sanitizeList(payload.sketches, N.MaxSketches)
    local images       = sanitizeList(payload.images, N.MaxImages)
    local sketchesJson = json.encode(sketches)
    local imagesJson   = json.encode(images)
    if #sketchesJson > MAX_MEDIA_JSON or #imagesJson > MAX_MEDIA_JSON then
        return { success = false, message = 'Note is too large' }
    end

    local createdAt = type(payload.createdAt) == 'string' and #payload.createdAt <= 40 and payload.createdAt
        or os.date('!%Y-%m-%dT%H:%M:%S.000Z')
    local updatedAt = type(payload.updatedAt) == 'string' and #payload.updatedAt <= 40 and payload.updatedAt
        or createdAt

    store.upsert(cid, id, body, sketchesJson, imagesJson, createdAt, updatedAt)
    return { success = true }
end

---Delete one of the caller's notes. The store scopes the DELETE to citizenid + id, so a forged id
---can only ever remove the caller's own row. Idempotent - a missing id deletes nothing.
---@param src integer player server id
---@param id any client-supplied note id
---@return table result envelope with { id } on success
function actions.delete(src, id)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(id) ~= 'string' or id == '' then return { success = false, message = 'Bad note id' } end
    store.delete(cid, id)
    return { success = true, data = { id = id } }
end

---Open an AirShare request offering this note's text, sketches and image URLs to a nearby player.
---The share core owns the real trust boundary (the target must be nearby with their phone open,
---and must accept); content is clamped with the same caps as a save so a pending request can't
---carry more than a note may hold. Delivery happens only on accept (actions.deliverShare).
---@param src integer sender server id
---@param target any client-supplied recipient server id (validated by share.request)
---@param payload any client-supplied note content { body?, sketches?, images? }
---@return table result envelope
function actions.requestShare(src, target, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end

    local body = type(payload.body) == 'string' and payload.body or ''
    if #body > N.MaxBodyLength then body = body:sub(1, N.MaxBodyLength) end

    local sketches = sanitizeList(payload.sketches, N.MaxSketches)
    local images   = sanitizeList(payload.images, N.MaxImages)
    if body:gsub('%s', '') == '' and #sketches == 0 and #images == 0 then
        return { success = false, message = 'Nothing to share' }
    end

    local okSent, msg = share.request(src, target, 'note', { body = body, sketches = sketches, images = images })
    if not okSent then return { success = false, message = msg or 'Could not send request' } end
    return { success = true }
end

---Deliver an accepted note share as a fresh note in the recipient's list. Not a client callback:
---it only runs as the AirShare 'note' handler (registered in init.lua) after the recipient
---accepts, with a payload requestShare already clamped - re-validated here anyway so the module
---stands alone. The id is server-generated so it can't collide with one of the recipient's own
---notes, and the recipient's note cap still applies. The new note is pushed only to the recipient.
---@param targetSrc number recipient server id
---@param payload { body: string, sketches: string[], images: string[] } vetted share payload
---@return boolean delivered
function actions.deliverShare(targetSrc, payload)
    local tcid = player.getIdentifier(targetSrc)
    if not tcid then return false end
    if store.countFor(tcid) >= N.MaxNotesPerPlayer then return false end

    local body     = type(payload.body) == 'string' and payload.body or ''
    if #body > N.MaxBodyLength then body = body:sub(1, N.MaxBodyLength) end
    local sketches = sanitizeList(payload.sketches, N.MaxSketches)
    local images   = sanitizeList(payload.images, N.MaxImages)
    if body == '' and #sketches == 0 and #images == 0 then return false end

    local sketchesJson = json.encode(sketches)
    local imagesJson   = json.encode(images)
    if #sketchesJson > MAX_MEDIA_JSON or #imagesJson > MAX_MEDIA_JSON then return false end

    local now = os.date('!%Y-%m-%dT%H:%M:%S.000Z')
    local id  = ('shr%d%d'):format(os.time(), math.random(100000, 999999))
    store.upsert(tcid, id, body, sketchesJson, imagesJson, now, now)

    TriggerClientEvent('sd-phone:client:notes:added', targetSrc, {
        id = id, body = body, sketches = sketches, images = images, createdAt = now, updatedAt = now,
    })
    return true
end

return actions
