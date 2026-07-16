---@type table Player bridge (bridge.server.player): citizenid/name/source lookups.
local player   = require 'bridge.server.player'
---@type table Settings persistence (server.settings.store): phone numbers, airplane mode, number-owner lookups.
local settings = require 'server.settings.store'
---@type table Contacts persistence (server.contacts.store): contact rows, recents log, block list.
local contacts = require 'server.contacts.store'
---@type table sd-phone config root (configs/config.lua).
local config   = require 'configs.config'
---@type table Badge engine (server.badges.init): server-authoritative unread badge pushes.
local badges   = require 'server.badges.init'

---@type table Actions module; the table returned at end of file.
local actions = {}

-- Live call state is transient and in-memory - only a FINISHED call is persisted, to each
-- side's recents log. Channels double as pma-voice call channels and are handed out
-- monotonically from 1000, so a stale client event can never collide with a newer call's
-- channel within a server run.
---@type table<number, table> Active 1:1 sessions keyed by channel: { channel, state ('ringing'|'active'), startedAt, caller, callee, company? (display name when promoted from a group ring) }.
local sessions = {}
---@type number Next pma-voice call channel to hand out.
local nextChannel = 1000

-- Pending "ring everyone" group calls (e.g. calling a company's on-duty staff), keyed by
-- channel. Unlike `sessions` these have MANY ringing callees; the first to accept is promoted
-- into a normal 1:1 `sessions` entry and the rest are cancelled. Nothing is persisted until a
-- promoted call ends.
---@type table<number, table> Pending group rings keyed by channel: { channel, caller, targets = { [src] = callee }, display }.
local groupRings = {}

local util = require 'server.util'
local ok, fail, digits = util.ok, util.fail, util.digits



---Find the channel + session a source is currently part of (as caller or callee).
---@param src number
---@return number|nil channel, table|nil session
local function sessionForSource(src)
    for channel, session in pairs(sessions) do
        if session.caller.src == src or session.callee.src == src then
            return channel, session
        end
    end
    return nil
end

---Find the group ring (+ channel) a source belongs to, as the caller or a ringer.
---@param src number
---@return number|nil channel, table|nil ring
local function ringForSource(src)
    for channel, ring in pairs(groupRings) do
        if ring.caller.src == src or ring.targets[src] then return channel, ring end
    end
    return nil
end

---Resolve a number to a saved-contact name for a given owner, or nil. Nil-guarded on the owner
---so a player dropping mid-callback can't push a nil citizenid into the contacts query.
---@param citizenid string|nil
---@param numberDigits string
---@return string|nil
local function contactNameFor(citizenid, numberDigits)
    if not citizenid then return nil end
    local rows = contacts.listContacts(citizenid)
    for i = 1, #rows do
        if digits(rows[i].phone) == numberDigits then return rows[i].name end
    end
    return nil
end

---Move a player in/out of a pma-voice call channel, pcall-guarded so a voice-resource hiccup
---can't break call signaling.
---@param src number
---@param channel number
local function setVoice(src, channel)
    pcall(function() exports['pma-voice']:setPlayerCall(src, channel) end)
end

---Persist one side of a finished call to its owner's recents log, pruning to the configured
---cap (config.Contacts.MaxRecents) so the log stays bounded.
---@param citizenid string
---@param number string
---@param name string|nil
---@param direction string
---@param duration number
local function logCall(citizenid, number, name, direction, duration)
    contacts.insertCall(contacts.newId(), citizenid, {
        number    = number,
        name      = name,
        direction = direction,
        duration  = duration,
        calledAt  = os.time(),
    })
    contacts.pruneCalls(citizenid, config.Contacts.MaxRecents)
end

---Reshape one stored call party for a first-party lifecycle event payload: the internal
---src/cid keys become source/citizenid, and the fresh copy keeps consumers from mutating live
---session state. Nil in, nil out, so an unknown party is simply absent.
---@param p { src: number, cid: string, name: string, number: string }|nil
---@return { source: number, citizenid: string, name: string, number: string }|nil
local function eventParty(p)
    if not p then return nil end
    return { source = p.src, citizenid = p.cid, name = p.name, number = p.number }
end

---Shared payload for the first-party 'sd-phone:server:call:*' lifecycle events, built ONLY
---from a stored session table - never fresh bridge lookups, which can fail while a participant
---is disconnecting. company is the ring's display name on a promoted company/group call and
---nil on a plain 1:1 call.
---@param s table session from `sessions`
---@return table
local function eventCall(s)
    return {
        channel = s.channel,
        company = s.company,
        caller  = eventParty(s.caller),
        callee  = eventParty(s.callee),
    }
end

---Ring variant of eventCall for a group ring that never got answered: there is no single
---callee, so callee stays nil, company is the ring's display name and targets lists everyone
---still ringing at the time of the event. Same rule as eventCall: stored ring state only,
---never fresh lookups.
---@param ring table ring from `groupRings`
---@return table
local function eventRing(ring)
    local targets = {}
    for _, t in pairs(ring.targets) do targets[#targets + 1] = eventParty(t) end
    return {
        channel = ring.channel,
        company = ring.display.name,
        caller  = eventParty(ring.caller),
        targets = targets,
    }
end

---Tear a call down: drop both sides from voice (only if the call went active), persist both
---recents rows, and notify both clients so their UI closes and recents refresh. The caller
---always logs 'outgoing'; the callee logs 'incoming' when answered, else 'missed' - and a
---missed call lights the callee's home-screen Phone badge. Idempotent: an unknown or
---already-ended channel is a no-op, so replayed hangups change nothing. Fires the first-party
---'sd-phone:server:call:ended' lifecycle event as (call, endedBy) with answered, duration and
---reason folded into the payload; the payload comes from the stored session only, never fresh
---bridge lookups, so it stays correct when the teardown came from a player disconnect.
---@param channel number
---@param reason string
---@param endedBy number|nil source that caused the teardown, nil when it came from a disconnect
local function endCall(channel, reason, endedBy)
    local s = sessions[channel]
    if not s then return end
    sessions[channel] = nil

    if s.state == 'active' then
        setVoice(s.caller.src, 0)
        setVoice(s.callee.src, 0)
    end

    local answered = s.state == 'active'
    local duration = (answered and s.startedAt) and (os.time() - s.startedAt) or 0

    logCall(s.caller.cid, s.callee.number, s.callee.name, 'outgoing', duration)
    logCall(s.callee.cid, s.caller.number, s.caller.name, answered and 'incoming' or 'missed', duration)

    if not answered then badges.push(s.callee.src) end

    TriggerClientEvent('sd-phone:client:call:ended', s.caller.src, { channel = channel, reason = reason })
    TriggerClientEvent('sd-phone:client:call:ended', s.callee.src, { channel = channel, reason = reason })

    -- Server-local lifecycle event, synchronous: the call is over; payload is the stored session reshaped, never fresh lookups.
    local call = eventCall(s)
    call.answered = answered
    call.duration = duration
    call.reason   = reason
    TriggerEvent('sd-phone:server:call:ended', call, endedBy)
end

actions.endCall = endCall

---Start a call to a dialed number. The caller's identity comes from src only; the payload
---contributes nothing but the dialed digits, so a crafted payload can't spoof who is calling.
---The caller's own number is read through ensurePhoneNumber (idempotent, mirrors actions.list),
---so an export-originated call from a player who has never opened their phone still presents a
---real assigned number instead of '' on the callee's screen and in both recents logs.
---Rejects when the caller is already mid-call/ring or in airplane mode, when the number is
---unassigned, and when the callee is unreachable. Offline, airplane mode, and having blocked
---the caller all return the SAME wording on purpose, so a caller can't probe whether they've
---been blocked. A callee already in a session OR a pending group ring reports busy, keeping the
---one-call-at-a-time invariant on both ends (the caller-side check already enforced both). On
---success both sides get their ring events and the session waits in 'ringing'.
---@param source number caller server id
---@param payload { number?: string }
---@return table
function actions.dial(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    local dialed = digits(payload.number)
    if dialed == '' then return fail('No number dialed') end
    if sessionForSource(source) or ringForSource(source) then return fail('You are already on a call') end
    if settings.isAirplane(cid) then return fail('Airplane Mode is on') end

    local myNumber = settings.ensurePhoneNumber(cid)
    if myNumber and digits(myNumber) == dialed then return fail('You can\'t call yourself') end

    local targetCid = settings.getCitizenByNumber(dialed)
    if not targetCid then return fail('Number not in service') end

    local targetSrc = player.getSourceByIdentifier(targetCid)
    if not targetSrc then return fail('This number is currently unavailable') end
    if settings.isAirplane(targetCid) then return fail('This number is currently unavailable') end
    if contacts.isBlocked(targetCid, digits(myNumber)) then return fail('This number is currently unavailable') end
    if sessionForSource(targetSrc) or ringForSource(targetSrc) then return fail('Line busy') end

    local channel = nextChannel
    nextChannel = nextChannel + 1

    sessions[channel] = {
        channel   = channel,
        state     = 'ringing',
        startedAt = nil,
        caller    = { src = source,    cid = cid,       name = player.getName(source),    number = digits(myNumber) },
        callee    = { src = targetSrc, cid = targetCid, name = player.getName(targetSrc), number = dialed },
    }

    TriggerClientEvent('sd-phone:client:call:outgoing', source, {
        channel = channel,
        name    = contactNameFor(cid, dialed),
        number  = dialed,
    })
    TriggerClientEvent('sd-phone:client:call:incoming', targetSrc, {
        channel = channel,
        name    = contactNameFor(targetCid, sessions[channel].caller.number),
        number  = sessions[channel].caller.number,
    })

    -- Server-local lifecycle event, synchronous: a 1:1 call just started ringing; payload is the stored session reshaped.
    TriggerEvent('sd-phone:server:call:started', eventCall(sessions[channel]))

    return ok({ channel = channel })
end

---Ring a set of recipients at once (a company's on-duty staff). Not registered as a client
---callback - reachable only server-side (services' callCompany and the startGroupCall export
---wrapper in init.lua), both of which build `targets` themselves, so nothing here is
---attacker-controlled. The caller sees a single
---outgoing call to `displayName`/`displayNumber`; every recipient rings as an incoming call
---from the caller (resolved to a saved-contact name where they have one). The caller's own
---number is read through ensurePhoneNumber, so a caller who has never opened their phone still
---rings out with a real assigned number instead of ''. Recipients who are
---the caller themselves, already in a call or ring, or in airplane mode are filtered out here;
---if nobody survives the filter the caller is told so and nothing rings. The FIRST to accept
---is connected and the rest are cancelled (see actions.accept).
---@param source number caller server id
---@param targets { src: number, cid: string }[] server-built recipient list
---@param displayName string what the caller sees they're calling (e.g. 'Police')
---@param displayNumber? string
---@return table
function actions.callGroup(source, targets, displayName, displayNumber)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if sessionForSource(source) or ringForSource(source) then return fail('You are already on a call') end
    if settings.isAirplane(cid) then return fail('Airplane Mode is on') end

    local myNumber = digits(settings.ensurePhoneNumber(cid))

    local ringTargets = {}
    for _, t in ipairs(targets) do
        if t.src and t.src ~= source
            and not sessionForSource(t.src) and not ringForSource(t.src)
            and not settings.isAirplane(t.cid) then
            ringTargets[t.src] = {
                src    = t.src,
                cid    = t.cid,
                name   = player.getName(t.src),
                number = digits(settings.getPhoneNumber(t.cid)),
            }
        end
    end
    if next(ringTargets) == nil then return fail('No one is available right now') end

    local channel = nextChannel
    nextChannel = nextChannel + 1
    groupRings[channel] = {
        channel = channel,
        caller  = { src = source, cid = cid, name = player.getName(source), number = myNumber },
        targets = ringTargets,
        display = { name = displayName, number = digits(displayNumber) },
    }

    TriggerClientEvent('sd-phone:client:call:outgoing', source, {
        channel = channel, name = displayName, number = digits(displayNumber),
    })
    for tsrc, t in pairs(ringTargets) do
        TriggerClientEvent('sd-phone:client:call:incoming', tsrc, {
            channel = channel,
            name    = contactNameFor(t.cid, myNumber),
            number  = myNumber,
        })
    end

    -- Server-local lifecycle event, synchronous: a company/group ring just started; no callee yet, targets lists every ringer.
    TriggerEvent('sd-phone:server:call:started', eventRing(groupRings[channel]))

    return ok({ channel = channel })
end

---Callee answers. On a group ring the FIRST acceptor wins: the ring is promoted into a normal
---active session and every other ringer is cancelled. The promoted callee record keeps the
---acceptor's src/cid (they drive voice + their recents) but the COMPANY's display name/number
---(what the caller sees + logs), falling back to the employee's own number when the company has
---none. On a 1:1 session only the ringing callee may answer - a forged accept on someone else's
---channel fails, and a replayed accept fails the 'ringing' state check, so answering is
---idempotent. Marks the session active, joins both sides to the pma-voice channel and notifies
---both clients.
---@param source number
---@param payload { channel?: number }
---@return table
function actions.accept(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local channel = tonumber(payload.channel)

    local ring = channel and groupRings[channel]
    if ring then
        local t = ring.targets[source]
        if not t then return fail('Call no longer active') end
        groupRings[channel] = nil
        for other in pairs(ring.targets) do
            if other ~= source then
                TriggerClientEvent('sd-phone:client:call:ended', other, { channel = channel, reason = 'answered' })
            end
        end
        sessions[channel] = {
            channel = channel, state = 'active', startedAt = os.time(),
            company = ring.display.name,
            caller  = ring.caller,
            callee  = {
                src    = t.src, cid = t.cid,
                name   = ring.display.name,
                number = ring.display.number ~= '' and ring.display.number or t.number,
            },
        }
        setVoice(ring.caller.src, channel)
        setVoice(t.src, channel)
        TriggerClientEvent('sd-phone:client:call:connected', ring.caller.src, { channel = channel })
        TriggerClientEvent('sd-phone:client:call:connected', t.src, { channel = channel })

        -- Server-local lifecycle event, synchronous: the group ring was answered; payload is the promoted session reshaped.
        local s = sessions[channel]
        local call = eventCall(s)
        call.startedAt = s.startedAt
        TriggerEvent('sd-phone:server:call:answered', call)

        return ok({ channel = channel })
    end

    local s = channel and sessions[channel]
    if not s then return fail('Call no longer active') end
    if s.callee.src ~= source then return fail('Not your call') end
    if s.state ~= 'ringing' then return fail('Call not ringing') end

    s.state = 'active'
    s.startedAt = os.time()

    setVoice(s.caller.src, channel)
    setVoice(s.callee.src, channel)

    TriggerClientEvent('sd-phone:client:call:connected', s.caller.src, { channel = channel })
    TriggerClientEvent('sd-phone:client:call:connected', s.callee.src, { channel = channel })

    -- Server-local lifecycle event, synchronous: the call was answered; payload is the stored session reshaped.
    local call = eventCall(s)
    call.startedAt = s.startedAt
    TriggerEvent('sd-phone:server:call:answered', call)

    return ok({ channel = channel })
end

---Callee declines. On a group ring a recipient declining just drops them from the ring; when
---the LAST one declines, the ring is torn down, the caller's outgoing side ends as
---'unavailable' and their attempt is logged to recents. On a 1:1 session only the callee may
---decline (the caller cancels via hangup instead), and someone else's decline can't end a call
---they aren't in. An unknown channel returns success - the call already ended, nothing to do.
---@param source number
---@param payload { channel?: number }
---@return table
function actions.decline(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local channel = tonumber(payload.channel)

    local ring = channel and groupRings[channel]
    if ring then
        if ring.targets[source] then
            ring.targets[source] = nil
            TriggerClientEvent('sd-phone:client:call:ended', source, { channel = channel, reason = 'declined' })
            if next(ring.targets) == nil then
                groupRings[channel] = nil
                TriggerClientEvent('sd-phone:client:call:ended', ring.caller.src, { channel = channel, reason = 'unavailable' })
                logCall(ring.caller.cid, ring.display.number ~= '' and ring.display.number or ring.display.name,
                        ring.display.name, 'outgoing', 0)

                -- Server-local lifecycle event, synchronous: the last ringer declined so the group ring ended unanswered; payload from the stored ring.
                local call = eventRing(ring)
                call.answered = false
                call.duration = 0
                call.reason   = 'declined'
                TriggerEvent('sd-phone:server:call:ended', call, source)
            end
        end
        return ok()
    end

    local s = channel and sessions[channel]
    if not s then return ok() end
    if s.callee.src ~= source then return fail('Not your call') end

    endCall(channel, 'declined', source)
    return ok()
end

---Either party hangs up. On a group ring the CALLER hanging up cancels the whole ring for every
---recipient and logs the attempt; a recipient hanging up on the ring is just a decline. On a
---1:1 session either member may end it (cancelling a ring or ending an active call); anyone
---else is rejected, so a crafted channel can't end someone else's call. An unknown channel
---returns success - the call already ended.
---@param source number
---@param payload { channel?: number }
---@return table
function actions.hangup(source, payload)
    if type(payload) ~= 'table' then payload = {} end
    local channel = tonumber(payload.channel)

    local ring = channel and groupRings[channel]
    if ring then
        if ring.caller.src == source then
            groupRings[channel] = nil
            for tsrc in pairs(ring.targets) do
                TriggerClientEvent('sd-phone:client:call:ended', tsrc, { channel = channel, reason = 'hangup' })
            end
            TriggerClientEvent('sd-phone:client:call:ended', source, { channel = channel, reason = 'hangup' })
            logCall(ring.caller.cid, ring.display.number ~= '' and ring.display.number or ring.display.name,
                    ring.display.name, 'outgoing', 0)

            -- Server-local lifecycle event, synchronous: the caller cancelled the ring before anyone answered; payload from the stored ring.
            local call = eventRing(ring)
            call.answered = false
            call.duration = 0
            call.reason   = 'hangup'
            TriggerEvent('sd-phone:server:call:ended', call, source)
        elseif ring.targets[source] then
            return actions.decline(source, payload)
        end
        return ok()
    end

    local s = channel and sessions[channel]
    if not s then return ok() end
    if s.caller.src ~= source and s.callee.src ~= source then return fail('Not your call') end

    endCall(channel, 'hangup', source)
    return ok()
end

---Report the caller's live call from their own perspective, or nil. Lets the UI re-sync after
---the phone was closed and reopened mid-call, so a call can never be left running with no way
---to hang up. A pending group ring re-syncs the same way: the caller sees their outgoing
---company call, a ringer sees the incoming call (with a way to answer or dismiss it).
---Read-only and scoped to src's own session.
---@param source number
---@return table
function actions.current(source)
    local channel, s = sessionForSource(source)
    if not s then
        local rchannel, ring = ringForSource(source)
        if ring then
            if ring.caller.src == source then
                return ok({ channel = rchannel, phase = 'outgoing',
                            number = ring.display.number, name = ring.display.name, elapsed = 0 })
            end
            return ok({ channel = rchannel, phase = 'incoming',
                        number = ring.caller.number,
                        name   = contactNameFor(player.getIdentifier(source), ring.caller.number), elapsed = 0 })
        end
        return ok(nil)
    end

    local meCaller = s.caller.src == source
    local peer = meCaller and s.callee or s.caller
    local phase = s.state == 'active' and 'active' or (meCaller and 'outgoing' or 'incoming')
    local elapsed = (s.state == 'active' and s.startedAt) and (os.time() - s.startedAt) or 0

    return ok({
        channel = channel,
        phase   = phase,
        number  = peer.number,
        name    = contactNameFor(player.getIdentifier(source), peer.number),
        elapsed = elapsed,
    })
end

-- Video calling is layered on top of an existing voice call: audio stays on pma-voice, the
-- picture is a peer-to-peer WebRTC stream between the two clients' CEF instances. The server
-- only relays signaling (offer/answer/ICE) to the OTHER member of the sender's live session -
-- never to anyone else - so a crafted event can't push video signaling at an arbitrary player.

---The source of the other party in `src`'s current call, or nil. Nil outside a live 1:1
---session (a still-pending group ring has no single peer yet), which is what gates every
---video relay below.
---@param src number
---@return number|nil
local function peerSrc(src)
    local _, s = sessionForSource(src)
    if not s then return nil end
    if s.caller.src == src then return s.callee.src end
    if s.callee.src == src then return s.caller.src end
    return nil
end

---Relay a WebRTC signaling blob to the call peer, verbatim and opaque - the server never
---inspects SDP/ICE contents. Dropped silently when the sender isn't in a live call.
---@param src number
---@param payload any opaque signaling blob
function actions.videoSignal(src, payload)
    local peer = peerSrc(src)
    if peer then TriggerClientEvent('sd-phone:client:call:video:signal', peer, payload) end
end

---Tell the peer this side wants to start video. Dropped silently outside a live call.
---@param src number
function actions.videoRequest(src)
    local peer = peerSrc(src)
    if peer then TriggerClientEvent('sd-phone:client:call:video:request', peer) end
end

---Tell the peer this side accepted their video request. Dropped silently outside a live call.
---@param src number
function actions.videoAccept(src)
    local peer = peerSrc(src)
    if peer then TriggerClientEvent('sd-phone:client:call:video:accept', peer) end
end

---Tell the peer this side stopped video (audio call continues). Dropped silently outside a
---live call.
---@param src number
function actions.videoStop(src)
    local peer = peerSrc(src)
    if peer then TriggerClientEvent('sd-phone:client:call:video:stop', peer) end
end

---ICE servers for the browser RTCPeerConnection. Google STUN by default; a TURN relay (for
---symmetric-NAT players) is added when the sd_phone_turn_* convars are set. The TURN credential
---is necessarily handed to any client that asks - the browser needs it verbatim to connect -
---so deployments should use dedicated throwaway TURN credentials, never a shared secret.
---@return { iceServers: table }
function actions.iceConfig()
    local servers = { { urls = 'stun:stun.l.google.com:19302' } }
    local turn = GetConvar('sd_phone_turn_url', '')
    if turn ~= '' then
        servers[#servers + 1] = {
            urls       = turn,
            username   = GetConvar('sd_phone_turn_username', ''),
            credential = GetConvar('sd_phone_turn_credential', ''),
        }
    end
    return { iceServers = servers }
end

---End whatever call a dropped player was in, so per-src state can't leak or collide when srcs
---recycle. A live session tears down normally ('disconnected'); a group-ring CALLER dropping
---cancels the whole ring for every recipient, and a dropping ringer is removed - ending the
---ring as 'unavailable' if they were the last one still ringing.
---@param src number
function actions.onDrop(src)
    local channel = sessionForSource(src)
    if channel then endCall(channel, 'disconnected'); return end

    local rchannel, ring = ringForSource(src)
    if not ring then return end
    if ring.caller.src == src then
        groupRings[rchannel] = nil
        for tsrc in pairs(ring.targets) do
            TriggerClientEvent('sd-phone:client:call:ended', tsrc, { channel = rchannel, reason = 'disconnected' })
        end

        -- Server-local lifecycle event, synchronous: the ring's caller disconnected; payload from the stored ring, no lookups on the dropping src.
        local call = eventRing(ring)
        call.answered = false
        call.duration = 0
        call.reason   = 'disconnected'
        TriggerEvent('sd-phone:server:call:ended', call)
    else
        ring.targets[src] = nil
        if next(ring.targets) == nil then
            groupRings[rchannel] = nil
            TriggerClientEvent('sd-phone:client:call:ended', ring.caller.src, { channel = rchannel, reason = 'unavailable' })

            -- Server-local lifecycle event, synchronous: the last ringer disconnected leaving nobody to answer; payload from the stored ring.
            local call = eventRing(ring)
            call.answered = false
            call.duration = 0
            call.reason   = 'unavailable'
            TriggerEvent('sd-phone:server:call:ended', call)
        end
    end
end

return actions
