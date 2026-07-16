---@type table sd-phone config root (configs/config.lua).
local config      = require 'configs.config'
---@type table Accounts persistence layer (server.accounts.store): account/session/vault CRUD + hashing.
local store       = require 'server.accounts.store'
---@type table Reset-code delivery (server.accounts.delivery): targeted in-game mail/SMS sends.
local delivery    = require 'server.accounts.delivery'
---@type table Mail persistence layer (server.mail.store): account lookups + legacy credential sync.
local mailStore   = require 'server.mail.store'
---@type table Birdy persistence layer (server.birdy.store): legacy password hasher for migrated rows.
local birdyStore  = require 'server.birdy.store'
---@type table Settings persistence layer (server.settings.store): citizenid -> phone-number lookups.
local settings    = require 'server.settings.store'
---@type table Player bridge (bridge.server.player): citizenid resolution from a server id.
local player      = require 'bridge.server.player'

---@type string Mail app domain (config.Mail.Domain), appended to bare mail usernames.
local MAIL_DOMAIN = config.Mail.Domain

---@type table Actions module; the table returned at end of file.
local actions     = {}

local util = require 'server.util'
local ok, fail, digits, trim = util.ok, util.fail, util.digits, util.trim


-- App whitelists. Every handler resolves its payload `app` against one of these BEFORE touching
-- the store, so a crafted payload can't reach an arbitrary app key. Birdy and Mail run their own
-- login/register modules and call into these actions from there, which is why only the reset,
-- password-change and vault callbacks serve them directly.
---@type table<string, boolean> Apps served by the generic register/login/logout/me callbacks.
local DIRECT_APPS    = { photogram = true, cherry = true, vibez = true, ryde = true }
---@type table<string, boolean> Every account app the engine knows (reset + vault callbacks).
local ALL_APPS       = { photogram = true, cherry = true, vibez = true, birdy = true, mail = true, ryde = true }

---@type table<string, fun(password: string): string> Legacy per-app hashers, so hashes migrated
---from the Birdy/Mail tables keep verifying; verifyPassword upgrades a legacy match to the
---engine's own hash on first login.
local LEGACY_HASHERS = {
    birdy = birdyStore.hashPassword,
    mail  = mailStore.hashPassword,
}



---@type integer Longest password any creation path accepts: the engine's hardcoded 64
---(validPassword) or the Birdy/Mail config caps if an owner raised them - same derivation as
---mail's MAX_SIGNIN_PASSWORD_LEN, so nothing storable is ever rejected here.
local MAX_PASSWORD_LEN = math.max(64, config.Birdy.MaxPasswordLength or 0, config.Mail.MaxPasswordLength or 0)

---Check a plaintext password against an account's stored hash. Non-strings, empty strings and
---anything longer than MAX_PASSWORD_LEN are rejected before hashing - the digest walks the string
---byte-by-byte in Lua, so without the length bound a crafted megabyte password is free server CPU
---burn on every login/changePassword call (checked here, the shared choke-point, so birdy's
---sign-in can't skip it either). Accounts migrated from the Birdy/Mail tables still carry those
---modules' pepper, so on an engine-hash miss the app's legacy hasher gets one try - and a legacy
---match silently re-hashes with the engine pepper, so every account converges on one hash format
---over time.
---@param account table account row (store shape, passwordHash included)
---@param plain any client-supplied plaintext password
---@return boolean verified
function actions.verifyPassword(account, plain)
    if type(plain) ~= 'string' or plain == '' or #plain > MAX_PASSWORD_LEN then return false end
    if store.hashPassword(plain) == account.passwordHash then return true end
    local legacy = LEGACY_HASHERS[account.app]
    if legacy and legacy(plain) == account.passwordHash then
        store.setPassword(account.id, store.hashPassword(plain))
        return true
    end
    return false
end

---Validate + normalise a username. Mail accounts use the email address as the username, so they
---get the looser format check (and the full 64-char column width); every other app is plain
---handles capped at 30 with a strict character whitelist. Both caps sit inside the VARCHAR(64)
---column, so nothing validated here can fail the insert on length.
---@param app string account app key
---@param raw any client-supplied username
---@return string|nil username, string|nil err
local function validUsername(app, raw)
    local u = trim(raw):lower()
    if app == 'mail' then
        if #u < 5 or #u > 64 or u:find('%s') or not u:find('@', 1, true) then
            return nil, 'That email address looks invalid'
        end
        return u, nil
    end
    if #u < 3 then return nil, 'Username needs at least 3 characters' end
    if #u > 30 then return nil, 'Username must be 30 characters or fewer' end
    if not u:match('^[%w_%.]+$') then return nil, 'Letters, numbers, _ and . only' end
    return u, nil
end

---Validate a password: 6-64 characters, must be an actual string (a crafted non-string payload
---fails here rather than reaching the hasher).
---@param raw any client-supplied password
---@return string|nil password, string|nil err
local function validPassword(raw)
    if type(raw) ~= 'string' or #raw < 6 then return nil, 'Password must be at least 6 characters' end
    if #raw > 64 then return nil, 'Password must be 64 characters or fewer' end
    return raw, nil
end

---Validate an optional recovery email: nil when blank, otherwise it must resolve to a REAL
---Mail-app account (a bare username gets the mail domain appended, matching how mail registers).
---Requiring an existing mailbox is what makes email recovery meaningful - a reset code can only
---ever be delivered somewhere the player can actually read.
---@param raw any client-supplied email
---@return string|nil email, string|nil err
local function validEmail(raw)
    local e = trim(raw):lower()
    if e == '' then return nil, nil end
    if not e:find('@', 1, true) then e = e .. '@' .. MAIL_DOMAIN end
    if not mailStore.getAccount(e) then
        return nil, 'No Mail account with that address exists'
    end
    return e, nil
end

---Validate an optional recovery phone: nil when blank, otherwise 7-15 digits (inside the
---VARCHAR(20) column).
---@param raw any client-supplied phone number
---@return string|nil phone, string|nil err
local function validPhone(raw)
    local p = digits(raw)
    if p == '' then return nil, nil end
    if #p < 7 or #p > 15 then return nil, 'That phone number looks invalid' end
    return p, nil
end

---Shared registration core for the generic callbacks and the Birdy/Mail modules. `app` must
---already be whitelisted by the caller; everything else is validated here: username/password
---format and length, optional recovery contacts, and a display name defaulting to the username
---(capped to the 50-char column). At least one recovery contact is required so the reset flow can
---always reach the owner, and each email/number may back only one account per app - like real
---services - which also keeps recovery resolution unambiguous. Uniqueness is pre-checked for the
---friendly message; the store's UNIQUE (app, username) key still backstops a race, surfacing as
---the generic insert failure rather than a duplicate row.
---@param app string account app key (already validated)
---@param payload table|nil client-supplied { username, password, name?, email?, phone? }
---@return table envelope on success data = { account }
function actions.createAccount(app, payload)
    payload = payload or {}
    local username, ue = validUsername(app, payload.username); if not username then return fail(ue) end
    local password, pe = validPassword(payload.password); if not password then return fail(pe) end
    local email, ee = validEmail(payload.email); if ee then return fail(ee) end
    local phone, he = validPhone(payload.phone); if he then return fail(he) end
    if not email and not phone then
        return fail('Add an email or phone number so you can recover the account')
    end
    local displayName = trim(payload.name)
    if displayName == '' then displayName = username end
    if #displayName > 50 then return fail('Name must be 50 characters or fewer') end

    if store.getAccount(app, username) then return fail('That username is taken') end

    if email and #store.findAccountsByContact(app, email, nil) > 0 then
        return fail('That email is already in use')
    end
    if phone and #store.findAccountsByContact(app, nil, phone) > 0 then
        return fail('That phone number is already in use')
    end

    local id = store.insertAccount(app, username, displayName, store.hashPassword(password), email, phone)
    if not id then return fail('Failed to create the account') end
    return ok({ account = store.getAccountById(id) })
end

---The account shape handed back to a client: identity + recovery contacts, never the password
---hash. Only ever returned to the caller who just authenticated or holds the session.
---@param a table account row
---@return table public fields { username, name, email, phone }
local function publicAccount(a)
    return { username = a.username, name = a.displayName, email = a.email, phone = a.phone }
end

---Register a new account for one of the direct apps and sign the caller straight into it. The
---actor is `source` alone - the session is keyed to the citizenid the player bridge resolves, so
---no payload field can create or claim a session for someone else.
---@param source number player server id
---@param payload table|nil client-supplied registration fields (see createAccount)
---@return table envelope on success data = { me }
function actions.register(source, payload)
    payload = payload or {}
    local app = payload.app
    if not DIRECT_APPS[app] then return fail('Unknown app') end
    local cid = player.getIdentifier(source); if not cid then return fail('Player not found') end

    local res = actions.createAccount(app, payload)
    if not res.success then return res end
    store.setSession(app, cid, res.data.account.id)
    return ok({ me = publicAccount(res.data.account) })
end

---Sign the caller into an existing account. The identity is tried as a username first, then as
---the linked recovery email (a bare mail username counts as its full address), so either logs in.
---Failure is a uniform 'Wrong username or password' whether the account exists or not, so this
---path can't be used to enumerate usernames. The session is keyed to the caller's own citizenid
---from `source`, never anything in the payload.
---@param source number player server id
---@param payload table|nil client-supplied { app, username, password }
---@return table envelope on success data = { me }
function actions.login(source, payload)
    payload = payload or {}
    local app = payload.app
    if not DIRECT_APPS[app] then return fail('Unknown app') end
    local cid = player.getIdentifier(source); if not cid then return fail('Player not found') end

    local raw = trim(payload.username):lower()
    if raw == '' then return fail('Wrong username or password') end

    local acc = store.getAccount(app, raw)
    if not acc then
        local e = raw
        if not e:find('@', 1, true) then e = e .. '@' .. MAIL_DOMAIN end
        local matches = store.findAccountsByContact(app, e, nil)
        if #matches == 1 then acc = matches[1] end
    end
    if not acc or not actions.verifyPassword(acc, payload.password) then
        return fail('Wrong username or password')
    end
    store.setSession(app, cid, acc.id)
    return ok({ me = publicAccount(acc) })
end

---Sign the caller out of an app. Only ever clears the caller's OWN session (citizenid from
---`source`); idempotent, so a replayed logout is a no-op.
---@param source number player server id
---@param payload table|nil client-supplied { app }
---@return table envelope
function actions.logout(source, payload)
    local app = payload and payload.app
    if not DIRECT_APPS[app] then return fail('Unknown app') end
    local cid = player.getIdentifier(source)
    if cid then store.clearSession(app, cid) end
    return ok()
end

---Who am I signed in as? Resolves the caller's session by their own citizenid and returns the
---public account shape - loggedIn = false covers both "no session" and "no identity". Read-only.
---@param source number player server id
---@param payload table|nil client-supplied { app }
---@return table envelope data = { loggedIn, me? }
function actions.me(source, payload)
    local app = payload and payload.app
    if not DIRECT_APPS[app] then return fail('Unknown app') end
    local cid = player.getIdentifier(source)
    if not cid then return ok({ loggedIn = false }) end
    local acc = store.getSessionAccount(app, cid)
    if not acc then return ok({ loggedIn = false }) end
    return ok({ loggedIn = true, me = publicAccount(acc) })
end

-- Password-reset codes. All state is in-memory and keyed app:accountId, so a restart voids every
-- outstanding code (fail-safe) and nothing secret ever touches disk or logs. A code is 6 digits,
-- single-use, expires after CODE_TTL, tolerates MAX_ATTEMPTS wrong guesses, and issuing is
-- rate-limited to MAX_REQUESTS per account per REQUEST_WINDOW - together that keeps brute-forcing
-- a live code to negligible odds (at most 15 guesses against a fresh 1-in-a-million code per
-- window). The code itself only ever travels inside the targeted mail/SMS delivery, plus the
-- suggestCode autofill below, which re-proves receipt before handing it back.
---@type table<string, { code: string, expires: integer, attempts: integer, channel: string }> Live codes by app:accountId.
local resetCodes     = {}
---@type table<string, { count: integer, windowStart: integer }> Issue-rate windows by app:accountId.
local resetRequests  = {}

---@type integer Reset-code lifetime in seconds (the delivery texts say "10 minutes" - keep in step).
local CODE_TTL       = 600
---@type integer Wrong guesses allowed per code before it is voided.
local MAX_ATTEMPTS   = 5
---@type integer Codes issuable per account within one request window.
local MAX_REQUESTS   = 3
---@type integer Issue-rate window length in seconds.
local REQUEST_WINDOW = 600

---Reset-state key. Keyed by the resolved account id rather than the raw identity string, so the
---same account reached via email and via phone shares one code and one rate limit.
---@param app string account app key
---@param accountId number account row id
---@return string key
local function resetKey(app, accountId) return app .. ':' .. accountId end

---Resolve a recovery identity (the email or phone number on file) to the single matching account.
---The identity's shape also decides the delivery channel: anything with letters or an '@' is an
---email (a bare mail username counts as its full address; mail itself must recover by phone,
---since its email IS the account being recovered), all-digits is a phone number. Ambiguity or no
---match returns an error instead of guessing.
---@param app string account app key
---@param raw string trimmed client-supplied identity
---@return table|nil acc, string|nil channel ('email'|'sms'), string|nil err
local function resolveRecovery(app, raw)
    if raw == '' then return nil, nil, 'Enter the email or phone number on the account' end

    local email, phone, channel
    if raw:find('@', 1, true) or raw:match('%a') then
        if app == 'mail' then
            return nil, nil, 'Use the phone number linked to the account'
        end
        local e = raw:lower()
        if not e:find('@', 1, true) then e = e .. '@' .. MAIL_DOMAIN end
        email, channel = e, 'email'
    else
        local p = digits(raw)
        if #p < 7 or #p > 15 then return nil, nil, 'Enter the email or phone number on the account' end
        phone, channel = p, 'sms'
    end

    local matches = store.findAccountsByContact(app, email, phone)
    if #matches == 0 then return nil, nil, 'No account uses that contact' end
    if #matches > 1 then return nil, nil, 'More than one account uses that contact. Ask an admin for help' end
    return matches[1], channel, nil
end

---Issue a password-reset code. Unauthenticated by design - the caller has lost the password, and
---possession of the linked mailbox or phone number is the real credential, so the code is only
---ever delivered THERE; the response carries just the channel name, never the code. Issuing is
---rate-limited per account so an attacker can't flood a victim with texts or churn codes. A fresh
---code replaces any previous one (new random value, attempt counter reset - harmless, since each
---code is an independent draw), while a failed delivery leaves prior state untouched and consumes
---no request slot.
---@param source number player server id
---@param payload { app: string, identity: string }|nil
---@return table envelope data = { channel }
function actions.requestReset(source, payload)
    payload = payload or {}
    local app = payload.app
    if not ALL_APPS[app] then return fail('Unknown app') end

    local acc, channel, err = resolveRecovery(app, trim(payload.identity))
    if not acc then return fail(err) end

    local key = resetKey(app, acc.id)
    local now = os.time()
    local req = resetRequests[key]
    if req and now - req.windowStart < REQUEST_WINDOW and req.count >= MAX_REQUESTS then
        return fail('Too many codes requested. Try again in a few minutes')
    end
    if not req or now - req.windowStart >= REQUEST_WINDOW then
        resetRequests[key] = { count = 0, windowStart = now }
        req = resetRequests[key]
    end

    local code = ('%06d'):format(math.random(0, 999999))
    local sent
    if channel == 'email' then
        sent = delivery.sendCodeEmail(acc.email, app, code)
        if not sent then return fail('Could not deliver the email. The linked address may have been deleted') end
    else
        sent = delivery.sendCodeSms(acc.phone, app, code)
        if not sent then return fail('Could not deliver the text. The linked number is not active') end
    end

    req.count = req.count + 1
    resetCodes[key] = { code = code, expires = now + CODE_TTL, attempts = 0, channel = channel }
    return ok({ channel = channel })
end

---iOS-style code autofill: hand the live code back, but ONLY when the caller's own phone provably
---received it - their registered number (resolved from `source` via settings, never the payload)
---is the number the text went to, or they are signed into the very mail account it was emailed
---to. That makes this a convenience for the legitimate recipient, not an oracle: every miss -
---unknown identity, expired code, wrong recipient - returns the same empty ok envelope.
---@param source number player server id
---@param payload { app: string, identity: string }|nil
---@return table envelope data = { code?, source? }
function actions.suggestCode(source, payload)
    payload = payload or {}
    local app = payload.app
    if not ALL_APPS[app] then return fail('Unknown app') end
    local cid = player.getIdentifier(source)
    if not cid then return ok({}) end

    local acc = (resolveRecovery(app, trim(payload.identity)))
    if not acc then return ok({}) end

    local entry = resetCodes[resetKey(app, acc.id)]
    if not entry or os.time() > entry.expires then return ok({}) end

    if entry.channel == 'sms' then
        local myNumber = digits(settings.getPhoneNumber(cid))
        if acc.phone and myNumber ~= '' and myNumber == acc.phone then
            return ok({ code = entry.code, source = 'messages' })
        end
    else
        local mailAcc = acc.email and mailStore.getAccount(acc.email)
        if mailAcc then
            for i = 1, #mailAcc.logged_in_citizens do
                if mailAcc.logged_in_citizens[i] == cid then
                    return ok({ code = entry.code, source = 'mail' })
                end
            end
        end
    end
    return ok({})
end

---Redeem a reset code and set a new password. Possession of the code IS the authority here.
---Expiry is checked first, then the attempt counter - incremented BEFORE the compare, so a
---spammed callback can't guess for free, and the code is voided outright past MAX_ATTEMPTS. On
---success the code is deleted: single-use, so a replayed confirm changes nothing. An identity
---that doesn't resolve is masked as "expired", so this path can't enumerate contacts either.
---Mail accounts also sync the new hash into mail's own credential column so nothing legacy
---diverges, and saved Passwords-app copies of this login follow the new password.
---@param source number player server id
---@param payload { app: string, identity: string, code: string, password: string }|nil
---@return table envelope
function actions.confirmReset(source, payload)
    payload = payload or {}
    local app = payload.app
    if not ALL_APPS[app] then return fail('Unknown app') end

    local acc = (resolveRecovery(app, trim(payload.identity)))
    if not acc then return fail('That code has expired. Request a new one') end

    local key = resetKey(app, acc.id)
    local entry = resetCodes[key]
    if not entry or os.time() > entry.expires then
        resetCodes[key] = nil
        return fail('That code has expired. Request a new one')
    end
    entry.attempts = entry.attempts + 1
    if entry.attempts > MAX_ATTEMPTS then
        resetCodes[key] = nil
        return fail('Too many wrong attempts. Request a new code')
    end
    if digits(payload.code) ~= entry.code then return fail('Wrong code') end

    local password, pe = validPassword(payload.password); if not password then return fail(pe) end

    store.setPassword(acc.id, store.hashPassword(password))
    if app == 'mail' then
        mailStore.setPasswordHash(acc.username, mailStore.hashPassword(password))
    end
    store.syncVaultPassword(app, acc.username, password)
    resetCodes[key] = nil
    return ok()
end

---Change an account's password using the CURRENT password (signed-in self-service, no reset
---code). Knowing the current password is the authority - the same bar every real service sets -
---and the failure message is uniform whether the account exists or not, so the path can't confirm
---usernames. Sync duties match confirmReset: mail's own credential column and saved
---Passwords-app copies follow the new password.
---@param source number player server id
---@param payload { app?: string, identity?: string, currentPassword?: string, newPassword?: string }
---@return table envelope
function actions.changePassword(source, payload)
    payload = payload or {}
    local app = payload.app
    if not ALL_APPS[app] then return fail('Unknown app') end
    local username = trim(payload.identity or '')
    if username == '' then return fail('Account is required') end
    local acc = store.getAccount(app, username)
    if not acc or not actions.verifyPassword(acc, payload.currentPassword) then
        return fail('Current password is incorrect')
    end
    local password, pe = validPassword(payload.newPassword); if not password then return fail(pe) end
    store.setPassword(acc.id, store.hashPassword(password))
    if app == 'mail' then
        mailStore.setPasswordHash(acc.username, mailStore.hashPassword(password))
    end
    store.syncVaultPassword(app, acc.username, password)
    return ok()
end

---Save one login into the caller's Passwords-app vault. Rows are keyed to the caller's own
---citizenid from `source`, so a payload can only ever write its own vault. The credentials are
---stored as given - the vault is deliberately a notebook, not an authenticator - with a bare
---email getting the mail domain appended to match how mail registers. Every field is capped to
---its phone_passwords column width, so an oversized crafted payload fails cleanly here instead of
---erroring the insert.
---@param source number player server id
---@param payload { app: string, username: string, password: string, email?: string, phone?: string }|nil
---@return table envelope
function actions.savePassword(source, payload)
    payload = payload or {}
    local app = payload.app
    if not ALL_APPS[app] then return fail('Unknown app') end
    local cid = player.getIdentifier(source); if not cid then return fail('Player not found') end

    local username = trim(payload.username):lower()
    local password = payload.password
    if username == '' or type(password) ~= 'string' or password == '' then
        return fail('Nothing to save')
    end
    if #username > 64 then return fail('Username must be 64 characters or fewer') end
    if #password > 64 then return fail('Password must be 64 characters or fewer') end
    local email = trim(payload.email):lower()
    if email ~= '' and not email:find('@', 1, true) then email = email .. '@' .. MAIL_DOMAIN end
    if #email > 120 then return fail('That email address looks invalid') end
    local phone = digits(payload.phone)
    if #phone > 20 then return fail('That phone number looks invalid') end

    store.saveVaultEntry(cid, app, username, password,
        email ~= '' and email or nil,
        phone ~= '' and phone or nil)
    return ok()
end

---The caller's own vault entries (empty for an unresolvable identity rather than an error, so
---the app renders an empty list). Read-only, scoped to the caller's citizenid.
---@param source number player server id
---@return table envelope data = { entries }
function actions.listPasswords(source)
    local cid = player.getIdentifier(source)
    if not cid then return ok({ entries = {} }) end
    return ok({ entries = store.listVaultEntries(cid) })
end

---Delete one vault entry. The store's DELETE is scoped citizenid AND id, so a guessed row id can
---only remove the caller's own entry. The id must be a finite integer - lib.callback payloads are
---msgpack, which CAN carry NaN/inf floats, and those must never reach the query.
---@param source number player server id
---@param payload { id?: number }|nil
---@return table envelope
function actions.deletePassword(source, payload)
    local cid = player.getIdentifier(source); if not cid then return fail('Player not found') end
    local id = tonumber(payload and payload.id)
    if not id or id ~= id or id == math.huge or id == -math.huge or id ~= math.floor(id) then
        return fail('Entry not found')
    end
    store.deleteVaultEntry(cid, id)
    return ok()
end

---The caller's own phone number, for pre-filling registration forms. Read-only.
---@param source number player server id
---@return table envelope data = { number }
function actions.myNumber(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    return ok({ number = settings.getPhoneNumber(cid) })
end

---The first mail account this character is signed into, for the email auto-fill chip on
---registration forms. nil when signed out of Mail. Read-only, and only ever the caller's own
---sign-ins.
---@param source number player server id
---@return table envelope data = { email? }
function actions.myEmail(source)
    local cid = player.getIdentifier(source)
    if not cid then return ok({}) end
    local accounts = mailStore.listAccountsForCitizen(cid)
    local first = accounts[1]
    return ok({ email = first and first.email or nil })
end

---Resolve an export-supplied (app, username) pair to a full account row. Serves the public
---exports in init.lua, whose callers are other server resources - a bad shape is a caller bug,
---so an app outside ALL_APPS or a blank/non-string username resolves to nil instead of erroring.
---The username gets the same trim+lower normalisation every authenticated path applies before
---it reaches the store.
---@param app any account app key (must be in ALL_APPS)
---@param username any account username
---@return table|nil account full store row, passwordHash included - strip before it leaves
local function exportAccount(app, username)
    if type(app) ~= 'string' or not ALL_APPS[app] then return nil end
    if type(username) ~= 'string' then return nil end
    local u = trim(username):lower()
    if u == '' then return nil end
    return store.getAccount(app, u)
end

---Does an account exist for `app`? Export-serving read: whitelist + normalisation via
---exportAccount, boolean out, so a caller can pre-check a handle without receiving any account
---data. Read-only.
---@param app string account app key
---@param username string account username
---@return boolean exists
function actions.accountExists(app, username)
    return exportAccount(app, username) ~= nil
end

---One account in its public shape - { username, name, email, phone }, never the password hash -
---or nil when the app is unknown or no such account exists. Read-only.
---@param app string account app key
---@param username string account username
---@return table|nil account public shape
function actions.getPublicAccount(app, username)
    local acc = exportAccount(app, username)
    return acc and publicAccount(acc) or nil
end

---The account a citizen is currently signed into for `app`, in the same public shape. nil
---covers every miss - unknown app, bad citizenid, simply signed out - so callers treat "no
---session" as data, not an error. Read-only.
---@param app string account app key
---@param citizenid string framework per-character id
---@return table|nil account public shape
function actions.getPublicSession(app, citizenid)
    if type(app) ~= 'string' or not ALL_APPS[app] then return nil end
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local acc = store.getSessionAccount(app, citizenid)
    return acc and publicAccount(acc) or nil
end

return actions
