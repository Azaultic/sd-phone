---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Thin delegates: each action proxies straight into its server callback, which owns the
-- validation + ride state (handlers are documented in server/ryde/actions.lua).
proxy('sd-phone:ryde:config',        'sd-phone:server:ryde:config')
proxy('sd-phone:ryde:me',            'sd-phone:server:ryde:me')
proxy('sd-phone:ryde:sync',          'sd-phone:server:ryde:sync')
proxy('sd-phone:ryde:deleteAccount', 'sd-phone:server:ryde:deleteAccount')
proxy('sd-phone:ryde:respond',       'sd-phone:server:ryde:respond')
proxy('sd-phone:ryde:cancel',        'sd-phone:server:ryde:cancel')
proxy('sd-phone:ryde:setOnline',     'sd-phone:server:ryde:setOnline')
proxy('sd-phone:ryde:requestsBoard', 'sd-phone:server:ryde:requestsBoard')
proxy('sd-phone:ryde:waitingCount',  'sd-phone:server:ryde:waitingCount')
proxy('sd-phone:ryde:watchTrip',     'sd-phone:server:ryde:watchTrip')
proxy('sd-phone:ryde:accept',        'sd-phone:server:ryde:accept')
proxy('sd-phone:ryde:tripStatus',    'sd-phone:server:ryde:tripStatus')
proxy('sd-phone:ryde:sameVehicle',   'sd-phone:server:ryde:sameVehicle')
proxy('sd-phone:ryde:complete',      'sd-phone:server:ryde:complete')
proxy('sd-phone:ryde:rate',          'sd-phone:server:ryde:rate')
proxy('sd-phone:ryde:history',       'sd-phone:server:ryde:history')
proxy('sd-phone:ryde:leaderboard',   'sd-phone:server:ryde:leaderboard')

---Is the player within `radius` metres (2D) of a world point? Gates the driver's "I've arrived
---at pickup" button to the actual pickup spot. Purely advisory UI state - trip milestones that
---matter (completion, payment) are validated server-side. Missing coords answer not-near with
---a -1 distance sentinel rather than erroring.
---@param payload table { x: number, y: number, radius?: number (default 100.0) }
RegisterNUICallback('sd-phone:ryde:nearPoint', function(payload, cb)
    payload = payload or {}
    local px, py = tonumber(payload.x), tonumber(payload.y)
    if not (px and py) then cb({ near = false, distance = -1 }); return end
    local c = GetEntityCoords(PlayerPedId())
    local dx, dy = c.x - (px + 0.0), c.y - (py + 0.0)
    local dist = math.sqrt(dx * dx + dy * dy)
    cb({ near = dist <= (tonumber(payload.radius) or 100.0), distance = math.floor(dist + 0.5) })
end)

---Friendly area name for a world point, e.g. "Vinewood", "Del Perro". The zone *code*
---GetNameOfZone returns ("VINE") doubles as a GXT label key, so GetLabelText turns it into the
---display name (same trick garages.lua uses for vehicles). Falls back to the raw code, then a
---generic, if a zone has no label.
---@param x number world x
---@param y number world y
---@param z number|nil world z (0.0 when absent)
---@return string name display label, raw zone code, or 'Unknown area'
local function zoneName(x, y, z)
    local code = GetNameOfZone(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
    if not code or code == '' then return 'Unknown area' end
    local label = GetLabelText(code)
    if label and label ~= '' and label ~= 'NULL' then return label end
    return code
end

---@type table<string, boolean> Generic, meaningless-to-the-driver dropoff placeholders that get
---swapped for the zone name. A destination the rider actually named (e.g. "Legion Square") is
---left alone.
local GENERIC_LABELS = {
    ['Current location'] = true, ['Dropped pin'] = true, ['Destination'] = true, [''] = true,
}

---The rider only picks a destination in the UI; the pickup is wherever they're standing, so the
---live world position is stamped in before forwarding (never trusted from the NUI). Both ends
---get a zone name so the driver sees "Vinewood - Del Perro", not "Current location". Fares and
---matching are validated in server/ryde/actions.lua.
---@param payload table ride request draft from the UI (dropoff label/coords)
RegisterNUICallback('sd-phone:ryde:requestRide', function(payload, cb)
    payload = payload or {}
    local coords = GetEntityCoords(PlayerPedId())
    payload.pickup = { label = zoneName(coords.x, coords.y, coords.z), x = coords.x, y = coords.y }
    local d = payload.dropoff
    if d and d.x and d.y and GENERIC_LABELS[d.label or ''] then
        d.label = zoneName(d.x, d.y, 0.0)
    end
    cb(lib.callback.await('sd-phone:server:ryde:requestRide', false, payload) or { success = false })
end)

---Friendly zone name for an arbitrary world point, so a map-dropped destination can be labelled
---"Vinewood" instead of "Dropped pin" (subtitle stays custom). Read-only.
---@param payload table { x: number, y: number }
RegisterNUICallback('sd-phone:ryde:zoneName', function(payload, cb)
    payload = payload or {}
    local x, y = tonumber(payload.x), tonumber(payload.y)
    if not (x and y) then cb({ success = false }); return end
    cb({ success = true, data = { name = zoneName(x, y, 0.0) } })
end)

---Register a server-push relay: 'sd-phone:client:ryde:<event>' forwards unchanged into the NUI
---under 'sd-phone:ryde:<event>'. Server-originated (trusted); only an open Ryde app reacts.
---@param event string event suffix, e.g. 'offer'
local function forward(event)
    RegisterNetEvent('sd-phone:client:ryde:' .. event, function(data)
        SendNUIMessage({ action = 'sd-phone:ryde:' .. event, data = data })
    end)
end

-- Thin relays for the live match pushes: board changes, offers, ratings, peer GPS.
forward('requestAdded')
forward('requestRemoved')
forward('waitingCount')
forward('offer')
forward('offerRemoved')
forward('ratingReceived')
forward('peerLocation')

---Trip updates also drop a GPS waypoint for the driver - to the pickup once the rider accepts,
---then to the destination once the rider's aboard. Riders (role ~= 'driver') only get the NUI
---relay; the server decides when a waypoint is attached.
---@param data table { role: string, waypoint?: { x: number, y: number } } plus trip fields
RegisterNetEvent('sd-phone:client:ryde:tripUpdate', function(data)
    SendNUIMessage({ action = 'sd-phone:ryde:tripUpdate', data = data })
    if data and data.role == 'driver' and data.waypoint then
        SetNewWaypoint(data.waypoint.x + 0.0, data.waypoint.y + 0.0)
    end
end)
