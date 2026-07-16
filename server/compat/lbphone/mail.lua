---@type table Shared shim helpers (server.compat.lbphone.shared): export registration + warn-once.
local shim = require 'server.compat.lbphone.shared'
---@type table Authoritative mail handlers (server.mail.actions): systemSend validation + fan-out.
local actions = require 'server.mail.actions'
---@type table Mail persistence layer (server.mail.store): account lookups by citizenid.
local store = require 'server.mail.store'
---@type table Settings persistence layer (server.settings.store): number -> citizenid resolution.
local settings = require 'server.settings.store'
---@type table Shared server helpers (server.util): trim at the shim boundary.
local util = require 'server.util'

local registerLbExport, stubLbExport, warnOnce = shim.registerLbExport, shim.stubLbExport, shim.warnOnce

---GetEmailAddress(number): the first mail address registered to the number's owner, in account
---creation order, nil when the number is unassigned or the owner never made an account.
---sd-phone allows several accounts per character where lb-phone has one per phone, so "first"
---is the closest equivalent.
registerLbExport('GetEmailAddress', function(number)
    local cid = settings.getCitizenByNumber(number)
    if not cid then return nil end
    local accounts = store.listAccountsForCitizen(cid)
    return accounts[1] and accounts[1].email or nil
end)

---SendMail(data { to, sender?, subject?, message?, attachments?, actions? }): system mail
---through actions.systemSend, which owns recipient normalization, the caps and the delivery
---fan-out. Attachment URLs are appended to the body on their own lines (sd mail has no
---attachment field); lb action buttons have no equivalent and are dropped with a one-time
---warning. Returns the success boolean only - sd-phone mail exposes no message id to return.
registerLbExport('SendMail', function(data)
    if type(data) ~= 'table' then return false end
    if data.actions ~= nil then
        warnOnce('SendMail.actions', ('SendMail action buttons are not supported (called by %s); the mail was sent without them'):format(GetInvokingResource() or 'unknown'))
    end

    local body = util.trim(type(data.message) == 'number' and tostring(data.message) or data.message)
    if type(data.attachments) == 'table' then
        for i = 1, #data.attachments do
            local url = data.attachments[i]
            if type(url) == 'string' and url ~= '' then
                body = body == '' and url or (body .. '\n' .. url)
            end
        end
    end

    local result = actions.systemSend({
        to      = data.to,
        subject = data.subject,
        body    = body,
        from    = { name = data.sender },
    })
    return result.success == true
end)

-- The sd-phone accounts engine only creates mail accounts for a present, signed-in player
-- (passwords hash through the interactive flows), and raw mailbox rows are not deletable from
-- other resources.
stubLbExport('CreateMailAccount', false)
stubLbExport('DeleteMail', false)
