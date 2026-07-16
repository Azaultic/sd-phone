---@type table sd-phone config root (configs/config.lua).
local config   = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid lookups from a server id.
local player   = require 'bridge.server.player'
---@type table Photos persistence layer (server.photos.store): photo/album row CRUD.
local store    = require 'server.photos.store'

---@type table Photos config (config.Photos): retention cap, album cap, name length bounds.
local photosCfg = config.Photos

---@type table Actions module; the table returned at end of file.
local actions = {}

local util = require 'server.util'
local ok, fail, isTruthy = util.ok, util.fail, util.truthy



---Shape a DB photo row into the React `Photo` type. `favorite` goes through the TINYINT(1)
---guard; `created_at` stays as whatever oxmysql hands us (epoch-ms number) - the React side
---normalises it.
---@param row { id: string, url: string, favorite: any, created_at: any }
---@return table
local function shapePhoto(row)
    return {
        id        = row.id,
        url       = row.url,
        favorite  = isTruthy(row.favorite),
        createdAt = row.created_at,
    }
end

---List every photo the caller owns, newest first. Identity comes from `source` via the
---player bridge - no payload field can choose whose gallery is read. Read-only.
---@param source number player server id
---@return table result { success, data = { photos } }
function actions.list(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    local rows = store.listForCitizen(cid)
    local out = {}
    for i = 1, #rows do
        out[i] = shapePhoto(rows[i])
    end
    return ok({ photos = out })
end

---@type integer Longest accepted photo URL in bytes - matches the phone_photos.url
---VARCHAR(512) column, so an oversized client-supplied URL is rejected here instead of
---erroring the INSERT.
local MAX_URL_BYTES = 512

---Persist a photo URL against the caller. Two callers: the upload pipeline (init.lua) hands
---it the Fivemanage CDN URL the server itself just received, and the saveUrl callback
---forwards a raw client string - so the URL is treated as attacker-controlled either way
---and must be a non-empty http(s) string that fits the DB column. After the insert the
---caller's gallery is pruned back under config.Photos.MaxPhotosPerPlayer, so a spammed
---shutter can't grow the table without bound. The returned `createdAt` is a UTC string
---while listed rows carry the DB timestamp - the React side normalises both.
---@param source number player server id
---@param url string http(s) URL of the hosted media
---@return table result { success, data = { photo } }
function actions.saveFromUrl(source, url)
    print(('^2[sd-phone:photos]^0 saveFromUrl source=%d, url=%s')
        :format(source, tostring(url):sub(1, 80)))

    local cid = player.getIdentifier(source)
    if not cid then
        print('^1[sd-phone:photos]^0 saveFromUrl: no citizenid for source')
        return fail('Player not found')
    end
    if type(url) ~= 'string' or url == '' then
        print('^1[sd-phone:photos]^0 saveFromUrl: empty url')
        return fail('No URL')
    end
    if not (url:sub(1, 8) == 'https://' or url:sub(1, 7) == 'http://') then
        print('^1[sd-phone:photos]^0 saveFromUrl: url not http(s)')
        return fail('Invalid URL')
    end
    if #url > MAX_URL_BYTES then
        return fail('Invalid URL')
    end

    local id = store.newId()
    if not store.insertPhoto(id, cid, url) then
        print('^1[sd-phone:photos]^0 DB insert failed')
        return fail('Failed to save photo')
    end

    store.pruneOldest(cid, photosCfg.MaxPhotosPerPlayer)
    print(('^2[sd-phone:photos]^0 saved photo id=%s for cid=%s'):format(id, cid))

    ---First-party hook: fires once per saved photo; the NUI capture path, the saveUrl callback
    ---and the addPhoto export all funnel through here. `source` is the parameter this function
    ---was handed (the capture path runs inside an async HTTP callback, so the global would be
    ---stale). Server-local and synchronous.
    TriggerEvent('sd-phone:server:photos:added', { source = source, citizenid = cid, id = id, url = url })

    return ok({
        photo = {
            id        = id,
            url       = url,
            favorite  = false,
            createdAt = os.date('!%Y-%m-%d %H:%M:%S'),
        },
    })
end

---Set the favourite flag on a photo. `value` is coerced to a strict boolean before it
---reaches the store; ownership is enforced by the store's citizenid scope, so a foreign
---photo id matches nothing and reads as 'Photo not found'. Idempotent: re-sending the same
---value still reports success (oxmysql connects with CLIENT_FOUND_ROWS, so an unchanged
---UPDATE still counts its matched row).
---@param source number player server id
---@param photoId string photo row id
---@param value boolean desired favourite state
---@return table result { success, data = { id, favorite } }
function actions.setFavorite(source, photoId, value)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if type(photoId) ~= 'string' or photoId == '' then return fail('Photo id required') end
    if not store.setFavorite(photoId, cid, value and true or false) then
        return fail('Photo not found')
    end
    return ok({ id = photoId, favorite = value and true or false })
end

---Hard-delete a photo. Ownership is enforced by the store (WHERE id AND citizenid), which
---also clears the photo's album-membership rows so no album keeps pointing at a ghost.
---@param source number player server id
---@param photoId string photo row id
---@return table result { success, data = { id } }
function actions.delete(source, photoId)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if type(photoId) ~= 'string' or photoId == '' then
        return fail('Photo id required')
    end
    local url = store.deletePhoto(photoId, cid)
    if not url then
        return fail('Photo not found')
    end
    ---First-party hook: fires once per owner-initiated delete; retention pruning and admin
    ---wipes bypass this deliberately. Server-local and synchronous.
    TriggerEvent('sd-phone:server:photos:deleted', { source = source, citizenid = cid, id = photoId, url = url })
    return ok({ id = photoId })
end

---List the caller's custom albums, each annotated by the store with a photo count and a
---cover URL (newest photo in the album). Read-only.
---@param source number player server id
---@return table result { success, data = { albums } }
function actions.listAlbums(source)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    local rows = store.listAlbums(cid)
    local out = {}
    for i = 1, #rows do
        out[i] = {
            id        = rows[i].id,
            name      = rows[i].name,
            count     = tonumber(rows[i].count) or 0,
            cover     = rows[i].cover,
            createdAt = rows[i].created_at,
        }
    end
    return ok({ albums = out })
end

---Create a custom album. The name is trimmed the same way the React input trims, then
---bounded by config.Photos.Min/MaxAlbumNameLength - the max mirrors the input's maxLength,
---and the byte-length check keeps even multi-byte names inside the VARCHAR(64) column. The
---per-player album cap is enforced here (not just in the UI) so calling the callback
---directly can't skip it.
---@param source number player server id
---@param name string requested album name
---@return table result { success, data = { album } }
function actions.createAlbum(source, name)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end

    name = type(name) == 'string' and name:gsub('^%s+', ''):gsub('%s+$', '') or ''
    if #name < photosCfg.MinAlbumNameLength or #name > photosCfg.MaxAlbumNameLength then
        return fail(('Album name must be %d–%d characters')
            :format(photosCfg.MinAlbumNameLength, photosCfg.MaxAlbumNameLength))
    end
    if store.countAlbums(cid) >= photosCfg.MaxAlbumsPerPlayer then
        return fail('Album limit reached')
    end

    local id = store.newId()
    if not store.createAlbum(id, cid, name) then
        return fail('Failed to create album')
    end
    return ok({
        album = { id = id, name = name, count = 0, cover = nil, createdAt = os.date('!%Y-%m-%d %H:%M:%S') },
    })
end

---Delete a custom album (never the photos in it). The store verifies the caller owns the
---album before removing it and its membership rows.
---@param source number player server id
---@param albumId string album row id
---@return table result { success, data = { id } }
function actions.deleteAlbum(source, albumId)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if type(albumId) ~= 'string' or albumId == '' then return fail('Album id required') end
    if not store.deleteAlbum(albumId, cid) then
        return fail('Album not found')
    end
    return ok({ id = albumId })
end

---Add one or more photos to an album. The id list is attacker-controlled: every entry must
---be a non-empty string (each becomes one INSERT in the store loop) and the batch is capped
---at config.Photos.MaxPhotosPerPlayer - nobody can own more photos than that, so a larger
---list is garbage and an uncapped one is a free DB hammer. Ownership of the album AND of
---each photo is enforced by the store (its WHERE EXISTS guard), so foreign photo ids are
---silently skipped rather than linked.
---@param source number player server id
---@param albumId string target album id
---@param photoIds string[] photo ids to add
---@return table result { success, data = { id, added } }
function actions.addPhotosToAlbum(source, albumId, photoIds)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if type(albumId) ~= 'string' or albumId == '' then return fail('Album id required') end
    if type(photoIds) ~= 'table' or #photoIds == 0 then return fail('No photos selected') end
    if #photoIds > photosCfg.MaxPhotosPerPlayer then return fail('Too many photos') end
    for i = 1, #photoIds do
        if type(photoIds[i]) ~= 'string' or photoIds[i] == '' then return fail('Photo id required') end
    end
    if not store.addPhotosToAlbum(albumId, cid, photoIds) then
        return fail('Album not found')
    end
    return ok({ id = albumId, added = #photoIds })
end

---Remove a single photo from an album. Ownership is enforced through the ALBUM row in the
---store, so a caller can only edit membership of albums they own.
---@param source number player server id
---@param albumId string album row id
---@param photoId string photo row id
---@return table result { success, data = { albumId, photoId } }
function actions.removePhotoFromAlbum(source, albumId, photoId)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if type(albumId) ~= 'string' or albumId == '' then return fail('Album id required') end
    if type(photoId) ~= 'string' or photoId == '' then return fail('Photo id required') end
    if not store.removePhotoFromAlbum(albumId, photoId, cid) then
        return fail('Not in album')
    end
    return ok({ albumId = albumId, photoId = photoId })
end

---List the photos in one album, newest first. The store joins through the album row, so a
---foreign albumId simply reads as an empty album. Read-only.
---@param source number player server id
---@param albumId string album row id
---@return table result { success, data = { photos } }
function actions.listAlbumPhotos(source, albumId)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    if type(albumId) ~= 'string' or albumId == '' then return fail('Album id required') end
    local rows = store.listAlbumPhotos(albumId, cid)
    local out = {}
    for i = 1, #rows do
        out[i] = shapePhoto(rows[i])
    end
    return ok({ photos = out })
end

return actions
