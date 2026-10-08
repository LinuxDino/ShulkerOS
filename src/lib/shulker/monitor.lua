-- Shulker monitor: reads sensors (energy, redstone, comparators, furnaces, the swarm, the machine itself)
-- and runs rules on them. The daemon (`monitor daemon`, started at boot when monitor.conf exists) writes
-- the current state to /tmp/shulker-monitor.json; `swarm` heartbeats and the projector dashboard read it.
--
-- /etc/shulker/monitor.conf:
--   interval=5
--   rule NAME SENSOR OP VALUE ACTION [ARGS]
--     SENSOR  energy (percent of all energy storage), energy.1 .., redstone.SIDE, comparator, furnace,
--             swarm.offline, swarm.alerts, drone.charge, mem, disk, load
--     OP      <  <=  >  >=  =  !=
--     ACTION  log | redstone:SIDE (on while the alert lasts) | run:COMMAND (once when it starts)
local U = require("shulker.util")
local json = require("shulker.json")
local devices = require("shulker.devices")

local M = {}
M.SIDES = { "up", "down", "north", "south", "east", "west" }

function M.confPath() return U.etcdir() .. "/monitor.conf" end
M.STATE = os.getenv("SHULKER_MONITOR_STATE") or "/tmp/shulker-monitor.json"
M.LOG = "/var/log/shulker-monitor.log"

---------------------------------------------------------------- configuration
function M.load()
  local conf = { interval = 5, rules = {} }
  for _, l in ipairs(U.lines(M.confPath())) do
    local k, v = l:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k == "interval" then conf.interval = tonumber(v) or 5 end
    local name, sensor, op, value, action = l:match("^%s*rule%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.-)%s*$")
    if name then
      conf.rules[#conf.rules + 1] = { name = name, sensor = sensor, op = op, value = value, action = action ~= "" and action or "log" }
    end
  end
  return conf
end

function M.save(conf)
  local out = { "# Shulker monitor (see `man monitor`)", "interval=" .. (conf.interval or 5) }
  for _, r in ipairs(conf.rules) do
    out[#out + 1] = ("rule %s %s %s %s %s"):format(r.name, r.sensor, r.op, r.value, r.action)
  end
  U.mkdir(U.etcdir())
  U.write(M.confPath(), table.concat(out, "\n") .. "\n")
end

local OPS = { ["<"] = true, ["<="] = true, [">"] = true, [">="] = true, ["="] = true, ["!="] = true }
function M.validRule(r)
  if not r.name or not r.name:match("^[%w_.-]+$") then return nil, "the name may use letters, digits, - _ ." end
  if not OPS[r.op] then return nil, "OP is one of < <= > >= = !=" end
  if not tonumber((r.value:gsub("%%$", ""))) then return nil, "VALUE must be a number (energy etc. are percent)" end
  local a = r.action
  if not (a == "log" or a:match("^redstone:%a+$") or a:match("^run:.+")) then
    return nil, "ACTION is log, redstone:SIDE or run:COMMAND"
  end
  return true
end

---------------------------------------------------------------- sensors
local function call(id, method, ...)
  local bus = devices.bus()
  if not bus then return nil end
  local ok, r = pcall(bus.invoke, bus, id, method, ...)
  if ok then return r end
end

local function devicesOf(typeName)
  local out = {}
  for _, d in ipairs(devices.list() or {}) do
    for _, t in ipairs(d.types) do if t == typeName then out[#out + 1] = d.id break end end
  end
  return out
end

-- {name = {value, unit, label}}  plus .energy = list of {stored, max}
function M.read()
  local s, energy = {}, {}
  if devices.bus() then
    local total, cap = 0, 0
    for i, id in ipairs(devicesOf("energy_storage")) do
      local stored, max = tonumber(call(id, "getEnergyStored")) or 0, tonumber(call(id, "getMaxEnergyStored")) or 0
      energy[#energy + 1] = { stored = stored, max = max }
      total, cap = total + stored, cap + max
      s["energy." .. i] = { value = max > 0 and math.floor(stored / max * 100 + 0.5) or 0, unit = "%",
        label = ("%d / %d FE"):format(stored, max) }
    end
    if cap > 0 then s.energy = { value = math.floor(total / cap * 100 + 0.5), unit = "%", label = ("%d / %d FE"):format(total, cap) } end
    local rs = devicesOf("redstone")[1]
    if rs then
      for _, side in ipairs(M.SIDES) do
        s["redstone." .. side] = { value = tonumber(call(rs, "getRedstoneInput", side)) or 0 }
      end
    end
    local cmp = devicesOf("comparator")[1]
    if cmp then s.comparator = { value = tonumber(call(cmp, "getOutputSignal")) or 0 } end
    local fur = devicesOf("furnace")[1]
    if fur then s.furnace = { value = call(fur, "isBurning") and 1 or 0 } end
  end
  -- the machine itself
  local mt, ma = 0, 0
  for _, l in ipairs(U.lines("/proc/meminfo")) do
    local k, v = l:match("^(%w+):%s+(%d+)")
    if k == "MemTotal" then mt = tonumber(v) elseif k == "MemAvailable" then ma = tonumber(v) end
  end
  if mt > 0 then s.mem = { value = math.floor((mt - ma) / mt * 100 + 0.5), unit = "%" } end
  local df = U.capture("busybox df / 2>/dev/null | tail -1")
  local used = df:match("(%d+)%%")
  if used then s.disk = { value = tonumber(used), unit = "%" } end
  local load = (U.read("/proc/loadavg") or ""):match("^(%S+)")
  if load then s.load = { value = tonumber(load) } end
  -- a drone's battery
  local okD, drone = pcall(require, "shulker.drone")
  local di = okD and drone.isDrone() and drone.info()
  if di and di.charge then s["drone.charge"] = { value = di.charge, unit = "%" } end
  -- the swarm, on the main computer
  local okS, swarm = pcall(require, "shulker.swarm")
  if okS and U.exists(swarm.confPath()) then
    local conf = swarm.loadConf()
    if conf.role == "main" then
      local local_ = setmetatable({ leader = "127.0.0.1" }, { __index = conf })
      local st = swarm.call(local_, { op = "status" }, 2)
      if st and st.nodes then
        local off, alerts = 0, 0
        for _, n in ipairs(st.nodes) do
          if not n.online then off = off + 1 end
          alerts = alerts + (tonumber(n.stats and n.stats.alerts) or 0)
        end
        s["swarm.offline"] = { value = off }
        s["swarm.alerts"] = { value = alerts }
      end
    end
  end
  return s, energy
end

---------------------------------------------------------------- rules
local function compare(a, op, b)
  if op == "<" then return a < b elseif op == "<=" then return a <= b elseif op == ">" then return a > b
  elseif op == ">=" then return a >= b elseif op == "=" then return a == b else return a ~= b end
end

function M.log(line)
  local f = io.open(M.LOG, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. line .. "\n") f:close() end
  if U.trimlog then pcall(U.trimlog, M.LOG, 64 * 1024) end
end

local function setRedstone(side, level)
  local rs = devicesOf("redstone")[1]
  if rs then call(rs, "setRedstoneOutput", side, level) end
end

-- one round: read, evaluate, act on changes. active = {name = since}; returns the new state table
function M.tick(conf, active)
  local sensors, energy = M.read()
  local alerts = {}
  for _, r in ipairs(conf.rules) do
    local s = sensors[r.sensor]
    local want = tonumber((r.value:gsub("%%$", "")))
    local hit = s and s.value and want and compare(s.value, r.op, want)
    if hit and not active[r.name] then
      active[r.name] = os.time()
      M.log(("ALERT %s: %s = %s%s (%s %s)"):format(r.name, r.sensor, s.value, s.unit or "", r.op, r.value))
      local side = r.action:match("^redstone:(%a+)$")
      if side then setRedstone(side, 15) end
      local cmd = r.action:match("^run:(.+)$")
      if cmd then os.execute("(" .. cmd .. ") >/dev/null 2>&1 &") end
    elseif not hit and active[r.name] and s then
      active[r.name] = nil
      M.log(("clear %s: %s = %s%s"):format(r.name, r.sensor, s.value, s.unit or ""))
      local side = r.action:match("^redstone:(%a+)$")
      if side then setRedstone(side, 0) end
    end
    if active[r.name] then
      alerts[#alerts + 1] = { name = r.name, sensor = r.sensor, value = s and s.value, since = active[r.name] }
    end
  end
  local state = { time = os.time(), sensors = sensors, energy = energy, alerts = alerts }
  U.write(M.STATE .. ".tmp", json.encode(state))
  os.rename(M.STATE .. ".tmp", M.STATE)
  return state
end

-- the last state the daemon wrote, if it is fresh
function M.state(maxAge)
  local text = U.read(M.STATE)
  if not text then return nil end
  local ok, st = pcall(json.decode, text)
  if not ok or type(st) ~= "table" then return nil end
  if maxAge and os.time() - (tonumber(st.time) or 0) > maxAge then return nil end
  return st
end

return M
