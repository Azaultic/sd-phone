---Whether the real lb-phone resource is started. Client-side resource enumeration
---(GetNumResources / GetResourceByFindIndex) only sees STARTED resources, which degrades safely
---for this guard: a started lb-phone enumerates and the shim skips registering (never shadow the
---real thing); a stopped lb-phone does not enumerate, but its client exports are unregistered
---then, so taking the names over is safe.
---@return boolean
local function realLbPhoneStarted()
    for i = 0, GetNumResources() - 1 do
        if GetResourceByFindIndex(i) == 'lb-phone' then return true end
    end
    return false
end

-- Guard, mirroring the server half of the shim: registration proceeds unless sd_phone_lbcompat
-- is explicitly disabled or the real lb-phone is running. GetConvar only reflects the server's
-- value when the convar is replicated (setr); a plain `set` reads the 'true' default here, so
-- the dependable client-side gate is the real-resource check.
local compatConvar = GetConvar('sd_phone_lbcompat', 'true')
if compatConvar == 'false' or compatConvar == '0' or realLbPhoneStarted() then return end

---@type table Self-export proxy for the sd-phone client surface (isOpen / open / close /
---openApp / setDisabled / showNotification), the same pattern client/apps/share.lua uses.
local sd = exports['sd-phone']

---@type table sd-phone config root (configs/config.lua), read here only for the Debug flag.
local config = require 'configs.config'

---@type any[] AddEventHandler cookies for every registered export handler, kept so the
---onClientResourceStart watcher at the bottom of the file can pull the whole registration if
---the real lb-phone starts mid-session.
local exportCookies = {}

---@type any[] Handler cookies for the event bridge (outbound mirrors, inbound lb-phone net
---events, the flashlight tracker), collected apart from the export cookies but pulled by the
---same watcher; RegisterNetEvent and AddEventHandler both return the same removable cookie kind.
local eventCookies = {}

---Register a function on the CLIENT export registry under lb-phone's name, via the same
---__cfx_export event FXServer's exports() helper binds. Other client resources calling
---exports['lb-phone']:Name(...) resolve to fn; the handler receives only the setCB closure.
---The client and server export registries are independent, so this file covers the client
---surface only (server/compat/lbphone owns the server side). The handler cookie is collected
---so the registration can be removed again.
---@param name string PascalCase lb-phone export name
---@param fn function implementation
local function registerLbExport(name, fn)
    exportCookies[#exportCookies + 1] = AddEventHandler(('__cfx_export_lb-phone_%s'):format(name), function(setCB)
        setCB(fn)
    end)
end

---@type table<string, boolean> Surfaces that already warned, so each complains once per session.
local warned = {}

---Print one console breadcrumb the first time an unsupported surface is touched, so a server
---owner can see which lb-phone integrations are running degraded without being spammed.
---@param name string warn key (export name, or name.arg for partially supported arguments)
---@param why string what is unsupported and what happens instead
local function warnOnce(name, why)
    if warned[name] then return end
    warned[name] = true
    print(('[sd-phone:lbcompat] %s %s'):format(name, why))
end

---Register a stubbed lb-phone export: warns once on first call, then returns the fixed safe
---default. A nil result doubles as a plain no-op.
---@param name string PascalCase lb-phone export name
---@param result any fixed return value
---@param why string|nil override for the warning text
local function stubLbExport(name, result, why)
    registerLbExport(name, function()
        warnOnce(name, why or 'has no sd-phone equivalent; returning a safe default')
        return result
    end)
end

---Register a tray-family stub: lb's Show*/Update*/Remove* tray exports answer with a success,
---errorReason pair, so these warn once and fail soft with a reason string instead of a bare
---false.
---@param name string PascalCase lb-phone export name
local function stubLbTrayExport(name)
    registerLbExport(name, function()
        warnOnce(name, 'has no sd-phone tray equivalent; returning false')
        return false, 'not supported'
    end)
end

---@type table<string, true> Every sd-phone app id the home screen knows, mirrored from the
---server shim (server/compat/lbphone/notifications.lua) and web/src/shell/appRegistry.tsx so a
---lowercase lb app name that already matches an sd id passes straight through. Keep in sync
---when apps are added.
local SD_APPS = {}
for _, id in ipairs({
    'photos', 'bank', 'settings', 'clock', 'messages', 'phone', 'calendar', 'mail', 'weather',
    'maps', 'music', 'stocks', 'ryde', 'notes', 'voicememos', 'health', 'compass', 'groups',
    'services', 'pages', 'review', 'marketplace', 'radio', 'darkchat', 'cherry', 'photogram',
    'garages', 'homes', 'calculator', 'passwords', 'cookie', 'wordle', 'flappy', 'blocks',
    'blackjack', 'climber', 'railrunner', 'connectfour', 'chess', 'battleship', 'vibez',
    'weazelnews', 'streaks', 'birdy', 'appstore', 'camera',
}) do SD_APPS[id] = true end

---@type table<string, string> lb-phone app name -> sd-phone app id, for the names that differ.
---Identity names (messages, mail, ...) resolve through SD_APPS instead; duplicates the server
---shim's mapping exactly.
local APP_MAP = {
    twitter     = 'birdy',
    instapic    = 'photogram',
    instagram   = 'photogram',
    trendy      = 'vibez',
    tiktok      = 'vibez',
    tinder      = 'cherry',
    spotify     = 'music',
    wallet      = 'bank',
    garage      = 'garages',
    home        = 'homes',
    yellowpages = 'pages',
}

---Map an lb-phone app name onto an sd-phone app id: known renames first, then a lowercase
---passthrough for names that already match an sd id. Anything else yields nil so callers can
---bail cleanly (OpenApp returns false, SendNotification falls back to a generic banner).
---@param app any lb-phone app id
---@return string|nil
local function mapApp(app)
    if type(app) ~= 'string' or app == '' then return nil end
    local key = app:lower():gsub('%s+', '')
    return APP_MAP[key] or (SD_APPS[key] and key) or nil
end

-- Real mappings: lb-phone client exports whose behaviour sd-phone can genuinely honour.

registerLbExport('IsOpen', function() return sd:isOpen() end)

-- lb-phone distinguishes "on screen" from "focused"; sd-phone has a single open state, which is
-- the closest equivalent for both.
registerLbExport('IsPhoneOnScreen', function() return sd:isOpen() end)

---ToggleOpen(open?, noFocus?): nil toggles, true opens, false closes. sd-phone always opens
---with NUI focus, so noFocus == true is honoured as a normal open and warned once.
registerLbExport('ToggleOpen', function(open, noFocus)
    if noFocus == true then
        warnOnce('ToggleOpen.noFocus', 'noFocus is unsupported; the phone opens with focus as normal')
    end
    if open == nil then open = not sd:isOpen() end
    if open then sd:open() else sd:close() end
end)

registerLbExport('IsDisabled', function() return sd:isDisabled() end)

---ToggleDisabled(disabled): sd setDisabled already coerces to a strict boolean (only literal
---true disables) and force-closes an open phone on disable.
registerLbExport('ToggleDisabled', function(disabled) sd:setDisabled(disabled) end)

---@type {value: string?, at: integer} Own-number cache for GetEquippedPhoneNumber. The number
---changes rarely (character switch), so it refreshes lazily after a minute instead of paying a
---server round trip per call; a failed refresh falls back to the last known value, and nil is
---returned only when the number was never resolvable at all.
local numberCache = { value = nil, at = 0 }

---Drop the cached number the moment the character changes; without this the fallback above
---would keep serving the PREVIOUS character's number. sd-phone has no client-side character
---bridge, so this listens to the framework announcements directly, the same events lb-phone's
---own client framework files hook (qb/qbx load + unload, ESX load + logout). Registering all
---four is harmless: on a framework that never fires them they simply stay silent.
local function clearNumberCache()
    numberCache.value, numberCache.at = nil, 0
end
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', clearNumberCache)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', clearNumberCache)
RegisterNetEvent('esx:playerLoaded', clearNumberCache)
RegisterNetEvent('esx:onPlayerLogout', clearNumberCache)

registerLbExport('GetEquippedPhoneNumber', function()
    if numberCache.value and GetGameTimer() - numberCache.at < 60000 then
        return numberCache.value
    end
    local ok, number = pcall(lib.callback.await, 'sd-phone:server:compat:selfNumber', false)
    if ok and type(number) == 'string' and number ~= '' then
        numberCache.value = number
        numberCache.at = GetGameTimer()
        return number
    end
    return numberCache.value
end)

---HasPhoneItem(number?): ownership is resolved server-side through the same inventory gate the
---keybind open uses. The lb-phone per-number refinement is ignored, sd-phone tracks one number
---per character, so owning any phone item answers the question.
registerLbExport('HasPhoneItem', function(_number)
    local ok, has = pcall(lib.callback.await, 'sd-phone:server:compat:selfHasPhone', false)
    return ok and has == true
end)

---SendNotification(data { app, title, content?, thumbnail? }) -> sd showNotification. The app
---id maps through APP_MAP so a banner aimed at an lb app lands on the sd equivalent, and doubles
---as appId so tapping the banner opens that app. Shape-checked the same way the sd funnel is: a
---non-table payload or missing title is dropped rather than erroring the caller.
registerLbExport('SendNotification', function(data)
    if type(data) ~= 'table' or type(data.title) ~= 'string' then return end
    local app = mapApp(data.app)
    sd:showNotification({
        app   = app,
        appId = app,
        title = data.title,
        body  = data.content,
        image = data.thumbnail,
    })
end)

---OpenApp(app, data?) -> sd openApp. Opens the phone first when closed (queued behind the
---lockscreen, nothing bypasses it); data rides through as the deep-link payload when it is a
---table. Returns false on a bad app name or when the open was refused (dead/swimming/disabled).
registerLbExport('OpenApp', function(app, data)
    local id = mapApp(app)
    if not id then return false end
    return sd:openApp(id, type(data) == 'table' and data or nil)
end)

---CloseApp(options?): sd-phone has no per-app close, and closing the whole phone would be more
---surprising than doing nothing, so this warns once and no-ops.
registerLbExport('CloseApp', function(_options)
    warnOnce('CloseApp', 'has no per-app close in sd-phone; leaving the phone as-is')
end)

---FormatNumber(number): sd-phone stores raw-digit numbers, so formatting is a digit
---normalisation passthrough (matching the server modules' util.digits behaviour, including
---the integral-float guard so 5551234.0 does not strip to a different number).
registerLbExport('FormatNumber', function(number)
    if math.type(number) == 'float' and number % 1 == 0 then
        number = ('%.0f'):format(number)
    end
    return (tostring(number or ''):gsub('%D', ''))
end)

-- Event parity: sd-phone announces state changes to its own client modules via first-party
-- local events; re-fire them under lb-phone's names so third-party client scripts listening for
-- those keep working. Every cookie lands in eventCookies so the mid-session watcher at the
-- bottom silences the event bridge together with the exports.

---lb-phone raises phoneToggled and setOnScreen separately (its phone can be on screen without
---being focused); sd-phone has a single open state, so both mirrors carry the same boolean from
---the one visibility announcement.
eventCookies[#eventCookies + 1] = AddEventHandler('sd-phone:client:openState', function(open)
    TriggerEvent('lb-phone:phoneToggled', open == true)
    TriggerEvent('lb-phone:setOnScreen', open == true)
end)

---lb-phone raises toggleHud(true) while its camera has the game HUD hidden. sd-phone's cell-cam
---really does hide it (client/apps/camera.lua switches HUD + radar off on entry and restores
---them on exit; video calls hide both per frame), and both surfaces announce themselves through
---sd-phone:client:cameraMode, true on enter and false on exit, so that event is the honest
---source. Coerced the same way client/main.lua coerces its own cameraActive state.
eventCookies[#eventCookies + 1] = AddEventHandler('sd-phone:client:cameraMode', function(on)
    TriggerEvent('lb-phone:toggleHud', on and true or false)
end)

---lb-phone re-announces framework job changes client-locally as lb-phone:jobUpdated; its own
---framework files (lb-phone/client/custom/frameworks/{qb,esx}/services.lua) hook these same
---events and fire { job = <name>, grade = <number> }, so the mirrors duplicate that shape
---exactly (qb grades are tables, ESX grades are plain numbers). A malformed payload is dropped
---rather than errored, and on a framework that never fires these the handlers stay silent.
eventCookies[#eventCookies + 1] = RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    if type(job) ~= 'table' or type(job.grade) ~= 'table' then return end
    TriggerEvent('lb-phone:jobUpdated', { job = job.name, grade = job.grade.level })
end)
eventCookies[#eventCookies + 1] = RegisterNetEvent('esx:setJob', function(job)
    if type(job) ~= 'table' then return end
    TriggerEvent('lb-phone:jobUpdated', { job = job.name, grade = job.grade })
end)

---@type boolean Tracked lockscreen beam state, fed by the first-party announcement below.
---Starts false to match the beam's initial state; client/main.lua fires the event on every
---state change, including the setDisabled force-off, so the tracker never needs to poll.
local flashlightOn = false
eventCookies[#eventCookies + 1] = AddEventHandler('sd-phone:client:flashlight', function(on)
    flashlightOn = on == true
end)

registerLbExport('GetFlashlight', function() return flashlightOn end)

---Inbound net event inventory bridges fire AT lb-phone (server-side TriggerClientEvent) when a
---phone item is used. sd-phone has no per-number unique phones, ownership is resolved
---server-side on every open, so the item's info.lbPhoneNumber metadata is ignored and the
---honest mapping is a plain open through the same path as the open export, dead / swimming /
---disabled blocks included.
eventCookies[#eventCookies + 1] = RegisterNetEvent('lb-phone:usePhoneItem', function(_item)
    if config.Debug then
        print('[sd-phone:lbcompat] usePhoneItem received; opening the phone (item payload ignored)')
    end
    sd:open()
end)

---Unique-phone housekeeping: lb-phone equips / unequips a specific number as its item enters or
---leaves the inventory. sd-phone resolves phone ownership server-side per open, so there is
---nothing to equip or unequip; registered as documented no-ops so bridge scripts firing them
---work identically either way.
eventCookies[#eventCookies + 1] = RegisterNetEvent('lb-phone:itemAdded', function() end)
eventCookies[#eventCookies + 1] = RegisterNetEvent('lb-phone:itemRemoved', function() end)

-- Stubs: the rest of lb-phone's client surface, registered so integrations degrade to a single
-- console breadcrumb + a safe default instead of a script error. Grouped by family.

-- Config and settings readers: sd-phone does not expose its config or settings tables to other
-- resources.
stubLbExport('GetConfig', {})
stubLbExport('GetCellTowers', {})
stubLbExport('GetSettings', nil)
stubLbExport('GetStreamerMode', false)

-- Airplane mode lives server-side in phone_settings with no client cache, so this reads as off.
stubLbExport('GetAirplaneMode', false, 'state is server-side only in sd-phone; returning false')

-- Flashlight: GetFlashlight is real, registered next to its tracker in the event bridge above.
-- The torch still has no Lua setter (it is UI-driven state in client/main.lua), so only the
-- toggle stubs.
stubLbExport('ToggleFlashlight', nil, 'has no Lua setter in sd-phone (the torch is UI-driven); GetFlashlight does read the real beam state')

-- Calls: call state is server-authoritative in sd-phone (the client only relays overlay
-- events), and lb-phone's custom-number call family has no equivalent.
stubLbExport('IsInCall', false, 'call state is server-side only in sd-phone; returning false')
stubLbExport('CreateCall', nil, 'is unsupported client-side; use the server CreateCall shim (or the sd-phone startCall export) instead')
stubLbExport('CreateCustomNumber', false)
stubLbExport('RemoveCustomNumber', false)
stubLbExport('CreateDynamicCustomNumber', false)
stubLbExport('RemoveDynamicCustomNumber', false)
stubLbExport('EndCustomCall', false)

-- Open-condition checks (lb-phone's AddCheck blocks opening while a check returns false); use
-- the setDisabled export for the same effect.
stubLbExport('AddCheck', 0, 'is unsupported; use exports["sd-phone"]:setDisabled(true) instead')
stubLbExport('RemoveCheck', false, 'is unsupported; use exports["sd-phone"]:setDisabled(false) instead')

-- Battery is cosmetic and internal to sd-phone, so the family reads as a healthy phone.
stubLbExport('GetBattery', 100)
stubLbExport('SetBattery', nil)
stubLbExport('IsCharging', false)
stubLbExport('ToggleCharging', nil)
stubLbExport('IsPhoneDead', false)

-- Appearance and shell tweaks with no sd-phone counterpart.
stubLbExport('SetPhoneVariation', nil)
stubLbExport('SetServiceBars', nil)
stubLbExport('ReloadPhone', nil)
stubLbExport('ToggleHomeIndicator', nil)
stubLbExport('ToggleLandscape', nil)
stubLbExport('SetAnimations', nil)
stubLbExport('ResetAnimations', nil)

-- Camera family: sd-phone's Camera app drives its own native cell-cam and exposes no external
-- toggles.
stubLbExport('EnableWalkableCam', nil)
stubLbExport('DisableWalkableCam', nil)
stubLbExport('ToggleSelfieCam', nil)
stubLbExport('ToggleCameraFrozen', nil)
stubLbExport('IsWalkingCamEnabled', false)
stubLbExport('IsSelfieCam', false)
stubLbExport('IsCameraOpen', false)
stubLbExport('SetCameraComponent', nil)
stubLbExport('SaveToGallery', nil, 'is unsupported client-side; use the sd-phone server addPhoto export instead')

-- UI component and overlay injection.
stubLbExport('ShowComponent', nil)
stubLbExport('SetPopUp', nil)
stubLbExport('SetContextMenu', nil)

-- Custom apps are not supported by the sd-phone shell.
stubLbExport('AddCustomApp', false, 'custom apps unsupported')
stubLbExport('RemoveCustomApp', false, 'custom apps unsupported')
stubLbExport('SendCustomAppMessage', false, 'custom apps unsupported')

-- Music and live tray surfaces: the whole tray family fails soft with a reason pair.
stubLbTrayExport('ShowMusicTray')
stubLbTrayExport('UpdateMusicTray')
stubLbTrayExport('RemoveMusicTray')
stubLbTrayExport('ShowLiveTray')
stubLbTrayExport('UpdateLiveTray')
stubLbTrayExport('RemoveLiveTray')
stubLbExport('IsLive', false)
stubLbExport('PostBirdy', false)

-- Home-screen management: sd-phone's app grid is not mutable from other resources.
stubLbExport('SetAppHidden', nil)
stubLbExport('SetAppInstalled', nil)

-- Crypto app readers (no sd-phone crypto wallet). GetOwnedCoin's documented return is an
-- OwnedCryptoCoin table or false, so false is the honest miss.
stubLbExport('GetCoinValue', 0)
stubLbExport('GetCryptoWallet', {})
stubLbExport('GetOwnedCoin', false)

-- Notification and contact mutations happen server-side in sd-phone.
stubLbExport('DeleteNotification', false)
stubLbExport('AddContact', false, 'is unsupported client-side; use the sd-phone server contact exports instead')
stubLbExport('UpdateContact', false, 'is unsupported client-side; use the sd-phone server contact exports instead')
stubLbExport('RemoveContact', false, 'is unsupported client-side; use the sd-phone server contact exports instead')
stubLbExport('SetContactModal', nil)

-- Company phone surfaces: messaging a company routes through the sd-phone server messageCompany
-- export; the calls toggle has no equivalent.
stubLbExport('SendCompanyMessage', false, 'is unsupported client-side; use the sd-phone server messageCompany export instead')
stubLbExport('SendCompanyCoords', false, 'is unsupported client-side; use the sd-phone server messageCompany export instead')
stubLbExport('GetCompanyCallsStatus', false)
stubLbExport('ToggleCompanyCalls', false)

-- lb-phone's custom callback wire is out of scope for the shim.
stubLbExport('RegisterClientCallback', nil, 'lb-phone custom callbacks are not bridged')
stubLbExport('TriggerCallback', nil, 'lb-phone custom callbacks are not bridged')
stubLbExport('AwaitCallback', nil, 'lb-phone custom callbacks are not bridged')

---The real lb-phone can be started mid-session (the boot guard above only sees resources that
---were already started). When it does, pull every shim handler, exports and event bridge alike,
---so NEW export lookups resolve to the real lb-phone and the shim stops answering inbound events
---or double-firing lb-phone's outbound ones; resources that already called a shimmed export hold
---a cached reference and keep the shim's functions until lb-phone next stops (the caller's
---export cache invalidates on resource stop).
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'lb-phone' then return end
    for i = 1, #exportCookies do
        RemoveEventHandler(exportCookies[i])
    end
    exportCookies = {}
    for i = 1, #eventCookies do
        RemoveEventHandler(eventCookies[i])
    end
    eventCookies = {}
    print('[sd-phone:lbcompat] the real lb-phone just started, so the compat shim deregistered its client exports and event handlers and new lookups now resolve to lb-phone. Only already-cached callers keep the shim\'s functions until lb-phone next stops.')
end)
