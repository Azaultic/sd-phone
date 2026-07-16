---Show one iOS-style banner in the React app. The single funnel for both the server notify
---event and the client export, so the shape check lives in one place: anything without a table
---payload and a string title is dropped, so a malformed call from another resource can't push
---garbage into the NUI. Fields: app (app-icon id, e.g. 'messages'), image (custom icon URL),
---title (required), body, time (e.g. 'now'), appId (app to open on tap).
---@param data table notification payload
local function push(data)
    if type(data) ~= 'table' or type(data.title) ~= 'string' then return end
    SendNUIMessage({ action = 'sd-phone:notification', data = data })
end

---Landing point for the SERVER notify export - other resources call
---exports['sd-phone']:notify(source, { app = 'messages', title = 'New Message', body = 'Hey!' })
---and it arrives here on the targeted client. Server-originated (trusted), still shape-checked
---by push.
---@param data table notification payload
RegisterNetEvent('sd-phone:client:notify', function(data)
    push(data)
end)

---Client-side direct banner for scripts on this machine:
---exports['sd-phone']:showNotification({ title = '...', body = '...' }).
exports('showNotification', push)

-- Home-screen badges: persistent unread counts (Messages, missed calls) computed server-side.
-- The React app fetches a snapshot on phone open; the server pushes fresh counts whenever they
-- change. See server/badges/init.lua.

---Server push: a fresh badge snapshot (counts changed); relay it unchanged.
---@param snap table per-app unread counts
RegisterNetEvent('sd-phone:client:badges', function(snap)
    SendNUIMessage({ action = 'sd-phone:badges', data = snap })
end)

---React to server: snapshot fetched on phone open (seeds existing unread state). Zeroed
---fallback keeps the UI sane if the server doesn't answer.
RegisterNUICallback('sd-phone:badges:get', function(_, cb)
    local snap = lib.callback.await('sd-phone:server:badges:get', false)
    cb(snap or { messages = 0, phone = 0 })
end)

---React to server: the Phone app opened - acknowledge missed calls so the badge clears. The
---server scopes the update to the caller's own rows.
RegisterNUICallback('sd-phone:calls:seen', function(_, cb)
    local result = lib.callback.await('sd-phone:server:calls:seen', false)
    cb(result or { success = false })
end)

---/phonenotif [app] - fire a sample banner (optional first arg picks the app icon, defaults to
---the Messages style). Purely cosmetic and client-local (no server trip, no state mutation), so
---it needs no restriction.
RegisterCommand('phonenotif', function(_, args)
    local app = args[1] or 'messages'
    push({
        app   = app,
        title = 'Notification',
        body  = 'This is a test notification 👋  Tap to open, or swipe up to dismiss.',
        time  = 'now',
        appId = app,
    })
end, false)
