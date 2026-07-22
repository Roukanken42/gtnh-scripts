-- Generator control layer -- the ONE place that drives redstone. The control
-- logic in main.lua only calls Generator:apply(on, now, live) and reads the
-- generator's config/state, so all knowledge of HOW a generator is switched
-- (plain side output vs. bundled colour) lives here.

local component = require("component")
local util = require("util")
local sides = require("sides")
local colors = require("colors")

local generators = {}

-- Resolve the redstone component (nil if none -- headless / mis-wired).
local function getRedstone()
    if component.isAvailable("redstone") then return component.redstone end
    return nil
end

-- Resolve a side given as a name ("top") or a number.
local function resolveSide(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return sides[v] end
    return nil
end

-- Resolve an optional bundled-cable colour given as a name ("white") or number.
local function resolveColor(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    if type(v) == "string" then return colors[v] end
    return nil
end

local Generator = {}
Generator.__index = Generator

-- Applies the desired on/off state to the hardware if it changed. `live` is
-- false under dry-run: the intended state is still tracked (so the dashboard and
-- log show what WOULD happen) but no redstone is touched. self.on starts nil so
-- the first cycle always writes, syncing the hardware to our computed state
-- (a generator left on by a previous run is corrected). Returns true if changed.
function Generator:apply(on, now, live)
    if on == self.on then return false end
    if live and self.rs and self.side then
        local value = on and (self.color and 255 or 15) or 0
        pcall(function()
            if self.color then
                self.rs.setBundledOutput(self.side, self.color, value)
            else
                self.rs.setOutput(self.side, value)
            end
        end)
    end
    self.on = on
    self.since = now
    return true
end

-- Builds the generator list from cfg.generators. Validates sides, thresholds and
-- duplicates, logging (not crashing) on problems. `log` is the controller's
-- logger; `now` seeds each generator's state timestamp.
function generators.build(cfg, log, now)
    local rs = getRedstone()
    if not rs then
        log("WARN: no redstone component -- generators cannot be switched (headless?).")
    end

    local list = {}
    local seen = {} -- "side/color" -> name, to catch double-driven outputs
    for _, g in ipairs(cfg.generators or {}) do
        local side = resolveSide(g.side)
        local color = resolveColor(g.color)
        if not g.name then
            log("WARN: a generator entry has no name; skipped.")
        elseif not side then
            log("WARN: generator '" .. g.name .. "' has an unknown side '" .. tostring(g.side) .. "'; skipped.")
        elseif g.color ~= nil and not color then
            log("WARN: generator '" .. g.name .. "' has an unknown colour '" .. tostring(g.color) .. "'; skipped.")
        else
            local onBelow = g.onBelow or 0.3
            local offAbove = g.offAbove or 0.7
            if onBelow >= offAbove then
                log("WARN: generator '" .. g.name .. "' has onBelow >= offAbove (" ..
                    tostring(onBelow) .. " >= " .. tostring(offAbove) .. "); it may flap.")
            end
            local key = side .. "/" .. tostring(color)
            if seen[key] then
                log("WARN: generator '" .. g.name .. "' shares side/colour with '" .. seen[key] ..
                    "'; both will be driven together.")
            end
            seen[key] = g.name

            list[#list + 1] = setmetatable({
                name = g.name,
                side = side,
                color = color,
                output = util.parseNum(g.output),
                prio = g.prio or 0,
                onBelow = onBelow,
                offAbove = offAbove,
                minOn = g.minOn or 0,
                rs = rs,
                on = nil,   -- unknown until the first apply
                since = now,
            }, Generator)
        end
    end

    -- Cheapest / highest priority first (lower prio number = turned on earlier).
    table.sort(list, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.name < b.name
    end)
    return list
end

generators.Generator = Generator

return generators
