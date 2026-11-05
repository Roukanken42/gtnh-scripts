-- Setup helper: finds the sides and addresses config.lua needs.
--
--   probe                 list every component
--   probe sides           what the transposer sees on each side (tank, interface, bus)
--   probe redstone [s]    redstone inputs now, then every change for s seconds
--                         (default 10) -- shows which side pulses once a second
--   probe machine         every gt_machine: name, active, progress, work allowed

local component = require("component")
local event = require("event")
local sides = require("sides")
local computer = require("computer")

local args = { ... }
local mode = args[1]

local function sideName(s) return sides[s] or tostring(s) end

local function listComponents()
    local list = {}
    for addr, ctype in component.list() do list[#list + 1] = { addr = addr, type = ctype } end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        return a.addr < b.addr
    end)
    for _, c in ipairs(list) do print(string.format("%-22s %s", c.type, c.addr)) end
end

local function probeSides()
    for addr in component.list("transposer", true) do
        local tp = component.proxy(addr)
        print("== transposer " .. addr)
        for side = 0, 5 do
            local _, name = pcall(tp.getInventoryName, side)
            local _, size = pcall(tp.getInventorySize, side)
            if type(size) ~= "number" then name, size = nil, nil end
            local okT, tanks = pcall(tp.getFluidInTank, side)
            local line = string.format("  %-6s (%d) ", sideName(side), side)
            if name or size then
                line = line .. string.format("inventory %s, %s slots", tostring(name), tostring(size))
            end
            if okT and type(tanks) == "table" then
                local list = (tanks.amount or tanks.capacity) and { tanks } or tanks
                for i = 1, (list.n or #list) do
                    local f = list[i]
                    if type(f) == "table" and f.capacity then
                        line = line .. string.format("  tank: %s %s/%s L", tostring(f.label or "empty"),
                            tostring(f.amount or 0), tostring(f.capacity))
                    end
                end
            end
            print(line)
            if size and size > 0 then
                local it = tp.getAllStacks(side)
                local shown = 0
                for slot = 1, it.count() do
                    local s = it()
                    if type(s) == "table" and s.label and shown < 6 then
                        print(string.format("           slot %d: %d x %s", slot, s.size or 0, s.label))
                        shown = shown + 1
                    end
                end
            end
        end
    end
end

local function probeRedstone(seconds)
    for addr in component.list("redstone", true) do
        local rs = component.proxy(addr)
        local levels = {}
        for side = 0, 5 do levels[#levels + 1] = sideName(side) .. "=" .. rs.getInput(side) end
        print("redstone " .. addr:sub(1, 8) .. ": " .. table.concat(levels, " "))
    end
    print("Watching for " .. seconds .. "s (a Utility Hatch in pulse mode rises once a second)...")
    local deadline = computer.uptime() + seconds
    local rises = {}
    while computer.uptime() < deadline do
        local _, addr, side, old, new, color = event.pull(deadline - computer.uptime(), "redstone_changed")
        if addr then
            print(string.format("%7.2f  %s %-6s %d -> %d%s", computer.uptime(), addr:sub(1, 8), sideName(side),
                old, new, color and (" color " .. color) or ""))
            if old == 0 and new > 0 then
                local k = addr:sub(1, 8) .. " " .. sideName(side)
                rises[k] = (rises[k] or 0) + 1
            end
        end
    end
    for k, n in pairs(rises) do print(string.format("  %s rose %d times (%.1f/s)", k, n, n / seconds)) end
end

local function probeMachine()
    for addr in component.list("gt_machine", true) do
        local m = component.proxy(addr)
        local function call(f) local ok, v = pcall(m[f]); return ok and v or nil end
        print(string.format("%s  %s  active=%s  progress=%s/%s  workAllowed=%s", addr, tostring(call("getName")),
            tostring(call("isMachineActive")), tostring(call("getWorkProgress")),
            tostring(call("getWorkMaxProgress")), tostring(call("isWorkAllowed"))))
    end
end

if mode == nil then
    listComponents()
elseif mode == "sides" then
    probeSides()
elseif mode == "redstone" then
    probeRedstone(tonumber(args[2]) or 10)
elseif mode == "machine" then
    probeMachine()
else
    print("usage: probe [sides | redstone [seconds] | machine]")
end
