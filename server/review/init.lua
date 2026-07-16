---@type table Review persistence layer (server.review.store): review/helpful-vote/override row CRUD.
local store = require 'server.review.store'
---@type table Authoritative review handlers (server.review.actions): validation + row mutation.
local actions = require 'server.review.actions'

---Schema bootstrap. Threaded so it yields until oxmysql is ready without blocking resource
---start; a SQL failure is caught and reported instead of killing the resource. Runs once.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:review]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:review]^0 schema ready')
end)

-- Authoritative NUI-facing callbacks: thin delegates into server.review.actions, which owns the
-- validation + row mutation (each handler is documented there). Payloads are attacker-controlled:
-- id fields are unpacked behind a type guard so a scalar payload can't index-error before the
-- action's own validation runs. Reviews are plain persisted rows re-fetched whenever the app
-- opens, so beyond the owner notification inside create there is no push/broadcast surface here.
lib.callback.register('sd-phone:server:review:list', function(src) return actions.list(src) end)
lib.callback.register('sd-phone:server:review:business', function(src, payload) return actions.business(src, type(payload) == 'table' and payload.id or nil) end)
lib.callback.register('sd-phone:server:review:create', function(src, payload) return actions.create(src, payload) end)
lib.callback.register('sd-phone:server:review:delete', function(src, payload) return actions.delete(src, type(payload) == 'table' and payload.id or nil) end)
lib.callback.register('sd-phone:server:review:helpful', function(src, payload) return actions.helpful(src, type(payload) == 'table' and payload.id or nil) end)
lib.callback.register('sd-phone:server:review:manage', function(src, payload) return actions.manage(src, payload) end)
