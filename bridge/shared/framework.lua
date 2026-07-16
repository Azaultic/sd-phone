---@class FrameworkInfo
---@field name 'qb'|'esx' Detected framework identifier.
---@field core any Live core object (`exports['qb-core']:GetCoreObject()` or ESX shared object).

---Detect which player framework is running and return a populated FrameworkInfo, or nil when
---neither qb-core nor es_extended is started. Resolved ONCE at first require - frameworks don't
---change at runtime - so every other bridge module dispatches on the cached `framework.name`.
---QBox counts as 'qb': qbx_core provides the 'qb-core' resource name and a compatible core object,
---so the same detection + API path covers both.
---@return FrameworkInfo|nil
local function detect()
    if GetResourceState('qb-core') == 'started' then
        return { name = 'qb', core = exports['qb-core']:GetCoreObject() }
    end
    if GetResourceState('es_extended') == 'started' then
        return { name = 'esx', core = exports['es_extended']:getSharedObject() }
    end
    return nil
end

---@type FrameworkInfo|nil Detection result; a nil here aborts the resource load below, on purpose -
---every bridge module (and every permission gate built on them) is meaningless without a framework.
local info = detect()

if not info then
    error([[
        ^1CRITICAL ERROR: No supported framework detected!^0
        ^3This resource requires one of the following frameworks:^0
        - QBCore (qb-core)
        - ESX (es_extended)

        Please ensure your framework is started before this resource.
    ]])
end

print(('^2[SD-PHONE]^0 Framework detected: ^3%s^0'):format(info.name))

return info
