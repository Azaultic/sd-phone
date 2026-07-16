---@type table AirShare core (server.share.core): request handshake + server-side proximity checks.
local share = require 'server.share.core'

---Deliver an accepted single-song share: push the track to the recipient's client. The music
---library lives client-side (localStorage in the NUI), so there is no DB row to write - this
---push IS the delivery; the recipient's client merges the track into its library even while the
---Music app is closed. Runs only after the recipient explicitly accepted, via the AirShare
---handshake in server.share.core. The track table is sender-supplied and forwarded verbatim;
---the accept is the recipient's consent to receive it.
---@param targetSrc number recipient server id
---@param payload table share payload ({ track: table })
---@return boolean delivered
local function deliverTrack(targetSrc, payload)
    if type(payload) ~= 'table' or type(payload.track) ~= 'table' then return false end
    TriggerClientEvent('sd-phone:client:music:receive', targetSrc, { kind = 'track', track = payload.track })
    return true
end

---Deliver an accepted playlist share: push the playlist name + all its tracks in one event, so
---the recipient gets the songs in their library AND a playlist folder referencing them. Same
---trust posture as deliverTrack - runs only on the recipient's accept.
---@param targetSrc number recipient server id
---@param payload table share payload ({ name: string, tracks: table[] })
---@return boolean delivered
local function deliverPlaylist(targetSrc, payload)
    if type(payload) ~= 'table' or type(payload.tracks) ~= 'table' or #payload.tracks == 0 then return false end
    TriggerClientEvent('sd-phone:client:music:receive', targetSrc, {
        kind = 'playlist', name = payload.name, tracks = payload.tracks,
    })
    return true
end

-- The two music share kinds AirShare can deliver; each handler runs on recipient accept.
share.registerHandler('music-track',    deliverTrack)
share.registerHandler('music-playlist', deliverPlaylist)

---Open an AirShare request for a song or playlist. Every trust check lives in share.request:
---`kind` must be one of the two handlers registered above (an arbitrary kind finds no handler
---and is rejected), and `target` must be a nearby player with their phone open - verified
---server-side from live coords at request time, so a crafted target can't reach a player across
---the map; the request then expires after 60s unanswered.
---@param src number sender server id
---@param payload table { target: number, kind: string, track?/name?/tracks?: any }
lib.callback.register('sd-phone:server:music:share', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end
    local ok, message = share.request(src, payload.target, payload.kind, payload)
    return { success = ok == true, message = message }
end)

---Give a track straight to a player's music library from another resource -
---exports['sd-phone']:giveTrack(source, track). Delivers through the same
---'sd-phone:client:music:receive' push as an accepted AirShare, but skips the nearby-share
---consent handshake entirely: the caller vouches for the delivery (a quest reward, a purchased
---song). `track` must be a table with non-empty string `title` and `url`; any extra fields
---(artist, artwork, duration, ...) ride along untouched - the recipient's client merges the
---table verbatim into their localStorage library, even while the Music app is closed. Returns
---false for an offline source or a malformed track instead of pushing a broken event.
---@param source number recipient server id, must be an online player
---@param track table { title: string, url: string, artist?: string, ... }
---@return boolean delivered
exports('giveTrack', function(source, track)
    if type(source) ~= 'number' or not GetPlayerName(source) then return false end
    if type(track) ~= 'table' then return false end
    if type(track.title) ~= 'string' or track.title == '' then return false end
    if type(track.url) ~= 'string' or track.url == '' then return false end
    return deliverTrack(source, { track = track })
end)
