---@type table Locale module; the table returned at end of file. Tiny i18n layer: loads
---locales/<lang>.json once at boot, flattens nested objects into dot-paths (so `menu.buy_title`
---reads `dict['menu.buy_title']`), and exposes a t(key, replacements) lookup that passes the key
---through when a translation is missing. Loaded by BOTH contexts - each side reads its own copy
---of the dictionary because LoadResourceFile is sided.
local locale = {}

---@type table|nil sd-phone config root (configs.config), nil when this context doesn't ship it -
---the pcall keeps this shared module loadable from either side without a hard dependency.
local config = (function()
    local ok, c = pcall(require, 'configs.config')
    return ok and c or nil
end)()

---@type table<string, any> Flattened dot-path -> translation dictionary for the loaded language.
local dict = {}

---Recursively flatten a nested JSON-decoded table into dot-notation keys written into `target`
---(e.g. `{ menu = { buy = 'Buy' } }` becomes `target['menu.buy'] = 'Buy'`). Locale files come
---from this resource's own files, never from clients, so depth/shape isn't attacker-controlled.
---@param prefix string|nil
---@param source table
---@param target table<string, any>
local function flatten(prefix, source, target)
    for key, value in pairs(source) do
        local newKey = prefix and (prefix .. '.' .. key) or key
        if type(value) == 'table' then
            flatten(newKey, value, target)
        else
            target[newKey] = value
        end
    end
end

---Localised lookup. Falls back to `key` when not present so missing translations are visible in
---the UI rather than rendering empty strings. Replacement values are %-escaped before the gsub so
---a value containing '%' can't act as a capture reference in the substitution.
---@param key string
---@param replacements? table<string, any>
---@return string
function locale.t(key, replacements)
    local lstr = dict[key]
    if lstr and replacements then
        for k, v in pairs(replacements) do
            local safe = tostring(v):gsub('%%', '%%%%')
            lstr = lstr:gsub('{' .. tostring(k) .. '}', safe)
        end
    end
    return lstr or key
end

---Load `locales/<lang>.json` into the dictionary, clearing the previous language first so keys
---removed from a file don't linger after a reload. Falls back to English when the requested file
---is missing; passes through silently if even English is absent (locale support is optional).
---@param lang string
function locale.load(lang)
    lang = lang or 'en'
    local path = ('locales/%s.json'):format(lang)
    local file = LoadResourceFile(GetCurrentResourceName(), path)

    if not file and lang ~= 'en' then
        print('^3[SD-PHONE] Falling back to English locale^0')
        path = 'locales/en.json'
        file = LoadResourceFile(GetCurrentResourceName(), path)
    end
    if not file then return end

    local decoded = json.decode(file)
    if not decoded then
        print('^1[SD-PHONE] Failed to parse the locale JSON.^0')
        return
    end

    for k in pairs(dict) do dict[k] = nil end
    flatten(nil, decoded, dict)

    print(('^2[SD-PHONE] Loaded locale: %s^0'):format(lang))
end

-- One-shot boot thread: load the configured language (config.Locale, default 'en') a beat after
-- start so it lands alongside the rest of the boot output. Until it runs, t() passes keys through.
CreateThread(function()
    Wait(100)
    locale.load(config and config.Locale or 'en')
end)

return locale
