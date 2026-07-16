---@type table Mail persistence layer (server.mail.store): schema bootstrap + read-only lookups
---for the exports.
local store   = require 'server.mail.store'
---@type table Authoritative mail handlers (server.mail.actions): validation + mutation per
---callback, plus the shared delivery fan-out.
local actions = require 'server.mail.actions'
---@type table Home-screen badge engine (server.badges.init): recomputes + pushes unread counts.
local badges  = require 'server.badges.init'
---@type table Shared server helpers (server.util): failure envelopes + input trims for the exports.
local util    = require 'server.util'
local fail, trim = util.fail, util.trim

---Schema bootstrap. Runs in a thread so it can yield until oxmysql is ready without blocking
---resource start; a failure is loud but non-fatal (the callbacks still register and surface
---their own errors).
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:mail]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:mail]^0 schema ready')
end)

---Complete a successful send envelope: run the shared delivery fan-out (actions.deliver, a live
---UI event + badge repush per online signed-in citizen), then strip the pushes list - and the
---citizenids inside it - from the envelope so the caller only ever learns about its own sent
---copy, never who is signed into which mailbox.
---@param result table envelope from actions.send
---@return table
local function dispatchSend(result)
    if result.success and result.data then
        actions.deliver(result.data.pushes)
        result.data = { sent = result.data.sent }
    end
    return result
end

-- Authoritative Mail callbacks: thin delegates into server.mail.actions, which owns the
-- validation + mutation (each handler is documented there). src is trusted (the server injects
-- it); every payload field is validated inside the action. Handlers that can change which
-- messages count as unread also repush the caller's badge snapshot afterwards - pushed, not
-- incremented, so the badge can't drift.
lib.callback.register('sd-phone:server:mail:list', function(src)
    return actions.list(src)
end)

lib.callback.register('sd-phone:server:mail:signUp', function(src, payload)
    return actions.signUp(src, payload)
end)

---Sign-in repushes the badge snapshot: a freshly signed-in mailbox's unread now counts.
lib.callback.register('sd-phone:server:mail:signIn', function(src, payload)
    local result = actions.signIn(src, payload)
    badges.push(src)
    return result
end)

---Sign-out repushes the badge snapshot: a signed-out mailbox's unread no longer counts.
lib.callback.register('sd-phone:server:mail:signOut', function(src, payload)
    local result = actions.signOut(src, payload)
    badges.push(src)
    return result
end)

---Send is the one non-thin delegate: on success the persisted inbox copies fan out through the
---shared delivery path and the push list is stripped before the envelope returns (dispatchSend).
lib.callback.register('sd-phone:server:mail:send', function(src, payload)
    return dispatchSend(actions.send(src, payload))
end)

lib.callback.register('sd-phone:server:mail:saveDraft', function(src, payload)
    return actions.saveDraft(src, payload)
end)

---Reading an email can decrement the Mail badge, so the snapshot repushes after.
lib.callback.register('sd-phone:server:mail:markRead', function(src, payload)
    local result = actions.markRead(src, payload)
    badges.push(src)
    return result
end)

lib.callback.register('sd-phone:server:mail:toggleFlag', function(src, payload)
    return actions.toggleFlag(src, payload)
end)

---Binning an unread email decrements the Mail badge, so the snapshot repushes after.
lib.callback.register('sd-phone:server:mail:moveToBin', function(src, payload)
    local result = actions.moveToBin(src, payload)
    badges.push(src)
    return result
end)

---Moving to/from the inbox changes what counts as unread, so the snapshot repushes after.
lib.callback.register('sd-phone:server:mail:move', function(src, payload)
    local result = actions.move(src, payload)
    badges.push(src)
    return result
end)

---A deleted account's unread mail no longer counts, so the snapshot repushes after.
lib.callback.register('sd-phone:server:mail:deleteAccount', function(src, payload)
    local result = actions.deleteAccount(src, payload)
    badges.push(src)
    return result
end)

---@type table<string, true> The five real folders getMailbox accepts; 'flagged' is a virtual
---view, matching the actions.move whitelist.
local FOLDERS = { inbox = true, drafts = true, sent = true, spam = true, bin = true }

-- Public Mail exports. Reachable only by other server resources - never by clients - so the
-- shape checks exist to fail cleanly on caller bugs rather than to distrust the values: a bad
-- argument returns false/nil/an empty list/a failure envelope instead of erroring. Any acting
-- identity is honoured as given, and the real validation lives in server.mail.actions.

---Send mail as the system - exports['sd-phone']:sendMail(mail). `mail.to` is one address or a
---list (deduped, capped at 20); optional subject/body are truncated to the compose caps;
---optional `from` { name, email } defaults to System <no-reply@Domain> and is display-only,
---never resolved to an account. Recipient addresses with no registered account are silently
---skipped; `delivered` counts the ones that existed, each getting a persisted inbox copy plus a
---live push + badge repush for its signed-in online citizens.
---@param mail { to: string|string[], subject?: string, body?: string, from?: { name?: string, email?: string } }
---@return { success: boolean, delivered: number }
exports('sendMail', function(mail)
    local result = actions.systemSend(mail)
    return {
        success   = result.success == true,
        delivered = result.data and result.data.delivered or 0,
    }
end)

---Send mail on a player's behalf from another resource -
---exports['sd-phone']:sendMailFromPlayer(source, payload). Mirrors the NUI send payload:
---{ fromEmail, to = string[], subject?, body? }. The caller is trusted to name the acting
---player, but the payload still walks the full compose validation in actions.send: the player
---must be signed into fromEmail, the From header is rebuilt from the account row, and the
---recipient/subject/body caps apply. The delivery fan-out runs here and the push list is
---stripped, so the envelope only carries the sender's own sent copy (data.sent).
---@param source number acting player's server id (the sender's identity resolves from it)
---@param payload table
---@return table envelope; data.sent is the serialized sent copy on success
exports('sendMailFromPlayer', function(source, payload)
    if type(source) ~= 'number' then return fail('Acting player source is required') end
    if type(payload) ~= 'table' then return fail('Payload must be a table') end
    return dispatchSend(actions.send(source, payload))
end)

---Every mail account a player is signed into - exports['sd-phone']:getMailAccounts(source).
---Returns { id, name, email } per account in creation order; empty when the source is offline
---or signed into nothing. Never carries password_hash or the signed-in citizen list.
---@param source number player server id
---@return { id: string, name: string, email: string }[]
exports('getMailAccounts', function(source)
    if type(source) ~= 'number' then return {} end
    local result = actions.list(source)
    return result.success and result.data.accounts or {}
end)

---Same account shape keyed by citizenid instead of a live source -
---exports['sd-phone']:getMailAddresses(citizenid). Works for offline players. The citizenid
---must be a non-empty string without % or _: the store's session lookup rides JSON_SEARCH,
---which treats both as wildcards, so a patterned input could match other citizens' sessions.
---Never carries password_hash or the signed-in citizen list.
---@param citizenid string
---@return { id: string, name: string, email: string }[]
exports('getMailAddresses', function(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or citizenid:find('[%%_]') then return {} end
    local accounts = store.listAccountsForCitizen(citizenid)
    local out = {}
    for i = 1, #accounts do
        out[i] = { id = accounts[i].email, name = accounts[i].display_name, email = accounts[i].email }
    end
    return out
end)

---Whether a mail address resolves to a registered account -
---exports['sd-phone']:mailAddressExists(email). Trimmed + lowercased before the lookup; a
---non-string or empty address is simply false.
---@param email string
---@return boolean
exports('mailAddressExists', function(email)
    local addr = trim(email):lower()
    if addr == '' then return false end
    return store.getAccount(addr) ~= nil
end)

---Read a mailbox's messages - exports['sd-phone']:getMailbox(email, folder?). Returns the same
---serialized MailMessage shape the app renders, nil when the account doesn't exist or the
---folder isn't one of the five real ones (inbox/drafts/sent/spam/bin; 'flagged' is a virtual
---view). Omit folder for every message in the account.
---@param email string
---@param folder? string
---@return table[]|nil
exports('getMailbox', function(email, folder)
    local addr = trim(email):lower()
    if addr == '' then return nil end
    if folder ~= nil and not FOLDERS[folder] then return nil end
    local acc = store.getAccount(addr)
    if not acc then return nil end
    local out = {}
    for i = 1, #acc.messages do
        local msg = acc.messages[i]
        if not folder or (msg.folder or 'inbox') == folder then
            out[#out + 1] = actions.serializeMessage(acc.email, msg)
        end
    end
    return out
end)
