---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework   = require 'bridge.shared.framework'
---@type table Inventory resource detection (bridge.shared.inventory_id): first-started candidate.
local inventoryId = require 'bridge.shared.inventory_id'
---@type table Player bridge (bridge.server.player): framework-native player object resolution.
local player_mod  = require 'bridge.server.player'

---@type table Money module; the table returned at end of file. Personal money + black-money
---operations. Black money is the special case: ox_inventory models it as an item (black_money),
---QBCore via the markedbills item with metadata-stored worth, and ESX as a true account - each
---path is dispatched once at module load. Contracts differ on purpose: the black-money debit is
---strict (true means the FULL amount left the player), while add/remove/get keep their legacy
---void/number shapes, so debit callers follow the phone's check-then-move convention (pre-check
---money.get, then remove). Amount hygiene lives with the callers - every server action coerces to
---a positive integer before reaching this layer.
local money = {}

---Normalise caller-passed money type names across frameworks. ESX wants `money` for cash, QBCore
---wants `cash`; both accept `bank` as-is.
---@param t string
---@return string
local function convertType(t)
    if t == 'money' and framework.name == 'qb'  then return 'cash'  end
    if t == 'cash'  and framework.name == 'esx' then return 'money' end
    return t
end

---Credit one of the player's framework accounts (cash, bank, ...). Returns nothing by contract;
---a no-op when the player can't be resolved (disconnected mid-callback).
---@param source number
---@param moneyType string
---@param amount number
---@param reason? string Optional reason string passed to the framework's logger.
function money.add(source, moneyType, amount, reason)
    local p = player_mod.get(source)
    if not p then return end

    if framework.name == 'qb' then
        p.Functions.AddMoney(convertType(moneyType), amount, reason)
    elseif framework.name == 'esx' then
        p.addAccountMoney(convertType(moneyType), amount)
    end
end

---Debit one of the player's framework accounts. Returns nothing by contract, so it CANNOT report
---a declined debit - callers MUST pre-check money.get(src, type) >= amount first, and every
---caller in server/ does (games, ryde, streaks). The qb path's internal decline signal
---(RemoveMoney returning false) is deliberately left unconsumed to keep the legacy void shape.
---@param source number
---@param moneyType string
---@param amount number
---@param reason? string Optional reason string passed to the framework's logger.
function money.remove(source, moneyType, amount, reason)
    local p = player_mod.get(source)
    if not p then return end

    if framework.name == 'qb' then
        p.Functions.RemoveMoney(convertType(moneyType), amount, reason)
    elseif framework.name == 'esx' then
        p.removeAccountMoney(convertType(moneyType), amount)
    end
end

---The player's current balance for one of their accounts. Read-only; 0 (never nil) when the
---player or account can't be resolved, so callers' numeric comparisons stay safe.
---@param source number
---@param moneyType string
---@return number
function money.get(source, moneyType)
    local p = player_mod.get(source)
    if not p then return 0 end

    if framework.name == 'qb' then
        return p.PlayerData.money[convertType(moneyType)] or 0
    elseif framework.name == 'esx' then
        local account = p.getAccount(convertType(moneyType))
        return account and account.money or 0
    end
    return 0
end

---Pick the "read black-money balance" implementation once at module load. ox_inventory counts
---the black_money item; qb-inventory sums every markedbills instance's `info.worth`; ESX reads
---the real account. The inventory bridge is required in-branch so non-ox setups never bind it.
---0 with no supported path.
---@return fun(source: number): number
local function chooseGetBlack()
    if inventoryId.name == 'ox_inventory' then
        local invMod = require 'bridge.server.inventory'
        return function(src) return invMod.count(src, 'black_money') end
    end
    if framework.name == 'qb' and inventoryId.name == 'qb-inventory' then
        return function(src)
            local bills = exports['qb-inventory']:GetItemsByName(src, 'markedbills')
            if not bills then return 0 end
            local worth = 0
            for _, bill in pairs(bills) do
                if bill.info and bill.info.worth then
                    worth = worth + bill.info.worth
                end
            end
            return worth
        end
    end
    if framework.name == 'esx' then
        return function(src)
            local p = player_mod.get(src); if not p then return 0 end
            local account = p.getAccount('black_money')
            return account and account.money or 0
        end
    end
    return function() return 0 end
end

---@type fun(source: number): number Black-money balance reader, bound once at load.
local getBlack = chooseGetBlack()

---The player's current black-money balance. Read-only; 0 when unsupported or unresolvable.
---@param source number
---@return number
function money.getBlack(source) return getBlack(source) end

---Pick the "credit black money" implementation once at module load. The ox path inherits the
---inventory bridge's AddItem result; the qb path mints one markedbills instance whose
---`info.worth` metadata carries the whole amount; ESX credits the account (no failure mode once
---the player resolves). False with no supported path, so a credit that went nowhere never
---reports success.
---@return fun(source: number, amount: number): boolean
local function chooseAddBlack()
    if inventoryId.name == 'ox_inventory' then
        local invMod = require 'bridge.server.inventory'
        return function(src, amount) return invMod.add(src, 'black_money', amount) end
    end
    if framework.name == 'qb' and inventoryId.name == 'qb-inventory' then
        return function(src, amount)
            local p = player_mod.get(src); if not p then return false end
            return p.Functions.AddItem('markedbills', 1, false, { worth = amount })
        end
    end
    if framework.name == 'esx' then
        return function(src, amount)
            local p = player_mod.get(src); if not p then return false end
            p.addAccountMoney('black_money', amount)
            return true
        end
    end
    return function() return false end
end

---@type fun(source: number, amount: number): boolean Black-money credit, bound once at load.
local addBlack = chooseAddBlack()

---Credit black money to the player. Returns true only if the credit landed.
---@param source number
---@param amount number
---@return boolean
function money.addBlack(source, amount) return addBlack(source, amount) end

---Pick the "debit black money" implementation once at module load. The contract every path must
---uphold: true ONLY when the full amount actually left the player - callers credit against this
---answer. The ox path inherits RemoveItem's own held-count check. The qb-inventory path pre-sums
---every bill's worth and refuses outright when the total falls short, so the walk can never
---consume bills and then report failure; a whole bill only counts once its RemoveItem succeeded,
---and a partial consume replaces the last bill (remove, then re-add at the reduced worth) because
---GetItemsByName hands back serialized COPIES across the resource boundary - mutating a copy's
---metadata changes nothing real. Each removal targets the bill's own `slot` field, not its
---position in the returned array. The ESX path reads the account and refuses when short:
---removeAccountMoney subtracts blindly (no floor), so an unchecked call could drive the account
---negative while reporting success. False with no supported path.
---@return fun(source: number, amount: number): boolean
local function chooseRemoveBlack()
    if inventoryId.name == 'ox_inventory' then
        local invMod = require 'bridge.server.inventory'
        return function(src, amount) return invMod.remove(src, 'black_money', amount) end
    end
    if framework.name == 'qb' and inventoryId.name == 'qb-inventory' then
        return function(src, amount)
            local p = player_mod.get(src); if not p then return false end
            local bills = exports['qb-inventory']:GetItemsByName(src, 'markedbills')
            if not bills then return false end

            local total = 0
            for _, bill in pairs(bills) do
                if bill.info and bill.info.worth then total = total + bill.info.worth end
            end
            if total < amount then return false end

            local remaining = amount
            for slot, bill in pairs(bills) do
                if remaining <= 0 then break end
                if bill.info and bill.info.worth then
                    if bill.info.worth <= remaining then
                        if p.Functions.RemoveItem('markedbills', 1, bill.slot or slot) then
                            remaining = remaining - bill.info.worth
                        end
                    elseif p.Functions.RemoveItem('markedbills', 1, bill.slot or slot) then
                        p.Functions.AddItem('markedbills', 1, false, { worth = bill.info.worth - remaining })
                        remaining = 0
                    end
                end
            end
            return remaining == 0
        end
    end
    if framework.name == 'esx' then
        return function(src, amount)
            local p = player_mod.get(src); if not p then return false end
            local account = p.getAccount('black_money')
            if not account or (tonumber(account.money) or 0) < amount then return false end
            p.removeAccountMoney('black_money', amount)
            return true
        end
    end
    return function() return false end
end

---@type fun(source: number, amount: number): boolean Black-money debit, bound once at load.
local removeBlack = chooseRemoveBlack()

---Debit black money from the player. Returns true only when the FULL amount could be debited;
---nothing is consumed on a refusal.
---@param source number
---@param amount number
---@return boolean
function money.removeBlack(source, amount) return removeBlack(source, amount) end

return money
