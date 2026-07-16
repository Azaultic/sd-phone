---@type table Player bridge (bridge.server.player): citizenid/name/phone-number lookups.
local player         = require 'bridge.server.player'
---@type table Messages persistence layer (server.messages.store): per-mailbox row CRUD.
local messageStore   = require 'server.messages.store'
---@type table Contacts/calls persistence layer (server.contacts.store): missed-call counts.
local contactStore   = require 'server.contacts.store'
---@type table Mail persistence layer (server.mail.store): inbox unread counts.
local mailStore      = require 'server.mail.store'
---@type table Groups persistence layer (server.groups.store): pending-invite counts.
local groupStore     = require 'server.groups.store'
---@type table App-accounts persistence layer (server.accounts.store): per-app session lookups.
local acctStore      = require 'server.accounts.store'
---@type table Photogram persistence layer (server.photogram.store): notification/DM counts.
local photogramStore = require 'server.photogram.store'

---@type table Badges module; the table returned at end of file.
local badges = {}

---Photogram unread = unseen Activity notifications + unread DMs, keyed by the photogram account
---signed in on this character (0 if not signed in - a signed-out app never shows a badge).
---@param cid string framework per-character id
---@return number unread
local function photogramCount(cid)
    local acc = acctStore.getSessionAccount('photogram', cid)
    if not acc then return 0 end
    return photogramStore.unseenNotificationCount(acc.username) + photogramStore.dmUnreadTotal(acc.username)
end

---Per-app unread counts for one character, keyed by home-screen app id. Computed straight from
---the database on every call (no in-memory bookkeeping to drift): Messages = unread inbound,
---Phone = unacknowledged missed calls, Mail = unread inbox mail, Groups = pending invites,
---Photogram = photogramCount. The React app displays the numbers verbatim; add a key here as
---other apps gain persistent unread state.
---@param cid string framework per-character id
---@return { messages: number, phone: number, mail: number, groups: number, photogram: number }
function badges.snapshot(cid)
    return {
        messages  = messageStore.unreadCount(cid),
        phone     = contactStore.unreadMissedCount(cid),
        mail      = mailStore.unreadCount(cid),
        groups    = groupStore.pendingInviteCount(cid),
        photogram = photogramCount(cid),
    }
end

---Recompute a player's badge counts and push the exact numbers to their phone. Because the
---counts are recomputed from the DB rather than incremented, a replayed or missed push can never
---drift the numbers. Cheap (a handful of COUNTs) and safe to call from any hook point; a no-op
---when the source has no resolvable citizenid (e.g. mid-disconnect).
---@param source number player server id
function badges.push(source)
    if not source or source <= 0 then return end
    local cid = player.getIdentifier(source)
    if not cid then return end
    TriggerClientEvent('sd-phone:client:badges', source, badges.snapshot(cid))
end

---Fetched once by the React app on phone open, so unread state that predates this session (or a
---resource restart) shows immediately. Scoped to the citizenid resolved from src; an
---unresolvable caller gets all-zero counts rather than an error. Read-only.
lib.callback.register('sd-phone:server:badges:get', function(src)
    local cid = player.getIdentifier(src)
    if not cid then return { messages = 0, phone = 0, mail = 0, groups = 0, photogram = 0 } end
    return badges.snapshot(cid)
end)

---Server export: recompute and push a player's badge counts from another resource -
---exports['sd-phone']:pushBadges(source). Call after mutating anything the counts derive from.
---Delegates to badges.push; a non-number source is a silent no-op, matching push's own handling
---of unresolvable players.
---@param source number player server id
exports('pushBadges', function(source)
    if type(source) ~= 'number' then return end
    badges.push(source)
end)

---Server export: a player's current per-app unread counts without pushing them -
---exports['sd-phone']:getBadgeCounts(source). Nil when the source doesn't resolve to a loaded
---character, so callers can tell "no player" apart from all-zero counts.
---@param source number player server id
---@return { messages: number, phone: number, mail: number, groups: number, photogram: number }|nil counts
exports('getBadgeCounts', function(source)
    if type(source) ~= 'number' then return nil end
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    return badges.snapshot(cid)
end)

return badges
