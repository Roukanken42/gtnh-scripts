local internet = require("internet")
local filesystem = require("filesystem")
local shell = require("shell")

-- =============================== CONFIG ===============================
-- Base "raw file" URL of the repo, WITHOUT a trailing slash.
-- GitLab raw URL format: https://gitlab.com/<user>/<repo>/-/raw
local REPO   = "https://gitlab.com/Roukanken/gtnh-scripts/-/raw"
local BRANCH = "main"
-- File in the repo that lists every file to install (one path per line).
local MANIFEST = "manifest"
-- ======================================================================

-- Optional first argument: install only paths starting with this prefix,
-- e.g. `install aether` installs just the files under aether/.
local args = {...}
local filter = args[1]

local baseUrl = REPO .. "/" .. BRANCH .. "/"
local cwd = shell.getWorkingDirectory()

local function abs(path)
    return filesystem.concat(cwd, path)
end

-- Downloads a file from the repo. Returns its contents, or nil + error.
local function download(path)
    local ok, result = pcall(internet.request, baseUrl .. path)
    if not ok then
        return nil, tostring(result)
    end

    local chunks = {}
    local ok2, err = pcall(function()
        for chunk in result do
            chunks[#chunks + 1] = chunk
        end
    end)
    if not ok2 then
        return nil, tostring(err)
    end

    return table.concat(chunks)
end

-- Writes content to a path (relative to the working directory),
-- creating any missing parent directories first.
local function writeFile(path, content)
    local full = abs(path)
    local dir = filesystem.path(full)
    if dir and dir ~= "" and not filesystem.exists(dir) then
        filesystem.makeDirectory(dir)
    end

    local file, err = io.open(full, "w")
    if not file then
        return false, err
    end
    file:write(content)
    file:close()
    return true
end

-- Parses the manifest text into a list of { path, keepIfExists } entries.
-- Format, one entry per line:
--   path/to/file.lua      -- always (re)downloaded, overwriting local copy
--   ? path/to/config.lua  -- only downloaded if it does NOT already exist
--   # comment             -- ignored (as are blank lines)
local function parseManifest(text)
    local entries = {}
    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local keepIfExists = false
            if line:sub(1, 1) == "?" then
                keepIfExists = true
                line = line:sub(2):match("^%s*(.-)%s*$")
            end
            entries[#entries + 1] = { path = line, keepIfExists = keepIfExists }
        end
    end
    return entries
end

print("Fetching manifest from " .. baseUrl .. MANIFEST)
local manifestText, err = download(MANIFEST)
if not manifestText then
    print("ERROR: could not download manifest: " .. tostring(err))
    return
end

local entries = parseManifest(manifestText)
local installed, kept, failed = 0, 0, 0

for _, entry in ipairs(entries) do
    if filter and entry.path:sub(1, #filter) ~= filter then
        -- outside the requested prefix, skip silently
    elseif entry.keepIfExists and filesystem.exists(abs(entry.path)) then
        print("  keep   " .. entry.path)
        kept = kept + 1
    else
        local content, derr = download(entry.path)
        if not content then
            print("  FAIL   " .. entry.path .. " (" .. tostring(derr) .. ")")
            failed = failed + 1
        else
            local ok, werr = writeFile(entry.path, content)
            if ok then
                print("  ok     " .. entry.path)
                installed = installed + 1
            else
                print("  FAIL   " .. entry.path .. " (" .. tostring(werr) .. ")")
                failed = failed + 1
            end
        end
    end
end

print(string.format("Done: %d installed, %d kept, %d failed.", installed, kept, failed))
if failed > 0 then
    print("Some files failed - check the URL/branch in install.lua and your Internet Card.")
end
if installed > 0 then
    print("Reboot before running (or `reboot`) so updated libraries reload -")
    print("OpenComputers caches required modules until the computer restarts.")
end