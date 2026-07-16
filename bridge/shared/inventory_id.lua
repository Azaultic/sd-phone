-- Shared by the client and server inventory bridges so both contexts agree on the same inventory
-- resource without each running its own detection. The FIRST started candidate wins - order
-- matters because some servers ship multiple inventory resources side-by-side during migrations.
---@type string[] Supported inventory resources, in detection-priority order.
local CANDIDATES = {
    'ox_inventory',
    'tgiann-inventory',
    'jaksam_inventory',
    'qs-inventory',
    'qs-inventory-pro',
    'origen_inventory',
    'qb-inventory',
    'ps-inventory',
    'lj-inventory',
    'codem-inventory',
}

---Walk CANDIDATES and return the first inventory resource that's currently started. Nil when no
---supported inventory is running, in which case downstream modules fall back to framework-native
---paths. Read-only; resolved once at require time (inventories don't change at runtime).
---@return string|nil resource name, or nil if none is started.
local function detect()
    for i = 1, #CANDIDATES do
        if GetResourceState(CANDIDATES[i]) == 'started' then
            return CANDIDATES[i]
        end
    end
    return nil
end

-- Module shape: `name` is the detected resource (nil = framework-default paths), `candidates` the
-- priority list for reference.
return {
    name       = detect(),
    candidates = CANDIDATES,
}
