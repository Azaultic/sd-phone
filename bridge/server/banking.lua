---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework = require 'bridge.shared.framework'
---@type table Money bridge (bridge.server.money): framework personal-account operations.
local money     = require 'bridge.server.money'
---@type table Player bridge (bridge.server.player): citizenid/identifier lookups from src.
local player    = require 'bridge.server.player'

---@type table Banking module; the table returned at end of file. Multi-banking adapter: reads +
---moves a player's PERSONAL bank balance across the popular banking resources. Research finding:
---for most of them the personal balance lives in the framework's own player bank account, so the
---base money bridge is authoritative and universal - only a handful keep balances in their OWN
---tables AND expose a player-level export, and those get a dedicated path. Everything else
---(esx_banking, qb-banking, Renewed-Banking, ps-banking, okokBanking, qs-banking, fd_banking,
---new_banking, or no banking resource at all) routes through the framework bank account. Every
---export call is wrapped so a missing/renamed export in a forked copy degrades to the framework
---path instead of erroring.
local banking = {}

-- Banking resources, in detection priority: own-table resources first (they must win over the
-- framework path), then framework-native ones (informational only). Dedicated-path export shapes:
--   wasabi_banking : AddMoney/RemoveMoney/GetAccountBalance(identifier, amount, reason)
--   omes_banking   : AddBankMoney/RemoveBankMoney/GetBankBalance(source, amount, desc)
--   prism_banking  : AddBankingTransaction(source, type, amount, spendType, tax, name, desc)
--   tgg-banking    : GetPersonalAccountByPlayerId(source).balance (read only - no personal
--                    add/remove exports, so money movement stays on the framework account)
---@type string[] Banking resources, in detection-priority order.
local KNOWN = {
    'wasabi_banking', 'omes_banking', 'prism_banking', 'tgg-banking', 'okokBanking',
    'Renewed-Banking', 'qb-banking', 'esx_banking', 'qs-banking', 'fd_banking',
    'new_banking', 'ps-banking',
}

-- Resources that store the personal balance in their OWN tables - the framework bank account is
-- NOT authoritative for these, so offline DB credit (addOffline) is unsafe and the transfer path
-- refuses it via balanceIsFramework().
---@type table<string, boolean> Own-table banking resources.
local OWN_TABLE = {
    wasabi_banking = true, okokBanking = true, ['tgg-banking'] = true,
    prism_banking  = true, fd_banking  = true,
}

---@type boolean, string|nil Detection-ran flag + cached provider name (nil = framework account).
local resolved, providerName = false, nil

---The active banking resource, resolved lazily (and cached) on first use rather than at load, so
---the banking resource is detected correctly even if it starts after sd-phone. Nil when none is
---started - every operation then uses the framework bank account directly.
---@return string|nil
local function provider()
    if not resolved then
        for _, name in ipairs(KNOWN) do
            if GetResourceState(name) == 'started' then providerName = name; break end
        end
        resolved = true
        print(('^2[sd-phone:banking]^0 banking provider: ^3%s^0'):format(providerName or 'framework account'))
    end
    return providerName
end

-- Back-compat: `banking.name` reads through the lazy resolver, so older call sites keep working
-- without forcing detection at load time.
setmetatable(banking, { __index = function(_, k) if k == 'name' then return provider() end end })

---True when the player's bank balance IS the framework account, so an offline DB credit
---(addOffline) is safe. False for the OWN_TABLE resources - crediting the framework account there
---would move money the banking resource never shows the player.
---@return boolean
function banking.balanceIsFramework()
    local name = provider()
    return not (name and OWN_TABLE[name])
end

---Run a provider export call; true only if it didn't error. Used so a bad/renamed export falls
---through to the framework path rather than throwing. Unlike the society bridge's try(), the
---provider's return VALUE is ignored here - addMoney/removeMoney have no return channel to
---propagate a decline anyway, which is why every debit caller pre-checks getBalance first.
---@param fn function
---@return boolean
local function try(fn)
    local ok = pcall(fn)
    return ok
end

---The player's current bank balance. Read-only. Own-table providers are read through their
---exports (prism returns a set of accounts - the first with a numeric balance wins); any miss,
---type surprise, or error falls through to the framework bank account, which is authoritative for
---every non-OWN_TABLE setup.
---@param src number
---@return number
function banking.getBalance(src)
    local name = banking.name
    if name == 'wasabi_banking' then
        local id = player.getIdentifier(src)
        if id then
            local ok, bal = pcall(function() return exports.wasabi_banking:GetAccountBalance(id) end)
            if ok and type(bal) == 'number' then return bal end
        end
    elseif name == 'omes_banking' then
        local ok, bal = pcall(function() return exports['omes_banking']:GetBankBalance(src) end)
        if ok and type(bal) == 'number' then return bal end
    elseif name == 'tgg-banking' then
        local ok, acc = pcall(function() return exports['tgg-banking']:GetPersonalAccountByPlayerId(src) end)
        if ok and type(acc) == 'table' and type(acc.balance) == 'number' then return acc.balance end
    elseif name == 'prism_banking' then
        local ok, accs = pcall(function() return exports['prism_banking']:GetBankAccounts(src) end)
        if ok and type(accs) == 'table' then
            for _, a in pairs(accs) do
                if type(a) == 'table' and type(a.balance) == 'number' then return a.balance end
            end
        end
    end
    return money.get(src, 'bank')
end

---Credit the player's bank account. A dedicated provider path returns early only when its export
---call didn't error; on error the credit lands on the framework bank account instead, so the
---money is never dropped. tgg-banking has no personal credit export, so it intentionally routes
---to the framework account.
---@param src number
---@param amount number
---@param reason? string
function banking.addMoney(src, amount, reason)
    local name = banking.name
    if name == 'wasabi_banking' then
        local id = player.getIdentifier(src)
        if id and try(function() exports.wasabi_banking:AddMoney(id, amount, reason or 'Phone transfer') end) then return end
    elseif name == 'omes_banking' then
        if try(function() exports['omes_banking']:AddBankMoney(src, amount, reason or 'Phone transfer') end) then return end
    elseif name == 'prism_banking' then
        if try(function() exports['prism_banking']:AddBankingTransaction(src, 'deposit', amount, 'phone', false, reason or 'Phone transfer', reason or '') end) then return end
    end
    money.add(src, 'bank', amount, reason)
end

---Debit the player's bank account. Returns nothing, so it CANNOT report a declined debit -
---callers MUST pre-check getBalance >= amount first, and every caller in server/ does (banking
---transfer, services deposit, stocks deposit). prism models a withdrawal as an
---AddBankingTransaction of type 'withdraw'.
---@param src number
---@param amount number
---@param reason? string
function banking.removeMoney(src, amount, reason)
    local name = banking.name
    if name == 'wasabi_banking' then
        local id = player.getIdentifier(src)
        if id and try(function() exports.wasabi_banking:RemoveMoney(id, amount, reason or 'Phone transfer') end) then return end
    elseif name == 'omes_banking' then
        if try(function() exports['omes_banking']:RemoveBankMoney(src, amount, reason or 'Phone transfer') end) then return end
    elseif name == 'prism_banking' then
        if try(function() exports['prism_banking']:AddBankingTransaction(src, 'withdraw', amount, 'phone', false, reason or 'Phone transfer', reason or '') end) then return end
    end
    money.remove(src, 'bank', amount, reason)
end

---Best-effort credit to an OFFLINE character's framework bank account via a direct, parameterized
---DB write against each framework's default schema. Only safe when the balance lives in the
---framework account (balanceIsFramework) - the transfer path enforces that before calling. True
---only when a row was actually updated: a query that succeeded while matching ZERO rows (unknown
---citizenid) must report false, because the caller refunds the sender's debit on false - reporting
---success there would vanish the sender's money with nobody credited.
---@param citizenid string
---@param amount number
---@return boolean ok
function banking.addOffline(citizenid, amount)
    if framework.name == 'qb' then
        local ok, affected = pcall(function()
            return MySQL.update.await(
                "UPDATE players SET money = JSON_SET(money, '$.bank', JSON_EXTRACT(money, '$.bank') + ?) WHERE citizenid = ?",
                { amount, citizenid })
        end)
        return ok and (tonumber(affected) or 0) > 0
    elseif framework.name == 'esx' then
        local ok, affected = pcall(function()
            return MySQL.update.await(
                "UPDATE users SET accounts = JSON_SET(accounts, '$.bank', JSON_EXTRACT(accounts, '$.bank') + ?) WHERE identifier = ?",
                { amount, citizenid })
        end)
        return ok and (tonumber(affected) or 0) > 0
    end
    return false
end

---Best-effort: mirror a phone transfer into the active banking resource's own transaction log so
---its UI stays roughly in sync. Failures are swallowed - a missing log line must never fail a
---transfer that already happened. wasabi_banking / prism_banking log implicitly via the reason
---passed to their add/remove calls; Renewed/ps/qs/fd/tgg/new expose no safe personal-log path, so
---they get nothing here.
---@param src number
---@param label string
---@param amount number positive magnitude
---@param isCredit boolean
function banking.logToResource(src, label, amount, isCredit)
    local name = banking.name
    if name == 'esx_banking' then
        try(function() exports['esx_banking']:logTransaction(src, label, isCredit and 'DEPOSIT' or 'WITHDRAW', amount) end)
    elseif name == 'qb-banking' then
        local cid = player.getIdentifier(src)
        try(function() exports['qb-banking']:CreateBankStatement(src, cid, amount, label, isCredit and 'deposit' or 'withdraw', 'player') end)
    elseif name == 'okokBanking' then
        local cid = player.getIdentifier(src)
        try(function() exports['okokBanking']:AddTransaction(cid, { type = isCredit and 'deposit' or 'withdraw', amount = amount, reason = label }, src) end)
    elseif name == 'omes_banking' then
        try(function() exports['omes_banking']:LogCustomTransaction(src, isCredit and 'deposit' or 'withdraw', amount, label) end)
    end
end

return banking
