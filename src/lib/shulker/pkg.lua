-- Shulker OS updates and the small package repository, straight from GitHub.
--
--   <repo>/manifest.txt              the OS itself: "version X" then "<sha256> <size> <path>" per file (paths in src/)
--   <repo>/packages/index.txt        "<name> <version> <description>" per package
--   <repo>/packages/<name>/PKG       "version X", "description ...", "file <sha256> <size> <path>"
--
-- Everything is downloaded to /tmp first and checked against the SHA-256 sums before anything is
-- replaced. Note the sums come over the same (unverified) TLS as the files: they catch broken or
-- truncated downloads, not a determined man-in-the-middle. Packages install to /usr/local/shulker.
local U = require("shulker.util")
local M = {}

M.DEFAULT_REPO = "https://raw.githubusercontent.com/LinuxDino/ShulkerOS"
M.PKGROOT = os.getenv("SHULKER_PKGROOT") or "/usr/local/shulker"
M.BINDIR = os.getenv("SHULKER_BINDIR") or "/usr/local/bin"

---------------------------------------------------------------- repo location
function M.conf()
  local c = { repo = M.DEFAULT_REPO, branch = "main" }
  for _, line in ipairs(U.lines(U.etcdir() .. "/repo.conf")) do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and v ~= "" then c[k] = v end
  end
  if os.getenv("SHULKER_REPO") then c.repo = os.getenv("SHULKER_REPO") end
  if os.getenv("SHULKER_BRANCH") then c.branch = os.getenv("SHULKER_BRANCH") end
  return c
end

function M.base(branch)
  local c = M.conf()
  return c.repo .. "/" .. (branch or c.branch)
end

function M.saveBranch(branch)
  U.mkdir(U.etcdir())
  local lines, found = {}, false
  for _, line in ipairs(U.lines(U.etcdir() .. "/repo.conf")) do
    if line:match("^%s*branch%s*=") then lines[#lines + 1] = "branch=" .. branch found = true
    else lines[#lines + 1] = line end
  end
  if not found then lines[#lines + 1] = "branch=" .. branch end
  U.write(U.etcdir() .. "/repo.conf", table.concat(lines, "\n") .. "\n")
end

---------------------------------------------------------------- downloading
-- curl with a CA bundle (Shulker Linux) checks certificates; BusyBox wget (stock Sedna) cannot
function M.verifiedTLS()
  if M._vtls == nil then
    M._vtls = U.which("curl") ~= nil and U.exists("/etc/ssl/certs/ca-certificates.crt")
  end
  return M._vtls
end

function M.fetch(url, dest)
  local cmd = M.verifiedTLS() and "curl -fsSL --max-time 120 -o %s %s" or "wget -q -T 30 -O %s %s"
  local out, code = U.capture(cmd:format(U.q(dest), U.q(url)))
  if code ~= 0 then
    os.remove(dest)
    out = out:gsub("wget: note: TLS certificate validation not implemented\n?", "")
    return nil, ("download failed: %s %s"):format(url, U.trim(out))
  end
  return true
end

function M.fetchText(url)
  local tmp = os.tmpname()
  local ok, err = M.fetch(url, tmp)
  if not ok then os.remove(tmp) return nil, err end
  local s = U.read(tmp)
  os.remove(tmp)
  return s
end

function M.sha256(path)
  local out = U.capture("sha256sum " .. U.q(path))
  return out:match("^(%x+)")
end

function M.freeKB(path)
  while path ~= "" and not U.isdir(path) do path = path:match("^(.*)/[^/]*$") or "" end
  local out = U.capture("df -k " .. U.q(path ~= "" and path or "/") .. " | tail -n 1")
  local f = {}
  for w in out:gmatch("%S+") do f[#f + 1] = w end
  return tonumber(f[4] or "")
end

-- parse "<sha> <size> <path>" lines (optionally prefixed with "file ")
function M.parseFiles(text)
  local files, meta = {}, {}
  for line in (text or ""):gmatch("[^\n]+") do
    local sha, size, path = line:match("^file%s+(%x+)%s+(%d+)%s+(%S+)$")
    if not sha then sha, size, path = line:match("^(%x+)%s+(%d+)%s+(%S+)$") end
    if sha and #sha == 64 then
      if path:find("%.%.") or path:sub(1, 1) == "/" then return nil, "unsafe path in manifest: " .. path end
      files[#files + 1] = { sha = sha:lower(), size = tonumber(size), path = path }
    else
      local k, v = line:match("^(%a+)%s+(.+)$")
      if k then meta[k] = v end
    end
  end
  return files, meta
end

-- download every file to a staging dir and verify it; returns staging dir | nil, why
function M.stage(baseUrl, files, progress)
  local stage = "/tmp/shulker-stage-" .. os.time()
  os.execute("rm -rf " .. U.q(stage))
  U.mkdir(stage)
  for i, f in ipairs(files) do
    if progress then progress(i, #files, f.path) end
    local dest = stage .. "/" .. f.path
    U.mkdir(dest:match("^(.*)/[^/]*$"))
    local ok, err = M.fetch(baseUrl .. "/" .. f.path, dest)
    if not ok then os.execute("rm -rf " .. U.q(stage)) return nil, err end
    local sum = M.sha256(dest)
    if sum ~= f.sha then
      os.execute("rm -rf " .. U.q(stage))
      return nil, ("checksum mismatch for %s (got %s, want %s)"):format(f.path, tostring(sum):sub(1, 12), f.sha:sub(1, 12))
    end
  end
  return stage
end

-- move staged files into root (keeps the executable bit for bin/ files)
local function install(stage, files, root)
  for _, f in ipairs(files) do
    local dest = root .. "/" .. f.path
    U.mkdir(dest:match("^(.*)/[^/]*$"))
    local ok = os.execute(("cp %s %s.new && mv %s.new %s"):format(U.q(stage .. "/" .. f.path), U.q(dest), U.q(dest), U.q(dest)))
    if not ok then return nil, "could not write " .. dest end
    if f.path:match("^bin/") or f.path:match("^etc/rc%.") then os.execute("chmod 755 " .. U.q(dest)) end
  end
  return true
end
M.install = install

---------------------------------------------------------------- updating the OS
function M.writable()
  local home = U.home()
  if home:find("^/mnt/builtin") then
    return nil, "Shulker OS runs from the data pack (/mnt/builtin is read-only). Update the data pack, or run the installer to put a copy on the disk."
  end
  return true
end

-- check: only report. returns { current, latest, changed = n } | nil, why
function M.update(opts)
  opts = opts or {}
  local ok, why = M.writable()
  if not ok then return nil, why end
  local base = M.base(opts.branch)
  local text, err = M.fetchText(base .. "/manifest.txt")
  if not text then return nil, err end
  local files, meta = M.parseFiles(text)
  if not files then return nil, meta end
  if #files == 0 then return nil, "the manifest lists no files" end
  local home = U.home()
  local changed, need = {}, 0
  for _, f in ipairs(files) do
    if M.sha256(home .. "/" .. f.path) ~= f.sha then changed[#changed + 1] = f need = need + f.size end
  end
  local info = { current = U.trim(U.read(home .. "/VERSION") or "?"), latest = meta.version or "?", changed = #changed }
  if opts.check or #changed == 0 then return info end
  local free = M.freeKB(home)
  if free and need / 1024 + 64 > free then
    return nil, ("not enough disk space: the update needs %d KB, %d KB free"):format(math.ceil(need / 1024) + 64, free)
  end
  local stage, serr = M.stage(base .. "/src", changed, opts.progress)
  if not stage then return nil, serr end
  local okI, ierr = install(stage, changed, home)
  os.execute("rm -rf " .. U.q(stage))
  if not okI then return nil, ierr end
  -- files that are no longer part of the OS
  local keep = {}
  for _, f in ipairs(files) do keep[f.path] = true end
  local old = M.parseFiles(U.read(home .. "/manifest.txt") or "") or {}
  for _, f in ipairs(old) do if not keep[f.path] then os.remove(home .. "/" .. f.path) end end
  U.write(home .. "/manifest.txt", text)
  if opts.branch then M.saveBranch(opts.branch) end
  M.refreshSystem()
  return info
end

-- keep the files outside SHULKER_HOME (profile, boot script, branding) in step with the new version
function M.refreshSystem()
  local home = U.home()
  if U.isdir("/etc/profile.d") then os.execute(("cp %s /etc/profile.d/shulker.sh"):format(U.q(home .. "/etc/profile.sh"))) end
  if U.exists("/etc/init.d/S95shulker") then
    os.execute(("cp %s /etc/init.d/S95shulker && chmod 755 /etc/init.d/S95shulker"):format(U.q(home .. "/etc/rc.shulker")))
  end
  if not U.exists(U.etcdir() .. "/no-branding") then
    os.execute(("cp %s /etc/issue 2>/dev/null; cp %s /etc/motd 2>/dev/null"):format(U.q(home .. "/share/issue"), U.q(home .. "/share/motd")))
  end
end

---------------------------------------------------------------- packages
function M.installedPath() return M.PKGROOT .. "/installed" end

function M.installed()
  local out = {}
  for _, line in ipairs(U.lines(M.installedPath())) do
    local name, ver = line:match("^(%S+)%s+(%S+)")
    if name then out[name] = ver out[#out + 1] = name end
  end
  return out
end

local function saveInstalled(set)
  U.mkdir(M.PKGROOT)
  local lines = {}
  local names = {}
  for k, v in pairs(set) do if type(k) == "string" then names[#names + 1] = k end end
  table.sort(names)
  for _, n in ipairs(names) do lines[#lines + 1] = n .. " " .. set[n] end
  U.write(M.installedPath(), table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

function M.index()
  local text, err = M.fetchText(M.base() .. "/packages/index.txt")
  if not text then return nil, err end
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local name, ver, desc = line:match("^([%w%-_]+)%s+(%S+)%s+(.*)$")
    if name then out[#out + 1] = { name = name, version = ver, description = desc } out[name] = out[#out] end
  end
  return out
end

local function pkgFiles(name)
  local text, err = M.fetchText(M.base() .. "/packages/" .. name .. "/PKG")
  if not text then return nil, err end
  return M.parseFiles(text)
end

function M.installPkg(name, progress)
  if not name:match("^[%w%-_]+$") then return nil, "bad package name" end
  local files, meta = pkgFiles(name)
  if not files then return nil, ("no package %q (see `shulker list`): %s"):format(name, tostring(meta)) end
  local need = 0
  for _, f in ipairs(files) do need = need + f.size end
  local free = M.freeKB(M.PKGROOT)
  if free and need / 1024 + 64 > free then
    return nil, ("not enough disk space: %s needs %d KB, %d KB free"):format(name, math.ceil(need / 1024), free)
  end
  local stage, err = M.stage(M.base() .. "/packages/" .. name, files, progress)
  if not stage then return nil, err end
  local root = M.PKGROOT .. "/pkg/" .. name
  M.removeFiles(name)
  local ok, ierr = install(stage, files, root)
  os.execute("rm -rf " .. U.q(stage))
  if not ok then return nil, ierr end
  U.mkdir(M.BINDIR)
  U.mkdir(M.PKGROOT .. "/man")
  for _, f in ipairs(files) do
    local file = f.path:match("^bin/([^/]+)$")
    if file then os.execute(("ln -sf %s %s"):format(U.q(root .. "/" .. f.path), U.q(M.BINDIR .. "/" .. file))) end
    local page = f.path:match("^man/([^/]+%.txt)$")
    if page then os.execute(("ln -sf %s %s"):format(U.q(root .. "/" .. f.path), U.q(M.PKGROOT .. "/man/" .. page))) end
  end
  local set = M.installed()
  set[name] = meta.version or "?"
  saveInstalled(set)
  return meta.version or "?"
end

function M.removeFiles(name)
  local root = M.PKGROOT .. "/pkg/" .. name
  -- links pointing into the package
  for _, dir in ipairs({ M.BINDIR, M.PKGROOT .. "/man" }) do
    local list = U.capture("ls " .. U.q(dir) .. " 2>/dev/null")
    for f in list:gmatch("%S+") do
      local target = U.trim((U.capture("readlink " .. U.q(dir .. "/" .. f))))
      if target:sub(1, #root + 1) == root .. "/" then os.remove(dir .. "/" .. f) end
    end
  end
  os.execute("rm -rf " .. U.q(root))
end

function M.removePkg(name)
  local set = M.installed()
  if not set[name] then return nil, name .. " is not installed" end
  M.removeFiles(name)
  set[name] = nil
  saveInstalled(set)
  return true
end

return M
