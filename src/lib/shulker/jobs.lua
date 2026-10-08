-- Scheduled jobs: run a shell command or a Claude agent prompt later or repeatedly, with BusyBox crond.
--
-- Sedna's /var/spool is a tmpfs, so the usual crontab would vanish on reboot. Shulker OS keeps its
-- crontabs in /etc/shulker/crontabs and starts `crond -c /etc/shulker/crontabs` at boot.
-- Jobs live in ~/.shulker/jobs/jobs.json; each job's output is appended to ~/.shulker/jobs/<id>.log
-- (trimmed to 16 KB, the disk is only 8 MB). The crontab lines between the "managed" markers are
-- rewritten from jobs.json; anything else in the crontab is left alone.
local U = require("shulker.util")
local json = require("shulker.json")
local M = {}

local BEGIN, END = "# --- shulker jobs (managed by `task job`, do not edit) ---", "# --- end shulker jobs ---"

function M.dir() return U.userdir() .. "/jobs" end
function M.file() return M.dir() .. "/jobs.json" end
function M.logPath(id) return M.dir() .. "/" .. id .. ".log" end
function M.crondir() return os.getenv("SHULKER_CRONTABS") or (U.etcdir() .. "/crontabs") end
function M.user() return os.getenv("USER") or os.getenv("LOGNAME") or "root" end

function M.load()
  local d = json.decode(U.read(M.file()) or "")
  if type(d) ~= "table" then return {} end
  local out = {}
  for _, j in ipairs(d) do if type(j) == "table" and j.id then out[#out + 1] = j end end
  return out
end

local function save(list)
  U.mkdir(U.userdir(), "700")
  U.mkdir(M.dir(), "700")
  return U.write(M.file(), json.encode(json.array(list)) .. "\n", "600")
end

function M.get(id)
  for _, j in ipairs(M.load()) do if j.id == id then return j end end
end

---------------------------------------------------------------- schedules
local RANGES = { { 0, 59 }, { 0, 23 }, { 1, 31 }, { 1, 12 }, { 0, 7 } }
local function validField(f, lo, hi)
  for part in (f .. ","):gmatch("([^,]*),") do
    local base, step = part:match("^(.-)/(%d+)$")
    base = base or part
    if step and tonumber(step) == 0 then return false end
    if base ~= "*" then
      local a, b = base:match("^(%d+)%-(%d+)$")
      a = tonumber(a or base) b = tonumber(b or a or base)
      if not a or not b or a < lo or b > hi or a > b then return false end
    end
  end
  return true
end

function M.validCron(spec)
  local f = {}
  for w in spec:gmatch("%S+") do f[#f + 1] = w end
  if #f ~= 5 then return false end
  for i = 1, 5 do if not validField(f[i], RANGES[i][1], RANGES[i][2]) then return false end end
  return true
end

local UNIT = { m = 60, min = 60, mins = 60, minute = 60, minutes = 60, h = 3600, hour = 3600, hours = 3600,
               d = 86400, day = 86400, days = 86400 }

local function atTime(t) return ("%d %d %d %d *"):format(t.min, t.hour, t.day, t.month) end

-- "in 10m", "at 14:30", "every 5m", "every 2h", "hourly", "daily", "daily 09:00", "weekly",
-- or a raw 5-field cron spec. Returns cron spec, once, human text | nil, why
function M.parseWhen(s, now)
  s = U.trim(tostring(s or "")):lower()
  now = now or os.time()
  if M.validCron(s) then return s, false, "cron " .. s end
  local n, unit = s:match("^in%s+(%d+)%s*(%a+)$")
  if n and UNIT[unit] then
    -- cron only knows minutes: round up so it is never early
    local t = os.date("*t", now + tonumber(n) * UNIT[unit] + 59)
    return atTime(t), true, ("once at %02d:%02d on %04d-%02d-%02d"):format(t.hour, t.min, t.year, t.month, t.day)
  end
  local hh, mm = s:match("^at%s+(%d%d?):(%d%d)$")
  if hh then
    hh, mm = tonumber(hh), tonumber(mm)
    if hh > 23 or mm > 59 then return nil, "bad time" end
    local t = os.date("*t", now)
    t.hour, t.min, t.sec = hh, mm, 0
    local when = os.time(t)
    if when <= now then when = when + 86400 end
    local w = os.date("*t", when)
    return atTime(w), true, ("once at %02d:%02d on %04d-%02d-%02d"):format(w.hour, w.min, w.year, w.month, w.day)
  end
  local en, eunit = s:match("^every%s+(%d+)%s*(%a+)$")
  if en and UNIT[eunit] then
    en = tonumber(en)
    local secs = UNIT[eunit]
    if secs == 60 and en >= 1 and en <= 59 then return ("*/%d * * * *"):format(en), false, ("every %d min"):format(en) end
    if secs == 3600 and en >= 1 and en <= 23 then return ("0 */%d * * *"):format(en), false, ("every %d h"):format(en) end
    if secs == 86400 and en >= 1 and en <= 31 then return ("0 0 */%d * *"):format(en), false, ("every %d days"):format(en) end
    return nil, "interval out of range (1-59 min, 1-23 h, 1-31 days)"
  end
  if s == "hourly" or s == "every hour" then return "0 * * * *", false, "hourly" end
  local dh, dm = s:match("^daily%s+(%d%d?):(%d%d)$")
  if not dh then dh, dm = s:match("^every day at%s+(%d%d?):(%d%d)$") end
  if dh then return ("%d %d * * *"):format(tonumber(dm), tonumber(dh)), false, ("daily at %02d:%02d"):format(tonumber(dh), tonumber(dm)) end
  if s == "daily" or s == "every day" then return "0 0 * * *", false, "daily at 00:00" end
  if s == "weekly" then return "0 0 * * 0", false, "weekly (Sunday 00:00)" end
  return nil, "unknown schedule. Try: in 10m, at 14:30, every 5m, every 2h, daily 09:00, hourly, weekly, or a cron spec like '*/15 * * * *'"
end

---------------------------------------------------------------- crontab + crond
local function binDir() return U.home() .. "/bin" end

function M.cronLine(j)
  return ("%s %s/shulker-job run %s"):format(j.schedule, binDir(), j.id)
end

function M.writeCrontab(list)
  list = list or M.load()
  local dir = M.crondir()
  U.mkdir(dir, "755")
  local path = dir .. "/" .. M.user()
  local keep, inside = {}, false
  for _, line in ipairs(U.lines(path)) do
    if line == BEGIN then inside = true
    elseif line == END then inside = false
    elseif not inside then keep[#keep + 1] = line end
  end
  while #keep > 0 and keep[#keep] == "" do keep[#keep] = nil end
  local out = {}
  for _, l in ipairs(keep) do out[#out + 1] = l end
  out[#out + 1] = BEGIN
  out[#out + 1] = "SHULKER_HOME=" .. U.home()
  out[#out + 1] = "PATH=" .. binDir() .. ":/bin:/sbin:/usr/bin:/usr/sbin:/mnt/builtin/bin"
  out[#out + 1] = "HOME=" .. (os.getenv("HOME") or "/root")
  for _, j in ipairs(list) do
    if j.enabled ~= false then out[#out + 1] = M.cronLine(j) end
  end
  out[#out + 1] = END
  local ok, err = U.write(path, table.concat(out, "\n") .. "\n", "600")
  if not ok then return nil, err end
  M.ensureCrond()
  return true
end

function M.crondRunning()
  local out = U.capture("pidof crond")
  return out:match("%d") ~= nil
end

function M.ensureCrond()
  if os.getenv("SHULKER_NO_CROND") == "1" then return true end
  if M.crondRunning() then
    -- crond re-reads crontabs when the directory changes; poke it to be sure
    os.execute("touch " .. U.q(M.crondir()) .. " 2>/dev/null")
    return true
  end
  local _, code = U.capture("crond -b -c " .. U.q(M.crondir()) .. " -L /tmp/crond.log")
  return code == 0
end

---------------------------------------------------------------- add / remove
local function newId(list)
  local used = {}
  for _, j in ipairs(list) do used[j.id] = true end
  for i = 1, 999 do
    local id = ("j%d"):format(i)
    if not used[id] then return id end
  end
end

-- spec: { when = "every 1h", kind = "shell"|"claude", command = "...", name = "...", allow = {tools} }
function M.add(spec)
  local schedule, once, human = M.parseWhen(spec.when)
  if not schedule then return nil, once end
  local kind = spec.kind or "shell"
  if kind ~= "shell" and kind ~= "claude" then return nil, "kind is shell or claude" end
  local command = U.trim(tostring(spec.command or ""))
  if command == "" then return nil, "nothing to run" end
  local list = M.load()
  if #list >= 50 then return nil, "too many jobs (50); remove some first" end
  local allow = {}
  for _, t in ipairs(spec.allow or {}) do allow[#allow + 1] = tostring(t) end
  local j = {
    id = newId(list), name = U.trim(tostring(spec.name or command:sub(1, 40))), kind = kind, command = command,
    schedule = schedule, once = once, when = human, allow = json.array(allow), created = os.date("%Y-%m-%d %H:%M"),
    by = spec.by or "user",
  }
  list[#list + 1] = j
  local ok, err = save(list)
  if not ok then return nil, err end
  local okc, cerr = M.writeCrontab(list)
  if not okc then return nil, "saved, but the crontab could not be written: " .. tostring(cerr) end
  return j
end

function M.remove(id)
  local list, keep, found = M.load(), {}, nil
  for _, j in ipairs(list) do if j.id == id then found = j else keep[#keep + 1] = j end end
  if not found then return nil, "no job " .. tostring(id) end
  save(keep)
  M.writeCrontab(keep)
  return found
end

local function update(id, fn)
  local list = M.load()
  for _, j in ipairs(list) do if j.id == id then fn(j) end end
  save(list)
end

---------------------------------------------------------------- running
function M.commandLine(j)
  if j.kind == "claude" then
    local args = { U.q(binDir() .. "/claude"), "-p", U.q(j.command), "--job", U.q(j.id) }
    if #(j.allow or {}) > 0 then
      local a = {}
      for _, t in ipairs(j.allow) do a[#a + 1] = t end
      args[#args + 1] = "--allow " .. U.q(table.concat(a, ","))
    end
    return table.concat(args, " ")
  end
  return j.command
end

-- run a job now (from crond or `task job run`); returns exit code, output
function M.run(id, opts)
  opts = opts or {}
  local j = M.get(id)
  if not j then return 1, "no job " .. tostring(id) end
  U.mkdir(M.dir(), "700")
  local log = M.logPath(id)
  local started = os.date("%Y-%m-%d %H:%M:%S")
  local cmd = ("cd %s && timeout %d sh -c %s"):format(U.q(os.getenv("HOME") or "/root"), opts.timeout or 1800, U.q(M.commandLine(j)))
  local out, code = U.capture(cmd .. " </dev/null")
  local header = ("=== %s  %s [%s]  exit %d ===\n"):format(started, j.name, j.kind, code)
  U.append(log, header .. out .. (out:sub(-1) == "\n" and "" or "\n"))
  U.trimlog(log, 16384)
  if j.once then
    M.remove(id)
    U.append(log, "(one-time job: removed after running)\n")
  else
    update(id, function(x) x.last_run, x.last_exit = started, code end)
  end
  return code, out
end

function M.tail(id, lines)
  local all = U.lines(M.logPath(id))
  lines = lines or 40
  local from = math.max(1, #all - lines + 1)
  local out = {}
  for i = from, #all do out[#out + 1] = all[i] end
  return table.concat(out, "\n")
end

function M.plain(list)
  if #list == 0 then return "(no scheduled jobs)" end
  local out = {}
  for _, j in ipairs(list) do
    out[#out + 1] = ("%s  %-22s %-6s %s%s"):format(j.id, j.when or j.schedule, j.kind,
      j.name, j.last_run and ("  (last run " .. j.last_run .. ", exit " .. tostring(j.last_exit) .. ")") or "")
  end
  return table.concat(out, "\n")
end

return M
