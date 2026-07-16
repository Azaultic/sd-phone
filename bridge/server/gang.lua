---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework  = require 'bridge.shared.framework'
---@type table Player bridge (bridge.server.player): framework-native player object resolution.
local player_mod = require 'bridge.server.player'

---@type table Gang module; the table returned at end of file. Gangs are a QBCore/QBox concept -
---ESX has no equivalent, so every helper here returns its zero/false default on ESX servers and
---any gate built on these fails closed there. `source` must come from the server's own event
---context, never from a client payload.
local gang = {}

---The player's current gang name (QBCore only). Nil when unresolvable or on ESX.
---@param source number player server id
---@return string|nil
function gang.getName(source)
    local p = player_mod.get(source)
    if not p then return nil end
    if framework.name == 'qb' then return p.PlayerData.gang and p.PlayerData.gang.name or nil end
    return nil
end

---The player's current gang grade level (QBCore only). Returns 0 (not nil) when the player or
---grade can't be resolved, so numeric comparisons at call sites never see nil.
---@param source number player server id
---@return integer
function gang.getGrade(source)
    local p = player_mod.get(source)
    if not p then return 0 end
    if framework.name == 'qb' then
        return p.PlayerData.gang and p.PlayerData.gang.grade and p.PlayerData.gang.grade.level or 0
    end
    return 0
end

---Predicate: does the player hold `gangName` at grade >= `minGrade`? Fails closed (false) when
---the player can't be resolved or the framework has no gangs.
---@param source number player server id
---@param gangName string
---@param minGrade? integer Default 0.
---@return boolean
function gang.has(source, gangName, minGrade)
    minGrade = minGrade or 0
    local p = player_mod.get(source)
    if not p then return false end

    if framework.name == 'qb' then
        local data = p.PlayerData.gang
        if data and data.name == gangName then
            return (data.grade and data.grade.level or 0) >= minGrade
        end
    end
    return false
end

---Convenience: true if the player matches any `{ name=..., minGrade=? }` entry. An EMPTY list
---returns true so callers can use it as a default-allow gate (an unset config whitelist means
---everyone) - callers gating something sensitive must pass a non-empty list.
---@param source number player server id
---@param options { name: string, minGrade?: integer }[]
---@return boolean
function gang.hasAny(source, options)
    if not options or #options == 0 then return true end
    for i = 1, #options do
        if gang.has(source, options[i].name, options[i].minGrade or 0) then
            return true
        end
    end
    return false
end

return gang
