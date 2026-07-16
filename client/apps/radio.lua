---Frequency (1.0-999.9) maps to an integer pma-voice radio channel: 12.5 -> 125. Radio and
---call channels are independent in pma-voice, so there's no collision with phone calls.
---Anything below the 1.0 floor means "off" and returns channel 0.
---@param freq number|string|nil user-facing frequency
---@return integer channel pma-voice radio channel (0 = leave the radio)
local function freqToChannel(freq)
    local f = tonumber(freq) or 0
    if f < 1.0 then return 0 end
    if f > 999.9 then f = 999.9 end
    return math.floor(f * 10 + 0.5)
end

-- Live session state, seeded from the player's saved prefs on first read. The radio keeps its
-- channel when the phone closes and only leaves when powered off in the app; pma-voice's own
-- push-to-talk key handles transmitting once you're on a channel. `standby` = left the channel
-- from the Dynamic Island (voice dropped) but the island still shows it in red for a quick
-- rejoin, until the app is opened.
---@type table Session radio state: { on: boolean, freq: number, volume: integer, standby: boolean }.
local state  = { on = false, freq = 1.0, volume = 50, standby = false }
---@type boolean True once the saved prefs were fetched (or the fetch failed) - seed only once.
local seeded = false

---Broadcast on/off (+ standby + frequency) to the NUI so the Dynamic Island can show a live
---indicator even when the Radio app (or the whole phone) is closed.
local function pushStatus()
    SendNUIMessage({ action = 'sd-phone:radio:status', data = { on = state.on, freq = state.freq, standby = state.standby } })
end

---Apply the session state to pma-voice (volume + channel; channel 0 when off), announce the
---channel to the server so it can report how many players share it, and push the status to the
---NUI. Both exports are pcall'd so a missing/stopped pma-voice can't error the app. The
---presence announcement is a report, not an authority - the server independently validates
---restricted bands and force-kicks violators (see the forceoff handler).
local function applyVoice()
    local channel = state.on and freqToChannel(state.freq) or 0
    pcall(function() exports['pma-voice']:setRadioVolume(state.volume) end)
    pcall(function() exports['pma-voice']:setRadioChannel(channel) end)
    TriggerServerEvent('sd-phone:server:radio:presence', channel)
    pushStatus()
end

---Fetch the saved frequency/volume once per session. The flag is set BEFORE the await so a
---second caller during the round-trip can't double-seed; a failed fetch simply keeps the
---defaults (deliberately no retry - the save path overwrites them on the next tune anyway).
local function seedFromServer()
    if seeded then return end
    seeded = true
    local res = lib.callback.await('sd-phone:server:radio:get', false)
    if res and res.success and res.data then
        state.freq   = tonumber(res.data.frequency) or state.freq
        state.volume = tonumber(res.data.volume) or state.volume
    end
end

---React -> Lua: current radio state when the app opens. Seeds saved prefs on first read and
---resolves a "standby" (left-from-island) state - the red island indicator clears and the app
---shows the off screen. Also re-announces our channel so the server re-pushes the live
---head-count: the app's count resets every time the phone (re)opens, but the radio stays
---connected while the phone is closed, so the figure must be refreshed here.
RegisterNUICallback('sd-phone:radio:get', function(_, cb)
    seedFromServer()
    if state.standby then
        state.standby = false
        pushStatus()
    end
    TriggerServerEvent('sd-phone:server:radio:presence', state.on and freqToChannel(state.freq) or 0)
    cb({ success = true, data = { on = state.on, freq = state.freq, volume = state.volume } })
end)

---React -> Lua: quick-leave from the Dynamic Island - drop the voice channel but keep the
---frequency and show the island in red (standby) so it can be rejoined. applyVoice does the
---rest: channel 0 (leaves voice), presence 0, and the status push carrying the standby flag.
RegisterNUICallback('sd-phone:radio:leave', function(_, cb)
    state.on = false
    state.standby = true
    applyVoice()
    cb({ success = true })
end)

---React -> Lua: power/tune/volume changes from the app. The desired frequency and power are
---resolved BEFORE anything commits (frequency clamped to 1.0-999.9 and snapped to one decimal,
---volume clamped to 0-100), because job-restricted bands are gated through the server's canTune
---callback when turning on or (re)tuning to a live frequency - a denial leaves the running
---state untouched and hands the app the unchanged state to render. Any explicit set/tune clears
---the island standby. The committed freq + volume are persisted fire-and-forget for the next
---session. The client-side gate is a convenience; the server independently force-kicks
---restricted bands.
RegisterNUICallback('sd-phone:radio:set', function(payload, cb)
    payload = payload or {}

    local newFreq = state.freq
    if payload.freq ~= nil then
        local f = tonumber(payload.freq) or state.freq
        if f < 1.0 then f = 1.0 elseif f > 999.9 then f = 999.9 end
        newFreq = math.floor(f * 10 + 0.5) / 10
    end
    local newOn = state.on
    if payload.on ~= nil then newOn = payload.on == true end

    if newOn and (payload.on == true or payload.freq ~= nil) then
        local res = lib.callback.await('sd-phone:server:radio:canTune', false, newFreq)
        if res and res.allowed == false then
            cb({ success = false, denied = true, message = res.message,
                 data = { on = state.on, freq = state.freq, volume = state.volume } })
            return
        end
    end

    state.freq    = newFreq
    state.on      = newOn
    state.standby = false
    if payload.volume ~= nil then
        local v = math.floor(tonumber(payload.volume) or state.volume)
        if v < 0 then v = 0 elseif v > 100 then v = 100 end
        state.volume = v
    end

    applyVoice()
    lib.callback('sd-phone:server:radio:save', false, function() end, { frequency = state.freq, volume = state.volume })

    cb({ success = true, data = { on = state.on, freq = state.freq, volume = state.volume } })
end)

---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxy = require 'client.nui'

-- Saved-channel CRUD: thin delegates into the Radio server module, which owns the validation
-- (each handler is documented there).
proxy('sd-phone:radio:saved:list',   'sd-phone:server:radio:saved:list')
proxy('sd-phone:radio:saved:add',    'sd-phone:server:radio:saved:add')
proxy('sd-phone:radio:saved:update', 'sd-phone:server:radio:saved:update')
proxy('sd-phone:radio:saved:remove', 'sd-phone:server:radio:saved:remove')

---Best-effort on-air indicator. pma-voice fires this locally when the local player transmits;
---if a build names it differently the handler simply never runs and the indicator stays dark.
---AddEventHandler (not RegisterNetEvent) on purpose - a purely local event stays untriggerable
---from the network.
---@param active boolean whether the local player is transmitting
AddEventHandler('pma-voice:radioActive', function(active)
    SendNUIMessage({ action = 'sd-phone:radio:onair', data = { active = active == true } })
end)

---Head-count of players sharing our channel, pushed by the server - forwarded straight into the
---NUI. Server-pushed, so the payload shape is trusted as-is.
---@param data table head-count payload
RegisterNetEvent('sd-phone:client:radio:count', function(data)
    SendNUIMessage({ action = 'sd-phone:radio:count', data = data })
end)

---The server kicked us off a restricted band (e.g. we lost the job). Leave the channel locally,
---clear standby (a rejoin would be denied anyway) and let the app + island reflect it. The
---server is authoritative here - this handler only makes the local voice state match.
---@param data table denial payload for the app's message
RegisterNetEvent('sd-phone:client:radio:forceoff', function(data)
    state.on = false
    state.standby = false
    pcall(function() exports['pma-voice']:setRadioChannel(0) end)
    SendNUIMessage({ action = 'sd-phone:radio:forceoff', data = data })
    pushStatus()
end)
