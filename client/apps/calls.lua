---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'

-- Thin delegates: each call action proxies straight into its server callback, which owns the
-- validation + call state (handlers are documented in server/calls/actions.lua).
proxyCallback('sd-phone:call:dial',    'sd-phone:server:call:dial')
proxyCallback('sd-phone:call:accept',  'sd-phone:server:call:accept')
proxyCallback('sd-phone:call:decline', 'sd-phone:server:call:decline')
proxyCallback('sd-phone:call:hangup',  'sd-phone:server:call:hangup')
proxyCallback('sd-phone:call:current', 'sd-phone:server:call:current')

---Forward a server call event straight into the React call overlay.
---@param action string NUI action name
---@param data any payload forwarded unchanged
local function pushCall(action, data)
    SendNUIMessage({ action = action, data = data })
end

---Incoming call. Force the phone open (mirroring a real handset lighting up) so the ringing UI
---is visible even if the phone was put away. The brief wait lets the React tree mount its
---call-event listener before the incoming message is pushed - otherwise a cold open races the
---first paint and the ring can be missed.
---@param data table incoming-call payload from the server
RegisterNetEvent('sd-phone:client:call:incoming', function(data)
    exports['sd-phone']:open()
    Wait(200)
    pushCall('sd-phone:call:incoming', data)
end)

-- Call-lifecycle relays: outgoing ring-back, connect, and end push straight into the React
-- overlay (incoming above is special-cased to force the phone open first).
RegisterNetEvent('sd-phone:client:call:outgoing', function(data)
    pushCall('sd-phone:call:outgoing', data)
end)

RegisterNetEvent('sd-phone:client:call:connected', function(data)
    pushCall('sd-phone:call:connected', data)
end)

RegisterNetEvent('sd-phone:client:call:ended', function(data)
    pushCall('sd-phone:call:ended', data)
end)

---CELL_CAM_ACTIVATE_SELFIE_MODE, bound by hash (no friendly name in the natives table): flips
---the active cell-cam between the rear and front (selfie) lens.
---@param on boolean true for the front (selfie) lens
local CellFrontCamActivate = function(on) Citizen.InvokeNative(0x2491A93618B7D838, on) end

---@type boolean Whether the native cell-cam currently owns the local view (video call active).
local videoCamActive = false

---Toggle the native cell-cam takeover for a video call: the selfie cam owns the local view so
---the WebRTC canvas captures the player's face, which the NUI streams to the peer (audio stays
---on the existing pma-voice call). On activate, the main script's third-person hold pose is
---stood down first - the cell-cam supplies its own pose + phone prop, and without the yield the
---two fight every frame and flicker (same guard the Camera app uses); CreateMobilePhone drives
---the cell-cam pose, and a helper thread hides the HUD each frame while active. `front` defaults
---to the front (selfie) lens. On deactivate, the cam and prop are torn down and the hold pose is
---handed back (it only re-applies if the phone is still out / the torch is on). Idempotent per
---direction: re-enabling while already active only switches the lens.
---@param on boolean|nil activate (truthy) or deactivate
---@param front boolean|nil front lens (default true); false switches to the rear lens
local function setVideoCamera(on, front)
    if on then
        if not videoCamActive then
            videoCamActive = true
            TriggerEvent('sd-phone:client:cameraMode', true)
            CreateMobilePhone(4)
            CellCamActivate(true, true)
            CreateThread(function()
                while videoCamActive do
                    Wait(0)
                    HideHudAndRadarThisFrame()
                end
            end)
        end
        CellFrontCamActivate(front ~= false)
    elseif videoCamActive then
        videoCamActive = false
        CellCamActivate(false, false)
        DestroyMobilePhone()
        TriggerEvent('sd-phone:client:cameraMode', false)
    end
end

-- NUI to server one-way signaling (request/accept/stop/signal): fire-and-forget events for low
-- latency; the server verifies both ends share the live call before relaying to the peer.
RegisterNUICallback('sd-phone:video:request', function(_, cb) TriggerServerEvent('sd-phone:server:call:video:request'); cb('ok') end)
RegisterNUICallback('sd-phone:video:accept',  function(_, cb) TriggerServerEvent('sd-phone:server:call:video:accept');  cb('ok') end)
RegisterNUICallback('sd-phone:video:stop',    function(_, cb) TriggerServerEvent('sd-phone:server:call:video:stop');    cb('ok') end)
RegisterNUICallback('sd-phone:video:signal',  function(data, cb) TriggerServerEvent('sd-phone:server:call:video:signal', data); cb('ok') end)

---ICE server config for the WebRTC peer connection (request/response). The server assembles it
---from convars so the TURN credentials never live in the NUI bundle; an empty list is a safe
---fallback (direct connection attempt only).
RegisterNUICallback('sd-phone:video:config', function(_, cb)
    cb(lib.callback.await('sd-phone:server:call:video:config', false) or { iceServers = {} })
end)

---Selfie-cam takeover toggle, driven by the video UI mounting / unmounting. Nil-guarded so a
---malformed payload just deactivates rather than erroring the NUI callback.
---@param data table { on: boolean, front?: boolean }
RegisterNUICallback('sd-phone:video:camera', function(data, cb)
    setVideoCamera(data and data.on, data and data.front)
    cb('ok')
end)

-- Server to NUI relays: the peer's video request/accept/stop and signaling messages forward
-- unchanged into the React call overlay.
RegisterNetEvent('sd-phone:client:call:video:request', function()      pushCall('sd-phone:video:request', nil) end)
RegisterNetEvent('sd-phone:client:call:video:accept',  function()      pushCall('sd-phone:video:accept',  nil) end)
RegisterNetEvent('sd-phone:client:call:video:stop',    function()      pushCall('sd-phone:video:stop',    nil) end)
RegisterNetEvent('sd-phone:client:call:video:signal',  function(data)  pushCall('sd-phone:video:signal',  data) end)
