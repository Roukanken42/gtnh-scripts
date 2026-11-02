-- Lapotronic Supercapacitor (LSC) read wrapper -- the ONE place that talks to
-- the battery. The controller only ever calls lsc.discover() and LSC:read(),
-- so all knowledge of the gt_machine getters and the getSensorInformation()
-- text layout lives here.
--
-- Large EU values are kept as bignum DIGIT STRINGS, never int64 (see bignum.lua
-- for why). Everything comes from a SINGLE getSensorInformation() call so the
-- read stays cheap; the *String getters are only a fallback if a line is missing:
--   storedEU   <- eu_stored sensor line      (fallback: getStoredEUString())
--   capacityEU <- total_capacity sensor line (fallback: getEUCapacityString())
--   fill       <- used_capacity sensor line  (robust to the capacity clamp)
--   wirelessEU <- wireless_eu sensor line    (ONLY source -- no getter)
-- Small live rates (EU IN/OUT per tick, averages, passive loss) stay numbers.

local component = require("component")
local util = require("util")
local bignum = require("bignum")

local LSC = {}
LSC.__index = LSC

local MACHINE_TYPE = "gt_machine"
local NAME_MATCH = "supercapacitor" -- getName() is "multimachine.supercapacitor"

-- Wireless mode balances the LSC's stored EU toward a "wireless threshold" every
-- 5 minutes (from both above and below). The threshold is the sum of each
-- high-tier capacitor's contribution, so it caps sustained wireless output at
-- threshold / 5min. Per-capacitor contributions (EU):
local CAP_ORDER = { "UHV", "UEV", "UIV", "UMV" }
local CAP_SI = { UHV = "60T", UEV = "6P", UIV = "600P", UMV = "60E" }
local CAP_EU = {}
for _, t in ipairs(CAP_ORDER) do CAP_EU[t] = bignum.expandSI(CAP_SI[t]) end
local BALANCE_TICKS = 5 * 60 * 20 -- 5 minutes, in ticks (20/s)

function LSC.new(address, proxy)
    local self = setmetatable({}, LSC)
    self.address = address
    self.proxy = proxy or component.proxy(address)
    return self
end

-- Call a proxy method by name, guarded. Returns nil if absent or on error
-- (OC proxy methods are callable tables, so test for presence with ~= nil).
local function call(proxy, name)
    if proxy[name] == nil then return nil end
    local ok, v = pcall(function() return proxy[name]() end)
    if ok then return v end
    return nil
end

-- ---- sensor lines ------------------------------------------------------------
-- Since GTNH 2.9 getSensorInformation() no longer returns English text. Each line
-- is a translation KEY followed by its arguments, joined with two backslashes
-- (IGregTechDeviceInformation.encode), and the client translates it:
--   kekztech.infodata.lapotronic_super_capacitor.eu_stored\\5,966,027,357,201,980
--   kekztech.infodata.lapotronic_super_capacitor.capacitors\\§5§nUEV§r\\1
-- So everything is matched on the key, which does not depend on language. The
-- numbers are formatted in the SERVER's locale (grouping commas on an English
-- one). Some keys appear twice, the second time in scientific form ("x10^").
local KEY = "kekztech.infodata.lapotronic_super_capacitor."
local SEP = "\\\\"   -- the two-backslash separator, as a plain (non-pattern) string

-- Splits one sensor line into its key and its arguments. Colour codes and the
-- \1 marker for an argument that is itself a translation key are stripped.
local function splitLine(raw)
    local parts, pos = {}, 1
    while true do
        local i = raw:find(SEP, pos, true)
        parts[#parts + 1] = raw:sub(pos, (i or 0) - 1)
        if not i then break end
        pos = i + #SEP
    end
    for n = 1, #parts do
        parts[n] = (util.stripColor(parts[n]):gsub("\1", ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local key = table.remove(parts, 1)
    return key, parts
end

-- The first argument of the first line with this key (relative to KEY unless it
-- starts with "kekztech."), skipping the scientific duplicate. nil if absent.
local function sensorArg(lines, key)
    if key:sub(1, 9) ~= "kekztech." then key = KEY .. key end
    for _, l in ipairs(lines) do
        local a = l.args[1]
        if l.key == key and a and not a:find("10^", 1, true) then return a end
    end
    return nil
end

-- True if any line has exactly this key (relative to KEY unless absolute).
local function hasKey(lines, key)
    if key:sub(1, 9) ~= "kekztech." then key = KEY .. key end
    for _, l in ipairs(lines) do
        if l.key == key then return true end
    end
    return false
end

-- Reads a full, read-only snapshot of the LSC. Every field is optional-safe;
-- anything unreadable is left nil (or 0 for summed rates).
function LSC:read()
    local proxy = self.proxy
    local s = { present = true, address = self.address }

    -- Sensor lines, split into { key, args }.
    local lines = {}
    local sensor = call(proxy, "getSensorInformation")
    if type(sensor) == "table" then
        for i = 1, #sensor do
            local key, args = splitLine(tostring(sensor[i]))
            lines[i] = { key = key, args = args }
        end
    end
    s.sensor = lines

    -- Stored EU / capacity: parse from the sensor lines already fetched above;
    -- only fall back to the (extra) string getters if a line is missing. This
    -- keeps the whole read to a single getSensorInformation() call.
    local storedLine = sensorArg(lines, "eu_stored")
    if storedLine then
        s.storedEU = util.parseGrouped(storedLine)
    else
        local g = call(proxy, "getStoredEUString")
        s.storedEU = g and bignum.norm(g) or "0"
    end
    local capLine = sensorArg(lines, "total_capacity")
    if capLine then
        s.capacityEU = util.parseGrouped(capLine)
    else
        local g = call(proxy, "getEUCapacityString")
        s.capacityEU = g and bignum.norm(g) or "0"
    end

    -- Fill fraction: prefer the game's own "Used Capacity %" (sidesteps the
    -- capacity-getter clamp); fall back to the string ratio.
    local usedPct = util.parseDecimal(sensorArg(lines, "used_capacity") or "")
    if usedPct ~= nil then
        s.fill = math.max(0, math.min(1, usedPct / 100))
    else
        s.fill = math.max(0, math.min(1, bignum.ratio(s.storedEU, s.capacityEU)))
    end

    -- Wireless network: mode flag + the global pool total (sensor-only).
    s.wirelessEnabled = hasKey(lines, "wireless_mode.enabled")
    s.wirelessEU = util.parseGrouped(sensorArg(lines, "wireless_eu") or "0")

    -- Flow rates (EU/t numbers). Big lasers transport power in huge bursts, so
    -- the instantaneous / 5-second figures are far too spiky to control on -- use
    -- the 5-MINUTE averages. The per-tick line and the getter are only fallbacks
    -- if the 5-minute line is missing. In WIRELESS mode these are useless for net
    -- flow: the 5-minute rebalance against the wireless network counts as LSC
    -- input/output too, so main.lua measures net flow by diffing totals instead.
    s.euIn = util.parseDecimal(sensorArg(lines, "avg_eu_in.min5") or "")
        or util.parseDecimal(sensorArg(lines, "eu_in") or "")
        or call(proxy, "getEUInputAverage") or 0
    s.euOut = util.parseDecimal(sensorArg(lines, "avg_eu_out.min5") or "")
        or util.parseDecimal(sensorArg(lines, "eu_out") or "")
        or call(proxy, "getEUOutputAverage") or 0
    s.passiveLoss = util.parseDecimal(sensorArg(lines, "passive_loss") or "") or 0
    s.net = s.euIn - s.euOut - s.passiveLoss

    -- nil when the line is missing, so the UI only warns on a definite "bad".
    if hasKey(lines, "kekztech.infodata.multi.maintenance_status.bad") then
        s.maintenance = "needs maintenance"
    elseif hasKey(lines, "kekztech.infodata.multi.maintenance_status.ok") then
        s.maintenance = "ok"
    end

    -- Wireless threshold from the high-tier capacitor counts (one "capacitors"
    -- line per tier, args { "<tier>", "<count>" }, colour-stripped above). The
    -- threshold can exceed 2^64 (UMV contributes 60E each), so it stays a bignum
    -- string. Sustained wireless output cannot exceed threshold / 5min ->
    -- outputCap EU/t.
    local caps, threshold = {}, "0"
    for _, tier in ipairs(CAP_ORDER) do
        local n = 0
        for _, l in ipairs(lines) do
            if l.key == KEY .. "capacitors" and l.args[1] == tier then
                n = math.floor(util.parseDecimal(l.args[2] or "") or 0)
                break
            end
        end
        caps[tier] = n
        if n > 0 then threshold = bignum.add(threshold, bignum.mulSmall(CAP_EU[tier], n)) end
    end
    s.capacitors = caps
    s.wirelessThreshold = threshold
    s.outputCap = threshold ~= "0" and (bignum.approx(threshold) / BALANCE_TICKS) or nil

    return s
end

local lsc = {}

-- Find the LSC on the component network: the first gt_machine whose getName()
-- contains "supercapacitor". Returns an LSC object, or nil + a message.
function lsc.discover()
    for addr in component.list(MACHINE_TYPE) do
        local proxy = component.proxy(addr)
        local ok, name = pcall(function() return proxy.getName() end)
        if ok and type(name) == "string" and name:lower():find(NAME_MATCH, 1, true) then
            return LSC.new(addr, proxy)
        end
    end
    return nil, "no supercapacitor found -- place an Adapter touching the LSC (try `probe`)"
end

lsc.LSC = LSC
lsc.TYPE = MACHINE_TYPE

return lsc
