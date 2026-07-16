---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework   = require 'bridge.shared.framework'
---@type table Inventory resource detection (bridge.shared.inventory_id): first-started candidate.
local inventoryId = require 'bridge.shared.inventory_id'
---@type table Player bridge (bridge.server.player): framework-native player object resolution.
local player_mod  = require 'bridge.server.player'

---@type table Inventory module; the table returned at end of file. Server-side inventory
---operations dispatcher: each operation is picked ONCE at module load (bound by the detected
---inventory resource), so call sites are direct calls into the chosen exports rather than
---repeated `if active == ...` chains. `system` exposes the detected resource name (nil =
---framework-native paths) for callers that need to branch on it.
local inventory = { system = inventoryId.name }

-- Inventory resource names, aliased so the choosers read as `active == OX` instead of repeating
-- string literals.
---@type string ox_inventory resource name.
local OX = 'ox_inventory'
---@type string tgiann-inventory resource name.
local TG = 'tgiann-inventory'
---@type string jaksam_inventory resource name.
local JK = 'jaksam_inventory'
---@type string qb-inventory resource name.
local QB = 'qb-inventory'
---@type string qs-inventory-pro resource name.
local QSP = 'qs-inventory-pro'
---@type string qs-inventory resource name.
local QS = 'qs-inventory'
---@type string origen_inventory resource name.
local OG = 'origen_inventory'
---@type string codem-inventory resource name.
local CD = 'codem-inventory'

---@type string|nil Detected inventory resource; nil routes every chooser to the framework paths.
local active = inventoryId.name

---Pick the inventory backend's AddItem implementation once at module load - the active inventory
---doesn't change at runtime, so binding once keeps call sites branch-free. Dedicated backends
---return their own success signal (jaksam's truthy return coerced to a strict boolean); the qs
---family takes slot as its 4th argument, so metadata rides 5th. Framework fallbacks: core ESX's
---addInventoryItem has no failure signal (it enforces no carry limit on add - use canCarry
---first), so a resolved player always reports true there; the qb path returns AddItem's own
---boolean. With no backend at all, always false - a grant that went nowhere must not report
---success.
---@return fun(source: number, item: string, count: number, metadata?: table): boolean
local function chooseAdd()
    if active == OX then
        return function(src, item, count, metadata) return exports[OX]:AddItem(src, item, count, metadata) end
    end
    if active == TG then
        return function(src, item, count, metadata) return exports[TG]:AddItem(src, item, count, metadata) end
    end
    if active == JK then
        return function(src, item, count, metadata)
            local ok = exports[JK]:addItem(src, item, count, metadata)
            return ok or false
        end
    end
    if active == CD then
        return function(src, item, count, metadata) return exports[CD]:AddItem(src, item, count, metadata) end
    end
    if active == QS or active == QSP then
        local inv = active
        return function(src, item, count, metadata) return exports[inv]:AddItem(src, item, count, nil, metadata) end
    end
    if active == OG then
        return function(src, item, count, metadata) return exports[OG]:addItem(src, item, count, metadata) end
    end
    if active == QB then
        return function(src, item, count, metadata) return exports[QB]:AddItem(src, item, count, metadata) end
    end

    if framework.name == 'esx' then
        return function(src, item, count, metadata)
            local p = player_mod.get(src)
            if not p then return false end
            p.addInventoryItem(item, count, metadata)
            return true
        end
    end
    if framework.name == 'qb' then
        return function(src, item, count, metadata)
            local p = player_mod.get(src)
            if not p then return false end
            return p.Functions.AddItem(item, count, nil, metadata)
        end
    end
    return function() return false end
end

---@type fun(source: number, item: string, count: number, metadata?: table): boolean Backend AddItem, bound once at load.
inventory.add = chooseAdd()

---Pick the inventory backend's count-of-item implementation once at module load. Read-only.
---ox_inventory has no direct total, so its path sums the counts of every matching slot from
---Search; the others expose a total directly. Framework fallbacks read the player's item row
---(ESX and qb name the count field differently, hence the `count or amount` probing). Every path
---answers 0 - never nil - when the player or item can't be resolved, so `has` and other numeric
---comparisons at call sites never see nil.
---@return fun(source: number, item: string): number
local function chooseCount()
    if active == OX then
        return function(src, item)
            local items = exports[OX]:Search(src, 'slots', item)
            if type(items) ~= 'table' then return 0 end
            local total = 0
            for _, row in pairs(items) do total = total + (row.count or 0) end
            return total
        end
    end
    if active == TG then return function(src, item) return exports[TG]:GetItemCount(src, item) or 0 end end
    if active == JK then return function(src, item) return exports[JK]:getTotalItemAmount(src, item) or 0 end end
    if active == CD then return function(src, item) return exports[CD]:GetItemsTotalAmount(src, item) or 0 end end
    if active == OG then return function(src, item) return exports[OG]:getItemCount(src, item, false, false) or 0 end end
    if active == QB then return function(src, item) return exports[QB]:GetItemCount(src, item) or 0 end end
    if active == QS or active == QSP then
        local inv = active
        return function(src, item) return exports[inv]:GetItemTotalAmount(src, item) or 0 end
    end

    if framework.name == 'esx' then
        return function(src, item)
            local p = player_mod.get(src); if not p then return 0 end
            local data = p.getInventoryItem(item)
            return data and (data.count or data.amount) or 0
        end
    end
    if framework.name == 'qb' then
        return function(src, item)
            local p = player_mod.get(src); if not p then return 0 end
            local data = p.Functions.GetItemByName(item)
            return data and (data.amount or data.count) or 0
        end
    end
    return function() return 0 end
end

---@type fun(source: number, item: string): number Backend item-count reader, bound once at load.
inventory.count = chooseCount()

---Predicate form of `count` - true when the player has at least `amount` of `item` (default 1).
---Fails closed on a nil item name, so ownership gates built on this can't be passed by a missing
---config value.
---@param source number
---@param item string
---@param amount? number Defaults to 1.
---@return boolean
function inventory.has(source, item, amount)
    if not item then return false end
    return inventory.count(source, item) >= (amount or 1)
end

---Pick the inventory backend's RemoveItem implementation once at module load. Debits must be
---truthful: a `true` from this function means the items actually left the player, because
---money-shaped callers (the black-money debit in bridge.server.money) credit against the answer.
---Dedicated backends report their own result (jaksam coerced to a strict boolean). The qb
---framework fallback drops metadata - qb-core's RemoveItem takes none. The ESX fallback verifies
---the held count BEFORE removing: core ESX's removeInventoryItem silently no-ops when the player
---holds fewer than `count`, which would otherwise report a successful debit that never happened.
---With no backend, always false.
---@return fun(source: number, item: string, count: number, metadata?: table): boolean
local function chooseRemove()
    if active == OX then
        return function(src, item, count, metadata) return exports[OX]:RemoveItem(src, item, count, metadata) end
    end
    if active == TG then
        return function(src, item, count, metadata) return exports[TG]:RemoveItem(src, item, count, metadata) end
    end
    if active == JK then
        return function(src, item, count, metadata)
            local ok = exports[JK]:removeItem(src, item, count, metadata)
            return ok or false
        end
    end
    if active == CD then
        return function(src, item, count, metadata) return exports[CD]:RemoveItem(src, item, count, metadata) end
    end
    if active == OG then
        return function(src, item, count, metadata) return exports[OG]:removeItem(src, item, count, metadata) end
    end
    if active == QB then
        return function(src, item, count, metadata) return exports[QB]:RemoveItem(src, item, count, metadata) end
    end
    if active == QS or active == QSP then
        local inv = active
        return function(src, item, count, metadata) return exports[inv]:RemoveItem(src, item, count, metadata) end
    end

    if framework.name == 'esx' then
        return function(src, item, count, metadata)
            local p = player_mod.get(src); if not p then return false end
            local data = p.getInventoryItem(item)
            local held = data and (data.count or data.amount) or 0
            if held < (tonumber(count) or 0) then return false end
            p.removeInventoryItem(item, count, metadata)
            return true
        end
    end
    if framework.name == 'qb' then
        return function(src, item, count, _metadata)
            local p = player_mod.get(src); if not p then return false end
            return p.Functions.RemoveItem(item, count)
        end
    end
    return function() return false end
end

---@type fun(source: number, item: string, count: number, metadata?: table): boolean Backend RemoveItem, bound once at load.
inventory.remove = chooseRemove()

---Pick the backend's "can the player carry this?" check once at module load. codem exposes no
---such check, so its path optimistically allows - grant paths there rely on AddItem's own result
---instead. ESX has no export either, so we emulate the answer with weight maths from the item's
---registered weight; an item ESX doesn't know at all answers false. With no backend, always
---false: better to refuse a grant than promise space that may not exist.
---@return fun(source: number, item: string, count: number, slot?: any): boolean
local function chooseCanCarry()
    if active == CD then
        return function() return true end
    end
    if active == OX then
        return function(src, item, count, metadata) return exports[OX]:CanCarryItem(src, item, count, metadata) end
    end
    if active == TG then
        return function(src, item, count) return exports[TG]:CanCarryItem(src, item, count) end
    end
    if active == JK then
        return function(src, item, count) return exports[JK]:canCarryItem(src, item, count) end
    end
    if active == OG then
        return function(src, item, count) return exports[OG]:canCarryItem(src, item, count) end
    end
    if active == QB then
        return function(src, item, count) return exports[QB]:CanAddItem(src, item, count) end
    end
    if active == QSP then
        return function(src, item, count) return exports[QSP]:CanCarryItem(src, item, count) end
    end
    if active == QS then
        return function(src, item, count) return exports[QS]:CanCarryItem(src, item, count) end
    end

    if framework.name == 'esx' then
        return function(src, item, count)
            local p = player_mod.get(src); if not p then return false end
            local current = p.getInventoryItem(item)
            if not current then return false end
            local maxW = p.getMaxWeight()
            local curW = p.getWeight()
            return curW + ((current.weight or 0) * count) <= maxW
        end
    end
    if framework.name == 'qb' then
        return function(src, item, count, slot)
            local p = player_mod.get(src); if not p then return false end
            return p.Functions.CanAddItem(item, count, slot)
        end
    end
    return function() return false end
end

---@type fun(source: number, item: string, count: number, slot?: any): boolean Backend carry check, bound once at load.
inventory.canCarry = chooseCanCarry()

---Pick the right "register a usable item" implementation once at module load. ox_inventory has
---no single registration API - it instead dispatches item use to a per-item export on the owning
---resource, so the ox path auto-derives that export name from the item key ('phone' ->
---'usePhone') and registers it, forwarding only the 'usingItem' phase to the callback with the
---holder's inventory id as the source. Other inventories expose their own CreateUsableItem /
---CreateUseableItem, and the framework cores cover the rest. With no path at all, registration
---raises loudly at boot - a phone item that silently can't be used would be undebuggable.
---@return fun(item: string, cb: fun(source: number, item?: any, inv?: table, slot?: any, data?: any)): nil
local function chooseRegisterUsable()
    if active == OX then
        return function(item, cb)
            local exportName = 'use' .. item:gsub('^%l', string.upper)
            exports(exportName, function(event, _item, inv, slot, data)
                if event == 'usingItem' then
                    cb(inv.id, _item, inv, slot, data)
                end
            end)
        end
    end
    if active == QSP then
        return function(item, cb) return exports[QSP]:CreateUsableItem(item, cb) end
    end
    if active == OG then
        return function(item, cb) return exports[OG]:CreateUseableItem(item, cb) end
    end

    if framework.name == 'esx' then
        return function(item, cb) return framework.core.RegisterUsableItem(item, cb) end
    end
    if framework.name == 'qb' then
        return function(item, cb) return framework.core.Functions.CreateUseableItem(item, cb) end
    end

    return function(item)
        error(('inventory.registerUsable: no supported registration path for item %q'):format(item))
    end
end

---@type fun(item: string, cb: function): nil Usable-item registrar, bound once at load.
inventory.registerUsable = chooseRegisterUsable()

---Pick the right item-label resolver once at module load. Falls back to the framework's shared
---items table for backends that don't expose a dedicated label API, and to the raw key when
---nothing knows the item. The ox/tgiann path calls the Items export via pcall since an unknown
---item can throw there.
---@return fun(itemName: string): string|nil
local function chooseLabel()
    if active == OX or active == TG then
        return function(itemName)
            local ok, item = pcall(exports[active].Items, exports[active], itemName)
            return (ok and item) and item.label or itemName
        end
    end
    if active == JK then
        return function(itemName) return exports[JK]:getItemLabel(itemName) or itemName end
    end
    if active == OG then
        return function(itemName) return exports[OG]:GetItemLabel(itemName) or itemName end
    end

    if framework.name == 'qb' then
        return function(itemName)
            local item = framework.core.Shared.Items[itemName]
            return item and item.label or itemName
        end
    end
    if framework.name == 'esx' then
        return function(itemName) return framework.core.GetItemLabel(itemName) or itemName end
    end
    return function(itemName) return itemName end
end

---@type fun(itemName: string): string|nil Label resolver, bound once at load.
local resolveLabel = chooseLabel()
---@type table<string, string> Resolved labels by item key - item definitions don't change at
---runtime, so first lookup wins forever.
local labelCache = {}

---The player-readable label for an item key, falling back to the raw key when the backend has no
---label registered. Cached after first lookup; an empty string for a nil key keeps string
---call sites safe.
---@param itemName string
---@return string
function inventory.label(itemName)
    if not itemName then return '' end
    local cached = labelCache[itemName]
    if cached ~= nil then return cached end

    local label = resolveLabel(itemName) or itemName
    labelCache[itemName] = label
    return label
end

return inventory
