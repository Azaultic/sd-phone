---@type table Store module; the table returned at end of file.
local store = {}


local util = require 'server.util'
local isTruthy = util.truthy
local function newId() return util.newId(9) end

store.newId = newId

-- Server-side pepper folded into every password hash, mirroring the Mail app. Not real crypto -
-- an in-game phone isn't a credentials store - but it keeps stored hashes from being trivially
-- reversible if the table leaks.
---@type string Static hash pepper; changing it invalidates every stored Birdy-side hash.
local PEPPER = 'sd-phone-v1::birdy::do-not-leak-this-string'

---Hash a password into a stable 24-char hex digest. Deterministic, so a signin re-hash can be
---compared against the stored value. Also registered with the accounts engine as Birdy's legacy
---hasher, so pre-engine accounts keep verifying until their first login upgrades them.
---@param password string
---@return string
function store.hashPassword(password)
    local input = password .. PEPPER
    local h1, h2, h3 = 0x12345678, 0x87654321, 0xABCDEF01
    for i = 1, #input do
        local b = input:byte(i)
        h1 = (h1 * 31 + b) & 0xFFFFFFFF
        h2 = ((h2 ~ ((b << (i % 8)) & 0xFFFFFFFF)) + 0x9E3779B9) & 0xFFFFFFFF
        h3 = (((h3 << 5) | (h3 >> 27)) + b * (h1 + 1)) & 0xFFFFFFFF
    end
    return ('%08x%08x%08x'):format(h1, h2, h3)
end

---Create every Birdy table idempotently and back-fill columns added after first release, so the
---resource is drop-in on an existing database. The nested ensureColumn probes
---information_schema before ALTERing (older MariaDB lacks ADD COLUMN IF NOT EXISTS); its table
---and DDL strings are hardcoded literals below, never derived from input, so the format() into
---SQL is safe. Back-filled columns: profile credentials/bio/session flags, post `images` (a JSON
---array of up to 3 URLs), and the rich-DM columns kind/meta/reactions (mirrors the Messages +
---Cherry message model so the same bubbles render). Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_birdy_profiles (
            citizenid    VARCHAR(64)  NOT NULL,
            handle       VARCHAR(32)  NOT NULL,
            display_name VARCHAR(64)  NOT NULL,
            password     VARCHAR(64)  NOT NULL DEFAULT '',
            bio          VARCHAR(200) NOT NULL DEFAULT '',
            verified     TINYINT(1)   NOT NULL DEFAULT 0,
            logged_in    TINYINT(1)   NOT NULL DEFAULT 0,
            join_label   VARCHAR(32)  NOT NULL DEFAULT '',
            protected    TINYINT(1)   NOT NULL DEFAULT 0,
            created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid),
            UNIQUE KEY uq_phone_birdy_handle (handle)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_birdy_posts (
            id         VARCHAR(16) NOT NULL,
            author_cid VARCHAR(64) NOT NULL,
            body       TEXT        NOT NULL,
            parent_id  VARCHAR(16) NULL,
            images     TEXT        NULL,
            views      INT         NOT NULL DEFAULT 0,
            created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            INDEX idx_birdy_posts_author  (author_cid),
            INDEX idx_birdy_posts_parent  (parent_id),
            INDEX idx_birdy_posts_created (created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_birdy_likes (
            post_id    VARCHAR(16) NOT NULL,
            citizenid  VARCHAR(64) NOT NULL,
            created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (post_id, citizenid),
            INDEX idx_birdy_likes_post (post_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_birdy_follows (
            follower_cid VARCHAR(64) NOT NULL,
            target_cid   VARCHAR(64) NOT NULL,
            created_at   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (follower_cid, target_cid),
            INDEX idx_birdy_follows_target (target_cid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_birdy_dms (
            id         VARCHAR(16) NOT NULL,
            from_cid   VARCHAR(64) NOT NULL,
            to_cid     VARCHAR(64) NOT NULL,
            body       TEXT        NOT NULL,
            kind       VARCHAR(16) NOT NULL DEFAULT 'text',
            meta       TEXT        NULL,
            reactions  TEXT        NULL,
            read_flag  TINYINT(1)  NOT NULL DEFAULT 0,
            created_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            INDEX idx_birdy_dms_from (from_cid),
            INDEX idx_birdy_dms_to   (to_cid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_birdy_notifications (
            id            VARCHAR(16) NOT NULL,
            recipient_cid VARCHAR(64) NOT NULL,
            kind          VARCHAR(16) NOT NULL,
            actor_cid     VARCHAR(64) NOT NULL,
            post_id       VARCHAR(16) NULL,
            created_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            INDEX idx_birdy_notifs_recipient (recipient_cid, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    local function ensureColumn(tbl, name, ddl)
        local present = MySQL.scalar.await([[
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?
        ]], { tbl, name })
        if (tonumber(present) or 0) == 0 then
            MySQL.query.await(('ALTER TABLE %s ADD COLUMN %s'):format(tbl, ddl))
        end
    end
    ensureColumn('phone_birdy_profiles', 'password',   "password VARCHAR(64) NOT NULL DEFAULT ''")
    ensureColumn('phone_birdy_profiles', 'bio',        "bio VARCHAR(200) NOT NULL DEFAULT ''")
    ensureColumn('phone_birdy_profiles', 'logged_in',  'logged_in TINYINT(1) NOT NULL DEFAULT 0')
    ensureColumn('phone_birdy_profiles', 'join_label', "join_label VARCHAR(32) NOT NULL DEFAULT ''")
    ensureColumn('phone_birdy_profiles', 'protected',  'protected TINYINT(1) NOT NULL DEFAULT 0')
    ensureColumn('phone_birdy_posts',    'images',     'images TEXT NULL')
    ensureColumn('phone_birdy_dms',      'kind',       "kind VARCHAR(16) NOT NULL DEFAULT 'text'")
    ensureColumn('phone_birdy_dms',      'meta',       'meta TEXT NULL')
    ensureColumn('phone_birdy_dms',      'reactions',  'reactions TEXT NULL')
end

---Decode a JSON column into a Lua table, tolerating nil / empty / corrupt values (always returns
---a table, so callers can index without guards). Client-shaped strings only ever reach here from
---our own columns; the pcall covers hand-edited or legacy rows.
---@param value any
---@return table
function store.decodeJson(value)
    if value == nil then return {} end
    if type(value) == 'table' then return value end
    if type(value) == 'string' and value ~= '' then
        local ok, decoded = pcall(json.decode, value)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return {}
end


---Reshape a raw profile row, normalising every TINYINT flag to a boolean.
---@param row table|nil
---@return { citizenid: string, handle: string, displayName: string, verified: boolean }|nil
local function hydrateProfile(row)
    if not row then return nil end
    return {
        citizenid   = row.citizenid,
        handle      = row.handle,
        displayName = row.display_name,
        password    = row.password,
        bio         = row.bio,
        verified    = isTruthy(row.verified),
        loggedIn    = isTruthy(row.logged_in),
        joinLabel   = row.join_label,
        protected   = isTruthy(row.protected),
    }
end

---A profile by its owning citizenid, or nil.
---@param citizenid string
---@return table|nil
function store.getProfile(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await(
        'SELECT citizenid, handle, display_name, password, bio, verified, logged_in, join_label, protected FROM phone_birdy_profiles WHERE citizenid = ?',
        { citizenid }
    )
    return hydrateProfile(row)
end

---Look up a profile by its unique handle (also the availability check at registration).
---@param handle string
---@return table|nil
function store.getProfileByHandle(handle)
    return hydrateProfile(MySQL.single.await(
        'SELECT citizenid, handle, display_name, password, bio, verified, logged_in, join_label, protected FROM phone_birdy_profiles WHERE handle = ?',
        { handle }
    ))
end

---Search accounts by handle or display name (substring), excluding the viewer. The query string
---is bound as a `?` LIKE parameter - never concatenated into the SQL - so user % / _ only act as
---extra wildcards inside the pattern.
---@param query string
---@param viewerCid string
---@param limit number
---@return table[] {citizenid, handle, displayName, verified}
function store.searchProfiles(query, viewerCid, limit)
    local like = '%' .. query .. '%'
    local rows = MySQL.query.await([[
        SELECT citizenid, handle, display_name, verified FROM phone_birdy_profiles
        WHERE (handle LIKE ? OR display_name LIKE ?) AND citizenid <> ?
        ORDER BY created_at DESC LIMIT ?
    ]], { like, like, viewerCid or '', limit }) or {}
    local out = {}
    for i = 1, #rows do
        local r = rows[i]
        out[i] = { citizenid = r.citizenid, handle = r.handle, displayName = r.display_name, verified = isTruthy(r.verified) }
    end
    return out
end

---Create a fresh, signed-in profile row for a citizenid. The UNIQUE handle key is the last-line
---race guard: two simultaneous registrations of the same handle can both pass the action's
---availability check, but only one insert survives (the other returns false and the caller
---compensates).
---@param citizenid string
---@param handle string
---@param displayName string
---@param passwordHash string
---@param bio string
---@param verified boolean
---@param joinLabel string
---@return boolean
function store.insertAccount(citizenid, handle, displayName, passwordHash, bio, verified, joinLabel)
    return MySQL.insert.await([[
        INSERT INTO phone_birdy_profiles (citizenid, handle, display_name, password, bio, verified, logged_in, join_label)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?)
    ]], { citizenid, handle, displayName, passwordHash, bio, verified and 1 or 0, joinLabel or '' }) ~= nil
end

---Update the editable profile fields (name, bio, join label, protected). Caller validates and
---bounds every value; the write is scoped to the given citizenid.
---@param citizenid string
---@param displayName string
---@param bio string
---@param joinLabel string
---@param protected boolean
function store.updateProfileFields(citizenid, displayName, bio, joinLabel, protected)
    MySQL.update.await([[
        UPDATE phone_birdy_profiles
        SET display_name = ?, bio = ?, join_label = ?, protected = ?
        WHERE citizenid = ?
    ]], { displayName, bio, joinLabel, protected and 1 or 0, citizenid })
end

---Replace a citizenid's legacy profile-row password hash (kept in sync with the engine hash).
---@param citizenid string
---@param passwordHash string
function store.setPassword(citizenid, passwordHash)
    MySQL.update.await('UPDATE phone_birdy_profiles SET password = ? WHERE citizenid = ?', { passwordHash, citizenid })
end

---@param citizenid string
---@return number following count
function store.countFollowing(citizenid)
    return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM phone_birdy_follows WHERE follower_cid = ?', { citizenid })) or 0
end

---@param citizenid string
---@return number follower count
function store.countFollowers(citizenid)
    return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM phone_birdy_follows WHERE target_cid = ?', { citizenid })) or 0
end

---Reshape a joined POST_SELECT row into the hydrated post table actions serialize from. `images`
---is stored as a JSON array string ('["url",...]'); decode to a Lua array, tolerating legacy
---NULL / empty / corrupt values by falling back to nil (the post just renders without media).
---@param row table|nil
---@return table|nil
local function hydratePost(row)
    if not row then return nil end
    local images = nil
    if type(row.images) == 'string' and row.images ~= '' then
        local okj, decoded = pcall(json.decode, row.images)
        if okj and type(decoded) == 'table' and #decoded > 0 then images = decoded end
    end
    return {
        id          = row.id,
        authorCid   = row.author_cid,
        handle      = row.handle,
        displayName = row.display_name,
        verified    = isTruthy(row.verified),
        body        = row.body,
        parentId    = row.parent_id,
        images      = images,
        views       = tonumber(row.views) or 0,
        createdMs   = (tonumber(row.created_s) or 0) * 1000,
        replies     = tonumber(row.reply_count) or 0,
        likes       = tonumber(row.like_count) or 0,
        liked       = (tonumber(row.liked) or 0) > 0,
    }
end

-- Shared post projection every post read builds on. The leading `?` binds the viewer's citizenid
-- for the per-row `liked` flag, so every caller must pass viewerCid as the FIRST parameter.
-- Declared before its first users (listPostsBy / listLikedBy) - as a local it is invisible to
-- functions defined above it.
---@type string SELECT prefix producing hydratePost-shaped rows (viewer cid is always param #1).
local POST_SELECT = [[
    SELECT
        p.id, p.author_cid, p.body, p.parent_id, p.images, p.views,
        UNIX_TIMESTAMP(p.created_at) AS created_s,
        pr.handle, pr.display_name, pr.verified,
        (SELECT COUNT(*) FROM phone_birdy_likes l  WHERE l.post_id   = p.id) AS like_count,
        (SELECT COUNT(*) FROM phone_birdy_posts r  WHERE r.parent_id = p.id) AS reply_count,
        (SELECT COUNT(*) FROM phone_birdy_likes lv WHERE lv.post_id  = p.id AND lv.citizenid = ?) AS liked
    FROM phone_birdy_posts p
    JOIN phone_birdy_profiles pr ON pr.citizenid = p.author_cid
]]

---List a single author's posts for a profile tab, newest first. 'replies' = posts with a parent;
---'media' = any post (top-level OR reply) carrying images; anything else = top-level only. The
---WHERE clause is chosen from three server-side literals - `kind` itself is never spliced into
---the SQL, so an arbitrary client string just falls through to the default filter.
---@param authorCid string
---@param kind string
---@param viewerCid string
---@param limit number
---@return table[]
function store.listPostsBy(authorCid, kind, viewerCid, limit)
    local clause
    if kind == 'replies' then
        clause = 'p.parent_id IS NOT NULL'
    elseif kind == 'media' then
        clause = "p.images IS NOT NULL AND p.images <> ''"
    else
        clause = 'p.parent_id IS NULL'
    end
    local rows = MySQL.query.await(
        POST_SELECT .. (' WHERE p.author_cid = ? AND %s ORDER BY p.created_at DESC LIMIT ?'):format(clause),
        { viewerCid, authorCid, limit }
    ) or {}
    for i = 1, #rows do rows[i] = hydratePost(rows[i]) end
    return rows
end

---List posts a citizenid has liked, most-recently-liked first.
---@param likerCid string
---@param viewerCid string
---@param limit number
---@return table[]
function store.listLikedBy(likerCid, viewerCid, limit)
    local rows = MySQL.query.await(
        POST_SELECT .. [[
            JOIN phone_birdy_likes lk ON lk.post_id = p.id AND lk.citizenid = ?
            ORDER BY lk.created_at DESC LIMIT ?
        ]],
        { viewerCid, likerCid, limit }
    ) or {}
    for i = 1, #rows do rows[i] = hydratePost(rows[i]) end
    return rows
end

---Delete an account and every row it owns or references: its likes, likes ON its posts, the
---posts themselves, both directions of follows, both directions of DMs, notifications either
---sent or received, and finally the profile row. Order matters only for the likes-on-own-posts
---subquery, which must run while the posts still exist.
---@param citizenid string
function store.deleteAccount(citizenid)
    MySQL.update.await('DELETE FROM phone_birdy_likes WHERE citizenid = ?', { citizenid })
    MySQL.update.await('DELETE FROM phone_birdy_likes WHERE post_id IN (SELECT id FROM phone_birdy_posts WHERE author_cid = ?)', { citizenid })
    MySQL.update.await('DELETE FROM phone_birdy_posts WHERE author_cid = ?', { citizenid })
    MySQL.update.await('DELETE FROM phone_birdy_follows WHERE follower_cid = ? OR target_cid = ?', { citizenid, citizenid })
    MySQL.update.await('DELETE FROM phone_birdy_dms WHERE from_cid = ? OR to_cid = ?', { citizenid, citizenid })
    MySQL.update.await('DELETE FROM phone_birdy_notifications WHERE recipient_cid = ? OR actor_cid = ?', { citizenid, citizenid })
    MySQL.update.await('DELETE FROM phone_birdy_profiles WHERE citizenid = ?', { citizenid })
end

---Overwrite an existing profile's editable fields and sign it in. Legacy path kept for
---compatibility; current actions register via insertAccount instead.
---@param citizenid string
---@param handle string
---@param displayName string
---@param passwordHash string
---@param bio string
function store.updateAccount(citizenid, handle, displayName, passwordHash, bio)
    MySQL.update.await([[
        UPDATE phone_birdy_profiles
        SET handle = ?, display_name = ?, password = ?, bio = ?, logged_in = 1
        WHERE citizenid = ?
    ]], { handle, displayName, passwordHash, bio, citizenid })
end

---Flip a citizenid's informational signed-in flag. Nothing reads it for authorization - sessions
---live in the accounts engine.
---@param citizenid string
---@param value boolean
function store.setLoggedIn(citizenid, value)
    MySQL.update.await(
        'UPDATE phone_birdy_profiles SET logged_in = ? WHERE citizenid = ?',
        { value and 1 or 0, citizenid }
    )
end

---Batch-load profiles keyed by citizenid. The IN (...) list is built purely of `?` placeholders
---(one per cid) with the values bound as parameters, so list length is the only thing formatted
---into the SQL.
---@param cids string[]
---@return table<string, table>
function store.getProfilesByCids(cids)
    local out = {}
    if not cids or #cids == 0 then return out end
    local marks = {}
    for i = 1, #cids do marks[i] = '?' end
    local rows = MySQL.query.await(
        ('SELECT citizenid, handle, display_name, verified FROM phone_birdy_profiles WHERE citizenid IN (%s)')
            :format(table.concat(marks, ',')),
        cids
    ) or {}
    for i = 1, #rows do
        local p = hydrateProfile(rows[i])
        if p then out[p.citizenid] = p end
    end
    return out
end

---A single post by id, hydrated for `viewerCid`'s liked flag.
---@param id string
---@param viewerCid string
---@return table|nil
function store.getPost(id, viewerCid)
    return hydratePost(MySQL.single.await(
        POST_SELECT .. ' WHERE p.id = ? LIMIT 1', { viewerCid, id }
    ))
end

---Hydrated posts for MANY ids in one query - the batch form of getPost, so a notification list
---resolving its reply posts fires one SELECT instead of one per row. Returns an id -> hydrated
---post map (missing ids absent); the viewer's `liked` flag is still resolved per row by the
---POST_SELECT subquery. Read-only.
---@param ids string[] post ids
---@param viewerCid string viewer citizenid (for the liked flag)
---@return table<string, table> id -> hydrated post
function store.postsByIds(ids, viewerCid)
    local out = {}
    if type(ids) ~= 'table' or #ids == 0 then return out end
    local seen, list = {}, {}
    for i = 1, #ids do
        local id = ids[i]
        if id and id ~= '' and not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
    if #list == 0 then return out end
    local marks = {}
    for i = 1, #list do marks[i] = '?' end
    local params = { viewerCid }
    for i = 1, #list do params[#params + 1] = list[i] end
    local rows = MySQL.query.await(
        POST_SELECT .. (' WHERE p.id IN (%s)'):format(table.concat(marks, ',')), params) or {}
    for i = 1, #rows do
        local post = hydratePost(rows[i])
        if post then out[rows[i].id] = post end
    end
    return out
end

---List top-level posts newest-first, optionally limited to accounts the viewer follows (the
---follow filter re-binds the viewer cid, hence it appears twice in that parameter list).
---@param viewerCid string
---@param limit number
---@param onlyFollowing boolean
---@return table[]
function store.listFeed(viewerCid, limit, onlyFollowing)
    local rows
    if onlyFollowing then
        rows = MySQL.query.await(POST_SELECT .. [[
            WHERE p.parent_id IS NULL
              AND p.author_cid IN (SELECT target_cid FROM phone_birdy_follows WHERE follower_cid = ?)
            ORDER BY p.created_at DESC LIMIT ?
        ]], { viewerCid, viewerCid, limit }) or {}
    else
        rows = MySQL.query.await(POST_SELECT .. [[
            WHERE p.parent_id IS NULL ORDER BY p.created_at DESC LIMIT ?
        ]], { viewerCid, limit }) or {}
    end
    for i = 1, #rows do rows[i] = hydratePost(rows[i]) end
    return rows
end

---@param parentId string
---@param viewerCid string
---@return table[] replies oldest-first
function store.listReplies(parentId, viewerCid)
    local rows = MySQL.query.await(
        POST_SELECT .. ' WHERE p.parent_id = ? ORDER BY p.created_at ASC',
        { viewerCid, parentId }
    ) or {}
    for i = 1, #rows do rows[i] = hydratePost(rows[i]) end
    return rows
end

---Insert a post row. Caller owns validation (body length, sanitized images, parent existence);
---we keep the data layer dumb.
---@param id string
---@param authorCid string
---@param body string
---@param parentId string|nil
---@param images string[]|nil up to 3 image URLs, stored as a JSON array
---@return boolean
function store.insertPost(id, authorCid, body, parentId, images)
    local imagesJson = (type(images) == 'table' and #images > 0) and json.encode(images) or nil
    return MySQL.insert.await([[
        INSERT INTO phone_birdy_posts (id, author_cid, body, parent_id, images) VALUES (?, ?, ?, ?, ?)
    ]], { id, authorCid, body, parentId, imagesJson }) ~= nil
end

---Increment a post's view count, but never for the author's own views (the author guard lives in
---the WHERE clause, so it costs nothing extra).
---@param id string
---@param viewerCid string
function store.bumpViews(id, viewerCid)
    MySQL.update.await(
        'UPDATE phone_birdy_posts SET views = views + 1 WHERE id = ? AND author_cid <> ?',
        { id, viewerCid }
    )
end

---@param id string
---@return string|nil author citizenid
function store.getPostAuthor(id)
    return MySQL.scalar.await('SELECT author_cid FROM phone_birdy_posts WHERE id = ?', { id })
end

---Add a like. INSERT IGNORE onto the (post, citizenid) primary key makes replays a no-op, so a
---double-tapped or resent toggle can never double-count.
---@param postId string
---@param cid string
function store.addLike(postId, cid)
    MySQL.insert.await('INSERT IGNORE INTO phone_birdy_likes (post_id, citizenid) VALUES (?, ?)', { postId, cid })
end

---@param postId string
---@param cid string
function store.removeLike(postId, cid)
    MySQL.update.await('DELETE FROM phone_birdy_likes WHERE post_id = ? AND citizenid = ?', { postId, cid })
end

---@param postId string
---@param cid string
---@return boolean true when `cid` has liked the post
function store.isLiked(postId, cid)
    return MySQL.scalar.await(
        'SELECT 1 FROM phone_birdy_likes WHERE post_id = ? AND citizenid = ? LIMIT 1', { postId, cid }
    ) ~= nil
end

---Add a follow edge. INSERT IGNORE onto the composite primary key makes replays a no-op.
---@param follower string
---@param target string
function store.addFollow(follower, target)
    MySQL.insert.await('INSERT IGNORE INTO phone_birdy_follows (follower_cid, target_cid) VALUES (?, ?)', { follower, target })
end

---@param follower string
---@param target string
function store.removeFollow(follower, target)
    MySQL.update.await('DELETE FROM phone_birdy_follows WHERE follower_cid = ? AND target_cid = ?', { follower, target })
end

---@param follower string
---@param target string
---@return boolean true when `follower` follows `target`
function store.isFollowing(follower, target)
    return MySQL.scalar.await(
        'SELECT 1 FROM phone_birdy_follows WHERE follower_cid = ? AND target_cid = ? LIMIT 1', { follower, target }
    ) ~= nil
end

---Insert a DM row. Caller owns validation (kind whitelist, body cap, sanitized meta); the meta
---table is encoded here so callers stay JSON-free.
---@param id string
---@param fromCid string
---@param toCid string
---@param kind string
---@param body string
---@param meta table|nil decoded metadata (gifUrl / amount / waveform / wpCode ...)
---@return boolean
function store.insertDm(id, fromCid, toCid, kind, body, meta)
    local metaJson = (type(meta) == 'table' and next(meta) ~= nil) and json.encode(meta) or nil
    return MySQL.insert.await([[
        INSERT INTO phone_birdy_dms (id, from_cid, to_cid, kind, body, meta) VALUES (?, ?, ?, ?, ?, ?)
    ]], { id, fromCid, toCid, kind or 'text', body or '', metaJson }) ~= nil
end

---Every message involving a player, oldest-first, with `created_ms` added. Always scoped to the
---given cid on one side, so a caller can only ever page its own traffic.
---@param cid string
---@return table[]
function store.listMessagesFor(cid)
    local rows = MySQL.query.await([[
        SELECT id, from_cid, to_cid, body, kind, meta, reactions, read_flag, UNIX_TIMESTAMP(created_at) AS created_s
        FROM phone_birdy_dms WHERE from_cid = ? OR to_cid = ? ORDER BY created_at ASC
    ]], { cid, cid }) or {}
    for i = 1, #rows do rows[i].created_ms = (tonumber(rows[i].created_s) or 0) * 1000 end
    return rows
end

---Mark every message FROM `otherCid` TO `viewerCid` as read (called when the viewer opens that
---thread). Direction-scoped, so a caller can only clear its own inbound flags. Idempotent.
---@param viewerCid string
---@param otherCid string
function store.markThreadRead(viewerCid, otherCid)
    if not viewerCid or viewerCid == '' or not otherCid or otherCid == '' then return end
    MySQL.update.await(
        'UPDATE phone_birdy_dms SET read_flag = 1 WHERE to_cid = ? AND from_cid = ? AND read_flag = 0',
        { viewerCid, otherCid })
end

---Messages between two players, oldest-first, with `created_ms` added. Both directions of
---exactly this pair - the caller pins one side to the requesting viewer.
---@param cidA string
---@param cidB string
---@return table[]
function store.listThread(cidA, cidB)
    local rows = MySQL.query.await([[
        SELECT id, from_cid, to_cid, body, kind, meta, reactions, UNIX_TIMESTAMP(created_at) AS created_s
        FROM phone_birdy_dms
        WHERE (from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?)
        ORDER BY created_at ASC
    ]], { cidA, cidB, cidB, cidA }) or {}
    for i = 1, #rows do rows[i].created_ms = (tonumber(rows[i].created_s) or 0) * 1000 end
    return rows
end

---A single DM row by id, with `created_ms` added. Caller enforces participant checks before
---acting on it.
---@param id string
---@return table|nil
function store.getDm(id)
    local row = MySQL.single.await([[
        SELECT id, from_cid, to_cid, body, kind, meta, reactions, UNIX_TIMESTAMP(created_at) AS created_s
        FROM phone_birdy_dms WHERE id = ?
    ]], { id })
    if row then row.created_ms = (tonumber(row.created_s) or 0) * 1000 end
    return row
end

---Overwrite a DM's reactions (a JSON object of emoji -> array of citizenids). An empty table
---stores NULL so untouched rows and cleared rows look the same.
---@param id string
---@param reactions table
function store.updateDmReactions(id, reactions)
    local rjson = (type(reactions) == 'table' and next(reactions) ~= nil) and json.encode(reactions) or nil
    MySQL.update.await('UPDATE phone_birdy_dms SET reactions = ? WHERE id = ?', { rjson, id })
end

---@param id string
---@param recipientCid string
---@param kind string
---@param actorCid string
---@param postId string|nil
function store.insertNotification(id, recipientCid, kind, actorCid, postId)
    MySQL.insert.await([[
        INSERT INTO phone_birdy_notifications (id, recipient_cid, kind, actor_cid, post_id)
        VALUES (?, ?, ?, ?, ?)
    ]], { id, recipientCid, kind, actorCid, postId })
end

---@param recipientCid string
---@param limit number
---@return table[] rows with `created_ms` added
function store.listNotifications(recipientCid, limit)
    local rows = MySQL.query.await([[
        SELECT id, kind, actor_cid, post_id, UNIX_TIMESTAMP(created_at) AS created_s
        FROM phone_birdy_notifications WHERE recipient_cid = ?
        ORDER BY created_at DESC LIMIT ?
    ]], { recipientCid, limit }) or {}
    for i = 1, #rows do rows[i].created_ms = (tonumber(rows[i].created_s) or 0) * 1000 end
    return rows
end

return store
