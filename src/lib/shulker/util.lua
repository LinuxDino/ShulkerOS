-- Small helpers shared by every Shulker OS command.
local M = {}

M.VERSION = "0.1.0"

---------------------------------------------------------------- paths
-- SHULKER_HOME: where the code lives (/opt/shulker, or /mnt/builtin/shulker from the data pack).
-- State (key, tasks, jobs, logs) lives under ~/.shulker; system config under /etc/shulker.
local HOME
function M.home() return HOME or os.getenv("SHULKER_HOME") or "/opt/shulker" end
function M.setHome(h)
  if h:sub(1, 1) ~= "/" then h = (os.getenv("PWD") or ".") .. "/" .. h:gsub("^%./?", "") end
  h = h:gsub("/+$", "")
  HOME = h
  local ok, std = pcall(require, "posix.stdlib")
  if ok and std.setenv then std.setenv("SHULKER_HOME", h) end
end
function M.userdir()
  local h = os.getenv("SHULKER_STATE")
  if h and h ~= "" then return h end
  return (os.getenv("HOME") or "/root") .. "/.shulker"
end
function M.etcdir() return os.getenv("SHULKER_ETC") or "/etc/shulker" end

---------------------------------------------------------------- files
function M.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

function M.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function M.isdir(path)
  return os.execute("[ -d " .. M.q(path) .. " ]") == true
end

-- write atomically (temp file + rename) so a power cut never leaves half a file
function M.write(path, data, mode)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  if mode then os.execute("chmod " .. mode .. " " .. M.q(tmp)) end
  local okw, werr = f:write(data)
  f:close()
  if not okw then os.remove(tmp) return nil, werr end
  local okr, rerr = os.rename(tmp, path)
  if not okr then os.remove(tmp) return nil, rerr end
  return true
end

function M.append(path, data)
  local f, err = io.open(path, "ab")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

function M.mkdir(path, mode)
  local cmd = "mkdir -p " .. M.q(path)
  if mode then cmd = cmd .. " && chmod " .. mode .. " " .. M.q(path) end
  return os.execute(cmd .. " 2>/dev/null") == true
end

function M.lines(path)
  local out = {}
  local s = M.read(path)
  if not s then return out end
  for line in (s .. (s:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\r?\n") do out[#out + 1] = line end
  return out
end

-- keep a log file below max bytes: drop the oldest half when it grows past
function M.trimlog(path, max)
  max = max or 16384
  local s = M.read(path)
  if s and #s > max then
    local cut = s:find("\n", #s - math.floor(max / 2)) or (#s - math.floor(max / 2))
    M.write(path, "[... older output trimmed ...]\n" .. s:sub(cut + 1))
  end
end

---------------------------------------------------------------- shell
function M.q(s)                          -- POSIX single-quote
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- run a shell command, return output (stdout+stderr), exit code
function M.capture(cmd)
  local p = io.popen(cmd .. " 2>&1", "r")
  if not p then return "", 127 end
  local out = p:read("a") or ""
  local ok, how, code = p:close()
  if how == "signal" then return out, 128 + (code or 0) end
  return out, code or (ok and 0 or 1)
end

function M.which(name)
  local out, code = M.capture("command -v " .. M.q(name))
  if code == 0 and out:match("%S") then return (out:gsub("%s+$", "")) end
end

local ttyCache = {}
function M.isatty(fd)
  fd = fd or 1
  if ttyCache[fd] == nil then ttyCache[fd] = os.execute("[ -t " .. fd .. " ]") == true end
  return ttyCache[fd]
end

function M.trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

function M.split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
  return out
end

-- clip long text for the terminal / for tool results, keeping head and tail
function M.clip(s, max)
  s = tostring(s or "")
  max = max or 12000
  if #s <= max then return s end
  local head = math.floor(max * 0.7)
  return s:sub(1, head) .. ("\n[... %d bytes cut ...]\n"):format(#s - max) .. s:sub(#s - (max - head) + 1)
end

function M.human(n)
  n = tonumber(n) or 0
  if n >= 1048576 then return ("%.1fM"):format(n / 1048576) end
  if n >= 1024 then return ("%.1fK"):format(n / 1024) end
  return tostring(math.floor(n))
end

function M.die(msg, code)
  io.stderr:write(M.c("err", tostring(msg)) .. "\n")
  os.exit(code or 1)
end

---------------------------------------------------------------- theme
-- The "shulker" palette: purple and lavender on the 16-colour OC2 terminal.
-- NO_COLOR or SHULKER_THEME=plain turns colours off.
local themes = {
  shulker = { accent = "35", soft = "95", text = "97", dim = "90", ok = "92", warn = "93", err = "91",
              info = "36", bold = "1" },
  ender   = { accent = "36", soft = "96", text = "97", dim = "90", ok = "92", warn = "93", err = "91",
              info = "35", bold = "1" },
}
local function colorOn()
  if os.getenv("NO_COLOR") then return false end
  local t = os.getenv("SHULKER_THEME")
  if t == "plain" then return false end
  if os.getenv("SHULKER_COLOR") == "1" then return true end
  return M.isatty(1)
end
local COLOR
function M.theme()
  return themes[os.getenv("SHULKER_THEME") or "shulker"] or themes.shulker
end
function M.c(role, s)
  if COLOR == nil then COLOR = colorOn() end
  if not COLOR then return s end
  local code = M.theme()[role] or role
  return "\27[" .. code .. "m" .. s .. "\27[0m"
end
function M.setColor(on) COLOR = on end
function M.colored()
  if COLOR == nil then COLOR = colorOn() end
  return COLOR
end

return M
