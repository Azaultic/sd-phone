---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'

-- Thin delegates into server/gifs: read-only GIF-picker lookups (the server owns the upstream
-- API key, so the NUI never talks to the GIF provider directly) - documented there.
proxyCallback('sd-phone:gifs:categories', 'sd-phone:server:gifs:categories')
proxyCallback('sd-phone:gifs:featured',   'sd-phone:server:gifs:featured')
proxyCallback('sd-phone:gifs:search',     'sd-phone:server:gifs:search')
