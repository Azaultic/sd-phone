---@type table Store module; the table returned at end of file.
local store = {}

---Create the save table if it doesn't exist and back-fill the nickname column on tables created
---before it existed, so the resource is drop-in. One row per character holds the whole save:
---spendable `cookies`, lifetime `earned` (drives achievements and the leaderboard), owned
---upgrades + unlocked achievements as JSON, and the rain toggle. `name` is denormalised so the
---leaderboard can list offline players. Counts are DOUBLE - idle play pushes them past INT
---range, and the UI only ever shows abbreviated values so float precision is fine. Run once at
---boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `phone_cookie` (
            `citizenid`    VARCHAR(60) NOT NULL,
            `name`         VARCHAR(60) NULL,
            `nickname`     VARCHAR(40) NULL,
            `cookies`      DOUBLE      NOT NULL DEFAULT 0,
            `earned`       DOUBLE      NOT NULL DEFAULT 0,
            `owned`        TEXT        NULL,
            `achievements` TEXT        NULL,
            `rain_on`      TINYINT(1)  NOT NULL DEFAULT 1,
            `updated_at`   BIGINT      NOT NULL,
            PRIMARY KEY (`citizenid`),
            KEY `earned` (`earned`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    local col = MySQL.scalar.await([[
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'phone_cookie' AND column_name = 'nickname' AND table_schema = DATABASE()
    ]])
    if not col then
        MySQL.query.await('ALTER TABLE `phone_cookie` ADD COLUMN `nickname` VARCHAR(40) NULL AFTER `name`')
    end
end

---A character's full save row, or nil when they've never played. Caller decodes the JSON
---columns; the data layer stays dumb. Read-only.
---@param cid string framework per-character id
---@return table|nil row
function store.get(cid)
    return MySQL.single.await('SELECT * FROM `phone_cookie` WHERE citizenid = ?', { cid })
end

---Persist one save (upsert). Values arrive pre-clamped and pre-encoded from the actions layer.
---@param cid string framework per-character id
---@param name string|nil character display-name snapshot
---@param cookies number spendable balance
---@param earned number lifetime total
---@param ownedJson string owned upgrades as JSON
---@param achJson string unlocked achievements as JSON
---@param rainOn integer rain toggle, 1/0
---@param ts integer unix seconds updated stamp
function store.save(cid, name, cookies, earned, ownedJson, achJson, rainOn, ts)
    MySQL.query.await([[
        INSERT INTO `phone_cookie` (citizenid, name, cookies, earned, owned, achievements, rain_on, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            name         = VALUES(name),
            cookies      = VALUES(cookies),
            earned       = VALUES(earned),
            owned        = VALUES(owned),
            achievements = VALUES(achievements),
            rain_on      = VALUES(rain_on),
            updated_at   = VALUES(updated_at)
    ]], { cid, name, cookies, earned, ownedJson, achJson, rainOn, ts })
end

---Top `limit` other players by total baked, excluding the caller (the client splices itself in
---live). Only display fields leave the table - never citizenids. Read-only.
---@param limit integer row cap
---@param excludeCid string caller's citizenid ('' when unresolvable)
---@return table rows { name, nickname, earned }[]
function store.topRivals(limit, excludeCid)
    return MySQL.query.await(
        'SELECT `name`, `nickname`, `earned` FROM `phone_cookie` WHERE citizenid != ? AND earned > 0 ORDER BY earned DESC LIMIT ?',
        { excludeCid, limit }) or {}
end

---Set (or clear, when nil) the caller's custom leaderboard alias. Upserts so an alias can be
---set before the first save row exists.
---@param cid string framework per-character id
---@param nickname string|nil validated alias (nil clears)
function store.setNickname(cid, nickname)
    MySQL.query.await([[
        INSERT INTO `phone_cookie` (citizenid, nickname, updated_at) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE nickname = VALUES(nickname)
    ]], { cid, nickname, os.time() })
end

return store
