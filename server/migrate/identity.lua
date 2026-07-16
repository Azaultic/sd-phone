---@type table Identity resolution for the lb-phone import (server.migrate.identity). lb-phone keys
---its data on the phone number and ties a phone to a player through phone_phones.owner_id (a
---framework identifier); sd-phone keys everything on citizenid. This module bridges the two: it
---reads every lb-phone phone once, resolves each owner id to an sd-phone citizenid, and hands the
---porters two lookups - the list of resolved phones (to adopt numbers) and a number -> citizenid
---map (so calls / messages can find the mailbox owner for any number).
local identity = {}

local store = require 'server.migrate.store'

---Strip a value to bare digits ('' when nil / digit-free), matching how sd-phone stores numbers.
---@param s any
---@return string
local function digits(s) return (tostring(s or ''):gsub('%D', '')) end

---A 4-6 digit lock code, or nil. lb-phone pins are 4 digits; sd-phone accepts 4-6, so this both
---validates and drops anything that is not a usable code.
---@param v any
---@return string|nil
local function pinOf(v)
    if type(v) ~= 'string' then return nil end
    return v:match('^%d%d%d%d%d?%d?$')
end

---Resolve one lb-phone owner id to an sd-phone citizenid under the configured mode. Returns the
---citizenid, or nil plus a reason ('unresolved' when no character matches, 'ambiguous' when an
---owner license maps to several characters and we refuse to guess).
---@param ownerId string
---@param roster { cids: table<string, boolean>, licenseToCids: table<string, string[]> }
---@param mode 'auto'|'citizenid'|'license'
---@return string|nil citizenid, string|nil reason
local function resolveOwner(ownerId, roster, mode)
    if not ownerId or ownerId == '' then return nil, 'unresolved' end

    if mode == 'citizenid' then
        return roster.cids[ownerId] and ownerId or nil, 'unresolved'
    end

    -- 'auto' tries a direct citizenid match first (the common, unambiguous case), then falls
    -- through to the license path; 'license' skips straight to it.
    if mode == 'auto' and roster.cids[ownerId] then return ownerId, nil end

    local bucket = roster.licenseToCids[ownerId]
    if not bucket then return nil, 'unresolved' end
    if #bucket > 1 then return nil, 'ambiguous' end
    return bucket[1], nil
end

---Build the identity context: read every lb-phone phone, resolve owners, and produce the lookups
---the porters use. Also tallies how many phones resolved / were unresolved / were ambiguous, for
---the boot log.
---@param cfg table config.Migrate
---@param framework { name: 'qb'|'esx' }
---@return { resolvedPhones: { cid: string, number: string, pin: string|nil }[], numberToCid: table<string, string>, cids: string[], stats: { total: number, resolved: number, unresolved: number, ambiguous: number } }
function identity.build(cfg, framework)
    local roster = store.loadRoster(framework.name)
    local phones = store.lbPhones()

    local resolvedPhones, numberToCid, cidSeen, cids = {}, {}, {}, {}
    local stats = { total = #phones, resolved = 0, unresolved = 0, ambiguous = 0 }

    for _, p in ipairs(phones) do
        local cid, reason = resolveOwner(p.owner_id, roster, cfg.identifierMode or 'auto')
        if cid then
            local number = digits(p.phone_number)
            resolvedPhones[#resolvedPhones + 1] = { cid = cid, number = number, pin = pinOf(p.pin) }
            if number ~= '' then numberToCid[number] = cid end
            if not cidSeen[cid] then cidSeen[cid] = true; cids[#cids + 1] = cid end
            stats.resolved = stats.resolved + 1
        elseif reason == 'ambiguous' then
            stats.ambiguous = stats.ambiguous + 1
        else
            stats.unresolved = stats.unresolved + 1
        end
    end

    return { resolvedPhones = resolvedPhones, numberToCid = numberToCid, cids = cids, stats = stats }
end

return identity
