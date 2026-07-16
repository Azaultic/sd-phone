---@type table Shared server helpers (server.util): the ensureIndex drop-in upgrade helper.
local util = require 'server.util'

---@type table Store module; the table returned at end of file.
local store = {}

---@type string Alphabet for generated row ids (lowercase base36).
local ID_CHARS = '0123456789abcdefghijklmnopqrstuvwxyz'

---A fresh random 7-char base36 id for any photogram row (post/comment/story/notification/DM).
---36^7 (~78 billion) keys make a PRIMARY KEY collision negligible at phone scale while staying
---short enough to ship to the React side verbatim.
---@return string id
function store.newId()
    local out = {}
    for i = 1, 7 do
        local n = math.random(1, #ID_CHARS)
        out[i] = ID_CHARS:sub(n, n)
    end
    return table.concat(out)
end

---Tolerant JSON-column reader. oxmysql hands JSON columns back as strings (and some call sites
---already hold decoded tables), so both are accepted; NULL, garbage, or non-table JSON all
---collapse to {} so callers can iterate without branching. The pcall guards json.decode raising
---on malformed input.
---@param value any raw column value (string | table | nil)
---@return table decoded table ({} when absent or invalid)
function store.decodeJson(value)
    if value == nil then return {} end
    if type(value) == 'table' then return value end
    if type(value) == 'string' then
        local ok, decoded = pcall(json.decode, value)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return {}
end

---Encode a table for a JSON column, mapping empty/absent to nil so unused columns stay SQL NULL
---instead of storing '{}' noise.
---@param tbl table|nil
---@return string|nil json
local function encodeJson(tbl)
    if not tbl or next(tbl) == nil then return nil end
    return json.encode(tbl)
end

---@type fun(tbl: table|nil): string|nil Public alias of encodeJson for sibling modules.
store.encodeJson = encodeJson

---Create every photogram table if missing and back-fill columns added after the tables first
---shipped, so the resource is drop-in on fresh and old databases alike. Run once at boot
---(server.photogram.init). Identity throughout the schema is the photogram ACCOUNT USERNAME -
---the accounts engine owns credentials/sessions, so a profile follows the account across
---characters. Counts (likes/comments/followers) are computed live from the relation tables,
---never denormalized, so they can't drift. Timestamps are unix seconds (BIGINT); the actions
---layer multiplies to millis for React. The nested ensureColumn back-fill exists because CREATE
---TABLE IF NOT EXISTS never alters an existing table - without it, servers whose photogram
---tables predate is_private/verified/status silently lose the private-account toggle and follow
---requests (the upsert/insert can't write the column). Its ALTER is built with :format, but both
---arguments are literals owned by this function - no client input ever reaches it. Follow rows
---that predate the request flow are defaulted to 'accepted' by the back-filled status column.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_profiles (
            username      VARCHAR(64)  NOT NULL,
            display_name  VARCHAR(64)  NOT NULL DEFAULT '',
            bio           VARCHAR(200) NOT NULL DEFAULT '',
            avatar        VARCHAR(512) NULL,
            is_private    TINYINT(1)   NOT NULL DEFAULT 0,
            verified      TINYINT(1)   NOT NULL DEFAULT 0,
            created_at    BIGINT       NOT NULL DEFAULT 0,
            PRIMARY KEY (username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_posts (
            id          VARCHAR(16)   NOT NULL,
            author      VARCHAR(64)   NOT NULL,
            images      JSON          NULL,
            caption     VARCHAR(2200) NOT NULL DEFAULT '',
            location    VARCHAR(120)  NULL,
            created_at  BIGINT        NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_photogram_posts_author (author, created_at),
            INDEX idx_photogram_posts_created (created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_likes (
            post_id     VARCHAR(16) NOT NULL,
            username    VARCHAR(64) NOT NULL,
            created_at  BIGINT      NOT NULL,
            PRIMARY KEY (post_id, username),
            INDEX idx_photogram_likes_post (post_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_saves (
            post_id     VARCHAR(16) NOT NULL,
            username    VARCHAR(64) NOT NULL,
            created_at  BIGINT      NOT NULL,
            PRIMARY KEY (username, post_id),
            INDEX idx_photogram_saves_user (username, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_comments (
            id          VARCHAR(16)   NOT NULL,
            post_id     VARCHAR(16)   NOT NULL,
            author      VARCHAR(64)   NOT NULL,
            body        VARCHAR(1000) NULL,
            gif_url     VARCHAR(512)  NULL,
            created_at  BIGINT        NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_photogram_comments_post (post_id, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_comment_likes (
            comment_id  VARCHAR(16) NOT NULL,
            username    VARCHAR(64) NOT NULL,
            created_at  BIGINT      NOT NULL,
            PRIMARY KEY (comment_id, username),
            INDEX idx_photogram_comment_likes_c (comment_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_follows (
            follower    VARCHAR(64) NOT NULL,
            target      VARCHAR(64) NOT NULL,
            status      VARCHAR(12) NOT NULL DEFAULT 'accepted',
            created_at  BIGINT      NOT NULL,
            PRIMARY KEY (follower, target),
            INDEX idx_photogram_follows_target (target, status)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_stories (
            id          VARCHAR(16)  NOT NULL,
            author      VARCHAR(64)  NOT NULL,
            image       VARCHAR(512) NOT NULL,
            created_at  BIGINT       NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_photogram_stories_author (author, created_at),
            INDEX idx_photogram_stories_created (created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_story_views (
            story_id    VARCHAR(16) NOT NULL,
            username    VARCHAR(64) NOT NULL,
            created_at  BIGINT      NOT NULL,
            PRIMARY KEY (story_id, username),
            INDEX idx_photogram_story_views_user (username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_notifications (
            id          VARCHAR(16)  NOT NULL,
            recipient   VARCHAR(64)  NOT NULL,
            kind        VARCHAR(16)  NOT NULL,
            actor       VARCHAR(64)  NOT NULL,
            post_id     VARCHAR(16)  NULL,
            preview     VARCHAR(200) NULL,
            seen        TINYINT(1)   NOT NULL DEFAULT 0,
            created_at  BIGINT       NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_photogram_notifs_recipient (recipient, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    util.ensureIndex('phone_photogram_notifications', 'idx_photogram_notifs_unseen', '(recipient, seen)')

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_photogram_dms (
            id          VARCHAR(16) NOT NULL,
            from_user   VARCHAR(64) NOT NULL,
            to_user     VARCHAR(64) NOT NULL,
            body        TEXT        NULL,
            kind        VARCHAR(16) NOT NULL DEFAULT 'text',
            meta        JSON        NULL,
            reactions   JSON        NULL,
            read_flag   TINYINT(1)  NOT NULL DEFAULT 0,
            created_at  BIGINT      NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_photogram_dms_from (from_user, created_at),
            INDEX idx_photogram_dms_to (to_user, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    util.ensureIndex('phone_photogram_dms', 'idx_photogram_dms_unread', '(to_user, read_flag)')

    local function ensureColumn(tbl, name, ddl)
        local present = MySQL.scalar.await([[
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?
        ]], { tbl, name })
        if (tonumber(present) or 0) == 0 then
            MySQL.query.await(('ALTER TABLE %s ADD COLUMN %s'):format(tbl, ddl))
        end
    end
    ensureColumn('phone_photogram_profiles', 'is_private', 'is_private TINYINT(1) NOT NULL DEFAULT 0')
    ensureColumn('phone_photogram_profiles', 'verified',   'verified TINYINT(1) NOT NULL DEFAULT 0')
    ensureColumn('phone_photogram_follows',  'status',     "status VARCHAR(12) NOT NULL DEFAULT 'accepted'")
end

---A profile row by exact username, nil when the handle doesn't exist. Read-only.
---@param username string account handle
---@return table|nil row
function store.getProfile(username)
    return MySQL.single.await('SELECT * FROM phone_photogram_profiles WHERE username = ?', { username })
end

---Insert or update a profile. ON DUPLICATE deliberately leaves verified and created_at alone:
---verified isn't self-service (actions.updateProfile only passes the existing flag through, and
---this upsert wouldn't write it anyway) and the join date never moves - so a crafted profile
---update can't mint a checkmark or reset account age. Length caps live in the actions layer;
---the data layer stays dumb.
---@param username string account handle
---@param p table { displayName?, bio?, avatar?, isPrivate?, verified?, createdAt? }
function store.upsertProfile(username, p)
    MySQL.query.await([[
        INSERT INTO phone_photogram_profiles (username, display_name, bio, avatar, is_private, verified, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            display_name = VALUES(display_name), bio = VALUES(bio),
            avatar = VALUES(avatar), is_private = VALUES(is_private)
    ]], {
        username, p.displayName or '', p.bio or '', p.avatar,
        p.isPrivate and 1 or 0, p.verified and 1 or 0, p.createdAt or os.time(),
    })
end

---Profiles for a list of usernames, keyed by username (batch hydration of notification / DM
---lists). Placeholders are generated per entry and every value is bound - nothing from the list
---is concatenated into the SQL. Blank entries are skipped; an all-blank list short-circuits.
---@param list string[] usernames
---@return table<string, table> rows by username
function store.profilesByUsernames(list)
    local out, ph, args = {}, {}, {}
    for i = 1, #list do
        if list[i] and list[i] ~= '' then ph[#ph + 1] = '?'; args[#args + 1] = list[i] end
    end
    if #args == 0 then return out end
    local rows = MySQL.query.await(
        ('SELECT * FROM phone_photogram_profiles WHERE username IN (%s)'):format(table.concat(ph, ',')),
        args
    ) or {}
    for _, r in ipairs(rows) do out[r.username] = r end
    return out
end

---Match accounts by handle or display name (Search / DM new-message / mentions). The query
---string travels as a bound LIKE parameter, never concatenated; the LIMIT is floored to an
---integer and is always supplied by the actions layer, not the client.
---@param query string search text
---@param limit? integer max rows (default 20)
---@return table[] rows
function store.searchProfiles(query, limit)
    local n = math.floor(tonumber(limit) or 20)
    local like = '%' .. query .. '%'
    return MySQL.query.await(([[
        SELECT * FROM phone_photogram_profiles
        WHERE username LIKE ? OR display_name LIKE ?
        ORDER BY username ASC
        LIMIT %d
    ]]):format(n), { like, like }) or {}
end

---How many posts an author has (profile header stat). Read-only.
---@param username string account handle
---@return integer n
function store.countPosts(username)
    local row = MySQL.single.await('SELECT COUNT(*) AS n FROM phone_photogram_posts WHERE author = ?', { username })
    return row and tonumber(row.n) or 0
end

---The follow edge's status from follower to target ('pending'/'accepted'), nil when no edge.
---@param follower string account handle
---@param target string account handle
---@return string|nil status
function store.followStatus(follower, target)
    return MySQL.scalar.await(
        'SELECT status FROM phone_photogram_follows WHERE follower = ? AND target = ?',
        { follower, target }
    )
end

---Create (or re-status) a follow edge. Upsert so re-following after an unfollow, or a request
---replayed by a double-tap, lands on the same (follower, target) row instead of erroring.
---@param follower string account handle
---@param target string account handle
---@param status string 'pending' | 'accepted'
---@param createdAt integer unix seconds
function store.addFollow(follower, target, status, createdAt)
    MySQL.query.await([[
        INSERT INTO phone_photogram_follows (follower, target, status, created_at)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE status = VALUES(status)
    ]], { follower, target, status, createdAt })
end

---Flip an existing follow edge's status (accepting a pending request). No-op when the edge
---doesn't exist.
---@param follower string account handle
---@param target string account handle
---@param status string new status
function store.setFollowStatus(follower, target, status)
    MySQL.update.await(
        'UPDATE phone_photogram_follows SET status = ? WHERE follower = ? AND target = ?',
        { status, follower, target }
    )
end

---Delete a follow edge (unfollow / cancel request / decline).
---@param follower string account handle
---@param target string account handle
function store.removeFollow(follower, target)
    MySQL.update.await('DELETE FROM phone_photogram_follows WHERE follower = ? AND target = ?', { follower, target })
end

---True when the follower-to-target edge exists AND is accepted - the single visibility test
---every private-account gate (posts, stories, lives, follow lists) rides on.
---@param follower string account handle
---@param target string account handle
---@return boolean accepted
function store.isAcceptedFollower(follower, target)
    return MySQL.scalar.await(
        "SELECT 1 FROM phone_photogram_follows WHERE follower = ? AND target = ? AND status = 'accepted'",
        { follower, target }
    ) ~= nil
end

---Accepted-follower count for the profile header. Pending requests don't count. Read-only.
---@param username string account handle
---@return integer n
function store.countFollowers(username)
    local row = MySQL.single.await(
        "SELECT COUNT(*) AS n FROM phone_photogram_follows WHERE target = ? AND status = 'accepted'",
        { username }
    )
    return row and tonumber(row.n) or 0
end

---Accepted-following count for the profile header. Read-only.
---@param username string account handle
---@return integer n
function store.countFollowing(username)
    local row = MySQL.single.await(
        "SELECT COUNT(*) AS n FROM phone_photogram_follows WHERE follower = ? AND status = 'accepted'",
        { username }
    )
    return row and tonumber(row.n) or 0
end

---Accounts that follow `username` (any kind value) or that `username` follows
---(kind='following'), each row a full profile card. Accepted edges only - pending requests
---never appear in either list.
---@param username string account handle
---@param kind string 'following' for the following list; anything else means followers
---@return table[] profile rows
function store.followList(username, kind)
    if kind == 'following' then
        return MySQL.query.await([[
            SELECT pr.* FROM phone_photogram_follows f
            JOIN phone_photogram_profiles pr ON pr.username = f.target
            WHERE f.follower = ? AND f.status = 'accepted'
            ORDER BY f.created_at DESC
        ]], { username }) or {}
    end
    return MySQL.query.await([[
        SELECT pr.* FROM phone_photogram_follows f
        JOIN phone_photogram_profiles pr ON pr.username = f.follower
        WHERE f.target = ? AND f.status = 'accepted'
        ORDER BY f.created_at DESC
    ]], { username }) or {}
end

---Pending follow requests waiting on `username` to accept, newest first, each with the
---requester's profile card.
---@param username string account handle
---@return table[] requester rows (+ requested_at)
function store.pendingRequests(username)
    return MySQL.query.await([[
        SELECT pr.*, f.created_at AS requested_at FROM phone_photogram_follows f
        JOIN phone_photogram_profiles pr ON pr.username = f.follower
        WHERE f.target = ? AND f.status = 'pending'
        ORDER BY f.created_at DESC
    ]], { username }) or {}
end

---Usernames of everyone who accepted-follows `username` (for fanning a new-post notification
---out to their feed audience).
---@param username string account handle
---@return string[] follower usernames
function store.followerUsernames(username)
    local rows = MySQL.query.await(
        "SELECT follower FROM phone_photogram_follows WHERE target = ? AND status = 'accepted'",
        { username }
    ) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.follower end
    return out
end

---@type string Shared post projection: the post row + its author's card fields + live counts +
---the viewer's own liked/saved flags. Binds the viewer TWICE up front (liked, saved), so every
---caller passes viewer, viewer first, then its own params.
local POST_SELECT = [[
    SELECT p.id, p.author, p.images, p.caption, p.location, p.created_at,
           pr.display_name, pr.avatar, pr.verified, pr.is_private,
           (SELECT COUNT(*) FROM phone_photogram_likes l WHERE l.post_id = p.id) AS like_count,
           (SELECT COUNT(*) FROM phone_photogram_comments cc WHERE cc.post_id = p.id) AS comment_count,
           (SELECT COUNT(*) FROM phone_photogram_likes lv WHERE lv.post_id = p.id AND lv.username = ?) AS liked,
           (SELECT COUNT(*) FROM phone_photogram_saves sv WHERE sv.post_id = p.id AND sv.username = ?) AS saved
    FROM phone_photogram_posts p
    JOIN phone_photogram_profiles pr ON pr.username = p.author
]]

---Persist a new post. Images arrive already sanitized (actions caps them at 10 http(s) URLs of
---512 chars); caption/location are pre-capped to their column widths.
---@param id string post id (store.newId)
---@param author string account handle
---@param images string[] image URLs
---@param caption string caption text
---@param location string|nil location label
---@param createdAt integer unix seconds
function store.insertPost(id, author, images, caption, location, createdAt)
    MySQL.insert.await([[
        INSERT INTO phone_photogram_posts (id, author, images, caption, location, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { id, author, encodeJson(images), caption, location, createdAt })
end

---One post through the viewer projection (nil when the id doesn't exist). Read-only.
---@param viewer string viewing account handle
---@param id string post id
---@return table|nil row
function store.getPost(viewer, id)
    return MySQL.single.await(POST_SELECT .. ' WHERE p.id = ? LIMIT 1', { viewer, viewer, id })
end

---Plain post row (no projection) - used for ownership checks before a mutation, so the caller
---can compare author against the acting account without paying for the full viewer projection.
---@param id string post id
---@return table|nil row { id, author }
function store.getPostRow(id)
    return MySQL.single.await('SELECT id, author FROM phone_photogram_posts WHERE id = ?', { id })
end

---Home feed: the viewer's own posts + accepted-following, newest first. Read-only.
---@param viewer string viewing account handle
---@param limit? integer max rows (default 60, server-supplied)
---@return table[] rows
function store.feedPosts(viewer, limit)
    local n = math.floor(tonumber(limit) or 60)
    return MySQL.query.await((POST_SELECT .. [[
        WHERE p.author = ? OR p.author IN (
            SELECT target FROM phone_photogram_follows WHERE follower = ? AND status = 'accepted'
        )
        ORDER BY p.created_at DESC
        LIMIT %d
    ]]):format(n), { viewer, viewer, viewer, viewer }) or {}
end

---Explore: recent posts from public accounts (or private ones the viewer follows), never the
---viewer's own - the discovery grid. The privacy filter lives in the SQL so a private author's
---posts can't leak into anyone's explore page. Read-only.
---@param viewer string viewing account handle
---@param limit? integer max rows (default 60, server-supplied)
---@return table[] rows
function store.explorePosts(viewer, limit)
    local n = math.floor(tonumber(limit) or 60)
    return MySQL.query.await((POST_SELECT .. [[
        WHERE p.author <> ?
          AND (pr.is_private = 0 OR p.author IN (
              SELECT target FROM phone_photogram_follows WHERE follower = ? AND status = 'accepted'
          ))
        ORDER BY p.created_at DESC
        LIMIT %d
    ]]):format(n), { viewer, viewer, viewer, viewer }) or {}
end

---A single author's posts (profile grid), newest first. Private-account gating is the CALLER's
---job (actions.profilePosts checks canView before asking). Read-only.
---@param viewer string viewing account handle
---@param author string profile being viewed
---@param limit? integer max rows (default 60, server-supplied)
---@return table[] rows
function store.postsBy(viewer, author, limit)
    local n = math.floor(tonumber(limit) or 60)
    return MySQL.query.await((POST_SELECT .. [[
        WHERE p.author = ?
        ORDER BY p.created_at DESC
        LIMIT %d
    ]]):format(n), { viewer, viewer, author }) or {}
end

---Posts the viewer has saved/bookmarked, newest-saved first. Read-only.
---@param viewer string viewing account handle
---@param limit? integer max rows (default 60, server-supplied)
---@return table[] rows
function store.savedPosts(viewer, limit)
    local n = math.floor(tonumber(limit) or 60)
    return MySQL.query.await((POST_SELECT .. [[
        JOIN phone_photogram_saves sf ON sf.post_id = p.id AND sf.username = ?
        ORDER BY sf.created_at DESC
        LIMIT %d
    ]]):format(n), { viewer, viewer, viewer }) or {}
end

---Delete a post and every dependent row, children before parents (comment likes, comments,
---likes, saves, notifications, then the post) so nothing is orphaned and a future id collision
---can't inherit stale rows. Ownership is checked by the caller (actions.deletePost) before this
---runs; the data layer stays dumb.
---@param id string post id
function store.deletePost(id)
    MySQL.update.await('DELETE FROM phone_photogram_comment_likes WHERE comment_id IN (SELECT id FROM phone_photogram_comments WHERE post_id = ?)', { id })
    MySQL.update.await('DELETE FROM phone_photogram_comments WHERE post_id = ?', { id })
    MySQL.update.await('DELETE FROM phone_photogram_likes WHERE post_id = ?', { id })
    MySQL.update.await('DELETE FROM phone_photogram_saves WHERE post_id = ?', { id })
    MySQL.update.await('DELETE FROM phone_photogram_notifications WHERE post_id = ?', { id })
    MySQL.update.await('DELETE FROM phone_photogram_posts WHERE id = ?', { id })
end

---Whether `username` currently likes a post. Read-only.
---@param postId string post id
---@param username string account handle
---@return boolean liked
function store.isLiked(postId, username)
    return MySQL.scalar.await('SELECT 1 FROM phone_photogram_likes WHERE post_id = ? AND username = ?', { postId, username }) ~= nil
end

---Record a like. INSERT IGNORE + the (post_id, username) PRIMARY KEY make a replayed like
---idempotent - a lag resend can't double-count.
---@param postId string post id
---@param username string account handle
---@param createdAt integer unix seconds
function store.addLike(postId, username, createdAt)
    MySQL.query.await('INSERT IGNORE INTO phone_photogram_likes (post_id, username, created_at) VALUES (?, ?, ?)', { postId, username, createdAt })
end

---Remove a like (no-op when absent).
---@param postId string post id
---@param username string account handle
function store.removeLike(postId, username)
    MySQL.update.await('DELETE FROM phone_photogram_likes WHERE post_id = ? AND username = ?', { postId, username })
end

---Whether `username` has saved a post. Read-only.
---@param postId string post id
---@param username string account handle
---@return boolean saved
function store.isSaved(postId, username)
    return MySQL.scalar.await('SELECT 1 FROM phone_photogram_saves WHERE post_id = ? AND username = ?', { postId, username }) ~= nil
end

---Record a save. INSERT IGNORE + the composite PRIMARY KEY make a replay idempotent.
---@param postId string post id
---@param username string account handle
---@param createdAt integer unix seconds
function store.addSave(postId, username, createdAt)
    MySQL.query.await('INSERT IGNORE INTO phone_photogram_saves (post_id, username, created_at) VALUES (?, ?, ?)', { postId, username, createdAt })
end

---Remove a save (no-op when absent).
---@param postId string post id
---@param username string account handle
function store.removeSave(postId, username)
    MySQL.update.await('DELETE FROM phone_photogram_saves WHERE post_id = ? AND username = ?', { postId, username })
end

---Persist a comment. body/gifUrl arrive pre-capped and at-least-one-present validated by
---actions.addComment.
---@param id string comment id (store.newId)
---@param postId string parent post id
---@param author string account handle
---@param body string|nil comment text
---@param gifUrl string|nil GIF attachment URL
---@param createdAt integer unix seconds
function store.insertComment(id, postId, author, body, gifUrl, createdAt)
    MySQL.insert.await([[
        INSERT INTO phone_photogram_comments (id, post_id, author, body, gif_url, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], { id, postId, author, body, gifUrl, createdAt })
end

---A post's comments, oldest first, each with its author card, live like count, and a per-viewer
---liked flag. Read-only.
---@param postId string post id
---@param viewer string viewing account handle
---@param limit? integer max rows (default 200, server-supplied)
---@return table[] rows
function store.commentsFor(postId, viewer, limit)
    local n = math.floor(tonumber(limit) or 200)
    return MySQL.query.await(([[
        SELECT c.id, c.post_id, c.author, c.body, c.gif_url, c.created_at,
               pr.display_name, pr.avatar, pr.verified,
               (SELECT COUNT(*) FROM phone_photogram_comment_likes cl WHERE cl.comment_id = c.id) AS like_count,
               (SELECT COUNT(*) FROM phone_photogram_comment_likes clv WHERE clv.comment_id = c.id AND clv.username = ?) AS liked
        FROM phone_photogram_comments c
        JOIN phone_photogram_profiles pr ON pr.username = c.author
        WHERE c.post_id = ?
        ORDER BY c.created_at ASC
        LIMIT %d
    ]]):format(n), { viewer, postId }) or {}
end

---Plain comment row - existence/ownership checks before a mutation. Read-only.
---@param id string comment id
---@return table|nil row { id, post_id, author }
function store.getCommentRow(id)
    return MySQL.single.await('SELECT id, post_id, author FROM phone_photogram_comments WHERE id = ?', { id })
end

---Whether `username` currently likes a comment. Read-only.
---@param commentId string comment id
---@param username string account handle
---@return boolean liked
function store.isCommentLiked(commentId, username)
    return MySQL.scalar.await('SELECT 1 FROM phone_photogram_comment_likes WHERE comment_id = ? AND username = ?', { commentId, username }) ~= nil
end

---Record a comment like. INSERT IGNORE + the composite PRIMARY KEY make a replay idempotent.
---@param commentId string comment id
---@param username string account handle
---@param createdAt integer unix seconds
function store.addCommentLike(commentId, username, createdAt)
    MySQL.query.await('INSERT IGNORE INTO phone_photogram_comment_likes (comment_id, username, created_at) VALUES (?, ?, ?)', { commentId, username, createdAt })
end

---Remove a comment like (no-op when absent).
---@param commentId string comment id
---@param username string account handle
function store.removeCommentLike(commentId, username)
    MySQL.update.await('DELETE FROM phone_photogram_comment_likes WHERE comment_id = ? AND username = ?', { commentId, username })
end

---Live like count for one comment. Read-only.
---@param commentId string comment id
---@return integer n
function store.commentLikeCount(commentId)
    local row = MySQL.single.await('SELECT COUNT(*) AS n FROM phone_photogram_comment_likes WHERE comment_id = ?', { commentId })
    return row and tonumber(row.n) or 0
end

---Persist a story frame. The image URL arrives pre-validated (http-prefixed, capped 512) from
---actions.addStory.
---@param id string story id (store.newId)
---@param author string account handle
---@param image string image URL
---@param createdAt integer unix seconds
function store.insertStory(id, author, image, createdAt)
    MySQL.insert.await(
        'INSERT INTO phone_photogram_stories (id, author, image, created_at) VALUES (?, ?, ?, ?)',
        { id, author, image, createdAt }
    )
end

---Active (non-expired) stories from the viewer + the accounts they accepted-follow, ordered by
---author then chronologically so frames group per author. The follow filter doubles as the
---privacy gate: a private author's stories only reach accepted followers. Read-only.
---@param viewer string viewing account handle
---@param cutoff integer unix seconds - stories created at or before this are expired
---@return table[] rows
function store.activeStoriesFor(viewer, cutoff)
    return MySQL.query.await([[
        SELECT s.id, s.author, s.image, s.created_at,
               pr.display_name, pr.avatar, pr.verified
        FROM phone_photogram_stories s
        JOIN phone_photogram_profiles pr ON pr.username = s.author
        WHERE s.created_at > ?
          AND (s.author = ? OR s.author IN (
              SELECT target FROM phone_photogram_follows WHERE follower = ? AND status = 'accepted'
          ))
        ORDER BY s.author ASC, s.created_at ASC
    ]], { cutoff, viewer, viewer }) or {}
end

---Story ids the viewer has already seen (across all stories), as a set for O(1) lookup while
---grouping the tray. Read-only.
---@param viewer string viewing account handle
---@return table<string, boolean> seen set
function store.seenStoryIds(viewer)
    local rows = MySQL.query.await('SELECT story_id FROM phone_photogram_story_views WHERE username = ?', { viewer }) or {}
    local set = {}
    for _, r in ipairs(rows) do set[r.story_id] = true end
    return set
end

---Record that `username` viewed a story. INSERT IGNORE + the composite PRIMARY KEY make a
---replayed view idempotent.
---@param storyId string story id
---@param username string account handle
---@param createdAt integer unix seconds
function store.markStorySeen(storyId, username, createdAt)
    MySQL.query.await('INSERT IGNORE INTO phone_photogram_story_views (story_id, username, created_at) VALUES (?, ?, ?)', { storyId, username, createdAt })
end

---Plain story row - existence checks before marking one seen. Read-only.
---@param id string story id
---@return table|nil row { id, author }
function store.getStoryRow(id)
    return MySQL.single.await('SELECT id, author FROM phone_photogram_stories WHERE id = ?', { id })
end

---Drop expired stories and their view rows - called opportunistically from actions.stories.
---Views go first while the subquery can still see the expiring story ids.
---@param cutoff integer unix seconds - stories created at or before this are expired
function store.pruneExpiredStories(cutoff)
    MySQL.update.await('DELETE FROM phone_photogram_story_views WHERE story_id IN (SELECT id FROM phone_photogram_stories WHERE created_at <= ?)', { cutoff })
    MySQL.update.await('DELETE FROM phone_photogram_stories WHERE created_at <= ?', { cutoff })
end

---Persist an Activity notification. preview arrives pre-capped (actions caps comment previews
---at 120 chars, well under the 200 column).
---@param id string notification id (store.newId)
---@param recipient string account handle receiving it
---@param kind string notification kind (like/comment/mention/follow/...)
---@param actor string account handle that caused it
---@param postId string|nil related post id
---@param preview string|nil short body preview
---@param createdAt integer unix seconds
function store.insertNotification(id, recipient, kind, actor, postId, preview, createdAt)
    MySQL.insert.await([[
        INSERT INTO phone_photogram_notifications (id, recipient, kind, actor, post_id, preview, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], { id, recipient, kind, actor, postId, preview, createdAt })
end

---A recipient's notifications, newest first, each with the actor's profile card (LEFT JOIN so a
---wiped actor still shows the row). Read-only.
---@param recipient string account handle
---@param limit? integer max rows (default 60, server-supplied)
---@return table[] rows
function store.notificationsFor(recipient, limit)
    local n = math.floor(tonumber(limit) or 60)
    return MySQL.query.await(([[
        SELECT n.id, n.kind, n.actor, n.post_id, n.preview, n.seen, n.created_at,
               pr.display_name, pr.avatar, pr.verified
        FROM phone_photogram_notifications n
        LEFT JOIN phone_photogram_profiles pr ON pr.username = n.actor
        WHERE n.recipient = ?
        ORDER BY n.created_at DESC
        LIMIT %d
    ]]):format(n), { recipient }) or {}
end

---Mark every unseen notification seen (opening the Activity tab clears the badge contribution).
---@param recipient string account handle
function store.markNotificationsSeen(recipient)
    MySQL.update.await('UPDATE phone_photogram_notifications SET seen = 1 WHERE recipient = ? AND seen = 0', { recipient })
end

---Delete one of the recipient's own notifications (swipe-to-dismiss). Scoped to the owner so a
---forged id can't clear someone else's feed.
---@param id string notification id
---@param recipient string owning account handle
function store.deleteNotification(id, recipient)
    MySQL.update.await('DELETE FROM phone_photogram_notifications WHERE id = ? AND recipient = ?', { id, recipient })
end

---Drop the pending follow-request notification when the requester cancels it, so it doesn't
---linger on the recipient's Activity or inflate their unread badge.
---@param recipient string account handle that received the request
---@param actor string account handle that withdrew it
function store.deleteRequestNotification(recipient, actor)
    MySQL.update.await(
        "DELETE FROM phone_photogram_notifications WHERE recipient = ? AND actor = ? AND kind = 'follow_request'",
        { recipient, actor })
end

---Unseen-notification count for the app badge. Read-only.
---@param recipient string account handle
---@return integer n
function store.unseenNotificationCount(recipient)
    local row = MySQL.single.await('SELECT COUNT(*) AS n FROM phone_photogram_notifications WHERE recipient = ? AND seen = 0', { recipient })
    return row and tonumber(row.n) or 0
end

---First image of a post (notification thumbnail), nil when the post is gone or imageless.
---Read-only.
---@param postId string|nil post id
---@return string|nil url
function store.postThumb(postId)
    if not postId or postId == '' then return nil end
    local row = MySQL.single.await('SELECT images FROM phone_photogram_posts WHERE id = ?', { postId })
    if not row then return nil end
    local imgs = store.decodeJson(row.images)
    return imgs[1]
end

---First image (thumbnail) for MANY posts in one query - the batch form of postThumb, so the
---Activity feed resolves all its notification thumbnails in a single round-trip instead of one
---SELECT per row. Returns a postId -> first-image-url map; ids with no post or no images are
---absent. Read-only.
---@param postIds string[]
---@return table<string, string> postId -> first image url
function store.thumbsFor(postIds)
    if type(postIds) ~= 'table' then return {} end
    local seen, list = {}, {}
    for i = 1, #postIds do
        local id = postIds[i]
        if id and id ~= '' and not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
    if #list == 0 then return {} end
    local placeholders = ('?,'):rep(#list):sub(1, -2)
    local rows = MySQL.query.await(
        'SELECT id, images FROM phone_photogram_posts WHERE id IN (' .. placeholders .. ')', list) or {}
    local out = {}
    for i = 1, #rows do
        local imgs = store.decodeJson(rows[i].images)
        if imgs[1] then out[rows[i].id] = imgs[1] end
    end
    return out
end

---Persist a DM. body/kind/meta arrive validated by actions.dmSend (kind whitelisted, body
---capped, meta sanitized per kind).
---@param id string message id (store.newId)
---@param fromUser string sending account handle
---@param toUser string receiving account handle
---@param body string message text
---@param kind string message kind (text/image/gif/voice/post)
---@param meta table|nil kind-specific attachment fields
---@param createdAt integer unix seconds
function store.insertDm(id, fromUser, toUser, body, kind, meta, createdAt)
    MySQL.insert.await([[
        INSERT INTO phone_photogram_dms (id, from_user, to_user, body, kind, meta, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], { id, fromUser, toUser, body, kind, encodeJson(meta), createdAt })
end

---One DM row by id. The CALLER must verify the viewer is a participant before acting on it
---(actions.dmReact does). Read-only.
---@param id string message id
---@return table|nil row
function store.getDm(id)
    return MySQL.single.await('SELECT * FROM phone_photogram_dms WHERE id = ?', { id })
end

---Overwrite a DM's reactions blob (the actions layer owns the toggle logic; the data layer
---stays dumb).
---@param id string message id
---@param reactions table|nil emoji -> usernames map
function store.updateDmReactions(id, reactions)
    MySQL.update.await('UPDATE phone_photogram_dms SET reactions = ? WHERE id = ?', { encodeJson(reactions), id })
end

---Distinct conversation peers for a user, most-recently-active first (both directions folded
---into one list). Read-only.
---@param username string account handle
---@return table[] rows { peer, last_at }
function store.dmPeers(username)
    return MySQL.query.await([[
        SELECT peer, MAX(created_at) AS last_at FROM (
            SELECT to_user   AS peer, created_at FROM phone_photogram_dms WHERE from_user = ?
            UNION ALL
            SELECT from_user AS peer, created_at FROM phone_photogram_dms WHERE to_user = ?
        ) t
        GROUP BY peer
        ORDER BY last_at DESC
    ]], { username, username }) or {}
end

---The newest message between two users (conversation-list preview). Read-only.
---@param a string account handle
---@param b string account handle
---@return table|nil row
function store.dmLast(a, b)
    return MySQL.single.await([[
        SELECT * FROM phone_photogram_dms
        WHERE (from_user = ? AND to_user = ?) OR (from_user = ? AND to_user = ?)
        ORDER BY created_at DESC LIMIT 1
    ]], { a, b, b, a })
end

---Messages between two users. Fetches newest-first so the LIMIT keeps the most RECENT n, then
---reverses in Lua so the chat view still receives them oldest-first. Read-only.
---@param a string account handle
---@param b string account handle
---@param limit? integer max rows (default 200, server-supplied, clamped >= 1)
---@return table[] rows oldest-first
function store.dmThread(a, b, limit)
    local n = math.floor(tonumber(limit) or 200)
    if n < 1 then n = 1 end
    local rows = MySQL.query.await(([[
        SELECT * FROM phone_photogram_dms
        WHERE (from_user = ? AND to_user = ?) OR (from_user = ? AND to_user = ?)
        ORDER BY created_at DESC
        LIMIT %d
    ]]):format(n), { a, b, b, a }) or {}
    local out, len = {}, #rows
    for i = len, 1, -1 do out[len - i + 1] = rows[i] end
    return out
end

---Mark every unread message FROM peer TO username read (opening the thread). Scoped to the
---reader's own inbox, so it can't clear a peer's receipts.
---@param username string reading account handle
---@param peer string conversation partner
function store.markDmRead(username, peer)
    MySQL.update.await(
        'UPDATE phone_photogram_dms SET read_flag = 1 WHERE to_user = ? AND from_user = ? AND read_flag = 0',
        { username, peer }
    )
end

---Unread count from one peer (conversation-list badge). Read-only.
---@param username string account handle
---@param peer string conversation partner
---@return integer n
function store.dmUnreadFrom(username, peer)
    local row = MySQL.single.await(
        'SELECT COUNT(*) AS n FROM phone_photogram_dms WHERE to_user = ? AND from_user = ? AND read_flag = 0',
        { username, peer }
    )
    return row and tonumber(row.n) or 0
end

---Unread DM counts grouped by sender in ONE query - the batch form of dmUnreadFrom, so the DM
---inbox resolves every peer's unread badge in a single round-trip instead of one COUNT per peer.
---Rides the (to_user, read_flag) index. Returns a peer -> unread-count map (peers with zero unread
---are absent). Read-only.
---@param username string viewer handle
---@return table<string, integer> peer -> unread count
function store.dmUnreadByPeer(username)
    local rows = MySQL.query.await(
        'SELECT from_user, COUNT(*) AS n FROM phone_photogram_dms WHERE to_user = ? AND read_flag = 0 GROUP BY from_user',
        { username }) or {}
    local out = {}
    for i = 1, #rows do out[rows[i].from_user] = tonumber(rows[i].n) or 0 end
    return out
end

---Total unread DMs (DM-button badge). Read-only.
---@param username string account handle
---@return integer n
function store.dmUnreadTotal(username)
    local row = MySQL.single.await('SELECT COUNT(*) AS n FROM phone_photogram_dms WHERE to_user = ? AND read_flag = 0', { username })
    return row and tonumber(row.n) or 0
end

---Erase every trace of an account (Settings delete-account): the user's own rows plus other
---users' rows that hang off them (likes/comments/saves on their posts, likes on their comments,
---views of their stories), children before parents so no orphans survive. Comment likes are
---cleared for BOTH comment populations - comments under the user's posts and comments the user
---authored under anyone's posts - before either comment set is deleted. Notifications and
---follows go both ways (they were recipient or actor, follower or target), so everyone else's
---counts settle immediately. Ownership is the caller's job: actions.deleteAccount only ever
---passes the signed-in account's own username.
---@param username string account handle being wiped
function store.wipeUser(username)
    MySQL.update.await('DELETE FROM phone_photogram_comment_likes WHERE comment_id IN (SELECT id FROM phone_photogram_comments WHERE post_id IN (SELECT id FROM phone_photogram_posts WHERE author = ?))', { username })
    MySQL.update.await('DELETE FROM phone_photogram_comment_likes WHERE comment_id IN (SELECT id FROM phone_photogram_comments WHERE author = ?)', { username })
    MySQL.update.await('DELETE FROM phone_photogram_comment_likes WHERE username = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_comments WHERE post_id IN (SELECT id FROM phone_photogram_posts WHERE author = ?)', { username })
    MySQL.update.await('DELETE FROM phone_photogram_comments WHERE author = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_likes WHERE post_id IN (SELECT id FROM phone_photogram_posts WHERE author = ?)', { username })
    MySQL.update.await('DELETE FROM phone_photogram_likes WHERE username = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_saves WHERE post_id IN (SELECT id FROM phone_photogram_posts WHERE author = ?)', { username })
    MySQL.update.await('DELETE FROM phone_photogram_saves WHERE username = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_notifications WHERE recipient = ? OR actor = ?', { username, username })
    MySQL.update.await('DELETE FROM phone_photogram_story_views WHERE story_id IN (SELECT id FROM phone_photogram_stories WHERE author = ?)', { username })
    MySQL.update.await('DELETE FROM phone_photogram_story_views WHERE username = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_stories WHERE author = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_dms WHERE from_user = ? OR to_user = ?', { username, username })
    MySQL.update.await('DELETE FROM phone_photogram_follows WHERE follower = ? OR target = ?', { username, username })
    MySQL.update.await('DELETE FROM phone_photogram_posts WHERE author = ?', { username })
    MySQL.update.await('DELETE FROM phone_photogram_profiles WHERE username = ?', { username })
end

return store
