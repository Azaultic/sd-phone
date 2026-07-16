---@type table Pages persistence layer (server.pages.store): post row CRUD.
local store = require 'server.pages.store'
---@type table Authoritative pages handlers (server.pages.actions).
local actions = require 'server.pages.actions'

-- One-shot boot thread: create/migrate the pages table before the first callback can hit it.
-- pcall'd so a DB fault surfaces as a tagged console line instead of an unhandled error.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:pages]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:pages]^0 schema ready')
end)

-- Authoritative callbacks, reachable by any connected client with any payload: thin delegates
-- into server.pages.actions, which owns the validation + ownership checks (each handler is
-- documented there). Posts are plain persisted rows - no live presence needed, the feed is
-- re-fetched whenever the app opens and kept fresh in between by the actions-layer feed pushes.
lib.callback.register('sd-phone:server:pages:list', function(src) return actions.list(src) end)
lib.callback.register('sd-phone:server:pages:create', function(src, payload) return actions.create(src, payload) end)
lib.callback.register('sd-phone:server:pages:update', function(src, payload) return actions.update(src, payload) end)

---Delete unwraps { id } here before delegating; a non-table payload (crafted client) is coerced
---to {} so the field access can't error before actions.delete's own id validation rejects it.
---@param src integer player server id
---@param payload table|nil { id } (untrusted)
lib.callback.register('sd-phone:server:pages:delete', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.delete(src, payload.id)
end)
