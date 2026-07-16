---@type table sd-phone config root (configs/config.lua): aggregated per-app config tables.
local config      = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid/name lookups from a live source,
---plus citizenid -> source resolution for the delivery fan-out.
local player      = require 'bridge.server.player'
---@type table Mail persistence layer (server.mail.store): account-row CRUD + in-row JSON message ops.
local store       = require 'server.mail.store'
---@type table Accounts-engine persistence (server.accounts.store): cross-app contact-uniqueness lookups.
local acctStore   = require 'server.accounts.store'
---@type table Accounts-engine actions (server.accounts.actions): credential mirror + password verify.
local acctActions = require 'server.accounts.actions'
---@type table Home-screen badge engine (server.badges.init): recomputes + pushes unread counts.
local badges      = require 'server.badges.init'

---@type table Mail app config (configs/mail.lua): domain, length limits, per-player caps.
local mailCfg = config.Mail

---@type table Actions module; the table returned at end of file.
local actions = {}

-- Server-side compose caps. The web composer imposes no hard limits of its own, so these bound
-- what a modified client can persist: every message copy lives inside an account row's JSON
-- column, so an unbounded subject/body/recipient list is a row-bloat + NUI DoS vector, and each
-- recipient costs a DB read at delivery - the count cap bounds that work too.
---@type integer Max recipients accepted per send/draft; larger lists are rejected outright.
local MAX_RECIPIENTS = 20
---@type integer Subject cap (chars); longer subjects are truncated (messages-app convention).
local MAX_SUBJECT_LEN = 200
---@type integer Body cap (chars); longer bodies are truncated (messages-app convention).
local MAX_BODY_LEN = 10000
---@type integer Sign-in password length bound: the larger of mailCfg.MaxPasswordLength and the
---accounts engine's hardcoded 64, so lowering the mail cap can't lock out engine-reset credentials.
local MAX_SIGNIN_PASSWORD_LEN = math.max(mailCfg.MaxPasswordLength, 64)

local util = require 'server.util'
local ok, fail, trim = util.ok, util.fail, util.trim


---Resolve a connected source to its citizenid + display name. The only identity path in this
---module: every handler derives the actor from src via the player bridge, never from a payload
---field, so a crafted payload can't act as another player.
---@param source number
---@return { cid: string, name: string }|nil
local function whois(source)
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    return { cid = cid, name = player.getName(source) }
end


---Permissive email-format check for RECIPIENT addresses: a `@` separator with non-empty local +
---host parts, no whitespace anywhere, and a host that either is the configured own domain or
---contains at least one `.` - validateEmail accepts a dotless mailCfg.Domain (e.g. 'weazel') at
---sign-up, so its addresses must pass here too or systemSend silently drops them. Foreign
---domains pass on purpose - a recipient that doesn't resolve to a registered account is silently
---skipped at delivery. Real validation is deferred to deliverability checks we don't have (no
---real SMTP).
---@param email string
---@return boolean
local function looksLikeEmail(email)
    if type(email) ~= 'string' then return false end
    if email:find('%s') then return false end
    local at = email:find('@', 1, true)
    if not at or at == 1 or at == #email then return false end
    local host = email:sub(at + 1)
    if host:lower() == mailCfg.Domain then return true end
    if not host:find('.', 1, true) then return false end
    return true
end

---Normalize a player-supplied OWN address (a bare username or a full email) into the canonical
---local@Domain form. Foreign domains are rejected, so every registered account lives under the
---one configured domain; the local part is whitelist-matched (alnum start, then alnum/._-) and
---the finished address is capped at mailCfg.MaxEmailLength, matching the VARCHAR(64) email
---column it becomes the primary key of.
---@param raw any
---@return string|nil normalized, string? message
local function validateEmail(raw)
    local trimmed = trim(raw):lower()
    local at = trimmed:find('@', 1, true)
    local localPart = at and trimmed:sub(1, at - 1) or trimmed
    if at and trimmed:sub(at + 1) ~= mailCfg.Domain then
        return nil, ('Email addresses are @%s only'):format(mailCfg.Domain)
    end
    if #localPart < 2 then
        return nil, 'Username must be at least 2 characters'
    end
    if not localPart:match('^[%w][%w%.%_%-]*$') then
        return nil, 'Letters, numbers, dots, dashes and _ only'
    end
    local email = localPart .. '@' .. mailCfg.Domain
    if #email > mailCfg.MaxEmailLength then
        return nil, ('Email must be %d characters or fewer'):format(mailCfg.MaxEmailLength)
    end
    return email, nil
end

---Validate password length only - content rules (must include a digit etc.) are deliberately
---omitted for in-game roleplay friendliness. Bounds come from configs/mail.lua; the type check
---matters because the raw value flows into the hash function on success.
---@param raw any
---@return string|nil normalized, string? message
local function validatePassword(raw)
    if type(raw) ~= 'string' then return nil, 'Password is required' end
    if #raw < mailCfg.MinPasswordLength then
        return nil, ('Password must be at least %d characters'):format(mailCfg.MinPasswordLength)
    end
    if #raw > mailCfg.MaxPasswordLength then
        return nil, ('Password must be %d characters or fewer'):format(mailCfg.MaxPasswordLength)
    end
    return raw, nil
end

---Validate display-name length against the configs/mail.lua bounds. Trimmed but not
---character-whitelisted - it's a mailbox label, not an address.
---@param raw any
---@return string|nil normalized, string? message
local function validateDisplayName(raw)
    local trimmed = trim(raw)
    if #trimmed < mailCfg.MinNameLength then
        return nil, ('Name must be at least %d character%s'):format(
            mailCfg.MinNameLength,
            mailCfg.MinNameLength == 1 and '' or 's'
        )
    end
    if #trimmed > mailCfg.MaxNameLength then
        return nil, ('Name must be %d characters or fewer'):format(mailCfg.MaxNameLength)
    end
    return trimmed, nil
end

---Reshape a hydrated store account into the React `MailAccount` shape. Deliberately narrow:
---password_hash and the logged_in_citizens session list never leave the server.
---@param acc { email: string, display_name: string }
---@return { id: string, name: string, email: string }
local function serializeAccount(acc)
    return { id = acc.email, name = acc.display_name, email = acc.email }
end

---Reshape a hydrated message (already-decoded JSON inside the account row) into the React
---`MailMessage` shape. The store keeps every message as `{ id, folder, from = {name, email},
---to = [], subject, body, sentAt, read, flagged }` - same shape - so this is mostly identity
---plus the `accountId` injection, with fallbacks for rows written by older builds.
---@param accountEmail string
---@param msg table
---@return table
local function serializeMessage(accountEmail, msg)
    return {
        id        = msg.id,
        accountId = accountEmail,
        folder    = msg.folder    or 'inbox',
        from      = msg.from      or { name = '', email = '' },
        to        = msg.to        or {},
        subject   = msg.subject   or '',
        body      = msg.body      or '',
        sentAt    = msg.sentAt    or '',
        read      = msg.read      == true,
        flagged   = msg.flagged   == true,
    }
end

---Public alias: init.lua's mailbox export reshapes stored messages through the same serializer,
---so every surface emits the identical MailMessage shape.
actions.serializeMessage = serializeMessage

---The one delivery fan-out. Every path that persists an inbox copy - the send callback, the
---mail exports and the accounts-engine mailer - ends here: each entry resolves its citizenid to
---a live source and, when online, gets the message as a live UI event plus a badge repush, so
---the Mail badge can never lag a push. Offline citizens are skipped; they see the message on
---their next mail-list fetch. Callers must strip the pushes list (and the citizenids inside it)
---from anything that leaves the server.
---@param pushes { citizenid: string, message: table }[]
function actions.deliver(pushes)
    if type(pushes) ~= 'table' then return end
    for i = 1, #pushes do
        local src = player.getSourceByIdentifier(pushes[i].citizenid)
        if src then
            TriggerClientEvent('sd-phone:client:mail:received', src, pushes[i].message)
            badges.push(src)
        end
    end
end

---Load the full Mail snapshot for the calling player - every account their citizenid is signed
---into and every message inside those accounts. Scope comes entirely from src (whois), so a
---client can only ever pull mailboxes it has authenticated into. Read-only.
---@param source number
---@return table
function actions.list(source)
    local me = whois(source); if not me then return fail('Player not found') end
    local accounts = store.listAccountsForCitizen(me.cid)

    local outAccounts = {}
    local outMessages = {}
    for i = 1, #accounts do
        local acc = accounts[i]
        outAccounts[i] = serializeAccount(acc)
        for j = 1, #acc.messages do
            outMessages[#outMessages + 1] = serializeMessage(acc.email, acc.messages[j])
        end
    end

    return ok({ accounts = outAccounts, messages = outMessages })
end

---Create a brand-new email account and sign the caller straight into it. Every field is
---validated server-side (address shape + domain, password/name lengths, and an optional
---recovery phone normalized to digits and length-checked). The phone-uniqueness and
---taken-email checks run BEFORE the insert so a rejected sign-up never leaves a half-created
---account behind; if two sign-ups race the same address anyway, the store's primary-key
---collision is the authoritative duplicate guard. The plaintext password is hashed before
---storage and also mirrored into the shared accounts engine, which is the source of truth for
---password resets - a duplicate from the one-time migration is harmless, so the mirror's
---result is intentionally ignored.
---@param source number
---@param payload { email?: string, password?: string, displayName?: string, phone?: string }
---@return table
function actions.signUp(source, payload)
    payload = payload or {}
    local me = whois(source); if not me then return fail('Player not found') end

    local email, ee = validateEmail(payload.email); if not email then return fail(ee) end
    local password, pe = validatePassword(payload.password); if not password then return fail(pe) end
    local displayName, ne = validateDisplayName(payload.displayName); if not displayName then return fail(ne) end

    local phone = (tostring(payload.phone or '')):gsub('%D', '')
    if phone ~= '' and (#phone < 7 or #phone > 15) then
        return fail('That phone number looks invalid')
    end
    if phone ~= '' and #acctStore.findAccountsByContact('mail', nil, phone) > 0 then
        return fail('That phone number is already in use')
    end

    if store.getAccount(email) then
        return fail('That email is already registered')
    end

    local sessions = store.listAccountsForCitizen(me.cid)
    if #sessions >= mailCfg.MaxAccountsPerPlayer then
        return fail(('You can have at most %d accounts signed in'):format(mailCfg.MaxAccountsPerPlayer))
    end

    if not store.insertAccount(email, store.hashPassword(password), displayName) then
        return fail('Failed to create account')
    end
    store.addSession(email, me.cid)

    acctActions.createAccount('mail', {
        username = email, password = password, name = displayName,
        email = email, phone = phone ~= '' and phone or nil,
    })

    local acc = store.getAccount(email)
    if not acc then return fail('Account vanished after creation') end
    return ok({ account = serializeAccount(acc) })
end

---Sign into an existing email account. Credentials-gated, not identity-gated: any player who
---knows the password may sign in - shared mailboxes are a feature (see configs/mail.lua). The
---failure message is identical whether the address exists or the password is wrong, so this
---callback can't be used to enumerate registered addresses; a password over
---MAX_SIGNIN_PASSWORD_LEN gets that same uniform failure BEFORE any hashing, because both
---creation paths (signUp here, the accounts engine's validPassword) enforce the bound - so the
---attempt can never be correct - and the hash functions walk the string per byte, which a
---crafted multi-megabyte password would turn into free server CPU burn. The accounts engine is
---verified first (it is canonical after password resets); the legacy hash column keeps
---pre-engine accounts working. Idempotent: signing into an account you're already in returns
---success without re-adding a session or counting against the per-player cap.
---@param source number
---@param payload { email?: string, password?: string }
---@return table
function actions.signIn(source, payload)
    payload = payload or {}
    local me = whois(source); if not me then return fail('Player not found') end

    local email, ee = validateEmail(payload.email); if not email then return fail(ee) end
    if type(payload.password) ~= 'string' or payload.password == '' then
        return fail('Password is required')
    end
    if #payload.password > MAX_SIGNIN_PASSWORD_LEN then
        return fail('Email or password is incorrect')
    end

    local acc = store.getAccount(email)
    local valid = false
    if acc then
        local engineAcc = acctStore.getAccount('mail', email)
        if engineAcc then valid = acctActions.verifyPassword(engineAcc, payload.password) end
        if not valid then valid = acc.password_hash == store.hashPassword(payload.password) end
    end
    if not valid then
        return fail('Email or password is incorrect')
    end

    local sessions = store.listAccountsForCitizen(me.cid)
    for i = 1, #sessions do
        if sessions[i].email == email then
            return ok({ account = serializeAccount(acc) })
        end
    end
    if #sessions >= mailCfg.MaxAccountsPerPlayer then
        return fail(('You can have at most %d accounts signed in'):format(mailCfg.MaxAccountsPerPlayer))
    end

    store.addSession(email, me.cid)
    return ok({ account = serializeAccount(acc) })
end

---Sign out of an account on this player's phone. The account itself survives - only the
---caller's session is dropped. No ownership gate is needed: the store only ever removes the
---CALLER's citizenid (from src), so pointing this at a mailbox you never joined is a harmless
---no-op and it can never drop anyone else's session.
---@param source number
---@param payload { email?: string }
---@return table
function actions.signOut(source, payload)
    payload = payload or {}
    local me = whois(source); if not me then return fail('Player not found') end

    local email = trim(payload.email):lower()
    if email == '' then return fail('Email is required') end

    store.removeSession(email, me.cid)
    return ok({ email = email })
end

---Send a new message. The payload only NAMES the sending mailbox; the right to use it is proven
---by the caller's citizenid (from src) appearing in that account's signed-in list, and the From
---header is rebuilt from the account row - a crafted payload can't spoof another sender's name
---or address. Recipients are trimmed, lowercased, deduped, capped at MAX_RECIPIENTS and
---length-limited to mailCfg.MaxEmailLength (a longer address can't exist as an account, so
---nothing deliverable is lost); subject/body are truncated to their caps. Persists a `sent`
---copy on the sender and an `inbox` copy on every recipient that exists - unknown addresses are
---silently skipped, so the response can't be used to probe which addresses are registered.
---Returns the citizenids currently signed into each recipient account so the caller can run the
---shared fan-out (actions.deliver); init.lua strips that list from the envelope before it
---reaches the sender's client.
---@param source number
---@param payload { fromEmail?: string, to?: string[], subject?: string, body?: string }
---@return table
function actions.send(source, payload)
    payload = payload or {}
    local me = whois(source); if not me then return fail('Player not found') end

    local fromEmail = trim(payload.fromEmail):lower()
    if fromEmail == '' then return fail('Sender account is required') end

    local sender = store.getAccount(fromEmail)
    if not sender then return fail('Sender account not found') end

    local owns = false
    for i = 1, #sender.logged_in_citizens do
        if sender.logged_in_citizens[i] == me.cid then owns = true; break end
    end
    if not owns then return fail('You are not signed into that account') end

    local toRaw = payload.to or {}
    if type(toRaw) ~= 'table' or #toRaw == 0 then return fail('At least one recipient is required') end
    if #toRaw > MAX_RECIPIENTS then return fail('Too many recipients') end

    local recipients = {}
    local seen = {}
    for i = 1, #toRaw do
        local addr = trim(toRaw[i]):lower()
        if addr ~= '' and #addr <= mailCfg.MaxEmailLength and not seen[addr] and looksLikeEmail(addr) then
            recipients[#recipients + 1] = addr
            seen[addr] = true
        end
    end
    if #recipients == 0 then return fail('No valid recipient addresses') end

    local subject = trim(payload.subject)
    if #subject > MAX_SUBJECT_LEN then subject = subject:sub(1, MAX_SUBJECT_LEN) end
    local body    = type(payload.body) == 'string' and payload.body or ''
    if #body > MAX_BODY_LEN then body = body:sub(1, MAX_BODY_LEN) end
    local sentAt  = os.date('!%Y-%m-%dT%H:%M:%S')

    local sentMessage = {
        id      = store.newId(),
        folder  = 'sent',
        from    = { name = sender.display_name, email = sender.email },
        to      = recipients,
        subject = subject,
        body    = body,
        sentAt  = sentAt,
        read    = true,
        flagged = false,
    }
    store.appendMessage(sender.email, sentMessage, mailCfg.MaxMessagesPerAccount)

    local pushes = {}
    for i = 1, #recipients do
        local addr = recipients[i]
        local recipient = store.getAccount(addr)
        if recipient then
            local inboxMessage = {
                id      = store.newId(),
                folder  = 'inbox',
                from    = { name = sender.display_name, email = sender.email },
                to      = recipients,
                subject = subject,
                body    = body,
                sentAt  = sentAt,
                read    = false,
                flagged = false,
            }
            store.appendMessage(addr, inboxMessage, mailCfg.MaxMessagesPerAccount)

            for j = 1, #recipient.logged_in_citizens do
                pushes[#pushes + 1] = {
                    citizenid = recipient.logged_in_citizens[j],
                    message   = serializeMessage(addr, inboxMessage),
                }
            end
        end
    end

    ---First-party server-local event: fired once per compose after the sent copy and every recipient inbox copy are stored; payload carries the sender citizenid for server-trusted consumers but never the pushes list or its citizenids.
    TriggerEvent('sd-phone:server:mail:sent', {
        system    = false,
        id        = sentMessage.id,
        citizenid = me.cid,
        from      = { name = sender.display_name, email = sender.email },
        to        = recipients,
        subject   = subject,
        body      = body,
        sentAt    = sentAt,
    })

    return ok({
        sent   = serializeMessage(sender.email, sentMessage),
        pushes = pushes,
    })
end

---Compose and deliver mail as the SYSTEM rather than a player: no sender account, no ownership
---proof and no sent copy - callers are other server modules (the accounts-engine mailer, the
---sendMail export), trusted to speak for the system, so validation here exists to fail cleanly
---on caller bugs. Recipients walk the same normalization as send (trim/lowercase, dedupe,
---looksLikeEmail, MAX_RECIPIENTS cap) and subject/body the same truncation caps; the From header
---defaults to System <no-reply@Domain> and is length-capped, never resolved to an account.
---Persists an `inbox` copy on every recipient that exists - unknown addresses are silently
---skipped - then runs the shared fan-out itself, so the returned envelope never carries pushes
---or citizenids, only the count of recipient accounts that existed.
---@param mail { to: string|string[], subject?: string, body?: string, from?: { name?: string, email?: string } }
---@return table envelope; data.delivered counts recipient accounts that existed
function actions.systemSend(mail)
    if type(mail) ~= 'table' then return fail('Mail payload must be a table') end

    local toRaw = type(mail.to) == 'string' and { mail.to } or mail.to
    if type(toRaw) ~= 'table' or #toRaw == 0 then return fail('At least one recipient is required') end
    if #toRaw > MAX_RECIPIENTS then return fail('Too many recipients') end

    local recipients = {}
    local seen = {}
    for i = 1, #toRaw do
        local addr = trim(toRaw[i]):lower()
        if addr ~= '' and #addr <= mailCfg.MaxEmailLength and not seen[addr] and looksLikeEmail(addr) then
            recipients[#recipients + 1] = addr
            seen[addr] = true
        end
    end
    if #recipients == 0 then return fail('No valid recipient addresses') end

    local from = type(mail.from) == 'table' and mail.from or {}
    local fromName = trim(from.name)
    if fromName == '' then fromName = 'System' end
    if #fromName > mailCfg.MaxNameLength then fromName = fromName:sub(1, mailCfg.MaxNameLength) end
    local fromEmail = trim(from.email):lower()
    if fromEmail == '' then fromEmail = 'no-reply@' .. mailCfg.Domain end
    if #fromEmail > mailCfg.MaxEmailLength then fromEmail = fromEmail:sub(1, mailCfg.MaxEmailLength) end

    local subject = trim(mail.subject)
    if #subject > MAX_SUBJECT_LEN then subject = subject:sub(1, MAX_SUBJECT_LEN) end
    local body = type(mail.body) == 'string' and mail.body or ''
    if #body > MAX_BODY_LEN then body = body:sub(1, MAX_BODY_LEN) end
    local sentAt = os.date('!%Y-%m-%dT%H:%M:%S')

    local delivered = 0
    local sentId
    local pushes = {}
    for i = 1, #recipients do
        local addr = recipients[i]
        local recipient = store.getAccount(addr)
        if recipient then
            local inboxMessage = {
                id      = store.newId(),
                folder  = 'inbox',
                from    = { name = fromName, email = fromEmail },
                to      = recipients,
                subject = subject,
                body    = body,
                sentAt  = sentAt,
                read    = false,
                flagged = false,
            }
            store.appendMessage(addr, inboxMessage, mailCfg.MaxMessagesPerAccount)
            delivered = delivered + 1
            sentId = sentId or inboxMessage.id

            for j = 1, #recipient.logged_in_citizens do
                pushes[#pushes + 1] = {
                    citizenid = recipient.logged_in_citizens[j],
                    message   = serializeMessage(addr, inboxMessage),
                }
            end
        end
    end

    ---Same contract as the send-path emission, system-flagged: fired once before the fan-out, id is the first stored copy's (absent when delivered is 0), never the pushes list or its citizenids.
    TriggerEvent('sd-phone:server:mail:sent', {
        system    = true,
        id        = sentId,
        from      = { name = fromName, email = fromEmail },
        to        = recipients,
        subject   = subject,
        body      = body,
        sentAt    = sentAt,
        delivered = delivered,
    })

    actions.deliver(pushes)
    return ok({ delivered = delivered })
end

---Save the caller's compose as a draft on the sender account. Same ownership proof and compose
---caps as `send`, but persists a single `drafts` copy and delivers to nobody - recipients are
---optional here and kept only if they parse as addresses.
---@param source number
---@param payload { fromEmail?: string, to?: string[], subject?: string, body?: string }
---@return table
function actions.saveDraft(source, payload)
    payload = payload or {}
    local me = whois(source); if not me then return fail('Player not found') end

    local fromEmail = trim(payload.fromEmail):lower()
    if fromEmail == '' then return fail('Sender account is required') end

    local sender = store.getAccount(fromEmail)
    if not sender then return fail('Sender account not found') end

    local owns = false
    for i = 1, #sender.logged_in_citizens do
        if sender.logged_in_citizens[i] == me.cid then owns = true; break end
    end
    if not owns then return fail('You are not signed into that account') end

    local recipients = {}
    local seen = {}
    local toRaw = payload.to
    if type(toRaw) == 'table' then
        if #toRaw > MAX_RECIPIENTS then return fail('Too many recipients') end
        for i = 1, #toRaw do
            local addr = trim(toRaw[i]):lower()
            if addr ~= '' and #addr <= mailCfg.MaxEmailLength and not seen[addr] and looksLikeEmail(addr) then
                recipients[#recipients + 1] = addr
                seen[addr] = true
            end
        end
    end

    local subject = trim(payload.subject)
    if #subject > MAX_SUBJECT_LEN then subject = subject:sub(1, MAX_SUBJECT_LEN) end
    local body = type(payload.body) == 'string' and payload.body or ''
    if #body > MAX_BODY_LEN then body = body:sub(1, MAX_BODY_LEN) end

    local draft = {
        id      = store.newId(),
        folder  = 'drafts',
        from    = { name = sender.display_name, email = sender.email },
        to      = recipients,
        subject = subject,
        body    = body,
        sentAt  = os.date('!%Y-%m-%dT%H:%M:%S'),
        read    = true,
        flagged = false,
    }
    store.appendMessage(sender.email, draft, mailCfg.MaxMessagesPerAccount)

    return ok({ draft = serializeMessage(sender.email, draft) })
end

---Ownership gate for the per-message mutators: the caller's citizenid (from src, never the
---payload) must appear in the account's signed-in list before anything inside that mailbox may
---change. Centralised so every mutator runs the exact same check; the string type check also
---keeps a non-string payload field from ever reaching the SQL layer as a query parameter.
---@param source number
---@param accountEmail string
---@return string|nil cid, table|nil err
local function requireOwnership(source, accountEmail)
    local me = whois(source); if not me then return nil, fail('Player not found') end
    if type(accountEmail) ~= 'string' or accountEmail == '' then return nil, fail('Account email is required') end
    local acc = store.getAccount(accountEmail); if not acc then return nil, fail('Account not found') end
    for i = 1, #acc.logged_in_citizens do
        if acc.logged_in_citizens[i] == me.cid then return me.cid, nil end
    end
    return nil, fail('You are not signed into that account')
end

---Mark a message as read. Ownership-gated; a bogus message id matches nothing in the store
---(the row is left untouched), so success is returned unconditionally - the client treats this
---as best-effort.
---@param source number
---@param payload { accountEmail?: string, messageId?: string }
---@return table
function actions.markRead(source, payload)
    payload = payload or {}
    local _, err = requireOwnership(source, payload.accountEmail); if err then return err end
    store.mutateMessage(payload.accountEmail, payload.messageId or '', function(m)
        m.read = true
        return m
    end)
    return ok()
end

---Toggle a message's flag. Ownership-gated; the new state derives from the STORED message, not
---the payload, so a crafted call can only ever flip the real flag.
---@param source number
---@param payload { accountEmail?: string, messageId?: string }
---@return table
function actions.toggleFlag(source, payload)
    payload = payload or {}
    local _, err = requireOwnership(source, payload.accountEmail); if err then return err end
    store.mutateMessage(payload.accountEmail, payload.messageId or '', function(m)
        m.flagged = not (m.flagged == true)
        return m
    end)
    return ok()
end

---Move a message to the bin, or hard-delete it if it's already there (the mutator returning nil
---removes it from the array). The flag clears on the way in so the Flagged view never shows
---binned mail. Ownership-gated.
---@param source number
---@param payload { accountEmail?: string, messageId?: string }
---@return table
function actions.moveToBin(source, payload)
    payload = payload or {}
    local _, err = requireOwnership(source, payload.accountEmail); if err then return err end
    store.mutateMessage(payload.accountEmail, payload.messageId or '', function(m)
        if m.folder == 'bin' then return nil end
        m.folder = 'bin'
        m.flagged = false
        return m
    end)
    return ok()
end

---Move a message to a specific folder (the Move action sheet). The destination is
---whitelist-checked against the five real folders - 'flagged' is a virtual view, never a real
---destination, and anything else from a crafted payload is rejected. Moving into the bin clears
---the flag, matching moveToBin. Ownership-gated.
---@param source number
---@param payload { accountEmail?: string, messageId?: string, folder?: string }
---@return table
function actions.move(source, payload)
    payload = payload or {}
    local _, err = requireOwnership(source, payload.accountEmail); if err then return err end
    local folder = payload.folder
    if folder ~= 'inbox' and folder ~= 'drafts' and folder ~= 'sent' and folder ~= 'spam' and folder ~= 'bin' then
        return { success = false, message = 'Bad folder' }
    end
    store.mutateMessage(payload.accountEmail, payload.messageId or '', function(m)
        if m.folder == folder then return nil end
        m.folder = folder
        if folder == 'bin' then m.flagged = false end
        return m
    end)
    return ok()
end

---Permanently delete an account the caller is signed into - the row carries the messages and
---session list, so all its mail dies with it. Gated by the same signed-in ownership check as
---the message mutators; by design ANY signed-in citizen can delete a shared mailbox, because
---credentials are the authority here, exactly as they are for sign-in.
---@param source number
---@param payload { email?: string }
---@return table
function actions.deleteAccount(source, payload)
    payload = payload or {}
    local email = trim(payload.email or ''):lower()
    local _, err = requireOwnership(source, email); if err then return err end
    store.deleteAccount(email)
    return ok({ email = email })
end

return actions
