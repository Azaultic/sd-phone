---CellFrontCamActivate isn't exposed by name in the Lua runtime - invoke the native by hash.
---Flips the active cellphone camera between rear and front (selfie).
---@param activate boolean true = front (selfie) camera
local function CellFrontCamActivate(activate)
    Citizen.InvokeNative(0x2491A93618B7D838, activate)
end

-- Keyboard controls for the viewfinder (control group 0). The cellphone nav controls map to the
-- arrow keys; on top of the clickable NUI controls, these let the camera be driven while the
-- cursor is toggled off (Left Alt).
---@type integer Enter (INPUT_CELLPHONE_SELECT) - press the shutter.
local CTRL_SHOOT  <const> = 176
---@type integer Up arrow (INPUT_CELLPHONE_UP) - flip rear/selfie.
local CTRL_FLIP   <const> = 172
---@type integer Left arrow (INPUT_CELLPHONE_LEFT) - previous capture mode.
local CTRL_PREV   <const> = 174
---@type integer Right arrow (INPUT_CELLPHONE_RIGHT) - next capture mode.
local CTRL_NEXT   <const> = 175
---@type integer E (INPUT_PICKUP) - toggle the flash.
local CTRL_FLASH  <const> = 38
---@type integer Left Alt (INPUT_CHARACTER_WHEEL) - take the cursor back.
local CTRL_CURSOR <const> = 19

---@type boolean True while the native cell-cam view is active.
local active   = false
---@type boolean True while the front (selfie) camera is selected.
local frontCam = false
---@type boolean True while NUI focus (clickable cursor) is on - the phone opens focused; Alt toggles it.
local cursorOn = true
---@type boolean True when entry hid the HUD, so exit owes a DisplayHud(true).
local hidHud   = false
---@type boolean True when entry hid the radar, so exit owes a DisplayRadar(true).
local hidRadar = false
---@type boolean True while the keyboard-control thread is alive - guards a second spawn (see
---startInputLoop).
local inputLoopRunning = false

---Push a key action into the NUI so Camera.tsx reacts exactly as if the matching on-screen
---control was clicked - the keyboard path and the click path share one handler web-side.
---@param key string action name (shutter/flip/flash/modePrev/modeNext)
local function sendKey(key)
    SendNUIMessage({ action = 'sd-phone:camera:key', data = { key = key } })
end

---Keyboard-control loop for the viewfinder. Keys are only read while the cursor is off (Left
---Alt), because with NUI focus on input goes to the page instead (the browser handles
---Alt-to-release; see Camera.tsx - the on-screen control legend is also drawn NUI-side, not as
---a scaleform). Each control's default action is disabled first so e.g. E doesn't try to enter
---a vehicle and Alt doesn't open the character wheel. One loop instance serves consecutive
---camera sessions: the sleeping loop only observes `active` once per frame, so without the
---inputLoopRunning guard a close + reopen inside a single frame would leave the old loop alive
---next to a fresh one and every key press would fire twice.
local function startInputLoop()
    if inputLoopRunning then return end
    inputLoopRunning = true
    CreateThread(function()
        while active do
            Wait(0)
            if not cursorOn then
                DisableControlAction(0, CTRL_CURSOR, true)
                DisableControlAction(0, CTRL_FLASH, true)
                DisableControlAction(0, CTRL_SHOOT, true)
                DisableControlAction(0, CTRL_FLIP, true)
                DisableControlAction(0, CTRL_PREV, true)
                DisableControlAction(0, CTRL_NEXT, true)

                if IsDisabledControlJustPressed(0, CTRL_CURSOR) then
                    cursorOn = true
                    SetNuiFocus(true, true)
                elseif IsDisabledControlJustPressed(0, CTRL_SHOOT) then
                    sendKey('shutter')
                elseif IsDisabledControlJustPressed(0, CTRL_FLIP) then
                    sendKey('flip')
                elseif IsDisabledControlJustPressed(0, CTRL_FLASH) then
                    sendKey('flash')
                elseif IsDisabledControlJustPressed(0, CTRL_PREV) then
                    sendKey('modePrev')
                elseif IsDisabledControlJustPressed(0, CTRL_NEXT) then
                    sendKey('modeNext')
                end
            end
        end
        inputLoopRunning = false
    end)
end

---Take over the view with GTA's NATIVE cellphone camera (CellCamActivate - the NPWD approach).
---The viewfinder itself is a live game-view canvas rendered NUI-side (web/.../Camera.tsx +
---web/src/render/), so capture reads the canvas framebuffer - the phone is never hidden and
---there's no flicker. Firing sd-phone:client:cameraMode first stands the main script's
---third-person hold anim/prop down, because the native cell-cam supplies its own pose + phone
---prop and the two fight otherwise (jittery anim, double phone in hand); CreateMobilePhone puts
---the prop in hand that drives the cell-cam pose. The HUD/radar are hidden only if they weren't
---hidden already, so exit can't un-hide someone else's HUD state. Idempotent while already
---active.
local function enterCameraView()
    if active then return end
    active   = true
    frontCam = false
    cursorOn = true

    TriggerEvent('sd-phone:client:cameraMode', true)

    CreateMobilePhone(1)
    CellCamActivate(true, true)
    CellFrontCamActivate(false)

    if not IsHudHidden()   then hidHud   = true; DisplayHud(false)   end
    if not IsRadarHidden() then hidRadar = true; DisplayRadar(false) end

    startInputLoop()
end

---Tear the cell-cam view down and undo everything enter changed: native camera off, phone prop
---destroyed, and the pose handed back (if the phone's still open or the torch is on, the main
---script resumes the normal "holding a phone" hold anim + prop). The HUD/radar are re-shown
---only if we were the ones who hid them. Leaves the phone focused so it's still usable after
---the camera closes. Idempotent while already inactive.
local function exitCameraView()
    if not active then return end
    active   = false
    frontCam = false

    CellFrontCamActivate(false)
    CellCamActivate(false, false)
    DestroyMobilePhone()

    TriggerEvent('sd-phone:client:cameraMode', false)

    if hidHud   then DisplayHud(true);   hidHud   = false end
    if hidRadar then DisplayRadar(true); hidRadar = false end

    cursorOn = true
    SetNuiFocus(true, true)
end

---Flip between rear and front (selfie) camera. No-op while the cell cam isn't active, so a
---stale NUI toggle can't activate the front cam outside the viewfinder.
---@param on boolean|nil truthy = front camera
local function setSelfie(on)
    if not active then return end
    frontCam = on and true or false
    CellFrontCamActivate(frontCam)
end

-- Flash: a bright point light spawned just in front of the active camera so it actually lights
-- the scene the viewfinder captures. Positioned off the FINAL rendered cam so it works for both
-- the rear and the selfie camera.
---@type boolean True while the flash light should keep drawing.
local flashing = false
---@type boolean True while the flash draw thread is alive - same one-frame respawn guard as the
---keyboard loop (the light must be re-drawn every frame, so a doubled loop would double it).
local flashLoopRunning = false

---Start drawing the flash light every frame until stopFlash clears the flag. The position is
---recomputed per frame from the final rendered camera's coords + rotation, so the light tracks
---view flips and camera movement.
local function startFlash()
    if flashing then return end
    flashing = true
    if flashLoopRunning then return end
    flashLoopRunning = true
    CreateThread(function()
        while flashing do
            local cam = GetFinalRenderedCamCoord()
            local rot = GetFinalRenderedCamRot(2)
            local rx, rz = math.rad(rot.x), math.rad(rot.z)
            local horiz  = math.abs(math.cos(rx))
            local dir    = vector3(-math.sin(rz) * horiz, math.cos(rz) * horiz, math.sin(rx))
            local pos    = cam + dir * 0.6
            DrawLightWithRange(pos.x, pos.y, pos.z, 255, 250, 235, 13.0, 20.0)
            Wait(0)
        end
        flashLoopRunning = false
    end)
end

---Stop the flash loop (the draw thread exits on its next frame).
local function stopFlash()
    flashing = false
end

---React -> Lua: flash toggle from the on-screen control (or the E key relayed back).
RegisterNUICallback('sd-phone:camera:flash', function(data, cb)
    if data and data.on then startFlash() else stopFlash() end
    cb({ success = true })
end)

---React -> Lua: rear/selfie flip from the on-screen control (or the Up key relayed back).
RegisterNUICallback('sd-phone:camera:selfie', function(data, cb)
    setSelfie(data and data.on)
    cb({ success = true })
end)

---React -> Lua: cursor toggle requested from the page (Left Alt while the cursor is on, which
---the game can't read because input is going to CEF). The keyboard loop handles the reverse
---direction, when input is going to the game.
RegisterNUICallback('sd-phone:camera:cursor', function(data, cb)
    local on = data and data.on and true or false
    cursorOn = on
    SetNuiFocus(on, on)
    cb({ success = true })
end)

---React -> Lua: the Camera app mounted - enter the native cell-cam view.
RegisterNUICallback('sd-phone:camera:open', function(_, cb)
    enterCameraView()
    cb({ success = true })
end)

---React -> Lua: the Camera app unmounted - kill the flash and restore the normal view.
RegisterNUICallback('sd-phone:camera:close', function(_, cb)
    stopFlash()
    exitCameraView()
    cb({ success = true })
end)

-- Shutter relay: the NUI hands the captured media over as a base64 data-URL (a JPEG photo, or
-- a webm/mp4 video clip) and it's forwarded to the server over a LATENT event, so the payload
-- is bandwidth-throttled instead of slammed onto the net thread. The server validates the
-- upload, pushes it to Fivemanage and broadcasts photos:added.
---@type integer Latent-event throttle for photos (bytes/sec): ~256 KB/s lands a cropped frame in ~1s.
local PHOTO_BPS <const> = 256 * 1024
---@type integer Latent-event throttle for videos (bytes/sec): ~2 MB/s lands a 1-min clip (~12 MB base64) in ~6s.
local VIDEO_BPS <const> = 2 * 1024 * 1024

---React -> Lua: shutter pressed - relay the captured media to the server. The image must be a
---non-empty string (a data-URL) and the kind is coerced onto the photo/video whitelist before
---it picks the throttle rate; the payload's actual content is validated server-side, where the
---upload happens.
RegisterNUICallback('sd-phone:camera:capture', function(data, cb)
    local image = data and data.image
    if type(image) ~= 'string' or image == '' then
        cb({ success = false, error = 'no-image' })
        return
    end

    local kind = (data and data.kind == 'video') and 'video' or 'photo'
    local bps  = kind == 'video' and VIDEO_BPS or PHOTO_BPS

    TriggerLatentServerEvent('sd-phone:server:photos:upload', bps, image, kind)
    cb({ success = true })
end)

---Safety net: never leave the cell cam active, the flash stuck on, or the player without input
---if the resource stops mid-session.
---@param res string name of the resource that stopped
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        stopFlash()
        exitCameraView()
    end
end)
