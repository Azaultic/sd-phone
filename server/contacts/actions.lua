---@type table sd-phone config root (configs/config.lua).
local config   = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid/name lookups.
local player   = require 'bridge.server.player'
---@type table Contacts persistence layer (server.contacts.store): contact/call-log/block-list row CRUD.
local store    = require 'server.contacts.store'
---@type table Settings persistence (server.settings.store): phone numbers, number-owner lookups, My Card.
local settings = require 'server.settings.store'
---@type table AirShare core (server.share.core): nearby-share request handshake + delivery routing.
local share    = require 'server.share.core'
---@type table Badge engine (server.badges.init): server-authoritative unread badge pushes.
local badges   = require 'server.badges.init'

---@type table Contacts config (config.Contacts): caps for contacts, recents, and field lengths.
local cfg = config.Contacts

---@type table Actions module; the table returned at end of file.
local actions = {}

local util = require 'server.util'
local ok, fail, trim, isTruthy, initialsFor = util.ok, util.fail, util.trim, util.truthy, util.initialsFor


local colorFor = util.colorFor

---@type table<string, boolean> Call directions accepted by logCall; anything else falls back to outgoing.
local VALID_DIRECTIONS = { incoming = true, outgoing = true, missed = true }




---Validate and normalise an add/update payload into stored fields. Guarded against non-table
---payloads (a crafted scalar would otherwise error on field access). Phone input is accepted in
---any format (bare digits or '(123) 456-7890') but stored as bare digits, so the saved value is
---always normalised regardless of how it was typed; a nameless contact falls back to showing
---exactly what was typed. Length caps mirror the React forms AND the DB columns, so nothing
---oversized reaches an insert.
---@param payload any client-supplied contact fields
---@return { name: string, phone: string, email: string|nil, address: string|nil, avatar: string|nil }|nil fields
---@return string? err refusal message when fields is nil
local function validate(payload)
    if type(payload) ~= 'table' then payload = {} end
    local name    = trim(payload.name)
    local typed   = trim(payload.phone)
    local phone   = (typed:gsub('%D', ''))
    local email   = trim(payload.email)
    local address = trim(payload.address)
    local avatar  = trim(payload.avatar)
    if #avatar > 512 then avatar = avatar:sub(1, 512) end

    if name == '' and phone == '' then
        return nil, 'A name or number is required'
    end
    if name == '' then name = typed end
    if #name > cfg.MaxNameLength then
        return nil, ('Name must be %d characters or fewer'):format(cfg.MaxNameLength)
    end
    if #phone > cfg.MaxPhoneLength then
        return nil, ('Number must be %d characters or fewer'):format(cfg.MaxPhoneLength)
    end
    if #email > cfg.MaxEmailLength then
        return nil, ('Email must be %d characters or fewer'):format(cfg.MaxEmailLength)
    end
    if #address > cfg.MaxAddressLength then
        return nil, ('Address must be %d characters or fewer'):format(cfg.MaxAddressLength)
    end

    return {
        name    = name,
        phone   = phone,
        email   = email   ~= '' and email   or nil,
        address = address ~= '' and address or nil,
        avatar  = avatar  ~= '' and avatar  or nil,
    }
end


---Reshape a stored contact row into the React `Contact` shape.
---@param row table
---@return table
local function serializeContact(row)
    return {
        id       = row.id,
        name     = row.name,
        phone    = row.phone,
        email    = row.email,
        address  = row.address,
        color    = row.color,
        avatar   = row.avatar,
        initials = initialsFor(row.name),
        favorite = isTruthy(row.favorite),
    }
end

actions.serializeContact = serializeContact

---Reshape a stored call row into the React call-log shape. The raw epoch is handed back as
---`calledAt` for the frontend to format.
---@param row table
---@return table
local function serializeCall(row)
    return {
        id        = row.id,
        number    = row.number,
        name      = row.name,
        direction = row.direction,
        duration  = tonumber(row.duration) or 0,
        calledAt  = tonumber(row.called_at) or 0,
    }
end

---Full phone state for one player in a single round-trip: every contact, the recent-calls log,
---their (created-on-demand) phone number, character name, and the editable My Card overrides.
---Read-only and scoped to the caller's own citizenid.
---@param source number
---@return table
function actions.list(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local contactRows = store.listContacts(cid)
    local contacts = {}
    for i = 1, #contactRows do contacts[i] = serializeContact(contactRows[i]) end

    local callRows = store.listCalls(cid, cfg.MaxRecents)
    local recents = {}
    for i = 1, #callRows do recents[i] = serializeCall(callRows[i]) end

    return ok({
        contacts = contacts,
        recents  = recents,
        myNumber = settings.ensurePhoneNumber(cid),
        myName   = player.getName(source),
        card     = settings.getCard(cid),
    })
end

---Persist the player's editable "My Card" (name / photo / email / address), scoped to their own
---citizenid. The phone number is server-assigned and never set here. Guarded against non-table
---payloads; per-field trimming and column-length clamping happen in settings.setCard.
---@param source number
---@param payload { name?: string, avatar?: string, email?: string, address?: string }
---@return table
function actions.saveCard(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    settings.setCard(cid, type(payload) == 'table' and payload or {})
    return ok(settings.getCard(cid))
end

---Create a contact for the caller. The number must be real (assigned to a character) - no
---dummy contacts that aren't attached to anyone - and must be neither the caller's own number
---nor one they already have saved. Inserts stop at config.Contacts.MaxContactsPerPlayer so a
---client can't grow the table unbounded.
---@param source number
---@param payload table
---@return table
function actions.add(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local fields, err = validate(payload)
    if not fields then return fail(err) end

    local newDigits = (tostring(fields.phone):gsub('%D', ''))
    if newDigits == '' then
        return fail('Enter a phone number')
    end
    if not settings.getCitizenByNumber(newDigits) then
        return fail('That number isn\'t in service')
    end

    local ownNumber = settings.getPhoneNumber(cid)
    if ownNumber and (tostring(ownNumber):gsub('%D', '')) == newDigits then
        return fail('You can\'t add your own number')
    end
    for _, row in ipairs(store.listContacts(cid)) do
        if (tostring(row.phone):gsub('%D', '')) == newDigits then
            return fail('You already have a contact with this number')
        end
    end

    if store.countContacts(cid) >= cfg.MaxContactsPerPlayer then
        return fail(('You can store at most %d contacts'):format(cfg.MaxContactsPerPlayer))
    end

    local id = store.newId()
    local record = {
        name    = fields.name,
        phone   = fields.phone,
        email   = fields.email,
        address = fields.address,
        avatar  = fields.avatar,
        color   = colorFor(fields.name),
    }
    if not store.insertContact(id, cid, record) then
        return fail('Failed to save contact')
    end

    -- First-party hook: one server-local event per saved contact; the payload carries a citizenid.
    TriggerEvent('sd-phone:server:contacts:added', {
        source = source, citizenid = cid, id = id,
        name = record.name, phone = record.phone, shared = false,
    })
    return ok(serializeContact(store.getContact(id, cid)))
end

---Send an AirShare request to share this contact card with a nearby player. The card fields are
---validated NOW (same rules as add) so nothing malformed sits in the pending request; delivery
---happens only if the recipient accepts (see actions.deliverShare). Recipient reachability and
---range are enforced in share.request.
---@param source number
---@param target number recipient server id (client-supplied, coerced + range-checked in share.request)
---@param payload table contact fields { name, phone, email, address, avatar }
---@return table
function actions.requestShare(source, target, payload)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local fields, err = validate(payload)
    if not fields then return fail(err) end

    local okSent, msg = share.request(source, target, 'contact', fields)
    if not okSent then return fail(msg or 'Could not send request') end
    return ok()
end

---Deliver an accepted contact share into the recipient's contacts (the AirShare 'contact'
---handler - registered in init.lua). `fields` were validated at request time and held in server
---memory, but AirShare bypasses actions.add, so add's guards are re-applied for the RECIPIENT:
---under the contact cap, number in service, not their own, and not one they already have.
---Returns a bare boolean (the share-core handler contract) instead of a message envelope.
---@param targetSrc number
---@param fields table validated contact fields
---@return boolean delivered
function actions.deliverShare(targetSrc, fields)
    local tcid = player.getIdentifier(targetSrc)
    if not tcid then return false end
    if store.countContacts(tcid) >= cfg.MaxContactsPerPlayer then return false end

    local newDigits = (tostring(fields.phone):gsub('%D', ''))
    if newDigits == '' or not settings.getCitizenByNumber(newDigits) then return false end
    local ownNumber = settings.getPhoneNumber(tcid)
    if ownNumber and (tostring(ownNumber):gsub('%D', '')) == newDigits then return false end
    for _, row in ipairs(store.listContacts(tcid)) do
        if (tostring(row.phone):gsub('%D', '')) == newDigits then return false end
    end

    local id = store.newId()
    local record = {
        name    = fields.name,
        phone   = fields.phone,
        email   = fields.email,
        address = fields.address,
        avatar  = fields.avatar,
        color   = colorFor(fields.name),
    }
    if not store.insertContact(id, tcid, record) then return false end

    -- First-party hook: server-local event for the delivered share; the payload carries the
    -- RECIPIENT's citizenid and source.
    TriggerEvent('sd-phone:server:contacts:added', {
        source = targetSrc, citizenid = tcid, id = id,
        name = record.name, phone = record.phone, shared = true,
    })
    TriggerClientEvent('sd-phone:client:contacts:shared', targetSrc, serializeContact(store.getContact(id, tcid)))
    return true
end

---Edit an existing contact. The id must be a string - anything else is rejected before it can
---reach the SQL layer as a bad parameter - and the row must belong to the caller (checked here,
---and again by the citizenid-scoped UPDATE). Fields re-run the same validation as add.
---@param source number
---@param payload { id?: string }
---@return table
function actions.update(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local id = type(payload.id) == 'string' and payload.id or ''
    if id == '' then return fail('Contact id is required') end
    if not store.getContact(id, cid) then return fail('Contact not found') end

    local fields, err = validate(payload)
    if not fields then return fail(err) end

    if not store.updateContact(id, cid, fields) then
        return fail('Failed to update contact')
    end

    return ok(serializeContact(store.getContact(id, cid)))
end

---Delete a contact. The citizenid-scoped DELETE is the ownership check: a crafted id belonging
---to someone else matches zero rows and reports not-found. The row is read first (same citizenid
---scope) so the removal hook can carry the contact's number.
---@param source number
---@param payload { id?: string }
---@return table
function actions.delete(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local id = type(payload.id) == 'string' and payload.id or ''
    local row = store.getContact(id, cid)
    if not row or not store.deleteContact(id, cid) then return fail('Contact not found') end

    -- First-party hook: one server-local event per deleted contact; the payload carries a citizenid.
    TriggerEvent('sd-phone:server:contacts:removed', {
        source = source, citizenid = cid, id = id, phone = row.phone, removed = 1,
    })
    return ok({ id = id })
end

---Remove every contact matching a number from a player's list. Reached via the
---removeContactByNumber export (other server resources), so the number is re-validated here:
---normalised to bare digits the same way add stores it, and matched digits-vs-digits so any
---formatting on either side still hits. Each hit deletes through the citizenid-scoped store
---call; when anything was removed, the player's open phone is told to drop the rows live.
---A number that matches nothing still succeeds with removed = 0.
---@param source number acting player's server id
---@param number string|number phone number, any format
---@return table
function actions.removeByNumber(source, number)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local digits = (tostring(number or ''):gsub('%D', ''))
    if digits == '' then return fail('A number is required') end

    local removed = 0
    for _, row in ipairs(store.listContacts(cid)) do
        if (tostring(row.phone):gsub('%D', '')) == digits and store.deleteContact(row.id, cid) then
            removed = removed + 1
        end
    end

    if removed > 0 then
        TriggerClientEvent('sd-phone:client:contacts:removed', source, { phone = digits })
        -- First-party hook: one server-local event per matched-number wipe (id is nil here); the
        -- payload carries a citizenid.
        TriggerEvent('sd-phone:server:contacts:removed', {
            source = source, citizenid = cid, phone = digits, removed = removed,
        })
    end

    return ok({ removed = removed })
end

---Set or clear a contact's favourite flag, scoped to its owner. The flag is compared strictly
---to `true` so any non-boolean payload value simply clears it.
---@param source number
---@param payload { id?: string, favorite?: boolean }
---@return table
function actions.favorite(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local id = type(payload.id) == 'string' and payload.id or ''
    if not store.getContact(id, cid) then return fail('Contact not found') end

    local fav = payload.favorite == true
    if not store.setFavorite(id, cid, fav) then return fail('Failed to update favourite') end
    return ok({ id = id, favorite = fav })
end

---Append a call to the caller's recents log and prune to the cap. Also reachable by other
---resources via the logCall export, so every field is re-validated here: the direction is
---whitelisted (anything else logs as outgoing), the number is required and length-capped to its
---column, the name is truncated to its column, and the duration is coerced to a finite
---non-negative integer clamped to the INT range - so no crafted value can blow up the insert.
---A missed call logged from elsewhere still lights the home-screen Phone badge. Contact
---resolution (number to saved contact) happens client-side.
---@param source number
---@param payload { number?: string, name?: string, direction?: string, duration?: number }
---@return table
function actions.logCall(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local number = trim(payload.number)
    if number == '' then return fail('A number is required') end
    if #number > cfg.MaxPhoneLength then
        return fail(('Number must be %d characters or fewer'):format(cfg.MaxPhoneLength))
    end

    local direction = VALID_DIRECTIONS[payload.direction] and payload.direction or 'outgoing'
    local name = trim(payload.name):sub(1, cfg.MaxNameLength)

    local duration = tonumber(payload.duration) or 0
    if duration ~= duration or duration == math.huge or duration == -math.huge then duration = 0 end
    duration = math.min(math.max(0, math.floor(duration)), 2147483647)

    local id = store.newId()
    local call = {
        number    = number,
        name      = name ~= '' and name or nil,
        direction = direction,
        duration  = duration,
        calledAt  = os.time(),
    }
    if not store.insertCall(id, cid, call) then return fail('Failed to log call') end
    store.pruneCalls(cid, cfg.MaxRecents)

    if direction == 'missed' then badges.push(source) end

    return ok(serializeCall({
        id        = id,
        number    = call.number,
        name      = call.name,
        direction = call.direction,
        duration  = call.duration,
        called_at = call.calledAt,
    }))
end

---Delete one recents entry. The citizenid-scoped DELETE is the ownership check: a crafted id
---belonging to someone else matches zero rows and reports not-found.
---@param source number
---@param payload { id?: string }
---@return table
function actions.deleteRecent(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local id = type(payload.id) == 'string' and payload.id or ''
    if not store.deleteCall(id, cid) then return fail('Call not found') end
    return ok({ id = id })
end

---Wipe the caller's recents log. Scoped to their own citizenid; idempotent.
---@param source number
---@return table
function actions.clearRecents(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    store.clearCalls(cid)
    return ok()
end

---Acknowledge missed calls - the player opened the Phone app, so clear the home-screen Phone
---badge. Persisted (the `seen` column), so it stays cleared across restarts; the badge repush
---updates the client immediately. Idempotent.
---@param source number
---@return table
function actions.markCallsSeen(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    store.markMissedSeen(cid)
    badges.push(source)
    return ok()
end

---Block a caller (by number) for the requesting player. A blocked number can't call them (the
---dial path refuses with the same wording as offline, so the blocker isn't revealed) or message
---them. The store normalises to bare digits and silently no-ops on garbage input; the handler
---still answers success, matching the UI's fire-and-forget toggle.
---@param source number
---@param payload { number?: string }
---@return table
function actions.block(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    store.blockNumber(cid, payload.number)
    return ok({ blocked = true })
end

---Unblock a caller. Scoped to the requesting player's own block list; idempotent.
---@param source number
---@param payload { number?: string }
---@return table
function actions.unblock(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    store.unblockNumber(cid, payload.number)
    return ok({ blocked = false })
end

---Whether a number is currently blocked by the requesting player. Read-only, scoped to their
---own block list.
---@param source number
---@param payload { number?: string }
---@return table
function actions.isBlocked(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    return ok({ blocked = store.isBlocked(cid, payload.number) })
end

return actions
