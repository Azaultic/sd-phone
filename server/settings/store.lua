---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'

---@type table Store module; the table returned at end of file.
local store = {}

---SQL fragment that strips the common phone-number separators ('-', ' ', '(', ')', '+', '.')
---from a column so every comparison is digit-to-digit. Numbers are normalised to bare digits on
---write, but a phone_settings table inherited from another/older phone resource can hold
---formatted values like 643-299-2243. `col` is always a literal column name supplied from inside
---this module - never client input - so the interpolation cannot be steered into SQL injection;
---the compared value itself is always passed as a ? parameter.
---@param col string literal column name to wrap
---@return string sql nested REPLACE(...) expression over the column
local function stripCol(col)
    return ("REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(%s,'-',''),' ',''),'(',''),')',''),'+',''),'.','')"):format(col)
end

---Generate a random 10-digit phone number as raw digits - the frontend formats it for display.
---The first block starts at 200 so a number never leads with 0 or 1.
---@return string number ten raw digits
local function genNumber()
    return ('%03d%03d%04d'):format(math.random(200, 989), math.random(100, 999), math.random(0, 9999))
end

---True if a column already exists on the given table (information_schema probe). ensureSchema
---uses this to backfill columns on servers whose tables predate them, since older MariaDB builds
---lack ADD COLUMN IF NOT EXISTS. Both names arrive as literals from this module, and are passed
---as ? parameters regardless.
---@param tbl string table name
---@param name string column name
---@return boolean exists
local function columnExists(tbl, name)
    local row = MySQL.single.await([[
        SELECT COUNT(*) AS n FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND table_name = ?
          AND column_name = ?
    ]], { tbl, name })
    return row ~= nil and tonumber(row.n) > 0
end

---Clamp a tone id to a safe shape (the frontend uses short lowercase slugs), capped at the
---column's 64 chars. Returns nil for empty/invalid input so the caller's COALESCE upsert leaves
---the stored value be rather than wiping it.
---@param id any client-supplied tone id
---@return string|nil clean lowercase [a-z0-9_-] slug, nil if unusable
local function sanitizeTone(id)
    if type(id) ~= 'string' then return nil end
    local clean = (id:lower():gsub('[^a-z0-9_-]', ''))
    if clean == '' then return nil end
    return clean:sub(1, 64)
end

---Create the shared phone_settings table (one row per character) plus its two satellite tables,
---backfilling columns on servers whose tables predate them so the resource stays drop-in. Run
---once at boot. The card_* columns are the editable "My Card" override fields - the phone number
---itself stays server-assigned. phone_custom_ringtones holds user-added YouTube tones (one row
---per saved tone per character; `kind` distinguishes a ringtone from a notification tone).
---phone_notif_prefs holds per-app notification toggles - a missing row means "on", so apps only
---store a row once the player flips the toggle and the default stays enabled without seeding
---every app for every character.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_settings (
            citizenid          VARCHAR(64) NOT NULL,
            phone_number       VARCHAR(20) NULL,
            active_group_id    VARCHAR(16) NULL,
            ringtone           VARCHAR(64) NULL,
            notification_tone  VARCHAR(64) NULL,
            airplane_mode      TINYINT(1)  NOT NULL DEFAULT 0,
            card_name          VARCHAR(64)  NULL,
            card_avatar        VARCHAR(512) NULL,
            card_email         VARCHAR(128) NULL,
            card_address       VARCHAR(128) NULL,
            installed_apps     TEXT         NULL,
            home_layout        TEXT         NULL,
            lock_clock         TEXT         NULL,
            wallpaper          VARCHAR(255) NULL,
            passcode           VARCHAR(8)   NULL,
            face_id            TINYINT(1)   NOT NULL DEFAULT 0,
            chat_text_scale    DECIMAL(3,2) NULL,
            hour24             TINYINT(1)   NULL,
            locale             VARCHAR(8)   NULL,
            updated_at         TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
                ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    if not columnExists('phone_settings', 'airplane_mode') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN airplane_mode TINYINT(1) NOT NULL DEFAULT 0')
    end
    if not columnExists('phone_settings', 'hour24') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN hour24 TINYINT(1) NULL')
    end
    for _, col in ipairs({
        { 'card_name',    'VARCHAR(64) NULL'  },
        { 'card_avatar',  'VARCHAR(512) NULL' },
        { 'card_email',   'VARCHAR(128) NULL' },
        { 'card_address', 'VARCHAR(128) NULL' },
    }) do
        if not columnExists('phone_settings', col[1]) then
            MySQL.query.await(('ALTER TABLE phone_settings ADD COLUMN %s %s'):format(col[1], col[2]))
        end
    end
    if not columnExists('phone_settings', 'phone_number') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN phone_number VARCHAR(20) NULL AFTER citizenid')
    end
    if not columnExists('phone_settings', 'ringtone') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN ringtone VARCHAR(64) NULL')
    end
    if not columnExists('phone_settings', 'notification_tone') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN notification_tone VARCHAR(64) NULL')
    end
    if not columnExists('phone_settings', 'installed_apps') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN installed_apps TEXT NULL')
    end
    if not columnExists('phone_settings', 'home_layout') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN home_layout TEXT NULL')
    end
    if not columnExists('phone_settings', 'lock_clock') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN lock_clock TEXT NULL')
    end
    if not columnExists('phone_settings', 'wallpaper') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN wallpaper VARCHAR(255) NULL')
    end
    if not columnExists('phone_settings', 'passcode') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN passcode VARCHAR(8) NULL')
    end
    if not columnExists('phone_settings', 'face_id') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN face_id TINYINT(1) NOT NULL DEFAULT 0')
    end
    if not columnExists('phone_settings', 'chat_text_scale') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN chat_text_scale DECIMAL(3,2) NULL')
    end
    if not columnExists('phone_settings', 'locale') then
        MySQL.query.await('ALTER TABLE phone_settings ADD COLUMN locale VARCHAR(8) NULL')
    end

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_custom_ringtones (
            citizenid  VARCHAR(64)  NOT NULL,
            id         VARCHAR(32)  NOT NULL,
            kind       VARCHAR(16)  NOT NULL DEFAULT 'ringtone',
            name       VARCHAR(64)  NOT NULL,
            url        VARCHAR(512) NOT NULL,
            created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid, id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    if not columnExists('phone_custom_ringtones', 'kind') then
        MySQL.query.await("ALTER TABLE phone_custom_ringtones ADD COLUMN kind VARCHAR(16) NOT NULL DEFAULT 'ringtone' AFTER id")
    end

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_notif_prefs (
            citizenid VARCHAR(64) NOT NULL,
            app       VARCHAR(32) NOT NULL,
            enabled   TINYINT(1)  NOT NULL DEFAULT 1,
            PRIMARY KEY (citizenid, app)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
end

---Clamp an app id to the short lowercase slug shape used everywhere else, capped at the column's
---32 chars. Returns nil for empty/invalid input so callers can treat "no valid app" uniformly.
---@param v any client-supplied app id
---@return string|nil clean lowercase [a-z0-9_-] slug, nil if unusable
local function sanitizeApp(v)
    if type(v) ~= 'string' then return nil end
    local clean = (v:lower():gsub('[^a-z0-9_-]', ''))
    if clean == '' then return nil end
    return clean:sub(1, 32)
end

---True if a player wants notifications from `app`. Defaults to true when they've never toggled
---it (no row) and when the app id is unusable, so a malformed lookup can never silence anyone.
---The TINYINT(1) flag is decoded accepting both the boolean and the numeric shape oxmysql may
---return. Read-only.
---@param citizenid string framework per-character id
---@param app string app slug
---@return boolean enabled
function store.getNotifPref(citizenid, app)
    local a = sanitizeApp(app)
    if not citizenid or citizenid == '' or not a then return true end
    local row = MySQL.single.await(
        'SELECT enabled FROM phone_notif_prefs WHERE citizenid = ? AND app = ?', { citizenid, a })
    if not row then return true end
    return row.enabled == true or tonumber(row.enabled) == 1
end

---Persist a player's notification preference for an app (upsert keyed on citizenid + app, so a
---replayed toggle is idempotent). No-op for an unusable app id.
---@param citizenid string framework per-character id
---@param app string app slug
---@param on boolean whether notifications are enabled
function store.setNotifPref(citizenid, app, on)
    local a = sanitizeApp(app)
    if not citizenid or citizenid == '' or not a then return end
    MySQL.update.await([[
        INSERT INTO phone_notif_prefs (citizenid, app, enabled) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE enabled = VALUES(enabled)
    ]], { citizenid, a, on == true and 1 or 0 })
end

---Trim a string and clamp it to `n` chars, sized to the target column so an oversized payload
---can't error the insert. nil / non-string / empty (after trim) becomes nil, which stores as
---NULL and reads back as "unset".
---@param v any client-supplied string
---@param n number maximum kept length
---@return string|nil trimmed string, nil if unusable
local function trimClamp(v, n)
    if type(v) ~= 'string' then return nil end
    local s = (v:gsub('^%s+', ''):gsub('%s+$', ''))
    if s == '' then return nil end
    return s:sub(1, n)
end

---Read a player's custom "My Card" overrides (nil fields = unset, so the caller falls back to
---the character's real name/defaults). Read-only.
---@param citizenid string framework per-character id
---@return { name: string|nil, avatar: string|nil, email: string|nil, address: string|nil }
function store.getCard(citizenid)
    if not citizenid or citizenid == '' then return {} end
    local row = MySQL.single.await(
        'SELECT card_name, card_avatar, card_email, card_address FROM phone_settings WHERE citizenid = ?',
        { citizenid }
    )
    if not row then return {} end
    return {
        name    = row.card_name,
        avatar  = row.card_avatar,
        email   = row.card_email,
        address = row.card_address,
    }
end

---Persist a player's "My Card" overrides in one upsert. Every field is trimmed and clamped to
---its column size; an empty field clears (stores NULL, reverting the card to its default). The
---caller (server.contacts.actions) resolves citizenid from src, so a client can only ever edit
---its own card.
---@param citizenid string framework per-character id
---@param fields { name?: string, avatar?: string, email?: string, address?: string }
function store.setCard(citizenid, fields)
    if not citizenid or citizenid == '' then return end
    fields = fields or {}
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, card_name, card_avatar, card_email, card_address)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            card_name    = VALUES(card_name),
            card_avatar  = VALUES(card_avatar),
            card_email   = VALUES(card_email),
            card_address = VALUES(card_address)
    ]], {
        citizenid,
        trimClamp(fields.name, 64),
        trimClamp(fields.avatar, 512),
        trimClamp(fields.email, 128),
        trimClamp(fields.address, 128),
    })
end

---Read a player's installed downloadable app ids (JSON array column). Decoded defensively: a
---garbage or hand-edited column yields {} rather than an error. Id-level whitelisting against
---the downloadable catalog happens in server.apps.actions, which sanitises on every read.
---@param citizenid string framework per-character id
---@return string[] ids installed app ids ({} when unset or unparseable)
function store.getInstalledApps(citizenid)
    if not citizenid or citizenid == '' then return {} end
    local row = MySQL.single.await(
        'SELECT installed_apps FROM phone_settings WHERE citizenid = ?',
        { citizenid }
    )
    if not row or not row.installed_apps or row.installed_apps == '' then return {} end
    local ok, decoded = pcall(json.decode, row.installed_apps)
    if not ok or type(decoded) ~= 'table' then return {} end
    return decoded
end

---Persist a player's installed downloadable app ids, leaving other settings intact. The callback
---layer (server.apps.actions) whitelists every id against the downloadable catalog before
---calling in, so the column only ever holds known app slugs.
---@param citizenid string framework per-character id
---@param ids string[] installed app ids
function store.setInstalledApps(citizenid, ids)
    if not citizenid or citizenid == '' then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, installed_apps) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE installed_apps = VALUES(installed_apps)
    ]], { citizenid, json.encode(ids or {}) })
end

---Read a player's saved home-screen layout - the opaque JSON string the UI stored, or nil if
---unset. The server never parses it; the frontend owns the shape. Read-only.
---@param citizenid string framework per-character id
---@return string|nil layout opaque layout JSON
function store.getHomeLayout(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await(
        'SELECT home_layout FROM phone_settings WHERE citizenid = ?',
        { citizenid }
    )
    if not row or not row.home_layout or row.home_layout == '' then return nil end
    return row.home_layout
end

---Persist a player's home-screen layout (an opaque JSON string from the UI), leaving other
---settings intact. The callback layer (server.apps.actions.saveLayout) enforces the string type
---and a 16k size cap before it reaches here, so the TEXT column can't be ballooned.
---@param citizenid string framework per-character id
---@param layout string opaque layout JSON
function store.setHomeLayout(citizenid, layout)
    if not citizenid or citizenid == '' then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, home_layout) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE home_layout = VALUES(home_layout)
    ]], { citizenid, layout })
end

---Read a player's phone number, or nil if not yet assigned. Read-only; use ensurePhoneNumber to
---assign on first access.
---@param citizenid string framework per-character id
---@return string|nil number raw-digit phone number
function store.getPhoneNumber(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await(
        'SELECT phone_number FROM phone_settings WHERE citizenid = ?',
        { citizenid }
    )
    return row and row.phone_number or nil
end

---Find the citizen who owns a given phone number. Compares raw digits on both sides (the input
---is stripped here, the column via stripCol) so formatted input still matches rows written by an
---older resource. Rejects input with no digits at all rather than matching everything. Read-only.
---@param number string phone number in any formatting
---@return string|nil citizenid owner, nil if unowned
function store.getCitizenByNumber(number)
    local digits = (tostring(number or ''):gsub('%D', ''))
    if digits == '' then return nil end
    local row = MySQL.single.await(
        ('SELECT citizenid FROM phone_settings WHERE %s = ? LIMIT 1'):format(stripCol('phone_number')),
        { digits }
    )
    return row and row.citizenid or nil
end

---True if any character already owns this number - the uniqueness probe ensurePhoneNumber runs
---against generated candidates (always non-empty digits). Digit-to-digit comparison like
---getCitizenByNumber. Read-only.
---@param number string phone number in any formatting
---@return boolean taken
function store.numberExists(number)
    local digits = (tostring(number or ''):gsub('%D', ''))
    local row = MySQL.single.await(
        ('SELECT 1 AS hit FROM phone_settings WHERE %s = ? LIMIT 1'):format(stripCol('phone_number')),
        { digits }
    )
    return row ~= nil
end

---Persist a player's phone number, leaving any other settings intact. Stores bare digits - the
---write-side half of the digit-to-digit comparison contract stripCol serves on the read side.
---@param citizenid string framework per-character id
---@param number string phone number in any formatting (separators stripped)
function store.setPhoneNumber(citizenid, number)
    if not citizenid or citizenid == '' then return end
    local clean = (tostring(number or ''):gsub('%D', ''))
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, phone_number) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE phone_number = VALUES(phone_number)
    ]], { citizenid, clean })
end

---Return a player's number, generating + saving a unique one on first access - "phone setup"
---boils down to this server-side. Idempotent: once a number exists it is returned unchanged
---forever. Tries 20 random candidates against numberExists, then accepts an unchecked one so a
---degenerate DB state can't loop forever; uniqueness is check-then-set (no unique index), so a
---same-instant collision between two first-time players is theoretically possible but
---practically unreachable in the ~7-billion number space.
---@param citizenid string framework per-character id
---@return string|nil number raw-digit phone number, nil only when citizenid is unusable
function store.ensurePhoneNumber(citizenid)
    if not citizenid or citizenid == '' then return nil end

    local existing = store.getPhoneNumber(citizenid)
    if existing then return existing end

    local number
    for _ = 1, 20 do
        local candidate = genNumber()
        if not store.numberExists(candidate) then
            number = candidate
            break
        end
    end
    number = number or genNumber()
    store.setPhoneNumber(citizenid, number)
    -- First-party mint announcement (citizenid, number): fires exactly once per character, on the
    -- true first assignment. No source is in scope here - listeners needing one resolve it via the
    -- player bridge - and it can fire from offline mints (getPhoneNumberByIdentifier, ensure=true).
    TriggerEvent('sd-phone:server:number:assigned', citizenid, number)
    return number
end

---Batch-resolve many citizenids to their stored phone numbers in ONE query - the read-only,
---no-assignment counterpart to ensurePhoneNumber, for hot roster loops that would otherwise fire
---a SELECT per id. Returns a cid -> bare-digit-number map; ids with no settings row are simply
---absent (callers here only look up players who already have a phone, so no number is minted).
---@param cids string[] citizenids to resolve
---@return table<string, string> cid -> digits number
function store.numbersFor(cids)
    if type(cids) ~= 'table' then return {} end
    local seen, list = {}, {}
    for i = 1, #cids do
        local c = cids[i]
        if c and c ~= '' and not seen[c] then seen[c] = true; list[#list + 1] = c end
    end
    if #list == 0 then return {} end
    local placeholders = ('?,'):rep(#list):sub(1, -2)
    local rows = MySQL.query.await(
        'SELECT citizenid, phone_number FROM phone_settings WHERE citizenid IN (' .. placeholders .. ')', list) or {}
    local out = {}
    for i = 1, #rows do out[rows[i].citizenid] = (tostring(rows[i].phone_number or ''):gsub('%D', '')) end
    return out
end

---Clamp a font/layout id to a safe lowercase slug (the frontend uses short slugs like 'rounded'
---/ 'centered'), capped at 16 chars. Returns nil for invalid input so setLockClock can drop the
---field instead of storing junk.
---@param v any client-supplied slug
---@return string|nil clean lowercase [a-z0-9_-] slug, nil if unusable
local function sanitizeSlug(v)
    if type(v) ~= 'string' then return nil end
    local clean = (v:lower():gsub('[^a-z0-9_-]', ''))
    if clean == '' then return nil end
    return clean:sub(1, 16)
end

---Validate a #rrggbb hex colour, returning it verbatim (or nil). Whitelist-shaped so nothing but
---a literal hex colour can reach the stored JSON the lockscreen later injects into CSS.
---@param v any client-supplied colour
---@return string|nil colour '#rrggbb', nil if not exactly that shape
local function sanitizeHex(v)
    if type(v) ~= 'string' then return nil end
    return v:match('^#%x%x%x%x%x%x$')
end

---Clamp the clock scale multiplier to the UI's sane range (0.7-1.4). Returns nil for
---non-numbers and NaN (msgpack lets a modded client send a genuine NaN float, which would slip
---past both range checks and corrupt the stored JSON); infinities fall to the nearest bound.
---@param v any client-supplied scale
---@return number|nil scale clamped multiplier, nil if unusable
local function clampScale(v)
    local n = tonumber(v)
    if not n or n ~= n then return nil end
    if n < 0.7 then n = 0.7 elseif n > 1.4 then n = 1.4 end
    return n
end

---Read a player's lockscreen clock config (font / layout / colour / scale), or nil if unset -
---the frontend then falls back to its defaults. Decoded defensively: a garbage column yields nil
---rather than an error. Read-only.
---@param citizenid string framework per-character id
---@return { font: string|nil, layout: string|nil, color: string|nil }|nil
function store.getLockClock(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await('SELECT lock_clock FROM phone_settings WHERE citizenid = ?', { citizenid })
    if not row or not row.lock_clock or row.lock_clock == '' then return nil end
    local ok, decoded = pcall(json.decode, row.lock_clock)
    if not ok or type(decoded) ~= 'table' then return nil end
    return decoded
end

---Persist a player's lockscreen clock config, leaving other settings intact. Each field is
---sanitised independently (slug/slug/hex/scale) and the stored JSON is rebuilt from ONLY the
---clean fields, so no client-shaped key or value ever lands in the column. A fully-invalid
---payload is ignored rather than wiping the saved config.
---@param citizenid string framework per-character id
---@param cfg { font?: string, layout?: string, color?: string, scale?: number }
function store.setLockClock(citizenid, cfg)
    if not citizenid or citizenid == '' or type(cfg) ~= 'table' then return end
    local clean = {
        font   = sanitizeSlug(cfg.font),
        layout = sanitizeSlug(cfg.layout),
        color  = sanitizeHex(cfg.color),
        scale  = clampScale(cfg.scale),
    }
    if not clean.font and not clean.layout and not clean.color and not clean.scale then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, lock_clock) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE lock_clock = VALUES(lock_clock)
    ]], { citizenid, json.encode(clean) })
end

---Clamp a wallpaper id to a safe shape, capped at the column's 255 chars. The frontend persists
---a build-stable filename key (e.g. 'background5.jpg'); the kept character set covers those keys
---plus simple asset/remote URLs. Returns nil for empty/invalid input.
---@param v any client-supplied wallpaper key
---@return string|nil clean key stripped to [%w._-/:], nil if unusable
local function sanitizeWallpaper(v)
    if type(v) ~= 'string' then return nil end
    local clean = (v:gsub('[^%w%._%-/:]', ''))
    if clean == '' then return nil end
    return clean:sub(1, 255)
end

---Read a player's saved wallpaper key, or nil if unset (the frontend then keeps its default).
---Read-only.
---@param citizenid string framework per-character id
---@return string|nil wallpaper saved key
function store.getWallpaper(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await('SELECT wallpaper FROM phone_settings WHERE citizenid = ?', { citizenid })
    if not row or not row.wallpaper or row.wallpaper == '' then return nil end
    return row.wallpaper
end

---Persist a player's selected wallpaper, leaving other settings intact. An empty or invalid
---value is ignored rather than wiping the saved pick, so a malformed payload can't reset the
---phone's look.
---@param citizenid string framework per-character id
---@param value string wallpaper key
function store.setWallpaper(citizenid, value)
    if not citizenid or citizenid == '' then return end
    local clean = sanitizeWallpaper(value)
    if not clean then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, wallpaper) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE wallpaper = VALUES(wallpaper)
    ]], { citizenid, clean })
end

---Clamp the chat-bubble text multiplier to the UI's supported range (0.8-1.5). Returns nil for
---non-numbers and NaN (a crafted NaN would pass both range checks and error the DECIMAL(3,2)
---write) so a bad payload leaves the stored value be; infinities fall to the nearest bound.
---@param v any client-supplied scale
---@return number|nil scale clamped multiplier, nil if unusable
local function clampChatTextScale(v)
    local n = tonumber(v)
    if not n or n ~= n then return nil end
    if n < 0.8 then n = 0.8 elseif n > 1.5 then n = 1.5 end
    return n
end

---Read a player's chat-bubble text size multiplier, or nil if unset (the frontend then keeps
---its 1x default). tonumber-coerced because DECIMAL columns can come back as strings. Read-only.
---@param citizenid string framework per-character id
---@return number|nil scale saved multiplier
function store.getChatTextScale(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await('SELECT chat_text_scale FROM phone_settings WHERE citizenid = ?', { citizenid })
    if not row or row.chat_text_scale == nil then return nil end
    return tonumber(row.chat_text_scale)
end

---Persist a player's chat-bubble text size multiplier, leaving other settings intact. An
---out-of-range / non-numeric value is ignored.
---@param citizenid string framework per-character id
---@param scale number multiplier (clamped to 0.8-1.5)
function store.setChatTextScale(citizenid, scale)
    if not citizenid or citizenid == '' then return end
    local clean = clampChatTextScale(scale)
    if not clean then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, chat_text_scale) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE chat_text_scale = VALUES(chat_text_scale)
    ]], { citizenid, clean })
end

-- Mirrors SUPPORTED_LOCALES in web/src/i18n/index.ts - keep in lockstep with whichever
-- locales/<code>.json catalogs actually exist.
---@type table<string, boolean> Whitelist of storable phone locales.
local SUPPORTED_LOCALES = {
    en = true, fr = true, es = true, de = true, it = true,
    pt = true, nl = true, pl = true, da = true, no = true,
}

---Read a player's saved phone language, or nil if unset (the frontend then falls back to the
---server's config.Locale). Read-only.
---@param citizenid string framework per-character id
---@return string|nil locale saved locale code
function store.getLocale(citizenid)
    if not citizenid or citizenid == '' then return nil end
    local row = MySQL.single.await('SELECT locale FROM phone_settings WHERE citizenid = ?', { citizenid })
    if not row or not row.locale or row.locale == '' then return nil end
    return row.locale
end

---Persist a player's chosen phone language. Whitelist-checked against SUPPORTED_LOCALES;
---anything else is silently ignored, so only real catalog codes ever reach the column.
---@param citizenid string framework per-character id
---@param locale any client-supplied locale code
function store.setLocale(citizenid, locale)
    if not citizenid or citizenid == '' then return end
    if type(locale) ~= 'string' or not SUPPORTED_LOCALES[locale] then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, locale) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE locale = VALUES(locale)
    ]], { citizenid, locale })
end

---Clamp a passcode to a bare 4-6 digit string, or nil (= no passcode). Applied on BOTH read and
---write, so a hand-edited row can't push a weird shape into the lock UI either.
---@param v any client-supplied passcode
---@return string|nil pin 4-6 digit string, nil if unusable
local function sanitizePin(v)
    if type(v) ~= 'string' then return nil end
    return v:match('^%d%d%d%d%d?%d?$')
end

local util = require 'server.util'
local isTruthy = util.truthy

---Read a player's lock security (passcode + Face Unlock). `passcode` is nil when no code is
---set; `faceId` is forced false whenever no passcode exists, because Face Unlock is only a
---convenience layered over the passcode. Read-only.
---@param citizenid string framework per-character id
---@return { passcode: string|nil, faceId: boolean }
function store.getSecurity(citizenid)
    if not citizenid or citizenid == '' then return { passcode = nil, faceId = false } end
    local row = MySQL.single.await('SELECT passcode, face_id FROM phone_settings WHERE citizenid = ?', { citizenid })
    if not row then return { passcode = nil, faceId = false } end
    local pin = sanitizePin(row.passcode)
    return { passcode = pin, faceId = pin ~= nil and isTruthy(row.face_id) }
end

---Persist a player's lock security. A `passcode` of nil (or any non-4-6-digit shape) clears it,
---which also forces Face Unlock off - the two can never disagree in the DB.
---@param citizenid string framework per-character id
---@param passcode string|nil 4-6 digit code, nil to clear
---@param faceId boolean Face Unlock enabled (only honoured alongside a valid passcode)
function store.setSecurity(citizenid, passcode, faceId)
    if not citizenid or citizenid == '' then return end
    local pin = sanitizePin(passcode)
    local face = pin ~= nil and faceId == true
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, passcode, face_id) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE passcode = VALUES(passcode), face_id = VALUES(face_id)
    ]], { citizenid, pin, face and 1 or 0 })
end

---Read a player's saved tone selections. Fields are nil when unset, letting the frontend fall
---back to its catalog defaults. Read-only.
---@param citizenid string framework per-character id
---@return { ringtone: string|nil, notificationTone: string|nil }
function store.getTones(citizenid)
    if not citizenid or citizenid == '' then return {} end
    local row = MySQL.single.await(
        'SELECT ringtone, notification_tone FROM phone_settings WHERE citizenid = ?',
        { citizenid }
    )
    return {
        ringtone         = row and row.ringtone or nil,
        notificationTone = row and row.notification_tone or nil,
    }
end

-- Airplane mode, cached in-memory so the per-message / per-call routing checks don't hit the DB.
-- The DB is the durable copy so the toggle survives relog / restart. Keyed by citizenid (not
-- src), so recycled server ids can't collide; entries are single booleans that live for the
-- resource's lifetime.
---@type table<string, boolean> Cached airplane-mode flag per citizenid.
local airplaneCache = {}

---True if a player currently has airplane mode on. Lazily warms the cache from the DB on first
---read; the TINYINT(1) column is decoded via isTruthy because oxmysql returns it as a Lua
---boolean on some builds and 1/0 on others.
---@param citizenid string framework per-character id
---@return boolean on
function store.isAirplane(citizenid)
    if not citizenid or citizenid == '' then return false end
    local cached = airplaneCache[citizenid]
    if cached ~= nil then return cached end
    local row = MySQL.single.await('SELECT airplane_mode FROM phone_settings WHERE citizenid = ?', { citizenid })
    local on = row ~= nil and isTruthy(row.airplane_mode)
    airplaneCache[citizenid] = on
    return on
end

---Set a player's airplane mode: cache first (so routing checks flip instantly), then the DB
---write-through for durability.
---@param citizenid string framework per-character id
---@param on boolean airplane mode enabled
function store.setAirplane(citizenid, on)
    if not citizenid or citizenid == '' then return end
    on = on == true
    airplaneCache[citizenid] = on
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, airplane_mode) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE airplane_mode = VALUES(airplane_mode)
    ]], { citizenid, on and 1 or 0 })
end

---The server default 24-hour preference for a player who has never toggled it
---(config.Lockscreen.Use24Hour).
---@return boolean default
local function defaultHour24()
    return (config.Lockscreen and config.Lockscreen.Use24Hour) == true
end

---True if a player prefers 24-hour time. Falls back to the server's configured default while the
---player has never set it (hour24 column is NULL). Accepts both TINYINT(1) shapes oxmysql may
---return. Read-only.
---@param citizenid string framework per-character id
---@return boolean hour24
function store.getHour24(citizenid)
    if not citizenid or citizenid == '' then return defaultHour24() end
    local row = MySQL.single.await('SELECT hour24 FROM phone_settings WHERE citizenid = ?', { citizenid })
    if row and row.hour24 ~= nil then
        return row.hour24 == true or tonumber(row.hour24) == 1
    end
    return defaultHour24()
end

---Persist a player's 24-hour time preference (upsert). Coerced to a strict boolean so any
---non-true payload stores as 0.
---@param citizenid string framework per-character id
---@param on boolean prefer 24-hour time
function store.setHour24(citizenid, on)
    if not citizenid or citizenid == '' then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, hour24) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE hour24 = VALUES(hour24)
    ]], { citizenid, on == true and 1 or 0 })
end

---Persist a player's tone selections, leaving any other settings intact. A nil (or invalid)
---field is left unchanged rather than wiped - the COALESCE keeps the stored value when the
---sanitiser returns nil - so the UI can update one tone without resending the other.
---@param citizenid string framework per-character id
---@param ringtone string|nil ringtone slug
---@param notificationTone string|nil notification tone slug
function store.setTones(citizenid, ringtone, notificationTone)
    if not citizenid or citizenid == '' then return end
    local r = sanitizeTone(ringtone)
    local n = sanitizeTone(notificationTone)
    if not r and not n then return end
    MySQL.update.await([[
        INSERT INTO phone_settings (citizenid, ringtone, notification_tone)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE
            ringtone          = COALESCE(VALUES(ringtone), ringtone),
            notification_tone = COALESCE(VALUES(notification_tone), notification_tone)
    ]], { citizenid, r, n })
end

---@type integer Cap on saved custom tones per character per kind - bounds table growth from a
---spammed tones:add.
local MAX_CUSTOM_TONES = 30

---Normalise a tone kind to one of the two valid values - anything that isn't exactly
---'notification' is a ringtone, so an arbitrary client string can't mint new kinds.
---@param kind any client-supplied kind
---@return string kind 'ringtone' or 'notification'
local function normKind(kind)
    return kind == 'notification' and 'notification' or 'ringtone'
end

---List a player's custom (YouTube) tones of a kind, oldest first. Read-only, scoped to the
---caller's citizenid.
---@param citizenid string framework per-character id
---@param kind 'ringtone'|'notification'
---@return { id: string, name: string, url: string }[]
function store.listCustomTones(citizenid, kind)
    if not citizenid or citizenid == '' then return {} end
    local rows = MySQL.query.await(
        'SELECT id, name, url FROM phone_custom_ringtones WHERE citizenid = ? AND kind = ? ORDER BY created_at ASC',
        { citizenid, normKind(kind) }
    )
    return rows or {}
end

---Save a custom tone for a player. Every field is clamped to its column size (id additionally
---stripped to filename-safe chars) and the per-kind list is capped at MAX_CUSTOM_TONES. The
---upsert keys on (citizenid, id), so re-adding an existing id updates it in place - though at
---the cap even that re-add is rejected, a quirk accepted to keep the check simple. The cap is
---check-then-insert, so two simultaneous adds can land one over it - harmless for a cosmetic
---list.
---@param citizenid string framework per-character id
---@param kind 'ringtone'|'notification'
---@param id string tone id (clamped to 32 [a-zA-Z0-9_-] chars)
---@param name string display name (clamped to 64 chars)
---@param url string audio URL (clamped to 512 chars)
---@return boolean ok false when a field is unusable or the cap is hit
function store.addCustomTone(citizenid, kind, id, name, url)
    if not citizenid or citizenid == '' then return false end
    local k         = normKind(kind)
    local cleanId   = type(id) == 'string'   and ((id:gsub('[^a-zA-Z0-9_-]', '')):sub(1, 32)) or ''
    local cleanName = type(name) == 'string' and name:sub(1, 64)  or ''
    local cleanUrl  = type(url) == 'string'  and url:sub(1, 512) or ''
    if cleanId == '' or cleanName == '' or cleanUrl == '' then return false end

    local countRow = MySQL.single.await(
        'SELECT COUNT(*) AS n FROM phone_custom_ringtones WHERE citizenid = ? AND kind = ?',
        { citizenid, k }
    )
    if countRow and tonumber(countRow.n) >= MAX_CUSTOM_TONES then return false end

    MySQL.update.await([[
        INSERT INTO phone_custom_ringtones (citizenid, id, kind, name, url)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE kind = VALUES(kind), name = VALUES(name), url = VALUES(url)
    ]], { citizenid, cleanId, k, cleanName, cleanUrl })
    return true
end

---Remove one of a player's custom tones. The delete is keyed on (citizenid, id), so a client can
---only ever remove its own rows no matter what id it sends.
---@param citizenid string framework per-character id
---@param id string tone id
function store.removeCustomTone(citizenid, id)
    if not citizenid or citizenid == '' or type(id) ~= 'string' or id == '' then return end
    MySQL.update.await(
        'DELETE FROM phone_custom_ringtones WHERE citizenid = ? AND id = ?',
        { citizenid, id }
    )
end

return store
