---@type table sd-phone config root (configs/config.lua).
local config   = require 'configs.config'
---@type table Services prefs store (server.services.store): per-(character, job) duty/calls/messages toggles.
local store    = require 'server.services.store'
---@type table Company inbox store (server.services.msgstore): shared (job, customer) message rows + read state.
local msgstore = require 'server.services.msgstore'
---@type table Saved-jobs store (server.services.jobstore): phone multijob list, job offers, pending fires.
local jobstore = require 'server.services.jobstore'
---@type table Society bridge (bridge.server.society): company balance, grade ladders, roster, hire/fire.
local society  = require 'bridge.server.society'
---@type table Banking bridge (bridge.server.banking): the caller's personal bank balance + credit/debit.
local bank     = require 'bridge.server.banking'
---@type table Job bridge (bridge.server.job): current job/grade/duty reads + SetJob/SetJobDuty writes.
local job      = require 'bridge.server.job'
---@type table Player bridge (bridge.server.player): citizenid/name/source lookups.
local player   = require 'bridge.server.player'
---@type table Settings store (server.settings.store): phone-number ownership lookups.
local settings = require 'server.settings.store'
---@type table Calls actions (server.calls.actions): the group-ring plumbing company calls reuse.
local calls    = require 'server.calls.actions'

---@type table Services config (configs/services.lua): companies, boss grades, employee caps.
local SV           = config.Services
---@type table[] Configured company entries (SV.Companies), in directory order.
local COMPANIES    = SV.Companies or {}
---@type integer ESX-only fallback boss grade for companies without their own bossGrade override.
local DEFAULT_BOSS = SV.DefaultBossGrade or 3
---@type string Job a fired or resigning employee is reset to.
local UNEMPLOYED   = SV.UnemployedJob or 'unemployed'
---@type integer Cap on how many rows the boss roster returns.
local EMP_LIMIT    = SV.EmployeeLimit or 100

---@type table<string, table> Company config entry by job name, for O(1) lookup of the caller's own company.
local byJob = {}
for _, c in ipairs(COMPANIES) do byJob[c.job] = c end

-- Jobs that count as "no job" (no Actions tab). Unemployed is always included.
---@type table<string, boolean> Set of jobs the Services app treats as not employed.
local BLACKLIST = {}
for _, j in ipairs(SV.JobBlacklist or { 'unemployed' }) do BLACKLIST[j] = true end
BLACKLIST[UNEMPLOYED] = true

---ESX boss-grade threshold for a job: the per-company bossGrade override, else DefaultBossGrade.
---QBCore/QBox ignore this - job.isBoss reads the grade's isboss flag there.
---@param jobName string framework job name
---@return integer
local function esxBossGrade(jobName)
    local entry = byJob[jobName]
    return (entry and entry.bossGrade) or DEFAULT_BOSS
end

---@type table Actions module; every handler returns the { success, data?, message? } envelope
---(matching the Banking module). The table returned at end of file.
local actions = {}

local util = require 'server.util'
local ok, fail, digits, trim = util.ok, util.fail, util.digits, util.trim



---Parse a client message draft into what gets stored: a kind, a body (a placeholder caption for
---non-text kinds, used for thread previews + push notifications) and a JSON meta blob of the
---extras. The kind is effectively whitelist-checked by the branching - anything that isn't
---'image' or 'location' is stored as plain text. Every client string is length-capped to the same
---limits server.messages uses (mediaUrl 512, wpCode 256, wpSub 128, body 300), so a crafted
---payload can't bloat the TEXT columns or the recipients' NUI. Returns `nil, errorMessage` when
---the draft is empty/invalid - on failure the second return is the error, not a body.
---@param payload { kind?: string, body?: string, mediaUrl?: string, wpCode?: string, wpSub?: string }
---@return string|nil kind, string body, string|nil meta
local function parseDraft(payload)
    local kind = tostring(payload.kind or 'text')
    if kind == 'image' then
        local url = trim(payload.mediaUrl):sub(1, 512)
        if url == '' then return nil, 'No image' end
        return 'image', '📷 Photo', json.encode({ mediaUrl = url })
    elseif kind == 'location' then
        local wp = trim(payload.wpCode):sub(1, 256)
        if wp == '' then return nil, 'No location' end
        local meta = { wpCode = wp }
        local sub = trim(payload.wpSub):sub(1, 128)
        if sub ~= '' then meta.wpSub = sub end
        return 'location', '📍 Location', json.encode(meta)
    end
    local body = trim(payload.body)
    if body == '' then return nil, 'Empty message' end
    if #body > 300 then body = body:sub(1, 300) end
    return 'text', body, nil
end

---Assert the caller is a boss of their CURRENT job - the single gate every management callback
---passes through. Boss status comes from the framework's isboss grade flag (esxBossGrade only
---matters on ESX, which has no flag), so it works for any job, configured company or not. Checked
---here (never client-side only), and the client never names which company it's acting on, so a
---player can only ever manage the company they actually work for. Returns `(jobName, citizenid)`
---on success, or `(nil, errorMessage)` so callers can `if not myJob then return fail(err) end`.
---@param src number caller server id
---@return string|nil jobName, string citizenidOrError
local function requireBoss(src)
    local cid = player.getIdentifier(src)
    if not cid then return nil, 'Player not found' end
    local myJob = job.getName(src)
    if not myJob or BLACKLIST[myJob] then return nil, "You're not in a job" end
    if not job.isBoss(src, myJob, esxBossGrade(myJob)) then return nil, 'You must be the boss to do that' end
    return myJob, cid
end

---Build the `myCompany` block for the caller, or nil when they hold no real job. Any
---non-blacklisted job gets an Actions tab (duty toggle + quit), even one that isn't a configured
---Company - the company-only bits (Job Calls, bank, employees) stay gated behind a config entry.
---Balance + roster are included ONLY for bosses, so that data never leaves the server for a
---regular employee; `myGrade` ships so the UI can hide manage actions on equal/higher ranks. Duty
---prefers the framework's REAL duty state (so the toggle reflects /duty, MDT, etc.), falling back
---to the stored pref on frameworks without native duty (ESX) - checked explicitly rather than via
---the and/or idiom, which would collapse a genuine OFF-duty (false) back onto prefs.duty and read
---as "off duty but the toggle shows on". The boss roster is framework members (their active job
---is this one) UNION saved-job holders (hired here but currently working another of their jobs),
---keyed by citizenid so a person who's both appears once; the grade ladder is mapped to labels
---once so the roster doesn't re-query grades per employee (N+1), saved-only members are named in
---one namesByCids batch, just-fired offline members (pendingFireCids) drop out at once, and the
---caller's own row is marked `self` so the UI hides "fire" on it. Status dot per row: working
---this job on duty = 'duty', working it off duty = 'offduty', offline or on another job = 'away'
---(a nil framework duty means no duty native, treated as on); the grade shown is the one that
---applies to THIS job - the framework grade while actively working it, else the saved grade.
---Sorted on-duty first, then off-duty, then away; within each by rank then name; capped at
---EMP_LIMIT rows.
---@param src number caller server id
---@return table|nil
local function buildMyCompany(src)
    local cid   = player.getIdentifier(src)
    local myJob = job.getName(src)
    if not cid or not myJob or BLACKLIST[myJob] then return nil end

    local entry  = byJob[myJob]
    local grade  = job.getGrade(src)
    local isBoss = job.isBoss(src, myJob, esxBossGrade(myJob))
    local prefs  = store.getPrefs(cid, myJob)

    local fwDuty = job.getDuty(src)
    local duty   = prefs.duty
    if fwDuty ~= nil then duty = fwDuty end

    local mc = {
        job         = myJob,
        label       = entry and entry.label or (job.getLabel(myJob) or myJob),
        isCompany   = entry ~= nil,
        isBoss      = isBoss,
        available   = society.available(),
        duty        = duty,
        jobCalls    = prefs.jobCalls,
        jobMessages = prefs.jobMessages,
        myGrade     = grade,
    }

    if isBoss then
        mc.balance = society.available() and society.getBalance(myJob) or nil
        mc.grades  = society.getGrades(myJob)

        local gradeMap = {}
        for _, g in ipairs(mc.grades) do gradeMap[g.level] = g.label end

        local online = player.onlineCidMap()

        local byCid, order = {}, {}
        local function ensure(ecid)
            local r = byCid[ecid]
            if not r then r = { id = ecid }; byCid[ecid] = r; order[#order + 1] = ecid end
            return r
        end
        for _, e in ipairs(society.listEmployees(myJob)) do
            local r = ensure(e.citizenid); r.name = e.name; r.fwGrade = e.grade
        end
        for _, s in ipairs(jobstore.savedJobMembers(myJob)) do
            ensure(s.citizenid).savedGrade = s.grade
        end

        local needNames = {}
        for ecid, r in pairs(byCid) do if not r.name then needNames[#needNames + 1] = ecid end end
        if #needNames > 0 then
            local names = society.namesByCids(needNames)
            for _, ecid in ipairs(needNames) do byCid[ecid].name = names[ecid] or ecid end
        end

        local fired  = jobstore.pendingFireCids(myJob)
        local roster = {}
        for _, ecid in ipairs(order) do
            if fired[ecid] then goto continue end
            local r    = byCid[ecid]
            local esrc = online[ecid]
            local status, grade
            if esrc and job.getName(esrc) == myJob then
                local d = job.getDuty(esrc)
                status = (d == nil or d) and 'duty' or 'offduty'
                grade  = r.fwGrade or r.savedGrade or 0
            else
                status = 'away'
                grade  = r.savedGrade or r.fwGrade or 0
            end
            roster[#roster + 1] = {
                id     = ecid,
                name   = r.name or ecid,
                rank   = gradeMap[grade] or ('Grade ' .. tostring(grade)),
                grade  = grade,
                status = status,
                online = esrc ~= nil,
                self   = ecid == cid or nil,
            }
            if #roster >= EMP_LIMIT then break end
            ::continue::
        end
        local statusRank = { duty = 0, offduty = 1, away = 2 }
        table.sort(roster, function(a, b)
            if a.status ~= b.status then return (statusRank[a.status] or 9) < (statusRank[b.status] or 9) end
            if a.grade  ~= b.grade  then return a.grade > b.grade end
            return a.name < b.name
        end)
        mc.employees = roster
    end

    return mc
end

---Tell every online boss of a job to refresh their roster (someone joined, left, changed rank or
---flipped duty). buildMyCompany only ships the roster to bosses, so only they need the nudge; the
---push carries no data - each boss's client re-pulls through the directory callback.
---@param jobName string|nil
function actions.notifyRoster(jobName)
    if not jobName or BLACKLIST[jobName] then return end
    local esxBoss = esxBossGrade(jobName)
    for _, tsrc in pairs(player.onlineCidMap()) do
        if job.getName(tsrc) == jobName and job.isBoss(tsrc, jobName, esxBoss) then
            TriggerClientEvent('sd-phone:client:services:rosterChanged', tsrc, {})
        end
    end
end

---Public directory rows for every configured company: config data only, nothing caller-specific.
---Shared by the directory callback and the getCompanyDirectory export so both list the same
---shape. Builds a fresh array per call, so callers may mutate their copy freely.
---@return table[] companies
function actions.companyList()
    local companies = {}
    for _, c in ipairs(COMPANIES) do
        companies[#companies + 1] = {
            id         = c.job,
            name       = c.label,
            location   = c.location,
            color      = c.color,
            emoji      = c.emoji,
            canCall    = c.canCall == true,
            callNumber = c.callNumber,
            coords     = c.coords and { x = c.coords.x, y = c.coords.y, z = c.coords.z } or nil,
        }
    end
    return companies
end

---Public company directory + the caller's own company block. The directory itself is open to
---everyone (it's config data); everything sensitive lives in myCompany, which buildMyCompany
---gates per caller. `multijob` gates the Jobs tab (qb/qbx only) and `pendingOffers` feeds its
---badge. Read-only.
---@param src number
function actions.directory(src)
    local cid = player.getIdentifier(src)
    return ok({
        companies     = actions.companyList(),
        myCompany     = buildMyCompany(src),
        multijob      = job.supportsMultijob(),
        pendingOffers = cid and #jobstore.listInvites(cid) or 0,
    })
end

---Toggle the caller's duty status for their current job (any employee, not just bosses). Drives
---the framework's REAL duty state (blips, /duty, pay) where one exists and always persists the
---pref (the ESX fallback, and it survives a relog). Fires the caller's own dutyChanged push, a
---generic server event other resources can hook, and nudges the bosses' rosters so the on/off
---duty status dot updates live while they're watching the Actions tab (not only after a re-open).
---Identity comes from src alone; the payload only carries the desired state, coerced to a strict
---boolean.
---@param src number
---@param payload { on?: boolean }
function actions.setDuty(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    local myJob = job.getName(src)
    if not myJob or BLACKLIST[myJob] then return fail("You're not in a job") end

    local on = payload.on == true
    job.setDuty(src, on)
    store.setDuty(cid, myJob, on)
    TriggerClientEvent('sd-phone:client:services:dutyChanged', src, { job = myJob, duty = on })
    TriggerEvent('sd-phone:services:dutyChanged', src, myJob, on)
    actions.notifyRoster(myJob)
    return ok({ myCompany = buildMyCompany(src) })
end

---Toggle whether the caller receives customer job calls. Only meaningful for a configured
---company (unconfigured jobs have no call path), and only for the job the caller currently
---works - both resolved from src, never the payload.
---@param src number
---@param payload { on?: boolean }
function actions.setJobCalls(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    local myJob = job.getName(src)
    if not (myJob and byJob[myJob]) then return fail("You're not in a company") end

    store.setJobCalls(cid, myJob, payload.on == true)
    return ok({ myCompany = buildMyCompany(src) })
end

---Toggle whether the caller is notified of messages sent to their company. Same posture as
---setJobCalls: company + identity resolved from src, payload only carries the flag.
---@param src number
---@param payload { on?: boolean }
function actions.setJobMessages(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    local myJob = job.getName(src)
    if not (myJob and byJob[myJob]) then return fail("You're not in a company") end

    store.setJobMessages(cid, myJob, payload.on == true)
    return ok({ myCompany = buildMyCompany(src) })
end

---Move money from the boss's personal bank into the company account. Boss-only (requireBoss).
---The amount is coerced to a positive integer with NaN/inf rejected explicitly - every comparison
---against NaN is false, so an unguarded NaN would sail past both the sign check and the balance
---check and reach the money bridges. Debit-before-credit: the personal debit is pre-checked
---against the live balance (the banking bridge exposes no success signal on the debit itself),
---and a society credit that fails refunds the debit, mirroring banking.send.
---@param src number
---@param payload { amount?: number }
function actions.deposit(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local myJob, cidOrErr = requireBoss(src)
    if not myJob then return fail(cidOrErr) end

    local amount = math.floor(tonumber(payload.amount) or 0)
    if amount <= 0 or amount ~= amount or amount == math.huge then return fail('Enter a valid amount') end
    if not society.available() then return fail('No company bank is available') end
    if (bank.getBalance(src) or 0) < amount then return fail('Insufficient personal funds') end

    bank.removeMoney(src, amount, 'Company deposit')
    if not society.addMoney(myJob, amount, 'Phone deposit') then
        bank.addMoney(src, amount, 'Deposit refund')
        return fail('Could not reach the company account')
    end
    return ok({ myCompany = buildMyCompany(src) })
end

---Move money from the company account into the boss's personal bank. Boss-only. Same amount
---hygiene as deposit (positive integer, NaN/inf rejected). The society debit runs FIRST and its
---return is checked (the society bridge propagates a declined debit), so the personal credit only
---happens once the company money actually left - a failed debit can't print money.
---@param src number
---@param payload { amount?: number }
function actions.withdraw(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local myJob, cidOrErr = requireBoss(src)
    if not myJob then return fail(cidOrErr) end

    local amount = math.floor(tonumber(payload.amount) or 0)
    if amount <= 0 or amount ~= amount or amount == math.huge then return fail('Enter a valid amount') end
    if not society.available() then return fail('No company bank is available') end
    if society.getBalance(myJob) < amount then
        return fail('Insufficient company funds')
    end

    if not society.removeMoney(myJob, amount, 'Phone withdrawal') then
        return fail('Could not reach the company account')
    end
    bank.addMoney(src, amount, 'Company withdrawal')
    return ok({ myCompany = buildMyCompany(src) })
end

---Send a job OFFER to an online player by their server ID - never an instant SetJob, so a job
---only ever lands on a player through an invite THEY accept (jobs.accept). Boss-only. Resolving
---the server ID requires the target to be connected (server IDs only exist for online players),
---which also means the offer notification can go straight to that id. The offered grade is
---clamped to a non-negative integer and must sit BELOW the caller's own grade - the same ceiling
---promote enforces - so a boss can't mint an equal or higher-ranked hire who could then out-rank
---and fire them. Re-offering upserts on (citizenid, job), refreshing the grade rather than
---stacking invites.
---@param src number
---@param payload { serverId?: number, grade?: number }
function actions.hire(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local myJob, cid = requireBoss(src)
    if not myJob then return fail(cid) end
    local label = job.getLabel(myJob) or myJob

    local targetId = math.floor(tonumber(payload.serverId) or 0)
    if targetId <= 0 then return fail('Enter a valid server ID') end
    local grade = math.max(0, math.floor(tonumber(payload.grade) or 0))
    if grade >= job.getGrade(src) then return fail("You can't hire someone at or above your own rank") end

    local targetCid = player.getIdentifier(targetId)
    if not targetCid then return fail('No player with that ID is online') end
    if targetCid == cid then return fail("You can't hire yourself") end
    if jobstore.getSaved(targetCid)[myJob] then return fail('They already work here') end

    jobstore.addInvite({
        id        = jobstore.newId(),
        cid       = targetCid,
        job       = myJob,
        grade     = grade,
        invitedBy = player.getName(src),
        createdAt = os.time(),
    })

    TriggerClientEvent('sd-phone:client:notify', targetId, {
        app = 'services', appId = 'services', title = label,
        body = ('You have a job offer from %s. Open Services → Jobs to accept.'):format(label),
        time = 'now',
    })
    TriggerClientEvent('sd-phone:client:services:jobsChanged', targetId, {})

    return ok({ myCompany = buildMyCompany(src) })
end

---Resolve a target's standing in `myJob`: whether they're actively working it (management goes
---through the framework), or just hold it as a saved job while working another (managed via the
---saved-jobs store). The grade returned is the one that currently applies - the framework grade
---while they're actively on the job, else their saved grade. nil = not an employee at all, which
---callers treat as a hard stop, so a payload-supplied citizenid can only ever act on a real
---member of the boss's own company.
---@param myJob string the boss's company job
---@param targetCid string target citizenid (payload-supplied; validated here by membership)
---@return { src?: number, online: boolean, activeHere: boolean, grade: number, fw: boolean, saved: boolean }|nil
local function memberInfo(myJob, targetCid)
    local fwGrade
    for _, e in ipairs(society.listEmployees(myJob)) do
        if e.citizenid == targetCid then fwGrade = e.grade break end
    end
    local saved      = jobstore.getSaved(targetCid)[myJob]
    local savedGrade = saved and math.floor(tonumber(saved.grade) or 0) or nil
    if fwGrade == nil and savedGrade == nil then return nil end

    local tsrc       = player.getSourceByIdentifier(targetCid)
    local activeHere = tsrc ~= nil and job.getName(tsrc) == myJob
    local grade      = activeHere and (fwGrade or savedGrade or 0) or (savedGrade or fwGrade or 0)
    return { src = tsrc, online = tsrc ~= nil, activeHere = activeHere, grade = grade, fw = fwGrade ~= nil, saved = savedGrade ~= nil }
end

---Remove an employee (by citizenid) from the caller's company. Boss-only, self-fire blocked, and
---rank-gated: the target's applicable grade must be strictly below the caller's. Works on members
---who only hold the job as a saved job (currently working elsewhere), not just the actively
---on-shift ones. An actively-working member goes through the framework (online-only); one whose
---ACTIVE framework job is this one but who is offline gets a pending fire queued instead, applied
---on their next load by reconcileJobs - the fire branch there runs first, so the job is never
---re-added. The saved-jobs entry is dropped in every branch that has one, an online-elsewhere
---target gets their Jobs tab refreshed, and the bosses' rosters update live.
---@param src number
---@param payload { citizenid?: string }
function actions.fire(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local myJob, cid = requireBoss(src)
    if not myJob then return fail(cid) end

    local targetCid = tostring(payload.citizenid or '')
    if targetCid == '' then return fail('No employee selected') end
    if targetCid == cid then return fail("You can't fire yourself") end

    local info = memberInfo(myJob, targetCid)
    if not info then return fail('Employee not found') end
    if info.grade >= job.getGrade(src) then return fail("You can't fire someone of equal or higher rank") end

    if info.activeHere then
        if not society.fire(targetCid, UNEMPLOYED) then return fail('That player must be online to be fired') end
        if info.saved then jobstore.removeSaved(targetCid, myJob) end
    else
        if info.saved then jobstore.removeSaved(targetCid, myJob) end
        if info.fw then jobstore.addPendingFire(targetCid, myJob) end
        if info.src then TriggerClientEvent('sd-phone:client:services:jobsChanged', info.src, {}) end
    end

    actions.notifyRoster(myJob)
    return ok({ myCompany = buildMyCompany(src) })
end

---Promote an employee one grade up the company's ladder (the first level above their current
---applicable grade; the ladder comes from the framework, never the payload). Boss-only,
---self-promote blocked, and the new grade must stay below the caller's own - so nobody can be
---raised to a rank that could then manage the promoter. An actively-working member's framework
---grade is set (must succeed) with the saved grade mirroring it; a saved-away member just gets
---their saved grade bumped and reconcileJobs syncs the framework side when they next work the
---job. A member who exists only on the framework roster (no saved entry) can't be adjusted
---portably while away, so that path requires them online. Notifies + live-refreshes the target
---when online, and nudges the bosses' rosters.
---@param src number
---@param payload { citizenid?: string }
function actions.promote(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local myJob, cid = requireBoss(src)
    if not myJob then return fail(cid) end
    local label = job.getLabel(myJob) or myJob

    local targetCid = tostring(payload.citizenid or '')
    if targetCid == '' then return fail('No employee selected') end
    if targetCid == cid then return fail("You can't promote yourself") end

    local info = memberInfo(myJob, targetCid)
    if not info then return fail('Employee not found') end

    local nextGrade
    for _, g in ipairs(society.getGrades(myJob)) do
        if g.level > info.grade then nextGrade = g.level; break end
    end
    if not nextGrade then return fail('They are already at the highest rank') end
    if nextGrade >= job.getGrade(src) then return fail("You can't promote someone to your own rank") end

    if info.activeHere then
        if not job.set(info.src, myJob, nextGrade) then return fail('Could not update their grade') end
        jobstore.addSaved(targetCid, myJob, nextGrade)
    elseif info.saved then
        jobstore.addSaved(targetCid, myJob, nextGrade)
    else
        return fail('That player must be online to be promoted')
    end

    if info.src then
        TriggerClientEvent('sd-phone:client:notify', info.src, {
            app = 'services', appId = 'services', title = label,
            body = ('You were promoted to %s.'):format(society.gradeLabel(myJob, nextGrade)),
            time = 'now',
        })
        TriggerClientEvent('sd-phone:client:services:jobsChanged', info.src, {})
    end
    actions.notifyRoster(myJob)

    return ok({ myCompany = buildMyCompany(src) })
end

---Demote an employee one grade down the company's ladder (the highest level below their current
---applicable grade, walked from the framework's ascending ladder). Boss-only, self-demote
---blocked, can't act on someone of equal or higher rank, and can't go below the lowest grade.
---Same active/saved-away split as promote: framework write for an actively-working member, saved
---grade only for one working elsewhere, online required for a framework-only member.
---@param src number
---@param payload { citizenid?: string }
function actions.demote(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local myJob, cid = requireBoss(src)
    if not myJob then return fail(cid) end
    local label = job.getLabel(myJob) or myJob

    local targetCid = tostring(payload.citizenid or '')
    if targetCid == '' then return fail('No employee selected') end
    if targetCid == cid then return fail("You can't demote yourself") end

    local info = memberInfo(myJob, targetCid)
    if not info then return fail('Employee not found') end
    if info.grade >= job.getGrade(src) then return fail("You can't demote someone of equal or higher rank") end

    local prevGrade
    for _, g in ipairs(society.getGrades(myJob)) do
        if g.level < info.grade then prevGrade = g.level end
    end
    if not prevGrade then return fail('They are already at the lowest rank') end

    if info.activeHere then
        if not job.set(info.src, myJob, prevGrade) then return fail('Could not update their grade') end
        jobstore.addSaved(targetCid, myJob, prevGrade)
    elseif info.saved then
        jobstore.addSaved(targetCid, myJob, prevGrade)
    else
        return fail('That player must be online to be demoted')
    end

    if info.src then
        TriggerClientEvent('sd-phone:client:notify', info.src, {
            app = 'services', appId = 'services', title = label,
            body = ('You were demoted to %s.'):format(society.gradeLabel(myJob, prevGrade)),
            time = 'now',
        })
        TriggerClientEvent('sd-phone:client:services:jobsChanged', info.src, {})
    end
    actions.notifyRoster(myJob)

    return ok({ myCompany = buildMyCompany(src) })
end

---Resign from the job the caller currently works: reset to the configured unemployed job, forget
---the phone's saved-jobs entry, and drop the framework membership (QBox-only; a no-op elsewhere)
---so it doesn't linger as a job they can switch back to - mirroring jobs.remove. (A boss can't
---fire themselves, but anyone can quit.) notifyRoster is a no-op for non-company jobs, and the
---returned myCompany is nil so the UI flips to "not in a company".
---@param src number
---@return table
function actions.quit(src)
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    local myJob = job.getName(src)
    if not myJob or BLACKLIST[myJob] then return fail("You're not in a job") end
    if not job.set(src, UNEMPLOYED, 0) then return fail('Could not update your job') end
    jobstore.removeSaved(cid, myJob)
    job.leave(src, myJob)
    actions.notifyRoster(myJob)
    return ok({ myCompany = buildMyCompany(src) })
end

---Call a company: ring every ONLINE, on-duty, call-accepting employee of that job at once; the
---first to answer is connected (the rest stop ringing), via the phone's group-ring call plumbing.
---The company comes from the payload but is whitelist-checked against the configured directory
---and must be flagged callable. Calling your own company is refused outright - the ring loop
---skips the caller anyway, but the dedicated message is clearer than "no one is on duty". The
---duty read prefers the framework's native state and falls back to the stored pref (ESX);
---`anyOnDuty` tracks whether staff were working at all so the failure can distinguish "nobody
---working" (No one is on duty) from "working but not taking calls" (No one is available).
---@param src number
---@param payload { job?: string }
---@return table
function actions.callCompany(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local entry = byJob[tostring(payload.job or '')]
    if not entry then return fail('Unknown company') end
    if not entry.canCall then return fail("You can't call this company") end
    if not player.getIdentifier(src) then return fail('Player not found') end
    if job.getName(src) == entry.job then return fail("You can't call the company you work for") end

    local targets   = {}
    local anyOnDuty = false
    for cid, tsrc in pairs(player.onlineCidMap()) do
        if tsrc ~= src and job.getName(tsrc) == entry.job then
            local prefs   = store.getPrefs(cid, entry.job)
            local onDuty  = job.getDuty(tsrc)
            if onDuty == nil then onDuty = prefs.duty end
            if onDuty then
                anyOnDuty = true
                if prefs.jobCalls then
                    targets[#targets + 1] = { src = tsrc, cid = cid }
                end
            end
        end
    end
    if #targets == 0 then
        return fail(anyOnDuty and 'No one is available to take your call' or 'No one is on duty right now')
    end

    return calls.callGroup(src, targets, entry.label, entry.callNumber)
end

---Reshape stored inbox rows for a viewer. `viewerKind` is 'citizen' (Personal tab, the customer)
---or 'staff' (Job tab, an employee) - it decides which side of the conversation renders as "me".
---Rich extras (image URL / shared-location waypoint) are unpacked from the JSON meta blob under a
---pcall guard: meta is server-written, but a decode failure must degrade to a plain bubble rather
---than kill the whole inbox. Plain text rows have no meta.
---@param rows table[]
---@param viewerKind 'citizen'|'staff'
---@return table[]
local function serializeInbox(rows, viewerKind)
    local out = {}
    for _, r in ipairs(rows) do
        local mine = (viewerKind == 'citizen' and r.sender == 'citizen')
                  or (viewerKind == 'staff'   and r.sender == 'staff')
        local m = {
            id   = r.id,
            from = mine and 'me' or 'them',
            name = r.sender == 'staff' and (r.staff_name or 'Staff') or (r.citizen_name or ''),
            body = r.body or '',
            kind = r.kind or 'text',
            ts   = (tonumber(r.created_at) or 0) * 1000,
        }
        if r.meta and r.meta ~= '' then
            local okj, decoded = pcall(json.decode, r.meta)
            if okj and type(decoded) == 'table' then
                m.mediaUrl = decoded.mediaUrl
                m.wpCode   = decoded.wpCode
                m.wpSub    = decoded.wpSub
            end
        end
        out[#out + 1] = m
    end
    return out
end

---The caller's full Services inbox: `personal` (companies they've messaged as a customer, keyed
---by their own phone number) + `job` (customer threads for the configured company they currently
---work at, visible to every employee). Unread counts are per viewer - the job inbox is shared, so
---read state can't live on the message. Everything is scoped to the caller's own number and
---current job resolved from src; thread bodies are capped at the newest 100 rows each. Read-only.
---@param src number
---@return table
function actions.inbox(src)
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end

    local myNumber = digits(settings.getPhoneNumber(cid) or '')
    local myJob    = job.getName(src)

    local personal = {}
    if myNumber ~= '' then
        local unread = msgstore.personalUnread(cid, myNumber)
        for _, t in ipairs(msgstore.citizenThreads(myNumber)) do
            local e = byJob[t.job]
            personal[#personal + 1] = {
                key      = t.job,
                name     = (e and e.label) or t.job,
                color    = (e and e.color) or '#8E8E93',
                emoji    = (e and e.emoji) or '💬',
                preview  = t.last_body or '',
                ts       = (tonumber(t.created_at) or 0) * 1000,
                unread   = unread[t.job] or 0,
                messages = serializeInbox(msgstore.threadMessages(t.job, myNumber, 100), 'citizen'),
            }
        end
    end

    local jobThreads = {}
    local e = myJob and byJob[myJob]
    if e then
        local unread = msgstore.jobUnread(cid, myJob)
        for _, t in ipairs(msgstore.jobThreads(myJob)) do
            jobThreads[#jobThreads + 1] = {
                key      = t.citizen_number,
                name     = (t.citizen_name and t.citizen_name ~= '') and t.citizen_name or t.citizen_number,
                color    = e.color,
                emoji    = e.emoji,
                preview  = t.last_body or '',
                ts       = (tonumber(t.created_at) or 0) * 1000,
                unread   = unread[t.citizen_number] or 0,
                messages = serializeInbox(msgstore.threadMessages(myJob, t.citizen_number, 100), 'staff'),
            }
        end
    end

    return ok({ personal = personal, job = jobThreads, hasJob = e ~= nil })
end

---Mark a message thread read for the caller. `scope` 'job' keys the thread by the customer's
---number and requires the caller to actually work a configured company; anything else is treated
---as 'personal', keyed by the company job and scoped to the caller's own number. The key is
---length-capped to its destination column (customer number 32 / job name 64) so a crafted key
---can't overflow the read-state insert; an unknown key merely writes an inert read-state row
---scoped to the caller. Idempotent - the stored read timestamp never moves backwards.
---@param src number
---@param payload { scope?: string, key?: string }
---@return table
function actions.markThreadRead(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    local key = tostring(payload.key or '')
    if key == '' then return fail('Missing thread') end

    if payload.scope == 'job' then
        local myJob = job.getName(src)
        if myJob and byJob[myJob] then msgstore.markRead(cid, myJob, key:sub(1, 32), os.time()) end
    else
        local myNumber = digits(settings.getPhoneNumber(cid) or '')
        if myNumber ~= '' then msgstore.markRead(cid, key:sub(1, 64), myNumber, os.time()) end
    end
    return ok()
end

---Notify (+ live-refresh) every online, ON-DUTY employee of a job about a customer message. The
---banner is opt-in (the Job Messages toggle) and quiet while they're already inside the Services
---app - the message lands in the inbox they're looking at anyway; the inbox push always fires so
---an open app stays current either way. Off-duty staff get nothing.
---@param jobName string
---@param title string
---@param body string
local function notifyStaff(jobName, title, body)
    for ecid, esrc in pairs(player.onlineCidMap()) do
        if job.getName(esrc) == jobName then
            local prefs  = store.getPrefs(ecid, jobName)
            local onDuty = job.getDuty(esrc)
            if onDuty == nil then onDuty = prefs.duty end
            if onDuty then
                if prefs.jobMessages then
                    TriggerClientEvent('sd-phone:client:notify', esrc, {
                        app = 'services', appId = 'services', title = title, body = body, time = 'now',
                        quietInApp = true,
                    })
                end
                TriggerClientEvent('sd-phone:client:services:inbox', esrc, {})
            end
        end
    end
end

---Customer -> company. The company comes from the payload but is whitelist-checked against the
---configured directory; the sender's number + name come from src alone (the number is created on
---first use). The draft goes through parseDraft (kind whitelist + length caps) - on failure its
---second return is the error message, which rides back in the fail envelope. Files the message
---into the (job, my number) thread, pings on-duty staff, and returns the customer's refreshed
---inbox so the app updates in place.
---@param src number
---@param payload { job?: string, kind?: string, body?: string, mediaUrl?: string, wpCode?: string, wpSub?: string }
---@return table
function actions.messageCompany(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local entry = byJob[tostring(payload.job or '')]
    if not entry then return fail('Unknown company') end
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end

    local kind, body, meta = parseDraft(payload)
    if not kind then return fail(body) end

    local myNumber = digits(settings.ensurePhoneNumber(cid) or '')
    if myNumber == '' then return fail('No phone number') end
    local myName = player.getName(src)

    msgstore.insert({
        id = msgstore.newId(), job = entry.job,
        citizenNumber = myNumber, citizenName = myName,
        sender = 'citizen', body = body, kind = kind, meta = meta, createdAt = os.time(),
    })
    notifyStaff(entry.job, entry.label, myName .. ': ' .. body)

    ---First-party hook: fires once per stored customer -> company message (never per employee).
    ---Server-local and synchronous; the citizenid is for server-trusted consumers only.
    TriggerEvent('sd-phone:server:services:message', {
        source = src, citizenid = cid, job = entry.job, label = entry.label,
        number = myNumber, name = myName, kind = kind, body = body, meta = meta,
    })

    return ok({ inbox = actions.inbox(src).data })
end

---Staff -> customer. The company is derived from the caller's CURRENT job (never the payload),
---so an employee can only ever reply on behalf of their own company. The recipient number is
---digit-stripped and capped to its column width (VARCHAR(32)); the draft goes through the same
---parseDraft validation as the customer side (failure message in the second return). Notifies the
---customer if online (quiet while they're already in the Services app - the reply shows live).
---Returns the staff member's refreshed inbox.
---@param src number
---@param payload { citizen?: string, kind?: string, body?: string, mediaUrl?: string, wpCode?: string, wpSub?: string }
---@return table
function actions.replyCompany(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = player.getIdentifier(src)
    if not cid then return fail('Player not found') end
    local myJob = job.getName(src)
    local entry = myJob and byJob[myJob]
    if not entry then return fail("You're not in a company") end

    local citizenNumber = digits(payload.citizen):sub(1, 32)
    if citizenNumber == '' then return fail('No recipient') end
    local kind, body, meta = parseDraft(payload)
    if not kind then return fail(body) end

    msgstore.insert({
        id = msgstore.newId(), job = entry.job,
        citizenNumber = citizenNumber, sender = 'staff',
        staffCid = cid, staffName = player.getName(src),
        body = body, kind = kind, meta = meta, createdAt = os.time(),
    })

    local custCid = settings.getCitizenByNumber(citizenNumber)
    local custSrc = custCid and player.getSourceByIdentifier(custCid)
    if custSrc then
        TriggerClientEvent('sd-phone:client:notify', custSrc, {
            app = 'services', appId = 'services', title = entry.label, body = body, time = 'now',
            quietInApp = true,
        })
        TriggerClientEvent('sd-phone:client:services:inbox', custSrc, {})
    end

    return ok({ inbox = actions.inbox(src).data })
end

-- src -> citizenid for currently-loaded players, so a disconnect can refresh the right rosters
-- even though the framework has already dropped the player by then.
---@type table<number, string> Cached citizenid per connected src (set on load, cleared on drop).
local srcToCid = {}

---Apply phone-managed job changes that happened while the player was offline, run from the
---framework's player-loaded event (server-fired, so src is trustworthy):
---  - fired while offline: set them unemployed (consumes the pending fire, so it applies once).
---  - promoted/demoted offline: sync their active job's framework grade to the saved grade
---    (saved-jobs is authoritative for phone-managed jobs).
---  - already hold a job with no saved entry (existing servers): record it so it shows in their
---    Jobs tab and bosses can manage them - configured companies AND plain jobs alike. This runs
---    only when NOT fired (the fire branch returns first), so a just-fired job is never re-added.
---Also caches src -> citizenid for onPlayerDropped.
---@param src number
function actions.reconcileJobs(src)
    local cid = player.getIdentifier(src)
    if not cid then return end
    srcToCid[src] = cid

    local activeJob = job.getName(src)
    if not activeJob or activeJob == '' or BLACKLIST[activeJob] then return end

    if jobstore.takePendingFire(cid, activeJob) then
        job.set(src, UNEMPLOYED, 0)
        return
    end

    local saved = jobstore.getSaved(cid)[activeJob]
    if saved then
        local savedGrade = math.floor(tonumber(saved.grade) or 0)
        if savedGrade ~= (job.getGrade(src) or 0) then
            job.set(src, activeJob, savedGrade)
        end
    else
        jobstore.addSaved(cid, activeJob, job.getGrade(src) or 0)
    end
end

---On disconnect, refresh the rosters of every company the player belonged to so a boss watching
---the Actions tab sees them flip offline live. The framework has already dropped them by now, so
---their jobs come from the cached cid + their saved jobs (reconcileJobs ensures their active
---company job is among them). The DB read runs on a fresh thread so the drop handler itself never
---blocks; the cache entry is cleared first so recycled srcs can't collide.
---@param src number
function actions.onPlayerDropped(src)
    local cid = srcToCid[src]
    srcToCid[src] = nil
    if not cid then return end
    CreateThread(function()
        for jobName in pairs(jobstore.getSaved(cid)) do
            actions.notifyRoster(jobName)
        end
    end)
end

return actions
