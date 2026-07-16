---@type table sd-phone config root (configs/config.lua): Banking.TransactionLimit is the default export row cap.
local config = require 'configs.config'
---@type table Banking persistence layer (server.banking.store): phone_bank_transactions rows.
local store = require 'server.banking.store'
---@type table Authoritative banking handlers (server.banking.actions): overview/send/addExternal.
local actions = require 'server.banking.actions'
---@type table Shared server helpers (server.util): finite-number guard for the export boundary.
local util = require 'server.util'

-- One-shot boot thread: create the transaction-log schema before any handler needs it. pcall'd
-- so a broken DB prints one tagged line instead of killing the resource load.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:banking]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:banking]^0 schema ready')
end)

-- Authoritative NUI-facing callbacks: thin delegates into server.banking.actions, which owns the
-- validation + money movement (each handler is documented there).
lib.callback.register('sd-phone:server:banking:overview', function(src) return actions.overview(src) end)
lib.callback.register('sd-phone:server:banking:send', function(src, payload) return actions.send(src, payload) end)

---Public export: append a transaction to a character's Wallet list. Log-only - it does NOT move
---money; the calling resource owns the actual credit/debit. `amount` is signed: positive =
---money in, negative = money out. Set `notify` only for incoming payments the player didn't
---initiate (true pops a default "You received $X", a string pops that exact line); omit it for
---self-initiated moves (cashouts, wagers) so players aren't notified about their own. Usage:
---  exports['sd-phone']:addBankTransaction(citizenid, {
---      label = 'Paycheck', amount = 500, category = 'income', counterparty = 'LSPD',
---      notify = true,
---  })
---@param identifier string recipient citizenid
---@param data table transaction fields (validated + capped in actions.addExternal)
---@return boolean ok
exports('addBankTransaction', function(identifier, data)
    return actions.addExternal(identifier, data)
end)

---Same append as the export, for resources that prefer TriggerEvent. Deliberately a plain
---AddEventHandler (NOT RegisterNetEvent): only server-side code can raise it, so a modded client
---can't inject fake Wallet rows or notification spam.
---@param identifier string recipient citizenid
---@param data table transaction fields (validated + capped in actions.addExternal)
AddEventHandler('sd-phone:bank:addTransaction', function(identifier, data)
    actions.addExternal(identifier, data)
end)

---Public export: read a character's Wallet transaction log, newest first -
---exports['sd-phone']:getBankTransactions(citizenid, limit?). Read-only: returns the raw
---phone_bank_transactions rows (id, citizenid, label, amount signed, category, counterparty,
---created_at unix seconds). `limit` is optional and defaults to Banking.TransactionLimit; a
---supplied value must coerce to a FINITE number (NaN/inf are caller bugs - every comparison
---against NaN is false, so it must never reach the query - and return nil) and is floored then
---clamped to 1..100. A non-string or empty citizenid also returns nil instead of erroring.
---@param citizenid string owning character's citizenid
---@param limit? number row cap, defaults to Banking.TransactionLimit, clamped 1..100
---@return table[]|nil rows raw transaction rows ({} when none), nil on a malformed call
exports('getBankTransactions', function(citizenid, limit)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local n
    if limit == nil then
        n = tonumber(config.Banking.TransactionLimit) or 50
    else
        n = tonumber(limit)
        if not util.finite(n) then return nil end
    end
    n = math.floor(n)
    if n < 1 then n = 1 elseif n > 100 then n = 100 end
    return store.recent(citizenid, n)
end)
