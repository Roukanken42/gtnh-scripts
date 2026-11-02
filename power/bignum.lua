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

-- a - b as a Lua number, computed exactly on the digit strings, so it stays
-- precise however big the operands are -- bignum.approx keeps only ~15 digits,
-- which on a 10^18 EU total is an error of thousands of EU. The RESULT must fit a
-- double exactly (|a - b| < 2^53), which an energy delta over a minute does.
function bignum.diff(a, b)
    a = bignum.norm(a)
    b = bignum.norm(b)
    local sign = 1
    if bignum.cmp(a, b) < 0 then a, b, sign = b, a, -1 end
    local i, j, borrow = #a, #b, 0
    local out = {}
    while i > 0 do
        local d = tonumber(a:sub(i, i)) - (j > 0 and tonumber(b:sub(j, j)) or 0) - borrow
        if d < 0 then d, borrow = d + 10, 1 else borrow = 0 end
        out[#out + 1] = d
        i, j = i - 1, j - 1
    end
    local s = {}
    for k = #out, 1, -1 do s[#s + 1] = out[k] end
    return sign * (tonumber((table.concat(s):gsub("^0+", ""))) or 0)
end

-- Exact addition of two big integers (schoolbook, on digit strings). Used to
-- combine LSC stored/capacity with the wireless pool for the energy level/bar.
function bignum.add(a, b)
    a = bignum.norm(a)
    b = bignum.norm(b)
    local i, j, carry = #a, #b, 0
    local out = {}
    while i > 0 or j > 0 or carry > 0 do
        local da = i > 0 and tonumber(a:sub(i, i)) or 0
        local db = j > 0 and tonumber(b:sub(j, j)) or 0
        local sum = da + db + carry
        out[#out + 1] = tostring(sum % 10)
        carry = math.floor(sum / 10)
        i, j = i - 1, j - 1
    end
    return bignum.norm(table.concat(out):reverse())
end

-- Multiply a big integer by a small non-negative Lua integer (schoolbook). Used
-- to scale a per-capacitor wireless-threshold contribution by its count.
function bignum.mulSmall(a, n)
    a = bignum.norm(a)
    if a == "0" or n == 0 then return "0" end
    local carry, out = 0, {}
    for i = #a, 1, -1 do
        local prod = tonumber(a:sub(i, i)) * n + carry
        out[#out + 1] = tostring(prod % 10)
        carry = math.floor(prod / 10)
    end
    while carry > 0 do
        out[#out + 1] = tostring(carry % 10)
        carry = math.floor(carry / 10)
    end
    return bignum.norm(table.concat(out):reverse())
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
