-- Arbitrary-size non-negative integer arithmetic on decimal strings.
--
-- The LSC's stored/capacity numeric getters clamp at Java's long (2^63-1), and
-- the wireless EU network total will exceed 2^64 (its cap is ~2^(2^32),
-- effectively infinite). So the large EU values are read as STRINGS -- either
-- from the dedicated getStoredEUString()/getEUCapacityString() getters or from
-- getSensorInformation() text -- and handled here as plain digit strings, never
-- forced through a 64-bit Lua integer.
--
-- Only what the controller actually needs: canonicalise, compare, an overflow-
-- safe approximate ratio (for the 0..1 level and for display), and SI expansion
-- for the wireless operating band in config.

local bignum = {}

-- Canonical digit string: strip commas/whitespace/units, take the digit run,
-- drop leading zeros. Numbers are formatted without exponent first so a large
-- double does not arrive as "5.8e+16". Result is "0" or a leading-digit string.
function bignum.norm(v)
    local s
    if type(v) == "number" then
        s = string.format("%.0f", v)
    else
        s = tostring(v)
    end
    s = s:gsub(",", ""):gsub("%s", "")
    s = s:match("%d+") or "0"
    s = s:gsub("^0+", "")
    return s == "" and "0" or s
end

-- Compare two big integers: -1 if a<b, 0 if equal, 1 if a>b.
function bignum.cmp(a, b)
    a = bignum.norm(a)
    b = bignum.norm(b)
    if #a ~= #b then return #a < #b and -1 or 1 end
    if a == b then return 0 end
    return a < b and -1 or 1
end

-- Approximate a/b as a Lua number, computed from the leading ~15 significant
-- digits plus the length difference, so it never overflows even for 100-digit
-- inputs. Good to ~15 significant figures -- ample for a 0..1 level or a bar.
-- Returns math.huge if b == 0, 0 if a == 0.
function bignum.ratio(a, b)
    a = bignum.norm(a)
    b = bignum.norm(b)
    if b == "0" then return math.huge end
    if a == "0" then return 0 end
    local la, lb = #a, #b
    local ka = math.min(15, la)
    local kb = math.min(15, lb)
    local na = tonumber(a:sub(1, ka))
    local nb = tonumber(b:sub(1, kb))
    -- a ~= na * 10^(la-ka),  b ~= nb * 10^(lb-kb)
    local exp = (la - ka) - (lb - kb)
    return (na / nb) * 10 ^ exp
end

-- Approximate value of a big integer as a Lua number (for ETAs / display math).
function bignum.approx(a)
    return bignum.ratio(a, "1")
end

-- SI multipliers (k .. Q) as powers of ten. Used for the wireless band, whose
-- values (e.g. "1E" = 1e18 EU) exceed what a Lua number can hold exactly.
local SI = { k = 3, K = 3, M = 6, G = 9, T = 12, P = 15, E = 18, Z = 21, Y = 24, R = 27, Q = 30 }

-- Expand an SI-suffixed decimal string ("1E", "500T", "3.2P") to a digit string.
-- Numbers and plain digit strings pass through norm. Sub-unit fractions are
-- truncated (EU is integer-valued). Returns a canonical digit string.
function bignum.expandSI(v)
    if type(v) == "number" then return bignum.norm(v) end
    local s = tostring(v):gsub(",", ""):gsub("%s", "")
    local mant, suf = s:match("^([%d%.]+)([kKMGTPEZYRQ]?)$")
    if not mant then return bignum.norm(s) end
    local exp = (suf ~= "" and SI[suf]) or 0
    local intp, frac = mant:match("^(%d*)%.?(%d*)$")
    intp = intp or ""
    frac = frac or ""
    local digits = (intp .. frac):gsub("^0+", "")
    local zeros = exp - #frac
    local out
    if zeros >= 0 then
        out = digits .. string.rep("0", zeros)
    else
        out = digits:sub(1, math.max(0, #digits + zeros)) -- truncate sub-unit tail
    end
    out = out:gsub("^0+", "")
    return out == "" and "0" or out
end

return bignum
