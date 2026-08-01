-- User configuration for the space-mining controller. This file is NOT
-- overwritten when you re-run `install` (it is marked `?` in the manifest), so
-- your settings survive updates.
--
-- The fiddly per-module addresses (transposer / ME interface / sides) are best
-- filled in by running the `setup` script, which discovers them and writes them
-- to stations.lua next to this file. This config loads that file automatically.

local cfg = {}

-- ---- Stations (one per mining module) --------------------------------------
-- Each module needs a "station": the transposer that shuffles its drones, the
-- ME interface it stocks from, and which transposer SIDES face the interface and
-- the module's input bus. Keyed by the miner's component address:
--
--   cfg.stations = {
--     ["<miner-address>"] = {
--       label         = "T2 miner",       -- friendly name (optional)
--       transposer    = "<transposer-address>",
--       interface     = "<me_interface-address>",
--       interfaceSide = 3,                 -- transposer side facing the interface
--       inputBusSide  = 2,                 -- transposer side facing the input bus
--       interfaceSlot = 1,                 -- staging slot; distinct per station
--                                          -- when several share one interface
--     },
--   }
--
-- Prefer running `setup` over editing this by hand -- it also assigns each
-- station a distinct interfaceSlot when several share an ME interface, so their
-- drone loads can run concurrently. Anything set here wins over stations.lua.
cfg.stations = {}

-- Shared database component that holds item metadata for ME stocking. Leave nil
-- to let setup pick it (there is usually exactly one).
cfg.database = nil

-- Pull in whatever `setup` discovered (stations.lua) without clobbering anything
-- you set above. stations.lua is machine-specific and not shipped in the repo.
do
    local ok, data = pcall(require, "stations")
    if ok and type(data) == "table" then
        if cfg.database == nil then cfg.database = data.database end
        if type(data.stations) == "table" then
            for addr, st in pairs(data.stations) do
                if cfg.stations[addr] == nil then cfg.stations[addr] = st end
            end
        end
    end
end

-- ---- Behaviour -------------------------------------------------------------

-- How many drones to keep in each module's input bus. One is enough to run the
-- module; revisit once we know whether parallels want a drone each.
cfg.dronesPerModule = 1

-- Safety: when true, drone moves are only LOGGED, never performed. Flip to false
-- once you have watched a drone move correctly in-game.
cfg.dryRun = true

-- Seconds to wait for AE2 to stock a requested drone into the interface before
-- giving up on a load.
cfg.stockTimeout = 10

-- Interface config/inventory slot (1..8) used to stage drones through.
cfg.interfaceSlot = 1

return cfg
