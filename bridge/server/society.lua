---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework = require 'bridge.shared.framework'
---@type table Job bridge (bridge.server.job): job.set powers the online-only hire/fire paths.
local job       = require 'bridge.server.job'
---@type table Player bridge (bridge.server.player): identifier -> online source resolution.
local player    = require 'bridge.server.player'

---@type table Society module; the table returned at end of file. Reads + moves a COMPANY's shared
---balance and reads its employee roster across the popular money + management resources - the
---society counterpart to bridge/server/banking.lua (personal balances), following the same shape:
---a KNOWN provider list, a lazily-resolved + cached provider(), and a try(fn) wrapper so a
---missing/renamed export in a forked copy degrades to a safe failure instead of erroring. No
---authority lives here: boss gating and amount hygiene (positive integer, NaN/inf rejection)
---belong to the callers in server/services/actions.lua. This layer's contract is that a reported
---success is a REAL balance movement and a provider decline propagates as false.
local society = {}

-- Society money providers, in detection priority: the first started resource wins, own-table
-- resources ahead of framework-coupled ones. Export shapes:
--   qb-banking      : GetAccountBalance / AddMoney / RemoveMoney (account, amount, reason)
--   Renewed-Banking : getAccountMoney / addAccountMoney / removeAccountMoney (account, amount)
--   qbx_management  : GetAccount / AddMoney / RemoveMoney (account[, amount]) - newer builds
--                     dropped these exports entirely; the pcall wrappers degrade them to 0/false.
--   qb-management   : GetAccount / AddMoney / RemoveMoney (account[, amount])
--   esx_addonaccount / esx_society : esx_addonaccount:getSharedAccount('society_<job>') ->
--                     { money, addMoney, removeMoney }
-- Deliberately NOT faked because no provider does them portably: offline hire/fire (needs a live
-- framework player object - callers surface "must be online") and a society transaction log
-- (unlike personal banking, the phone keeps none for societies).
---@type string[] Society money providers, in detection-priority order.
local KNOWN = {
    'qb-banking', 'Renewed-Banking', 'qbx_management', 'qb-management',
    'esx_addonaccount', 'esx_society',
}

---@type boolean, string|nil Detection-ran flag + cached provider name (nil = none started).
local resolved, providerName = false, nil

---The active society money provider, resolved lazily (and cached) on first use rather than at
---load, so a provider that starts after sd-phone is still detected. Nil when none is started -
---callers then hide the money UI (via society.available) instead of showing a misleading $0.
---@return string|nil
local function provider()
    if not resolved then
        for _, name in ipairs(KNOWN) do
            if GetResourceState(name) == 'started' then providerName = name; break end
        end
        resolved = true
        print(('^2[sd-phone:society]^0 society provider: ^3%s^0'):format(providerName or 'none'))
    end
    return providerName
end

---Run a provider export/event call. Returns false if it errored OR the provider returned an
---explicit `false` (unknown account, insufficient funds) - so a credit / debit the provider
---DECLINED propagates as a failure instead of masquerading as success (qb-banking and
---Renewed-Banking signal declines with a boolean; treating "no error" as success silently lost
---the player's money on a bad account). A nil/other truthy return with no error still counts as
---success, since several providers return nothing on their happy path.
---@param fn function
---@return boolean
local function try(fn)
    local ok, res = pcall(fn)
    if not ok then return false end
    return res ~= false
end

---Default society account name for a job ('society_police'), overridable per company in
---configs/services.lua.
---@param jobName string
---@param override? string
---@return string
local function accName(jobName, override)
    return override or ('society_' .. jobName)
end

---True when a society money provider is running. When false, callers should hide the balance /
---deposit / withdraw UI rather than show a misleading $0.
---@return boolean
function society.available()
    return provider() ~= nil
end

---A company's shared balance; 0 when no provider is running or the account can't be read.
---Read-only. Keying differs per provider, hence the probing: qb-banking setups exist keyed by
---BOTH 'society_<job>' and the bare job name, so the first pass prefers whichever holds a NONZERO
---balance and the final call falls back to the society account's true value even when that's 0.
---Renewed-Banking keys its shared job accounts by the BARE job name (it seeds one per job at
---start via CreateJobAccount), so an explicit override is honoured first, then the job name, then
---the legacy 'society_<job>' just in case - its getAccountMoney returns false (not a number) for
---an unknown account, so the type() check naturally skips the misses. Stock esx_addonaccount
---fires its getSharedAccount callback synchronously, so the captured `bal` is populated before
---the pcall returns.
---@param jobName string
---@param override? string society account name override
---@return number
function society.getBalance(jobName, override)
    local name = provider()
    local acc  = accName(jobName, override)

    if name == 'qb-banking' then
        for _, key in ipairs({ acc, jobName }) do
            local ok, bal = pcall(function() return exports['qb-banking']:GetAccountBalance(key) end)
            if ok and type(bal) == 'number' and bal ~= 0 then return bal end
        end
        local ok, bal = pcall(function() return exports['qb-banking']:GetAccountBalance(acc) end)
        if ok and type(bal) == 'number' then return bal end

    elseif name == 'Renewed-Banking' then
        for _, key in ipairs({ override or jobName, 'society_' .. jobName }) do
            local ok, bal = pcall(function() return exports['Renewed-Banking']:getAccountMoney(key) end)
            if ok and type(bal) == 'number' then return bal end
        end

    elseif name == 'qbx_management' or name == 'qb-management' then
        local ok, bal = pcall(function() return exports[name]:GetAccount(jobName) end)
        if ok and type(bal) == 'number' then return bal end

    elseif name == 'esx_addonaccount' or name == 'esx_society' then
        local bal
        pcall(function()
            TriggerEvent('esx_addonaccount:getSharedAccount', acc, function(account)
                bal = account and account.money or nil
            end)
        end)
        if type(bal) == 'number' then return bal end
    end

    return 0
end

---Credit a company's shared balance. Returns true only if the credit landed - try() propagates a
---provider decline, so the caller can refund the player's side (services deposit does exactly
---that, debit-before-credit with a refund on a false here). Never falls through to personal
---money - the caller owns that side. Amount hygiene lives with the caller.
---@param jobName string
---@param amount number positive magnitude
---@param reason? string
---@param override? string
---@return boolean
function society.addMoney(jobName, amount, reason, override)
    local name = provider()
    if not name then return false end
    local acc = accName(jobName, override)
    reason = reason or 'Phone society deposit'

    if name == 'qb-banking' then
        return try(function() return exports['qb-banking']:AddMoney(acc, amount, reason) end)
    elseif name == 'Renewed-Banking' then
        return try(function() return exports['Renewed-Banking']:addAccountMoney(override or jobName, amount) end)
    elseif name == 'qbx_management' or name == 'qb-management' then
        return try(function() return exports[name]:AddMoney(jobName, amount) end)
    elseif name == 'esx_addonaccount' or name == 'esx_society' then
        local done = false
        pcall(function()
            TriggerEvent('esx_addonaccount:getSharedAccount', acc, function(account)
                if account then account.addMoney(amount); done = true end
            end)
        end)
        return done
    end
    return false
end

---Debit a company's shared balance. Returns true only if the debit landed; callers MUST verify
---the balance first (getBalance). qb-banking and Renewed-Banking also decline internally on
---insufficient funds and try() propagates that. The esx_addonaccount path checks sufficiency
---HERE, before calling removeMoney: the stock shared-account object subtracts blindly (no floor),
---so without the check a raced double-withdraw could drive the shared account negative while this
---bridge reported success. Checked here (not just in the caller's pre-check) so the answer stays
---truthful under concurrency.
---@param jobName string
---@param amount number positive magnitude
---@param reason? string
---@param override? string
---@return boolean
function society.removeMoney(jobName, amount, reason, override)
    local name = provider()
    if not name then return false end
    local acc = accName(jobName, override)
    reason = reason or 'Phone society withdrawal'

    if name == 'qb-banking' then
        return try(function() return exports['qb-banking']:RemoveMoney(acc, amount, reason) end)
    elseif name == 'Renewed-Banking' then
        return try(function() return exports['Renewed-Banking']:removeAccountMoney(override or jobName, amount) end)
    elseif name == 'qbx_management' or name == 'qb-management' then
        return try(function() return exports[name]:RemoveMoney(jobName, amount) end)
    elseif name == 'esx_addonaccount' or name == 'esx_society' then
        local done = false
        pcall(function()
            TriggerEvent('esx_addonaccount:getSharedAccount', acc, function(account)
                if account and (tonumber(account.money) or 0) >= amount then
                    account.removeMoney(amount)
                    done = true
                end
            end)
        end)
        return done
    end
    return false
end

---A job's grade ladder as `{ {level, label}, ... }` ordered by level. Read-only. On 'qb' the
---definition comes from framework.core.Shared.Jobs when populated, else the QBox export
---(qbx_core:GetJob) - QBox ships a compat core whose Shared table may be empty, so both probes
---are needed. On ESX the ladder is read straight from job_grades (parameterized). Yields an empty
---ladder when nothing is readable; gradeLabel then falls back to rendering "Grade N".
---@param jobName string
---@return { level: number, label: string }[]
function society.getGrades(jobName)
    local out = {}

    if framework.name == 'qb' then
        local def
        if framework.core and framework.core.Shared and framework.core.Shared.Jobs then
            def = framework.core.Shared.Jobs[jobName]
        end
        if not def then
            pcall(function() def = exports.qbx_core:GetJob(jobName) end)
        end
        if def and type(def.grades) == 'table' then
            for level, g in pairs(def.grades) do
                local lvl = tonumber(level) or 0
                out[#out + 1] = { level = lvl, label = (type(g) == 'table' and g.name) or ('Grade ' .. lvl) }
            end
        end

    elseif framework.name == 'esx' then
        local ok, rows = pcall(function()
            return MySQL.query.await(
                'SELECT grade, label FROM job_grades WHERE job_name = ? ORDER BY grade ASC', { jobName })
        end)
        if ok and type(rows) == 'table' then
            for _, r in ipairs(rows) do
                out[#out + 1] = { level = tonumber(r.grade) or 0, label = r.label or ('Grade ' .. tostring(r.grade)) }
            end
        end
    end

    table.sort(out, function(a, b) return a.level < b.level end)
    return out
end

---Resolve a grade level to its label for a job (used to render roster ranks). Falls back to
---"Grade N" when the ladder doesn't know the level.
---@param jobName string
---@param level number
---@return string
function society.gradeLabel(jobName, level)
    for _, g in ipairs(society.getGrades(jobName)) do
        if g.level == level then return g.label end
    end
    return 'Grade ' .. tostring(level or 0)
end

---A company's employees from the framework's player table as
---`{ {citizenid, name, grade}, ... }`. Read-only, DB-sourced (parameterized queries only), so
---OFFLINE employees are included. Online status is NOT set here - the actions layer annotates it
---via player.onlineCidMap() to keep this pure data. QBox caveat: the players table stores each
---character's ACTIVE job, so off-duty multijob members may not appear. Malformed charinfo/job
---JSON degrades that row to citizenid + grade 0 rather than dropping it.
---@param jobName string
---@return { citizenid: string, name: string, grade: number }[]
function society.listEmployees(jobName)
    local out = {}

    if framework.name == 'qb' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[
                SELECT citizenid, charinfo, job FROM players
                WHERE JSON_UNQUOTE(JSON_EXTRACT(job, '$.name')) = ?
            ]], { jobName })
        end)
        if ok and type(rows) == 'table' then
            for _, r in ipairs(rows) do
                local name, grade = r.citizenid, 0
                local okc, ci = pcall(json.decode, r.charinfo)
                if okc and type(ci) == 'table' then
                    name = ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
                end
                local okj, jb = pcall(json.decode, r.job)
                if okj and type(jb) == 'table' and jb.grade then grade = tonumber(jb.grade.level) or 0 end
                out[#out + 1] = { citizenid = r.citizenid, name = name ~= '' and name or r.citizenid, grade = grade }
            end
        end

    elseif framework.name == 'esx' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[
                SELECT identifier, firstname, lastname, job_grade FROM users WHERE job = ?
            ]], { jobName })
        end)
        if ok and type(rows) == 'table' then
            for _, r in ipairs(rows) do
                local name = ('%s %s'):format(r.firstname or '', r.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
                out[#out + 1] = {
                    citizenid = r.identifier,
                    name      = name ~= '' and name or r.identifier,
                    grade     = tonumber(r.job_grade) or 0,
                }
            end
        end
    end

    return out
end

---Resolve character names for a set of citizenids from the framework player table (works for
---offline players): `{ [citizenid] = name }`. The IN clause is built purely from `?` placeholders
---with the cids passed as bound params, so caller values never reach the SQL text. Used to name
---saved-job employees who aren't in a job's active framework roster. A row with empty/malformed
---charinfo falls back to the citizenid itself.
---@param cids string[]
---@return table<string, string>
function society.namesByCids(cids)
    local out = {}
    if not cids or #cids == 0 then return out end

    local placeholders = {}
    for i = 1, #cids do placeholders[i] = '?' end
    local inClause = table.concat(placeholders, ',')

    if framework.name == 'qb' then
        local ok, rows = pcall(function()
            return MySQL.query.await(('SELECT citizenid, charinfo FROM players WHERE citizenid IN (%s)'):format(inClause), cids)
        end)
        if ok and type(rows) == 'table' then
            for _, r in ipairs(rows) do
                local name = r.citizenid
                local okc, ci = pcall(json.decode, r.charinfo)
                if okc and type(ci) == 'table' then
                    local n = ('%s %s'):format(ci.firstname or '', ci.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
                    if n ~= '' then name = n end
                end
                out[r.citizenid] = name
            end
        end
    elseif framework.name == 'esx' then
        local ok, rows = pcall(function()
            return MySQL.query.await(('SELECT identifier, firstname, lastname FROM users WHERE identifier IN (%s)'):format(inClause), cids)
        end)
        if ok and type(rows) == 'table' then
            for _, r in ipairs(rows) do
                local n = ('%s %s'):format(r.firstname or '', r.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
                out[r.identifier] = n ~= '' and n or r.identifier
            end
        end
    end

    return out
end

---Set an ONLINE target's job to `jobName` at `grade`. Returns false when the target isn't
---currently connected - offline hire isn't portable (it needs a live framework player object).
---No permission checks here on purpose: authority (boss gating, the offered-grade-below-caller
---ceiling, invite-accept flow) is enforced by server/services/actions.lua before this runs; this
---is pure mechanism.
---@param jobName string
---@param targetCid string
---@param grade? number
---@return boolean
function society.hire(jobName, targetCid, grade)
    local src = player.getSourceByIdentifier(targetCid)
    if not src then return false end
    return job.set(src, jobName, grade or 0) == true
end

---Reset an ONLINE target to the unemployed job. Returns false when offline, for the same
---portability reason as hire - callers surface "must be online". Authority lives with the caller.
---@param targetCid string
---@param unemployedJob string
---@return boolean
function society.fire(targetCid, unemployedJob)
    local src = player.getSourceByIdentifier(targetCid)
    if not src then return false end
    return job.set(src, unemployedJob, 0) == true
end

return society
