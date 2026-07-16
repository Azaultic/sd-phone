---@type table Player bridge (bridge.server.player): citizenid lookup from a server id.
local player = require 'bridge.server.player'
---@type table Settings persistence layer (server.settings.store): phone-number assignment/lookup.
local settingsStore = require 'server.settings.store'

-- Both callbacks below back the lb-phone compat CLIENT shim (client/compat/lbphone.lua) and are
-- registered unconditionally: they are sd-phone namespaced (no collision with a real lb-phone)
-- and answer only about the calling player, so leaving them live while the shim is disabled is
-- harmless and keeps the shim working even when the compat convar is not replicated to clients.

---Backs GetEquippedPhoneNumber: the CALLER'S own phone number, assigning one on first access
---the same way the getPhoneNumber export does. `source` is injected by lib.callback, never read
---from a payload, so this can only ever leak the caller's own number. Nil when the character
---does not resolve (mid-connect, character not loaded).
lib.callback.register('sd-phone:server:compat:selfNumber', function(source)
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    return settingsStore.ensurePhoneNumber(cid)
end)

---Backs HasPhoneItem: whether the caller owns any configured phone item, routed through the
---same authoritative inventory gate the keybind open uses (ResolveOwnedColor, reached via this
---resource's own hasPhone export) so it can never disagree with whether the phone would actually
---open. Boolean only; the owned frame colour stays server-side.
lib.callback.register('sd-phone:server:compat:selfHasPhone', function(source)
    return exports['sd-phone']:hasPhone(source) ~= nil
end)
