---@type table Player bridge (bridge.server.player): connected-source lookup from a citizenid.
local player = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): phone-number -> citizenid lookups.
local settingsStore = require 'server.settings.store'

---Shared relay behind both notification exports: shape-check the payload, then push the banner.
---Exports are reachable only by other server resources - never by clients - so the checks here
---exist to fail cleanly on caller bugs rather than to distrust the payload: a non-number source,
---non-table data or missing title returns false instead of pushing a broken banner.
---@param source number player server id
---@param data table notification payload
---@return boolean sent
local function relay(source, data)
    if type(source) ~= 'number' then return false end
    if type(data) ~= 'table' or type(data.title) ~= 'string' then return false end
    TriggerClientEvent('sd-phone:client:notify', source, data)
    return true
end

---Public export: send an iOS-style phone notification to a player from any resource -
---exports['sd-phone']:notify(source, data). `data.title` is required; the optional fields are
---`app` (app-icon id), `image` (custom icon URL, overrides app), `body`, `time` (display
---string), and `appId` (the app opened when the banner is tapped).
---@param source number player server id
---@param data table notification payload
---@return boolean sent
exports('notify', function(source, data)
    return relay(source, data)
end)

---Public export: send the same notification addressed by phone number instead of server id -
---exports['sd-phone']:notifyNumber(number, data). The number is digit-normalised before lookup so
---any formatting matches; a digitless number, an unassigned number or an offline owner returns
---false rather than erroring. The payload contract matches notify.
---@param number string phone number in any formatting
---@param data table notification payload
---@return boolean sent
exports('notifyNumber', function(number, data)
    local digits = (tostring(number or ''):gsub('%D', ''))
    if digits == '' then return false end
    local cid = settingsStore.getCitizenByNumber(digits)
    if not cid then return false end
    local src = player.getSourceByIdentifier(cid)
    if not src then return false end
    return relay(src, data)
end)

---/phonenotif-to <playerId> - push a canned test notification at one player. Ace-restricted
---(RegisterCommand's restricted flag), so only the console and principals granted
---command.phonenotif-to can fire it. The console gets a usage hint when the target argument is
---missing; a permitted player's malformed call is silently ignored. Firing at a non-existent
---server id is a harmless no-op.
---@param src number caller server id (0 = console)
---@param args string[] raw command args
RegisterCommand('phonenotif-to', function(src, args)
    local target = tonumber(args[1])
    if not target then
        if src ~= 0 then return end
        print('^3usage:^0 phonenotif-to <playerId>')
        return
    end
    TriggerClientEvent('sd-phone:client:notify', target, {
        app   = 'messages',
        title = 'Notification',
        body  = 'Test notification from the server.',
        time  = 'now',
        appId = 'messages',
    })
end, true)
