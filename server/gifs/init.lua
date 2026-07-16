---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'

---@type string GIPHY v1 API base URL - every request is proxied through the server so the API
---key never reaches a client.
local GIPHY = 'https://api.giphy.com/v1/'

local util = require 'server.util'
local ok, fail = util.ok, util.fail


---@return table Giphy config (configs/giphy.lua): Limit, Rating (the API key is in config.ApiKeys).
local function cfg() return config.Giphy or {} end

---The GIPHY API key, read from the server-only configs/server/apikeys.lua (merged into
---config.ApiKeys server-side). Only ever appears in the api_key query param of this server ->
---GIPHY request; it never flows back toward a client (only mapped media URLs do).
---@return string key the API key, or '' when unconfigured
local function apiKey() return (config.ApiKeys or {}).Giphy or '' end

---@return boolean true when a GIPHY API key is configured (the picker is disabled without one)
local function hasKey()
    return apiKey() ~= ''
end

---Percent-encode a value for use as a single query-string parameter. Every value in every
---outbound GIPHY URL passes through here - including the client-supplied search text - so a
---crafted string can't splice extra parameters (a different rating, a bigger limit) onto the
---proxied request.
---@param s any value to encode (tostring'd; nil becomes '')
---@return string encoded
local function urlencode(s)
    return (tostring(s or ''):gsub('[^%w%-_%.~]', function(c)
        return ('%%%02X'):format(c:byte())
    end))
end

---Call a GIPHY v1 endpoint and return the decoded JSON, or nil on any failure (missing key,
---transport error, non-200, unparseable body). The API key (config.ApiKeys.Giphy) and the content
---rating are appended here, never from the payload, and every param value is urlencoded.
---@param path string endpoint path under the v1 base
---@param params? table<string, string> extra query parameters
---@return table|nil decoded response body
local function giphyGet(path, params)
    local key = apiKey()
    if key == '' then return nil end
    local c = cfg()

    local query = {
        'api_key=' .. urlencode(key),
        'rating='  .. urlencode(c.Rating or 'pg-13'),
    }
    for k, v in pairs(params or {}) do
        query[#query + 1] = k .. '=' .. urlencode(v)
    end

    local url = GIPHY .. path .. '?' .. table.concat(query, '&')
    local p = promise.new()
    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or not body then return p:resolve(nil) end
        local success, data = pcall(json.decode, body)
        p:resolve(success and data or nil)
    end, 'GET')
    return Citizen.Await(p)
end

---Flatten GIPHY's `images` renditions into the { id, preview, full } shape the UI wants.
---`fixed_width` is a grid-sized loop; `downsized` keeps the sent GIF small. Each falls back
---through the others so a missing rendition is fine; an entry with no usable full URL is
---dropped. Only these media URLs ever reach the client - never the API request URLs (which
---carry the key).
---@param results table[]|nil GIPHY result objects
---@return table[] gifs { id: string, preview: string, full: string }[]
local function mapGifs(results)
    local out = {}
    for i = 1, #(results or {}) do
        local r   = results[i]
        local img = r.images or {}
        local preview = (img.fixed_width and img.fixed_width.url)
            or (img.fixed_width_small and img.fixed_width_small.url)
            or (img.downsized and img.downsized.url)
        local full = (img.downsized and img.downsized.url)
            or (img.original and img.original.url)
            or (img.fixed_width and img.fixed_width.url)
        if full then
            out[#out + 1] = { id = tostring(r.id or i), preview = preview or full, full = full }
        end
    end
    return out
end

-- Browse-grid categories. GIPHY has no category endpoint with images, so the live trending
-- search terms stand in (falling back to this built-in set when that request fails), and each
-- tile resolves a representative GIF via its own limit=1 search.
---@type string[] Category terms used when the trending-searches request fails.
local FALLBACK_CATEGORIES = {
    'happy', 'lol', 'love', 'excited', 'sad', 'dance', 'no', 'yes',
    'hello', 'bye', 'hug', 'wow', 'thank you', 'sorry', 'facepalm', 'wink',
}

---@type integer Max category tiles resolved per refresh - each costs one HTTP search, so this
---bounds the fan-out.
local CATEGORY_LIMIT = 14
---@type table|nil, integer Resolved category list shared by all players + the GetGameTimer ms it
---was resolved at (0 = never).
local categoriesCache, categoriesCacheAt = nil, 0
---@type integer Category cache lifetime in ms (30 minutes) - tiles are cosmetic, staleness is fine.
local CATEGORIES_TTL = 30 * 60 * 1000

---First GIF rendition URL from a /gifs/search response (a category tile), or ''.
---@param data table|nil decoded search response
---@return string url preview URL, '' when none
local function firstPreview(data)
    local first = data and data.data and data.data[1]
    local img   = first and first.images
    if not img then return '' end
    return (img.fixed_width and img.fixed_width.url)
        or (img.downsized and img.downsized.url)
        or (img.original and img.original.url)
        or ''
end

---Browse-grid categories for the GIF picker: the live trending search terms, each resolved to a
---representative tile image via one limit=1 search fired concurrently per term. Pricey to
---refetch, so the resolved list is cached for CATEGORIES_TTL and shared by every player - which
---also bounds how often ANY client can make the server fan out HTTP requests. Takes no client
---input at all. Read-only.
lib.callback.register('sd-phone:server:gifs:categories', function()
    if not hasKey() then return fail('GIPHY API key not configured') end

    local now = GetGameTimer()
    if categoriesCache and (now - categoriesCacheAt) < CATEGORIES_TTL then
        return ok(categoriesCache)
    end

    local data  = giphyGet('trending/searches')
    local terms = (data and data.data) or {}
    if #terms == 0 then terms = FALLBACK_CATEGORIES end
    if #terms > CATEGORY_LIMIT then
        local trimmed = {}
        for i = 1, CATEGORY_LIMIT do trimmed[i] = terms[i] end
        terms = trimmed
    end

    local c, key, jobs = cfg(), apiKey(), {}
    for i = 1, #terms do
        local p = promise.new()
        jobs[i] = p
        local url = GIPHY .. 'gifs/search?' .. table.concat({
            'api_key=' .. urlencode(key),
            'rating='  .. urlencode(c.Rating or 'pg-13'),
            'q='       .. urlencode(tostring(terms[i])),
            'limit=1',
        }, '&')
        PerformHttpRequest(url, function(status, body)
            if status ~= 200 or not body then return p:resolve(nil) end
            local s, d = pcall(json.decode, body)
            p:resolve(s and d or nil)
        end, 'GET')
    end

    local out = {}
    for i = 1, #terms do
        local term = tostring(terms[i])
        out[#out + 1] = { name = term, term = term, image = firstPreview(Citizen.Await(jobs[i])) }
    end

    categoriesCache, categoriesCacheAt = out, now
    return ok(out)
end)

---@type table|nil, integer Cached trending payload shared by all players + the GetGameTimer ms it
---was fetched (0 = never). Trending is identical for everyone and changes slowly, so a short cache
---turns "one GIPHY request per Featured-tab open, per player" into at most one request per TTL.
local featuredCache, featuredCacheAt = nil, 0
---@type integer Featured cache lifetime in ms (5 minutes).
local FEATURED_TTL = 5 * 60 * 1000

---Trending GIFs for the picker's featured tab. No client input; the page size comes from config
---(Giphy.Limit), never the payload. Served from a shared 5-minute cache so many players opening the
---tab don't each hit GIPHY; a failed fetch is not cached, so it retries next time. Read-only.
lib.callback.register('sd-phone:server:gifs:featured', function()
    if not hasKey() then return fail('GIPHY API key not configured') end
    local now = GetGameTimer()
    if featuredCache and (now - featuredCacheAt) < FEATURED_TTL then return ok(featuredCache) end
    local data = giphyGet('gifs/trending', { limit = tostring(cfg().Limit or 24) })
    local payload = { gifs = mapGifs(data and data.data), next = '' }
    if data and data.data then featuredCache, featuredCacheAt = payload, now end
    return ok(payload)
end)

---Search GIFs. `q` and `pos` are the only client-supplied values and both reach GIPHY only as
---urlencoded single query values, so a crafted string can't steer the proxied request; the page
---size comes from config, never the payload. Both are also length-capped (well above any real
---search term - the UI sends short text and never sends pos at all) so a crafted megabyte string
---can't burn server CPU in urlencode or balloon the outbound request URL. Read-only.
---@param payload table { q?: string, pos?: string|number }
lib.callback.register('sd-phone:server:gifs:search', function(_, payload)
    if not hasKey() then return fail('GIPHY API key not configured') end
    if type(payload) ~= 'table' then payload = {} end
    local q = tostring(payload.q or ''):sub(1, 128)
    if q == '' then return fail('Empty query') end
    local data = giphyGet('gifs/search', {
        q      = q,
        limit  = tostring(cfg().Limit or 24),
        offset = tostring(payload.pos or '0'):sub(1, 16),
    })
    return ok({ gifs = mapGifs(data and data.data), next = '' })
end)
