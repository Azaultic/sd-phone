---@type table sd-phone config root (configs/config.lua).
local config    = require 'configs.config'
---@type table Framework bridge (bridge.shared.framework): active framework detection + name.
local framework = require 'bridge.shared.framework'
---@type table Inventory bridge (bridge.server.inventory): backend-agnostic item ops.
local inv       = require 'bridge.server.inventory'

-- Loaded for side effects: every server-side app module self-registers its lib.callback
-- handlers, net events, commands and exports on require, so they're all listening by the time
-- any client opens the phone.
require 'server.settings.init'
require 'server.apps.init'
require 'server.groups.init'
require 'server.mail.init'
require 'server.messages.init'
require 'server.photos.init'
require 'server.birdy.init'
require 'server.accounts.init'
require 'server.contacts.init'
require 'server.calls.init'
require 'server.badges.init'
require 'server.gifs.init'
require 'server.garages.init'
require 'server.darkchat.init'
require 'server.marketplace.init'
require 'server.pages.init'
require 'server.review.init'
require 'server.weazelnews.init'
require 'server.banking.init'
require 'server.services.init'
require 'server.voicememos.init'
require 'server.music.init'
require 'server.share.init'
require 'server.devseed'
require 'server.notifications.init'
require 'server.notes.init'
require 'server.homes.init'
require 'server.maps.init'
require 'server.friends.init'
require 'server.cherry.init'
require 'server.photogram.init'
require 'server.voice.init'
require 'server.streaks.init'
require 'server.ryde.init'
require 'server.radio.init'
require 'server.clock.init'
require 'server.cookie.init'
require 'server.stocks.init'
require 'server.chess.init'
require 'server.connectfour.init'
require 'server.games.chips'
require 'server.games.railrunner'
require 'server.battleship.init'
require 'server.wordle.init'
require 'server.admin.wipe'
-- lb-phone -> sd-phone one-time data import (no-op unless lb-phone's tables are present).
require 'server.migrate.init'
-- lb-phone export compatibility shim (inert while the real lb-phone runs; sd_phone_lbcompat kill switch).
require 'server.compat.lbphone.init'

---Register each configured phone item (config.Phone.Items) as a usable item on whichever
---inventory/framework is active. The inventory bridge handles the multi-inventory dispatch - we
---just hand it the item name + callback. Using an item is itself proof of possession, so the
---phone opens straight away, passing the variant's frame colour so the client opens in the
---matching colour + in-hand prop.
local function RegisterPhoneItems()
    for _, entry in ipairs(config.Phone.Items or {}) do
        inv.registerUsable(entry.item, function(source)
            TriggerClientEvent('sd-phone:client:openFromItem', source, entry.color)
        end)
    end
end

---Server-authoritative ownership gate for the keybind. Using an item proves possession, but a
---keybind press can't, so the client asks whether the player owns a phone item and which colour
---to open with. `preferred` is the client's last-used colour hint - client-supplied, but only
---ever used as an equality probe against configured colours whose item the player provably
---holds, so a crafted value can at worst pick between variants they genuinely own. Falls back to
---the first owned variant in config order; nil when the player owns no phone item (the client
---then shows "You don't have a phone.").
---@param source integer player server id
---@param preferred string|nil last-used frame colour hint
---@return string|nil color frame colour to open with, nil when no phone item is owned
local function ResolveOwnedColor(source, preferred)
    local items = config.Phone.Items or {}
    if preferred then
        for _, entry in ipairs(items) do
            if entry.color == preferred and inv.count(source, entry.item) > 0 then
                return entry.color
            end
        end
    end
    for _, entry in ipairs(items) do
        if inv.count(source, entry.item) > 0 then
            return entry.color
        end
    end
    return nil
end

---Keybind open request: may this player open a phone, and in which colour? Checked server-side
---(inventory counts, not the payload) so a client can't open a phone it doesn't hold. Read-only.
lib.callback.register('sd-phone:server:phone:resolveOpen', function(source, preferred)
    return ResolveOwnedColor(source, preferred)
end)

-- Boot: register the usable phone items once (the short wait lets the inventory bridge's
-- registration path settle on slow starts), then print the startup banner. One-shot.
CreateThread(function()
    Wait(50)
    RegisterPhoneItems()

    local names = {}
    for _, entry in ipairs(config.Phone.Items or {}) do names[#names + 1] = entry.item end
    local itemList = #names > 0 and table.concat(names, ', ') or 'disabled'

    print('^2╭─────────────────────────────────────────────╮^0')
    print('^2│^0  ^3sd-phone^0 — iOS-themed in-game phone         ^2│^0')
    print('^2╰─────────────────────────────────────────────╯^0')
    print(('^2[sd-phone]^0 Framework: ^3%s^0  Items: ^3%s^0  v0.1.0'):format(
        framework.name, itemList))
end)

---Public export: does this player own a phone - exports['sd-phone']:hasPhone(source). Returns
---the frame colour of the first owned phone item, resolved by the same authoritative inventory
---check the keybind gate uses (ResolveOwnedColor, no colour preference), or nil when the player
---owns none. Exports are reachable only by other server resources - never by clients - so the
---checks here exist to fail cleanly on caller bugs rather than to distrust the value: a
---non-number source, or one that doesn't resolve to a connected player, returns nil.
---@param source number player server id
---@return string|nil color owned frame colour, nil when no phone item is owned
exports('hasPhone', function(source)
    if type(source) ~= 'number' then return nil end
    if not GetPlayerName(source) then return nil end
    return ResolveOwnedColor(source, nil)
end)

require 'server.compat.lbphone.clientsupport'
