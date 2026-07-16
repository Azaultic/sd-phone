-- Loaded for side effects: eager-load every server bridge module so consumers can `require` any
-- of them in any order. Each is a pure library that binds its framework/inventory dispatch once
-- at first load; none registers callbacks or events of its own.
require 'bridge.server.player'
require 'bridge.server.notify'
require 'bridge.server.inventory'
require 'bridge.server.money'
require 'bridge.server.job'
require 'bridge.server.gang'
require 'bridge.server.version'

---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework   = require 'bridge.shared.framework'
---@type table Inventory resource detection (bridge.shared.inventory_id): first started candidate.
local inventoryId = require 'bridge.shared.inventory_id'

-- The boot announcement is the only side effect anchored here beyond the eager loads.
print(('^2[SD-PHONE]^0 Bridge initialised — Framework: ^3%s^0, Inventory: ^3%s^0'):format(
    framework.name, inventoryId.name or 'framework-default'))
