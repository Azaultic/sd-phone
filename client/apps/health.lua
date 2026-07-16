---Resolve the player's current activity state. Cascades from highest intensity downward so a
---sprint also counts as a run also counts as a walk - the most-intense match wins.
---@param ped number
---@return 'dead'|'vehicle'|'sprinting'|'running'|'walking'|'idle'
local function detectState(ped)
    if IsEntityDead(ped) or IsPedDeadOrDying(ped, true) then return 'dead' end
    if IsPedInAnyVehicle(ped, false) then return 'vehicle' end
    if IsPedSprinting(ped) then return 'sprinting' end
    if IsPedRunning(ped)   then return 'running' end
    if IsPedWalking(ped)   then return 'walking' end
    return 'idle'
end

---@type table<string, number> Steps per second by activity state. Cadences chosen so cadence x
---average stride lands at realistic speeds: walking ~5 km/h, running ~12 km/h, sprinting ~18 km/h.
local CADENCE = {
    idle      = 0,
    walking   = 1.83,
    running   = 2.83,
    sprinting = 3.33,
    vehicle   = 0,
    dead      = 0,
}

---@type table<string, integer> Heart-rate target (bpm) the smoother pulls toward, by activity state.
local TARGET_HR = {
    idle      = 70,
    walking   = 90,
    running   = 125,
    sprinting = 160,
    vehicle   = 75,
    dead      = 0,
}

-- Asymmetric low-pass on heart rate - rise quickly (~20s to climb), recover slowly (~90s) -
-- plus a little per-tick jitter so the figure reads like a live sensor.
---@type number Smoothing alpha per nominal tick while the rate is rising.
local HR_ALPHA_RISE = 0.05
---@type number Smoothing alpha per nominal tick while the rate is recovering.
local HR_ALPHA_FALL = 0.02
---@type number Maximum +/- bpm of per-tick jitter.
local HR_JITTER     = 1.5

---@type number Single-tick position deltas (metres) above this are treated as teleports and skipped.
local MAX_TICK_DISTANCE_M = 50.0

---@type integer Sampler cadence in ms - coarse; nothing here is frame-sensitive.
local TICK_MS = 250

---@type table Session running totals: steps, distanceM (on-foot metres), heartRate (bpm), activity state.
local stats = {
    steps     = 0,
    distanceM = 0,
    heartRate = 70,
    state     = 'idle',
}

---Per-tick sampler: classify the ped, accumulate steps + on-foot distance, smooth heart rate
---toward the per-state target. Runs at TICK_MS cadence for the lifetime of the resource (not
---just while the phone is open) so the counts stay continuous. Steps are synthesised from the
---per-state cadence x real elapsed time; distance only accrues while genuinely on foot, and a
---single-tick jump above MAX_TICK_DISTANCE_M is treated as a teleport and skipped. The
---heart-rate alpha is scaled by the real elapsed time over the nominal tick (capped at 1.0) so
---a starved tick can't overshoot the target, and death pins the rate to 0 until revive.
CreateThread(function()
    local lastPos
    local lastTickMs = GetGameTimer()

    while true do
        Wait(TICK_MS)
        local ped = PlayerPedId()
        if DoesEntityExist(ped) then
            local now = GetGameTimer()
            local dt  = (now - lastTickMs) / 1000.0
            lastTickMs = now

            local state = detectState(ped)
            stats.state = state

            stats.steps = stats.steps + (CADENCE[state] * dt)

            local pos = GetEntityCoords(ped)
            if lastPos and (state == 'walking' or state == 'running' or state == 'sprinting') then
                local delta = #(pos - lastPos)
                if delta < MAX_TICK_DISTANCE_M then
                    stats.distanceM = stats.distanceM + delta
                end
            end
            lastPos = pos

            if state ~= 'dead' then
                local target    = TARGET_HR[state]
                local baseA     = (target > stats.heartRate) and HR_ALPHA_RISE or HR_ALPHA_FALL
                local effective = math.min(1.0, baseA * (dt / (TICK_MS / 1000.0)))
                stats.heartRate = stats.heartRate + (target - stats.heartRate) * effective
                stats.heartRate = stats.heartRate + (math.random() - 0.5) * HR_JITTER * 2
            else
                stats.heartRate = 0
            end
        end
    end
end)

---@type boolean True while the phone is on screen (gates the NUI pump below).
local phoneOpen = false

---Push the current stats snapshot into the NUI. Steps floor (a partial step isn't a step);
---heart rate rounds to the nearest bpm.
local function pushSnapshot()
    SendNUIMessage({
        action = 'sd-phone:health',
        data = {
            steps     = math.floor(stats.steps),
            distanceM = stats.distanceM,
            heartRate = math.floor(stats.heartRate + 0.5),
            state     = stats.state,
        },
    })
end

---Phone open/close signal - a local event the phone shell fires (client/main.lua), not a net
---event. One snapshot fires immediately on open so the Health app never shows stale numbers
---while the 1s pump gets going.
---@param open boolean whether the phone is now on screen
AddEventHandler('sd-phone:client:openState', function(open)
    phoneOpen = open
    if open then pushSnapshot() end
end)

-- The sampler above runs for the whole session (step continuity), but the NUI pump only runs
-- while the phone is actually on screen. Coarse (1s) - nothing here is frame-sensitive.
CreateThread(function()
    while true do
        Wait(1000)
        if phoneOpen then pushSnapshot() end
    end
end)
