---@type table Store module; the table returned at end of file.
local store = {}

---Create the phone_bank_transactions table if it doesn't exist, so the resource is drop-in.
---The phone owns this table because most banking resources don't expose a portable transaction
---history: the phone records an entry for every transfer it makes, and external resources append
---their own rows through the addBankTransaction export. One row per SIDE of a transfer (the
---sender gets a debit, the recipient a credit), each keyed to its own citizenid. Run once at boot.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `phone_bank_transactions` (
            `id`           INT AUTO_INCREMENT PRIMARY KEY,
            `citizenid`    VARCHAR(64)  NOT NULL,
            `label`        VARCHAR(120) NOT NULL,
            `amount`       BIGINT       NOT NULL,
            `category`     VARCHAR(32)  NOT NULL DEFAULT 'transfer',
            `counterparty` VARCHAR(64)  NULL,
            `created_at`   BIGINT       NOT NULL,
            KEY `citizenid` (`citizenid`),
            KEY `created_at` (`created_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

---Append one transaction row. `amount` is a signed whole-currency value: negative = outflow,
---positive = inflow. The caller validates and caps every field to its column width
---(server.banking.actions does); we keep the data layer dumb.
---@param citizenid string owning character's citizenid
---@param label string display label (VARCHAR(120))
---@param amount integer signed whole-currency amount
---@param category string|nil category slug, defaults to 'transfer' (VARCHAR(32))
---@param counterparty string|nil other party's bare-digit phone number, if any (VARCHAR(64))
---@param ts integer unix-seconds timestamp
---@return integer insertId
function store.insert(citizenid, label, amount, category, counterparty, ts)
    return MySQL.insert.await(
        'INSERT INTO `phone_bank_transactions` (citizenid, label, amount, category, counterparty, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        { citizenid, label, amount, category or 'transfer', counterparty, ts })
end

---Most-recent `limit` transactions for a character, newest-first by insert id (so two rows
---sharing a same-second timestamp still order deterministically). Read-only.
---@param citizenid string owning character's citizenid
---@param limit integer row cap (Banking.TransactionLimit at the call site)
---@return table[] rows raw DB rows, {} when none
function store.recent(citizenid, limit)
    return MySQL.query.await(
        'SELECT * FROM `phone_bank_transactions` WHERE citizenid = ? ORDER BY id DESC LIMIT ?',
        { citizenid, limit }) or {}
end

return store
