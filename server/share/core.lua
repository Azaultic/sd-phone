---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid/name/phone-number lookups.
local player = require 'bridge.server.player'

---@type table Core module; the table returned at end of file.
local core = {}

---@type table<number, boolean> Set of srcs whose phone is currently open (out in hand). Tracked
---in memory from the client's open/close hooks; positions are never cached - they're read live
---at query time.
local openPhones = {}

---Track a player's phone-open state. Self-reported by the owning client, which is safe: being
---"open" only makes THAT player a potential share target (they receive popups); it grants the
---reporter nothing, and every delivery is still gated by the live server-side distance check.
---@param src number player server id
---@param open boolean whether the phone is now open
function core.setOpen(src, open)
    if open then openPhones[src] = true else openPhones[src] = nil end
end

-- AirShare request handshake. A share isn't delivered immediately: the sender opens a request,
-- the recipient gets an accept/decline popup, and only on accept does the per-kind handler run -
-- so nothing ever lands on a phone without its owner's consent. Requests are short-lived (60s),
-- keyed by a monotonically-increasing id, and swept on every new request plus on either party's
-- disconnect, so unanswered ones can't accumulate.
---@type table<string, table> Pending requests: [id] = { kind, fromSrc, target, payload, expires }.
local requests  = {}
---@type table<string, fun(targetSrc: number, payload: table): boolean> Delivery handler per kind.
local handlers  = {}
---@type integer Next request id ordinal.
local nextReqId = 1

---Register the delivery handler for a share kind (e.g. 'contact', 'voice'). Registration is the
---kind whitelist: a request whose kind has no handler is rejected up front.
---@param kind string share kind
---@param fn fun(targetSrc: number, payload: table): boolean delivery function, true on success
function core.registerHandler(kind, fn) handlers[kind] = fn end

---Human noun for a share kind, used in the sender-facing accept/decline notifications. Falls
---back to 'contact' for the contact kind and anything unrecognised.
---@param kind string share kind
---@return string label
local function kindLabel(kind)
    if kind == 'voice' then return 'voice memo' end
    if kind == 'note'  then return 'note' end
    if kind == 'pin'   then return 'map pin' end
    if kind == 'music-track'    then return 'song' end
    if kind == 'music-playlist' then return 'playlist' end
    return 'contact'
end

---Drop every expired pending request. Swept on each new request: before this, a request whose
---recipient never responded (and never disconnected) stayed in memory for the resource's
---lifetime, so spammed requests could grow the table without bound.
local function pruneExpired()
    local now = os.time()
    for id, req in pairs(requests) do
        if now > req.expires then requests[id] = nil end
    end
end

---Open an AirShare request to a nearby, phone-open player. `target` and `kind` are
---client-supplied: the kind must have a registered handler, and the target must pass the live
---canShareTo check (phone open + within config.Share.Range of the sender, measured server-side),
---so a crafted request can't reach an arbitrary player. The payload is held server-side until
---the recipient answers; only the request id, kind and sender name are pushed to the target.
---@param src number sender server id
---@param target any client-supplied recipient server id
---@param kind string share kind
---@param payload table kind-specific share data, handed to the handler on accept
---@return boolean ok, string? message failure reason
function core.request(src, target, kind, payload)
    pruneExpired()
    target = tonumber(target)
    if not target then return false, 'Invalid recipient' end
    if not handlers[kind] then return false, 'Unknown share type' end
    if not core.canShareTo(src, target) then return false, 'Recipient is no longer nearby' end

    local id = ('as%d'):format(nextReqId)
    nextReqId = nextReqId + 1
    requests[id] = { kind = kind, fromSrc = src, target = target, payload = payload, expires = os.time() + 60 }

    TriggerClientEvent('sd-phone:client:airshare:request', target, {
        id = id, kind = kind, fromName = player.getName(src),
    })
    return true
end

---Recipient's accept/decline. Only the request's addressed target may answer - a crafted id from
---anyone else fails the `req.target ~= src` check, so a share can't be stolen or dismissed by a
---third party. The request is consumed either way (idempotent: a replayed answer finds nothing),
---an expired one is refused, and on accept the registered per-kind handler performs the actual
---delivery; the sender is notified of the outcome.
---@param src number responder server id
---@param id any client-supplied request id
---@param accept boolean whether the share was accepted
---@return table result { success, message? }
function core.respond(src, id, accept)
    local req = requests[id]
    if not req or req.target ~= src then return { success = false } end
    requests[id] = nil
    if os.time() > req.expires then return { success = false, message = 'Request expired' } end

    if not accept then
        TriggerClientEvent('sd-phone:client:notify', req.fromSrc, {
            app = 'phone', title = 'AirShare',
            body = ('%s declined your %s.'):format(player.getName(src), kindLabel(req.kind)),
        })
        return { success = true }
    end

    local handler = handlers[req.kind]
    local ok = (handler and handler(src, req.payload)) == true
    if ok then
        TriggerClientEvent('sd-phone:client:notify', req.fromSrc, {
            app = 'phone', title = 'AirShare',
            body = ('%s accepted your %s.'):format(player.getName(src), kindLabel(req.kind)),
        })
    end
    return { success = ok }
end

---Forget a departing player entirely: their open flag and every pending request they sent OR
---were addressed to, so a recycled src can't inherit stale state or answer a ghost request.
---@param src number player server id
function core.clear(src)
    openPhones[src] = nil
    for id, req in pairs(requests) do
        if req.fromSrc == src or req.target == src then requests[id] = nil end
    end
end

---Live ped coords for a player, nil when they have no ped (disconnecting / not spawned).
---@param src number player server id
---@return vector3|nil coords
local function coordsOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

---Players (other than `src`) with their phone open, within config.Share.Range, nearest first,
---capped at config.Share.MaxTargets. Positions are read server-side at query time, never taken
---from the client. Read-only.
---@param src number player server id
---@return { id: number, name: string }[] targets
function core.nearby(src)
    local origin = coordsOf(src)
    if not origin then return {} end

    local range = config.Share.Range
    local found = {}
    for tgt in pairs(openPhones) do
        if tgt ~= src then
            local c = coordsOf(tgt)
            if c then
                local dist = #(origin - c)
                if dist <= range then
                    found[#found + 1] = { id = tgt, name = player.getName(tgt), dist = dist }
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.dist < b.dist end)

    local out = {}
    for i = 1, math.min(#found, config.Share.MaxTargets) do
        out[#out + 1] = { id = found[i].id, name = found[i].name }
    end
    return out
end

---Guard for opening a share request: true only if `target` is a phone-open player within
---config.Share.Range of `src`, measured from live server-side coords. Checked here (not just in
---the client's share-sheet listing) so calling the share callbacks directly can't reach a
---distant or phone-closed player.
---@param src number sender server id
---@param target number recipient server id
---@return boolean allowed
function core.canShareTo(src, target)
    if not openPhones[target] then return false end
    local o, c = coordsOf(src), coordsOf(target)
    if not o or not c then return false end
    return #(o - c) <= config.Share.Range
end

return core
