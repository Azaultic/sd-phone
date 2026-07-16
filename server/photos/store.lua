---@type table Store module; the table returned at end of file.
local store = {}

---@type string Alphabet for generated row ids (base-36, lowercase).
local ID_CHARS = '0123456789abcdefghijklmnopqrstuvwxyz'
---@type integer Generated id length - fits the VARCHAR(16) id columns with headroom.
local ID_LEN   = 12

---Generate a 12-character base-36 id for a photo or album row. Not cryptographic - ids are
---never an authority boundary (every read/write is additionally scoped by citizenid), and a
---freak collision just fails the PRIMARY KEY insert, which the caller reports as a failure.
---@return string id
function store.newId()
    local out = {}
    for i = 1, ID_LEN do
        local n = math.random(1, #ID_CHARS)
        out[i] = ID_CHARS:sub(n, n)
    end
    return table.concat(out)
end

---Create the Photos tables if they don't exist and back-fill newer columns, so the resource
---is drop-in. `phone_photos` holds one row per image (the URL is a remote CDN address, never
---the binary). `phone_photo_albums` holds player-created albums; `phone_photo_album_items`
---is the many-to-many join between albums and photos. The `favorite` back-fill goes through
---information_schema because MySQL 8 lacks ADD COLUMN IF NOT EXISTS. Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photos (
            id         VARCHAR(16)  NOT NULL,
            citizenid  VARCHAR(64)  NOT NULL,
            url        VARCHAR(512) NOT NULL,
            favorite   TINYINT(1)   NOT NULL DEFAULT 0,
            created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            INDEX idx_phone_photos_owner (citizenid, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    local hasFav = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'phone_photos'
          AND COLUMN_NAME = 'favorite'
    ]])
    if (hasFav or 0) == 0 then
        MySQL.query.await('ALTER TABLE phone_photos ADD COLUMN favorite TINYINT(1) NOT NULL DEFAULT 0')
    end

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photo_albums (
            id         VARCHAR(16) NOT NULL,
            citizenid  VARCHAR(64) NOT NULL,
            name       VARCHAR(64) NOT NULL,
            created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            INDEX idx_phone_albums_owner (citizenid, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photo_album_items (
            album_id VARCHAR(16) NOT NULL,
            photo_id VARCHAR(16) NOT NULL,
            added_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (album_id, photo_id),
            INDEX idx_album_items_photo (photo_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end

---Persist a freshly-uploaded photo against its owner. The caller validates the URL; we keep
---the data layer dumb.
---@param id string generated row id
---@param citizenid string owner's framework per-character id
---@param url string hosted media URL
---@return boolean inserted
function store.insertPhoto(id, citizenid, url)
    local affected = MySQL.insert.await(
        'INSERT INTO phone_photos (id, citizenid, url) VALUES (?, ?, ?)',
        { id, citizenid, url }
    )
    return affected ~= nil
end

---One player's photos, newest first. Read-only.
---@param citizenid string owner's framework per-character id
---@return { id: string, url: string, favorite: any, created_at: number }[] rows
function store.listForCitizen(citizenid)
    return MySQL.query.await([[
        SELECT id, url, favorite, created_at
        FROM phone_photos
        WHERE citizenid = ?
        ORDER BY created_at DESC, id DESC
    ]], { citizenid }) or {}
end

---Set the favourite flag on a photo the caller owns. The citizenid in the WHERE clause is
---the ownership check - a foreign photo id matches zero rows and reports false. A same-value
---replay still reports true (the pool connects with CLIENT_FOUND_ROWS, so affectedRows
---counts matched rows, not changed ones).
---@param photoId string photo row id
---@param citizenid string caller's framework per-character id
---@param value boolean desired favourite state
---@return boolean updated
function store.setFavorite(photoId, citizenid, value)
    local affected = MySQL.update.await(
        'UPDATE phone_photos SET favorite = ? WHERE id = ? AND citizenid = ?',
        { value and 1 or 0, photoId, citizenid }
    )
    return (affected or 0) > 0
end

---Hard-delete a photo, but only if the caller owns it (the citizenid in the WHERE clause).
---The row's url is read first so the caller can report WHAT was deleted, and its
---album-membership rows are cleared only after the owned delete actually removed a row, so a
---foreign photo id can't be used to strip someone else's album memberships.
---@param photoId string photo row id
---@param citizenid string caller's framework per-character id
---@return string|nil url of the deleted photo, nil when nothing matched
function store.deletePhoto(photoId, citizenid)
    local url = MySQL.scalar.await(
        'SELECT url FROM phone_photos WHERE id = ? AND citizenid = ?',
        { photoId, citizenid }
    )
    if not url then return nil end
    local affected = MySQL.update.await(
        'DELETE FROM phone_photos WHERE id = ? AND citizenid = ?',
        { photoId, citizenid }
    )
    if (affected or 0) > 0 then
        MySQL.update.await('DELETE FROM phone_photo_album_items WHERE photo_id = ?', { photoId })
        return url
    end
    return nil
end

---Trim the oldest photos for one player so their row count stays at `maxRetained`
---(config.Photos.MaxPhotosPerPlayer). No-op when they're already at or under the cap. The
---excess ids are resolved first so their album-membership rows are deleted with them - a
---bare DELETE ... LIMIT would leave orphaned phone_photo_album_items rows that permanently
---inflate album counts. Only `?` placeholders are formatted into the IN-lists; the ids
---themselves stay parameterized.
---@param citizenid string owner's framework per-character id
---@param maxRetained number cap on retained photo rows
function store.pruneOldest(citizenid, maxRetained)
    if not maxRetained or maxRetained <= 0 then return end
    local row = MySQL.single.await(
        'SELECT COUNT(*) AS n FROM phone_photos WHERE citizenid = ?',
        { citizenid }
    )
    local count = row and tonumber(row.n) or 0
    if count <= maxRetained then return end

    local rows = MySQL.query.await([[
        SELECT id FROM phone_photos
        WHERE citizenid = ?
        ORDER BY created_at ASC, id ASC
        LIMIT ?
    ]], { citizenid, count - maxRetained }) or {}
    if #rows == 0 then return end

    local ids, marks = {}, {}
    for i = 1, #rows do
        ids[i]   = rows[i].id
        marks[i] = '?'
    end
    local inList = table.concat(marks, ',')
    MySQL.update.await(('DELETE FROM phone_photo_album_items WHERE photo_id IN (%s)'):format(inList), ids)
    MySQL.update.await(('DELETE FROM phone_photos WHERE id IN (%s)'):format(inList), ids)
end

---Create a custom album for the player. The caller bounds the name; we keep the data layer
---dumb.
---@param id string generated row id
---@param citizenid string owner's framework per-character id
---@param name string trimmed album name
---@return boolean inserted
function store.createAlbum(id, citizenid, name)
    local affected = MySQL.insert.await(
        'INSERT INTO phone_photo_albums (id, citizenid, name) VALUES (?, ?, ?)',
        { id, citizenid, name }
    )
    return affected ~= nil
end

---How many albums a player owns - the caller compares it against the per-player cap before
---creating another. Read-only.
---@param citizenid string owner's framework per-character id
---@return number count
function store.countAlbums(citizenid)
    return MySQL.scalar.await(
        'SELECT COUNT(*) FROM phone_photo_albums WHERE citizenid = ?',
        { citizenid }
    ) or 0
end

---Delete a custom album and its membership rows, but only if the caller owns it - the
---ownership SELECT runs first so a foreign albumId deletes nothing. The photos themselves
---are never touched.
---@param albumId string album row id
---@param citizenid string caller's framework per-character id
---@return boolean deleted
function store.deleteAlbum(albumId, citizenid)
    local owns = MySQL.scalar.await(
        'SELECT 1 FROM phone_photo_albums WHERE id = ? AND citizenid = ?',
        { albumId, citizenid }
    )
    if not owns then return false end
    MySQL.update.await('DELETE FROM phone_photo_album_items WHERE album_id = ?', { albumId })
    MySQL.update.await('DELETE FROM phone_photo_albums WHERE id = ?', { albumId })
    return true
end

---One player's custom albums, newest first, each annotated with a photo count and a cover
---URL (the newest photo in the album). Read-only.
---@param citizenid string owner's framework per-character id
---@return { id: string, name: string, count: number, cover: string|nil, created_at: number }[] rows
function store.listAlbums(citizenid)
    return MySQL.query.await([[
        SELECT
            a.id,
            a.name,
            a.created_at,
            (SELECT COUNT(*) FROM phone_photo_album_items i WHERE i.album_id = a.id) AS count,
            (SELECT p.url
               FROM phone_photo_album_items i
               JOIN phone_photos p ON p.id = i.photo_id
              WHERE i.album_id = a.id
              ORDER BY p.created_at DESC
              LIMIT 1) AS cover
        FROM phone_photo_albums a
        WHERE a.citizenid = ?
        ORDER BY a.created_at DESC
    ]], { citizenid }) or {}
end

---Add photos to an album. Album ownership is verified up front, and the INSERT only takes
---photos the same caller also owns (the WHERE EXISTS guard) - so neither a foreign album id
---nor a foreign photo id links anything. Duplicate memberships are silently ignored
---(INSERT IGNORE against the composite primary key), which makes a replayed add harmless.
---@param albumId string album row id
---@param citizenid string caller's framework per-character id
---@param photoIds string[] photo ids to add (caller caps and type-checks the list)
---@return boolean albumOwned
function store.addPhotosToAlbum(albumId, citizenid, photoIds)
    local owns = MySQL.scalar.await(
        'SELECT 1 FROM phone_photo_albums WHERE id = ? AND citizenid = ?',
        { albumId, citizenid }
    )
    if not owns then return false end
    for i = 1, #photoIds do
        MySQL.insert.await([[
            INSERT IGNORE INTO phone_photo_album_items (album_id, photo_id)
            SELECT ?, ?
            WHERE EXISTS (SELECT 1 FROM phone_photos WHERE id = ? AND citizenid = ?)
        ]], { albumId, photoIds[i], photoIds[i], citizenid })
    end
    return true
end

---Remove a single photo from an album. Ownership is enforced via the ALBUM row - the
---membership delete only runs once the caller is confirmed as the album's owner.
---@param albumId string album row id
---@param photoId string photo row id
---@param citizenid string caller's framework per-character id
---@return boolean removed
function store.removePhotoFromAlbum(albumId, photoId, citizenid)
    local owns = MySQL.scalar.await(
        'SELECT 1 FROM phone_photo_albums WHERE id = ? AND citizenid = ?',
        { albumId, citizenid }
    )
    if not owns then return false end
    local affected = MySQL.update.await(
        'DELETE FROM phone_photo_album_items WHERE album_id = ? AND photo_id = ?',
        { albumId, photoId }
    )
    return (affected or 0) > 0
end

---The photos in one album, newest first. Joins through the album row so a foreign citizenid
---can't read someone else's album - it just comes back empty. Read-only.
---@param albumId string album row id
---@param citizenid string caller's framework per-character id
---@return { id: string, url: string, favorite: any, created_at: number }[] rows
function store.listAlbumPhotos(albumId, citizenid)
    return MySQL.query.await([[
        SELECT p.id, p.url, p.favorite, p.created_at
        FROM phone_photo_album_items i
        JOIN phone_photos p       ON p.id = i.photo_id
        JOIN phone_photo_albums a ON a.id = i.album_id
        WHERE i.album_id = ? AND a.citizenid = ?
        ORDER BY p.created_at DESC, p.id DESC
    ]], { albumId, citizenid }) or {}
end

return store
