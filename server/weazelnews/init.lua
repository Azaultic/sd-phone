---@type table Weazel News persistence layer (server.weazelnews.store): article + ticker row CRUD.
local store   = require 'server.weazelnews.store'
---@type table Authoritative Weazel News handlers (server.weazelnews.actions): staff gating,
---input clamping and envelope responses.
local actions = require 'server.weazelnews.actions'

-- Boot-time schema bootstrap, pcall-wrapped so a DB outage prints a tagged error instead of
-- killing the resource. Stories are plain persisted rows re-fetched whenever the app opens, so
-- this is the module's only thread - no live presence or push is needed.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:weazelnews]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:weazelnews]^0 schema ready')
end)

-- Authoritative NUI callbacks: thin delegates into server.weazelnews.actions, which owns the
-- staff gating + validation (each handler is documented there). Payloads are attacker-controlled
-- msgpack, so shims that index a field normalize non-table payloads first.
lib.callback.register('sd-phone:server:weazelnews:feed', function(src)
    return actions.feed(src)
end)

lib.callback.register('sd-phone:server:weazelnews:view', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.view(src, payload.id)
end)

lib.callback.register('sd-phone:server:weazelnews:save', function(src, payload)
    return actions.save(src, payload)
end)

lib.callback.register('sd-phone:server:weazelnews:delete', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    return actions.delete(src, payload.id)
end)

lib.callback.register('sd-phone:server:weazelnews:setBreaking', function(src, payload)
    return actions.setBreaking(src, payload)
end)

---Publish an article from another server resource - exports['sd-phone']:postArticle(article).
---`article` mirrors the staff draft: { category, headline, dek?, body, image?, featured?,
---author? }, where body is a paragraph array or a single string. The caller is trusted, so only
---the staff boss-gate is skipped; every clamp in the staff path still applies (category
---whitelist, required headline, length caps). The byline defaults to 'Weazel News', timestamps
---are server-stamped, and a featured article demotes every other story so there is a single
---hero. The feed has no live push - the article appears the next time a player opens the app.
---Returns the new article id, or nil plus a reason on a validation failure.
---@param article table
---@return integer|nil articleId
---@return string? reason failure reason when articleId is nil
exports('postArticle', function(article)
    return actions.publish(article)
end)

---Replace the breaking ticker from another server resource -
---exports['sd-phone']:setBreakingTicker(lines). Same clamps as the staff editor: lines are
---trimmed, non-strings and empties dropped, each line capped to MaxBreakingLength and at most
---MaxBreakingLines kept, in order. An empty array clears the ticker; a non-table returns false
---without touching it. Like articles there is no live push - open apps see the new ticker on
---their next feed fetch.
---@param lines string[] ticker lines in display order
---@return boolean replaced
exports('setBreakingTicker', function(lines)
    return actions.replaceTicker(lines)
end)
