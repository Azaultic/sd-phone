---@type table Maps app config (configs.maps): pin caps, waypoint behaviour, live-location knobs.
local config = require 'configs.maps'
---@type table Notify bridge (bridge.client.notify): local notification popups.
local notify = require 'bridge.client.notify'

---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'

-- Pin persistence proxies: thin delegates into the Maps server module, which owns the validation
-- (pin cap, label length, share targets - each handler is documented there). The GPS waypoint and
-- the live "you are here" dot below are handled entirely client-side; no server round-trip needed.
proxyCallback('sd-phone:maps:list', 'sd-phone:server:maps:list')
proxyCallback('sd-phone:maps:save', 'sd-phone:server:maps:save')
proxyCallback('sd-phone:maps:sharePin', 'sd-phone:server:maps:sharePin')

---React -> Lua: UI-relevant Maps config. `people` gates the whole People tab (live location
---sharing) - when false the web app hides the tab and the chats' location button goes straight
---to the one-time share confirm. Read-only.
RegisterNUICallback('sd-phone:maps:config', function(_, cb)
    cb({ success = true, data = { people = config.People ~= false } })
end)

---An accepted pin AirShare was saved server-side - forward it into the NUI so an open Maps app
---can append it live instead of waiting for a remount. Server-pushed, so the marker shape is
---trusted as-is.
---@param marker table saved pin row
RegisterNetEvent('sd-phone:client:maps:pinAdded', function(marker)
    SendNUIMessage({ action = 'sd-phone:maps:pinAdded', data = marker })
end)

---React -> Lua: set the in-game GPS waypoint to a pin's world coords. Guarded against
---non-numeric input so a malformed payload can't feed the native junk. Optionally closes the
---phone afterward (configs.maps CloseOnWaypoint) so the route is immediately visible on the
---minimap.
RegisterNUICallback('sd-phone:maps:waypoint', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if not x or not y then
        notify.show({ description = 'Could not set waypoint.', type = 'error' })
        cb({ success = false })
        return
    end

    SetNewWaypoint(x + 0.0, y + 0.0)
    notify.show({ description = 'Waypoint set.', type = 'success' })

    if config.CloseOnWaypoint then
        exports['sd-phone']:close()
    end

    cb({ success = true })
end)

---React -> Lua: estimate distance + arrival time to a pin, for the Apple-Maps style directions
---card. Distance prefers the live minimap GPS route length (exact, matches the minimap) while a
---waypoint route is active, then the road-network distance (so the figure still matches a GPS
---route), then straight-line for targets the pathfinder can't reach (an off-road or island
---point). ETA uses a steady cruising speed per travel mode (configs.maps Navigation) so it
---doesn't jump around when you stop; the speed floor guards a nonsense <= 0 config value. The
---card polls this while it's open (Navigation.RefreshInterval). Read-only.
RegisterNUICallback('sd-phone:maps:route', function(data, cb)
    local tx, ty = tonumber(data and data.x), tonumber(data and data.y)
    if not tx or not ty then
        cb({ success = false })
        return
    end

    local nav = config.Navigation or {}
    local ped = PlayerPedId()
    local c   = GetEntityCoords(ped)

    local dist = GetGpsBlipRouteLength()
    if not dist or dist <= 0.0 then
        dist = CalculateTravelDistanceBetweenPoints(c.x, c.y, c.z, tx + 0.0, ty + 0.0, c.z)
    end
    if not dist or dist <= 0.0 then
        dist = #(vector3(c.x, c.y, c.z) - vector3(tx + 0.0, ty + 0.0, c.z))
    end

    local inVeh = IsPedInAnyVehicle(ped, false)
    local speed = inVeh and (nav.DriveSpeed or 16.0) or (nav.WalkSpeed or 1.7)
    if speed <= 0 then speed = 16.0 end

    cb({
        success = true,
        data = {
            distance = dist,
            eta      = dist / speed,
            mode     = inVeh and 'drive' or 'walk',
            units    = nav.Units or 'metric',
        },
    })
end)

---React -> Lua: the player's current world coords. Used when sharing "current location" in
---Messages so the bubble carries a real point the recipient can open in Maps / set a waypoint
---to. Read-only.
RegisterNUICallback('sd-phone:maps:here', function(_, cb)
    local c = GetEntityCoords(PlayerPedId())
    cb({ success = true, data = { x = c.x, y = c.y } })
end)

-- Live "you are here" dot. The React Maps app turns the stream on while it's mounted and off
-- when it closes (mirroring the weather feed's "only poll while needed" pattern): one thread
-- reads the local ped's coords + heading and pushes them to the NUI, stopping the moment the
-- app closes or the phone is put away.
---@type boolean True while the Maps app is on screen and wants position pushes.
local watching = false
---@type boolean True while the stream thread is alive - guards against spawning a second one.
local streamRunning = false
---@type boolean True while a /mapcal calibration run is active (arms the in-app capture banner).
local calArmed = false

---Spawn the position-stream thread unless it's already running. The loop re-checks both the
---watch flag and the phone's open state every tick, so it self-terminates when either drops and
---can be started again cleanly on the next watch(on). Cadence comes from configs.maps
---LiveLocation.Interval - smooth without being chatty.
local function startLocationStream()
    if streamRunning then return end
    streamRunning = true
    CreateThread(function()
        while watching and exports['sd-phone']:isOpen() do
            local ped = PlayerPedId()
            local c = GetEntityCoords(ped)
            SendNUIMessage({
                action = 'sd-phone:maps:location',
                data   = { x = c.x, y = c.y, h = GetEntityHeading(ped) },
            })
            Wait(config.LiveLocation and config.LiveLocation.Interval or 300)
        end
        streamRunning = false
    end)
end

---React -> Lua: start/stop the live-location stream. Fired when the Maps app mounts
---(`on = true`) and unmounts (`on = false`); configs.maps LiveLocation.Enabled = false
---hard-disables the stream no matter what the NUI asks for. Also re-arms the calibration
---banner each time Maps opens while a /mapcal run is in progress - the phone steals NUI focus,
---so the command has to be run with the phone closed, and this restores calib mode on open.
RegisterNUICallback('sd-phone:maps:watch', function(data, cb)
    local enabled = not (config.LiveLocation and config.LiveLocation.Enabled == false)
    watching = enabled and (data and data.on == true) or false
    if watching then
        startLocationStream()
        if calArmed then
            SendNUIMessage({ action = 'sd-phone:maps:calibrate', data = { on = true } })
        end
    end
    cb({ success = true })
end)

-- Map calibration helper (TEMPORARY - remove once the WORLD bounds are locked). /mapcal
-- teleports through a handful of spread, visually-distinct spots and arms the in-app capture
-- banner. At each spot: open the phone -> Maps -> tap the satellite exactly where you really
-- are (ignore the blue dot). The app logs { real = live GPS coord, placed = tap }. Hit Copy in
-- the banner and paste the blob back so the WORLD bounds in data.ts can be solved. /mapcaldone
-- (or the banner's Done button) disarms it.
---@type vector3[] Calibration teleport spots, spread to the map EXTREMES so the linear fit
---anchors its line ends instead of extrapolating from a clustered middle: LSIA runway (far S),
---Chumash coast (far W), Legion Square (centre), RON wind farm (far E), Sandy Shores strip (NE
---centre), Grapeseed (NE) and Paleto Bay pier (far N) bracket the playable square, and each is
---visually distinct enough to find your real spot in the imagery and tap it precisely.
local CAL_POINTS = {
    vec3(-1336.0, -3044.0, 13.9),
    vec3(-3192.0,  1100.0,  4.5),
    vec3(  195.0,  -934.0, 30.7),
    vec3( 2354.0,  1830.0, 38.0),
    vec3( 1735.0,  3315.0, 41.4),
    vec3( 2450.0,  4970.0, 46.0),
    vec3( -275.0,  6620.0, 12.0),
}
---@type integer 1-based index of the last visited calibration point (0 = run not started).
local calIndex = 0

---/mapcal - arm the calibration run and teleport to the next point, wrapping back to the first
---after the last. Ace-restricted (command.mapcal) because it teleports the player: left open,
---any connected player could hop across the map through the calibration spots.
RegisterCommand('mapcal', function()
    calArmed = true
    calIndex = calIndex % #CAL_POINTS + 1
    local p = CAL_POINTS[calIndex]
    local ped = PlayerPedId()
    RequestCollisionAtCoord(p.x, p.y, p.z)
    SetEntityCoords(ped, p.x, p.y, p.z, false, false, false, false)
    notify.show({
        description = ('Calib %d/%d — open Maps, tap your REAL spot, then close & /mapcal.'):format(calIndex, #CAL_POINTS),
        type = 'info',
    })
    print(('[sd-phone:mapcal] point %d/%d -> %.1f, %.1f | open phone > Maps, tap your real spot. /mapcaldone to finish.'):format(
        calIndex, #CAL_POINTS, p.x, p.y))
end, true)

---/mapcaldone - disarm the calibration run so the banner stops reappearing. Left unrestricted
---on purpose: it only clears this client's own local flag, which is a no-op unless a run was
---armed here in the first place.
RegisterCommand('mapcaldone', function()
    calArmed = false
    print('[sd-phone:mapcal] calibration disarmed.')
end, false)

---/maptiles - high-res tile pack verifier (dev tool). After dropping a deep tile pack in (see
---web HIGH_RES_TILES.md), this asks the NUI to probe one tile per zoom level for each style
---(whatever TILE_SOURCES point at - local nui:// pack or CDN) and report which levels loaded,
---so you can confirm the pack is complete and how deep it really goes. Works with the phone
---open or closed. Read-only, so it stays unrestricted.
RegisterCommand('maptiles', function()
    SendNUIMessage({ action = 'sd-phone:maps:tilecheck' })
    notify.show({ description = 'Checking map tiles… results in the F8 console.', type = 'info' })
    print('[sd-phone:maptiles] probing tile levels — results below in a moment…')
end, false)

---NUI -> Lua: the tile-probe results from /maptiles, printed to the F8 console. The per-style
---verdict compares the deepest zoom that actually loaded against the depth enabled in data.ts,
---so a broken base URL, a short pack, or a pack deeper than what's enabled each get called out
---explicitly.
RegisterNUICallback('sd-phone:maps:tilecheckResult', function(data, cb)
    print('[sd-phone:maptiles] ===== map tile check =====')
    for _, s in ipairs(data and data.styles or {}) do
        print(('[sd-phone:maptiles] %s  base=%s  enabled maxZoom=%s'):format(
            tostring(s.name), tostring(s.base), tostring(s.maxZoom)))
        local parts = {}
        for _, lvl in ipairs(s.levels or {}) do
            parts[#parts + 1] = ('z%s:%s'):format(tostring(lvl.z), lvl.ok and 'OK' or '--')
        end
        print('[sd-phone:maptiles]   ' .. table.concat(parts, '  ') .. '   (only z3+ are used by the map)')

        local deepest, maxz = tonumber(s.deepestOk), tonumber(s.maxZoom)
        if deepest and maxz then
            if deepest < 0 then
                print('[sd-phone:maptiles]   FAIL: no tiles loaded — check the base URL / pack folder path.')
            elseif deepest > maxz then
                print(('[sd-phone:maptiles]   NOTE: pack goes deeper than enabled — set maxZoom: %d in data.ts to use it all.'):format(deepest))
            elseif deepest < maxz then
                print(('[sd-phone:maptiles]   WARN: pack shallower than enabled — only z%d loaded; set maxZoom: %d or complete the pack.'):format(deepest, deepest))
            else
                print('[sd-phone:maptiles]   OK: pack matches the enabled depth — all good.')
            end
        end
    end
    cb({ success = true })
end)

---React -> Lua: the in-app calibration "Done" button disarms the run so the banner stops
---reappearing when Maps is reopened.
RegisterNUICallback('sd-phone:maps:calibrateDone', function(_, cb)
    calArmed = false
    cb({ success = true })
end)
