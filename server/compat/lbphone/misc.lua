---@type table Shared shim helpers (server.compat.lbphone.shared): export registration + warn-once.
local shim = require 'server.compat.lbphone.shared'
---@type table Authoritative banking handlers (server.banking.actions): external transaction log.
local banking = require 'server.banking.actions'
---@type table Settings persistence layer (server.settings.store): number -> citizenid resolution.
local settings = require 'server.settings.store'
---@type table Shared server helpers (server.util): digit/trim/finite guards at the shim boundary.
local util = require 'server.util'

local registerLbExport, stubLbExport = shim.registerLbExport, shim.stubLbExport

---FormatNumber(number): sd-phone stores and displays raw digits, so formatting collapses to the
---digit normalisation every sd module applies anyway.
registerLbExport('FormatNumber', function(number)
    return util.digits(number)
end)

---ContainsBlacklistedWord(source, text): sd-phone has no word blacklist, so nothing is ever
---blacklisted. Silent - false is the harmless answer, not a degraded one.
registerLbExport('ContainsBlacklistedWord', function(_source, _text)
    return false
end)

---AddTransaction(phoneNumber, amount, company, logo?): append a Wallet row for the number's
---owner via the same actions.addExternal path the first-party addBankTransaction export uses.
---Log-only, exactly like lb's: no money moves. `amount` is signed (positive = received,
---negative = paid); incoming amounts pop the default received banner, matching lb's
---notify-on-transaction behaviour without notifying players about their own spending. The logo
---is dropped silently - sd Wallet rows carry no image. Works for offline owners (the log is
---keyed by citizenid).
registerLbExport('AddTransaction', function(phoneNumber, amount, company, logo)
    local cid = settings.getCitizenByNumber(phoneNumber)
    if not cid then return false end
    local n = tonumber(amount)
    if not util.finite(n) then return false end

    local label = util.trim(type(company) == 'number' and tostring(company) or company)
    if label == '' then label = 'Transaction' end

    return banking.addExternal(cid, {
        label        = label,
        amount       = n,
        counterparty = label,
        notify       = n > 0,
    })
end)

-- Misc surfaces with no sd-phone equivalent. GetConfig/GetCellTowers answer with empty tables
-- so iterating callers keep working; AirShare's consent handshake only exists player-to-player
-- inside sd-phone; AddCheck open-conditions are covered by the sd setDisabled client export.
stubLbExport('GetConfig', {})
stubLbExport('GetCellTowers', {})
stubLbExport('AirShare', nil)
stubLbExport('AddCheck', 0, 'is not supported; use exports["sd-phone"]:setDisabled(true) on the client instead')
stubLbExport('RemoveCheck', false, 'is not supported; use exports["sd-phone"]:setDisabled(false) on the client instead')

-- Social media: sd-phone's photogram/birdy/vibez accounts are managed by their own apps and the
-- accounts engine; none of lb's remote mutation surface is bridged.
stubLbExport('GetSocialMediaUsername', nil)
stubLbExport('ToggleVerified', false)
stubLbExport('IsVerified', false)
stubLbExport('ChangePassword', false)
stubLbExport('PostBirdy', false)
stubLbExport('GetBirdyPost', nil)
stubLbExport('DeleteBirdyAccount', false)
stubLbExport('DeleteInstaPicAccount', false)
stubLbExport('DeleteTrendyAccount', false)

-- DarkChat: sd-phone's darkchat is its own system with no external mutation surface.
stubLbExport('SendDarkChatMessage', false)
stubLbExport('SendDarkChatLocation', false)
stubLbExport('CreateDarkChatChannel', false)
stubLbExport('DeleteDarkChatChannel', false)
stubLbExport('AddUserToDarkChatChannel', false)
stubLbExport('RemoveUserFromDarkChatChannel', false)

-- Crypto: sd-phone has no crypto wallet (Stocks is a different app with different semantics).
stubLbExport('AddCrypto', false)
stubLbExport('RemoveCrypto', false)
stubLbExport('AddCustomCoin', nil)
stubLbExport('GetCoin', nil)
stubLbExport('GetOwnedCoin', false)

-- lb-phone's custom callback wire and the custom-app ecosystem built on it are out of scope for
-- the shim; there is nothing on the sd side for a bridged callback to reach.
stubLbExport('RegisterCallback', nil, 'is not bridged: the lb-phone callback wire and custom-app ecosystem are out of scope')
stubLbExport('BaseCallback', nil, 'is not bridged: the lb-phone callback wire and custom-app ecosystem are out of scope')
stubLbExport('TriggerClientCallback', nil, 'is not bridged: the lb-phone callback wire and custom-app ecosystem are out of scope')
stubLbExport('AwaitClientCallback', nil, 'is not bridged: the lb-phone callback wire and custom-app ecosystem are out of scope')
