-- The GTA map is metres with the origin (0,0) out near Vespucci. Anchoring that origin to a
-- downtown-Los-Angeles latitude/longitude (Los Santos is GTA's take on LA) and offsetting by
-- metres makes the readout look like believable LA GPS that also moves correctly: heading
-- north raises latitude, east raises longitude.
---@type number Degrees north at the GTA origin (0,0).
local LAT0 = 34.0522
---@type number Degrees west at the GTA origin (0,0).
local LON0 = -118.2437
---@type number Metres per degree of latitude.
local M_PER_DEG_LAT = 111320.0
---@type number Cosine of the anchor latitude - shrinks a longitude degree's metre width.
local COS_LAT0 = math.cos(math.rad(LAT0))

---Project GTA world metres onto the anchored latitude/longitude frame.
---@param x number world x (metres east of the origin)
---@param y number world y (metres north of the origin)
---@return number lat degrees north
---@return number lon degrees east (negative = west)
local function gtaToLatLon(x, y)
    local lat = LAT0 + (y / M_PER_DEG_LAT)
    local lon = LON0 + (x / (M_PER_DEG_LAT * COS_LAT0))
    return lat, lon
end

---Live readout the React app polls while the Compass screen is open. Purely local reads of
---our own ped - nothing reaches the server. GTA headings are 0 = north increasing
---counter-clockwise while a compass bearing increases clockwise, so the heading is flipped;
---alt is metres above sea level.
RegisterNUICallback('sd-phone:compass:get', function(_, cb)
    local ped = PlayerPedId()
    local bearing  = (360.0 - GetEntityHeading(ped)) % 360.0
    local c        = GetEntityCoords(ped)
    local lat, lon = gtaToLatLon(c.x, c.y)
    cb({
        heading = bearing,
        lat     = lat,
        lon     = lon,
        alt     = c.z,
    })
end)
