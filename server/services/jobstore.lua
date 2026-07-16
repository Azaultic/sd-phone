---@type table Saved-jobs store module; the table returned at end of file.
local store = {}

---Create the saved-jobs, job-offer and pending-fire tables if they don't exist, so the resource
---is drop-in. phone_saved_jobs is the phone's OWN multi-job list (framework-agnostic, so it works
---on both QBCore and QBox); its `jobs` column is a JSON map of jobName -> { grade }.
---phone_job_invites holds the offers a player must accept - one per (citizenid, job), so
---re-hiring just refreshes the grade, and DB-backed so an offline player sees the offer on next
---login. phone_job_fires records players fired from their ACTIVE framework job while offline (an
---offline framework job can't be changed), consumed on their next load by reconcileJobs. Run once
---at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_saved_jobs (
            citizenid  VARCHAR(64) NOT NULL,
            jobs       JSON        NULL,
            updated_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_job_invites (
            id         VARCHAR(48)  NOT NULL,
            citizenid  VARCHAR(64)  NOT NULL,
            job        VARCHAR(64)  NOT NULL,
            grade      INT          NOT NULL DEFAULT 0,
            invited_by VARCHAR(128) NULL,
            created_at INT          NOT NULL DEFAULT 0,
            PRIMARY KEY (id),
            UNIQUE KEY uq_invite (citizenid, job)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_job_fires (
            citizenid VARCHAR(64) NOT NULL,
            job       VARCHAR(64) NOT NULL,
            PRIMARY KEY (citizenid, job)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end

---Queue an unemployment to apply on the player's next load (offline fire). Idempotent: INSERT
---IGNORE, so re-firing the same (citizenid, job) changes nothing.
---@param citizenid string
---@param job string
function store.addPendingFire(citizenid, job)
    if not citizenid or citizenid == '' or not job or job == '' then return end
    MySQL.update.await('INSERT IGNORE INTO phone_job_fires (citizenid, job) VALUES (?, ?)', { citizenid, job })
end

---Consume a pending fire for (citizenid, job): returns true and clears it if one existed, so the
---caller sets them unemployed exactly once.
---@param citizenid string
---@param job string
---@return boolean
function store.takePendingFire(citizenid, job)
    if not citizenid or citizenid == '' or not job or job == '' then return false end
    local row = MySQL.single.await('SELECT 1 AS x FROM phone_job_fires WHERE citizenid = ? AND job = ?', { citizenid, job })
    if not row then return false end
    MySQL.update.await('DELETE FROM phone_job_fires WHERE citizenid = ? AND job = ?', { citizenid, job })
    return true
end

---Citizenids with a pending fire for `jobName` (set), so a just-fired offline member can be
---hidden from the roster immediately rather than lingering until they reconnect. Non-consuming.
---@param jobName string
---@return table<string, boolean>
function store.pendingFireCids(jobName)
    local set = {}
    if not jobName or jobName == '' then return set end
    local rows = MySQL.query.await('SELECT citizenid FROM phone_job_fires WHERE job = ?', { jobName }) or {}
    for _, r in ipairs(rows) do set[r.citizenid] = true end
    return set
end

---Fresh offer id (time + random suffix). Real uniqueness is enforced by the table's
---(citizenid, job) unique key; the id only needs to be practically collision-free.
---@return string
function store.newId()
    return ('inv_%d_%d'):format(os.time(), math.random(100000, 999999))
end

---Read a player's saved-jobs map. Returns `{ [job] = { grade } }`, or `{}`. oxmysql may hand the
---JSON column back pre-decoded as a table; a raw string is decoded under a pcall guard so a
---corrupt row degrades to an empty map instead of erroring the caller.
---@param citizenid string
---@return table
function store.getSaved(citizenid)
    if not citizenid or citizenid == '' then return {} end
    local row = MySQL.single.await('SELECT jobs FROM phone_saved_jobs WHERE citizenid = ?', { citizenid })
    if not row or not row.jobs then return {} end
    if type(row.jobs) == 'table' then return row.jobs end
    local ok, decoded = pcall(json.decode, row.jobs)
    return (ok and type(decoded) == 'table') and decoded or {}
end

---Everyone who has `jobName` in their saved jobs -> `{ {citizenid, grade}, ... }`. Used to roster
---employees who were hired here but are currently working another of their jobs (so bosses can
---still see + manage them). The JSON path is built from a framework/config job name (never client
---input) and rides as a bound `?` parameter either way.
---@param jobName string
---@return { citizenid: string, grade: number }[]
function store.savedJobMembers(jobName)
    if not jobName or jobName == '' then return {} end
    local path = ('$."%s".grade'):format(jobName)
    local rows = MySQL.query.await([[
        SELECT citizenid, JSON_EXTRACT(jobs, ?) AS grade
        FROM phone_saved_jobs
        WHERE JSON_EXTRACT(jobs, ?) IS NOT NULL
    ]], { path, path }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { citizenid = r.citizenid, grade = math.floor(tonumber(r.grade) or 0) }
    end
    return out
end

---Overwrite a player's saved-jobs map (upsert).
---@param citizenid string
---@param map table
function store.setSaved(citizenid, map)
    if not citizenid or citizenid == '' then return end
    MySQL.update.await([[
        INSERT INTO phone_saved_jobs (citizenid, jobs) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE jobs = VALUES(jobs)
    ]], { citizenid, json.encode(map or {}) })
end

---Add (or update the grade of) one saved job. The grade is coerced to a non-negative-safe
---integer here so every write path stores the same shape.
---@param citizenid string
---@param job string
---@param grade number
function store.addSaved(citizenid, job, grade)
    local map = store.getSaved(citizenid)
    map[job] = { grade = math.floor(tonumber(grade) or 0) }
    store.setSaved(citizenid, map)
end

---Remove one saved job. No-op when the job isn't saved, so it never churns the row.
---@param citizenid string
---@param job string
function store.removeSaved(citizenid, job)
    local map = store.getSaved(citizenid)
    if map[job] == nil then return end
    map[job] = nil
    store.setSaved(citizenid, map)
end

---List a player's pending job offers, newest first.
---@param citizenid string
---@return table[]
function store.listInvites(citizenid)
    if not citizenid or citizenid == '' then return {} end
    return MySQL.query.await(
        'SELECT id, job, grade, invited_by, created_at FROM phone_job_invites WHERE citizenid = ? ORDER BY created_at DESC',
        { citizenid }) or {}
end

---Fetch a single offer for a player. Scoped to the caller's citizenid as well as the id, so a
---player can't act on someone else's invite id.
---@param citizenid string
---@param id string
---@return table|nil
function store.getInvite(citizenid, id)
    if not citizenid or not id or id == '' then return nil end
    return MySQL.single.await(
        'SELECT id, job, grade, invited_by, created_at FROM phone_job_invites WHERE citizenid = ? AND id = ?',
        { citizenid, id })
end

---Create or refresh a pending offer. Unique per (citizenid, job): re-inviting upserts the grade,
---inviter and timestamp rather than stacking a second offer.
---@param inv { id: string, cid: string, job: string, grade: number, invitedBy?: string, createdAt: number }
function store.addInvite(inv)
    MySQL.update.await([[
        INSERT INTO phone_job_invites (id, citizenid, job, grade, invited_by, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            grade = VALUES(grade), invited_by = VALUES(invited_by), created_at = VALUES(created_at)
    ]], { inv.id, inv.cid, inv.job, math.floor(tonumber(inv.grade) or 0), inv.invitedBy, inv.createdAt or os.time() })
end

---Delete one offer, scoped to its owner. Idempotent.
---@param citizenid string
---@param id string
function store.deleteInvite(citizenid, id)
    if not citizenid or not id then return end
    MySQL.update.await('DELETE FROM phone_job_invites WHERE citizenid = ? AND id = ?', { citizenid, id })
end

return store
