---@type table Clock persistence layer (server.clock.store): per-citizenid alarm + recents CRUD.
local store  = require 'server.clock.store'
---@type table Player bridge (bridge.server.player): citizenid lookups from a server id.
local player = require 'bridge.server.player'

---@type table Actions module; the table returned at end of file.
local actions = {}

---@type integer Alarm cap per character - keeps the list UI-sized and bounds how many rows one
---client can insert.
local MAX_ALARMS = 25

---Stable per-character key (framework citizenid) scoping every read/write. Resolved from src via
---the bridge - never from the payload - so a client can't act on another character's rows.
---@param src integer player server id
---@return string|nil citizenid (nil when the player can't be resolved)
local function cidOf(src) return player.getIdentifier(src) end

local util = require 'server.util'
local isTruthy = util.truthy

---Every alarm the caller owns, ordered by time of day, with the TINYINT flags normalised to
---real booleans for the UI. Read-only.
---@param src integer player server id
---@return table result { success, data = { alarms = table[] } }
function actions.listAlarms(src)
    local cid = cidOf(src)
    if not cid then return { success = false, data = { alarms = {} } } end

    local out = {}
    for _, r in ipairs(store.alarmsFor(cid)) do
        out[#out + 1] = {
            id      = r.id,
            hour    = r.hour,
            minute  = r.minute,
            label   = r.label or '',
            days    = r.days or '',
            enabled = isTruthy(r.enabled),
            sound      = isTruthy(r.sound),
            snooze     = isTruthy(r.snooze),
            snoozeSecs = tonumber(r.snooze_secs) or 60,
        }
    end
    return { success = true, data = { alarms = out } }
end

---Create or update one alarm, matched on the CLIENT-generated id (the app owns alarm identity;
---the store's (citizenid, id) primary key keeps ids from colliding across characters). Every
---field is validated server-side: the id must be a modest string, hour/minute/snoozeSecs are
---clamped into range, label/days capped to their column widths, and the flag fields coerced to
---real booleans, so a crafted payload can't push out-of-range or mistyped values into the DB.
---The MAX_ALARMS cap applies only to brand-new ids - updates to an existing alarm skip the
---COUNT so a full list can still be edited. Idempotent: a replayed save upserts the same row.
---@param src integer player server id
---@param payload table { id, hour, minute, label?, days?, enabled?, sound?, snooze?, snoozeSecs? }
---@return table result
function actions.saveAlarm(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end

    local id = payload.id
    if type(id) ~= 'string' or id == '' or #id > 40 then return { success = false, message = 'Bad alarm id' } end

    if not store.alarmExists(cid, id) and store.countAlarms(cid) >= MAX_ALARMS then
        return { success = false, message = 'Alarm limit reached' }
    end

    local hour    = math.max(0, math.min(23, math.floor(tonumber(payload.hour)   or 0)))
    local minute  = math.max(0, math.min(59, math.floor(tonumber(payload.minute) or 0)))
    local label   = type(payload.label) == 'string' and payload.label:sub(1, 60) or ''
    local days    = type(payload.days)  == 'string' and payload.days:sub(1, 40)  or ''
    local enabled = payload.enabled
    if enabled == nil then enabled = true end
    local sound = payload.sound
    if sound == nil then sound = true end
    local snooze     = payload.snooze == true
    local snoozeSecs = math.max(1, math.min(3600, math.floor(tonumber(payload.snoozeSecs) or 60)))

    store.upsertAlarm(cid, {
        id = id, hour = hour, minute = minute, label = label, days = days,
        enabled = isTruthy(enabled), sound = isTruthy(sound), snooze = snooze, snoozeSecs = snoozeSecs,
    })
    return { success = true }
end

---Delete one alarm by client id, scoped to the caller in the store. Deleting an id that doesn't
---exist (or belongs to another character) is a silent no-op, so a replayed delete can't surface
---a spurious error.
---@param src integer player server id
---@param id string client-generated alarm id
---@return table result
function actions.deleteAlarm(src, id)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(id) ~= 'string' or id == '' then return { success = false, message = 'Bad alarm id' } end
    store.deleteAlarm(cid, id)
    return { success = true, data = { id = id } }
end

---The caller's most-recently-used timer durations, newest first. Read-only.
---@param src integer player server id
---@return table result { success, data = { recents = integer[] } }
function actions.listRecents(src)
    local cid = cidOf(src)
    if not cid then return { success = false, data = { recents = {} } } end
    return { success = true, data = { recents = store.recentsFor(cid) } }
end

---Record a started timer duration for the recents list, bounded to 1s-24h. The range check
---rejects NaN explicitly - NaN fails both < and > comparisons, so the plain bounds pair alone
---would wave it through to the SQL layer as an unencodable parameter. Replays are harmless: the
---store upserts on (citizenid, seconds) and just bumps recency.
---@param src integer player server id
---@param seconds any raw client duration in seconds
---@return table result
function actions.addRecent(src, seconds)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    local s = math.floor(tonumber(seconds) or 0)
    if s ~= s or s <= 0 or s > 86400 then return { success = false, message = 'Bad duration' } end
    store.addRecent(cid, s, os.time())
    return { success = true }
end

return actions
