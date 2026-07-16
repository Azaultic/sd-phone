---@type table Notify module; the table returned at end of file. Server -> client notification
---dispatcher: wraps the 'sd-phone:client:notify' net event that bridge/client/notify.lua listens
---for, so server modules never hand-roll the event name or payload shape.
local notify = {}

---Send a notification to a specific player. Accepts either a bare description string (with an
---optional type) or a full payload table passed straight through to the client - both shapes are
---common at call sites and the client's notify.show handles either. Trusted direction (server ->
---client); the target `source` is chosen by server code, never by a client payload.
---@param source number Target player id.
---@param data string|table Either a (description) string or a payload table.
---@param notifyType? 'info'|'success'|'error' Used when `data` is a string.
function notify.to(source, data, notifyType)
    if type(data) == 'string' then
        TriggerClientEvent('sd-phone:client:notify', source,
            { description = data, type = notifyType or 'info' })
    else
        TriggerClientEvent('sd-phone:client:notify', source, data)
    end
end

return notify
