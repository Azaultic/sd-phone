---@type table sd-phone config root (configs/config.lua): Birdy bounds + the mail domain for email sign-in.
local config = require 'configs.config'
---@type table Player bridge (bridge.server.player): citizenid lookups + cid -> online source resolution.
local player = require 'bridge.server.player'
---@type table Birdy persistence layer (server.birdy.store): profile/post/like/follow/DM/notification CRUD.
local store = require 'server.birdy.store'
---@type table Accounts engine store (server.accounts.store): global credential rows + per-app sessions.
local acctStore = require 'server.accounts.store'
---@type table Accounts engine actions (server.accounts.actions): createAccount + verifyPassword.
local acctActions = require 'server.accounts.actions'
---@type table Settings persistence (server.settings.store): citizenid -> phone number for money DMs.
local settings = require 'server.settings.store'
---@type table Banking actions (server.banking.actions): authoritative money transfer for money DMs.
local banking = require 'server.banking.actions'

---@type table Birdy config (config.Birdy): field bounds + feed/notification limits.
local birdyCfg = config.Birdy

---@type table Actions module; the table returned at end of file.
local actions = {}

local util = require 'server.util'
local ok, fail = util.ok, util.fail


---Trim surrounding whitespace. Returns nil for non-strings, so every free-text payload field
---funnels through one type check before use.
---@param s any
---@return string|nil
local function trimmed(s)
    if type(s) ~= 'string' then return nil end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

---Coerce an untrusted callback payload into a table. Payloads are attacker-controlled and can be
---nil or any scalar; indexing a number/boolean raises, so every payload-taking handler routes
---through this one guard before reading fields. Scalars collapse to {} - handlers already treat
---absent fields as "not provided".
---@param payload any
---@return table
local function tbl(payload)
    return type(payload) == 'table' and payload or {}
end

---Normalise a user-supplied username into a handle: lowercase, keeping only letters, digits and
---underscores. The result is the only shape ever used in handle lookups, so hostile input never
---reaches a query un-normalised.
---@param raw any
---@return string|nil
local function normalizeHandle(raw)
    if type(raw) ~= 'string' then return nil end
    return (raw:lower():gsub('[^a-z0-9_]', ''))
end

---Clean a client-supplied image list into at most 3 valid URL strings, or nil. Entries are
---whitelisted by shape only (non-empty string, capped at 512 chars so the stored JSON stays
---bounded); anything else is dropped rather than rejecting the whole post.
---@param raw any
---@return string[]|nil
local function sanitizeImages(raw)
    if type(raw) ~= 'table' then return nil end
    local out = {}
    for i = 1, #raw do
        local u = raw[i]
        if type(u) == 'string' then
            u = (u:gsub('^%s+', ''):gsub('%s+$', ''))
            if #u > 0 and #u <= 512 then
                out[#out + 1] = u
                if #out >= 3 then break end
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

---Compact relative label ("now", "5m", "2h", "3d", "2w") for a ms timestamp.
---@param ms number
---@return string
local function relativeLabel(ms)
    local secs = math.max(0, os.time() - math.floor(ms / 1000))
    if secs < 60 then return 'now' end
    local mins = math.floor(secs / 60)
    if mins < 60 then return mins .. 'm' end
    local hours = math.floor(mins / 60)
    if hours < 24 then return hours .. 'h' end
    local days = math.floor(hours / 24)
    if days < 7 then return days .. 'd' end
    return math.floor(days / 7) .. 'w'
end

---HH:MM clock label for a ms timestamp.
---@param ms number
---@return string
local function timeLabel(ms)
    return os.date('%H:%M', math.floor(ms / 1000))
end

---Resolve the requesting player's signed-in Birdy profile through the shared accounts engine
---session (source -> citizenid -> session account -> profile by handle), so any character who
---logs into an account acts as that persona. The actor is ALWAYS derived from `source`; nothing
---identity-shaped is ever read from a payload. Returns nil when signed out - every write action
---bails in that case.
---@param source number player server id
---@return table|nil profile
local function viewer(source)
    local cid = player.getIdentifier(source)
    if not cid then return nil end
    local acc = acctStore.getSessionAccount('birdy', cid)
    if not acc then return nil end
    return store.getProfileByHandle(acc.username)
end

---Resolve a viewer citizenid for the PUBLIC read actions (feed, post). Returns the signed-in
---account's cid, or '' for a guest. The post projection only uses this for the per-row `liked`
---flag, so '' simply yields liked=false - letting account-less players browse without unlocking
---any write/personal action.
---@param source number player server id
---@return string viewerCid '' = anonymous guest
local function optionalViewerCid(source)
    local prof = viewer(source)
    return prof and prof.citizenid or ''
end

---Public author shape embedded in posts, notifications and conversation heads. Deliberately
---citizenid-free - handles are the public identity.
---@param profile table
---@return { name: string, handle: string, verified: boolean }
local function serializeAuthor(profile)
    return { name = profile.displayName, handle = profile.handle, verified = profile.verified }
end

---Shape a full profile (with live follow counts) for the profile page. Counts are read fresh
---from the follows table on every call, so the header can never drift from the stored edges.
---@param profile table
---@return table
local function serializeProfile(profile)
    return {
        name      = profile.displayName,
        handle    = profile.handle,
        verified  = profile.verified,
        bio       = profile.bio or '',
        joined    = profile.joinLabel or '',
        protected = profile.protected == true,
        following = store.countFollowing(profile.citizenid),
        followers = store.countFollowers(profile.citizenid),
    }
end

---Shape a hydrated post row into the React `BirdyPost` form. `images` is nil (omitted on the
---wire) or the store-decoded array of up to 3 URLs. Reposts aren't implemented, so the count is
---pinned at 0.
---@param p table
---@return table
local function serializePost(p)
    return {
        id        = p.id,
        author    = { name = p.displayName, handle = p.handle, verified = p.verified },
        body      = p.body,
        images    = p.images,
        createdAt = p.createdMs,
        replies   = p.replies,
        reposts   = 0,
        likes     = p.likes,
        liked     = p.liked,
        views     = p.views,
    }
end

---Auth state for the requesting player: whether they're signed in, and their public profile
---when they are. Read-only.
---@param source number player server id
---@return table envelope
function actions.me(source)
    local prof = viewer(source)
    if not prof then return ok({ loggedIn = false }) end
    return ok({ loggedIn = true, me = serializeAuthor(prof) })
end

---Register a new Birdy account and sign the character in. The engine owns credentials + recovery
---contacts (email/phone are validated there: the email must belong to a real Mail-app account,
---the phone must look plausible); the profile row stays Birdy's content anchor, keyed by the
---CREATING character's citizenid. One profile per character. Handle uniqueness is checked
---against both stores, and a failed profile insert compensates by deleting the just-created
---engine account so the two stores can't drift. Every field is trimmed and bounds-checked
---against config.Birdy before insert; all caps sit inside the DB column widths.
---@param source number player server id
---@param payload { name?: string, username?: string, password?: string, bio?: string, email?: string, phone?: string }
---@return table envelope
function actions.register(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    payload = tbl(payload)

    local name = trimmed(payload.name)
    if not name or #name < 1 then return fail('Name is required') end
    if #name > birdyCfg.MaxNameLength then return fail('Name is too long') end

    local handle = normalizeHandle(payload.username)
    if not handle or #handle < birdyCfg.MinHandleLength then
        return fail(('Username needs at least %d letters, numbers or _'):format(birdyCfg.MinHandleLength))
    end
    if #handle > birdyCfg.MaxHandleLength then
        return fail(('Username must be %d characters or fewer'):format(birdyCfg.MaxHandleLength))
    end

    local password = payload.password
    if type(password) ~= 'string' or #password < birdyCfg.MinPasswordLength then
        return fail(('Password must be at least %d characters'):format(birdyCfg.MinPasswordLength))
    end
    if #password > birdyCfg.MaxPasswordLength then return fail('Password is too long') end

    local bio = trimmed(payload.bio) or ''
    if #bio > birdyCfg.MaxBioLength then return fail('Bio is too long') end

    if not trimmed(payload.email) or trimmed(payload.email) == '' then
        return fail('Email is required so you can recover the account')
    end

    if store.getProfileByHandle(handle) or acctStore.getAccount('birdy', handle) then
        return fail('That username is taken')
    end
    if store.getProfile(cid) then
        return fail('This character already created a Birdy account. Log into it instead')
    end

    local acctRes = acctActions.createAccount('birdy', {
        username = handle, password = password, name = name,
        email = payload.email, phone = payload.phone,
    })
    if not acctRes.success then return acctRes end

    if not store.insertAccount(cid, handle, name, store.hashPassword(password), bio, birdyCfg.DefaultVerified == true, os.date('%B %Y')) then
        acctStore.deleteAccount(acctRes.data.account.id)
        return fail('Failed to create the account')
    end
    acctStore.setSession('birdy', cid, acctRes.data.account.id)
    store.setLoggedIn(cid, true)

    return ok({ me = serializeAuthor(store.getProfile(cid)) })
end

---Sign in to any existing Birdy account by handle + password. Accounts are global: knowing the
---credentials is enough, whichever character made it. Accepts the handle or the linked email -
---emails go through the contact lookup BEFORE handle normalization would strip their @ and dots,
---and a bare handle that matches no account also retries as handle@<mail domain>. Password
---verification lives in the engine and is type-safe (non-strings verify false), so a crafted
---payload can't error its way past the check.
---@param source number player server id
---@param payload { username?: string, password?: string }
---@return table envelope
function actions.login(source, payload)
    local cid = player.getIdentifier(source)
    if not cid then return fail('Player not found') end
    payload = tbl(payload)

    local raw = trimmed(payload.username) or ''
    local acc
    if raw:find('@', 1, true) then
        local matches = acctStore.findAccountsByContact('birdy', raw:lower(), nil)
        if #matches == 1 then acc = matches[1] end
    else
        local handle = normalizeHandle(raw)
        if handle and handle ~= '' then
            acc = acctStore.getAccount('birdy', handle)
            if not acc then
                local matches = acctStore.findAccountsByContact('birdy', handle .. '@' .. config.Mail.Domain, nil)
                if #matches == 1 then acc = matches[1] end
            end
        end
    end
    if not acc or not acctActions.verifyPassword(acc, payload.password) then
        return fail('Wrong username or password')
    end
    local prof = store.getProfileByHandle(acc.username)
    if not prof then return fail('That account has no Birdy profile') end

    acctStore.setSession('birdy', cid, acc.id)
    store.setLoggedIn(prof.citizenid, true)
    return ok({ me = serializeAuthor(prof) })
end

---Sign out - keeps the account, just drops this character's engine session. The logged_in column
---touched here is informational only; authorization always re-derives from the engine session,
---so this can't lock anyone in or out. Idempotent.
---@param source number player server id
---@return table envelope
function actions.logout(source)
    local cid = player.getIdentifier(source)
    if cid then
        acctStore.clearSession('birdy', cid)
        store.setLoggedIn(cid, false)
    end
    return ok()
end

---A profile page: another account's when payload.handle is given (normalized before lookup),
---otherwise the signed-in viewer's own. isFollowing is only computed for a signed-in viewer
---looking at someone else; guests with no handle get 'Profile not found'. Read-only.
---@param source number player server id
---@param payload { handle?: string }|nil
---@return table envelope
function actions.profile(source, payload)
    payload = tbl(payload)
    local viewerCid = optionalViewerCid(source)
    local handle = payload and payload.handle and normalizeHandle(payload.handle)
    local prof
    if handle and handle ~= '' then
        prof = store.getProfileByHandle(handle)
    elseif viewerCid ~= '' then
        prof = store.getProfile(viewerCid)
    end
    if not prof then return fail('Profile not found') end

    local data = serializeProfile(prof)
    local isMe = viewerCid ~= '' and prof.citizenid == viewerCid
    data.isMe = isMe
    data.isFollowing = ((not isMe) and viewerCid ~= '' and store.isFollowing(viewerCid, prof.citizenid)) or false
    return ok({ profile = data })
end

---Posts for a profile tab: 'posts', 'replies', 'media', or 'likes'. targetCid = whose posts,
---viewerCid = whose like-state colours the hearts. 'likes' reads the like join; the other three
---are author-scoped filters the store picks from server-side literals, so an arbitrary `kind`
---string just falls back to 'posts'. Read-only.
---@param source number player server id
---@param payload { kind?: string, handle?: string }|nil
---@return table envelope
function actions.profilePosts(source, payload)
    payload = tbl(payload)
    local viewerCid = optionalViewerCid(source)
    local handle = payload and payload.handle and normalizeHandle(payload.handle)
    local targetCid
    if handle and handle ~= '' then
        local tp = store.getProfileByHandle(handle)
        targetCid = tp and tp.citizenid
    elseif viewerCid ~= '' then
        targetCid = viewerCid
    end
    if not targetCid then return fail('Profile not found') end
    local kind = (payload and payload.kind) or 'posts'

    local rows
    if kind == 'likes' then
        rows = store.listLikedBy(targetCid, viewerCid, birdyCfg.FeedLimit)
    else
        rows = store.listPostsBy(targetCid, kind, viewerCid, birdyCfg.FeedLimit)
    end

    local posts = {}
    for i = 1, #rows do posts[i] = serializePost(rows[i]) end
    return ok({ posts = posts })
end

---Search accounts by handle/display name substring for the Search tab. The query reaches the
---store only as a parameterized LIKE value, capped at 64 chars so a crafted megabyte string
---can't become an expensive scan needle; % and _ act as user wildcards, which is harmless here.
---Read-only.
---@param source number player server id
---@param payload { query?: string }|nil
---@return table envelope
function actions.search(source, payload)
    payload = tbl(payload)
    local viewerCid = optionalViewerCid(source)
    local q = trimmed(payload and payload.query)
    if not q or #q == 0 then return ok({ users = {} }) end
    local rows = store.searchProfiles(q:sub(1, 64), viewerCid, 20)
    local users = {}
    for i = 1, #rows do
        users[i] = { name = rows[i].displayName, handle = rows[i].handle, verified = rows[i].verified }
    end
    return ok({ users = users })
end

---Update the signed-in user's editable profile fields. Missing fields keep their current value;
---everything is trimmed and bounds-checked against config.Birdy / the DB column widths, and the
---write is scoped to the session profile's own citizenid - no payload can point it elsewhere.
---@param source number player server id
---@param payload { name?: string, bio?: string, joinLabel?: string, protected?: boolean }|nil
---@return table envelope
function actions.updateProfile(source, payload)
    local prof = viewer(source); if not prof then return fail('Not signed in') end
    payload = tbl(payload)

    local name = trimmed(payload.name) or prof.displayName
    if #name < 1 then return fail('Name is required') end
    if #name > birdyCfg.MaxNameLength then return fail('Name is too long') end

    local bio = trimmed(payload.bio) or ''
    if #bio > birdyCfg.MaxBioLength then return fail('Bio is too long') end

    local joinLabel = (trimmed(payload.joinLabel) or prof.joinLabel or ''):sub(1, 32)

    store.updateProfileFields(prof.citizenid, name, bio, joinLabel, payload.protected == true)
    return ok({ profile = serializeProfile(store.getProfile(prof.citizenid)) })
end

---Change the signed-in user's password. The engine hash is authoritative; the Passwords-app
---vault copy and Birdy's legacy profile-row hash are synced in the same step so no verifier can
---diverge. The account comes from the caller's session - payloads carry only the new secret.
---@param source number player server id
---@param payload { password?: string }|nil
---@return table envelope
function actions.changePassword(source, payload)
    local cid = player.getIdentifier(source)
    local acc = cid and acctStore.getSessionAccount('birdy', cid) or nil
    if not acc then return fail('Not signed in') end
    payload = tbl(payload)
    local password = payload and payload.password
    if type(password) ~= 'string' or #password < birdyCfg.MinPasswordLength then
        return fail(('Password must be at least %d characters'):format(birdyCfg.MinPasswordLength))
    end
    if #password > birdyCfg.MaxPasswordLength then return fail('Password is too long') end
    acctStore.setPassword(acc.id, acctStore.hashPassword(password))
    acctStore.syncVaultPassword('birdy', acc.username, password)
    local prof = store.getProfileByHandle(acc.username)
    if prof then store.setPassword(prof.citizenid, store.hashPassword(password)) end
    return ok()
end

---Permanently delete the signed-in user's account and all of its content. Account-level
---authority: any character signed into the account may delete it, same as changing its password.
---Content rows (keyed by the creating character's citizenid) go first, then the engine account -
---a partial failure leaves live credentials rather than orphaned content.
---@param source number player server id
---@return table envelope
function actions.deleteAccount(source)
    local cid = player.getIdentifier(source)
    local acc = cid and acctStore.getSessionAccount('birdy', cid) or nil
    if not acc then return fail('Not signed in') end
    local prof = store.getProfileByHandle(acc.username)
    if prof then store.deleteAccount(prof.citizenid) end
    acctStore.deleteAccount(acc.id)
    return ok()
end

---Top-level feed, newest first. The "Following" filter needs a signed-in viewer; guests always
---get the public "all" feed (their '' viewer cid only means every liked flag reads false).
---Read-only.
---@param source number player server id
---@param payload { following?: boolean }|nil
---@return table envelope
function actions.feed(source, payload)
    payload = tbl(payload)
    local viewerCid = optionalViewerCid(source)
    local following = viewerCid ~= '' and payload and payload.following == true
    local rows = store.listFeed(viewerCid, birdyCfg.FeedLimit, following)
    local posts = {}
    for i = 1, #rows do posts[i] = serializePost(rows[i]) end
    return ok({ posts = posts })
end

---A single post with its reply thread. The view counter bumps for non-authors (guests included)
---before the read, so the count the author sees already includes this fetch; the id is only ever
---used as a parameterized lookup key. Read-only apart from that counter.
---@param source number player server id
---@param payload { id?: string }|nil
---@return table envelope
function actions.post(source, payload)
    payload = tbl(payload)
    local viewerCid = optionalViewerCid(source)
    local id = payload and payload.id
    if type(id) ~= 'string' or id == '' then return fail('Post id required') end

    store.bumpViews(id, viewerCid)
    local row = store.getPost(id, viewerCid)
    if not row then return fail('Post not found') end

    local post = serializePost(row)
    local replyRows = store.listReplies(id, viewerCid)
    local thread = {}
    for i = 1, #replyRows do thread[i] = serializePost(replyRows[i]) end
    post.thread = thread

    return ok({ post = post })
end

---Create a top-level post as the session profile. A post needs text OR at least one image; the
---body is trimmed and capped at config.Birdy.MaxPostLength (mirroring the composer), images are
---whitelisted by sanitizeImages, and the row id is server-generated - clients never supply ids.
---@param source number player server id
---@param payload { body?: string, images?: string[] }|nil
---@return table envelope
function actions.create(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local body = trimmed(payload and payload.body) or ''
    local images = sanitizeImages(payload and payload.images)
    if body == '' and not images then return fail('Post cannot be empty') end
    if #body > birdyCfg.MaxPostLength then return fail('Post is too long') end

    local id = store.newId()
    if not store.insertPost(id, prof.citizenid, body, nil, images) then return fail('Failed to post') end

    -- First-party hook: one server-local event per created post; the payload carries a citizenid.
    TriggerEvent('sd-phone:server:birdy:post', {
        id = id, source = source, citizenid = prof.citizenid,
        username = prof.handle, displayName = prof.displayName,
        body = body, images = images,
    })
    return ok({ post = serializePost(store.getPost(id, prof.citizenid)) })
end

---Reply to a post. The parent must exist (checked before insert, which also bounds the stored
---parent id to a real row key). Returns the new reply plus the recipient citizenid so init can
---push a notification to the parent's author when online - never for self-replies.
---@param source number player server id
---@param payload { parentId?: string, body?: string }|nil
---@return table envelope
function actions.reply(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local parentId = payload and payload.parentId
    local body = trimmed(payload and payload.body)
    if type(parentId) ~= 'string' or parentId == '' then return fail('Missing post') end
    if not body or body == '' then return fail('Reply cannot be empty') end
    if #body > birdyCfg.MaxPostLength then return fail('Reply is too long') end

    local parentAuthor = store.getPostAuthor(parentId)
    if not parentAuthor then return fail('Post not found') end

    local id = store.newId()
    if not store.insertPost(id, prof.citizenid, body, parentId, nil) then return fail('Failed to reply') end

    local notifyCid = nil
    if parentAuthor ~= prof.citizenid then
        store.insertNotification(store.newId(), parentAuthor, 'reply', prof.citizenid, id)
        notifyCid = parentAuthor
    end

    return ok({ post = serializePost(store.getPost(id, prof.citizenid)), notifyCid = notifyCid })
end

---Toggle the viewer's like on a post. The like row is keyed (post, viewer), so a replayed toggle
---simply flips the state back rather than double-counting. Returns the new liked state plus the
---author citizenid to notify when a like was just added (not on unlike, never for self-likes).
---@param source number player server id
---@param payload { id?: string }|nil
---@return table envelope
function actions.toggleLike(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local id = payload and payload.id
    if type(id) ~= 'string' or id == '' then return fail('Missing post') end

    local author = store.getPostAuthor(id)
    if not author then return fail('Post not found') end

    local nowLiked
    if store.isLiked(id, prof.citizenid) then
        store.removeLike(id, prof.citizenid)
        nowLiked = false
    else
        store.addLike(id, prof.citizenid)
        nowLiked = true
    end

    local notifyCid = nil
    if nowLiked and author ~= prof.citizenid then
        store.insertNotification(store.newId(), author, 'like', prof.citizenid, id)
        notifyCid = author
    end

    return ok({ liked = nowLiked, notifyCid = notifyCid })
end

---Toggle following another account, addressed by handle (preferred) or citizenid. The target is
---only ever the ACTION TARGET - the follower is always the session profile - and it is type +
---length checked against the DB column before any row is written. Self-follows are rejected.
---Returns the target to notify on a new follow (not on unfollow).
---@param source number player server id
---@param payload { handle?: string, targetCid?: string }|nil
---@return table envelope
function actions.toggleFollow(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local handle = payload and payload.handle and normalizeHandle(payload.handle)
    local target = payload and payload.targetCid
    if handle and handle ~= '' then
        local tp = store.getProfileByHandle(handle)
        target = tp and tp.citizenid
    end
    if type(target) ~= 'string' or target == '' or #target > 64 then return fail('Missing account') end
    if target == prof.citizenid then return fail('You cannot follow yourself') end

    local notifyCid = nil
    local nowFollowing
    if store.isFollowing(prof.citizenid, target) then
        store.removeFollow(prof.citizenid, target)
        nowFollowing = false
    else
        store.addFollow(prof.citizenid, target)
        nowFollowing = true
        store.insertNotification(store.newId(), target, 'follow', prof.citizenid, nil)
        notifyCid = target
    end

    return ok({ following = nowFollowing, notifyCid = notifyCid })
end

---List the viewer's notifications, serialized into the React union shape. Reply notifications
---embed the reply post itself; like/follow rows resolve the actor's public profile, falling back
---to a placeholder when the actor deleted their account. Recipient-scoped by the session
---profile, so nobody can read another inbox. Read-only.
---@param source number player server id
---@return table envelope
function actions.notifications(source)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    local rows = store.listNotifications(prof.citizenid, birdyCfg.NotificationLimit)

    local actorCids = {}
    for i = 1, #rows do actorCids[#actorCids + 1] = rows[i].actor_cid end
    local profiles = store.getProfilesByCids(actorCids)

    local replyPostIds = {}
    for i = 1, #rows do
        if rows[i].kind == 'reply' and rows[i].post_id then replyPostIds[#replyPostIds + 1] = rows[i].post_id end
    end
    local replyPosts = store.postsByIds(replyPostIds, prof.citizenid)

    local items = {}
    for i = 1, #rows do
        local r = rows[i]
        if r.kind == 'reply' and r.post_id then
            local postRow = replyPosts[r.post_id]
            if postRow then
                items[#items + 1] = { id = r.id, kind = 'reply', post = serializePost(postRow) }
            end
        else
            local ap = profiles[r.actor_cid]
            local user = ap and serializeAuthor(ap) or { name = 'Someone', handle = 'someone', verified = false }
            if r.kind == 'like' then
                items[#items + 1] = { id = r.id, kind = 'like', user = user, text = 'liked your post' }
            elseif r.kind == 'follow' then
                items[#items + 1] = { id = r.id, kind = 'follow', user = user }
            end
        end
    end

    return ok({ notifications = items })
end

-- Rich DM messages (text / image / gif / money / location / voice). Mirrors the Messages +
-- Cherry message vocabulary so the same bubbles render on both ends.
---@type table<string, boolean> Whitelist of DM kinds a client may send; anything else sends as text.
local VALID_DM_KINDS = { text = true, image = true, gif = true, money = true, location = true, voice = true }

---Clamp/coerce composer metadata at the trust boundary, per kind. Only whitelisted fields
---survive, every string is length-capped and every number floored + clamped, so a crafted
---payload can't smuggle arbitrary keys into the stored meta JSON. Money amounts additionally
---reject non-finite doubles (NaN already collapses to 0 through math.max; +inf is zeroed
---explicitly) - a `requested` card skips banking validation entirely, so an Infinity amount
---would otherwise be stored and re-serialized to both phones.
---@param kind string validated DM kind (a VALID_DM_KINDS member)
---@param payload table raw client payload
---@return table meta whitelisted, clamped metadata
local function sanitizeDmMeta(kind, payload)
    local meta = {}
    if kind == 'image' or kind == 'gif' then
        local url = trimmed(payload.gifUrl) or ''
        if url ~= '' then meta.gifUrl = url:sub(1, 512) end
    elseif kind == 'money' then
        local amount = tonumber(payload.amount) or 0
        if amount == math.huge then amount = 0 end
        meta.amount = math.max(0, math.floor(amount))
        if payload.requested == true then meta.requested = true end
    elseif kind == 'voice' then
        meta.duration = math.max(0, math.min(36000, math.floor(tonumber(payload.duration) or 0)))
        local audio = trimmed(payload.audioUrl) or ''
        if audio ~= '' then meta.audio = audio:sub(1, 512) end
        if type(payload.waveform) == 'table' then
            local bars = {}
            for i = 1, math.min(#payload.waveform, 64) do
                bars[i] = math.max(0, math.min(100, math.floor(tonumber(payload.waveform[i]) or 0)))
            end
            if #bars > 0 then meta.waveform = bars end
        end
    elseif kind == 'location' then
        local code = trimmed(payload.wpCode) or ''
        local sub  = trimmed(payload.wpSub) or ''
        if code ~= '' then meta.wpCode = code:sub(1, 256) end
        if sub  ~= '' then meta.wpSub  = sub:sub(1, 128) end
    end
    return meta
end

---True when a message of `kind` actually carries content, so blank cards can't be spammed: text
---needs a body, media needs a URL, money a positive amount, voice a positive duration, location
---a body or a waypoint code.
---@param kind string
---@param body string
---@param meta table
---@return boolean
local function dmHasContent(kind, body, meta)
    if kind == 'text'                   then return body ~= '' end
    if kind == 'image' or kind == 'gif' then return meta.gifUrl ~= nil end
    if kind == 'money'                  then return (meta.amount or 0) > 0 end
    if kind == 'voice'                  then return (meta.duration or 0) > 0 end
    if kind == 'location'               then return body ~= '' or meta.wpCode ~= nil end
    return body ~= ''
end

---DB row -> the client DM message shape: `fromMe` from the viewer's perspective plus whichever
---rich fields the bubble renders. Reactions are re-shaped per viewer (emoji, count, whether the
---viewer reacted); the raw citizenid lists inside the stored reactions JSON never leave the
---server.
---@param row table
---@param viewerCid string
---@return table
local function serializeDm(row, viewerCid)
    local meta = store.decodeJson(row.meta)
    local msg = {
        id     = row.id,
        fromMe = row.from_cid == viewerCid,
        body   = row.body or '',
        kind   = row.kind or 'text',
        ts     = row.created_ms or 0,
        at     = timeLabel(row.created_ms or 0),
    }
    if meta.gifUrl    then msg.gifUrl    = meta.gifUrl end
    if meta.amount    then msg.amount    = meta.amount end
    if meta.requested then msg.requested = true end
    if meta.duration  then msg.duration  = meta.duration end
    if meta.audio     then msg.audioUrl  = meta.audio end
    if meta.waveform  then msg.waveform  = meta.waveform end
    if meta.wpCode    then msg.wpCode    = meta.wpCode end
    if meta.wpSub     then msg.wpSub     = meta.wpSub end

    local reactions = store.decodeJson(row.reactions)
    if next(reactions) ~= nil then
        local out = {}
        for emoji, users in pairs(reactions) do
            local mine = false
            for _, u in ipairs(users) do if u == viewerCid then mine = true break end end
            if #users > 0 then out[#out + 1] = { emoji = emoji, count = #users, mine = mine } end
        end
        if #out > 0 then msg.reactions = out end
    end
    return msg
end

---List the viewer's DM conversations (one row per other party, latest message as the preview),
---newest-first. The store query is pinned to the viewer's own citizenid, so nobody can list
---someone else's inbox. read_flag is a TINYINT(1) that oxmysql hands back as a Lua boolean (or
---1/'1' from older drivers) - the nested isRead accepts every truthy shape, mirroring the
---store's isTruthy. Unread counts only messages TO the viewer that they haven't opened.
---@param source number player server id
---@return table envelope
function actions.dmList(source)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    local msgs = store.listMessagesFor(prof.citizenid)

    local function isRead(v) return v == true or v == 1 or v == '1' end

    local lastByOther, unreadByOther = {}, {}
    for i = 1, #msgs do
        local m = msgs[i]
        local other = (m.from_cid == prof.citizenid) and m.to_cid or m.from_cid
        lastByOther[other] = m
        if m.to_cid == prof.citizenid and not isRead(m.read_flag) then
            unreadByOther[other] = (unreadByOther[other] or 0) + 1
        end
    end

    local others = {}
    for other in pairs(lastByOther) do others[#others + 1] = other end
    table.sort(others, function(a, b) return lastByOther[a].created_ms > lastByOther[b].created_ms end)

    local profiles = store.getProfilesByCids(others)
    local convos = {}
    for i = 1, #others do
        local other = others[i]
        local last  = lastByOther[other]
        local p     = profiles[other]
        convos[i] = {
            id       = other,
            user     = p and serializeAuthor(p) or { name = 'Unknown', handle = 'unknown', verified = false },
            updated  = relativeLabel(last.created_ms),
            unread   = unreadByOther[other] or 0,
            messages = { serializeDm(last, prof.citizenid) },
        }
    end

    return ok({ conversations = convos })
end

---Full message thread with one other party (conversation id = their cid). The store query keeps
---the viewer's own citizenid on one side of every row, so an arbitrary id can only ever select
---messages the viewer participates in. Opening the thread clears its unread flags.
---@param source number player server id
---@param payload { id?: string }|nil
---@return table envelope
function actions.dmThread(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local other = payload and payload.id
    if type(other) ~= 'string' or other == '' then return fail('Missing conversation') end

    local rows = store.listThread(prof.citizenid, other)
    local messages = {}
    for i = 1, #rows do messages[i] = serializeDm(rows[i], prof.citizenid) end

    store.markThreadRead(prof.citizenid, other)

    local op = store.getProfile(other)
    return ok({
        id       = other,
        user     = op and serializeAuthor(op) or { name = 'Unknown', handle = 'unknown', verified = false },
        messages = messages,
    })
end

---Mark a conversation read without fetching it (used when a message arrives in the thread the
---viewer is already looking at). Only messages TO the viewer flip, so it can't touch the other
---party's read state. Idempotent.
---@param source number player server id
---@param payload { id?: string }|nil
---@return table envelope
function actions.markRead(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local other = payload and payload.id
    if type(other) ~= 'string' or other == '' then return fail('Missing conversation') end
    store.markThreadRead(prof.citizenid, other)
    return ok()
end

---Send a DM of any kind. Returns the sender's own message + the recipient's copy (for the live
---push) + the routing data init needs to deliver it; init strips those internal fields before
---the envelope reaches the sender's NUI. `toCid` is the ACTION TARGET only (type + length
---checked against the DB column) - the sender is always the session profile. Money moves real
---funds (like Messages / Cherry): the transfer clears through banking.send, which re-validates
---amount, caps and balance server-side against the CALLER's account, BEFORE the row is stored,
---so a failed payment never leaves a phantom card. Requested money never moves funds here - the
---recipient pays through their own flow.
---@param source number player server id
---@param payload table { toCid, kind, body, gifUrl, amount, requested, duration, audioUrl, waveform, wpCode, wpSub }
---@return table envelope
function actions.dmSend(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local toCid = payload.toCid
    if type(toCid) ~= 'string' or toCid == '' or #toCid > 64 then return fail('Missing recipient') end

    local kind = VALID_DM_KINDS[payload.kind] and payload.kind or 'text'
    local body = (trimmed(payload.body) or ''):sub(1, birdyCfg.MaxDmLength)
    local meta = sanitizeDmMeta(kind, payload)
    if not dmHasContent(kind, body, meta) then return fail('Message cannot be empty') end

    if kind == 'money' and not meta.requested then
        local tsrc = player.getSourceByIdentifier(toCid)
        if not tsrc then return fail('They need to be online to receive money') end
        local number = settings.getPhoneNumber(toCid)
        if not number then return fail('Payment failed') end
        local res = banking.send(source, { number = number, amount = meta.amount, note = 'Birdy payment' })
        if not res or not res.success then return fail(res and res.message or 'Payment failed') end
    end

    local id = store.newId()
    if not store.insertDm(id, prof.citizenid, toCid, kind, body, meta) then return fail('Failed to send') end

    local row = store.getDm(id)
    return ok({
        message         = serializeDm(row, prof.citizenid),
        messageForOther = serializeDm(row, toCid),
        toCid           = toCid,
        fromCid         = prof.citizenid,
        fromProfile     = serializeAuthor(prof),
    })
end

---Toggle the viewer's reaction on a DM; both parties get the new set. Only a participant of the
---message may react - checked against the stored row, never the payload - and the emoji key is
---length-capped before it lands in the reactions JSON. Keyed per user, so a replayed toggle just
---flips back. For the recipient the conversation is keyed by the sender's cid, hence
---conversationId = the caller.
---@param source number player server id
---@param payload { id?: string, emoji?: string }|nil
---@return table envelope
function actions.dmReact(source, payload)
    local prof = viewer(source); if not prof then return fail('Player not found') end
    payload = tbl(payload)
    local row = type(payload.id) == 'string' and store.getDm(payload.id) or nil
    if not row then return fail('Message not found') end
    if row.from_cid ~= prof.citizenid and row.to_cid ~= prof.citizenid then return fail('Message not found') end

    local emoji = tostring(payload.emoji or '')
    if emoji == '' or #emoji > 16 then return fail('Invalid reaction') end

    local reactions = store.decodeJson(row.reactions)
    local users = reactions[emoji] or {}
    local found
    for i, u in ipairs(users) do if u == prof.citizenid then found = i break end end
    if found then table.remove(users, found) else users[#users + 1] = prof.citizenid end
    if #users > 0 then reactions[emoji] = users else reactions[emoji] = nil end
    store.updateDmReactions(row.id, reactions)

    local fresh = store.getDm(row.id)
    local other = (row.from_cid == prof.citizenid) and row.to_cid or row.from_cid
    return ok({
        id             = row.id,
        reactions      = serializeDm(fresh, prof.citizenid).reactions or {},
        otherCid       = other,
        otherReactions = serializeDm(fresh, other).reactions or {},
        conversationId = prof.citizenid,
    })
end

return actions
