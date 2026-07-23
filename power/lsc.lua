-- Lapotronic Supercapacitor (LSC) read wrapper -- the ONE place that talks to
-- the battery. The controller only ever calls lsc.discover() and LSC:read(),
-- so all knowledge of the gt_machine getters and the getSensorInformation()
-- text layout lives here.
--
-- Large EU values are kept as bignum DIGIT STRINGS, never int64 (see bignum.lua
-- for why). Everything comes from a SINGLE getSensorInformation() call so the
-- read stays cheap; the *String getters are only a fallback if a line is missing:
--   storedEU   <- "EU Stored:" sensor line   (fallback: getStoredEUString())
--   capacityEU <- "Total Capacity:" sensor line (fallback: getEUCapacityString())
--   fill       <- "Used Capacity:" sensor line (robust to the capacity clamp)
--   wirelessEU <- "Total wireless EU:" sensor line (ONLY source -- no getter)
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

-- Value after a "Label:" prefix, from the first stripped sensor line that starts
-- with `prefix`, is NOT the scientific ("x10^") duplicate, and (if `contains` is
-- given) also contains that substring -- used to pick a specific averaging window
-- among the several "Avg EU IN:" lines. Returns nil if no such line exists.
local function sensorValue(lines, prefix, contains)
    for _, line in ipairs(lines) do
        if line:sub(1, #prefix) == prefix and not line:find("10^", 1, true)
            and (not contains or line:find(contains, 1, true)) then
            return (line:sub(#prefix + 1):gsub("^%s+", ""):gsub("%s+$", ""))
        end
    end
    return nil
end

-- Reads a full, read-only snapshot of the LSC. Every field is optional-safe;
-- anything unreadable is left nil (or 0 for summed rates).
function LSC:read()
    local proxy = self.proxy
    local s = { present = true, address = self.address }

    -- Raw sensor lines, colour-stripped and trimmed.
    local lines = {}
    local sensor = call(proxy, "getSensorInformation")
    if type(sensor) == "table" then
        for i = 1, #sensor do
            lines[i] = (util.stripColor(tostring(sensor[i])):gsub("^%s+", ""))
        end
    end
    s.sensor = lines

    -- Stored EU / capacity: parse from the sensor lines already fetched above;
    -- only fall back to the (extra) string getters if a line is missing. This
    -- keeps the whole read to a single getSensorInformation() call.
    local storedLine = sensorValue(lines, "EU Stored:")
    if storedLine then
        s.storedEU = util.parseGrouped(storedLine)
    else
        local g = call(proxy, "getStoredEUString")
        s.storedEU = g and bignum.norm(g) or "0"
    end
    local capLine = sensorValue(lines, "Total Capacity:")
    if capLine then
        s.capacityEU = util.parseGrouped(capLine)
    else
        local g = call(proxy, "getEUCapacityString")
        s.capacityEU = g and bignum.norm(g) or "0"
    end

    -- Fill fraction: prefer the game's own "Used Capacity %" (sidesteps the
    -- capacity-getter clamp); fall back to the string ratio.
    local usedPct = util.parseDecimal(sensorValue(lines, "Used Capacity:") or "")
    if usedPct ~= nil then
        s.fill = math.max(0, math.min(1, usedPct / 100))
    else
        s.fill = math.max(0, math.min(1, bignum.ratio(s.storedEU, s.capacityEU)))
    end

    -- Wireless network: mode flag + the global pool total (sensor-only).
    local mode = sensorValue(lines, "Wireless mode:")
    s.wirelessEnabled = mode ~= nil and mode:lower():find("enabled", 1, true) ~= nil
        and not mode:lower():find("disabled", 1, true)
    s.wirelessEU = util.parseGrouped(sensorValue(lines, "Total wireless EU:") or "0")

    -- Flow rates (EU/t numbers). Big lasers transport power in huge bursts, so
    -- the instantaneous / 5-second figures are far too spiky to control on -- use
    -- the 5-MINUTE averages for net flow and the fill/drain ETA. The per-tick
    -- line and the getter are only fallbacks if the 5-minute line is missing.
    s.euIn = util.parseDecimal(sensorValue(lines, "Avg EU IN:", "5 minute") or "")
        or util.parseDecimal(sensorValue(lines, "EU IN:") or "")
        or call(proxy, "getEUInputAverage") or 0
    s.euOut = util.parseDecimal(sensorValue(lines, "Avg EU OUT:", "5 minute") or "")
        or util.parseDecimal(sensorValue(lines, "EU OUT:") or "")
        or call(proxy, "getEUOutputAverage") or 0
    s.passiveLoss = util.parseDecimal(sensorValue(lines, "Passive Loss:") or "") or 0
    s.net = s.euIn - s.euOut - s.passiveLoss

    s.maintenance = sensorValue(lines, "Maintenance Status:")

    -- Wireless threshold from the high-tier capacitor counts (lines like
    -- "UHV Capacitors detected: 1", colour-stripped above). The threshold can
    -- exceed 2^64 (UMV contributes 60E each), so it stays a bignum string.
    -- Sustained wireless output cannot exceed threshold / 5min -> outputCap EU/t.
    local caps, threshold = {}, "0"
    for _, tier in ipairs(CAP_ORDER) do
        local n = 0
        for _, line in ipairs(lines) do
            local m = line:match("^" .. tier .. "%s+[Cc]apacitors?%s+detected:%s*(%d+)")
            if m then n = math.floor(tonumber(m) or 0); break end
        end
        caps[tier] = n
        if n > 0 then threshold = bignum.add(threshold, bignum.mulSmall(CAP_EU[tier], n)) end
    end
    s.capacitors = caps
    s.wirelessThreshold = threshold
    s.outputCap = threshold ~= "0" and (bignum.approx(threshold) / BALANCE_TICKS) or nil

    -- ETA in seconds (20 ticks/s), from approximate magnitudes (display only).
    local perSec = s.net * 20
    local capA = bignum.approx(s.capacityEU)
    local storedA = bignum.approx(s.storedEU)
    if perSec > 0 then
        s.timeToFull = math.max(0, capA - storedA) / perSec
    elseif perSec < 0 then
        s.timeToEmpty = storedA / (-perSec)
    end

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
