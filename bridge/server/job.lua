---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework  = require 'bridge.shared.framework'
---@type table Player bridge (bridge.server.player): framework-native player object resolution.
local player_mod = require 'bridge.server.player'

---@type table Job module; the table returned at end of file. Job identity/permission primitives
---for the server bridge - every `source` these take must come from the server's own event context
---(lib.callback src / net event source), never from a client payload, since app permission gates
---(boss dashboards, job whitelists) build directly on these answers.
local job = {}

---The player's current job name, read live from the framework player object so a mid-session job
---change is always reflected. Nil when the player can't be resolved (offline / between characters)
---or the framework path yields nothing.
---@param source number player server id
---@return string|nil
function job.getName(source)
    local p = player_mod.get(source)
    if not p then return nil end
    if framework.name == 'esx'  then return p.job and p.job.name or nil end
    if framework.name == 'qb' then return p.PlayerData.job and p.PlayerData.job.name or nil end
    return nil
end

---The player's current job grade level. Returns 0 (not nil) when the player or grade can't be
---resolved, so numeric comparisons at call sites never see nil.
---@param source number player server id
---@return integer
function job.getGrade(source)
    local p = player_mod.get(source)
    if not p then return 0 end
    if framework.name == 'esx'  then return p.job and p.job.grade or 0 end
    if framework.name == 'qb' then
        return p.PlayerData.job and p.PlayerData.job.grade and p.PlayerData.job.grade.level or 0
    end
    return 0
end

---Predicate: does the player currently hold `jobName` at grade >= `minGrade`? Checks the ACTIVE
---job only - an off-duty saved job doesn't count. Fails closed (false) when the player can't be
---resolved, so a permission gate built on this can't be passed by an unresolvable source.
---@param source number player server id
---@param jobName string
---@param minGrade? integer Default 0.
---@return boolean
function job.has(source, jobName, minGrade)
    minGrade = minGrade or 0
    local p = player_mod.get(source)
    if not p then return false end

    if framework.name == 'qb' then
        local data = p.PlayerData.job
        if data and data.name == jobName then
            return (data.grade and data.grade.level or 0) >= minGrade
        end
    elseif framework.name == 'esx' then
        local data = p.job
        if data and data.name == jobName then
            return (data.grade or 0) >= minGrade
        end
    end
    return false
end

---Convenience: true if the player matches any `{ name=..., minGrade=? }` entry. An EMPTY list
---returns true so callers can use it as a default-allow gate (an unset config whitelist means
---everyone) - callers gating something sensitive must pass a non-empty list.
---@param source number player server id
---@param options { name: string, minGrade?: integer }[]
---@return boolean
function job.hasAny(source, options)
    if not options or #options == 0 then return true end
    for i = 1, #options do
        if job.has(source, options[i].name, options[i].minGrade or 0) then
            return true
        end
    end
    return false
end

---True when the player is currently on `jobName` AND a boss of it. QBCore/QBox expose an `isboss`
---flag on the active job grade; ESX has no such flag, so it falls back to "grade >= esxBossGrade"
---(default 0 = any grade - pass a real threshold to gate it). Fails closed when unresolvable.
---@param source number player server id
---@param jobName string
---@param esxBossGrade? integer ESX boss-grade threshold. Default 0.
---@return boolean
function job.isBoss(source, jobName, esxBossGrade)
    local p = player_mod.get(source)
    if not p then return false end

    if framework.name == 'qb' then
        local data = p.PlayerData.job
        return data ~= nil and data.name == jobName and data.isboss == true
    elseif framework.name == 'esx' then
        local data = p.job
        return data ~= nil and data.name == jobName and (data.grade or 0) >= (esxBossGrade or 0)
    end
    return false
end

---Set the player's job through the framework's REAL job system (so paychecks, duty and every
---other consumer see it - not just the phone). Mutating: callers own the permission check (the
---Services app only reaches this via a server-validated accepted offer or the player's own saved
---job). Returns the framework's own verdict on QBCore (false when the job doesn't exist); ESX
---setJob returns nothing, so success is assumed there.
---@param source number player server id
---@param jobName string
---@param grade? integer Default 0.
---@return boolean
function job.set(source, jobName, grade)
    local p = player_mod.get(source)
    if not p then return false end
    grade = grade or 0

    if framework.name == 'qb' then return p.Functions.SetJob(jobName, grade) end
    if framework.name == 'esx' then p.setJob(jobName, grade); return true end
    return false
end

---The player's current on-duty state. QBCore/QBox expose `job.onduty`; ESX has no native duty
---concept, so this returns nil there and callers fall back to their own stored preference.
---@param source number player server id
---@return boolean|nil
function job.getDuty(source)
    local p = player_mod.get(source)
    if not p then return nil end
    if framework.name == 'qb' then
        return p.PlayerData.job ~= nil and p.PlayerData.job.onduty == true
    end
    return nil
end

---True when the framework supports a multi-job ("saved jobs") model - QBCore and QBox both do (a
---player can hold several jobs and switch the active one via SetJob). ESX has no portable
---multi-job concept, so the phone's Jobs tab is hidden there.
---@return boolean
function job.supportsMultijob()
    return framework.name == 'qb'
end

---Resolve a job's display label ('Police') from the framework's job definitions: qb-core's
---Shared.Jobs first, then the qbx_core GetJob export (pcall-guarded - the export doesn't exist on
---plain QBCore). Falls back to nil so callers can use the bare job name. Read-only.
---@param jobName string
---@return string|nil
function job.getLabel(jobName)
    if not jobName or jobName == '' then return nil end
    if framework.name == 'qb' then
        local def
        if framework.core and framework.core.Shared and framework.core.Shared.Jobs then
            def = framework.core.Shared.Jobs[jobName]
        end
        if not def then pcall(function() def = exports.qbx_core:GetJob(jobName) end) end
        return def and def.label or nil
    end
    return nil
end

---Drive the player's on-duty state through the framework's REAL duty system so blips, /duty
---gating, dispatch and paychecks all see it - not just the phone. QBCore/QBox route through
---SetJobDuty; ESX has no native duty, so this is a no-op there (returns false) and the caller
---keeps its own pref as the source of truth.
---@param source number player server id
---@param onDuty boolean
---@return boolean applied true when the framework applied it
function job.setDuty(source, onDuty)
    local p = player_mod.get(source)
    if not p then return false end
    if framework.name == 'qb' then
        p.Functions.SetJobDuty(onDuty == true)
        return true
    end
    return false
end

---Drop the player's framework membership of `jobName` (QBox's multi-job table) so it stops paying
---out / showing duty. The RemovePlayerFromJob export is pcall-guarded because it only exists on
---qbx_core. No-op on plain QBCore and ESX, which have no separate membership table - there the
---phone's own saved-jobs list is the only record. Returns true when the framework handled it.
---@param source number player server id
---@param jobName string
---@return boolean
function job.leave(source, jobName)
    if framework.name ~= 'qb' then return false end
    local p = player_mod.get(source)
    local cid = p and p.PlayerData and p.PlayerData.citizenid
    if not cid then return false end
    local ok = pcall(function() exports.qbx_core:RemovePlayerFromJob(cid, jobName) end)
    return ok
end

return job
