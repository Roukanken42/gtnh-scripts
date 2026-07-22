-- Small shared helpers for the power controller.

local bignum = require("bignum")

local util = {}

-- SI multipliers for parsing small human-written magnitudes into a number.
local SI = { k = 1e3, K = 1e3, M = 1e6, G = 1e9, T = 1e12, P = 1e15, E = 1e18 }

-- Parse a generator output written as a number or an SI string ("3.2M", "32M")
-- into a plain Lua number. Used for the (small) per-generator EU/t figures that
-- are summed and displayed -- NOT for the huge LSC/wireless values (those stay
-- as bignum strings). Returns 0 on garbage so a typo can't crash the controller.
function util.parseNum(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return 0 end
    local s = v:gsub(",", ""):gsub("%s", "")
    local mant, suf = s:match("^([%d%.]+)([kKMGTPE]?)$")
    if not mant then return tonumber(s) or 0 end
    local n = tonumber(mant) or 0
    return n * ((suf ~= "" and SI[suf]) or 1)
end

-- Strip Minecraft formatting codes. The section sign is UTF-8 0xC2 0xA7 followed
-- by one code char; also handle a bare 0xA7 just in case.
function util.stripColor(s)
    if type(s) ~= "string" then return s end
    s = (s:gsub("\xC2\xA7.", ""))
    s = (s:gsub("\xA7.", ""))
    return s
end

-- Normalise a large grouped EU string ("58,885,155,470,742,406 EU") to a
-- canonical digit string for bignum use.
function util.parseGrouped(s)
    return bignum.norm(s)
end

-- Parse a small decimal (percentages, per-tick rates) out of a sensor value,
-- keeping digits, one dot and a leading minus. "0.638400%" -> 0.6384,
-- "2,621,440 EU/t" -> 2621440. Returns nil if no number is present.
function util.parseDecimal(s)
    if type(s) ~= "string" then return nil end
    local body = s:match(":%s*(.*)$") or s          -- drop a leading "Label:"
    body = body:gsub(",", "")
    local m = body:match("%-?%d+%.?%d*")
    return m and tonumber(m) or nil
end

return util
