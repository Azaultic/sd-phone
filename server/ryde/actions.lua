---@type table Player bridge (bridge.server.player): citizenid/name/live-source lookups.
local player    = require 'bridge.server.player'
---@type table Shared app-accounts store (server.accounts.store): signed-in session -> account rows.
local acctStore = require 'server.accounts.store'
---@type table Money bridge (bridge.server.money): framework-agnostic bank debits/credits.
local money     = require 'bridge.server.money'
---@type table Ryde persistence layer (server.ryde.store): driver profiles + finished rides.
local store     = require 'server.ryde.store'
---@type table Settings store (server.settings.store): phone-number provisioning for trip cards.
local settings  = require 'server.settings.store'
---@type table Banking actions (server.banking.actions): phone Wallet transaction log entries.
local bank      = require 'server.banking.actions'
---@type table Ryde config (configs/ryde.lua): destinations, fare rails, driver cut, leaderboard.
local config    = require 'configs.ryde'

---@type table Actions module; the table returned at end of file.
local actions = {}

-- Live matching state. Authoritative and in-memory only - a request or an in-flight trip is
-- meaningless across a restart, so only finished rides are persisted (see store.insertRide).
-- Driver-side keys are the Ryde account username; the citizenid is stored alongside so the live
-- source can be re-resolved on every push (reconnect-safe). Riders need no account and are keyed
-- by citizenid throughout.
---@type table<string, table> On-duty drivers by username: { cid, name, vehicle, plate, color, rating, since }.
local online       = {}
---@type table<string, table> Pending ride requests by id (no driver locked in yet).
local requests     = {}
---@type table<string, table> Engaged trips by id (offered -> enroute_pickup -> arriving -> in_progress -> completed).
local trips        = {}
---@type table<string, string> The request/trip id a rider (citizenid) is currently in.
local riderActive  = {}
---@type table<string, string> The trip id a driver (username) is currently on.
local driverActive = {}
---@type table<integer, string> Citizenid per live src, cached so disconnect cleanup stays reliable.
local srcCid       = {}
---@type table<integer, table> { tripId, role } per src while they watch a trip map (gates the live peer stream).
local tripViewers  = {}

---@type string Client event prefix every Ryde push goes out under.
local EV = 'sd-phone:client:ryde:'

local util = require 'server.util'
local ok, fail = util.ok, util.fail


---Coerce a client-supplied value to a finite number, rejecting non-numbers, NaN and the
---infinities. NaN in particular slips plain < / > range checks (every comparison on it is
---false), so money amounts, stars and coordinates must pass through here before any arithmetic
---or DB write.
---@param v any
---@return number|nil n the finite number, nil when unusable
local function finite(v)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

---Current server source for a citizenid, or nil when they're offline.
---@param cid string|nil
---@return integer|nil
local function srcOf(cid) return cid and player.getSourceByIdentifier(cid) or nil end

---Push an event straight to a player by citizenid. No-op when offline.
---@param cid string|nil
---@param event string suffix appended to EV
---@param data table
local function pushTo(cid, event, data)
    local src = srcOf(cid)
    if src then TriggerClientEvent(EV .. event, src, data) end
end

---Fan an event out to every on-duty driver (the live requests board). A driver whose live source
---can't be resolved is logged rather than evicted here - onPlayerDropped owns removing them.
---@param event string suffix appended to EV
---@param data table
local function broadcastToDrivers(event, data)
    for _, d in pairs(online) do
        local src = srcOf(d.cid)
        if src then
            TriggerClientEvent(EV .. event, src, data)
        else
            print(('^1[sd-phone:ryde]^0 online driver %s could not be reached (no live source)'):format(d.cid))
        end
    end
end

---How many riders are waiting on the open board right now (no driver locked in).
---@return integer
local function waitingCount()
    local n = 0
    for _ in pairs(requests) do n = n + 1 end
    return n
end

---Tell every player how many riders are waiting. Off-duty drivers are dropped from the requests
---fan-out, so this is how their dashboard still sees live demand (a nudge to go online). It's
---just an integer - broadcasting to all is reconnect-safe, and non-driver clients simply ignore it.
local function broadcastWaiting()
    TriggerClientEvent(EV .. 'waitingCount', -1, { count = waitingCount() })
end

---Fire a Ryde phone notification to a player (by citizenid) for a trip milestone.
---quietInApp = true so the banner is dropped if they're already in Ryde watching it live; when
---the phone's closed it peeks / lands on the lockscreen, so a player who isn't looking (rider
---mid-trip, driver who offered then closed) still finds out.
---@param cid string|nil
---@param body string
local function notifyRyde(cid, body)
    local src = srcOf(cid)
    if not src then return end
    TriggerClientEvent('sd-phone:client:notify', src, {
        app = 'ryde', appId = 'ryde', quietInApp = true, time = 'now', title = 'Ryde', body = body,
    })
end

---Fire a Bank/Wallet notification for a Ryde money movement (logging a Wallet entry doesn't
---notify on its own). quietInApp drops it only if the player is literally in the Bank app,
---where the new row is already visible.
---@param cid string|nil
---@param body string
local function notifyBank(cid, body)
    local src = srcOf(cid)
    if not src then return end
    TriggerClientEvent('sd-phone:client:notify', src, {
        app = 'bank', appId = 'bank', quietInApp = true, time = 'now', title = 'Bank', body = body,
    })
end

---Resolve the caller's signed-in Ryde account from src alone - identity is never read from a
---payload. Returns the account with the citizenid attached as `_cid` and the display name
---resolved (displayName falling back to username), or nil when not signed in. Also refreshes the
---src -> citizenid cache used for disconnect cleanup while the source is live.
---@param src integer player server id
---@return table|nil account
local function account(src)
    local cid = player.getIdentifier(src)
    if not cid then return nil end
    local acc = acctStore.getSessionAccount('ryde', cid)
    if not acc then return nil end
    acc._cid  = cid
    acc.name  = (acc.displayName and acc.displayName ~= '') and acc.displayName or acc.username
    srcCid[src] = cid
    return acc
end

---Resolve the caller as a rider - no Ryde account required (anyone can hail a cab). Identity is
---the citizenid from src; the display name is their character name. Refreshes the disconnect
---cleanup cache the same way account() does.
---@param src integer player server id
---@return table|nil rider { cid, name }
local function rider(src)
    local cid = player.getIdentifier(src)
    if not cid then return nil end
    srcCid[src] = cid
    return { cid = cid, name = player.getName(src) }
end

---How many drivers are currently on duty.
---@return integer
local function onlineCount()
    local n = 0
    for _ in pairs(online) do n = n + 1 end
    return n
end

---Straight-line 2D distance in km between two {x, y} points. Display only - fares are
---driver-quoted, so this never feeds money math.
---@param a table
---@param b table
---@return number
local function distanceKm(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) / 1000
end

---Trim a pending request down to what a driver's board card needs. This is the shape broadcast
---to EVERY on-duty driver, so it deliberately omits the rider's citizenid and payment choice.
---@param r table request record
---@return table
local function publicRequest(r)
    return {
        id = r.id, riderName = r.riderName,
        pickup = r.pickup, dropoff = r.dropoff,
        distance = r.distance, createdAt = r.createdAt,
    }
end

---Trip as seen by one side. `role` tags which end this payload is for so the client knows
---whether to drop a driver waypoint / show a rating prompt. Each side gets the OTHER party's
---phone number so they can call/message - the rider sees the driver's, the driver the rider's,
---never both.
---@param t table trip record
---@param role string 'rider'|'driver'
---@return table
local function publicTrip(t, role)
    return {
        id = t.id, requestId = t.requestId, status = t.status, role = role,
        riderName = t.riderName, driverName = t.driverName,
        vehicle = t.vehicle, plate = t.plate, color = t.color, rating = t.driverRating,
        number = (role == 'driver') and t.riderNumber or t.driverNumber,
        fare = t.fare, payment = t.payment,
        pickup = t.pickup, dropoff = t.dropoff, distance = t.distance,
    }
end

---Tear down an engaged trip, record it as cancelled, and notify the party who didn't trigger
---the cancel. The rider's active slot is cleared only when it points at THIS trip - an offered
---trip's slot still points at the open request (the offer never claimed the rider). `by` is
---'rider' | 'driver' | 'disconnect'.
---@param trip table
---@param by string
local function cancelTrip(trip, by)
    trips[trip.id] = nil
    if riderActive[trip.riderUsername] == trip.id then riderActive[trip.riderUsername] = nil end
    driverActive[trip.driverUsername] = nil
    trip.status = 'cancelled'
    trip.paid   = false
    store.insertRide(trip)
    if by ~= 'rider' then
        pushTo(trip.riderCid,  'tripUpdate', { id = trip.id, status = 'cancelled', role = 'rider',  by = by })
    end
    if by ~= 'driver' then
        pushTo(trip.driverCid, 'tripUpdate', { id = trip.id, status = 'cancelled', role = 'driver', by = by })
    end
end

---Drop a single offered trip and free its driver. The rider's open request is left untouched
---(other offers still stand); callers notify whoever needs it. The driver took this request off
---their board when they bid, so if it is STILL open (the rider didn't accept someone else or
---cancel the whole request - both of those remove it from `requests` before offers are dropped)
---it goes back on this driver's board, so a withdrawn or declined offer doesn't make the request
---vanish for them.
---@param trip table
local function dropOffer(trip)
    trips[trip.id] = nil
    driverActive[trip.driverUsername] = nil
    local req = trip.requestId and requests[trip.requestId] or nil
    if req then
        pushTo(trip.driverCid, 'requestAdded', publicRequest(req))
    end
end

---Drop every outstanding offer on a request except `keepId` (nil = drop all), bumping each
---passed-over driver back to free with a `notify` status push.
---@param requestId string
---@param keepId string|nil
---@param notify string
local function clearOffersFor(requestId, keepId, notify)
    for id, t in pairs(trips) do
        if t.requestId == requestId and t.status == 'offered' and id ~= keepId then
            dropOffer(t)
            pushTo(t.driverCid, 'tripUpdate', { id = id, status = notify, role = 'driver' })
        end
    end
end

---Are the trip's rider and driver currently sitting in the same vehicle? Read from server-side
---OneSync entities so the client can't fake it - both must be live, both in a vehicle, and it
---must be the SAME vehicle entity. Gates starting the trip (no specific vehicle required, just a
---shared one).
---@param trip table
---@return boolean
local function inSameVehicle(trip)
    local driverSrc = srcOf(trip.driverCid)
    local riderSrc  = srcOf(trip.riderCid)
    if not (driverSrc and riderSrc) then return false end
    local dv = GetVehiclePedIsIn(GetPlayerPed(driverSrc), false)
    local rv = GetVehiclePedIsIn(GetPlayerPed(riderSrc), false)
    return dv ~= 0 and dv == rv
end

---Is a live player within `radius` metres of a world point? Server-side ped coords, so a crafted
---client call can't spoof being there.
---@param src number|nil
---@param x number
---@param y number
---@param radius number
---@return boolean
local function withinOf(src, x, y, radius)
    if not src then return false end
    local c = GetEntityCoords(GetPlayerPed(src))
    local dx, dy = c.x - x, c.y - y
    return (dx * dx + dy * dy) <= (radius * radius)
end

---A rider (no Ryde account needed) posts a ride request onto the open board - one live
---request/trip per rider, so a double-tap can't double-post. Pickup/dropoff coords are
---client-supplied by design (the pickup is the rider's own position, the dropoff a map pin) but
---are coerced to finite numbers - NaN/inf would poison the distance math, the counterpart's
---cancel/complete paths and every later DB write - and labels are type-checked + capped to the
---VARCHAR(96) ride columns. Payment is whitelisted to cash/card. Free on-duty drivers get a
---notification; drivers mid-trip only get the board update (they can't take it anyway).
---@param src integer player server id
---@param payload table { pickup: { label?, x, y }, dropoff: { label?, x, y }, payment?: string }
---@return table result { requestId } on success
function actions.requestRide(src, payload)
    local rdr = rider(src)
    if not rdr then return fail('Could not resolve your character.') end
    if riderActive[rdr.cid] then return fail('You already have an active ride.') end

    local p = type(payload) == 'table' and payload or {}
    local pickup  = type(p.pickup)  == 'table' and p.pickup  or nil
    local dropoff = type(p.dropoff) == 'table' and p.dropoff or nil
    local px = pickup and finite(pickup.x)
    local py = pickup and finite(pickup.y)
    local dx = dropoff and finite(dropoff.x)
    local dy = dropoff and finite(dropoff.y)
    if not (px and py and dx and dy) then
        return fail('Pick a destination first.')
    end

    local req = {
        id            = store.newId(),
        riderUsername = rdr.cid,
        riderName     = rdr.name,
        riderCid      = rdr.cid,
        pickup        = { label = (type(pickup.label) == 'string' and pickup.label or 'Current location'):sub(1, 96), x = px + 0.0, y = py + 0.0 },
        dropoff       = { label = (type(dropoff.label) == 'string' and dropoff.label or 'Destination'):sub(1, 96), x = dx + 0.0, y = dy + 0.0 },
        payment       = (p.payment == 'cash') and 'cash' or 'card',
        createdAt     = os.time() * 1000,
    }
    req.distance = distanceKm(req.pickup, req.dropoff)

    requests[req.id]      = req
    riderActive[rdr.cid]  = req.id
    broadcastToDrivers('requestAdded', publicRequest(req))
    broadcastWaiting()
    for username, d in pairs(online) do
        if not driverActive[username] then
            notifyRyde(d.cid, ('New ride request from %s near %s'):format(rdr.name, req.pickup.label))
        end
    end
    print(('^3[sd-phone:ryde]^0 ride request from %s (%s) broadcast to %d online driver(s)'):format(rdr.name, rdr.cid, onlineCount()))
    return ok({ requestId = req.id })
end

---Rider responds to a driver's offer. Accept locks the trip in: the request leaves the board,
---every other outstanding bid is bounced back to its driver as 'declined', and both parties get
---the engaged trip (the driver's copy carries a pickup waypoint, plus a notification in case
---they offered then closed the app). Decline drops just this offer - the request stays open and
---any other bids stand, so the rider keeps choosing/searching. Ownership: only the request's own
---rider (matched by citizenid from src) can respond, and only while the trip is still 'offered',
---so a replayed accept changes nothing.
---@param src integer player server id
---@param payload table { tripId: string, accept?: boolean }
---@return table result
function actions.respond(src, payload)
    local cid = player.getIdentifier(src)
    local p = type(payload) == 'table' and payload or {}
    local trip = p.tripId and trips[p.tripId] or nil
    if not (trip and trip.riderCid == cid and trip.status == 'offered') then
        return fail('No pending offer.')
    end

    if p.accept then
        if trip.requestId and requests[trip.requestId] then
            requests[trip.requestId] = nil
            broadcastToDrivers('requestRemoved', { id = trip.requestId })
            broadcastWaiting()
        end
        clearOffersFor(trip.requestId, trip.id, 'declined')

        trip.status = 'enroute_pickup'
        riderActive[trip.riderUsername] = trip.id
        local driverView = publicTrip(trip, 'driver')
        driverView.waypoint = trip.pickup
        pushTo(trip.driverCid, 'tripUpdate', driverView)
        pushTo(trip.riderCid,  'tripUpdate', publicTrip(trip, 'rider'))
        notifyRyde(trip.driverCid, ('%s accepted your fare. Head to the pickup.'):format(trip.riderName or 'Your rider'))
        return ok({ tripId = trip.id })
    end

    dropOffer(trip)
    pushTo(trip.driverCid, 'tripUpdate', { id = trip.id, status = 'declined', role = 'driver' })
    return ok({ declined = true })
end

---Go on/off duty. Going online registers/refreshes the driver's vehicle card - client-supplied
---cosmetics only (the server computes nothing from them), each capped to its DB column length -
---and hands back the current board. Going offline is blocked mid-trip so an engaged rider can't
---be silently stranded; the response carries the live waiting count so the dashboard's greyed
---badge is right the instant they go off duty (no waiting for the next pool change to push).
---@param src integer player server id
---@param payload table { online: boolean, vehicle?: string, plate?: string, color?: string }
---@return table result
function actions.setOnline(src, payload)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    local p = type(payload) == 'table' and payload or {}

    if p.online then
        local veh   = tostring(p.vehicle or 'Vehicle'):sub(1, 64)
        local plate = tostring(p.plate or ''):sub(1, 16)
        local color = tostring(p.color or '#111111'):sub(1, 16)
        store.upsertDriver(acc.username, acc.name, veh, plate, color)
        local d = store.getDriver(acc.username)
        local rating = (d and d.rating_count > 0) and (d.rating_sum / d.rating_count) or 5.0
        online[acc.username] = {
            cid = acc._cid, name = acc.name,
            vehicle = veh, plate = plate, color = color, rating = rating, since = os.time() * 1000,
        }
        local pending = {}
        for _, r in pairs(requests) do pending[#pending + 1] = publicRequest(r) end
        print(('^3[sd-phone:ryde]^0 %s went on duty (%d pending request(s) on the board)'):format(acc.name, #pending))
        return ok({ online = true, requests = pending, waiting = #pending })
    end

    if driverActive[acc.username] then return fail('Finish your current trip before going offline.') end
    online[acc.username] = nil
    return ok({ online = false, waiting = waitingCount() })
end

---Lightweight demand read: how many riders are waiting right now. Available to any signed-in
---account regardless of duty, so an off-duty driver's dashboard can hydrate its greyed "riders
---waiting" badge on open. Read-only.
---@param src integer player server id
---@return table result { count }
function actions.waitingCount(src)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    return ok({ count = waitingCount() })
end

---Snapshot of the open requests board (dashboard refresh). On-duty drivers only; anyone else
---gets an empty board rather than an error. Read-only.
---@param src integer player server id
---@return table result { requests }
function actions.requestsBoard(src)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    if not online[acc.username] then return ok({ requests = {} }) end
    local pending = {}
    for _, r in pairs(requests) do pending[#pending + 1] = publicRequest(r) end
    return ok({ requests = pending })
end

---Driver bids on a pending request by quoting a fare -> an 'offered' trip. The fare is the money
---the rider will later be charged, so it is coerced to a finite integer (NaN slips plain range
---checks) and clamped to the config rails. The request stays on the board - other drivers keep
---bidding until the rider picks one; the offer is its own trip record linked back via requestId,
---and riderActive stays on the open request until acceptance. A driver cannot bid on their own
---request: self-dealing would let one player farm trips and self-ratings essentially for free.
---Phone-number provisioning yields (DB awaits), so the free/on-duty/board gates are re-checked
---afterwards - otherwise two concurrent accepts could hand one driver two live trips, or bind an
---offer to a request the rider cancelled mid-await.
---@param src integer player server id
---@param payload table { requestId: string, fare: number }
---@return table result { tripId } on success
function actions.accept(src, payload)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    if not online[acc.username] then return fail('Go online to accept rides.') end
    if driverActive[acc.username] then return fail('You already have an active trip.') end

    local p = type(payload) == 'table' and payload or {}
    local req = p.requestId and requests[p.requestId] or nil
    if not req then return fail('That ride is no longer available.') end
    if req.riderCid == acc._cid then return fail('You cannot accept your own request.') end

    local fare = finite(p.fare)
    fare = fare and math.floor(fare) or 0
    if fare < (config.MinFare or 1) then return fail('Enter a fare.') end
    if fare > (config.MaxFare or 100000) then return fail('That fare is too high.') end

    local drv = online[acc.username]
    local driverNumber = settings.ensurePhoneNumber(acc._cid)
    local riderNumber  = settings.ensurePhoneNumber(req.riderCid)
    if not online[acc.username] then return fail('Go online to accept rides.') end
    if driverActive[acc.username] then return fail('You already have an active trip.') end
    if not requests[req.id] then return fail('That ride is no longer available.') end

    local trip = {
        id = store.newId(), requestId = req.id,
        riderUsername = req.riderUsername, riderName = req.riderName, riderCid = req.riderCid,
        driverUsername = acc.username, driverName = drv.name, driverCid = acc._cid,
        driverNumber = driverNumber,
        riderNumber  = riderNumber,
        vehicle = drv.vehicle, plate = drv.plate, color = drv.color, driverRating = drv.rating,
        pickup = req.pickup, dropoff = req.dropoff, distance = req.distance,
        payment = req.payment, fare = fare, status = 'offered',
    }
    trips[trip.id]             = trip
    driverActive[acc.username] = trip.id
    pushTo(trip.riderCid, 'offer', publicTrip(trip, 'rider'))
    local riderSrc = srcOf(trip.riderCid)
    if riderSrc then
        TriggerClientEvent('sd-phone:client:notify', riderSrc, {
            app = 'ryde', appId = 'ryde', quietInApp = true, time = 'now',
            title = 'Ryde', body = ('%s offered a fare of $%d'):format(trip.driverName, fare),
        })
    end
    print(('^3[sd-phone:ryde]^0 %s offered $%d on request %s (trip %s)'):format(acc.name, fare, req.id, trip.id))
    return ok({ tripId = trip.id })
end

---Driver advances an accepted trip: 'arriving' at the pickup, then 'in_progress' once the rider
---boards. Only the trip's own driver may advance it, and never from 'offered' - an offer the
---rider hasn't accepted must not be able to progress toward a fare charge (checked here, not
---just in the UI, so calling the callback directly can't skip acceptance). Starting the trip
---additionally requires rider and driver to share a vehicle right now (server-side OneSync
---check), which stops the button being spammed before pickup.
---@param src integer player server id
---@param payload table { tripId: string, status: 'arriving'|'in_progress' }
---@return table result { status }
function actions.tripStatus(src, payload)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    local p = type(payload) == 'table' and payload or {}
    local trip = p.tripId and trips[p.tripId] or nil
    if not (trip and trip.driverUsername == acc.username) then return fail('No active trip.') end
    if trip.status == 'offered' then return fail('No active trip.') end

    local nextStatus = p.status
    if nextStatus ~= 'arriving' and nextStatus ~= 'in_progress' then return fail('Invalid status.') end
    if nextStatus == 'in_progress' and not inSameVehicle(trip) then
        return fail('Your rider needs to be in your vehicle to start the trip.')
    end
    trip.status = nextStatus

    pushTo(trip.riderCid, 'tripUpdate', publicTrip(trip, 'rider'))
    local driverView = publicTrip(trip, 'driver')
    if nextStatus == 'in_progress' then driverView.waypoint = trip.dropoff end
    pushTo(trip.driverCid, 'tripUpdate', driverView)
    if nextStatus == 'arriving' then
        notifyRyde(trip.riderCid, 'Your driver has arrived. Hop in when you’re ready.')
    else
        notifyRyde(trip.riderCid, ('Trip started. On the way to %s.'):format(trip.dropoff.label))
    end
    return ok({ status = nextStatus })
end

---Driver UI poll: has the rider boarded the driver's vehicle yet? Drives the "Start trip"
---button's enabled state; tripStatus enforces the same check for real. Read-only.
---@param src integer player server id
---@param payload table { tripId: string }
---@return table result { same }
function actions.sameVehicle(src, payload)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    local p = type(payload) == 'table' and payload or {}
    local trip = p.tripId and trips[p.tripId] or nil
    if not (trip and trip.driverUsername == acc.username) then return fail('No active trip.') end
    return ok({ same = inSameVehicle(trip) })
end

---Driver completes the trip: charge the rider, pay the driver their cut, persist the ride, bump
---stats. Guards, in order: only the trip's own driver; only a trip that actually started
---('in_progress' - which itself required rider acceptance and a shared vehicle), so an
---unaccepted offer or a no-show pickup can never be charged; and the driver must physically be
---within 250m of the drop-off (server-side coords). The trip is then claimed out of the live
---tables BEFORE any money or DB work - the store awaits below are yields a replayed complete
---could otherwise slip through, and a double-tap must never double-charge. Fares move
---bank -> bank; the driver payout only happens when the rider's balance covered the debit
---(paid = false records the ride as uncollected and pays nothing). The Wallet entries +
---notifications only mirror the movement - the money already moved above.
---@param src integer player server id
---@param payload table { tripId: string }
---@return table result { rideId, fare, paid }
function actions.complete(src, payload)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    local p = type(payload) == 'table' and payload or {}
    local trip = p.tripId and trips[p.tripId] or nil
    if not (trip and trip.driverUsername == acc.username) then return fail('No active trip.') end
    if trip.status ~= 'in_progress' then return fail('Pick up your rider before completing the trip.') end
    if not withinOf(srcOf(trip.driverCid), trip.dropoff.x, trip.dropoff.y, 250.0) then
        return fail('Drive to the drop-off to complete the trip.')
    end

    trips[trip.id] = nil
    riderActive[trip.riderUsername]   = nil
    driverActive[trip.driverUsername] = nil

    local riderSrc  = srcOf(trip.riderCid)
    local driverSrc = srcOf(trip.driverCid)
    local driverEarn = math.floor(trip.fare * (config.DriverCut or 1.0) + 0.5)

    local paid = false
    if riderSrc and money.get(riderSrc, 'bank') >= trip.fare then
        money.remove(riderSrc, 'bank', trip.fare, 'Ryde fare')
        if driverSrc then money.add(driverSrc, 'bank', driverEarn, 'Ryde earnings') end
        paid = true
    end

    if paid then
        bank.addExternal(trip.riderCid, { label = 'Ryde trip', amount = -trip.fare, category = 'ryde', counterparty = trip.driverName })
        notifyBank(trip.riderCid, ('Charged $%d for your Ryde trip'):format(trip.fare))
        if driverSrc then
            bank.addExternal(trip.driverCid, { label = 'Ryde earnings', amount = driverEarn, category = 'ryde', counterparty = trip.riderName })
            notifyBank(trip.driverCid, ('You earned $%d from your Ryde trip'):format(driverEarn))
        end
    end

    trip.status = 'completed'
    trip.paid   = paid
    store.insertRide(trip)
    store.bumpDriverStats(trip.driverUsername, paid and driverEarn or 0)

    pushTo(trip.riderCid, 'tripUpdate', {
        id = trip.id, rideId = trip.id, status = 'completed', role = 'rider',
        fare = trip.fare, paid = paid, driverName = trip.driverName,
    })
    pushTo(trip.driverCid, 'tripUpdate', {
        id = trip.id, status = 'completed', role = 'driver',
        fare = trip.fare, earn = paid and driverEarn or 0, paid = paid,
    })
    notifyRyde(trip.riderCid, ('Ride completed. Fare $%d. Tap to rate your driver.'):format(math.floor(trip.fare)))
    return ok({ rideId = trip.id, fare = trip.fare, paid = paid })
end

---Either party cancels whatever they're currently in - which end is being cancelled is derived
---from the caller's own live state, never from a payload. Rider side first (keyed by citizenid,
---riders have no account): a still-pending request is pulled off the board and every outstanding
---bid bounced; an engaged trip is torn down with the driver notified. Driver side (by account
---username): withdrawing an un-accepted offer keeps the rider's request (and any other bids)
---alive - they only drop back to searching if it was the last one - while cancelling an engaged
---trip tears it down and notifies the rider.
---@param src integer player server id
---@return table result
function actions.cancel(src)
    local cid      = player.getIdentifier(src)
    local riderId  = cid and riderActive[cid] or nil
    if riderId then
        if requests[riderId] then
            requests[riderId] = nil
            riderActive[cid]  = nil
            broadcastToDrivers('requestRemoved', { id = riderId })
            broadcastWaiting()
            clearOffersFor(riderId, nil, 'cancelled')
            return ok({})
        end
        local trip = trips[riderId]
        if trip then cancelTrip(trip, 'rider'); return ok({}) end
    end

    local acc   = account(src)
    local drvId = acc and driverActive[acc.username] or nil
    local trip  = drvId and trips[drvId] or nil
    if trip then
        if trip.status == 'offered' then
            dropOffer(trip)
            pushTo(trip.riderCid, 'offerRemoved', { id = trip.id, requestId = trip.requestId })
        else
            cancelTrip(trip, 'driver')
        end
        return ok({})
    end
    return fail('Nothing to cancel.')
end

---Rider rates a finished ride 1-5 stars, optionally with a tip. Ownership: the ride row must
---belong to the caller (rider_username = their citizenid) - a bare rideId is never trusted. The
---rating is single-shot at the DB level (UPDATE ... WHERE rating IS NULL plus an affected-rows
---check), so a replayed or racing call can neither re-rate nor re-tip. Stars go through the
---finite coercion first - NaN slips a plain 1..5 range check and would corrupt the driver's
---running average. The tip is real money, rider bank -> driver bank, debited only when the
---rider's balance covers it and the driver is reachable via the on-duty board (they almost
---always still are right after a drop-off) - never charge a tip that can't be paid through. The
---driver gets a live Trips-list update plus a notification for the stars (and tip, if any).
---@param src integer player server id
---@param payload table { rideId: string, stars: number, tip?: number }
---@return table result { rated, tipPaid }
function actions.rate(src, payload)
    local cid = player.getIdentifier(src)
    if not cid then return fail('Could not resolve your character.') end
    local p = type(payload) == 'table' and payload or {}
    local stars = finite(p.stars)
    stars = stars and math.floor(stars) or 0
    if stars < 1 or stars > 5 then return fail('Pick 1 to 5 stars.') end

    local ride = type(p.rideId) == 'string' and store.getRide(p.rideId) or nil
    if not (ride and ride.rider_username == cid) then return fail('Ride not found.') end
    if ride.rating ~= nil then return fail('You already rated this trip.') end

    local affected = store.setRideRating(ride.id, stars)
    if not (affected and affected > 0) then return fail('Could not save your rating.') end

    local drvUser = ride.driver_username
    if drvUser and drvUser ~= '' then store.addRating(drvUser, stars) end

    local drv       = drvUser and online[drvUser] or nil
    local driverSrc = drv and srcOf(drv.cid) or nil

    local tip = finite(p.tip)
    tip = tip and math.floor(tip) or 0
    local tipPaid = 0
    if tip > 0 and driverSrc then
        if money.get(src, 'bank') >= tip then
            money.remove(src, 'bank', tip, 'Ryde tip')
            money.add(driverSrc, 'bank', tip, 'Ryde tip')
            tipPaid = tip
        end
    end

    if tipPaid > 0 then
        bank.addExternal(cid, { label = 'Ryde tip', amount = -tipPaid, category = 'ryde', counterparty = ride.driver_name })
        notifyBank(cid, ('You tipped $%d'):format(tipPaid))
        if drv then
            bank.addExternal(drv.cid, { label = 'Ryde tip', amount = tipPaid, category = 'ryde', counterparty = ride.rider_name })
            notifyBank(drv.cid, ('You received a $%d tip'):format(tipPaid))
        end
    end

    if driverSrc then
        pushTo(drv.cid, 'ratingReceived', { id = ride.id, stars = stars, tip = tipPaid })
        local who  = (ride.rider_name and ride.rider_name ~= '') and ride.rider_name or 'Your rider'
        local body = ('%s rated you %d★'):format(who, stars)
        if tipPaid > 0 then body = ('%s and tipped $%d'):format(body, tipPaid) end
        TriggerClientEvent('sd-phone:client:notify', driverSrc, {
            app = 'ryde', appId = 'ryde', time = 'now', title = 'Ryde', body = body,
        })
    end

    return ok({ rated = stars, tipPaid = tipPaid })
end

---Driver-info block for a trip, as the rider's UI expects it.
---@param t table trip record
---@return table
local function tripDriverInfo(t)
    return { name = t.driverName, car = t.vehicle, plate = t.plate, color = t.color, rating = t.driverRating, number = t.driverNumber }
end

---The rider's live ride right now: a pending request (with any open offers folded in) or an
---engaged trip. Self-contained so the client can rebuild its rider-side ride from scratch on app
---open - the pushes it missed while closed are irrelevant.
---@param cid string rider citizenid
---@return table|nil
local function riderActivePayload(cid)
    local id  = riderActive[cid]
    local req = id and requests[id] or nil
    if req then
        local offers = {}
        for tid, t in pairs(trips) do
            if t.requestId == id and t.status == 'offered' then
                offers[#offers + 1] = { tripId = tid, fare = t.fare, driver = tripDriverInfo(t) }
            end
        end
        return {
            id = req.id, status = (#offers > 0) and 'offered' or 'finding',
            pickup = req.pickup, dropoff = req.dropoff, distance = req.distance,
            payment = req.payment, createdAt = req.createdAt, riderName = req.riderName,
            offers = offers,
        }
    end
    local t = id and trips[id] or nil
    if t then
        return {
            id = t.id, tripId = t.id, status = t.status,
            pickup = t.pickup, dropoff = t.dropoff, distance = t.distance,
            payment = t.payment, fare = t.fare, riderName = t.riderName,
            driver = tripDriverInfo(t),
        }
    end
    return nil
end

---The driver's live engaged trip (offered -> in_progress), driver perspective.
---@param username string|nil driver account username
---@return table|nil
local function driverActivePayload(username)
    local id = username and driverActive[username] or nil
    local t  = id and trips[id] or nil
    if not t then return nil end
    return {
        id = t.id, tripId = t.id, status = t.status,
        pickup = t.pickup, dropoff = t.dropoff, distance = t.distance,
        payment = t.payment, fare = t.fare, riderName = t.riderName, riderNumber = t.riderNumber,
    }
end

---Re-sync the caller's live Ryde state on app open. The store's push listeners only exist while
---the app is mounted, so a phone that was closed missed every offer/trip update - this hands
---back the authoritative current state. When nothing is live rider-side, the most recent
---persisted ride rides along so the client can resolve a trip that finished while closed into a
---rating prompt; fare is a DECIMAL column that oxmysql returns as a string, coerced here because
---the UI does number math on it. On-duty drivers also get the full open board, since the
---requestAdded pushes only land while the app is mounted - without it a driver whose phone was
---closed when requests came in would reopen to an empty board even though the count is right.
---Read-only.
---@param src integer player server id
---@return table result { rider, driver, lastEnded, requests }
function actions.sync(src)
    local cid = player.getIdentifier(src)
    if not cid then return fail('Could not resolve your character.') end
    local acc    = account(src)
    local rider  = riderActivePayload(cid)
    local driver = acc and driverActivePayload(acc.username) or nil
    local lastEnded
    if not rider then
        local row = store.latestRiderRide(cid)
        if row then lastEnded = { id = row.id, status = row.status, fare = tonumber(row.fare) or 0 } end
    end
    local board
    if acc and online[acc.username] then
        board = {}
        for _, r in pairs(requests) do board[#board + 1] = publicRequest(r) end
    end
    return ok({ rider = rider, driver = driver, lastEnded = lastEnded, requests = board })
end

---Start/stop the live peer-location stream for the caller while they look at a trip map. Only
---the trip's own rider or driver may watch (validated here against src-derived identity, with
---the role fixed server-side), and the stream thread below only does work while someone is
---watching - positions go out on demand, never wastefully. The counterpart's coords are read
---server-side, so they can't be spoofed.
---@param src integer player server id
---@param payload table { tripId: string, on: boolean }
---@return table result
function actions.watchTrip(src, payload)
    local p = type(payload) == 'table' and payload or {}
    if not p.on then tripViewers[src] = nil; return ok({}) end
    local trip = p.tripId and trips[p.tripId] or nil
    if not trip then tripViewers[src] = nil; return fail('No such trip.') end
    local cid = player.getIdentifier(src)
    local acc = account(src)
    local isRider  = trip.riderCid == cid
    local isDriver = acc and trip.driverUsername == acc.username
    if not (isRider or isDriver) then return fail('Not your trip.') end
    tripViewers[src] = { tripId = p.tripId, role = isDriver and 'driver' or 'rider' }
    return ok({})
end

-- Live peer-location push loop: for every src currently watching a trip map, read their
-- counterpart's live ped position server-side (unspoofable) and push it down - the rider sees
-- the driver's car move, the driver sees the rider. Only validated trip members ever register
-- (actions.watchTrip); a watcher whose trip ended or who disconnected is dropped, and the loop
-- does no work while nobody is watching. Coarse (500ms) - a map marker isn't frame-sensitive.
CreateThread(function()
    while true do
        Wait(500)
        for vsrc, w in pairs(tripViewers) do
            if not GetPlayerName(vsrc) then
                tripViewers[vsrc] = nil
            else
                local trip = w.tripId and trips[w.tripId] or nil
                if not trip then
                    tripViewers[vsrc] = nil
                else
                    local otherCid  = (w.role == 'driver') and trip.riderCid or trip.driverCid
                    local otherRole = (w.role == 'driver') and 'rider' or 'driver'
                    local osrc = otherCid and srcOf(otherCid) or nil
                    if osrc then
                        local ped = GetPlayerPed(osrc)
                        if ped and ped ~= 0 then
                            local c = GetEntityCoords(ped)
                            TriggerClientEvent(EV .. 'peerLocation', vsrc, {
                                tripId = w.tripId, role = otherRole,
                                x = c.x, y = c.y, h = GetEntityHeading(ped),
                            })
                        end
                    end
                end
            end
        end
    end
end)

---Every ride the caller took part in, split into rider/driver entries for the history tab.
---Riders are keyed by citizenid, drivers by account username (falling back to citizenid when not
---signed in, which then simply matches no driver rows). The paid flag is deserialised with the
---truthy set because oxmysql hands TINYINT(1) back as a Lua boolean, not 1/0. Read-only, scoped
---to the caller's own keys.
---@param src integer player server id
---@return table result { asRider, asDriver }
function actions.history(src)
    local cid = player.getIdentifier(src)
    if not cid then return fail('Could not resolve your character.') end
    local acc = account(src)
    local driverKey = (acc and acc.username) or cid
    local rows = store.ridesForUser(cid, driverKey)
    local asRider, asDriver = {}, {}
    for _, r in ipairs(rows) do
        local entry = {
            id = r.id, status = r.status, fare = r.fare, paid = r.paid == true or r.paid == 1 or r.paid == '1', payment = r.payment,
            pickup   = { label = r.pickup_label,  x = r.pickup_x,  y = r.pickup_y },
            dropoff  = { label = r.dropoff_label, x = r.dropoff_x, y = r.dropoff_y },
            distance = r.distance, rating = r.rating, createdAt = r.created_at,
            riderName = r.rider_name, driverName = r.driver_name,
        }
        if r.rider_username  == cid       then asRider[#asRider + 1]   = entry end
        if r.driver_username == driverKey then asDriver[#asDriver + 1] = entry end
    end
    return ok({ asRider = asRider, asDriver = asDriver })
end

---Top drivers server-wide (confidence-weighted rating; the maths lives in store.leaderboard and
---configs/ryde.lua). avg_rating comes out of a DECIMAL division, so oxmysql may hand it back as
---a string - coerced and rounded to two decimals here. Public by design: it only exposes what
---the leaderboard screen renders (name/username, rating, trip count, card colour). Read-only.
---@return table result { leaders }
function actions.leaderboard()
    local rows = store.leaderboard(50, config.LeaderboardPriorRating or 4.5, config.LeaderboardWeight or 10)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            username = r.username,
            name   = (r.display_name and r.display_name ~= '') and r.display_name or r.username,
            rating = math.floor((tonumber(r.avg_rating) or 5) * 100 + 0.5) / 100,
            trips  = tonumber(r.trips) or 0,
            color  = r.color,
        }
    end
    return ok({ leaders = out })
end

---The caller's own Ryde profile: account identity, driver card + lifetime stats when they have
---one, current duty state, and whatever ride/trip they're active in. Read-only.
---@param src integer player server id
---@return table result
function actions.me(src)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end
    local d = store.getDriver(acc.username)
    local rating = (d and d.rating_count > 0) and (d.rating_sum / d.rating_count) or 5.0
    return ok({
        username = acc.username,
        name     = acc.name,
        driver   = d and {
            vehicle = d.vehicle, plate = d.plate, color = d.color,
            rating = math.floor(rating * 100 + 0.5) / 100,
            trips = d.trips, earnings = d.earnings_total,
        } or nil,
        online = online[acc.username] ~= nil,
        active = riderActive[acc._cid] or driverActive[acc.username] or nil,
    })
end

---Permanently delete the caller's Ryde account: pull them off duty, withdraw an un-accepted
---offer or cancel an engaged trip (the rider counterpart is notified either way), then drop the
---driver record and the account itself. Only ever operates on the caller's own signed-in account
---- the account id comes from the session, never from a payload.
---@param src integer player server id
---@return table result
function actions.deleteAccount(src)
    local acc = account(src)
    if not acc then return fail('Sign in to Ryde first.') end

    online[acc.username] = nil
    local tripId = driverActive[acc.username]
    local trip   = tripId and trips[tripId] or nil
    if trip then
        if trip.status == 'offered' then
            dropOffer(trip)
            pushTo(trip.riderCid, 'offerRemoved', { id = trip.id, requestId = trip.requestId })
        else
            cancelTrip(trip, 'driver')
        end
    end

    store.deleteDriver(acc.username)
    acctStore.deleteAccount(acc.id)
    return ok({})
end

---Client-facing slice of configs/ryde.lua: quick-pick destinations, the driver's cut for the
---earnings preview, and the leaderboard weighting so the UI can explain rankings. Read-only.
---@return table result
function actions.config()
    return ok({
        locations    = config.Locations or {},
        driverCut    = config.DriverCut or 1.0,
        leaderPrior  = config.LeaderboardPriorRating or 4.5,
        leaderWeight = config.LeaderboardWeight or 10,
    })
end

-- DEV/TEST tooling for /rydeoffer: synthetic driver cards used to exercise the rider's
-- multi-offer switcher without a second real player.
---@type table[] Fake driver cards devOffer picks from at random.
local DEV_DRIVERS = {
    { name = 'Test Driver', car = 'Bravado Buffalo',     color = '#10b981', plate = 'DEV 001' },
    { name = 'Avery R.',    car = 'Annis Elegy RH8',     color = '#3b82f6', plate = 'DEV 002' },
    { name = 'Sam Q.',      car = 'Dewbauchee Rapid GT', color = '#f59e0b', plate = 'DEV 003' },
    { name = 'Jordan P.',   car = 'Vapid Peyote',        color = '#ef4444', plate = 'DEV 004' },
}

---DEV/TEST: drop a synthetic fare offer onto the caller's own open ride request, so the rider's
---multi-offer switcher can be exercised without a second real driver. Self-scoped: it can only
---ever add an offer to the CALLER's request, and the synthetic driver has no real session - it
---never touches driverActive and its pushes/cid resolve to nothing (a no-op) - so the offer is
---safe to accept or decline. Returns a short status string for the chat ack.
---@param src integer player server id
---@return string message
function actions.devOffer(src)
    local cid = player.getIdentifier(src)
    if not cid then return 'No character.' end
    local reqId = riderActive[cid]
    local req   = reqId and requests[reqId] or nil
    if not req then return 'Request a ride first, then run /rydeoffer to add a test offer.' end

    local d    = DEV_DRIVERS[math.random(#DEV_DRIVERS)]
    local fare = math.random(config.MinFare or 5, math.max((config.MinFare or 5) + 1, 45))
    local trip = {
        id = store.newId(), requestId = req.id,
        riderUsername = req.riderUsername, riderName = req.riderName, riderCid = req.riderCid,
        driverUsername = 'dev:' .. cid, driverName = d.name, driverCid = 'dev',
        driverNumber = '5550000',
        vehicle = d.car, plate = d.plate, color = d.color, driverRating = 4.8,
        pickup = req.pickup, dropoff = req.dropoff, distance = req.distance,
        payment = req.payment, fare = fare, status = 'offered',
    }
    trips[trip.id] = trip
    pushTo(trip.riderCid, 'offer', publicTrip(trip, 'rider'))
    return ('Sent a test offer: %s for $%d.'):format(d.name, fare)
end

---Player left - drop them from the duty board and cancel anything they were in, releasing the
---counterpart. The citizenid comes from the live cache first because the framework may have
---already unloaded the player by the time playerDropped fires; the per-src caches (srcCid,
---tripViewers) are always cleared so recycled server ids can't inherit stale state. Their
---pending request (if any) is binned along with every bid on it. An offered trip is only an
---offer withdrawal - the rider keeps the request and is told to remove just that one card when
---its driver was the leaver - while an engaged trip is cancelled with by = 'disconnect' so the
---survivor is notified.
---@param src number player server id
function actions.onPlayerDropped(src)
    local cid = srcCid[src] or player.getIdentifier(src)
    srcCid[src] = nil
    tripViewers[src] = nil
    if not cid then return end
    for username, d in pairs(online) do
        if d.cid == cid then online[username] = nil; break end
    end
    for id, r in pairs(requests) do
        if r.riderCid == cid then
            requests[id] = nil
            riderActive[r.riderUsername] = nil
            broadcastToDrivers('requestRemoved', { id = id })
            broadcastWaiting()
            clearOffersFor(id, nil, 'cancelled')
        end
    end
    for id, t in pairs(trips) do
        if t.riderCid == cid or t.driverCid == cid then
            if t.status == 'offered' then
                dropOffer(t)
                if t.driverCid == cid then
                    pushTo(t.riderCid, 'offerRemoved', { id = id, requestId = t.requestId })
                end
            else
                cancelTrip(t, 'disconnect')
            end
        end
    end
end

return actions
