---@type table Shared helpers for the lb-phone compat shim; the table returned at end of file.
local shim = {}

---@type table<string, boolean> Warn keys that already printed, so each breadcrumb appears once per session.
local warned = {}

---@type any[] AddEventHandler cookies for every registered export handler, kept so
---shim.deregisterAll can pull the whole registration if the real lb-phone starts mid-session.
local cookies = {}

---Register a function on the server export registry under lb-phone's resource name. This is
---exactly what the exports() sugar does, spelled out with a raw AddEventHandler because the
---sugar hardcodes the registering resource's own name. The handler receives EXACTLY one
---argument, the setCB closure, and must call it synchronously with the implementation; the
---calling resource then invokes fn directly with the export arguments. (lb-phone's own
---qbox/mail.lua treats the handler arguments as export arguments, which is wrong - do not copy
---that shape.) The handler cookie is collected so the registration can be removed again.
---@param name string PascalCase lb-phone export name
---@param fn function implementation
function shim.registerLbExport(name, fn)
    cookies[#cookies + 1] = AddEventHandler(('__cfx_export_lb-phone_%s'):format(name), function(setCB)
        setCB(fn)
    end)
end

---Remove every export handler the shim registered, so NEW exports['lb-phone'] lookups resolve
---to the real lb-phone instead. Resources that already called a shimmed export hold a cached
---reference and keep the shim's function until lb-phone next stops (the caller's export cache
---invalidates on resource stop). Idempotent.
function shim.deregisterAll()
    for i = 1, #cookies do
        RemoveEventHandler(cookies[i])
    end
    cookies = {}
end

---Print one console breadcrumb the first time `key` is hit, so a server owner can see which
---lb-phone integrations run degraded without being spammed. Subsequent hits are silent.
---@param key string dedupe key (export name, or name.arg for a partially supported argument)
---@param msg string message printed after the '[sd-phone] lb-phone compat:' prefix
function shim.warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    print(('^3[sd-phone]^0 lb-phone compat: %s'):format(msg))
end

---Render a stub's default for the warn line; nil and {} would otherwise print as noise.
---@param v any
---@return string
local function repr(v)
    if v == nil then return 'nil' end
    if type(v) == 'table' then return json.encode(v) end
    return tostring(v)
end

---Register a stubbed lb-phone export: it warns once on first call, naming the calling resource
---via GetInvokingResource so the degraded integration is findable, then returns the fixed safe
---default (every call, not just the first). `why` replaces the default 'is not supported'
---clause when the reason deserves more words.
---@param name string PascalCase lb-phone export name
---@param default any fixed return value
---@param why string|nil reason clause for the warning
function shim.stubLbExport(name, default, why)
    shim.registerLbExport(name, function()
        shim.warnOnce(name, ('%s %s (called by %s), returned %s'):format(
            name, why or 'is not supported', GetInvokingResource() or 'unknown', repr(default)))
        return default
    end)
end

return shim
