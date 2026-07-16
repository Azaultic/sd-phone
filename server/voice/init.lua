---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid/name/phone-number lookups.
local player = require 'bridge.server.player'

---@type table Voice config (configs/voice.lua): nearby-capture switches + TURN provisioning.
local CFG   = config.Voice or {}
---@type number Capture radius in metres - how close another player must be to be recordable.
local RANGE = tonumber(CFG.NearbyRange) or 12.0
---@type integer Cap on simultaneous nearby voices mixed into one recording (bandwidth/CPU guard).
local MAXN  = tonumber(CFG.MaxNearbyVoices) or 6
---@type table Public STUN server URLs, always offered to every peer connection.
local STUN  = CFG.StunServers or { 'stun:stun.l.google.com:19302' }
---@type table TURN provisioning config (CFG.Turn): Provider + TtlSeconds.
local TURN  = CFG.Turn or {}

---@return boolean true when nearby-voice capture is switched on (config.Voice.RecordNearbyVoices)
local function enabled() return CFG.RecordNearbyVoices == true end

-- ICE provisioning for the client-to-client WebRTC mesh that captures nearby players' voices
-- into camera videos and Photogram Live. Public STUN is always offered; Cloudflare Realtime TURN
-- relays are appended when configured, so peers on different networks can still connect. The
-- provisioned credential set is cached per player for its lifetime so a recording session
-- doesn't re-hit the Cloudflare API. The audio itself never touches the server.
---@type table<number, { servers: table, expires: number }> Cached ICE servers per player src.
local iceCache = {}

---The always-available STUN portion of an iceServers list, built fresh so callers can append.
---@return table servers array of { urls = string }
local function baseStun()
    local servers = {}
    for _, url in ipairs(STUN) do servers[#servers + 1] = { urls = url } end
    return servers
end

---Provision a Cloudflare Realtime TURN credential set. The long-lived API token lives in server
---convars (sd_cf_turn_token_id / sd_cf_turn_api_token - never in the repo, never sent to any
---client); only the short-lived credential set Cloudflare returns (urls/username/credential,
---TtlSeconds lifetime) is handed out, so a leaked client credential expires on its own. Returns
---nil when unconfigured or on any transport/decode failure.
---@return table|nil iceServers Cloudflare's iceServers object, nil on failure
local function fetchCloudflareTurn()
    local tokenId  = GetConvar('sd_cf_turn_token_id', '')
    local apiToken = GetConvar('sd_cf_turn_api_token', '')
    if tokenId == '' or apiToken == '' then return nil end

    local ttl = tonumber(TURN.TtlSeconds) or 86400
    local p = promise.new()
    PerformHttpRequest(
        ('https://rtc.live.cloudflare.com/v1/turn/keys/%s/credentials/generate-ice-servers'):format(tokenId),
        function(status, body)
            if status ~= 201 or not body then return p:resolve(nil) end
            local ok, decoded = pcall(json.decode, body)
            p:resolve(ok and decoded and decoded.iceServers or nil)
        end,
        'POST',
        json.encode({ ttl = ttl }),
        {
            ['Authorization'] = 'Bearer ' .. apiToken,
            ['Content-Type']  = 'application/json',
            ['Accept']        = 'application/json',
        }
    )
    return Citizen.Await(p)
end

---ICE servers for one player: STUN always, TURN appended when the Cloudflare provider is
---configured. Cached per src until a minute before the provisioned credential actually lapses,
---so repeated recordings don't re-provision - which also means any client can only make the
---server call Cloudflare once per TTL, not once per request. A failed TURN fetch caches the
---STUN-only result for the same window rather than retrying every call.
---@param src number player server id
---@return table servers iceServers array for RTCPeerConnection
local function iceServersFor(src)
    local cached = iceCache[src]
    if cached and cached.expires > os.time() then return cached.servers end

    local servers = baseStun()
    if TURN.Provider == 'cloudflare' then
        local turn = fetchCloudflareTurn()
        if turn then servers[#servers + 1] = turn end
    end

    iceCache[src] = { servers = servers, expires = os.time() + (tonumber(TURN.TtlSeconds) or 86400) - 60 }
    return servers
end

---Live ped coords for a player, nil when they have no ped (disconnecting / not spawned).
---@param src number player server id
---@return vector3|nil coords
local function coordsOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

---True if `a` and `b` are within `range` metres of each other, from live server-side coords -
---false when either has no ped, so a mid-disconnect player can never pass.
---@param a number player server id
---@param b number player server id
---@param range number metres
---@return boolean within
local function withinRange(a, b, range)
    local ca, cb = coordsOf(a), coordsOf(b)
    if not ca or not cb then return false end
    return #(ca - cb) <= range
end

---Players (other than `src`) within RANGE metres, nearest first, capped to MAXN. Positions are
---read server-side at query time; the trimmed result carries only id + display name.
---@param src number recorder server id
---@return { id: number, name: string }[] targets
local function nearbyTargets(src)
    local origin = coordsOf(src)
    if not origin then return {} end

    local found = {}
    for _, pid in ipairs(GetPlayers()) do
        local tgt = tonumber(pid)
        if tgt and tgt ~= src then
            local c = coordsOf(tgt)
            if c then
                local dist = #(origin - c)
                if dist <= RANGE then
                    found[#found + 1] = { id = tgt, name = player.getName(tgt), dist = dist }
                end
            end
        end
    end

    table.sort(found, function(a, b) return a.dist < b.dist end)
    local out = {}
    for i = 1, math.min(#found, MAXN) do
        out[#out + 1] = { id = found[i].id, name = found[i].name }
    end
    return out
end

---ICE servers for this client's peer connections. Read-only; rate-bounded by the per-src cache.
lib.callback.register('sd-phone:server:voice:ice', function(src)
    return { success = true, data = { iceServers = iceServersFor(src) } }
end)

---Who can the recorder capture right now (+ its ICE servers). Proximity is computed entirely
---server-side, so the client can't nominate its own capture list. Empty when the feature is
---disabled - the client then simply records its own voice.
lib.callback.register('sd-phone:server:voice:nearby', function(src)
    if not enabled() then return { success = true, data = { targets = {}, iceServers = iceServersFor(src) } } end
    return { success = true, data = { targets = nearbyTargets(src), iceServers = iceServersFor(src) } }
end)

---Relay one WebRTC signaling message (offer/answer/ICE candidate) to another player. Only this
---tiny signaling text crosses the server - the audio itself flows peer-to-peer. Proximity is
---re-checked on EVERY hop (1.5x RANGE, slack for movement between hops) and the master switch is
---honoured, so a modded client can't use the relay to negotiate a capture of a far-away mic or
---keep signaling while the feature is off. `sid`/`kind`/`data` are opaque session text the
---receiving client validates; `from` is stamped from the trusted source, never from the payload.
---@param payload table { to: number, sid?: any, kind?: any, data?: any }
RegisterNetEvent('sd-phone:server:voice:signal', function(payload)
    local src = source
    if type(payload) ~= 'table' then return end
    local to = tonumber(payload.to)
    if not to or not enabled() then return end
    if not withinRange(src, to, RANGE * 1.5) then return end

    TriggerClientEvent('sd-phone:client:voice:signal', to, {
        from = src,
        sid  = payload.sid,
        kind = payload.kind,
        data = payload.data,
    })
end)

---A departing player's cached ICE credentials are dropped (srcs recycle across sessions).
AddEventHandler('playerDropped', function()
    iceCache[source] = nil
end)
