---@type table Player bridge (bridge.server.player): citizenid/source lookups.
local player    = require 'bridge.server.player'
---@type table App-accounts engine store (server.accounts.store): account rows + per-character app sessions.
local acctStore = require 'server.accounts.store'
---@type table Badges module (server.badges.init): server-authoritative unread-badge pushes.
local badges    = require 'server.badges.init'
---@type table Photogram persistence layer (server.photogram.store): profile/post/comment/follow/story/DM CRUD.
local store     = require 'server.photogram.store'
---@type table Photogram Live module (server.photogram.live): in-memory livestream sessions merged into the stories tray.
local live      = require 'server.photogram.live'

---@type table Actions module; the table returned at end of file.
local actions = {}

---@type integer Story lifetime in seconds (24h) - older stories are pruned and never served.
local STORY_TTL    = 86400
---@type table<string, boolean> Whitelisted DM kinds; anything else coerces to 'text'.
local VALID_DMKIND = { text = true, image = true, gif = true, voice = true, post = true }

local util = require 'server.util'
local ok, fail, trim, flag = util.ok, util.fail, util.trim, util.truthy




---The photogram account the calling player is signed into, resolved from `src` alone: citizenid
---via the player bridge, then the accounts engine's session row (the engine owns auth). Identity
---is NEVER read from the payload - everything keys off this account's username (the handle).
---nil when the character isn't signed in; every handler turns that into 'Not signed in'.
---@param src integer player server id
---@return table|nil account accounts-engine row (username, displayName, ...)
local function viewerAccount(src)
    local cid = player.getIdentifier(src)
    if not cid then return nil end
    return acctStore.getSessionAccount('photogram', cid)
end

---Load (or bootstrap) the viewer's profile row. A fresh account gets a starter profile seeded
---from its display name so it's immediately discoverable; an existing row is returned untouched
---(idempotent).
---@param acc table accounts-engine account row
---@return table profile phone_photogram_profiles row
local function ensureProfile(acc)
    local row = store.getProfile(acc.username)
    if row then return row end
    store.upsertProfile(acc.username, {
        displayName = (acc.displayName and acc.displayName ~= '') and acc.displayName or acc.username,
        bio = '', avatar = nil, isPrivate = false, verified = false, createdAt = os.time(),
    })
    return store.getProfile(acc.username)
end

---Online sources signed into `username`'s photogram account - the push targets for its
---notifications, DMs, and badge refreshes. An account can be signed in from several characters;
---offline ones simply resolve to no source.
---@param username string photogram handle
---@return integer[] sources
local function sourcesFor(username)
    local acc = acctStore.getAccount('photogram', username)
    if not acc then return {} end
    local out = {}
    for _, cid in ipairs(acctStore.sessionCitizens('photogram', acc.id)) do
        local src = player.getSourceByIdentifier(cid)
        if src then out[#out + 1] = src end
    end
    return out
end

---Fan a content change out to every phone. The photogram app applies it live when open; phones
---without it open have no listener mounted, so it's a no-op for them. Keeps every viewer of a
---post / feed in sync (new comments, like & comment counts, new posts, deletions).
---@param event string client event suffix
---@param data table event payload
local function broadcast(event, data)
    TriggerClientEvent('sd-phone:client:photogram:' .. event, -1, data)
end

---Fan a post-scoped change out with privacy intact. A public author's changes broadcast to every
---phone (any of them may have the post rendered in feed/explore); a PRIVATE author's go only to
---the author's + accepted followers' phones. Broadcast payloads are observable by any modded
---client, so a private account's post ids and comment content must never ride a -1 event.
---@param author string post author's handle
---@param event string client event suffix
---@param data table event payload
local function broadcastPost(author, event, data)
    local row = store.getProfile(author)
    if not row or not flag(row.is_private) then return broadcast(event, data) end
    local names = store.followerUsernames(author)
    names[#names + 1] = author
    for _, u in ipairs(names) do
        for _, dst in ipairs(sourcesFor(u)) do
            TriggerClientEvent('sd-phone:client:photogram:' .. event, dst, data)
        end
    end
end

---Push a follow-status change to just the FOLLOWER's phone(s) so their open profile view /
---follow lists update live when the owner accepts (-> Following) or declines (-> Follow) their
---request - no leaving and re-opening the page.
---@param follower string requesting handle
---@param target string owner handle
---@param status string new follow status ('accepted'/'none')
local function pushFollowStatus(follower, target, status)
    for _, dst in ipairs(sourcesFor(follower)) do
        TriggerClientEvent('sd-phone:client:photogram:followChanged', dst, { target = target, status = status })
    end
end

---UI user card from any row carrying profile columns (author/username, avatar, verified,
---display_name) - the shape web/src/apps/photogram/data.ts renders.
---@param row table row with profile fields
---@return table card
local function userCard(row)
    return {
        id       = row.author or row.username,
        handle   = row.author or row.username,
        avatar   = row.avatar or '',
        verified = flag(row.verified),
        name     = row.display_name or '',
    }
end

---POST_SELECT row -> the React Post shape. Unix-second timestamps become millis; liked/saved
---arrive as per-viewer COUNT columns the store query bound up front.
---@param row table post row
---@return table post
local function serializePost(row)
    local location = row.location
    if location == '' then location = nil end
    return {
        id        = row.id,
        user      = userCard(row),
        location  = location,
        images    = store.decodeJson(row.images),
        caption   = row.caption or '',
        likes     = tonumber(row.like_count) or 0,
        liked     = (tonumber(row.liked) or 0) > 0,
        saved     = (tonumber(row.saved) or 0) > 0,
        comments  = tonumber(row.comment_count) or 0,
        createdAt = (tonumber(row.created_at) or 0) * 1000,
    }
end

---Comment row -> the React Comment shape (per-viewer liked flag included by the store query).
---@param row table comment row
---@return table comment
local function serializeComment(row)
    return {
        id        = row.id,
        user      = userCard(row),
        text      = row.body,
        gifUrl    = row.gif_url,
        likes     = tonumber(row.like_count) or 0,
        liked     = (tonumber(row.liked) or 0) > 0,
        createdAt = (tonumber(row.created_at) or 0) * 1000,
    }
end

---The Activity-row suffix per kind (the React side prepends the actor's handle). Kinds are
---server-written, so the empty-string fallback is only a forward-compat guard.
---@param kind string notification kind
---@param preview string|nil comment preview text
---@return string suffix
local function notifSuffix(kind, preview)
    if kind == 'like'           then return 'liked your photo.' end
    if kind == 'comment'        then return (preview and preview ~= '') and ('commented: "%s"'):format(preview) or 'commented with a GIF.' end
    if kind == 'mention'        then return 'mentioned you in a comment.' end
    if kind == 'follow'         then return 'started following you.' end
    if kind == 'follow_request' then return 'requested to follow you.' end
    if kind == 'follow_accept'  then return 'accepted your follow request.' end
    if kind == 'post'           then return 'shared a new post.' end
    if kind == 'unfollow'       then return 'unfollowed you.' end
    return ''
end

---Notification row -> the React Activity shape, with the actor's card inlined and a post
---thumbnail only when the row references a post.
---@param row table notification row (actor profile columns LEFT-JOINed)
---@return table notification
local function serializeNotif(row, thumbs)
    return {
        id        = row.id,
        kind      = row.kind,
        user      = {
            id       = row.actor,
            handle   = row.actor,
            avatar   = row.avatar or '',
            verified = flag(row.verified),
            name     = row.display_name or '',
        },
        text      = notifSuffix(row.kind, row.preview),
        thumb     = (row.post_id and row.post_id ~= '')
            and ((thumbs and thumbs[row.post_id]) or store.postThumb(row.post_id)) or nil,
        postId    = row.post_id,
        seen      = flag(row.seen),
        createdAt = (tonumber(row.created_at) or 0) * 1000,
    }
end

---A DM row's reactions JSON -> the React reaction chips: one entry per emoji with its count and
---whether the viewer reacted. nil (not an empty list) when there are none, so the client omits
---the chip row entirely.
---@param row table DM row
---@param viewer string viewer handle
---@return table|nil reactions
local function serializeReactions(row, viewer)
    local reactions = store.decodeJson(row.reactions)
    if next(reactions) == nil then return nil end
    local out = {}
    for emoji, users in pairs(reactions) do
        if #users > 0 then
            local mine = false
            for _, u in ipairs(users) do if u == viewer then mine = true break end end
            out[#out + 1] = { emoji = emoji, count = #users, mine = mine }
        end
    end
    return #out > 0 and out or nil
end

---DM row -> the React message shape from `viewer`'s perspective (mine = they sent it). Optional
---meta fields (gif, voice clip, shared post card, reply preview) only appear when set.
---@param row table DM row
---@param viewer string viewer handle
---@return table message
local function serializeDm(row, viewer)
    local meta = store.decodeJson(row.meta)
    local msg = {
        id   = row.id,
        mine = row.from_user == viewer,
        body = row.body or '',
        kind = row.kind or 'text',
        ts   = (tonumber(row.created_at) or 0) * 1000,
    }
    if meta.gifUrl   then msg.gifUrl   = meta.gifUrl end
    if meta.duration then msg.duration = meta.duration end
    if meta.audio    then msg.audioUrl = meta.audio end
    if meta.waveform then msg.waveform = meta.waveform end
    if meta.replyTo  then msg.replyTo  = meta.replyTo end
    if meta.post     then msg.post     = meta.post end
    msg.reactions = serializeReactions(row, viewer)
    return msg
end

---Banner preview per kind (full sentence, actor name prepended).
---@param actorName string display name or handle
---@param kind string notification kind
---@param preview string|nil comment preview
---@return string banner
local function notifBanner(actorName, kind, preview)
    return ('%s %s'):format(actorName, notifSuffix(kind, preview))
end

---Persist an Activity notification and, if the recipient is online, push a refresh ping, a
---banner (quiet while they're in the app), and a fresh badge. The banner's deeplink opens the
---app on the Notifications (Activity) tab, clearing any drill-in left over from last time
---(false = closed). Self-notifications and empty recipients are dropped, so acting on your own
---content stays silent.
---@param recipient string recipient handle
---@param kind string notification kind
---@param actor string acting handle
---@param postId string|nil related post id
---@param preview string|nil comment preview (already capped by the caller)
local function notify(recipient, kind, actor, postId, preview)
    if recipient == actor or recipient == '' then return end
    store.insertNotification(store.newId(), recipient, kind, actor, postId, preview, os.time())

    local sources = sourcesFor(recipient)
    if #sources == 0 then return end
    local actorRow  = store.getProfile(actor)
    local actorName = (actorRow and actorRow.display_name ~= '' and actorRow.display_name) or actor
    local thumb     = postId and store.postThumb(postId) or nil
    for _, src in ipairs(sources) do
        TriggerClientEvent('sd-phone:client:photogram:notification', src, {})
        TriggerClientEvent('sd-phone:client:notify', src, {
            app = 'photogram', appId = 'photogram', title = 'Photogram',
            body = notifBanner(actorName, kind, preview), image = thumb,
            time = 'now', quietInApp = true,
            link = {
                ['photogram:tab'] = 'activity',
                ['photogram:dmOpen'] = false, ['photogram:commentId'] = false,
                ['photogram:viewHandle'] = false, ['photogram:detail'] = false, ['photogram:follows'] = false,
            },
        })
        badges.push(src)
    end
end

---Refresh just the badge for a user's online sources (DM read, Activity opened).
---@param username string handle
local function bumpBadge(username)
    for _, src in ipairs(sourcesFor(username)) do badges.push(src) end
end

---Ping a recipient to refetch Activity (the requests list re-reads, the badge re-derives)
---WITHOUT adding a notification - used when a follow request is withdrawn so the pending entry
---disappears from their Follow Requests live.
---@param recipient string handle
local function pingActivity(recipient)
    for _, src in ipairs(sourcesFor(recipient)) do
        TriggerClientEvent('sd-phone:client:photogram:notification', src, {})
        badges.push(src)
    end
end

---Clamp a client-supplied list of post image URLs: http(s) scheme only (so no javascript:/data:
---URI ever reaches another player's NUI), at most 10 images, each capped at the 512-char column
---width.
---@param list any raw payload value
---@return string[] images
local function sanitizeImages(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, #list do
        local url = trim(list[i])
        if url:sub(1, 4) == 'http' then
            out[#out + 1] = url:sub(1, 512)
            if #out >= 10 then break end
        end
    end
    return out
end

---Whitelist + clamp DM metadata per kind, dropping anything the kind doesn't own. Media URLs
---must be http(s) and cap at 512 like every stored URL; voice durations clamp to 0..36000s and
---waveforms to <=64 bars of 0..100; a shared post card keeps only its id and capped display
---fields. The reply preview is display-only text capped to the composer's own limits.
---@param kind string whitelisted DM kind
---@param payload table raw client payload
---@return table meta sanitized metadata (may be empty)
local function sanitizeDmMeta(kind, payload)
    local meta = {}
    if kind == 'image' or kind == 'gif' then
        local url = trim(payload.gifUrl)
        if url:sub(1, 4) == 'http' then meta.gifUrl = url:sub(1, 512) end
    elseif kind == 'voice' then
        meta.duration = math.max(0, math.min(36000, math.floor(tonumber(payload.duration) or 0)))
        local audio = trim(payload.audioUrl)
        if audio:sub(1, 4) == 'http' then meta.audio = audio:sub(1, 512) end
        if type(payload.waveform) == 'table' then
            local bars = {}
            for i = 1, math.min(#payload.waveform, 64) do
                bars[i] = math.max(0, math.min(100, math.floor(tonumber(payload.waveform[i]) or 0)))
            end
            if #bars > 0 then meta.waveform = bars end
        end
    elseif kind == 'post' then
        local p = type(payload.post) == 'table' and payload.post or {}
        local pid   = trim(p.id)
        local image = trim(p.image)
        if pid ~= '' then
            local avatar = trim(p.avatar)
            meta.post = {
                id      = pid:sub(1, 16),
                image   = (image:sub(1, 4) == 'http') and image:sub(1, 512) or '',
                avatar  = (avatar:sub(1, 4) == 'http') and avatar:sub(1, 512) or '',
                author  = trim(p.author):sub(1, 64),
                caption = trim(p.caption):sub(1, 200),
            }
        end
    end
    if type(payload.replyTo) == 'table' then
        local name = trim(payload.replyTo.name):sub(1, 64)
        local body = trim(payload.replyTo.body):sub(1, 120)
        if name ~= '' then meta.replyTo = { name = name, body = body } end
    end
    return meta
end

---Whether a sanitized DM actually carries content for its kind, so sends whose media failed
---sanitation (or an empty text) are rejected rather than stored as blank rows.
---@param kind string whitelisted DM kind
---@param body string trimmed body
---@param meta table sanitized metadata
---@return boolean hasContent
local function hasDmContent(kind, body, meta)
    if kind == 'text'                   then return body ~= '' end
    if kind == 'image' or kind == 'gif' then return meta.gifUrl ~= nil end
    if kind == 'voice'                  then return (meta.duration or 0) > 0 end
    if kind == 'post'                   then return meta.post ~= nil end
    return body ~= ''
end

---@-mentions in a caption / comment that resolve to real photogram accounts, deduplicated and
---excluding the author. Every unique candidate costs a profile lookup, so lookups cap at 50 per
---text - a caption stuffed with hundreds of handles can't turn one callback into hundreds of
---sequential DB queries - and unresolvable candidates are remembered so repeats don't re-query.
---@param text string caption or comment body (already length-capped)
---@param exclude string author's own handle
---@return string[] handles
local function mentionsIn(text, exclude)
    local seen, out, checked = {}, {}, 0
    for handle in text:gmatch('@([%w_%.]+)') do
        local h = handle:lower()
        if not seen[h] and h ~= exclude then
            seen[h] = true
            checked = checked + 1
            if checked > 50 then break end
            if store.getProfile(h) then out[#out + 1] = h end
        end
    end
    return out
end

---Whether `viewer` may see `profileRow`'s content: always for themselves and public accounts,
---otherwise only with an accepted follow. The single privacy predicate every read gate uses.
---@param viewer string viewer handle
---@param profileRow table content owner's profile row
---@return boolean allowed
local function canView(viewer, profileRow)
    if viewer == profileRow.username then return true end
    if not flag(profileRow.is_private) then return true end
    return store.isAcceptedFollower(viewer, profileRow.username)
end

---Whether `viewer` may interact with content authored by `author` (like/save/comment/read a
---thread). Checked server-side in every interaction handler - not just by the UI hiding the
---buttons - so a leaked or guessed post id can't touch or read a private account's content.
---A missing author profile allows the action (the row is orphaned; there is nothing to protect).
---@param viewer string viewer handle
---@param author string content author's handle
---@return boolean allowed
local function canInteract(viewer, author)
    local row = store.getProfile(author)
    return not row or canView(viewer, row)
end

---Home feed: the viewer's own posts + accepted-following, newest first (limit 60). Bootstraps
---the profile on first open so a fresh account is immediately discoverable. Read-only.
---@param src integer player server id
---@return table result { posts }
function actions.feed(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    ensureProfile(acc)
    local out = {}
    for _, row in ipairs(store.feedPosts(acc.username, 60)) do out[#out + 1] = serializePost(row) end
    return ok({ posts = out })
end

---The discovery grid: recent posts from public accounts (or ones the viewer follows), never
---their own - privacy is enforced inside the store query. Read-only.
---@param src integer player server id
---@return table result { posts }
function actions.explore(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    ensureProfile(acc)
    local out = {}
    for _, row in ipairs(store.explorePosts(acc.username, 60)) do out[#out + 1] = serializePost(row) end
    return ok({ posts = out })
end

---A single post + its comment thread. Gated on the author's privacy so a leaked or guessed post
---id can't read a private account's content - the UI hiding locked grids isn't enough, the
---callback itself must refuse. Read-only.
---@param src integer player server id
---@param payload table { id: string }
---@return table result { post, comments }
function actions.post(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = store.getPost(acc.username, trim(payload.id))
    if not row then return fail('Post not found') end
    local author = store.getProfile(row.author)
    if author and not canView(acc.username, author) then return fail('This account is private') end
    local comments = {}
    for _, c in ipairs(store.commentsFor(row.id, acc.username, 200)) do comments[#comments + 1] = serializeComment(c) end
    return ok({ post = serializePost(row), comments = comments })
end

---Create a post from sanitized images (http-only, <=10) with the caption/location capped at
---their column widths. Fan-out: @-mentions in the caption get a 'mention' notification only when
---they may view the post (a private author's post id and thumbnail must never reach a
---non-follower's Activity feed or banner), every accepted follower gets a 'post' one (a mentioned
---follower gets only the mention, not both), and every phone gets a content-free feedChanged
---ping - private post data never rides the -1 broadcast, open feeds simply refetch what they're
---allowed to see.
---@param src integer player server id
---@param payload table { images: string[], caption?: string, location?: string }
---@return table result { post }
function actions.create(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local me = ensureProfile(acc)

    local images = sanitizeImages(payload.images)
    if #images == 0 then return fail('Add at least one photo') end
    local caption  = trim(payload.caption):sub(1, 2200)
    local location = trim(payload.location):sub(1, 120)
    if location == '' then location = nil end

    local id = store.newId()
    store.insertPost(id, acc.username, images, caption, location, os.time())

    local mentioned = {}
    for _, m in ipairs(mentionsIn(caption, acc.username)) do
        if canView(m, me) then
            mentioned[m] = true
            notify(m, 'mention', acc.username, id, nil)
        end
    end
    for _, f in ipairs(store.followerUsernames(acc.username)) do
        if not mentioned[f] then notify(f, 'post', acc.username, id, nil) end
    end
    broadcast('feedChanged', {})
    -- First-party hook: one server-local event per created post. A private author's content is
    -- follower-scoped, so this payload must never be forwarded to clients unfiltered.
    TriggerEvent('sd-phone:server:photogram:post', {
        id = id, source = src, citizenid = player.getIdentifier(src),
        username = acc.username, images = images, caption = caption,
        location = location, private = flag(me.is_private),
    })
    return ok({ post = serializePost(store.getPost(acc.username, id)) })
end

---Delete one of the viewer's own posts - ownership-checked against the signed-in handle so a
---forged id can't delete someone else's. The store cascades comments/likes/saves/notifications.
---postRemoved broadcasts id-only (no content) so any stale feed/detail view drops it.
---@param src integer player server id
---@param payload table { id: string }
---@return table result
function actions.deletePost(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = store.getPostRow(trim(payload.id))
    if not row then return fail('Post not found') end
    if row.author ~= acc.username then return fail('Not your post') end
    store.deletePost(row.id)
    broadcast('postRemoved', { postId = row.id })
    return ok()
end

---Toggle the viewer's like on a post. Interaction-gated for private authors (post ids leak
---through live pushes, so the gate can't live client-side). The like row is keyed (post, user)
---with INSERT IGNORE, so a replayed toggle flips cleanly and never double-counts. Only liking
---(not unliking) notifies the author; the fresh count returns to the caller and fans out
---privacy-scoped.
---@param src integer player server id
---@param payload table { id: string }
---@return table result { liked, likes }
function actions.toggleLike(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = store.getPostRow(trim(payload.id))
    if not row then return fail('Post not found') end
    if not canInteract(acc.username, row.author) then return fail('This account is private') end

    local nowLiked
    if store.isLiked(row.id, acc.username) then
        store.removeLike(row.id, acc.username)
        nowLiked = false
    else
        store.addLike(row.id, acc.username, os.time())
        nowLiked = true
        notify(row.author, 'like', acc.username, row.id, nil)
    end
    local fresh = store.getPost(acc.username, row.id)
    local likes = fresh and (tonumber(fresh.like_count) or 0) or 0
    broadcastPost(row.author, 'postChanged', { postId = row.id, likes = likes })
    return ok({ liked = nowLiked, likes = likes })
end

---Toggle a private bookmark on a post. Interaction-gated like every other post action - without
---it, saving a leaked private post id would smuggle the full post into the viewer's Saved grid.
---Saves are the viewer's own state, so nothing is broadcast or notified.
---@param src integer player server id
---@param payload table { id: string }
---@return table result { saved }
function actions.toggleSave(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = store.getPostRow(trim(payload.id))
    if not row then return fail('Post not found') end
    if not canInteract(acc.username, row.author) then return fail('This account is private') end

    local nowSaved
    if store.isSaved(row.id, acc.username) then
        store.removeSave(row.id, acc.username); nowSaved = false
    else
        store.addSave(row.id, acc.username, os.time()); nowSaved = true
    end
    return ok({ saved = nowSaved })
end

---The viewer's saved posts, newest-saved first. Save rows were privacy-gated when created
---(toggleSave); visibility is not re-checked at read time. Read-only.
---@param src integer player server id
---@return table result { posts }
function actions.saved(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local out = {}
    for _, row in ipairs(store.savedPosts(acc.username, 60)) do out[#out + 1] = serializePost(row) end
    return ok({ posts = out })
end

---A post's comment thread on its own (the comment sheet refetch). Privacy-gated exactly like
---actions.post - the thread of a private author's post is only served to the owner and accepted
---followers, so a leaked post id reads nothing. Read-only.
---@param src integer player server id
---@param payload table { postId: string }
---@return table result { comments }
function actions.comments(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = store.getPostRow(trim(payload.postId))
    if not row then return fail('Post not found') end
    if not canInteract(acc.username, row.author) then return fail('This account is private') end
    local out = {}
    for _, c in ipairs(store.commentsFor(row.id, acc.username, 200)) do out[#out + 1] = serializeComment(c) end
    return ok({ comments = out })
end

---Add a comment (text and/or GIF, both capped) to a post the viewer may interact with. The
---author gets a notification with a 120-char preview; @-mentions in the text get their own,
---skipping the author (who already got the comment one) and anyone who may not view the post -
---a mention must not leak a private post's id and thumbnail into a non-follower's Activity feed
---or banner. The refreshed thread count + new comment fan out privacy-scoped so open post views
---append it live.
---@param src integer player server id
---@param payload table { postId: string, text?: string, gifUrl?: string }
---@return table result { comment, count }
function actions.addComment(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end

    local row = store.getPostRow(trim(payload.postId))
    if not row then return fail('Post not found') end
    if not canInteract(acc.username, row.author) then return fail('This account is private') end

    local text   = trim(payload.text):sub(1, 1000)
    local gifUrl = trim(payload.gifUrl)
    gifUrl = (gifUrl:sub(1, 4) == 'http') and gifUrl:sub(1, 512) or nil
    if text == '' and not gifUrl then return fail('Empty comment') end

    local id = store.newId()
    store.insertComment(id, row.id, acc.username, text ~= '' and text or nil, gifUrl, os.time())

    notify(row.author, 'comment', acc.username, row.id, text ~= '' and text:sub(1, 120) or nil)
    for _, m in ipairs(mentionsIn(text, acc.username)) do
        if m ~= row.author and canInteract(m, row.author) then notify(m, 'mention', acc.username, row.id, nil) end
    end

    local fresh = store.commentsFor(row.id, acc.username, 200)
    local serialized
    for _, c in ipairs(fresh) do if c.id == id then serialized = serializeComment(c) end end
    broadcastPost(row.author, 'postChanged', { postId = row.id, comments = #fresh, comment = serialized })
    return ok({ comment = serialized, count = #fresh })
end

---Toggle the viewer's like on a comment, gated on the parent post author's privacy (comment ids
---travel inside post-change pushes, so an ungated toggle would let non-followers poke private
---threads). Keyed (comment, user) with INSERT IGNORE so replays never double-count.
---@param src integer player server id
---@param payload table { commentId: string }
---@return table result { liked, likes }
function actions.toggleCommentLike(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = store.getCommentRow(trim(payload.commentId))
    if not row then return fail('Comment not found') end
    local post = store.getPostRow(row.post_id)
    if post and not canInteract(acc.username, post.author) then return fail('This account is private') end

    local nowLiked
    if store.isCommentLiked(row.id, acc.username) then
        store.removeCommentLike(row.id, acc.username); nowLiked = false
    else
        store.addCommentLike(row.id, acc.username, os.time()); nowLiked = true
    end
    return ok({ liked = nowLiked, likes = store.commentLikeCount(row.id) })
end

---Full profile header for the React side: card fields + live counts + the viewer's relationship
---(followStatus, followsMe) and whether the grid is locked to them (private and not accepted).
---Counts stay public even when locked, like the real app.
---@param acc table viewer's account row
---@param target string profile handle
---@return table|nil profile nil when no such profile exists
local function serializeProfile(acc, target)
    local row = store.getProfile(target)
    if not row then return nil end
    local isMe = target == acc.username
    local status = isMe and 'self' or (store.followStatus(acc.username, target) or 'none')
    local locked = (not isMe) and flag(row.is_private) and status ~= 'accepted'
    return {
        username     = row.username,
        name         = row.display_name or '',
        bio          = row.bio or '',
        avatar       = row.avatar or '',
        verified     = flag(row.verified),
        isPrivate    = flag(row.is_private),
        isMe         = isMe,
        followStatus = status,
        followsMe    = (not isMe) and store.isAcceptedFollower(target, acc.username) or false,
        posts        = store.countPosts(target),
        followers    = store.countFollowers(target),
        following    = store.countFollowing(target),
        locked       = locked,
    }
end

---A profile page header. An empty handle means the viewer's own (bootstrapped if fresh);
---anything else lowercases to match stored handles. Private profiles are still returned - the
---card and counts are public - with `locked` telling the UI to hide the grid. Read-only.
---@param src integer player server id
---@param payload table { handle?: string }
---@return table result { profile }
function actions.profile(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    ensureProfile(acc)
    local target = trim(payload.handle)
    if target == '' then target = acc.username else target = target:lower() end
    local profile = serializeProfile(acc, target)
    if not profile then return fail('Profile not found') end
    return ok({ profile = profile })
end

---A profile's post grid. A private author the viewer can't view yields an empty grid rather
---than an error, so the locked profile page still renders its header. Read-only.
---@param src integer player server id
---@param payload table { handle?: string }
---@return table result { posts }
function actions.profilePosts(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local target = trim(payload.handle)
    if target == '' then target = acc.username else target = target:lower() end

    local row = store.getProfile(target)
    if row and not canView(acc.username, row) then return ok({ posts = {} }) end
    local out = {}
    for _, p in ipairs(store.postsBy(acc.username, target, 60)) do out[#out + 1] = serializePost(p) end
    return ok({ posts = out })
end

---Update the viewer's own profile - the target always comes from the session, never the payload.
---Fields cap at their column widths; a blank name keeps the current display name; the avatar
---must be http(s) (anything else clears it, which is how removal works). `verified` is copied
---from the existing row so a client can't self-verify, and created_at is preserved.
---@param src integer player server id
---@param payload table { name?: string, bio?: string, avatar?: string, private?: boolean }
---@return table result { profile }
function actions.updateProfile(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local existing = ensureProfile(acc)

    local name = trim(payload.name):sub(1, 64)
    if name == '' then name = existing.display_name end
    local avatar = trim(payload.avatar)
    avatar = (avatar:sub(1, 4) == 'http') and avatar:sub(1, 512) or nil

    store.upsertProfile(acc.username, {
        displayName = name,
        bio         = trim(payload.bio):sub(1, 200),
        avatar      = avatar,
        isPrivate   = payload.private == true,
        verified    = flag(existing.verified),
        createdAt   = existing.created_at,
    })
    return ok({ profile = serializeProfile(acc, acc.username) })
end

---Follow / unfollow (or request / cancel-request for private targets) in one toggle. An existing
---relation is removed: an accepted one notifies the target of the unfollow, while cancelling a
---still-pending request instead deletes the follow-request notification and pings the target's
---Activity so the pending entry disappears live (no new notification). Otherwise a private
---target gets a 'pending' row + follow_request notification, a public one 'accepted' + follow.
---Self-follow and unknown targets are rejected.
---@param src integer player server id
---@param payload table { handle: string }
---@return table result { status }
function actions.toggleFollow(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local target = trim(payload.handle):lower()
    if target == '' or target == acc.username then return fail('Bad target') end

    local tprofile = store.getProfile(target)
    if not tprofile then return fail('Account not found') end

    local prior = store.followStatus(acc.username, target)
    if prior then
        store.removeFollow(acc.username, target)
        if prior == 'accepted' then
            notify(target, 'unfollow', acc.username, nil, nil)
        elseif prior == 'pending' then
            store.deleteRequestNotification(target, acc.username)
            pingActivity(target)
        end
        return ok({ status = 'none' })
    end

    if flag(tprofile.is_private) then
        store.addFollow(acc.username, target, 'pending', os.time())
        notify(target, 'follow_request', acc.username, nil, nil)
        return ok({ status = 'pending' })
    end
    store.addFollow(acc.username, target, 'accepted', os.time())
    notify(target, 'follow', acc.username, nil, nil)
    return ok({ status = 'accepted' })
end

---Owner accepts or declines a pending follow request. Only valid while the requester->owner row
---is still 'pending', so a replayed or forged respond is a no-op failure. Accept upgrades the
---row and notifies the requester; decline silently deletes it. Either way the requester's open
---profile view is pushed the new status so their Follow button updates live.
---@param src integer player server id
---@param payload table { handle: string, accept?: boolean }
---@return table result
function actions.respondFollow(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local requester = trim(payload.handle):lower()
    if requester == '' then return fail('Bad request') end
    if store.followStatus(requester, acc.username) ~= 'pending' then return fail('No pending request') end

    if payload.accept == true then
        store.setFollowStatus(requester, acc.username, 'accepted')
        notify(requester, 'follow_accept', acc.username, nil, nil)
        pushFollowStatus(requester, acc.username, 'accepted')
    else
        store.removeFollow(requester, acc.username)
        pushFollowStatus(requester, acc.username, 'none')
    end
    return ok()
end

---Pending follow requests waiting on the viewer, as user cards. Read-only.
---@param src integer player server id
---@return table result { requests }
function actions.followRequests(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local out = {}
    for _, r in ipairs(store.pendingRequests(acc.username)) do out[#out + 1] = userCard(r) end
    return ok({ requests = out })
end

---Followers / following list for a profile, privacy-gated to an empty list for locked profiles.
---Each card carries the VIEWER's relationship to that user so the row's Follow button renders
---correctly ('self' for their own row). Read-only.
---@param src integer player server id
---@param payload table { handle?: string, kind?: string }
---@return table result { users }
function actions.followList(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local target = trim(payload.handle)
    if target == '' then target = acc.username else target = target:lower() end
    local kind = payload.kind == 'following' and 'following' or 'followers'

    local row = store.getProfile(target)
    if row and not canView(acc.username, row) then return ok({ users = {} }) end

    local out = {}
    for _, r in ipairs(store.followList(target, kind)) do
        local card = userCard(r)
        card.followStatus = (r.username == acc.username) and 'self' or (store.followStatus(acc.username, r.username) or 'none')
        out[#out + 1] = card
    end
    return ok({ users = out })
end

---Search accounts by handle or display name (LIKE '%q%', 20 rows). The query caps at the 64-char
---handle column width before it reaches the DB - it drives a table scan, so an unbounded string
---is a cheap DoS lever. Empty queries skip the DB entirely; the viewer is filtered out of the
---results. Read-only.
---@param src integer player server id
---@param payload table { query: string }
---@return table result { users }
function actions.search(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local query = trim(payload.query):sub(1, 64):lower()
    if query == '' then return ok({ users = {} }) end
    local out = {}
    for _, r in ipairs(store.searchProfiles(query, 20)) do
        if r.username ~= acc.username then out[#out + 1] = userCard(r) end
    end
    return ok({ users = out })
end

---The stories tray: active (<24h) stories from the viewer + accounts they follow (the store
---query enforces the follow scope, so private authors are covered), grouped per author into
---@type integer os.time() of the last global story prune (0 = never). Expired stories are filtered
---out at READ time by activeStoriesFor's cutoff, so they never render regardless; the prune is pure
---DB housekeeping, so it's throttled to once a minute across ALL players instead of firing two
---DELETEs on every per-player stories() open (home refresh hits this constantly).
local lastStoryPruneAt = 0

---frame stacks and ordered mine-first, then unseen, then seen - the iOS ordering. Live sessions
---the viewer may watch ride along. Expired stories never render (activeStoriesFor filters by
---cutoff); a throttled global prune sweeps them from the DB at most once a minute. Read-only apart
---from that prune.
---@param src integer player server id
---@return table result { stories, hasOwn, lives }
function actions.stories(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    ensureProfile(acc)

    local cutoff = os.time() - STORY_TTL
    if (os.time() - lastStoryPruneAt) >= 60 then
        lastStoryPruneAt = os.time()
        store.pruneExpiredStories(cutoff)
    end

    local seen = store.seenStoryIds(acc.username)
    local groups, order = {}, {}
    for _, row in ipairs(store.activeStoriesFor(acc.username, cutoff)) do
        local g = groups[row.author]
        if not g then
            g = { user = userCard(row), isMe = row.author == acc.username, frames = {}, seen = true }
            groups[row.author] = g
            order[#order + 1] = row.author
        end
        g.frames[#g.frames + 1] = { id = row.id, url = row.image }
        if not seen[row.id] then g.seen = false end
    end

    local mine, unseen, seenList = nil, {}, {}
    for _, author in ipairs(order) do
        local g = groups[author]
        if g.isMe then mine = g
        elseif g.seen then seenList[#seenList + 1] = g
        else unseen[#unseen + 1] = g end
    end
    local stories = {}
    if mine then stories[#stories + 1] = mine end
    for _, g in ipairs(unseen) do stories[#stories + 1] = g end
    for _, g in ipairs(seenList) do stories[#stories + 1] = g end

    return ok({ stories = stories, hasOwn = mine ~= nil, lives = live.activeForViewer(acc.username) })
end

---Publish a story frame: one http(s) image URL, capped at the column width. Its 24h lifetime is
---enforced at read/prune time (STORY_TTL), not stored on the row.
---@param src integer player server id
---@param payload table { image: string }
---@return table result
function actions.addStory(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    ensureProfile(acc)
    local image = trim(payload.image)
    if image:sub(1, 4) ~= 'http' then return fail('Add a photo') end
    store.insertStory(store.newId(), acc.username, image:sub(1, 512), os.time())
    return ok()
end

---Record that the viewer watched a story frame. Scoped to the viewer's own seen-set (it only
---affects their tray ordering) and only for ids that actually exist, so forged ids can't grow
---the table. Idempotent - the view row is keyed (story, user) with INSERT IGNORE.
---@param src integer player server id
---@param payload table { storyId: string }
---@return table result
function actions.markStorySeen(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local id = trim(payload.storyId)
    if id ~= '' and store.getStoryRow(id) then store.markStorySeen(id, acc.username, os.time()) end
    return ok()
end

---The Activity feed (newest 60). Opening it marks everything seen and re-pushes the badge, so
---the unread count clears the moment the tab is read.
---@param src integer player server id
---@return table result { notifications }
function actions.activity(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end

    local rows = store.notificationsFor(acc.username, 60)
    local postIds = {}
    for i = 1, #rows do
        if rows[i].post_id and rows[i].post_id ~= '' then postIds[#postIds + 1] = rows[i].post_id end
    end
    local thumbs = store.thumbsFor(postIds)

    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = serializeNotif(row, thumbs) end

    store.markNotificationsSeen(acc.username)
    bumpBadge(acc.username)
    return ok({ notifications = out })
end

---Unread counts for the in-app badges (Activity tab + DM button). Read-only - marks nothing
---seen.
---@param src integer player server id
---@return table result { activity, dms }
function actions.counts(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    return ok({
        activity = store.unseenNotificationCount(acc.username),
        dms      = store.dmUnreadTotal(acc.username),
    })
end

---Swipe-to-dismiss one Activity row. The delete is recipient-scoped in the store, so a forged id
---can't clear someone else's notification.
---@param src integer player server id
---@param payload table { id: string }
---@return table result
function actions.dismissNotification(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local id = trim(payload.id)
    if id ~= '' then store.deleteNotification(id, acc.username) end
    return ok()
end

---Profile card for a DM peer, with a handle-only placeholder when the profile row is gone
---(deleted account) so old threads still render.
---@param username string peer handle
---@return table card
local function peerCard(username, row)
    row = row or store.getProfile(username)
    if not row then return { id = username, handle = username, avatar = '', verified = false, name = username } end
    return {
        id = row.username, handle = row.username, avatar = row.avatar or '',
        verified = flag(row.verified), name = row.display_name or '',
    }
end

---The DM inbox: one row per conversation peer, most-recent first, with the last message and the
---per-peer unread count. Peers derive from the viewer's own message rows, so only their own
---threads are reachable. Read-only.
---@param src integer player server id
---@return table result { conversations }
function actions.dmList(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end

    local peers   = store.dmPeers(acc.username)
    local handles = {}
    for i = 1, #peers do handles[i] = peers[i].peer end
    local profiles = store.profilesByUsernames(handles)
    local unread   = store.dmUnreadByPeer(acc.username)

    local out = {}
    for _, p in ipairs(peers) do
        local last = store.dmLast(acc.username, p.peer)
        out[#out + 1] = {
            id      = p.peer,
            user    = peerCard(p.peer, profiles[p.peer]),
            last    = last and serializeDm(last, acc.username) or nil,
            unread  = unread[p.peer] or 0,
            ts      = (tonumber(p.last_at) or 0) * 1000,
        }
    end
    return ok({ conversations = out })
end

---One conversation, oldest-first (last 200). Opening it marks the peer's messages read and
---re-derives the badge. The thread query is keyed on the viewer's own handle, so whatever handle
---the payload names, only threads the viewer participates in are readable.
---@param src integer player server id
---@param payload table { handle: string }
---@return table result { id, user, messages }
function actions.dmThread(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local peer = trim(payload.handle):lower()
    if peer == '' then return fail('No conversation') end

    local messages = {}
    for _, row in ipairs(store.dmThread(acc.username, peer, 200)) do messages[#messages + 1] = serializeDm(row, acc.username) end

    store.markDmRead(acc.username, peer)
    bumpBadge(acc.username)
    return ok({ id = peer, user = peerCard(peer), messages = messages })
end

---Send a DM. The recipient must exist and differ from the sender; the kind is whitelisted
---(anything else coerces to 'text'), the body caps at 1000 chars, the metadata is sanitized per
---kind, and content-free sends are rejected. Each of the recipient's online phones gets the
---message push, a banner - titled with the sender's display name, deeplinking straight into this
---conversation and clearing any stale drill-in (false = closed) - and a badge refresh.
---@param src integer player server id
---@param payload table { to: string, kind?: string, body?: string, ...per-kind meta }
---@return table result { message }
function actions.dmSend(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local to = trim(payload.to):lower()
    if to == '' or to == acc.username then return fail('Bad recipient') end
    if not store.getProfile(to) then return fail('Account not found') end

    local kind = VALID_DMKIND[payload.kind] and payload.kind or 'text'
    local body = trim(payload.body):sub(1, 1000)
    local meta = sanitizeDmMeta(kind, payload)
    if not hasDmContent(kind, body, meta) then return fail('Empty message') end

    local id = store.newId()
    store.insertDm(id, acc.username, to, body, kind, meta, os.time())
    local row = store.getDm(id)

    local myName = peerCard(acc.username).name
    for _, tsrc in ipairs(sourcesFor(to)) do
        TriggerClientEvent('sd-phone:client:photogram:dmReceived', tsrc, {
            peer = acc.username, user = peerCard(acc.username), message = serializeDm(row, to),
        })
        TriggerClientEvent('sd-phone:client:notify', tsrc, {
            app = 'photogram', appId = 'photogram', title = myName ~= '' and myName or acc.username,
            body = (kind == 'image' and '📷 Photo') or (kind == 'gif' and 'GIF') or (kind == 'voice' and '🎤 Voice message') or (kind == 'post' and '📷 Shared a post') or body,
            time = 'now', quietInApp = true,
            link = {
                ['photogram:tab'] = 'home', ['photogram:dmOpen'] = true, ['photogram:dmDeepLink'] = acc.username,
                ['photogram:commentId'] = false, ['photogram:viewHandle'] = false,
                ['photogram:detail'] = false, ['photogram:follows'] = false,
            },
        })
        badges.push(tsrc)
    end
    return ok({ message = serializeDm(row, acc.username) })
end

---Toggle the viewer's emoji reaction on a DM they are part of - participant-checked, so a forged
---message id outside their threads is rejected. Reactions live as a JSON emoji->users map on the
---row; an emoji's user list is dropped when it empties. The updated chips return to the caller
---and push live to the peer, each serialized from their own perspective.
---@param src integer player server id
---@param payload table { id: string, emoji: string }
---@return table result { id, reactions }
function actions.dmReact(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    local row = type(payload.id) == 'string' and store.getDm(payload.id) or nil
    if not row or (row.from_user ~= acc.username and row.to_user ~= acc.username) then return fail('Message not found') end

    local emoji = tostring(payload.emoji or '')
    if emoji == '' or #emoji > 16 then return fail('Invalid reaction') end

    local reactions = store.decodeJson(row.reactions)
    local users = reactions[emoji] or {}
    local found
    for i, u in ipairs(users) do if u == acc.username then found = i break end end
    if found then table.remove(users, found) else users[#users + 1] = acc.username end
    if #users > 0 then reactions[emoji] = users else reactions[emoji] = nil end
    store.updateDmReactions(row.id, reactions)

    local fresh = store.getDm(row.id)
    local peer  = row.from_user == acc.username and row.to_user or row.from_user
    for _, tsrc in ipairs(sourcesFor(peer)) do
        TriggerClientEvent('sd-phone:client:photogram:dmReaction', tsrc, {
            peer = acc.username, id = row.id, reactions = serializeReactions(fresh, peer) or {},
        })
    end
    return ok({ id = row.id, reactions = serializeReactions(fresh, acc.username) or {} })
end

---Wipe every trace of the viewer's photogram content (posts, comments, likes, saves, stories,
---DMs, follows, notifications, profile). Keyed to the signed-in account only - there is no
---payload to forge. Deleting the credential row itself belongs to the accounts engine.
---@param src integer player server id
---@return table result
function actions.deleteAccount(src)
    local acc = viewerAccount(src)
    if not acc then return fail('Not signed in') end
    store.wipeUser(acc.username)
    return ok()
end

return actions
