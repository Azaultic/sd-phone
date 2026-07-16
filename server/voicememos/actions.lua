---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Voice-memo persistence layer (server.voicememos.store): per-memo row CRUD.
local store  = require 'server.voicememos.store'
---@type table Player bridge (bridge.server.player): citizenid/name lookups from src.
local player = require 'bridge.server.player'
---@type table AirShare core (server.share.core): nearby-target validation + the
---request/accept handshake every share kind rides on.
local share  = require 'server.share.core'

---@type table Voice Memos config (config.VoiceMemos): list/name/size caps.
local VM = config.VoiceMemos
---@type table Actions module; the table returned at end of file.
local actions = {}

---Actor identity for every handler: the caller's citizenid, resolved from src via the player
---bridge - never from the payload - so memos are always scoped to the caller's character.
---@param src number player server id
---@return string|nil citizenid or nil when the character isn't loaded
local function cidOf(src) return player.getIdentifier(src) end

local util = require 'server.util'
local trim = util.trim

---Coerce a client-supplied memo id into a finite positive integer, or nil. NaN, the infinities
---and fractional values are rejected here so a crafted id can never reach oxmysql as a
---non-integer parameter (which errors inside the query layer instead of returning "not found").
---@param id any client-supplied memo id
---@return integer|nil id validated id, nil when malformed
local function memoId(id)
    id = tonumber(id)
    if not id or id ~= id or id == math.huge or id == -math.huge then return nil end
    if id ~= math.floor(id) or id < 1 then return nil end
    return id
end

---Shape a DB row (or row-alike) into the memo object the React app renders: string id, numeric
---duration, ISO-8601 date. The citizenid never leaves the server this way.
---@param row table memo row { id, name, url, duration, created_at }
---@return table memo { id, name, url, duration, date }
local function toMemo(row)
    return {
        id       = tostring(row.id),
        name     = row.name,
        url      = row.url,
        duration = tonumber(row.duration) or 0,
        date     = os.date('!%Y-%m-%dT%H:%M:%SZ', tonumber(row.created_at)),
    }
end

---List the caller's most recent memos (VM.ListLimit), newest first, scoped to their citizenid.
---Always returns an array in `data.memos` so the app can render straight from it. Read-only.
---@param src number player server id
---@return table result { success, data = { memos = memo[] } }
function actions.list(src)
    local cid = cidOf(src)
    if not cid then return { success = false, data = { memos = {} } } end

    local out = {}
    for _, row in ipairs(store.recent(cid, VM.ListLimit)) do
        out[#out + 1] = toMemo(row)
    end
    return { success = true, data = { memos = out } }
end

---Persist a memo whose audio is already hosted on Fivemanage. Called by the upload handler in
---init.lua once the CDN URL is known - the URL is server-obtained, never client-supplied. The
---memo is server-authoritative: owner is the caller's citizenid, timestamp is set here, the
---name is trimmed/defaulted/capped to VM.MaxNameLength, and the client-supplied duration is
---clamped to a sane finite range (NaN/inf/negative/absurd values become 0) so it can never
---error the INT insert. Refused (nil) at the VM.MaxPerPlayer cap or without a loaded character.
---@param src number player server id
---@param url string Fivemanage-hosted audio URL
---@param name any client-supplied display name
---@param duration any client-supplied recording length in seconds
---@return table|nil memo the stored memo shape, nil when refused
function actions.saveUploaded(src, url, name, duration)
    local cid = cidOf(src)
    if not cid then return nil end
    if store.countFor(cid) >= VM.MaxPerPlayer then return nil end

    name = trim(name)
    if name == '' then name = 'New Recording' end
    if #name > VM.MaxNameLength then name = name:sub(1, VM.MaxNameLength) end

    duration = tonumber(duration) or 0
    if duration ~= duration or duration < 0 or duration > 86400 then duration = 0 end
    duration = math.floor(duration)

    local ts = os.time()
    local id = store.insert(cid, name, url, duration, ts)
    return toMemo({ id = id, name = name, url = url, duration = duration, created_at = ts })
end

---Rename one of the caller's memos. The ownership gate (store.ownerOf against the caller's
---citizenid) is checked here, server-side, so a crafted id can't touch another player's memo.
---The new name follows the same trim/cap rules as saveUploaded but an empty result is refused
---rather than defaulted - a rename to nothing is a user error, not a fresh recording.
---@param src number player server id
---@param id any client-supplied memo id
---@param name any client-supplied new name
---@return table result { success, message?, data? }
function actions.rename(src, id, name)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    id = memoId(id)
    if not id then return { success = false, message = 'Bad memo id' } end
    if store.ownerOf(id) ~= cid then return { success = false, message = 'Not your memo' } end

    name = trim(name)
    if name == '' then return { success = false, message = 'Name required' } end
    if #name > VM.MaxNameLength then name = name:sub(1, VM.MaxNameLength) end

    store.rename(id, name)
    return { success = true, data = { id = tostring(id), name = name } }
end

---Send an AirShare request offering one of the caller's memos to a nearby player. Ownership is
---checked against the full row here, and the handshake payload is built from that ROW (name,
---url, duration) - not from anything client-supplied - so what deliverShare later writes is
---exactly what the sender owns. Target validation (nearby + phone open) is share.request's job;
---delivery happens only if the recipient accepts.
---@param src number sender server id
---@param target number recipient server id (client-chosen, validated by share.request)
---@param id any client-supplied memo id
---@return table result { success, message? }
function actions.requestShare(src, target, id)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    id = memoId(id)
    if not id then return { success = false, message = 'Bad memo id' } end

    local row = store.getById(id)
    if not row or row.citizenid ~= cid then return { success = false, message = 'Not your memo' } end

    local payload = { name = row.name, url = row.url, duration = tonumber(row.duration) or 0 }
    local okSent, msg = share.request(src, target, 'voice', payload)
    if not okSent then return { success = false, message = msg or 'Could not send request' } end
    return { success = true }
end

---Deliver an accepted voice-memo share into the recipient's Voice Memos (AirShare handler -
---registered in init.lua). Only reachable through share.respond, so the payload is the
---server-built copy of the sender's row, never raw client data. Inserts a fresh row for the
---recipient and live-pushes it so an open app updates immediately. Refused (false) when the
---recipient is at the VM.MaxPerPlayer cap or has no loaded character.
---@param targetSrc number recipient server id
---@param payload { name: string, url: string, duration: number } stored share payload
---@return boolean delivered
function actions.deliverShare(targetSrc, payload)
    local tcid = player.getIdentifier(targetSrc)
    if not tcid then return false end
    if store.countFor(tcid) >= VM.MaxPerPlayer then return false end

    local ts    = os.time()
    local newId = store.insert(tcid, payload.name, payload.url, payload.duration, ts)
    TriggerClientEvent('sd-phone:client:voice:added', targetSrc,
        toMemo({ id = newId, name = payload.name, url = payload.url, duration = payload.duration, created_at = ts }))
    return true
end

---Delete one of the caller's memos. Same server-side ownership gate as rename, so a crafted id
---can't delete another player's memo. Idempotent from the caller's view: deleting an
---already-gone id fails the ownership check and changes nothing.
---@param src number player server id
---@param id any client-supplied memo id
---@return table result { success, message?, data? }
function actions.delete(src, id)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    id = memoId(id)
    if not id then return { success = false, message = 'Bad memo id' } end
    if store.ownerOf(id) ~= cid then return { success = false, message = 'Not your memo' } end

    store.delete(id)
    return { success = true, data = { id = tostring(id) } }
end

return actions
