---Bind a NUI callback that forwards its payload to the matching server callback and returns the
---response envelope unchanged, falling back to a uniform failure when the server never answers.
---Deliberately adds no validation: the NUI payload reaches the server exactly as a modded client
---could send it directly, so every real check lives in the server handler this forwards to. Shared
---by every app's thin pass-through registrations so the forward and the no-response fallback stay
---identical everywhere (the behaviour lives here, not copied into each app).
---@param nuiAction string NUI action name the React app fetches
---@param serverEvent string server callback name to await
local function proxy(nuiAction, serverEvent)
    RegisterNUICallback(nuiAction, function(payload, cb)
        cb(lib.callback.await(serverEvent, false, payload) or { success = false, message = 'No response from server' })
    end)
end

return proxy
