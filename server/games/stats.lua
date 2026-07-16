---@type table Stats module; the table returned at end of file. Unified per-character game stats
---(W/L/D, split vs-Computer / Online, cumulative chip amounts, and a single-player high score)
---shared by every game (chess, connectfour, blackjack, blocks, flappy, ...). One row per
---(citizenid, game).
local stats = {}

---Create the stats table if it doesn't exist, back-fill the chip-amount + high-score columns on
---tables created before they existed (ADD COLUMN IF NOT EXISTS is a no-op once applied, pcall'd for
---servers whose MariaDB predates it), and copy legacy chess records over once. The backfill is
---INSERT IGNORE keyed on (citizenid, game), so it's safe to run on every boot - live rows win - and
---the legacy `phone_chess_stats` table is left intact (copy, not move).
function stats.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_game_stats (
            citizenid     VARCHAR(64) NOT NULL,
            game          VARCHAR(32) NOT NULL,
            name          VARCHAR(64) NULL,
            cpu_wins      INT NOT NULL DEFAULT 0,
            cpu_losses    INT NOT NULL DEFAULT 0,
            cpu_draws     INT NOT NULL DEFAULT 0,
            online_wins   INT NOT NULL DEFAULT 0,
            online_losses INT NOT NULL DEFAULT 0,
            online_draws  INT NOT NULL DEFAULT 0,
            chips_won     BIGINT NOT NULL DEFAULT 0,
            chips_lost    BIGINT NOT NULL DEFAULT 0,
            high_score    BIGINT NOT NULL DEFAULT 0,
            plays         INT NOT NULL DEFAULT 0,
            last_score    BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY (citizenid, game)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    pcall(MySQL.query.await, [[
        ALTER TABLE phone_game_stats
            ADD COLUMN IF NOT EXISTS chips_won  BIGINT NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS chips_lost BIGINT NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS high_score BIGINT NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS plays      INT NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS last_score BIGINT NOT NULL DEFAULT 0
    ]])
    local legacy = MySQL.single.await([[
        SELECT COUNT(*) AS n FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = 'phone_chess_stats'
    ]])
    if legacy and tonumber(legacy.n) > 0 then
        MySQL.query.await([[
            INSERT IGNORE INTO phone_game_stats
                (citizenid, game, name, cpu_wins, cpu_losses, cpu_draws, online_wins, online_losses, online_draws)
            SELECT citizenid, 'chess', name, cpu_wins, cpu_losses, cpu_draws, online_wins, online_losses, online_draws
            FROM phone_chess_stats
        ]])
    end
end

---Read a player's stats for one game: { cpu = {wins,losses,draws}, online = {...}, won, lost, high }
---where won/lost are cumulative chips for the gambling games and high is the single-player high
---score. A non-string game id (the value is client-supplied) skips the query and returns the zero
---shape - a table parameter would error inside oxmysql. Read-only.
---@param cid string citizenid
---@param game any game id (client-supplied)
---@return table stats zero-filled when the row (or a valid game id) doesn't exist
function stats.statsFor(cid, game)
    local r = type(game) == 'string'
        and MySQL.single.await('SELECT * FROM phone_game_stats WHERE citizenid = ? AND game = ?', { cid, game })
        or nil
    return {
        cpu    = { wins = r and r.cpu_wins or 0,    losses = r and r.cpu_losses or 0,    draws = r and r.cpu_draws or 0 },
        online = { wins = r and r.online_wins or 0, losses = r and r.online_losses or 0, draws = r and r.online_draws or 0 },
        won    = r and tonumber(r.chips_won)  or 0,
        lost   = r and tonumber(r.chips_lost) or 0,
        high   = r and tonumber(r.high_score) or 0,
        plays  = r and tonumber(r.plays)      or 0,
        last   = r and tonumber(r.last_score) or 0,
    }
end

-- The column an increment lands in is interpolated into SQL, so it must only ever come from this
-- fixed whitelist - never from input. Unknown mode/result pairs fall out as nil and are rejected.
---@type table<string, table<string, string>> mode -> result -> column name.
local STAT_COL = {
    cpu    = { win = 'cpu_wins',    loss = 'cpu_losses',    draw = 'cpu_draws' },
    online = { win = 'online_wins', loss = 'online_losses', draw = 'online_draws' },
}

---@type integer Max absolute chip swing credited to the boards per recorded result.
local AMOUNT_MAX = 1000000

---@type integer Max high score accepted per submission - a coarse ceiling that stops a tampered
---client poisoning the board with an absurd value, well above any real arcade run.
local SCORE_MAX = 100000000

---Increment one result column and return the updated stats. Everything client-supplied is fenced:
---mode/result must hit the STAT_COL whitelist, the game id must be a string that fits its
---VARCHAR(32) column, the name is capped to VARCHAR(64), and `amount` (the net chips for this
---result: positive adds to chips_won, negative to chips_lost by magnitude) is clamped to
---AMOUNT_MAX with NaN/inf collapsing to 0 rather than resolving to the clamp boundary. Returns
---nil on a bad mode/result/game so the caller can reject the report.
---@param cid string citizenid
---@param game any game id (client-supplied)
---@param mode any 'cpu' | 'online' (client-supplied)
---@param result any 'win' | 'loss' | 'draw' (client-supplied)
---@param name string display name for the boards (server-resolved)
---@param amount any net chip swing (client-supplied)
---@return table|nil stats updated stats, nil when the report is malformed
function stats.record(cid, game, mode, result, name, amount)
    if type(game) ~= 'string' or game == '' or #game > 32 then return nil end
    local col = STAT_COL[mode] and STAT_COL[mode][result]
    if not col then return nil end
    name = type(name) == 'string' and name:sub(1, 64) or nil
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then amount = 0 end
    amount = math.max(-AMOUNT_MAX, math.min(AMOUNT_MAX, math.floor(amount)))
    local won  = math.max(amount, 0)
    local lost = math.max(-amount, 0)
    MySQL.query.await((
        'INSERT INTO phone_game_stats (citizenid, game, name, %s, chips_won, chips_lost) VALUES (?, ?, ?, 1, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE name = VALUES(name), %s = %s + 1, ' ..
        'chips_won = chips_won + VALUES(chips_won), chips_lost = chips_lost + VALUES(chips_lost)'
    ):format(col, col, col), { cid, game, name, won, lost })
    return stats.statsFor(cid, game)
end

---Submit a single-player run, tracking the best score, the play count and the most recent score.
---Everything client-supplied is fenced: the game id must be a string that fits its column, the name
---is capped, and `score` is coerced to a whole non-negative int clamped to SCORE_MAX (NaN/inf
---collapse to 0). The upsert keeps the GREATEST of the stored and submitted score (a lower run never
---lowers a record), increments plays, and stores the run as last_score. Returns { best, isRecord,
---plays, last } (best/plays after this submit, isRecord = it beat the previous best), or nil on a
---malformed game id so the caller can reject the report.
---@param cid string citizenid
---@param game any game id (client-supplied)
---@param score any score (client-supplied)
---@param name string display name for the board (server-resolved)
---@return { best: integer, isRecord: boolean, plays: integer, last: integer }|nil
function stats.submitScore(cid, game, score, name)
    if type(game) ~= 'string' or game == '' or #game > 32 then return nil end
    name = type(name) == 'string' and name:sub(1, 64) or nil
    score = tonumber(score)
    if not score or score ~= score or score == math.huge or score == -math.huge then score = 0 end
    score = math.max(0, math.min(SCORE_MAX, math.floor(score)))

    local prevRow = MySQL.single.await(
        'SELECT high_score, plays FROM phone_game_stats WHERE citizenid = ? AND game = ?', { cid, game })
    local prevHigh  = prevRow and tonumber(prevRow.high_score) or 0
    local prevPlays = prevRow and tonumber(prevRow.plays) or 0

    MySQL.query.await([[
        INSERT INTO phone_game_stats (citizenid, game, name, high_score, plays, last_score) VALUES (?, ?, ?, ?, 1, ?)
        ON DUPLICATE KEY UPDATE
            name       = VALUES(name),
            high_score = GREATEST(high_score, VALUES(high_score)),
            plays      = plays + 1,
            last_score = VALUES(last_score)
    ]], { cid, game, name, score, score })

    return { best = math.max(prevHigh, score), isRecord = score > prevHigh, plays = prevPlays + 1, last = score }
end

---Global leaderboards for a game (all players): `cpu`/`online` ranked by wins, `winners`/`losers`
---ranking the gambling games by net chips (won - lost). The interpolated identifiers are literal
---arguments at the two inner call sites - never input; the game id itself rides as a `?` param,
---and a non-string one returns the empty shape without touching SQL. Read-only.
---@param game any game id (client-supplied)
---@return table boards { cpu, online, winners, losers }
function stats.leaderboard(game)
    if type(game) ~= 'string' then return { cpu = {}, online = {}, winners = {}, losers = {} } end
    local function wlBoard(winCol, lossCol)
        return MySQL.query.await((
            'SELECT name, %s AS wins, %s AS losses FROM phone_game_stats ' ..
            'WHERE game = ? AND (%s + %s) > 0 ORDER BY %s DESC, %s ASC LIMIT 20'
        ):format(winCol, lossCol, winCol, lossCol, winCol, lossCol), { game }) or {}
    end
    local function chipBoard(cmp, order)
        return MySQL.query.await((
            'SELECT name, chips_won AS won, chips_lost AS lost, (chips_won - chips_lost) AS net ' ..
            'FROM phone_game_stats WHERE game = ? AND (chips_won - chips_lost) %s 0 ' ..
            'ORDER BY net %s LIMIT 20'
        ):format(cmp, order), { game }) or {}
    end
    return {
        cpu     = wlBoard('cpu_wins', 'cpu_losses'),
        online  = wlBoard('online_wins', 'online_losses'),
        winners = chipBoard('>', 'DESC'),
        losers  = chipBoard('<', 'ASC'),
    }
end

---Global high-score board for a game: top 20 players by high score (only those with a score).
---Non-string game id returns the empty board without touching SQL. Read-only; exposes only display
---names and scores.
---@param game any game id (client-supplied)
---@return { name: string, score: integer }[]
function stats.scoreboard(game)
    if type(game) ~= 'string' then return {} end
    return MySQL.query.await([[
        SELECT name, high_score AS score FROM phone_game_stats
        WHERE game = ? AND high_score > 0
        ORDER BY high_score DESC LIMIT 20
    ]], { game }) or {}
end

return stats
