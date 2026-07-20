-- Phase 0 discovery tool for the upcoming power control & display program.
-- Run this in-game to learn what the Lapotronic Supercapacitor (LSC) actually
-- exposes over an Adapter: its component type/address, its full method surface,
-- the LIVE values of every energy getter (numeric vs. string, to expose 2^53
-- precision loss), and the raw getSensorInformation() lines (where the LSC's
-- stored EU / average I/O / wireless-EU-network total are surfaced as text).
-- It also snapshots any redstone card so we know the side layout for the
-- generator control we build next. This tool is READ-ONLY: it never sets a
-- parameter, output, or work state.
--
-- Usage (from the folder this file lives in):
--   probe                  full spike: components, every gt_machine (deep),
--                          and the redstone snapshot
--   probe <addr|substr>    deep-probe only the gt_machine whose address starts
--                          with <addr> or whose getName() contains <substr>
--
-- Paste the output back so lsc.lua / config.lua can be finalized against the
-- real API instead of the documentation stubs.

local component = require("component")
local sides = require("sides")

local args = {...}
local filter = args[1]

-- gt_machine energy/status getters worth reading live. Ordered so the numeric
-- and string variants of the same value sit next to each other for comparison.
local READ_METHODS = {
    "getName",
    "getCoordinates",
    "isMachineActive",
    "isWorkAllowed",
    "getStoredEU",
    "getStoredEUString",
    "getEUStored",
    "getEUCapacity",
    "getEUCapacityString",
    "getEUMaxStored",
    "getEUInputAverage",
    "getEUOutputAverage",
    "getAverageElectricInput",
    "getAverageElectricOutput",
    "getInputVoltage",
    "getOutputVoltage",
    "getOutputAmperage",
}

-- Human-readable rendering of an arbitrary Lua return value (handles the
-- coordinates table, strings, booleans, nil).
local function fmt(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "table" then
        local parts = {}
        for i = 1, #v do parts[i] = tostring(v[i]) end
        return "{" .. table.concat(parts, ", ") .. "}"
    else
        return tostring(v)
    end
end

local function listComponents()
    local list = {}
    for addr, ctype in component.list() do
        list[#list + 1] = { addr = addr, type = ctype }
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        return a.addr < b.addr
    end)

    print("== Connected components ==")
    for _, c in ipairs(list) do
        print(string.format("%-26s %s", c.type, c.addr))
    end
    print("Total: " .. #list .. " components (this counts against the computer's budget)")
    print("")
end

-- Deep-probe one gt_machine: method dump, live energy values, sensor lines.
local function probeMachine(addr)
    local proxy = component.proxy(addr)
    if not proxy then
        print("!! could not proxy " .. tostring(addr))
        return
    end

    local ok, name = pcall(function() return proxy.getName() end)
    name = ok and name or "<getName failed>"
    print("========================================================")
    print("== gt_machine " .. addr)
    print("==   name = " .. tostring(name))
    print("========================================================")

    -- Full method surface with docs (same idiom as pump/probe.lua).
    print("-- METHODS --")
    local methods = component.methods(addr)
    local names = {}
    for m in pairs(methods) do names[#names + 1] = m end
    table.sort(names)
    for _, m in ipairs(names) do
        local direct = methods[m] and " [direct]" or ""
        local doc = component.doc(addr, m)
        print("- " .. m .. direct)
        if doc and doc ~= "" then print("    " .. doc) end
    end

    -- Live values. Presence-check first: OC proxy methods are callable tables,
    -- so test `~= nil` rather than type(x) == "function".
    print("-- LIVE VALUES --")
    for _, m in ipairs(READ_METHODS) do
        if proxy[m] ~= nil then
            local callOk, val = pcall(function() return proxy[m]() end)
            if callOk then
                print(string.format("  %-26s = %s  (%s)", m .. "()", fmt(val), type(val)))
            else
                print(string.format("  %-26s ! error: %s", m .. "()", tostring(val)))
            end
        else
            print(string.format("  %-26s (absent)", m .. "()"))
        end
    end

    -- Sensor information: the LSC surfaces stored EU, average I/O, %-full and
    -- the wireless EU network total here as human-readable strings. Numbered so
    -- we can reference lines when writing the parser.
    print("-- SENSOR INFO (getSensorInformation) --")
    if proxy.getSensorInformation ~= nil then
        local sOk, lines = pcall(function() return proxy.getSensorInformation() end)
        if sOk and type(lines) == "table" then
            for i = 1, #lines do
                print(string.format("  %2d| %s", i, tostring(lines[i])))
            end
            if #lines == 0 then print("  (returned an empty table)") end
        else
            print("  ! error or non-table: " .. tostring(lines))
        end
    else
        print("  (method absent)")
    end
    print("")
end

-- Does this machine match the user-supplied filter (address prefix or a
-- substring of its getName())?
local function matches(addr)
    if not filter then return true end
    if addr:sub(1, #filter) == filter then return true end
    local ok, name = pcall(function() return component.proxy(addr).getName() end)
    if ok and type(name) == "string" and name:lower():find(filter:lower(), 1, true) then
        return true
    end
    return false
end

local function probeMachines()
    local addrs = {}
    for addr in component.list("gt_machine") do
        if matches(addr) then addrs[#addrs + 1] = addr end
    end

    if #addrs == 0 then
        if filter then
            print("No gt_machine matched '" .. filter .. "'. Run `probe` with no argument to list all.")
        else
            print("== No gt_machine found ==")
            print("Place an Adapter block touching the LSC (and any other GT multiblock)")
            print("you want to read; it then appears as a `gt_machine` component here.")
        end
        print("")
        return
    end

    -- Show every candidate up front (name may not contain "supercapacitor",
    -- so we deep-probe all of them and let the reader identify the LSC).
    print("== gt_machine candidates (" .. #addrs .. ") ==")
    for _, addr in ipairs(addrs) do
        local ok, name = pcall(function() return component.proxy(addr).getName() end)
        local hint = ""
        if ok and type(name) == "string" then
            local low = name:lower()
            if low:find("supercapacitor", 1, true) or low:find("lapotronic", 1, true) then
                hint = "   <- likely LSC"
            end
        end
        print(string.format("  %s  %s%s", addr, ok and tostring(name) or "<getName failed>", hint))
    end
    print("")

    for _, addr in ipairs(addrs) do
        probeMachine(addr)
    end
end

-- Snapshot every redstone card: per-side input/output. Informational only --
-- tells us which card/side to drive when we add generator control.
local function probeRedstone()
    local found = false
    for addr in component.list("redstone") do
        found = true
        local rs = component.proxy(addr)
        print("== redstone " .. addr .. " ==")
        for i = 0, 5 do
            local inOk, inV = pcall(function() return rs.getInput(i) end)
            local outOk, outV = pcall(function() return rs.getOutput(i) end)
            print(string.format("  %-7s (%d)  in=%s  out=%s",
                sides[i], i,
                inOk and tostring(inV) or "?",
                outOk and tostring(outV) or "?"))
        end
        print("")
    end
    if not found then
        print("== No redstone component found ==")
        print("Add a Redstone Card (or I/O block) to drive generators later.")
        print("")
    end
end

-- Filtered runs target a single machine; only dump the full component list on a
-- plain `probe` so the noise stays low when zooming in on one LSC.
if not filter then
    listComponents()
end
probeMachines()
if not filter then
    probeRedstone()
end
