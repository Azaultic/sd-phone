---@type table Framework bridge (bridge.shared.framework): detected core name ('qb'/'esx') + live core object.
local framework = require 'bridge.shared.framework'

-- Toggles for the notification backend. ox_lib is preferred; lation_ui is an opt-in fallback for
-- servers that have standardised on it.
---@type boolean Use ox_lib's lib.notify when ox_lib is loaded.
local USE_OX_LIB    = true
---@type boolean Use lation_ui's notify export instead (only consulted when the ox_lib path is off/unavailable).
local USE_LATION_UI = false

---@type table Notify module; the table returned at end of file. Client-side notification bridge:
---one show() over whichever toast backend the server runs (ox_lib, lation_ui, or the framework's
---native notify), plus the listener for the 'sd-phone:client:notify' net event that
---bridge/server/notify.lua fires.
local notify = {}

---Pick the notify backend once at module load - frameworks/UIs don't change at runtime, so we
---only branch once and store the chosen function. Preference order: ox_lib (when loaded and
---enabled), lation_ui (opt-in), then the framework's native notify. With none of those, the
---fallback errors loudly on first use so a misconfigured server surfaces immediately instead of
---silently dropping every notification.
---@return fun(data: { title?: string, description: string, type?: string, position?: string, duration?: number })
local function chooseBackend()
    if lib ~= nil and USE_OX_LIB then
        return function(data)
            lib.notify({
                id          = math.random(1, 999999),
                title       = data.title,
                description = data.description,
                type        = data.type or 'inform',
                position    = data.position or 'top-right',
                duration    = data.duration or 3000,
            })
        end
    end

    if USE_LATION_UI then
        return function(data)
            exports.lation_ui:notify({
                title   = data.title,
                message = data.description,
                type    = data.type or 'info',
            })
        end
    end

    if framework.name == 'esx' then
        return function(data) framework.core.ShowNotification(data.description) end
    elseif framework.name == 'qb' then
        return function(data) framework.core.Functions.Notify(data.description, data.type or 'info') end
    end

    return function(data)
        error(('Notification system not supported. message=%s type=%s'):format(
            data.description, data.type))
    end
end

---@type fun(data: table) Chosen notify backend, resolved once at module load.
local backend = chooseBackend()

---Show a notification. Accepts a fully-typed payload table or a (text, type) pair - both are
---common in the wild and we don't want to force callers to rebuild a table for the common case.
---@param data string|table
---@param notifyType? string
function notify.show(data, notifyType)
    if type(data) == 'string' then
        backend({ description = data, type = notifyType or 'info' })
    else
        backend(data)
    end
end

---Server -> client notify trigger: server modules call bridge.server.notify.to(src, ...) which
---fires this event. Trusted direction (net events to a client can only come from the server),
---but the payload is still type-guarded defensively - a string or table shows, anything else is
---dropped instead of erroring inside the backend.
---@param data string|table Notification payload (passed straight through to `notify.show`).
RegisterNetEvent('sd-phone:client:notify', function(data)
    if type(data) ~= 'string' and type(data) ~= 'table' then return end
    notify.show(data)
end)

return notify
