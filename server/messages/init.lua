---@type table sd-phone config root (configs/config.lua).
local config  = require 'configs.config'
---@type table Shared server helpers (server.util): digit / trim sanitizers for the export boundary.
local util    = require 'server.util'
---@type table Messages persistence layer (server.messages.store): mailbox rows, groups, reactions.
local store   = require 'server.messages.store'
---@type table Authoritative message handlers (server.messages.actions): validation + delivery fan-out.
local actions = require 'server.messages.actions'

---Schema bootstrap. Threaded so it yields until oxmysql is ready without blocking resource
---start; a failure is printed and leaves the module registered but inert rather than crashing
---the whole resource.
CreateThread(function()
    local success, err = pcall(store.ensureSchema)
    if not success then
        print(('^1[sd-phone:messages]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:messages]^0 schema ready')
end)

-- Authoritative NUI callbacks: thin delegates into server.messages.actions, which owns the
-- validation + mailbox mutation (each handler is documented there). Reachable by ANY client with
-- ANY payload - every handler resolves the actor from src alone and re-validates its payload at
-- the trust boundary.
lib.callback.register('sd-phone:server:messages:list', function(src) return actions.list(src) end)
lib.callback.register('sd-phone:server:messages:send', function(src, payload) return actions.send(src, payload) end)
lib.callback.register('sd-phone:server:messages:uploadVoice', function(src, payload) return actions.uploadVoice(src, payload) end)
lib.callback.register('sd-phone:server:messages:createGroup', function(src, payload) return actions.createGroup(src, payload) end)
lib.callback.register('sd-phone:server:messages:addGroupMember', function(src, payload) return actions.addGroupMember(src, payload) end)
lib.callback.register('sd-phone:server:messages:updateGroup', function(src, payload) return actions.updateGroup(src, payload) end)
lib.callback.register('sd-phone:server:messages:removeGroupMember', function(src, payload) return actions.removeGroupMember(src, payload) end)
lib.callback.register('sd-phone:server:messages:markRead', function(src, payload) return actions.markRead(src, payload) end)
lib.callback.register('sd-phone:server:messages:delete', function(src, payload) return actions.deleteConversation(src, payload) end)
lib.callback.register('sd-phone:server:messages:react', function(src, payload) return actions.react(src, payload) end)

---When a player turns OFF airplane mode the settings module fires this server-side event:
---deliver everything that was held back while it was on. Plain AddEventHandler (not
---network-registered), so a client can't fire it - `source` is trusted as the argument the
---settings module passes.
---@param source number player server id
AddEventHandler('sd-phone:server:airplane:released', function(source)
    actions.releaseWithheld(source)
end)

---Send a message on a player's behalf from another resource. Mirrors the NUI `send` payload:
---{ conversation = '<number>' | 'g-<groupId>', body, kind?, gifUrl?/amount?/duration?/wpCode?/
---wpSub? }. Callers are other server resources (trusted to name the acting player), but the
---payload still walks the full composer validation in actions.send - kind whitelist, caps,
---banking-validated money - so a sloppy caller can't corrupt a mailbox or move unchecked funds.
---@param source number acting player's server id (the sender's identity resolves from it)
---@param payload table
---@return table
exports('sendMessage', function(source, payload)
    return actions.send(source, payload)
end)

---Coerce an export argument to a trimmed string: numbers stringify (an integral float as a plain
---integer, so a phone number passed as 5551234.0 becomes '5551234', not '55512340' once the
---digit-strip eats the '.0'), any other non-string becomes ''. Keeps a caller bug (table,
---boolean) from leaking tostring() garbage into a row.
---@param v any
---@return string
local function str(v)
    if math.type(v) == 'float' and v % 1 == 0 then
        v = ('%.0f'):format(v)
    elseif type(v) == 'number' then
        v = tostring(v)
    end
    return util.trim(v)
end

---Deliver a one-way system text to a phone number from another resource -
---exports['sd-phone']:sendSystemMessage(senderNumber, senderName, targetNumber, body, opts?).
---A service-to-player SMS rather than a player send: NO sender mailbox copy is stored, the
---recipient's block list is bypassed, and a recipient in airplane mode has the message withheld
---until they switch it off. `opts` may request a presentation-safe kind - { kind = 'image' |
---'gif', gifUrl = url } or { kind = 'location', wpCode = code, wpSub = label } - the whitelist
---and meta sanitizing live in actions.systemText, and anything outside it (money above all) is
---delivered as plain text, so this path can never mint payment cards. Numbers are
---digit-normalized, the body is trimmed and capped at the Messages MaxBodyLength config, and
---the sender fields are capped to their columns (number 32, name 64). Returns false on caller
---bugs (blank numbers, no content for the kind) or a target number not in service.
---@param senderNumber string|number service short code the recipient's thread files under
---@param senderName string|number display name for the banner and thread header
---@param targetNumber string|number recipient phone number
---@param body string|number message body
---@param opts table|nil presentation-safe kind + its fields (see above)
---@return boolean delivered
exports('sendSystemMessage', function(senderNumber, senderName, targetNumber, body, opts)
    local sender = util.digits(str(senderNumber)):sub(1, 32)
    local target = util.digits(str(targetNumber))
    if sender == '' or target == '' then return false end

    local name = str(senderName):sub(1, 64)
    local text = str(body)
    local maxBody = config.Messages.MaxBodyLength
    if #text > maxBody then text = text:sub(1, maxBody) end

    return actions.systemText(sender, name, target, text, type(opts) == 'table' and opts or nil)
end)
