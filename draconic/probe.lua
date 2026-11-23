-- Setup helper: shows what the controller sees, without changing anything.
--
--   probe            every component
--   probe sides      what each transposer side holds; which is the
--                    replenisher and which the buffer chest
--   probe stock      the replenisher's and the chest's contents, with fuel value
--   probe reactor    getReactorInfo(), and a simulated shutdown from now

local component = require("component")

local hw = require("hw")
local P = require("physics")

local mode = ...

local function sideName(s) return string.format("%d=%s", s, hw.SIDE_NAMES[s] or "?") end

local function loadCfg()
    local ok, cfg = pcall(require, "config")
    if not ok then
        io.stderr:write("config.lua: " .. tostring(cfg) .. "\n")
        os.exit(1)
    end
    return cfg
end

local function listComponents()
    local list = {}
    for addr, ctype in component.list() do list[#list + 1] = { addr = addr, type = ctype } end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        return a.addr < b.addr
    end)
    for _, c in ipairs(list) do print(string.format("%-20s %s", c.type, c.addr)) end
end

local function probeSides()
    local cfg = loadCfg()
    local any = false
    for addr in component.list("transposer", true) do
        any = true
        local tp = component.proxy(addr)
        local survey = hw.surveySides(tp)
        local stock, target, err = hw.pickSides(survey, cfg.transposer or {})
        print("== transposer " .. addr)
        print("   replenisher: " .. (stock and sideName(stock) or "?") .. "   buffer chest: "
            .. (target and sideName(target) or "?") .. (err and ("   (" .. err .. ")") or ""))
        for s = 0, 5 do
            local i = survey[s]
            if i.size then
                print(string.format("  %-9s %s (%d slots)", sideName(s), tostring(i.name), i.size))
            end
        end
    end
    if not any then print("No transposer found.") end
end

local function probeStock()
    local cfg = loadCfg()
    cfg.feed = { enabled = true }
    local h, problems = hw.init(cfg)
    if not h then print(table.concat(problems, "\n")) return end
    if not h.tp then print(h.tpProblem) return end
    print(h:describe())
    local C = P.constants(cfg.game)
    for _, part in ipairs({ { "replenisher", h.stock }, { "buffer chest", h.buffer } }) do
        local items, err = part[2](h)
        if not items then
            print(err)
        else
            print(part[1] .. ":")
            local total = 0
            for _, it in ipairs(items) do
                local v = P.fuelValue(it.label, C)
                total = total + v * it.size
                print(string.format("  slot %-3d %6d x %-34s %s", it.slot, it.size, tostring(it.label),
                    v > 0 and (v .. " fuel each") or "(not fuel)"))
            end
            print(string.format("Fuel in the %s: %d (%.1f blocks)", part[1], total, total / C.block))
        end
    end
end

local function probeReactor()
    local cfg = loadCfg()
    cfg.feed = { enabled = false }
    local h, problems = hw.init(cfg)
    if not h then print(table.concat(problems, "\n")) return end
    local d, err = h:info()
    if not d then print("getReactorInfo failed: " .. tostring(err)) return end
    local keys = {}
    for k in pairs(d) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do print(string.format("  %-10s %s", k, tostring(d[k]))) end
    local res = P.simulateStop({ temp = d.temp, sat = d.sat, satMax = d.satMax,
        converted = d.converted, fuel = d.fuel }, cfg.game)
    print(string.format("A shutdown from now: %s after %.0f s, using %d fuel, peak %.0f C%s",
        res.finished and "OFFLINE" or "DOES NOT FINISH", res.ticks / 20, res.fuelUsed, res.peak,
        res.why and (" (" .. res.why .. ")") or ""))
end

if mode == "sides" then probeSides()
elseif mode == "stock" then probeStock()
elseif mode == "reactor" then probeReactor()
else
    listComponents()
    print("\nprobe sides | probe stock | probe reactor")
end
