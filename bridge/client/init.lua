-- Loaded for side effects: notify registers the 'sd-phone:client:notify' net-event handler;
-- target and inventory each resolve their backend once at require time, so a missing target
-- resource fails loudly at boot (not at first interaction) and later requires stay cheap for
-- consumers. The on-demand bridges (housing, vehiclekeys, weather) are required by the client
-- modules that use them instead.
require 'bridge.client.notify'
require 'bridge.client.target'
require 'bridge.client.inventory'
