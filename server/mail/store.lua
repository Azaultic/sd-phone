---@type table Store module; the table returned at end of file.
local store = {}


local util = require 'server.util'
local function newId() return util.newId(10) end

---@type fun(): string Public alias - composers outside this module (mail actions, the
---accounts-engine delivery mailer) mint their message ids through the store.
store.newId = newId

-- Server-side pepper mixed into every password hash. Combined with the multi-round bit-mixing
-- below this makes the stored hashes resistant to trivial inspection. Real-world hashing would
-- use bcrypt/scrypt but FiveM Lua ships no crypto primitives and an in-game phone is not a
-- credentials store worth importing one for.
---@type string
local PEPPER = 'sd-phone-v1::mail::do-not-leak-this-string'

---Hash a password into a stable 24-character hex string. Deterministic (same password -> same
---hash) so sign-in verifies by recomputing and comparing; the plaintext never persists. Also
---called by the accounts engine (server.accounts.actions) when a password reset syncs the new
---credential back into this legacy column.
---@param password string
---@return string 24-char hex digest
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

---Decode a JSON column defensively: nil, garbage, or a non-table decode all collapse to {}, so
---hydrated rows always carry real tables and callers never nil-check. The pass-through exists
---because oxmysql can hand JSON columns back pre-decoded; the pcall because json.decode can
---raise on junk input.
---@param value any
---@return table
local function decodeJson(value)
    if value == nil then return {} end
    if type(value) == 'table' then return value end
    if type(value) == 'string' then
        local ok, decoded = pcall(json.decode, value)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return {}
end

---Encode a table for a JSON column; nil becomes an empty array/object.
---@param tbl table|nil
---@return string
local function encodeJson(tbl) return json.encode(tbl or {}) end

---Hydrate a raw row from `phone_mail_accounts` into the canonical Lua shape with `messages`
---and `logged_in_citizens` pre-decoded.
---@param row table|nil
---@return table|nil
local function hydrateRow(row)
    if not row then return nil end
    return {
        email              = row.email,
        password_hash      = row.password_hash,
        display_name       = row.display_name,
        messages           = decodeJson(row.messages),
        logged_in_citizens = decodeJson(row.logged_in_citizens),
    }
end

---Create the single Mail table idempotently, so the resource is drop-in. Messages and the
---active player-session list both live in JSON columns on the account row - one app, one
---table, mirroring the Groups schema choice. Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_mail_accounts (
            email              VARCHAR(64)  NOT NULL,
            password_hash      VARCHAR(255) NOT NULL,
            display_name       VARCHAR(64)  NOT NULL,
            messages           JSON         NOT NULL,
            logged_in_citizens JSON         NOT NULL,
            created_at         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end

---Read a single mail account (nil if no row matches). The email column's utf8mb4_unicode_ci
---collation makes the match case-insensitive, which is why differently-cased client input
---still resolves to the one stored row. Read-only.
---@param email string
---@return table|nil
function store.getAccount(email)
    if not email or email == '' then return nil end
    local row = MySQL.single.await(
        'SELECT email, password_hash, display_name, messages, logged_in_citizens FROM phone_mail_accounts WHERE email = ?',
        { email }
    )
    return hydrateRow(row)
end

---Insert a brand-new account with empty messages + sessions. Returns false when the insert
---fails - in practice a primary-key collision on the email - which makes this the
---authoritative uniqueness check: a taken-email pre-check that races another sign-up still
---resolves safely here.
---@param email string
---@param passwordHash string
---@param displayName string
---@return boolean
function store.insertAccount(email, passwordHash, displayName)
    local ok = pcall(function()
        MySQL.insert.await([[
            INSERT INTO phone_mail_accounts (email, password_hash, display_name, messages, logged_in_citizens)
            VALUES (?, ?, ?, '[]', '[]')
        ]], { email, passwordHash, displayName })
    end)
    return ok
end

---Add a citizenid to an account's logged-in list. Idempotent: re-adding an already-logged-in
---citizen is a silent no-op, so a replayed sign-in can never duplicate a session entry.
---@param email string
---@param citizenid string
---@return boolean
function store.addSession(email, citizenid)
    local acc = store.getAccount(email); if not acc then return false end
    for i = 1, #acc.logged_in_citizens do
        if acc.logged_in_citizens[i] == citizenid then return true end
    end
    acc.logged_in_citizens[#acc.logged_in_citizens + 1] = citizenid
    local affected = MySQL.update.await(
        'UPDATE phone_mail_accounts SET logged_in_citizens = ? WHERE email = ?',
        { encodeJson(acc.logged_in_citizens), email }
    )
    return (affected or 0) > 0
end

---Remove a citizenid from an account's logged-in list. Filtering out a citizenid that was
---never in the list rewrites the row unchanged - a harmless no-op, which is what makes the
---sign-out action safe without its own ownership check.
---@param email string
---@param citizenid string
---@return boolean
function store.removeSession(email, citizenid)
    local acc = store.getAccount(email); if not acc then return false end
    local filtered = {}
    for i = 1, #acc.logged_in_citizens do
        if acc.logged_in_citizens[i] ~= citizenid then
            filtered[#filtered + 1] = acc.logged_in_citizens[i]
        end
    end
    local affected = MySQL.update.await(
        'UPDATE phone_mail_accounts SET logged_in_citizens = ? WHERE email = ?',
        { encodeJson(filtered), email }
    )
    return (affected or 0) > 0
end

---List every account the given citizenid is currently logged into. Uses `JSON_SEARCH` so the
---membership check pushes into MySQL rather than scanning every row in Lua. Safe here only
---because citizenid is always server-derived: JSON_SEARCH treats % and _ as wildcards, so this
---must never be fed a client-supplied string. Read-only.
---@param citizenid string
---@return table[] hydrated accounts
function store.listAccountsForCitizen(citizenid)
    local rows = MySQL.query.await([[
        SELECT email, password_hash, display_name, messages, logged_in_citizens
        FROM phone_mail_accounts
        WHERE JSON_SEARCH(logged_in_citizens, 'one', ?) IS NOT NULL
        ORDER BY created_at ASC
    ]], { citizenid }) or {}

    for i = 1, #rows do rows[i] = hydrateRow(rows[i]) end
    return rows
end

---Append a message to an account's messages array, pruning the oldest past `maxRetained` so a
---single mailbox's JSON can't grow without bound. Returns false if the account doesn't exist,
---which lets the caller skip delivery to unknown recipients without blowing up. Read-modify-
---write with no row lock: two simultaneous appends to the SAME account can lose one message -
---an accepted rarity for an in-game mailbox.
---@param email string
---@param message table
---@param maxRetained number cap on stored messages per account; oldest pruned first
---@return boolean
function store.appendMessage(email, message, maxRetained)
    local acc = store.getAccount(email); if not acc then return false end
    acc.messages[#acc.messages + 1] = message

    if maxRetained and #acc.messages > maxRetained then
        local trimmed = {}
        local offset = #acc.messages - maxRetained
        for i = offset + 1, #acc.messages do
            trimmed[#trimmed + 1] = acc.messages[i]
        end
        acc.messages = trimmed
    end

    local affected = MySQL.update.await(
        'UPDATE phone_mail_accounts SET messages = ? WHERE email = ?',
        { encodeJson(acc.messages), email }
    )
    return (affected or 0) > 0
end

---Mutate a single message inside the account's JSON by id, via a caller-supplied
---`apply(message) -> message|nil` function - apply returning nil deletes the message from the
---array. Returns false when no message matched, so callers can treat a bogus id as a no-op
---rather than an error; the whole array is rewritten in one UPDATE (same read-modify-write
---caveat as appendMessage).
---@param email string
---@param messageId string
---@param apply fun(msg: table): table|nil
---@return boolean updated true if a message was found + persisted
function store.mutateMessage(email, messageId, apply)
    local acc = store.getAccount(email); if not acc then return false end
    local rewritten = {}
    local hit = false
    for i = 1, #acc.messages do
        local m = acc.messages[i]
        if m.id == messageId then
            hit = true
            local replaced = apply(m)
            if replaced ~= nil then
                rewritten[#rewritten + 1] = replaced
            end
        else
            rewritten[#rewritten + 1] = m
        end
    end
    if not hit then return false end
    local affected = MySQL.update.await(
        'UPDATE phone_mail_accounts SET messages = ? WHERE email = ?',
        { encodeJson(rewritten), email }
    )
    return (affected or 0) > 0
end

---Overwrite an account's stored password hash. Called by the accounts engine
---(server.accounts.actions) when a password reset completes, keeping this legacy column in
---step with the engine's canonical hash so old sign-in paths keep working.
---@param email string
---@param passwordHash string
function store.setPasswordHash(email, passwordHash)
    MySQL.update.await('UPDATE phone_mail_accounts SET password_hash = ? WHERE email = ?', { passwordHash, email })
end

---Permanently delete an account and all its mail. Messages + sessions live in the account
---row's JSON columns, so dropping the row removes everything at once.
---@param email string
function store.deleteAccount(email)
    if not email or email == '' then return end
    MySQL.update.await('DELETE FROM phone_mail_accounts WHERE email = ?', { email })
end

---Total unread inbox messages across every Mail account the citizen is signed into - the
---home-screen Mail badge source (server.badges.init). Sent/binned messages don't count (only
---folder 'inbox'); a citizen logged into several mailboxes sees the sum. Read-only.
---@param citizenid string
---@return number
function store.unreadCount(citizenid)
    local accounts = store.listAccountsForCitizen(citizenid)
    local n = 0
    for i = 1, #accounts do
        local msgs = accounts[i].messages
        for j = 1, #msgs do
            local m = msgs[j]
            if m.folder == 'inbox' and m.read ~= true then n = n + 1 end
        end
    end
    return n
end

return store
