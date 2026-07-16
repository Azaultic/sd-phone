---@type table Player bridge (bridge.server.player): citizenid/name/job lookups from a server id.
local player = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): phone_settings row CRUD plus
---custom tones and per-app notification prefs, all keyed by citizenid.
local store  = require 'server.settings.store'

-- Schema bootstrap. Threaded so it yields until oxmysql is ready without blocking resource
-- start; a failure is printed and swallowed so the rest of the phone still boots.
CreateThread(function()
    local success, err = pcall(store.ensureSchema)
    if not success then
        print(('^1[sd-phone:settings]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:settings]^0 schema ready')
end)

---Server export: another resource asks for a player's phone number by server id, assigning one
---on first access. Server-to-server only (exports are not reachable from clients), so `source`
---is whatever the calling resource passes; identity still resolves through the player bridge and
---an unresolvable player yields nil rather than a number.
---@param source number player server id
---@return string|nil number raw-digit phone number
exports('getPhoneNumber', function(source)
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    return store.ensurePhoneNumber(cid)
end)

-- Every callback below is reachable by any connected client with any payload (NUI fetch ->
-- client proxy -> lib.callback), so nothing in the payload is trusted: the acting character
-- always resolves from src via the player bridge, and each payload is normalised to a table
-- before field access because msgpack lets a modded client send a number/boolean, which would
-- otherwise error the handler on indexing. Field-level sanitising (slugs, clamps, whitelists,
-- length caps) lives in server.settings.store, so calling these directly can't skip it.

---Fetch the caller's full settings snapshot in one round trip: tone selections, custom tones of
---both kinds, airplane mode, clock preferences, wallpaper, chat text scale, locale and lock
---security. Everything is the caller's own row; the passcode is returned only to its owner (the
---lock UI validates entry client-side). Read-only.
lib.callback.register('sd-phone:server:settings:get', function(source)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    local data = store.getTones(cid)
    data.customRingtones         = store.listCustomTones(cid, 'ringtone')
    data.customNotificationTones = store.listCustomTones(cid, 'notification')
    data.airplaneMode            = store.isAirplane(cid)
    data.hour24                  = store.getHour24(cid)
    data.lockClock               = store.getLockClock(cid)
    data.wallpaper               = store.getWallpaper(cid)
    data.chatTextScale           = store.getChatTextScale(cid)
    data.locale                  = store.getLocale(cid)
    local sec = store.getSecurity(cid)
    data.passcode                = sec.passcode
    data.faceId                  = sec.faceId
    return { success = true, data = data }
end)

---Persist the caller's selected wallpaper (a build-stable filename key). The store sanitises
---the key and ignores empty/invalid values rather than wiping the saved pick.
lib.callback.register('sd-phone:server:settings:setWallpaper', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setWallpaper(cid, payload.wallpaper)
    return { success = true }
end)

---Persist the caller's lock security (passcode + Face Unlock). The frontend always sends the
---full state, so this overwrites both fields; the store clamps the pin to 4-6 digits and forces
---Face Unlock off whenever no valid passcode accompanies it.
lib.callback.register('sd-phone:server:settings:setSecurity', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setSecurity(cid, payload.passcode, payload.faceId == true)
    return { success = true }
end)

---Persist the caller's lockscreen clock customization (font/layout/colour/scale). The whole
---payload goes to the store, which type-checks it, sanitises every field and rebuilds the stored
---JSON from only the clean values.
lib.callback.register('sd-phone:server:settings:setLockClock', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    store.setLockClock(cid, payload or {})
    return { success = true }
end)

---Persist the caller's chat-bubble text size multiplier. The store clamps it to the UI's
---supported range and ignores non-numeric/NaN values.
lib.callback.register('sd-phone:server:settings:setChatTextScale', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setChatTextScale(cid, payload.scale)
    return { success = true }
end)

---Persist the caller's chosen phone language. The store whitelist-checks it against the
---supported locale catalog, so an arbitrary string never reaches the column.
lib.callback.register('sd-phone:server:settings:setLocale', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setLocale(cid, payload.locale)
    return { success = true }
end)

---Toggle the caller's airplane mode. Turning it OFF fires the release event so the messages
---module can deliver anything withheld while it was on; the event is server-local
---(TriggerEvent), so only trusted server code observes it.
lib.callback.register('sd-phone:server:settings:setAirplane', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    local on = payload.on == true
    store.setAirplane(cid, on)
    if not on then TriggerEvent('sd-phone:server:airplane:released', source) end
    return { success = true }
end)

---Persist the caller's 24-hour time preference (status bar + lockscreen). Coerced to a strict
---boolean before storage.
lib.callback.register('sd-phone:server:settings:setHour24', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setHour24(cid, payload.on == true)
    return { success = true }
end)

---Persist the caller's tone selections. The store sanitises each slug and leaves a missing or
---invalid field unchanged, so the UI can update one tone without resending the other.
lib.callback.register('sd-phone:server:settings:setTones', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setTones(cid, payload.ringtone, payload.notificationTone)
    return { success = true }
end)

---Read the caller's notification preference for one app. Defaults to enabled when never toggled
---or when the app id is unusable, so a malformed lookup can't silence notifications. Read-only.
lib.callback.register('sd-phone:server:settings:getNotifPref', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    return { success = true, data = { enabled = store.getNotifPref(cid, payload.app) } }
end)

---Persist the caller's notification preference for one app. The store sanitises the app slug
---and upserts, so a replayed toggle is idempotent.
lib.callback.register('sd-phone:server:settings:setNotifPref', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.setNotifPref(cid, payload.app, payload.on == true)
    return { success = true }
end)

---Save a custom (YouTube) tone - ringtone or notification tone. The store clamps every field to
---its column size and enforces the per-kind cap; its boolean result is surfaced as the envelope's
---success flag so the UI can tell a full list from a saved tone.
lib.callback.register('sd-phone:server:settings:tones:add', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    return { success = store.addCustomTone(cid, payload.kind, payload.id, payload.name, payload.url) }
end)

---Remove one of the caller's custom tones. The store's delete is keyed on (citizenid, id), so an
---arbitrary id can only ever hit the caller's own rows.
lib.callback.register('sd-phone:server:settings:tones:remove', function(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end
    payload = type(payload) == 'table' and payload or {}
    store.removeCustomTone(cid, payload.id)
    return { success = true }
end)

---Server export: a character's phone number straight from a citizenid, for resources that hold
---identifiers rather than server ids (offline characters included). Pass ensure == true to assign
---a number on first access the way getPhoneNumber does; otherwise a never-assigned character
---yields nil. A non-string or empty citizenid yields nil rather than erroring.
---@param citizenid string framework per-character id
---@param ensure boolean|nil assign a number when none exists yet
---@return string|nil number raw-digit phone number
exports('getPhoneNumberByIdentifier', function(citizenid, ensure)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    if ensure == true then return store.ensurePhoneNumber(citizenid) end
    return store.getPhoneNumber(citizenid)
end)

---Server export: the citizenid that owns a phone number, or nil when unassigned. The store
---digit-normalises both sides and rejects digitless input, so any formatting is accepted.
---@param number string phone number in any formatting
---@return string|nil citizenid
exports('getIdentifierByNumber', function(number)
    return store.getCitizenByNumber(number)
end)

---Server export: the connected server id of the character that owns a phone number. Nil when the
---number is unassigned or its owner is offline.
---@param number string phone number in any formatting
---@return number|nil source
exports('getSourceByNumber', function(number)
    local cid = store.getCitizenByNumber(number)
    if not cid then return nil end
    return player.getSourceByIdentifier(cid)
end)

---Server export: true when a phone number is assigned to any character. Digit-normalises and
---rejects empty input here because store.numberExists carries no empty-digit guard (its internal
---callers only ever probe non-empty generated candidates).
---@param number string phone number in any formatting
---@return boolean inService
exports('isNumberInService', function(number)
    local digits = (tostring(number or ''):gsub('%D', ''))
    if digits == '' then return false end
    return store.numberExists(digits)
end)

---Server export: true when a player currently has airplane mode on. Served from the store's
---in-memory cache after the first read, so it is cheap enough to call per routed message or
---call. An unresolvable source reads as false rather than blocking delivery.
---@param source number player server id
---@return boolean on
exports('isAirplaneMode', function(source)
    if type(source) ~= 'number' then return false end
    local cid = player.getIdentifier(source)
    if not cid then return false end
    return store.isAirplane(cid)
end)
