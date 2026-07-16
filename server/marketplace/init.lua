---@type table Marketplace persistence layer (server.marketplace.store): listing row CRUD.
local store = require 'server.marketplace.store'
---@type table Authoritative marketplace handlers (server.marketplace.actions).
local actions = require 'server.marketplace.actions'

-- One-shot boot thread: create/migrate the marketplace table before the first callback can hit
-- it. pcall'd so a DB fault surfaces as a tagged console line instead of an unhandled error.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:marketplace]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:marketplace]^0 schema ready')
end)

-- Authoritative callbacks, reachable by any connected client with any payload: thin delegates
-- into server.marketplace.actions, which owns the validation + ownership checks (each handler is
-- documented there). Listings are plain persisted rows - no live presence needed, the feed is
-- re-fetched whenever the app opens and kept fresh in between by the actions-layer feed pushes.
lib.callback.register('sd-phone:server:marketplace:list', function(src) return actions.list(src) end)
lib.callback.register('sd-phone:server:marketplace:create', function(src, payload) return actions.create(src, payload) end)
lib.callback.register('sd-phone:server:marketplace:update', function(src, payload) return actions.update(src, payload) end)

---Delete unwraps { id } here before delegating; a non-table payload (crafted client) is coerced
---to {} so the field access can't error before actions.delete's own id validation rejects it.
---@param src integer player server id
---@param payload table|nil { id } (untrusted)
lib.callback.register('sd-phone:server:marketplace:delete', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.delete(src, payload.id)
end)
