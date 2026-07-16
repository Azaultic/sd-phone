---Owner-gated housing actions, run on THIS client on the server bridge's behalf. Some housing
---systems gate lock/key control on the property OWNER - either a client-only export (origen) or
---a net event whose handler reads `source` as the owner (ps-housing, vms_housing). The phone NUI
---runs on the owner, so bridge/server/housing.lua's clientExec awaits this callback instead of
---calling the system directly. Trusted direction: a client lib.callback can only be invoked by
---the server (never by another player), and the server bridge chooses `system` itself from its
---own detection - but every export call is still pcall-wrapped, so a missing/renamed export
---degrades to a no-op result rather than erroring, matching the server bridge's philosophy.
---
---origen's toggleDoor() FLIPS the door, so 'lock' reads getHouseDoor() first and only toggles
---when the current state differs from what was requested - idempotent for replays, and the
---requested state is returned either way. ps-housing / vms_housing 'give'/'remove' fire those
---systems' own owner-gated server events and report true (fire-and-forget; their servers do the
---real permission work). 'keyHolders' normalises whatever row shape ps-housing's callback
---returns to { id, name } pairs for the app, skipping non-table rows, and returns {} on any
---failure. An unhandled system/action pair returns nil so the server bridge treats it as
---unsupported.
---@param system string|nil detected housing resource name (the server bridge's ACTIVE)
---@param action string 'lock'|'give'|'remove'|'keyHolders'
---@param id any property identifier in the active system's own terms
---@param arg any action argument (desired lock state, target server id, or key-holder identifier)
lib.callback.register('sd-phone:client:housing:exec', function(system, action, id, arg)
    if system == 'origen_housing' then
        if action == 'lock' then
            local want = arg and true or false
            local cur
            local ok, door = pcall(function() return exports['origen_housing']:getHouseDoor(id) end)
            if ok and type(door) == 'table' then cur = door.locked end
            if cur == nil or cur ~= want then
                pcall(function() exports['origen_housing']:toggleDoor(id) end)
            end
            return want
        elseif action == 'give' then
            return (pcall(function() exports['origen_housing']:addKeyHolder(id, tonumber(arg)) end)) and true or false
        elseif action == 'remove' then
            return (pcall(function() exports['origen_housing']:removeKeyHolder(id, arg) end)) and true or false
        end

    elseif system == 'ps-housing' then
        if action == 'give' then
            TriggerServerEvent('ps-housing:server:addAccess', id, tonumber(arg))
            return true
        elseif action == 'remove' then
            TriggerServerEvent('ps-housing:server:removeAccess', id, arg)
            return true
        elseif action == 'keyHolders' then
            local ok, list = pcall(function()
                return lib.callback.await('ps-housing:cb:getPlayersWithAccess', false, id)
            end)
            if not ok or type(list) ~= 'table' then return {} end
            local out = {}
            for _, p in pairs(list) do
                if type(p) == 'table' then
                    out[#out + 1] = { id = tostring(p.citizenid or p.id or ''), name = p.name or 'Resident' }
                end
            end
            return out
        end

    elseif system == 'vms_housing' then
        if action == 'give' then
            TriggerServerEvent('vms_housing:sv:giveKey', id, tonumber(arg))
            return true
        elseif action == 'remove' then
            TriggerServerEvent('vms_housing:sv:removeKey', id, arg)
            return true
        end
    end

    return nil
end)

-- Side-effect module: the callback above self-registers; nothing to export.
return {}
