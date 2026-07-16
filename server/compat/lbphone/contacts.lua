---@type table Shared shim helpers (server.compat.lbphone.shared): export registration + warn-once.
local shim = require 'server.compat.lbphone.shared'
---@type table Authoritative contact handlers (server.contacts.actions): add validation + serialization.
local actions = require 'server.contacts.actions'
---@type table Player bridge (bridge.server.player): source resolution from a citizenid.
local player = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): number -> citizenid resolution.
local settings = require 'server.settings.store'
---@type table Shared server helpers (server.util): trim for the name assembly.
local util = require 'server.util'

local registerLbExport, warnOnce = shim.registerLbExport, shim.warnOnce

---AddContact(phoneNumber, data { number, firstname, lastname?, avatar?, email?, address? }):
---plant a contact in the ONLINE owner of phoneNumber's list. Walks the exact actions.add
---validation the NUI path uses (number in service, not their own, not a duplicate, per-player
---cap) and pushes the new card live over the same client event an accepted AirShare uses,
---mirroring the first-party addContact export. sd-phone contacts are keyed by citizenid but
---mutated through a source-scoped action, so an OFFLINE owner cannot be reached; that case
---warns once and adds nothing. A validation rejection (duplicate, cap, number not in service)
---also warns once, with the reason, so a dropped integration contact is findable in console.
registerLbExport('AddContact', function(phoneNumber, data)
    if type(data) ~= 'table' then return false end

    local cid = settings.getCitizenByNumber(phoneNumber)
    local src = cid and player.getSourceByIdentifier(cid) or nil
    if not src then
        warnOnce('AddContact.offline', ('AddContact only reaches ONLINE players in sd-phone (called by %s); the contact was not added'):format(GetInvokingResource() or 'unknown'))
        return false
    end

    local name = util.trim(('%s %s'):format(
        type(data.firstname) == 'string' and data.firstname or '',
        type(data.lastname) == 'string' and data.lastname or ''))

    local result = actions.add(src, {
        name    = name,
        phone   = data.number,
        email   = data.email,
        address = data.address,
        avatar  = data.avatar,
    })
    if result.success then
        TriggerClientEvent('sd-phone:client:contacts:shared', src, result.data)
    else
        warnOnce('AddContact.rejected', ('AddContact was rejected by contact validation: %s (called by %s)'):format(result.message or 'unknown reason', GetInvokingResource() or 'unknown'))
    end
    return result.success == true
end)
