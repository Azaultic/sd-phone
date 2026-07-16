---@type table Shared shim helpers (server.compat.lbphone.shared): export registration + warn-once.
local shim = require 'server.compat.lbphone.shared'
---@type table Player bridge (bridge.server.player): citizenid/source resolution.
local player = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): numbers, airplane mode, lock security.
local settings = require 'server.settings.store'

local registerLbExport, stubLbExport = shim.registerLbExport, shim.stubLbExport

---@type table Self-export proxy for sd-phone's own server surface. hasPhone closes over
---server/main.lua locals (the same inventory gate the keybind open uses), so the export is the
---one reusable entry point; a resource may call its own exports.
local sd = exports['sd-phone']

---GetEquippedPhoneNumber(source | identifier): the target's phone number. sd-phone has no
---equipped-phone concept - one number per character - so a server id resolves through the same
---assign-on-first-access path the first-party getPhoneNumber export uses, and a string is
---treated as a citizenid (lb-phone's offline form) with a read-only lookup, matching
---getPhoneNumberByIdentifier without ensure.
registerLbExport('GetEquippedPhoneNumber', function(target)
    if type(target) == 'number' then
        local cid = player.getIdentifier(target)
        return cid and settings.ensurePhoneNumber(cid) or nil
    end
    if type(target) == 'string' and target ~= '' then
        return settings.getPhoneNumber(target)
    end
    return nil
end)

---GetSourceFromNumber(number): the connected server id owning a phone number, nil when the
---number is unassigned or its owner is offline. Any formatting is accepted (the store
---digit-normalises both sides).
registerLbExport('GetSourceFromNumber', function(number)
    local cid = settings.getCitizenByNumber(number)
    return cid and player.getSourceByIdentifier(cid) or nil
end)

---HasPhoneItem(source, number?): whether the player owns any configured phone item, answered by
---the first-party hasPhone export (the authoritative inventory gate). The per-number refinement
---is meaningless under sd-phone's one-number-per-character model and is ignored.
registerLbExport('HasPhoneItem', function(source, _phoneNumber)
    if type(source) ~= 'number' then return false end
    return sd:hasPhone(source) ~= nil
end)

---HasAirplaneMode(number): airplane state of the number's owner, served from the settings
---store's memory cache. An unassigned number reads as false rather than blocking a caller.
registerLbExport('HasAirplaneMode', function(number)
    local cid = settings.getCitizenByNumber(number)
    if not cid then return false end
    return settings.isAirplane(cid)
end)

---ResetSecurity(number): clear the owner's lock passcode. The store forces Face Unlock off
---whenever no passcode is stored, so the pair can never disagree. A number nobody owns is a
---no-op, matching lb-phone's nothing-returned contract.
registerLbExport('ResetSecurity', function(number)
    local cid = settings.getCitizenByNumber(number)
    if cid then settings.setSecurity(cid, nil, false) end
end)

-- Battery family: sd-phone has no battery system, so a phone is never dead and battery saves
-- are meaningless. Silent by design - these are poll-shaped calls, not integrations worth a
-- degraded-mode breadcrumb.
registerLbExport('IsPhoneDead', function() return false end)
registerLbExport('SaveBattery', function() end)
registerLbExport('SaveAllBatteries', function() end)

-- Phone/user surfaces with no sd-phone equivalent: the settings table is not exposed to other
-- resources, and there is no factory-reset path.
stubLbExport('GetSettings', nil)
stubLbExport('FactoryReset', nil)
stubLbExport('GetPin', nil, 'is never disclosed: sd-phone does not hand lock passcodes to other resources, a privacy decision')
