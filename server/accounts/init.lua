---@type table Accounts persistence layer (server.accounts.store): schema bootstrap + legacy migration.
local store   = require 'server.accounts.store'
---@type table Authoritative account handlers (server.accounts.actions): validation + all mutation.
local actions = require 'server.accounts.actions'

---Schema bootstrap + one-time legacy credential migration, in a thread so it can yield until
---oxmysql is ready without blocking resource start. Each step is pcall-guarded independently: a
---failed migration (the Birdy/Mail source tables may not exist on a fresh install) must not take
---the schema down with it, and migrateLegacy's INSERT IGNORE makes re-runs no-ops.
CreateThread(function()
    local okSchema, err = pcall(store.ensureSchema)
    if not okSchema then
        print(('^1[sd-phone:accounts]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    local okMig, merr = pcall(store.migrateLegacy)
    if not okMig then
        print(('^1[sd-phone:accounts]^0 legacy migration failed: %s'):format(merr))
    end
    print('^2[sd-phone:accounts]^0 schema ready')
end)

-- Authoritative account callbacks: thin delegates into server.accounts.actions, which owns the
-- validation + persistence (each handler is documented there). Reachable by ANY connected client
-- with ANY payload - the actions layer trusts `src` alone and validates everything else.
lib.callback.register('sd-phone:server:accounts:register',     function(src, payload) return actions.register(src, payload) end)
lib.callback.register('sd-phone:server:accounts:login',        function(src, payload) return actions.login(src, payload) end)
lib.callback.register('sd-phone:server:accounts:logout',       function(src, payload) return actions.logout(src, payload) end)
lib.callback.register('sd-phone:server:accounts:me',           function(src, payload) return actions.me(src, payload) end)
lib.callback.register('sd-phone:server:accounts:requestReset', function(src, payload) return actions.requestReset(src, payload) end)
lib.callback.register('sd-phone:server:accounts:confirmReset', function(src, payload) return actions.confirmReset(src, payload) end)
lib.callback.register('sd-phone:server:accounts:changePassword', function(src, payload) return actions.changePassword(src, payload) end)
lib.callback.register('sd-phone:server:accounts:suggestCode',  function(src, payload) return actions.suggestCode(src, payload) end)
lib.callback.register('sd-phone:server:accounts:myNumber',     function(src)          return actions.myNumber(src) end)
lib.callback.register('sd-phone:server:accounts:myEmail',      function(src)          return actions.myEmail(src) end)
lib.callback.register('sd-phone:server:accounts:savePassword',   function(src, payload) return actions.savePassword(src, payload) end)
lib.callback.register('sd-phone:server:accounts:listPasswords',  function(src)          return actions.listPasswords(src) end)
lib.callback.register('sd-phone:server:accounts:deletePassword', function(src, payload) return actions.deletePassword(src, payload) end)

-- Every table that holds app accounts or content keyed to them. Wiping the engine tables alone is
-- not enough: the bootstrap migration would re-import credentials from the mail/birdy tables on
-- the next restart, so those (and birdy's account-keyed content) go too.
---@type string[] Tables truncated by /wipephoneaccounts.
local WIPE_TABLES = {
    'phone_app_accounts',
    'phone_app_sessions',
    'phone_passwords',
    'phone_mail_accounts',
    'phone_birdy_profiles',
    'phone_birdy_posts',
    'phone_birdy_likes',
    'phone_birdy_follows',
    'phone_birdy_dms',
    'phone_birdy_notifications',
}

---/wipephoneaccounts - truncate every account-bearing table (admin-only via `restricted`; a
---player client can't invoke it). Table names come from the constant list above, never from
---input, and each TRUNCATE is pcall-guarded so a missing table on a partial install skips
---instead of aborting the sweep. Also runnable from the server console (source 0), where the
---notify is skipped.
---@param source integer player server id (0 from console)
lib.addCommand('wipephoneaccounts', {
    help = 'Wipe EVERY phone app account (mail, birdy, photogram, cherry, vibez), all birdy content, and the passwords vault',
    restricted = 'group.admin',
}, function(source)
    local wiped, failed = 0, 0
    for i = 1, #WIPE_TABLES do
        local okTruncate = pcall(function()
            MySQL.query.await('TRUNCATE TABLE ' .. WIPE_TABLES[i])
        end)
        if okTruncate then wiped = wiped + 1 else failed = failed + 1 end
    end

    local msg = ('wiped %d account table%s%s'):format(
        wiped, wiped == 1 and '' or 's',
        failed > 0 and (' (%d missing/failed)'):format(failed) or ''
    )
    print(('^3[sd-phone:accounts]^0 %s'):format(msg))
    if source and source > 0 then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Phone accounts', description = msg, type = 'success',
        })
    end
end)

---/wipephotogram - remove just the Photogram accounts (plus their sessions and saved
---Passwords-app logins), leaving every other app's accounts intact (admin-only via `restricted`).
---The engine tables are shared and keyed by `app`, so this DELETEs WHERE app = 'photogram' rather
---than truncating. Photogram's feed/DMs are client-side mock data with no DB tables, so nothing
---else needs clearing. Everyone must re-register afterwards.
---@param source integer player server id (0 from console)
lib.addCommand('wipephotogram', {
    help = 'Wipe ALL Photogram accounts (plus their sessions and saved logins). Everyone must re-register.',
    restricted = 'group.admin',
}, function(source)
    local removed = 0
    local ok = pcall(function()
        removed = MySQL.update.await('DELETE FROM phone_app_accounts WHERE app = ?', { 'photogram' }) or 0
        MySQL.update.await('DELETE FROM phone_app_sessions WHERE app = ?', { 'photogram' })
        MySQL.update.await('DELETE FROM phone_passwords   WHERE app = ?', { 'photogram' })
    end)

    local msg = ok
        and ('wiped %d Photogram account%s'):format(removed, removed == 1 and '' or 's')
        or  'failed to wipe Photogram accounts (see server console)'
    print(('^3[sd-phone:accounts]^0 %s'):format(msg))
    if source and source > 0 then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Photogram', description = msg, type = ok and 'success' or 'error',
        })
    end
end)

---Public export: does an account exist for `app`? -
---exports['sd-phone']:accountExists(app, username). Read-only; `app` must be one of the engine's
---account apps (photogram, cherry, vibez, birdy, mail, ryde) and the username is trimmed and
---lowercased before the lookup, matching how accounts register. Callers are other server
---resources - a non-string or blank argument returns false instead of erroring.
---@param app string account app key
---@param username string account username
---@return boolean exists
exports('accountExists', function(app, username)
    return actions.accountExists(app, username)
end)

---Public export: one account in its public shape -
---exports['sd-phone']:getAppAccount(app, username). Returns { username, name, email, phone } -
---NEVER the password hash - or nil when the app is unknown, the arguments are malformed, or no
---such account exists. Read-only.
---@param app string account app key
---@param username string account username
---@return table|nil account public shape { username, name, email, phone }
exports('getAppAccount', function(app, username)
    return actions.getPublicAccount(app, username)
end)

---Public export: the account a citizen is currently signed into for `app` -
---exports['sd-phone']:getSessionAccount(app, citizenid). Same public shape as getAppAccount,
---never the password hash. nil means "not signed in" (or an unknown app / malformed citizenid),
---not an error. Read-only.
---@param app string account app key
---@param citizenid string framework per-character id
---@return table|nil account public shape { username, name, email, phone }
exports('getSessionAccount', function(app, citizenid)
    return actions.getPublicSession(app, citizenid)
end)
