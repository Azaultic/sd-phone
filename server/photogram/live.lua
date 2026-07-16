---@type table Player bridge (bridge.server.player): citizenid/source lookups.
local player    = require 'bridge.server.player'
---@type table App-accounts persistence (server.accounts.store): resolves which photogram account
---a character is signed into.
local acctStore = require 'server.accounts.store'
---@type table Photogram persistence layer (server.photogram.store): profile rows + id generator.
local store     = require 'server.photogram.store'
---@type table sd-phone config root (configs/config.lua).
local config    = require 'configs.config'

---@type table Live module; the table returned at end of file.
local live = {}

---@type table Live-video knobs (configs/photogram.lua Photogram.Live).
local CFG = (config.Photogram and config.Photogram.Live) or {}
---@type integer Concurrent viewers allowed on one stream (0 = unlimited).
local MAX_VIEWERS = tonumber(CFG.MaxViewers) or 50
---@type integer Per-viewer latent-event send ceiling (bytes/s) - paces each relayed chunk onto
---the wire instead of slamming the net thread.
local RELAY_BPS   = tonumber(CFG.RelayBytesPerSec) or 512 * 1024
---@type table Encoder hints handed to the broadcaster by live.start: target bitrate, capture
---fps, chunk cadence, and how often it re-anchors with a keyframe.
local ENC = {
    bitrate     = tonumber(CFG.Bitrate) or 900000,
    fps         = tonumber(CFG.Fps) or 25,
    timesliceMs = tonumber(CFG.TimesliceMs) or 250,
    keyframeMs  = tonumber(CFG.KeyframeMs) or 4000,
}

-- Sessions live in memory only - a live has no meaning once it ends, so nothing is persisted.
-- hostLive/viewerLive invert lives' membership so the media-push handlers and disconnect
-- cleanup resolve a source's session in O(1).
---@type table<string, table> Live sessions by liveId (host identity, transport cache, viewers).
local lives      = {}
---@type table<integer, string> liveId being broadcast, per hosting player src.
local hostLive   = {}
---@type table<integer, string> liveId being watched, per viewer src.
local viewerLive = {}

-- Ingest ceilings on the host's media pushes. A legitimate chunk is ~30 KB (Bitrate x
-- TimesliceMs, base64-inflated) and a legitimate keyframe group well under 1 MB, so these only
-- bite a modified client trying to balloon server memory or the relay fan-out.
---@type integer Base64 byte ceiling per JPEG frame / video chunk (~600 KB).
local MAX_FRAME = 600000
---@type integer Cap on cached current-GOP chunk COUNT (a runaway host that never re-anchors).
local MAX_GOP   = 240
---@type integer Cap on cached current-GOP total BYTES. MAX_GOP alone still allowed 240 max-size
---chunks (~140 MB) resident per session; 8 MB is roughly 10x a legitimate keyframe group, so
---only a hostile host ever trips it.
local MAX_GOP_BYTES = 8 * 1024 * 1024

local util = require 'server.util'
local ok, fail, trim, flag = util.ok, util.fail, util.trim, util.truthy




---Coerce a raw client payload to a table. Callback / net-event arguments are attacker-controlled
---and can arrive as nil, a number, or a string - indexing a number would raise inside the
---handler, so every entry point normalises through this before touching a field.
---@param payload any raw client payload
---@return table payload the same table, or {} for any non-table
local function tbl(payload)
    return type(payload) == 'table' and payload or {}
end

---The photogram account the character behind `src` is signed into (nil when signed out). The
---ONLY identity source for every handler in this module - usernames are never read from
---payloads.
---@param src integer player server id
---@return table|nil account accounts-engine record (username, displayName, ...)
local function viewerAccount(src)
    local cid = player.getIdentifier(src)
    if not cid then return nil end
    return acctStore.getSessionAccount('photogram', cid)
end

---A user card for relayed host/comment payloads, tolerating a missing profile row (falls back
---to a bare handle-only card) so a live never breaks on an unbootstrapped profile.
---@param username string account handle
---@return table card { id, handle, avatar, verified, name }
local function cardFor(username)
    local row = store.getProfile(username)
    if not row then return { id = username, handle = username, avatar = '', verified = false, name = username } end
    return {
        id       = row.username,
        handle   = row.username,
        avatar   = row.avatar or '',
        verified = flag(row.verified),
        name     = row.display_name or '',
    }
end

---@param session table live session
---@return integer n current viewer count (viewers is a src-keyed set, so counting walks it)
local function viewerCount(session)
    local n = 0
    for _ in pairs(session.viewers) do n = n + 1 end
    return n
end

---Every source attached to a session (host + viewers) - the relay targets.
---@param session table live session
---@return integer[] sources
local function participants(session)
    local out = { session.hostSrc }
    for src in pairs(session.viewers) do out[#out + 1] = src end
    return out
end

---Fan a session-scoped event to the host and every viewer. Only ever carries session-public
---data (ids, counts, comment text, public profile cards) - never another player's identifiers.
---@param session table live session
---@param event string event suffix under sd-phone:client:photogram:
---@param data table payload
local function relay(session, event, data)
    for _, dst in ipairs(participants(session)) do
        TriggerClientEvent('sd-phone:client:photogram:' .. event, dst, data)
    end
end

---Push the current (real) viewer count to everyone in the session.
---@param session table live session
local function pushViewers(session)
    relay(session, 'liveViewers', { liveId = session.id, viewers = viewerCount(session) })
end

---Start (or resume) a broadcast for the caller's account. Identity comes from `src` alone.
---Idempotent: a re-entrant start (double-tap, app re-open while already live) returns the
---existing session instead of minting a second one, so one source can never host two lives. The
---session records which transport the host settles on once content arrives: 'image' is the
---legacy JPEG slideshow (the host's CEF lacks the video encoder), 'video' the real encoded
---stream whose codec header + current keyframe group are cached for clean late-joins. The empty
---liveChanged broadcast makes every phone refresh its stories tray so followers see the live
---ring - it deliberately carries no data, since WHO may see the live is decided per viewer by
---live.activeForViewer.
---@param src integer hosting player server id
---@return table result { liveId, startedAt (ms), enc } or failure
function live.start(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end

    local existing = hostLive[src]
    if existing and lives[existing] then
        return ok({ liveId = existing, startedAt = lives[existing].startedAt * 1000, enc = ENC })
    end

    local id = store.newId()
    lives[id] = {
        id        = id,
        host      = acc.username,
        card      = cardFor(acc.username),
        hostSrc   = src,
        startedAt = os.time(),
        mode      = nil,    -- 'image' (JPEG slideshow) | 'video' (encoded stream), set on first content
        frame     = nil,    -- latest JPEG (image mode)
        videoMime = nil,    -- e.g. 'video/webm;codecs=vp8' (video mode)
        header    = nil,    -- init chunk that carries the codec config (video mode)
        genChunks = nil,    -- chunks since the last keyframe anchor (video mode)
        genBytes  = 0,      -- total bytes cached in genChunks
        viewers   = {},     -- [src] = username
    }
    hostLive[src] = id

    TriggerClientEvent('sd-phone:client:photogram:liveChanged', -1, {})
    return ok({ liveId = id, startedAt = lives[id].startedAt * 1000, enc = ENC })
end

---Host JPEG push (latent net event, not a callback) - the fallback path for CEF builds without
---the video encoder. Trust posture: only the session's recorded hostSrc may feed it (the host
---was authenticated at live.start), so a forged liveId from anyone else is a silent no-op; the
---frame must be a non-empty string under MAX_FRAME. The latest frame is kept on the session so
---a late joiner gets a picture immediately, then relayed to current viewers.
---@param src integer sender server id (must be the session host)
---@param payload table { liveId, frame } attacker-controlled
function live.frame(src, payload)
    payload = tbl(payload)
    local session = lives[payload.liveId]
    if not session or session.hostSrc ~= src then return end
    local frame = payload.frame
    if type(frame) ~= 'string' or #frame == 0 or #frame > MAX_FRAME then return end

    session.mode  = 'image'
    session.frame = frame
    for viewerSrc in pairs(session.viewers) do
        TriggerLatentClientEvent('sd-phone:client:photogram:liveFrame', viewerSrc, 256 * 1024, { liveId = session.id, frame = frame })
    end
end

---Host video chunk push (latent net event) - the real-time path: the broadcaster encodes its
---camera view to a VP8/VP9 stream and ships ~quarter-second chunks. Trust posture matches
---live.frame: host-only, string-typed, MAX_FRAME-capped. `init` chunks carry the codec header
---and re-anchor the stream (a fresh keyframe group), so the latest header is cached and the GOP
---buffer reset; media chunks append to that buffer under BOTH caps (MAX_GOP chunks and
---MAX_GOP_BYTES bytes, oldest dropped first) so a hostile host that never re-anchors can't grow
---server-resident memory unbounded. Every chunk is relayed to current viewers; the cached
---header + GOP let a late joiner start cleanly (see live.join).
---@param src integer sender server id (must be the session host)
---@param payload table { liveId, chunk, init?, mime? } attacker-controlled
function live.chunk(src, payload)
    payload = tbl(payload)
    local session = lives[payload.liveId]
    if not session or session.hostSrc ~= src then return end
    local chunk = payload.chunk
    if type(chunk) ~= 'string' or #chunk == 0 or #chunk > MAX_FRAME then return end

    local isInit = payload.init == true
    session.mode = 'video'
    if isInit then
        if type(payload.mime) == 'string' and payload.mime ~= '' then
            session.videoMime = payload.mime:sub(1, 64)
        end
        session.header    = chunk
        session.genChunks = {}
        session.genBytes  = 0
    else
        local gop = session.genChunks
        if gop then
            gop[#gop + 1] = chunk
            session.genBytes = (session.genBytes or 0) + #chunk
            while #gop > 0 and (#gop > MAX_GOP or session.genBytes > MAX_GOP_BYTES) do
                session.genBytes = session.genBytes - #gop[1]
                table.remove(gop, 1)
            end
        end
    end

    local data = { liveId = session.id, chunk = chunk, init = isInit }
    if isInit then data.mime = session.videoMime end
    for viewerSrc in pairs(session.viewers) do
        TriggerLatentClientEvent('sd-phone:client:photogram:liveChunk', viewerSrc, RELAY_BPS, data)
    end
end

---Join a live as a viewer. The caller must be signed in, and the host's account privacy is
---enforced HERE - not only in the stories tray that live.activeForViewer filters - so a leaked
---or guessed liveId can't watch a private account the viewer doesn't follow; the refusal
---deliberately reads as an ended live so probing can't confirm one exists. The host joining
---their own live is refused (they're already broadcasting). Capacity (MAX_VIEWERS, 0 =
---unlimited) only gates NEW viewers - a re-join by someone already watching always succeeds.
---Joining while attached to a DIFFERENT live detaches from that one first, keeping the
---one-live-per-viewer invariant that leave / playerDropped cleanup relies on. In video mode the
---cached codec header + current keyframe group replay to just this viewer so they decode a
---clean picture right away - sent before any further live chunk can reach them (those only fire
---on the next host tick), so ordering holds.
---@param src integer viewer server id
---@param payload table { liveId } attacker-controlled
---@return table result { liveId, host, mode, mime, frame, viewers, startedAt (ms) } or failure
function live.join(src, payload)
    payload = tbl(payload)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local session = lives[payload.liveId]
    if not session then return fail('This live has ended') end
    if session.hostSrc == src then return fail('You are the host') end

    local hostRow = store.getProfile(session.host)
    local visible = hostRow and (not flag(hostRow.is_private) or store.isAcceptedFollower(acc.username, session.host))
    if not visible then return fail('This live has ended') end

    if not session.viewers[src] and MAX_VIEWERS > 0 and viewerCount(session) >= MAX_VIEWERS then
        return fail('This live is full')
    end

    local prior = viewerLive[src]
    if prior and prior ~= session.id then
        local old = lives[prior]
        if old and old.viewers[src] then
            old.viewers[src] = nil
            pushViewers(old)
        end
    end

    session.viewers[src] = acc.username
    viewerLive[src] = session.id
    pushViewers(session)

    if session.mode == 'video' and session.header then
        TriggerLatentClientEvent('sd-phone:client:photogram:liveChunk', src, RELAY_BPS,
            { liveId = session.id, chunk = session.header, init = true, mime = session.videoMime })
        if session.genChunks then
            for _, chunk in ipairs(session.genChunks) do
                TriggerLatentClientEvent('sd-phone:client:photogram:liveChunk', src, RELAY_BPS,
                    { liveId = session.id, chunk = chunk, init = false })
            end
        end
    end

    return ok({
        liveId    = session.id,
        host      = session.card,
        mode      = session.mode,
        mime      = session.videoMime,
        frame     = session.frame,
        viewers   = viewerCount(session),
        startedAt = session.startedAt * 1000,
    })
end

---Leave a live. Scoped to the caller's own membership (only session.viewers[src] is ever
---touched), so a forged liveId can't evict anyone else. Falls back to the caller's tracked live
---when the payload omits the id (the disconnect-cleanup path). Always reports success - leaving
---twice, or leaving a live that already ended, is a no-op.
---@param src integer viewer server id
---@param payload table { liveId? } attacker-controlled
---@return table result success envelope
function live.leave(src, payload)
    payload = tbl(payload)
    local id = payload.liveId or viewerLive[src]
    local session = id and lives[id]
    if session and session.viewers[src] then
        session.viewers[src] = nil
        viewerLive[src] = nil
        pushViewers(session)
    end
    return ok()
end

---Post an ephemeral comment to a live - relayed to everyone in the session, never persisted
---(the session dies with the stream). Only the host or an active viewer may comment, so an
---outsider can't inject text into a stream they're not watching. Text is trimmed and capped at
---200 chars; an empty result is silently absorbed.
---@param src integer sender server id
---@param payload table { liveId, text } attacker-controlled
---@return table result success envelope
function live.comment(src, payload)
    payload = tbl(payload)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local session = lives[payload.liveId]
    if not session then return fail('This live has ended') end
    if session.hostSrc ~= src and not session.viewers[src] then return fail('Not in this live') end

    local text = trim(payload.text):sub(1, 200)
    if text == '' then return ok() end

    relay(session, 'liveComment', {
        liveId  = session.id,
        comment = { id = store.newId(), user = cardFor(acc.username), text = text },
    })
    return ok()
end

---Float a heart on a live. Same membership gate as comments, but every outcome - unknown live,
---outsider - returns plain success, so hearts can't be used to probe which liveIds exist.
---@param src integer sender server id
---@param payload table { liveId } attacker-controlled
---@return table result success envelope
function live.heart(src, payload)
    payload = tbl(payload)
    local session = lives[payload.liveId]
    if not session then return ok() end
    if session.hostSrc ~= src and not session.viewers[src] then return ok() end
    relay(session, 'liveHeart', { liveId = session.id })
    return ok()
end

---End a broadcast. Host-only: a forged or someone else's liveId fails the hostSrc check and
---returns plain success - nothing changed, nothing to learn. Every viewer is kicked out of the
---watch screen (their viewerLive pointer cleared first so a subsequent leave / disconnect can't
---double-fire on a dead session), the session is dropped, and every phone is told to refresh
---its stories tray so the live ring disappears.
---@param src integer hosting player server id
---@param payload table { liveId? } attacker-controlled (falls back to the caller's hosted live)
---@return table result success envelope
function live.endLive(src, payload)
    payload = tbl(payload)
    local id = payload.liveId or hostLive[src]
    local session = id and lives[id]
    if not session or session.hostSrc ~= src then return ok() end

    for viewerSrc in pairs(session.viewers) do
        viewerLive[viewerSrc] = nil
        TriggerClientEvent('sd-phone:client:photogram:liveEnded', viewerSrc, { liveId = session.id })
    end
    lives[id] = nil
    hostLive[src] = nil

    TriggerClientEvent('sd-phone:client:photogram:liveChanged', -1, {})
    return ok()
end

---Active lives the given account is allowed to watch (public hosts, or private hosts they
---accepted-follow), newest first - merged into the stories tray by actions.stories, which
---resolves `username` from its own authenticated session. Visibility twin of the gate in
---live.join: both must agree, or the tray would advertise lives the join then refuses (or a
---join would admit viewers the tray hides). Read-only.
---@param username string viewer account handle
---@return table[] lives [{ user, liveId, startedAt (ms) }]
function live.activeForViewer(username)
    local out = {}
    for _, session in pairs(lives) do
        if session.host ~= username then
            local hostRow = store.getProfile(session.host)
            local visible = hostRow and (not flag(hostRow.is_private) or store.isAcceptedFollower(username, session.host))
            if visible then
                out[#out + 1] = { user = session.card, liveId = session.id, startedAt = session.startedAt * 1000 }
            end
        end
    end
    table.sort(out, function(a, b) return a.startedAt > b.startedAt end)
    return out
end

---A departing player's live state is torn down (srcs recycle across sessions): a hosted live
---ends for everyone, a watched live loses them as a viewer. Both paths reuse the exact code the
---explicit callbacks run, so disconnect cleanup can never drift from the user-initiated flows.
AddEventHandler('playerDropped', function()
    local src = source
    local hid = hostLive[src]
    if hid then live.endLive(src, { liveId = hid }) end
    local vid = viewerLive[src]
    if vid then live.leave(src, { liveId = vid }) end
end)

return live
