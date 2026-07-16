---@type table Store module; the table returned at end of file.
local store = {}

-- Server-side pepper folded into every password hash, mirroring the Mail and Birdy stores. The
-- engine has its own pepper; legacy hashes are verified via those modules' hashers and upgraded
-- on first successful login (see actions.verifyPassword). Never log or broadcast this string.
---@type string Engine password pepper.
local PEPPER = 'sd-phone-v1::accounts::do-not-leak-this-string'

---Hash a password into a stable 24-char hex digest - the same three-lane digest the mail/birdy
---stores use, with the engine's own pepper. Deterministic on purpose: verification is a straight
---string compare in the caller, and the digest fits comfortably in the VARCHAR(64) hash column.
---@param password string plaintext password
---@return string hash 24-char hex digest
function store.hashPassword(password)
    local input = password .. PEPPER
    local h1, h2, h3 = 0x12345678, 0x87654321, 0xABCDEF01
    for i = 1, #input do
        local b = input:byte(i)
        h1 = (h1 * 31 + b) & 0xFFFFFFFF
        h2 = ((h2 ~ ((b << (i % 8)) & 0xFFFFFFFF)) + 0x9E3779B9) & 0xFFFFFFFF
        h3 = (((h3 << 5) | (h3 >> 27)) + b * (h1 + 1)) & 0xFFFFFFFF
    end
    return ('%08x%08x%08x'):format(h1, h2, h3)
end

---Create the engine tables idempotently, so the resource is drop-in. phone_app_accounts holds one
---row per (app, username) - the UNIQUE key is the authoritative duplicate guard behind the actions
---layer's friendlier pre-check. phone_app_sessions maps which account each citizen is signed into
---per app. phone_passwords is the per-character credential vault behind the Passwords app -
---plaintext by design: a password manager has to display what it stores, so its rows must only
---ever be read through citizenid-scoped queries. Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_app_accounts (
            id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
            app           VARCHAR(24)  NOT NULL,
            username      VARCHAR(64)  NOT NULL,
            display_name  VARCHAR(50)  NOT NULL DEFAULT '',
            password_hash VARCHAR(64)  NOT NULL,
            email         VARCHAR(120) NULL,
            phone         VARCHAR(20)  NULL,
            created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            UNIQUE KEY uq_app_username (app, username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_app_sessions (
            app        VARCHAR(24) NOT NULL,
            citizenid  VARCHAR(64) NOT NULL,
            account_id INT UNSIGNED NOT NULL,
            PRIMARY KEY (app, citizenid, account_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_passwords (
            id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
            citizenid  VARCHAR(64)  NOT NULL,
            app        VARCHAR(24)  NOT NULL,
            username   VARCHAR(64)  NOT NULL,
            password   VARCHAR(64)  NOT NULL,
            email      VARCHAR(120) NULL,
            phone      VARCHAR(20)  NULL,
            created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            UNIQUE KEY uq_vault (citizenid, app, username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

---Map a phone_app_accounts row to the camelCase account shape the actions layer uses. The
---passwordHash rides along for verification - callers strip it (publicAccount) before anything
---leaves the server.
---@param row table|nil raw DB row
---@return table|nil account
local function rowToAccount(row)
    if not row then return nil end
    return {
        id           = row.id,
        app          = row.app,
        username     = row.username,
        displayName  = row.display_name,
        passwordHash = row.password_hash,
        email        = row.email,
        phone        = row.phone,
    }
end

---One account by app + username. Read-only.
---@param app string account app key
---@param username string account username (already trimmed/lowered by the caller)
---@return table|nil account
function store.getAccount(app, username)
    return rowToAccount(MySQL.single.await(
        'SELECT * FROM phone_app_accounts WHERE app = ? AND username = ?',
        { app, username }
    ))
end

---One account by row id. Read-only.
---@param id number account row id
---@return table|nil account
function store.getAccountById(id)
    return rowToAccount(MySQL.single.await(
        'SELECT * FROM phone_app_accounts WHERE id = ?', { id }
    ))
end

---Accounts in `app` whose linked email or phone matches. Pass nil for the side that isn't being
---searched - each side is guarded by an IS NOT NULL check in the SQL, so a nil never matches a
---NULL column. Read-only.
---@param app string account app key
---@param email string|nil linked email to match
---@param phone string|nil linked phone (digits) to match
---@return table[] accounts
function store.findAccountsByContact(app, email, phone)
    local rows = MySQL.query.await([[
        SELECT * FROM phone_app_accounts
        WHERE app = ? AND ((? IS NOT NULL AND email = ?) OR (? IS NOT NULL AND phone = ?))
    ]], { app, email, email, phone, phone }) or {}
    local out = {}
    for i = 1, #rows do out[i] = rowToAccount(rows[i]) end
    return out
end

---Insert a new account row. Returns nil when the insert fails - including the UNIQUE
---(app, username) key rejecting a duplicate that raced past the actions layer's pre-check - so
---the caller reports failure instead of assuming success.
---@param app string account app key
---@param username string account username
---@param displayName string display name
---@param passwordHash string peppered hash (never the plaintext)
---@param email string|nil linked recovery email
---@param phone string|nil linked recovery phone (digits)
---@return number|nil insertId
function store.insertAccount(app, username, displayName, passwordHash, email, phone)
    return MySQL.insert.await([[
        INSERT INTO phone_app_accounts (app, username, display_name, password_hash, email, phone)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { app, username, displayName, passwordHash, email, phone })
end

---Replace an account's stored hash. Takes the already-hashed value so plaintext never enters the
---data layer.
---@param id number account row id
---@param passwordHash string peppered hash
function store.setPassword(id, passwordHash)
    MySQL.update.await('UPDATE phone_app_accounts SET password_hash = ? WHERE id = ?', { passwordHash, id })
end

---Delete an account and its sessions - sessions first, so no window exists where a session row
---resolves to a missing account.
---@param id number account row id
function store.deleteAccount(id)
    MySQL.update.await('DELETE FROM phone_app_sessions WHERE account_id = ?', { id })
    MySQL.update.await('DELETE FROM phone_app_accounts WHERE id = ?', { id })
end

---Sign a citizen into an account. Single-session apps (everything except mail, which keeps its
---own logged_in_citizens json) replace any prior session: delete-then-insert keyed off
---(app, citizenid), so one citizen can never hold two live sessions in the same app here.
---@param app string account app key
---@param citizenid string framework per-character id
---@param accountId number account row id
function store.setSession(app, citizenid, accountId)
    MySQL.update.await('DELETE FROM phone_app_sessions WHERE app = ? AND citizenid = ?', { app, citizenid })
    MySQL.insert.await(
        'INSERT INTO phone_app_sessions (app, citizenid, account_id) VALUES (?, ?, ?)',
        { app, citizenid, accountId }
    )
end

---Sign a citizen out of an app (idempotent: no rows is a no-op).
---@param app string account app key
---@param citizenid string framework per-character id
function store.clearSession(app, citizenid)
    MySQL.update.await('DELETE FROM phone_app_sessions WHERE app = ? AND citizenid = ?', { app, citizenid })
end

---Every citizen currently signed into an account in `app` - for apps that need to push live
---updates at "whoever is logged into this account" (e.g. Cherry delivering a chat message to the
---match's owner). Read-only.
---@param app string account app key
---@param accountId number account row id
---@return string[] citizenids
function store.sessionCitizens(app, accountId)
    local rows = MySQL.query.await(
        'SELECT citizenid FROM phone_app_sessions WHERE app = ? AND account_id = ?',
        { app, accountId }
    ) or {}
    local out = {}
    for i = 1, #rows do out[i] = rows[i].citizenid end
    return out
end

---First (only, for single-session apps) account this citizen is signed into. Read-only.
---@param app string account app key
---@param citizenid string framework per-character id
---@return table|nil account
function store.getSessionAccount(app, citizenid)
    local row = MySQL.single.await([[
        SELECT a.* FROM phone_app_sessions s
        JOIN phone_app_accounts a ON a.id = s.account_id
        WHERE s.app = ? AND s.citizenid = ?
        LIMIT 1
    ]], { app, citizenid })
    return rowToAccount(row)
end

---Upsert one vault entry for a character - the UNIQUE (citizenid, app, username) key makes a
---re-save of the same login update in place rather than duplicate.
---@param citizenid string framework per-character id (the vault's owner)
---@param app string account app key
---@param username string saved login username
---@param password string saved login password (plaintext by design - see ensureSchema)
---@param email string|nil saved linked email
---@param phone string|nil saved linked phone (digits)
function store.saveVaultEntry(citizenid, app, username, password, email, phone)
    MySQL.query.await([[
        INSERT INTO phone_passwords (citizenid, app, username, password, email, phone)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE password = VALUES(password), email = VALUES(email), phone = VALUES(phone)
    ]], { citizenid, app, username, password, email, phone })
end

---All of one character's vault entries, ordered app then username, with the creation date
---pre-formatted for the UI. Scoped to `citizenid` - the only way vault plaintext should ever be
---read. Read-only.
---@param citizenid string framework per-character id
---@return table[] entries
function store.listVaultEntries(citizenid)
    return MySQL.query.await([[
        SELECT id, app, username, password, email, phone, DATE_FORMAT(created_at, '%d/%m/%Y') AS created
        FROM phone_passwords WHERE citizenid = ? ORDER BY app, username
    ]], { citizenid }) or {}
end

---Delete one vault entry. Owner-scoped (`citizenid AND id`), so a guessed or leaked row id can
---only ever remove the caller's own entry.
---@param citizenid string framework per-character id
---@param id number vault row id
function store.deleteVaultEntry(citizenid, id)
    MySQL.update.await('DELETE FROM phone_passwords WHERE citizenid = ? AND id = ?', { citizenid, id })
end

---Keep saved vault copies in sync when an account's password changes - every character who saved
---this login sees the new password, matching what the account now accepts.
---@param app string account app key
---@param username string account username
---@param password string the new plaintext password
function store.syncVaultPassword(app, username, password)
    MySQL.update.await(
        'UPDATE phone_passwords SET password = ? WHERE app = ? AND username = ?',
        { password, app, username }
    )
end

---One-time credential migration from the Birdy and Mail tables. Birdy handles/passwords live on
---phone_birdy_profiles - copied once, with currently-logged-in profiles becoming engine sessions.
---Mail accounts copy from phone_mail_accounts with the email as both username and linked email;
---mail sessions stay in mail's own logged_in_citizens json (multi-account per citizen). INSERT
---IGNORE makes re-runs no-ops; missing source tables are caught by the pcall in init.lua.
function store.migrateLegacy()
    MySQL.query.await([[
        INSERT IGNORE INTO phone_app_accounts (app, username, display_name, password_hash)
        SELECT 'birdy', p.handle, p.display_name, p.password
        FROM phone_birdy_profiles p
        WHERE p.handle <> '' AND p.password <> ''
    ]])
    MySQL.query.await([[
        INSERT IGNORE INTO phone_app_sessions (app, citizenid, account_id)
        SELECT 'birdy', p.citizenid, a.id
        FROM phone_birdy_profiles p
        JOIN phone_app_accounts a ON a.app = 'birdy' AND a.username = p.handle
        WHERE p.logged_in = 1
    ]])
    MySQL.query.await([[
        INSERT IGNORE INTO phone_app_accounts (app, username, display_name, password_hash, email)
        SELECT 'mail', m.email, m.display_name, m.password_hash, m.email
        FROM phone_mail_accounts m
    ]])
end

return store
