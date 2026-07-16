---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'
---@type table Weazel News persistence layer (server.weazelnews.store): article + ticker row CRUD.
local store  = require 'server.weazelnews.store'
---@type table Player bridge (bridge.server.player): citizenid/name lookups from a server id.
local player = require 'bridge.server.player'
---@type table Job bridge (bridge.server.job): framework job membership/grade/boss checks.
local job    = require 'bridge.server.job'

---@type table Weazel News config (configs/weazelnews.lua): staff gating + content caps.
local WZ = config.WeazelNews

---@type table Actions module; the table returned at end of file. Handlers return the phone's
---{ success, message?, data? } envelope. The feed is public; publishing is staff-only. Byline,
---author citizenid and timestamps are stamped server-side and every input is clamped, so clients
---can't spoof bylines or smuggle oversized payloads.
local actions = {}

---@type table<string, boolean> Whitelist set of allowed article categories (WZ.Categories) -
---mirrors the web Category union. Anything else is rejected outright, never coerced.
local CATS = {}
for _, c in ipairs(WZ.Categories) do CATS[c] = true end

---The acting player's citizenid, always resolved from src via the player bridge - identity is
---never read from a payload.
---@param src integer player server id
---@return string|nil citizenid nil when the player can't be resolved
local function cidOf(src) return player.getIdentifier(src) end

local util = require 'server.util'
local trim = util.trim

---Coerce a client-supplied article id to a positive integer, or nil. Callback payloads are
---msgpack, so a modded client can send real NaN/inf/fractional floats - tonumber passes those
---through and the SQL layer errors serializing them, so they are rejected here instead.
---@param v any client-supplied id value
---@return integer|nil id positive integer, nil when malformed
local function articleId(v)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n ~= math.floor(n) or n < 1 then return nil end
    return n
end

---True when `src` is news staff allowed to manage the newsroom. With CheckIsBoss = false, anyone
---on a listed job qualifies (any grade). With CheckIsBoss = true, only a boss of a configured job
---(QBCore/QBox `isboss`; ESX falls back to grade >= BossGrade), or - when ManageMinGrade is set -
---someone on a listed job at that grade or above. The job always comes from the framework via the
---job bridge, so a client can't claim staff status through a payload. Every write handler
---(save/delete/setBreaking) passes through here; the feed only uses it to drive the manage
---cogwheel in the app.
---@param src integer player server id
---@return boolean canManage
local function canManage(src)
    for _, name in ipairs(WZ.Jobs) do
        if not WZ.CheckIsBoss then
            if job.has(src, name) then return true end
        else
            if job.isBoss(src, name, WZ.BossGrade) then return true end
            if WZ.ManageMinGrade and job.has(src, name, WZ.ManageMinGrade) then return true end
        end
    end
    return false
end

---Compact relative-time label from a unix timestamp: "now", "38m", "2h", "3d".
---@param ts integer|nil unix seconds the article was created
---@return string label
local function relTime(ts)
    local d = os.time() - (ts or 0)
    if d < 60      then return 'now' end
    if d < 3600    then return math.floor(d / 60) .. 'm' end
    if d < 86400   then return math.floor(d / 3600) .. 'h' end
    return math.floor(d / 86400) .. 'd'
end

---Split blank-line-separated text back into the paragraph array the reader expects. `(.-)\n\n` is
---non-greedy and `.` spans newlines in Lua patterns, so a paragraph keeps any single internal
---newlines while double newlines delimit. Falls back to the whole trimmed text as one paragraph.
---@param text string|nil stored body text
---@return string[] body paragraph array
local function splitParas(text)
    local body = {}
    for chunk in ((text or '') .. '\n\n'):gmatch('(.-)\n\n') do
        local p = trim(chunk)
        if p ~= '' then body[#body + 1] = p end
    end
    if #body == 0 then
        local t = trim(text or '')
        if t ~= '' then body[1] = t end
    end
    return body
end

---Public article shape sent to the app. Deliberately omits author_cid: readers only ever see the
---display byline, so citizenids never reach other players' clients. Handles oxmysql's TINYINT(1)
---reads arriving as either a Lua boolean or a number.
---@param row table article DB row
---@return table article public article payload
local function pubArticle(row)
    local body = splitParas(row.body)
    return {
        id       = tostring(row.id),
        category = row.category,
        headline = row.headline,
        dek      = row.dek,
        body     = body,
        author   = row.author,
        time     = relTime(row.created_at),
        views    = tonumber(row.views) or 0,
        image    = (row.image and row.image ~= '') and row.image or nil,
        featured = (tonumber(row.featured) == 1) or row.featured == true,
    }
end

---Validate + clamp a client save payload into a row-ready table. Category is whitelist-checked
---and the headline required (hard failures); everything else is clamped to the configured caps,
---which all fit their DB columns. The body arrives as an array of paragraphs and is stored as
---blank-line-separated text (splitParas is the inverse). A non-table payload sanitizes as empty -
---and so fails the category check - rather than crashing the handler.
---@param payload any client-supplied article draft
---@return table|nil row row-ready fields, nil on a hard validation failure
---@return string? message failure reason when row is nil
local function sanitize(payload)
    if type(payload) ~= 'table' then payload = {} end

    local category = trim(payload.category)
    if not CATS[category] then return nil, 'Pick a valid category' end

    local headline = trim(payload.headline)
    if headline == '' then return nil, 'Headline is required' end
    if #headline > WZ.MaxHeadlineLength then headline = headline:sub(1, WZ.MaxHeadlineLength) end

    local dek = trim(payload.dek)
    if #dek > WZ.MaxDekLength then dek = dek:sub(1, WZ.MaxDekLength) end

    local paras = {}
    if type(payload.body) == 'table' then
        for _, p in ipairs(payload.body) do
            local t = trim(p)
            if t ~= '' then paras[#paras + 1] = t end
        end
    elseif type(payload.body) == 'string' then
        local t = trim(payload.body)
        if t ~= '' then paras[1] = t end
    end
    local body = table.concat(paras, '\n\n')
    if #body > WZ.MaxBodyLength then body = body:sub(1, WZ.MaxBodyLength) end

    local image = trim(payload.image)
    if image == '' then image = nil
    elseif #image > WZ.MaxImageUrlLength then image = image:sub(1, WZ.MaxImageUrlLength) end

    return {
        category = category,
        headline = headline,
        dek      = dek,
        body     = body,
        image    = image,
        featured = (payload.featured == true or payload.featured == 1) and 1 or 0,
    }
end

---Public feed: the latest articles plus the breaking ticker, and whether the caller is news staff
---(drives the manage cogwheel in the app). Read-only - safe for any caller.
---@param src integer player server id
---@return table result envelope with { articles, ticker, canManage }
function actions.feed(src)
    local articles = {}
    for _, row in ipairs(store.articles(WZ.ArticlesPerFeed)) do
        articles[#articles + 1] = pubArticle(row)
    end
    local ticker = {}
    for _, row in ipairs(store.breaking()) do ticker[#ticker + 1] = row.text end

    return { success = true, data = { articles = articles, ticker = ticker, canManage = canManage(src) } }
end

---Count one read of an article and return its new view total. Best-effort and unauthenticated by
---design (any reader counts): a bad or unknown id just no-ops with the count it can find (0 for
---missing rows).
---@param src integer player server id
---@param id any client-supplied article id
---@return table result envelope with { id, views }
function actions.view(src, id)
    id = articleId(id)
    if not id then return { success = false, message = 'Bad article id' } end
    store.bumpViews(id)
    return { success = true, data = { id = tostring(id), views = store.viewsOf(id) } }
end

---Staff-only: create a new article, or update an existing one when `id` is set. Gated by
---canManage here (not just the client-side cogwheel), so calling the callback directly can't skip
---it; any staff member may edit any story - the newsroom is job-scoped, not per-author. Byline +
---author citizenid + created_at are stamped only on first insert, so edits never re-attribute a
---story. Setting `featured` demotes every other story so there's a single hero. A present-but-
---malformed id fails as not-found rather than silently inserting a duplicate article.
---@param src integer player server id
---@param payload any client-supplied article draft (sanitize documents the shape)
---@return table result envelope with { article } on success
function actions.save(src, payload)
    if not canManage(src) then return { success = false, message = 'Only Weazel News staff can publish' } end
    local cid = cidOf(src)
    if not cid then return { success = false } end

    local row, err = sanitize(payload)
    if not row then return { success = false, message = err } end

    local ts = os.time()
    local id
    if type(payload) == 'table' and payload.id ~= nil then
        id = articleId(payload.id)
        if not id then return { success = false, message = 'Article not found' } end
    end

    if id then
        if not store.articleById(id) then return { success = false, message = 'Article not found' } end
        row.updated_at = ts
        store.updateArticle(id, row)
    else
        row.author     = player.getName(src) or 'Weazel Staff'
        row.author_cid = cid
        row.created_at = ts
        row.updated_at = ts
        id = store.insertArticle(row)
    end

    if row.featured == 1 then store.clearFeatured(id) end

    local saved = store.articleById(id)
    return { success = true, data = { article = saved and pubArticle(saved) or nil } }
end

---Staff-only: delete an article by id. Same canManage gate as save, checked server-side so the
---callback can't be reached without the job - any staff member can retire any story.
---@param src integer player server id
---@param id any client-supplied article id
---@return table result envelope with { id } on success
function actions.delete(src, id)
    if not canManage(src) then return { success = false, message = 'Only Weazel News staff can edit this' } end
    id = articleId(id)
    if not id then return { success = false, message = 'Bad article id' } end
    store.deleteArticle(id)
    return { success = true, data = { id = tostring(id) } }
end

---Clamp candidate ticker lines to what the store accepts: non-strings and empties are dropped,
---the rest trimmed, capped per line (MaxBreakingLength fits the ticker column) and capped to
---MaxBreakingLines in order. Shared by the staff setBreaking handler and the setBreakingTicker
---export so both paths store identically clamped lines. A non-table clamps to an empty list.
---@param raw any candidate lines array
---@return string[] lines row-ready ticker lines in display order
local function clampTickerLines(raw)
    local lines = {}
    if type(raw) == 'table' then
        for _, l in ipairs(raw) do
            local t = trim(l)
            if t ~= '' then
                if #t > WZ.MaxBreakingLength then t = t:sub(1, WZ.MaxBreakingLength) end
                lines[#lines + 1] = t
                if #lines >= WZ.MaxBreakingLines then break end
            end
        end
    end
    return lines
end

---Staff-only: replace the whole breaking ticker. Lines walk the clampTickerLines clamps.
---Wholesale replace matches the editor - there are no per-line ids to track on the client.
---@param src integer player server id
---@param payload any client-supplied { lines: string[] }
---@return table result envelope with { ticker } echoing the stored lines
function actions.setBreaking(src, payload)
    if not canManage(src) then return { success = false, message = 'Only Weazel News staff can edit this' } end
    if type(payload) ~= 'table' then payload = {} end

    local lines = clampTickerLines(payload.lines)
    store.replaceBreaking(lines, os.time())
    return { success = true, data = { ticker = lines } }
end

---Trusted-caller publish for the postArticle export: another server resource files the story, so
---only the canManage staff gate is skipped - the draft still walks every sanitize clamp (category
---whitelist, required headline, length caps). Timestamps are stamped server-side, the byline
---defaults to 'Weazel News' (capped to the 80-char author column) and author_cid is the 'export'
---sentinel so the row is traceable to an export caller. A featured article demotes every other
---story, exactly like a staff save. Insert-only; edits stay staff-only through actions.save.
---@param article any export-supplied article draft (sanitize documents the shape)
---@return integer|nil articleId new article id, nil on validation failure
---@return string? reason failure reason when articleId is nil
function actions.publish(article)
    local row, err = sanitize(article)
    if not row then return nil, err end

    local author = trim(article.author)
    if author == '' then author = 'Weazel News' end

    local ts = os.time()
    row.author     = author:sub(1, 80)
    row.author_cid = 'export'
    row.created_at = ts
    row.updated_at = ts

    local id = store.insertArticle(row)
    if row.featured == 1 then store.clearFeatured(id) end
    return id
end

---Trusted-caller ticker replace for the setBreakingTicker export: no staff gate (the caller
---vouches), same clampTickerLines clamps as the staff path. An empty array legitimately clears
---the ticker; a non-table is a caller bug and returns false without touching the stored lines.
---@param lines any string[] ticker lines in display order
---@return boolean replaced
function actions.replaceTicker(lines)
    if type(lines) ~= 'table' then return false end
    store.replaceBreaking(clampTickerLines(lines), os.time())
    return true
end

return actions
