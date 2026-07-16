---@type table Radio persistence layer (server.radio.store): prefs row + saved-channel CRUD.
local store  = require 'server.radio.store'
---@type table Player bridge (bridge.server.player): citizenid/job lookups from a server id.
local player = require 'bridge.server.player'
---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'

---@type table Actions module; the table returned at end of file.
local actions = {}

---True when `job` appears in a range's allowed-jobs list. A nil list never matches, so a
---restricted range with no jobs configured stays closed rather than falling open.
---@param job string|nil the caller's current job name (nil when the bridge can't resolve one)
---@param jobs table|nil the range's allowed job names
---@return boolean listed
local function jobInList(job, jobs)
    if not jobs then return false end
    for _, j in ipairs(jobs) do if j == job then return true end end
    return false
end

---@type number Frequency (MHz) handed out when a player has never saved prefs.
local DEFAULT_FREQ   = 1.0
---@type integer Volume (0-100) handed out when a player has never saved prefs.
local DEFAULT_VOLUME = 50

---@type integer Saved-channel cap per character - keeps the list UI-sized and bounds how many
---rows one client can insert.
local SAVED_CAP = 24

---Stable per-character key (framework citizenid) scoping every read/write. Resolved from src via
---the bridge - never from the payload - so a client can't act on another character's rows.
---@param src integer player server id
---@return string|nil citizenid (nil when the player can't be resolved)
local function cidOf(src) return player.getIdentifier(src) end

local util = require 'server.util'
local trim = util.trim

---Clamp a client-supplied frequency to the app's 1.0-999.9 band, snapped to one decimal place.
---tonumber-coerces first; NaN is rejected explicitly (it passes both boundary comparisons and
---would otherwise reach the DECIMAL column as an unencodable parameter), so garbage collapses to
---the default instead.
---@param f any raw client value
---@return number frequency one-decimal in-band frequency
local function clampFreq(f)
    f = tonumber(f) or DEFAULT_FREQ
    if f ~= f then f = DEFAULT_FREQ end
    if f < 1.0 then f = 1.0 elseif f > 999.9 then f = 999.9 end
    return math.floor(f * 10 + 0.5) / 10
end

---Clamp a client-supplied volume to an integer 0-100, with the same explicit NaN rejection as
---clampFreq (NaN would otherwise pass both boundary checks and error the INT column write).
---@param v any raw client value
---@return integer volume
local function clampVolume(v)
    v = tonumber(v) or DEFAULT_VOLUME
    if v ~= v then v = DEFAULT_VOLUME end
    v = math.floor(v)
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    return v
end

---Whether `src` may tune to `freq`, per config.Radio.RestrictedRanges: a band is open unless a
---range covers it, and a covered band needs the caller's CURRENT job to match ANY covering
---range. The job comes from the bridge (never the payload) so a client can't claim one it
---doesn't hold. Both the pre-tune callback and the presence event route through here, so
---bypassing the UI's check still hits the rule. Read-only. Returns an { allowed, message? }
---verdict rather than the success envelope - the client reads it as a yes/no answer, not an
---action result.
---@param src integer player server id
---@param freq any raw client frequency (clamped here)
---@return table verdict { allowed: boolean, message?: string }
function actions.canTune(src, freq)
    freq = clampFreq(freq)
    local ranges = config.Radio and config.Radio.RestrictedRanges
    if not ranges or #ranges == 0 then return { allowed = true } end

    local job = player.getJob(src)
    local restricted, label
    for _, r in ipairs(ranges) do
        if freq >= (r.min or 0) and freq <= (r.max or 0) then
            if jobInList(job, r.jobs) then return { allowed = true } end
            restricted = true
            label = label or r.label
        end
    end
    if restricted then
        return { allowed = false, message = ('%.1f MHz is reserved for %s.'):format(freq, label or 'authorized units') }
    end
    return { allowed = true }
end

---The caller's persisted prefs (last frequency + volume), re-clamped on the way out so a
---hand-edited row can't push out-of-band values to the UI. Defaults when they've never saved.
---Read-only.
---@param src integer player server id
---@return table result { success, data = { frequency, volume } }
function actions.get(src)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    local row = store.get(cid)
    return {
        success = true,
        data = {
            frequency = row and clampFreq(row.frequency) or DEFAULT_FREQ,
            volume    = row and clampVolume(row.volume)  or DEFAULT_VOLUME,
        },
    }
end

---Persist the caller's last frequency + volume so the app restores them next session. Both are
---clamped server-side; the response echoes what was actually stored so the UI converges on the
---server's version.
---@param src integer player server id
---@param payload table { frequency?: number, volume?: number }
---@return table result { success, data = { frequency, volume } }
function actions.save(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end
    local freq = clampFreq(payload.frequency)
    local vol  = clampVolume(payload.volume)
    store.save(cid, freq, vol)
    return { success = true, data = { frequency = freq, volume = vol } }
end

---Shape one saved-channel row for the UI: the id stringified (the web layer keys rows by string
---id) and the stored frequency re-clamped so a hand-edited row can't leak an out-of-band value.
---@param row table store row { id, label, frequency }
---@return table saved { id: string, label: string, freq: number }
local function savedOut(row)
    return { id = tostring(row.id), label = row.label, freq = clampFreq(row.frequency) }
end

---Every saved channel the caller owns, oldest-first, in UI shape. Read-only.
---@param src integer player server id
---@return table result { success, data = { saved = table[] } }
function actions.listSaved(src)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    local out = {}
    for _, row in ipairs(store.listSaved(cid)) do out[#out + 1] = savedOut(row) end
    return { success = true, data = { saved = out } }
end

---Save a named channel. The label is trimmed + capped to the column width (VARCHAR(40)), the
---frequency clamped, and the per-character SAVED_CAP enforced server-side so a modified client
---can't flood the table. Accepts `freq` or `frequency` - the UI call sites send different keys.
---@param src integer player server id
---@param payload table { label: string, freq?: number, frequency?: number }
---@return table result { success, data? = { id, label, freq }, message? }
function actions.addSaved(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end
    local label = trim(payload.label):sub(1, 40)
    if label == '' then return { success = false, message = 'Name required' } end
    if store.countSaved(cid) >= SAVED_CAP then return { success = false, message = 'Saved list is full' } end
    local freq = clampFreq(payload.freq or payload.frequency)
    local id   = store.addSaved(cid, label, freq, os.time())
    return { success = true, data = { id = tostring(id), label = label, freq = freq } }
end

---Rename/retune one saved channel. The id must be a plain integer - NaN/inf survive tonumber
---(they're truthy) and would otherwise reach the SQL layer as unencodable parameters. Ownership
---is enforced in the store (WHERE id AND citizenid), so a forged id belonging to another
---character updates nothing.
---@param src integer player server id
---@param payload table { id: number|string, label: string, freq?: number, frequency?: number }
---@return table result { success, data? = { id, label, freq }, message? }
function actions.updateSaved(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end
    local id = tonumber(payload.id)
    if not id or id % 1 ~= 0 then return { success = false, message = 'Bad id' } end
    local label = trim(payload.label):sub(1, 40)
    if label == '' then return { success = false, message = 'Name required' } end
    local freq = clampFreq(payload.freq or payload.frequency)
    store.updateSaved(cid, id, label, freq)
    return { success = true, data = { id = tostring(id), label = label, freq = freq } }
end

---Delete one saved channel. Same integer-id validation as updateSaved; the DELETE is scoped to
---the caller in the store, so a forged id can't remove another character's row.
---@param src integer player server id
---@param payload table { id: number|string }
---@return table result { success, data? = { id }, message? }
function actions.removeSaved(src, payload)
    local cid = cidOf(src)
    if not cid then return { success = false } end
    if type(payload) ~= 'table' then payload = {} end
    local id = tonumber(payload.id)
    if not id or id % 1 ~= 0 then return { success = false, message = 'Bad id' } end
    store.removeSaved(cid, id)
    return { success = true, data = { id = tostring(id) } }
end

return actions
