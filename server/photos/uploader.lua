---@type table sd-phone config root (configs/config.lua) - config.ApiKeys holds the media token.
local config = require 'configs.config'

---@type table Uploader module; the table returned at end of file.
local uploader = {}

-- Fivemanage's v3 base64 route accepts a JSON body carrying the data-URL string directly,
-- so there's no multipart to hand-build and no base64 decoding on our side - we forward the
-- canvas data-URL as-is. Response shape: { data = { id, url }, status = "ok" }.
---@type string Fivemanage media upload endpoint (v3 base64 route).
local UPLOAD_URL = 'https://api.fivemanage.com/api/v3/file/base64'

-- The Fivemanage Media key lives server-side only so it never reaches clients: primarily in
-- configs/server/apikeys.lua (FivemanageMedia), which is excluded from fxmanifest files{}. For
-- backward compatibility a blank config value falls back to the legacy `sd_fivemanage_key`
-- server convar (set in server.cfg with a non-replicated `set`).
---@type string Legacy convar name still honoured when the config key is blank.
local CONVAR_KEY = 'sd_fivemanage_key'

---The Fivemanage Media token: configs/server/apikeys.lua first, else the legacy convar. Read
---fresh on every upload so it can be changed (config edit + resource restart, or a live convar
---`set`) without code changes.
---@return string key the media token, or '' when unconfigured
local function mediaKey()
    local k = (config.ApiKeys or {}).FivemanageMedia
    if type(k) == 'string' and k ~= '' then return k end
    return GetConvar(CONVAR_KEY, '')
end

---Upload a base64 data-URL to Fivemanage and hand back the hosted CDN URL. Asynchronous -
---calls `cb(url|nil, err)` exactly once. The key comes from mediaKey() and only ever appears in
---the Authorization header of this server -> Fivemanage request; neither the key nor anything
---derived from it flows into `cb`, so no caller can leak it toward a client. Shared by the
---messages voice notes and voicememos modules, so the signature is a cross-module contract.
---(Instrumented - see the [UP n] prints.)
---@param base64Image string media as a base64 data-URL (data:image/...;base64,...)
---@param filename string suggested filename stored alongside the upload
---@param cb fun(url: string|nil, err: string|nil)
function uploader.uploadMedia(base64Image, filename, cb)
    local key = mediaKey()
    print(('^2[sd-phone:photos]^0 [UP 1] uploadMedia — key set=%s keylen=%d')
        :format(tostring(key ~= ''), #key))

    if key == '' then
        print('^1[sd-phone:photos]^0 [UP 2] aborting — no Fivemanage key configured')
        cb(nil, 'No Fivemanage key configured. Set FivemanageMedia in configs/server/apikeys.lua.')
        return
    end

    if type(base64Image) ~= 'string' or base64Image == '' then
        print('^1[sd-phone:photos]^0 [UP 3] aborting — empty image payload')
        cb(nil, 'Empty image payload')
        return
    end

    print(('^2[sd-phone:photos]^0 [UP 4] base64 len=%d head=%s')
        :format(#base64Image, base64Image:sub(1, 48)))

    local body = json.encode({
        base64   = base64Image,
        filename = filename or ('sdphone-%d.jpg'):format(os.time()),
    })

    print(('^2[sd-phone:photos]^0 [UP 5] POST -> %s (body bytes=%d)'):format(UPLOAD_URL, #body))

    PerformHttpRequest(UPLOAD_URL, function(status, responseBody, _headers)
        local respLen = responseBody and #responseBody or 0
        print(('^2[sd-phone:photos]^0 [UP 6] response status=%s bodylen=%d'):format(tostring(status), respLen))
        print(('^2[sd-phone:photos]^0 [UP 7] response body: %s')
            :format(tostring(responseBody and responseBody:sub(1, 800) or '(none)')))

        if status ~= 200 and status ~= 201 then
            cb(nil, ('Fivemanage upload failed: HTTP %s'):format(tostring(status)))
            return
        end

        if not responseBody or responseBody == '' then
            cb(nil, 'Empty response from Fivemanage')
            return
        end

        local okJson, decoded = pcall(json.decode, responseBody)
        if not okJson or type(decoded) ~= 'table' then
            cb(nil, 'Could not parse Fivemanage response')
            return
        end

        local url = type(decoded.data) == 'table' and decoded.data.url or nil
        print(('^2[sd-phone:photos]^0 [UP 8] parsed data.url=%s'):format(tostring(url)))
        if type(url) ~= 'string' or url == '' then
            cb(nil, 'Fivemanage returned no URL')
            return
        end

        cb(url, nil)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = key,
    })
end

return uploader
