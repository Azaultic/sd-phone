---@type table Store module; the table returned at end of file.
local store = {}

---Create the phone_map_markers table if it doesn't exist, so the resource is drop-in. One row
---per citizenid holding that player's whole pin set as a JSON array - the client always sends
---the complete array on save, so per-pin rows would buy nothing. Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `phone_map_markers` (
            `citizenid`  VARCHAR(60) NOT NULL,
            `markers`    MEDIUMTEXT  NOT NULL,
            `updated_at` VARCHAR(40) NOT NULL,
            PRIMARY KEY (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

---A player's stored markers as a raw JSON string (nil if none saved yet).
---Caller decodes; we keep the data layer dumb. Read-only.
---@param cid string framework per-character id
---@return string|nil json JSON-encoded array of markers
function store.forPlayer(cid)
    return MySQL.scalar.await('SELECT markers FROM `phone_map_markers` WHERE citizenid = ?', { cid })
end

---Persist a player's whole marker set (upsert). The row is overwritten wholesale on every save;
---the actions layer has already sanitized and capped the array, so the data layer stays dumb.
---@param cid string framework per-character id
---@param markersJson string JSON-encoded array of sanitized markers
---@param updatedAt string ISO-8601 timestamp
function store.save(cid, markersJson, updatedAt)
    MySQL.query.await([[
        INSERT INTO `phone_map_markers` (citizenid, markers, updated_at)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE
            markers    = VALUES(markers),
            updated_at = VALUES(updated_at)
    ]], { cid, markersJson, updatedAt })
end

return store
