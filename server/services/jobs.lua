---@type table sd-phone config root (configs/config.lua).
local config  = require 'configs.config'
---@type table Saved-jobs store (server.services.jobstore): the phone's multijob list + offers.
local store   = require 'server.services.jobstore'
---@type table Services actions (server.services.actions): reused for the live roster push.
local actions = require 'server.services.actions'
---@type table Society bridge (bridge.server.society): grade-label resolution.
local society = require 'bridge.server.society'
---@type table Job bridge (bridge.server.job): SetJob/duty writes + the multijob capability probe.
local job     = require 'bridge.server.job'
---@type table Player bridge (bridge.server.player): citizenid resolution from src.
local player  = require 'bridge.server.player'

---@type table Services config (configs/services.lua).
local SV         = config.Services
---@type integer Max saved jobs per player (0 = no cap).
local MAX        = SV.MaxSavedJobs or 5
---@type boolean Drop the player off duty when they switch active job (mirrors sd-multijob).
local OFF_DUTY   = SV.SwitchOffDuty ~= false
---@type string Job the player is reset to when removing their active job.
local UNEMPLOYED = SV.UnemployedJob or 'unemployed'

-- Jobs that are never listed, switchable, or accept-able (you go unemployed via the Actions tab's
-- Quit, not here).
---@type table<string, boolean> Set of blacklisted job names.
local BLACKLIST = {}
for _, j in ipairs(SV.JobBlacklist or { 'unemployed' }) do BLACKLIST[j] = true end

---@type table Jobs module; every handler returns the { success, data?, message? } envelope. The
---table returned at end of file.
local jobs = {}

local util = require 'server.util'
local ok, fail = util.ok, util.fail

---Shape one saved job for the UI (label + rank resolved from the framework).
---@param jobName string
---@param grade number|nil grade level, defaulting to 0
---@param active boolean|nil whether this is the caller's current framework job
---@return table
local function describe(jobName, grade, active)
    return {
        job        = jobName,
        label      = job.getLabel(jobName) or jobName,
        grade      = grade or 0,
        gradeLabel = society.gradeLabel(jobName, grade or 0),
        active     = active or nil,
    }
end

---Count a player's saved jobs, ignoring blacklisted entries, for the MaxSavedJobs cap.
---@param map table saved-jobs map
---@return number
local function savedCount(map)
    local n = 0
    for j in pairs(map) do if not BLACKLIST[j] then n = n + 1 end end
    return n
end

---A player's saved jobs + pending offers. When the framework has no multi-job model (ESX) this
---returns `multijob = false` and the UI hides the tab. The caller's CURRENT framework job is
---seeded/refreshed into their saved map first, so the list is never empty and a promotion on the
---active job is reflected - the framework stays authoritative for the job they're actually
---working. Sorted active first, then alphabetically; offers ship the inviter's display name
---('A manager' when an invite predates names). Everything is keyed off the caller's own
---citizenid.
---@param src number
---@return table
function jobs.list(src)
    if not job.supportsMultijob() then
        return ok({ multijob = false, jobs = {}, invites = {}, max = MAX })
    end

    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end

    local activeJob   = job.getName(src)
    local activeGrade = job.getGrade(src)

    local map = store.getSaved(cid)
    if activeJob and not BLACKLIST[activeJob] then
        local prev = map[activeJob]
        if not prev or prev.grade ~= activeGrade then
            map[activeJob] = { grade = activeGrade }
            store.setSaved(cid, map)
        end
    end

    local list = {}
    for jName, info in pairs(map) do
        if not BLACKLIST[jName] then
            list[#list + 1] = describe(jName, info.grade or 0, jName == activeJob)
        end
    end
    table.sort(list, function(a, b)
        if (a.active or false) ~= (b.active or false) then return a.active == true end
        return a.label < b.label
    end)

    local invites = {}
    for _, r in ipairs(store.listInvites(cid)) do
        invites[#invites + 1] = {
            id         = r.id,
            job        = r.job,
            label      = job.getLabel(r.job) or r.job,
            grade      = r.grade or 0,
            gradeLabel = society.gradeLabel(r.job, r.grade or 0),
            from       = (r.invited_by and r.invited_by ~= '') and r.invited_by or 'A manager',
        }
    end

    return ok({ multijob = true, jobs = list, invites = invites, max = MAX })
end

---Make a saved job the active one (framework SetJob at its SAVED grade). The target job comes
---from the payload but must already exist in the caller's own saved map - which is only ever
---written by accepted offers, boss promotions/demotions, and framework seeding - so a crafted
---payload can't switch into a job or grade the player was never given. Blacklisted jobs are
---rejected outright. Mirrors sd-multijob: switching drops you off duty (config SwitchOffDuty),
---and the rosters of the job you left and the one you joined both refresh live.
---@param src number
---@param payload { job?: string }
---@return table
function jobs.switch(src, payload)
    payload = type(payload) == 'table' and payload or {}
    if not job.supportsMultijob() then return fail('Not available here') end
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end

    local target = tostring(payload.job or '')
    if target == '' or BLACKLIST[target] then return fail('Invalid job') end

    local map = store.getSaved(cid)
    local info = map[target]
    if not info then return fail("You haven't got that job saved") end
    local fromJob = job.getName(src)
    if fromJob == target then return fail('That job is already active') end

    if not job.set(src, target, info.grade or 0) then
        return fail('Could not switch to that job')
    end
    if OFF_DUTY then job.setDuty(src, false) end

    actions.notifyRoster(fromJob)
    actions.notifyRoster(target)

    return jobs.list(src)
end

---Forget a saved job, dropping the framework membership on QBox so it truly goes away. Removing
---the job you're actively working resigns you to unemployed (and off duty) first, then refreshes
---the bosses' rosters of the job you left. Scoped entirely to the caller's own saved map, so an
---arbitrary payload job at worst removes nothing.
---@param src number
---@param payload { job?: string }
---@return table
function jobs.remove(src, payload)
    payload = type(payload) == 'table' and payload or {}
    if not job.supportsMultijob() then return fail('Not available here') end
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end

    local target = tostring(payload.job or '')
    if target == '' then return fail('No job selected') end

    local wasActive = job.getName(src) == target
    if wasActive then
        if not job.set(src, UNEMPLOYED, 0) then return fail('Could not update your job') end
        job.setDuty(src, false)
    end

    store.removeSaved(cid, target)
    job.leave(src, target)
    if wasActive then actions.notifyRoster(target) end
    return jobs.list(src)
end

---Accept a pending offer: save the job (you switch to it from "My Jobs" when ready) and clear the
---offer. The invite is looked up scoped to the caller's own citizenid, so an invite id can't be
---replayed against someone else's offer, and the saved grade comes from the stored invite - never
---the payload - so accepting is the ONLY way a hire lands, and it lands exactly as the boss
---offered it. Enforces the MaxSavedJobs cap (0 = no cap; already holding the job doesn't
---double-count). The hiring boss's Manage Employees list updates live.
---@param src number
---@param payload { id?: string }
---@return table
function jobs.accept(src, payload)
    payload = type(payload) == 'table' and payload or {}
    if not job.supportsMultijob() then return fail('Not available here') end
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end

    local id  = tostring(payload.id or '')
    local inv = store.getInvite(cid, id)
    if not inv then return fail('That offer is no longer available') end

    local map = store.getSaved(cid)
    if MAX > 0 and not map[inv.job] and savedCount(map) >= MAX then
        return fail('You already have the maximum number of jobs')
    end

    store.addSaved(cid, inv.job, inv.grade or 0)
    store.deleteInvite(cid, id)
    actions.notifyRoster(inv.job)
    return jobs.list(src)
end

---Decline (delete) a pending offer. Scoped to the caller's own citizenid, so deleting an unknown
---or foreign id is a no-op. Idempotent.
---@param src number
---@param payload { id?: string }
---@return table
function jobs.decline(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    store.deleteInvite(cid, tostring(payload.id or ''))
    return jobs.list(src)
end

return jobs
