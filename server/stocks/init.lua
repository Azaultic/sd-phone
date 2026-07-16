---@type table sd-phone config root (configs/config.lua).
local config  = require 'configs.config'
---@type table Stocks persistence layer (server.stocks.store): schema bootstrap + price rows.
local store   = require 'server.stocks.store'
---@type table Shared price simulation (server.stocks.engine): tick, persist + broadcast payloads.
local engine  = require 'server.stocks.engine'
---@type table Authoritative trade handlers (server.stocks.actions): validation + money movement.
local actions = require 'server.stocks.actions'

---@type table Stocks config (config.Stocks): tick + save cadence.
local ST = config.Stocks

-- Authoritative NUI-facing callbacks: thin delegates into server.stocks.actions, which owns the
-- validation + money movement (each handler is documented there).
lib.callback.register('sd-phone:server:stocks:market',   function(src)          return actions.market(src)             end)
lib.callback.register('sd-phone:server:stocks:deposit',  function(src, payload) return actions.deposit(src, payload)   end)
lib.callback.register('sd-phone:server:stocks:withdraw', function(src, payload) return actions.withdraw(src, payload)  end)
lib.callback.register('sd-phone:server:stocks:buy',      function(src, payload) return actions.buy(src, payload)       end)
lib.callback.register('sd-phone:server:stocks:sell',     function(src, payload) return actions.sell(src, payload)      end)
lib.callback.register('sd-phone:server:stocks:holders',  function(src, payload) return actions.holders(src, payload)   end)

---@type table<number, boolean> Players with the Stocks app open (live price-push targets), by src.
local watchers = {}

---The app flips this on while it's open and off when it closes, so the per-tick price push reaches
---only players actually watching the market instead of every online phone every few seconds. Public
---market data, so nothing sensitive; self-scoped - the payload can only sub/unsub the CALLER. On
---open the app also fetches the current snapshot via :market, so a just-subscribed player isn't
---blank until the next tick.
---@param src number
---@param payload table { on: boolean }
lib.callback.register('sd-phone:server:stocks:watch', function(src, payload)
    payload = type(payload) == 'table' and payload or {}
    if payload.on == true then watchers[src] = true else watchers[src] = nil end
    return { success = true }
end)

---A departing watcher's entry is dropped (srcs recycle across sessions, so a stale key would push
---the market to the wrong client).
AddEventHandler('playerDropped', function()
    watchers[source] = nil
end)

-- Boot then heartbeat: schema first (bail if it fails - trading against missing tables would
-- error every callback), then seed prices, then every ST.TickSeconds each asset takes its
-- random-walk step. The market ALWAYS advances (and is persisted) regardless of who's watching;
-- the light tick payload (price + % change, no history) is only PUSHED to players with Stocks open
-- (the watchers set), not broadcast to every phone. Public market data only, no player fields.
-- Coarse (seconds) - nothing here is frame-sensitive.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('^1[sd-phone:stocks]^0 schema bootstrap failed: %s'):format(err))
        return
    end
    engine.init()
    print('^2[sd-phone:stocks]^0 market ready')

    while true do
        Wait((ST.TickSeconds or 5) * 1000)
        engine.tick()
        if next(watchers) then
            local ticks = engine.ticks()
            for src in pairs(watchers) do
                if GetPlayerName(src) then
                    TriggerClientEvent('sd-phone:client:stocks:prices', src, { assets = ticks })
                else
                    watchers[src] = nil
                end
            end
        end
    end
end)

-- Batched persistence (every ST.SaveSeconds) so the market survives a restart without writing
-- on every tick. The save is pcall-guarded so a transient DB error can't kill the loop.
CreateThread(function()
    while true do
        Wait((ST.SaveSeconds or 30) * 1000)
        local ok, err = pcall(function() store.savePrices(engine.persistRows()) end)
        if not ok then print(('^1[sd-phone:stocks]^0 price save failed: %s'):format(err)) end
    end
end)

---Flush the live prices once on resource stop so an intentional restart keeps the latest
---market (the batched save can be up to ST.SaveSeconds stale). Guarded to this resource only;
---failures are swallowed since the server is going down anyway.
---@param resource string name of the resource that stopped
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    pcall(function() store.savePrices(engine.persistRows()) end)
end)
