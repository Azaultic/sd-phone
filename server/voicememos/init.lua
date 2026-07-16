---@type table sd-phone config root (configs/config.lua).
local config   = require 'configs.config'
---@type table Voice-memo persistence layer (server.voicememos.store): per-memo row CRUD.
local store    = require 'server.voicememos.store'
---@type table Authoritative voice-memo handlers (server.voicememos.actions): ownership +
---sanitisation + the share/deliver pair.
local actions  = require 'server.voicememos.actions'
---@type table Fivemanage uploader (server.photos.uploader): server-side media push, shared
---with Photos; the API key never leaves the server.
local uploader = require 'server.photos.uploader'
---@type table AirShare core (server.share.core): per-kind delivery handler registry.
local share    = require 'server.share.core'

-- Deliver an accepted voice-memo AirShare into the recipient's Voice Memos (payload was built
-- server-side from the sender's row; the handler is documented in server.voicememos.actions).
share.registerHandler('voice', actions.deliverShare)

---@type table Voice Memos config (config.VoiceMemos): list/name/size caps.
local VM = config.VoiceMemos

---@type table<number, boolean> Srcs with a Fivemanage upload currently in flight - one upload
---at a time per player, so a replayed/spammed upload event can't double-insert a memo or burn
---Fivemanage bandwidth with parallel 12MB pushes.
local uploading = {}

---A departing player's in-flight upload marker is dropped (srcs recycle across sessions).
AddEventHandler('playerDropped', function() uploading[source] = nil end)

---Bootstrap the memos schema once at boot; a failed bootstrap is reported and leaves the
---callbacks in place (they degrade to empty lists / failed saves rather than hard errors).
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:voice]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:voice]^0 schema ready')
end)

-- Authoritative NUI callbacks: thin delegates into server.voicememos.actions, which owns the
-- validation + ownership gates (each handler is documented there). Identity always comes from
-- src; the payload is type-guarded before any field access so a crafted non-table can't error.
lib.callback.register('sd-phone:server:voice:list',   function(src)          return actions.list(src) end)
lib.callback.register('sd-phone:server:voice:rename', function(src, payload) payload = type(payload) == 'table' and payload or {}; return actions.rename(src, payload.id, payload.name) end)
lib.callback.register('sd-phone:server:voice:delete', function(src, payload) payload = type(payload) == 'table' and payload or {}; return actions.delete(src, payload.id) end)
lib.callback.register('sd-phone:server:voice:share',  function(src, payload) payload = type(payload) == 'table' and payload or {}; return actions.requestShare(src, payload.target, payload.id) end)

---Audio upload: the client sends a base64 audio data-URL, we push it to Fivemanage (reusing
---the Photos uploader) and persist the hosted URL via actions.saveUploaded, which owns the
---name/duration sanitisation and the per-player cap. Reachable by any client with any payload,
---so the audio is gated up front: must be a string with a data:audio/ prefix and within
---VM.MaxAudioBytes, and only ONE upload may be in flight per src (see `uploading`) - the lock
---is released in the uploader's callback, which fires exactly once. The stored extension is
---sniffed from the MIME prefix (mp3/ogg/wav, defaulting to webm) so Fivemanage files it
---sensibly. Success pushes the saved memo back; every failure path notifies the client instead
---of failing silently.
---@param payload table client payload { audio: string, name?: string, duration?: number }
RegisterNetEvent('sd-phone:server:voice:upload', function(payload)
    local src = source
    payload = type(payload) == 'table' and payload or {}
    local audio = payload.audio

    if type(audio) ~= 'string' or audio:sub(1, 11) ~= 'data:audio/' then
        TriggerClientEvent('sd-phone:client:voice:uploadFailed', src, 'Bad audio payload')
        return
    end
    if #audio > VM.MaxAudioBytes then
        TriggerClientEvent('sd-phone:client:voice:uploadFailed', src, 'Recording is too long')
        return
    end
    if uploading[src] then
        TriggerClientEvent('sd-phone:client:voice:uploadFailed', src, 'Upload already in progress')
        return
    end

    local ext = audio:find('^data:audio/mpeg') and 'mp3'
        or audio:find('^data:audio/ogg') and 'ogg'
        or audio:find('^data:audio/wav') and 'wav'
        or 'webm'
    local filename = ('sdphone-voice-%d-%d.%s'):format(src, os.time(), ext)

    uploading[src] = true
    uploader.uploadMedia(audio, filename, function(url, err)
        uploading[src] = nil
        if not url then
            print(('^1[sd-phone:voice]^0 upload failed: %s'):format(tostring(err)))
            TriggerClientEvent('sd-phone:client:voice:uploadFailed', src, err or 'Upload failed')
            return
        end
        local memo = actions.saveUploaded(src, url, payload.name, payload.duration)
        if memo then
            TriggerClientEvent('sd-phone:client:voice:added', src, memo)
        else
            TriggerClientEvent('sd-phone:client:voice:uploadFailed', src, 'Could not save memo')
        end
    end)
end)
