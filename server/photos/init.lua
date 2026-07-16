---@type table Photos persistence layer (server.photos.store): photo/album row CRUD.
local store    = require 'server.photos.store'
---@type table Authoritative photo/album handlers (server.photos.actions).
local actions  = require 'server.photos.actions'
---@type table Fivemanage uploader (server.photos.uploader): server-side base64 media upload.
local uploader = require 'server.photos.uploader'
---@type table Shared server helpers (server.util): finite-number guard for the export boundary.
local util     = require 'server.util'

---Schema bootstrap. Runs in a thread so it can yield until oxmysql is ready without blocking
---resource start; a failure is loud but non-fatal so the rest of the phone still boots.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:photos]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    print('^2[sd-phone:photos]^0 schema ready')
end)

-- Authoritative gallery-read callback: thin delegate into server.photos.actions, which owns
-- the identity resolution (documented there).
lib.callback.register('sd-phone:server:photos:list', function(src)
    return actions.list(src)
end)

-- Hard payload ceilings for the capture upload. The whole event payload has already crossed
-- the wire by the time this handler runs (inherent to FiveM events), so these caps protect
-- the Fivemanage quota and the DB - not receive bandwidth. Base64 inflates by ~4/3.
---@type integer Max accepted photo data-URL size in bytes (~4 MB - any shutter JPEG fits).
local MAX_PHOTO_BYTES <const> = 4  * 1024 * 1024
---@type integer Max accepted video data-URL size in bytes (~32 MB - base64 of a <=60s clip + headroom).
local MAX_VIDEO_BYTES <const> = 32 * 1024 * 1024

---Capture path: the Camera app renders the live game view into a NUI canvas and the shutter
---grabs it as a base64 data-URL - a JPEG photo, or a webm/mp4 video clip. It arrives here
---over a LATENT event (bandwidth-throttled client-side, so a legitimate payload can't stall
---the net thread). `source` is authenticated by the event system, so no token is needed -
---but `image` and `kind` are attacker-controlled: the payload must be a data-URL of the
---claimed media type and fit the per-kind byte cap before any Fivemanage quota is spent.
---The filename extension is derived from the data-URL's MIME (not from `kind` alone) so
---Fivemanage and the gallery - which detects videos by extension - treat it correctly. On
---success the row is persisted via actions.saveFromUrl (which re-resolves identity and
---prunes the gallery) and pushed back to the SAME player over photos:added; nothing is
---broadcast.
---@param image string base64 data-URL (data:image/... or data:video/...)
---@param kind string 'video' for clips; anything else is treated as a photo
RegisterNetEvent('sd-phone:server:photos:upload', function(image, kind)
    local src     = source
    local isVideo = kind == 'video'

    local prefix  = isVideo and 'data:video/' or 'data:image/'
    if type(image) ~= 'string' or image:sub(1, #prefix) ~= prefix then
        print(('^1[sd-phone:photos]^0 [UPLOAD] src=%s rejected — not a %s data-URL'):format(tostring(src), isVideo and 'video' or 'image'))
        return
    end
    if #image > (isVideo and MAX_VIDEO_BYTES or MAX_PHOTO_BYTES) then
        print(('^1[sd-phone:photos]^0 [UPLOAD] src=%s rejected — payload too large (%d bytes)'):format(tostring(src), #image))
        return
    end

    print(('^2[sd-phone:photos]^0 [UPLOAD] src=%s kind=%s bytes=%d'):format(tostring(src), isVideo and 'video' or 'photo', #image))

    local ext = 'jpg'
    if isVideo then
        ext = image:find('^data:video/mp4') and 'mp4' or 'webm'
    end
    local filename = ('sdphone-%d-%d.%s'):format(src, os.time(), ext)
    uploader.uploadMedia(image, filename, function(url, err)
        if not url then
            print(('^1[sd-phone:photos]^0 [UPLOAD] failed: %s'):format(tostring(err)))
            return
        end

        local saveRes = actions.saveFromUrl(src, url)
        if saveRes and saveRes.success and saveRes.data and saveRes.data.photo then
            TriggerClientEvent('sd-phone:client:photos:added', src, saveRes.data.photo)
            print(('^2[sd-phone:photos]^0 [UPLOAD] saved + pushed id=%s'):format(saveRes.data.photo.id))
        end
    end)
end)

---Save an already-hosted media URL for the caller (UI flows that hold a CDN address, e.g.
---saving an image out of a chat). Validation - type, scheme, length - lives in
---actions.saveFromUrl; the extra photos:added push keeps any other open gallery surface in
---sync with the row the callback returns.
lib.callback.register('sd-phone:server:photos:saveUrl', function(src, payload)
    local res = actions.saveFromUrl(src, payload and payload.url)
    if res and res.success and res.data and res.data.photo then
        TriggerClientEvent('sd-phone:client:photos:added', src, res.data.photo)
    end
    return res
end)

-- Authoritative photo/album callbacks: thin delegates into server.photos.actions, which owns
-- the validation + ownership checks (each handler is documented there). Payload fields are
-- normalised to the expected primitive here; the actions layer re-type-checks everything.
lib.callback.register('sd-phone:server:photos:setFavorite', function(src, payload)
    return actions.setFavorite(src, payload and payload.photoId or '', payload and payload.value)
end)

lib.callback.register('sd-phone:server:photos:delete', function(src, payload)
    return actions.delete(src, payload and payload.photoId or '')
end)

lib.callback.register('sd-phone:server:albums:list', function(src)
    return actions.listAlbums(src)
end)

lib.callback.register('sd-phone:server:albums:create', function(src, payload)
    return actions.createAlbum(src, payload and payload.name or '')
end)

lib.callback.register('sd-phone:server:albums:delete', function(src, payload)
    return actions.deleteAlbum(src, payload and payload.albumId or '')
end)

lib.callback.register('sd-phone:server:albums:addPhotos', function(src, payload)
    return actions.addPhotosToAlbum(src, payload and payload.albumId or '', payload and payload.photoIds or {})
end)

lib.callback.register('sd-phone:server:albums:removePhoto', function(src, payload)
    return actions.removePhotoFromAlbum(src, payload and payload.albumId or '', payload and payload.photoId or '')
end)

lib.callback.register('sd-phone:server:albums:photos', function(src, payload)
    return actions.listAlbumPhotos(src, payload and payload.albumId or '')
end)

---Public export: save an already-hosted http(s) media URL into a player's gallery -
---exports['sd-phone']:addPhoto(source, url). Callers are other server resources naming the
---acting player; the URL walks the same validation the NUI path walks (actions.saveFromUrl:
---identity from source, http(s) scheme, 512-byte cap, gallery prune), so a sloppy caller can't
---corrupt a gallery. On success the photo is also pushed to that player over photos:added, so
---an open Photos app updates live. A source that isn't a finite integer (NaN/inf/1.5) is a
---caller bug and returns { success = false } instead of erroring inside saveFromUrl's %d format.
---@param source number acting player's server id (the gallery owner resolves from it)
---@param url string http(s) URL of the hosted media
---@return { success: boolean, photo?: table }
exports('addPhoto', function(source, url)
    if type(source) ~= 'number' or not util.finite(source) or source % 1 ~= 0 then
        return { success = false }
    end
    local res = actions.saveFromUrl(source, url)
    if res and res.success and res.data and res.data.photo then
        TriggerClientEvent('sd-phone:client:photos:added', source, res.data.photo)
        return { success = true, photo = res.data.photo }
    end
    return { success = false }
end)

---Public export: upload a base64 data-URL to Fivemanage and hand the hosted CDN URL to `cb` -
---exports['sd-phone']:uploadMedia(dataUrl, filename, cb). Asynchronous: cb(url|nil, err|nil) is
---called exactly once. Every accepted call SPENDS THE SERVER'S FIVEMANAGE QUOTA, so the boundary
---enforces the same ceilings as the capture upload before any quota is spent: the payload must
---be a data: URL and fit the per-kind byte cap (MAX_VIDEO_BYTES for data:video/, MAX_PHOTO_BYTES
---for everything else). Upload only - nothing lands in a gallery; pair with addPhoto when it
---should. A non-function cb is a caller bug and returns false without calling anything.
---@param dataUrl string media as a base64 data-URL (data:image/... or data:video/...)
---@param filename string|nil suggested filename stored alongside the upload
---@param cb fun(url: string|nil, err: string|nil)
---@return boolean accepted false when the callback or payload shape is unusable
exports('uploadMedia', function(dataUrl, filename, cb)
    if type(cb) ~= 'function' then return false end
    if type(dataUrl) ~= 'string' or dataUrl:sub(1, 5) ~= 'data:' then
        cb(nil, 'Expected a base64 data: URL')
        return false
    end
    local cap = dataUrl:sub(1, 11) == 'data:video/' and MAX_VIDEO_BYTES or MAX_PHOTO_BYTES
    if #dataUrl > cap then
        cb(nil, ('Payload too large (%d bytes, cap %d)'):format(#dataUrl, cap))
        return false
    end
    uploader.uploadMedia(dataUrl, type(filename) == 'string' and filename or nil, cb)
    return true
end)
