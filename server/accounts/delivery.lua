---@type table Messages handlers (server.messages.actions): systemText for targeted SMS delivery.
local msgActions = require 'server.messages.actions'

---@type table|nil Mail handlers (server.mail.actions), resolved lazily inside sendCodeEmail: a
---boot-time require would close a load cycle (server.mail.actions -> server.accounts.actions ->
---this module), so the reference is fetched on first use, long after every module has loaded.
local mailActions

---@type table Delivery module; the table returned at end of file.
local delivery = {}

-- Per-app delivery identity: the SMS short code (the "sender number" of verification texts,
-- keypad-spelling the app name) and the pretty name used on both channels. An app with no entry
-- here cannot deliver reset codes, so every ALL_APPS key in server.accounts.actions needs a row.
---@type table<string, { name: string, code: string }> Sender identity per account app.
local APPS = {
    photogram = { name = 'Photogram', code = '74682' },
    cherry    = { name = 'Cherry',    code = '24377' },
    vibez     = { name = 'Vibez',     code = '84239' },
    birdy     = { name = 'Birdy',     code = '24739' },
    mail      = { name = 'Mail',      code = '62450' },
    ryde      = { name = 'Ryde',      code = '79333' },
}

---Pretty display name for an app, falling back to the raw key for apps with no delivery identity.
---@param app string account app key
---@return string label
function delivery.appLabel(app)
    return APPS[app] and APPS[app].name or app
end

---Deliver a verification mail to `email`'s inbox through the shared system-sender path
---(server.mail.actions.systemSend): the inbox copy persists and each of the mailbox's signed-in
---citizens gets a targeted live push + badge repush - never a broadcast, and the code is never
---printed; it exists solely inside the recipient's mailbox. Returns false (so the caller can
---report a delivery failure without leaking anything) when the app has no delivery identity or
---the mailbox no longer exists.
---@param email string recipient mail address
---@param app string account app key
---@param code string 6-digit reset code
---@return boolean delivered
function delivery.sendCodeEmail(email, app, code)
    local meta = APPS[app]; if not meta then return false end
    mailActions = mailActions or require 'server.mail.actions'
    local result = mailActions.systemSend({
        to      = { email },
        from    = { name = meta.name, email = ('no-reply@%s.ls'):format(app) },
        subject = ('Your %s verification code'):format(meta.name),
        body    = ('Your %s password reset code is %s. It expires in 10 minutes. If you did not request this, ignore this email.'):format(meta.name, code),
    })
    if not result.success or not result.data then return false end
    return (result.data.delivered or 0) > 0
end

---Text a verification code to `phone` from the app's short code. systemText resolves the number
---to its single owning citizen and delivers to that player alone - never a broadcast - and
---returns false when the number isn't active (or the app has no delivery identity), so the
---caller can surface the failure.
---@param phone string recipient phone number (digits)
---@param app string account app key
---@param code string 6-digit reset code
---@return boolean delivered
function delivery.sendCodeSms(phone, app, code)
    local meta = APPS[app]; if not meta then return false end
    local body = ('Your %s code is %s. It expires in 10 minutes.'):format(meta.name, code)
    return msgActions.systemText(meta.code, meta.name, phone, body)
end

return delivery
