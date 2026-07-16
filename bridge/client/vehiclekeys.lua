---@type string[] Supported vehicle-key resources, in detection-priority order.
local RESOURCES = { 'qbx_vehiclekeys', 'qb-vehiclekeys', 'qs-vehiclekeys', 'vehicles_keys', 'mk_vehiclekeys' }

---@type table Vehicle-lock module; the table returned at end of file. The supported resources
---are KEY systems - they decide who may lock a vehicle - and none of them exposes an "is this
---plate locked" query; they all toggle the lock through the GTA native SetVehicleDoorsLocked, so
---the authoritative lock STATE is the entity's GetVehicleDoorLockStatus, which is correct no
---matter which of them is running. We therefore read the live entity by plate. That only works
---for a vehicle currently streamed near the player (an `out` vehicle you're at); stored or
---far-away vehicles have no client entity, so those reads return nil and the caller keeps its
---sensible default (stored = locked).
local M = {}

---Resource name of the running key system, or nil. Checked at call time so resource start-order
---doesn't matter.
---@return string|nil
function M.active()
    for i = 1, #RESOURCES do
        if GetResourceState(RESOURCES[i]) == 'started' then return RESOURCES[i] end
    end
    return nil
end

---Normalise a plate for comparison: trailing whitespace stripped, uppercased (GTA pads plate
---text with trailing spaces and is case-insensitive about it). Non-strings normalise to '' so a
---bad input can never accidentally match a real plate.
---@param p any candidate plate value
---@return string normalised plate ('' when unusable)
local function norm(p)
    return type(p) == 'string' and (p:gsub('%s+$', ''):upper()) or ''
end

---The spawned vehicle entity for a plate, or nil if none is streamed nearby. A linear scan of
---the local vehicle pool - plates aren't indexed client-side, and the pool near one player is
---small enough that this stays cheap.
---@param plate string
---@return number|nil veh
local function findByPlate(plate)
    local want = norm(plate)
    if want == '' then return nil end
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) and norm(GetVehicleNumberPlateText(veh)) == want then
            return veh
        end
    end
    return nil
end

---Live lock state for a plate, read off the spawned entity. Lock status 0 means the game doesn't
---know (treated as undeterminable), 1 is unlocked, and 2 plus the other lock variants (3, 4, 7,
---8...) all mean locked. Requires a key system to be running - without one the phone has no
---business reporting lock state. Read-only.
---@param plate string
---@return boolean|nil locked true = locked, false = unlocked, nil = undeterminable
function M.isLocked(plate)
    if not M.active() then return nil end
    local veh = findByPlate(plate)
    if not veh then return nil end
    local status = GetVehicleDoorLockStatus(veh)
    if type(status) ~= 'number' or status == 0 then return nil end
    return status >= 2
end

---Generic fob acknowledgement for key systems we don't drive natively: flash the hazards (both
---indicators - index 0 is the right, 1 the left) twice when locking, once when unlocking. Lights
---only - StartVehicleHorn plays the full car horn, not a subtle chirp, so it reads as obnoxious.
---Runs in its own thread so the Wait()s don't block the caller.
---@param veh number
---@param locked boolean
local function blip(veh, locked)
    local flashes = locked and 2 or 1
    CreateThread(function()
        for i = 1, flashes do
            SetVehicleIndicatorLights(veh, 0, true)
            SetVehicleIndicatorLights(veh, 1, true)
            Wait(190)
            SetVehicleIndicatorLights(veh, 0, false)
            SetVehicleIndicatorLights(veh, 1, false)
            if i < flashes then Wait(150) end
        end
    end)
end

---A quick headlight flash, replicating qbx_vehiclekeys' own toggleLock acknowledgement. Paired
---with its 'Remote_Control_Fob' beep at the call site. Runs in its own thread so the Wait()s
---don't block the caller.
---@param veh number
local function fobLights(veh)
    CreateThread(function()
        SetVehicleLights(veh, 2)
        Wait(250)
        SetVehicleLights(veh, 1)
        Wait(200)
        SetVehicleLights(veh, 0)
    end)
end

---Lock or unlock the nearby spawned vehicle for a plate. Network control is requested first,
---best effort, so the lock + lights replicate to other players (the local feedback shows
---regardless). On qbx_vehiclekeys we drive ITS lock path - the same
---'qb-vehiclekeys:server:setVehLockState' server event the key fob fires (2 = lock, 1 = unlock;
---its server sets the statebag and every client syncs the door lock from it), the exact
---'Remote_Control_Fob' key-fob beep, and the headlight flash - so the phone is indistinguishable
---from pressing the lock key. Other key systems fall back to the native door lock + a silent
---hazard flash. Returns nil if the car isn't streamed nearby.
---@param plate string
---@param locked boolean true = lock, false = unlock
---@return boolean|nil locked the applied state, or nil if no nearby entity
function M.setLocked(plate, locked)
    local veh = findByPlate(plate)
    if not veh then return nil end
    if NetworkGetEntityIsNetworked(veh) and not NetworkHasControlOfEntity(veh) then
        NetworkRequestControlOfEntity(veh)
    end

    local lockstate = locked and 2 or 1
    if M.active() == 'qbx_vehiclekeys' then
        TriggerServerEvent('qb-vehiclekeys:server:setVehLockState', NetworkGetNetworkIdFromEntity(veh), lockstate)
        PlaySoundFromEntity(-1, 'Remote_Control_Fob', veh, 'PI_Menu_Sounds', false, 0)
        fobLights(veh)
    else
        SetVehicleDoorsLocked(veh, lockstate)
        blip(veh, locked)
    end
    return locked
end

return M
