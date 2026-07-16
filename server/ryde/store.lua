---@type table Store module; the table returned at end of file.
local store = {}


local util = require 'server.util'
local function newId() return util.newId(12) end

store.newId = newId

---Create every Ryde table idempotently, so the resource is drop-in. Run once at boot. Driver
---identity is the Ryde *account* username (the shared accounts engine), not the citizenid - a
---player keeps their driver record across characters as long as they sign into the same Ryde
---account. Rides key the rider by citizenid and the driver by username, hence the two indexes.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_ryde_drivers (
            username       VARCHAR(64)  NOT NULL,
            display_name   VARCHAR(64)  NOT NULL DEFAULT '',
            vehicle        VARCHAR(64)  NOT NULL DEFAULT '',
            plate          VARCHAR(16)  NOT NULL DEFAULT '',
            color          VARCHAR(16)  NOT NULL DEFAULT '#111111',
            rating_sum     INT          NOT NULL DEFAULT 0,
            rating_count   INT          NOT NULL DEFAULT 0,
            trips          INT          NOT NULL DEFAULT 0,
            earnings_total DECIMAL(12,2) NOT NULL DEFAULT 0,
            created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_ryde_rides (
            id              VARCHAR(16)  NOT NULL,
            rider_username  VARCHAR(64)  NOT NULL,
            rider_name      VARCHAR(64)  NOT NULL DEFAULT '',
            driver_username VARCHAR(64)  NULL,
            driver_name     VARCHAR(64)  NOT NULL DEFAULT '',
            pickup_label    VARCHAR(96)  NOT NULL DEFAULT '',
            pickup_x        FLOAT        NOT NULL DEFAULT 0,
            pickup_y        FLOAT        NOT NULL DEFAULT 0,
            dropoff_label   VARCHAR(96)  NOT NULL DEFAULT '',
            dropoff_x       FLOAT        NOT NULL DEFAULT 0,
            dropoff_y       FLOAT        NOT NULL DEFAULT 0,
            distance        FLOAT        NOT NULL DEFAULT 0,
            fare            DECIMAL(10,2) NOT NULL DEFAULT 0,
            payment         VARCHAR(8)   NOT NULL DEFAULT 'cash',
            paid            TINYINT(1)   NOT NULL DEFAULT 0,
            status          VARCHAR(16)  NOT NULL DEFAULT 'completed',
            rating          TINYINT      NULL,
            created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            completed_at    TIMESTAMP    NULL,
            PRIMARY KEY (id),
            INDEX idx_ryde_rides_rider  (rider_username),
            INDEX idx_ryde_rides_driver (driver_username)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    util.ensureIndex('phone_ryde_rides', 'idx_ryde_rides_rider_recent', '(rider_username, created_at)')
end

---Fetch a driver record by account username. Read-only.
---@param username string
---@return table|nil
function store.getDriver(username)
    return MySQL.single.await('SELECT * FROM phone_ryde_drivers WHERE username = ?', { username })
end

---Remove a driver record (on account deletion). Past rides are left intact - they're shared
---history with the rider, and the driver simply drops off the leaderboard once their row is gone.
---@param username string
function store.deleteDriver(username)
    MySQL.query.await('DELETE FROM phone_ryde_drivers WHERE username = ?', { username })
end

---Create or update a driver's profile (vehicle details), preserving stats - the upsert only
---touches the cosmetic columns, never the rating/trip/earnings counters.
---@param username string
---@param displayName string
---@param vehicle string
---@param plate string
---@param color string
function store.upsertDriver(username, displayName, vehicle, plate, color)
    MySQL.query.await([[
        INSERT INTO phone_ryde_drivers (username, display_name, vehicle, plate, color)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            display_name = VALUES(display_name),
            vehicle      = VALUES(vehicle),
            plate        = VALUES(plate),
            color        = VALUES(color)
    ]], { username, displayName, vehicle, plate, color })
end

---Credit a completed trip to a driver: one more trip, plus their earnings (0 when the fare
---couldn't be collected - the trip still counts, the money doesn't).
---@param username string
---@param earnings number
function store.bumpDriverStats(username, earnings)
    MySQL.update.await([[
        UPDATE phone_ryde_drivers
        SET trips = trips + 1, earnings_total = earnings_total + ?
        WHERE username = ?
    ]], { earnings, username })
end

---Fold a rider's star rating into the driver's running average (sum + count, so the average is
---derived at read time and never drifts).
---@param username string
---@param stars number
function store.addRating(username, stars)
    MySQL.update.await([[
        UPDATE phone_ryde_drivers
        SET rating_sum = rating_sum + ?, rating_count = rating_count + 1
        WHERE username = ?
    ]], { stars, username })
end

---Persist a finished (or cancelled) ride. Live requests and in-flight trips are deliberately
---never written - only terminal states reach this table.
---@param r table trip record from server.ryde.actions
function store.insertRide(r)
    MySQL.insert.await([[
        INSERT INTO phone_ryde_rides
            (id, rider_username, rider_name, driver_username, driver_name,
             pickup_label, pickup_x, pickup_y, dropoff_label, dropoff_x, dropoff_y,
             distance, fare, payment, paid, status, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        r.id, r.riderUsername, r.riderName, r.driverUsername, r.driverName,
        r.pickup.label, r.pickup.x, r.pickup.y, r.dropoff.label, r.dropoff.x, r.dropoff.y,
        r.distance, r.fare, r.payment, r.paid and 1 or 0, r.status,
    })
end

---Fetch one ride row by id. The caller owns the ownership check (rider_username vs the caller's
---citizenid); the data layer stays dumb. Read-only.
---@param rideId string
---@return table|nil
function store.getRide(rideId)
    return MySQL.single.await('SELECT * FROM phone_ryde_rides WHERE id = ?', { rideId })
end

---Attach a rider's star rating to a ride, but only if it has none yet - the IS NULL predicate
---makes the write single-shot at the DB level, so the returned affected-row count is the
---caller's replay/race guard (0 means someone already rated it).
---@param rideId string
---@param stars number
---@return number affected rows
function store.setRideRating(rideId, stars)
    return MySQL.update.await(
        'UPDATE phone_ryde_rides SET rating = ? WHERE id = ? AND rating IS NULL',
        { stars, rideId }
    )
end

---Every ride a player took part in, newest first (capped at 100). Riders are keyed by citizenid,
---drivers by account username, so the two keys can differ for one caller. Read-only.
---@param riderKey string citizenid
---@param driverKey string account username (falls back to citizenid)
---@return table[]
function store.ridesForUser(riderKey, driverKey)
    return MySQL.query.await([[
        SELECT * FROM phone_ryde_rides
        WHERE rider_username = ? OR driver_username = ?
        ORDER BY created_at DESC
        LIMIT 100
    ]], { riderKey, driverKey }) or {}
end

---The rider's most recent ride (any status). Used to resolve a trip that ended while their phone
---was closed: if it matches the stale local ride's trip id, the client knows whether it
---completed (rate it) or was cancelled. Read-only.
---@param riderKey string citizenid
---@return table|nil
function store.latestRiderRide(riderKey)
    return MySQL.single.await([[
        SELECT id, status, fare, paid, driver_name
        FROM phone_ryde_rides
        WHERE rider_username = ?
        ORDER BY created_at DESC
        LIMIT 1
    ]], { riderKey })
end

---Top drivers server-wide, ranked by a confidence-weighted rating then trip count, so one lucky
---5-star can't outrank a high-volume driver (see configs/ryde.lua for the formula). Drivers with
---no ratings yet score a provisional 5 so a new driver isn't buried. Read-only.
---@param limit number max rows
---@param prior number confidence-weighting prior rating (configs.ryde LeaderboardPriorRating)
---@param weight number confidence weight in trips (configs.ryde LeaderboardWeight)
---@return table[]
function store.leaderboard(limit, prior, weight)
    return MySQL.query.await([[
        SELECT username, display_name, color, trips, earnings_total,
               CASE WHEN rating_count > 0 THEN rating_sum / rating_count ELSE 5 END AS avg_rating,
               (((CASE WHEN rating_count > 0 THEN rating_sum / rating_count ELSE 5 END) * trips + ?) / (trips + ?)) AS weighted
        FROM phone_ryde_drivers
        WHERE trips > 0
        ORDER BY weighted DESC, trips DESC
        LIMIT ?
    ]], { prior * weight, weight, limit }) or {}
end

return store
